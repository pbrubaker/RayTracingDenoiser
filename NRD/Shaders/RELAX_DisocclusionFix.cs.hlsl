/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE(cbuffer, globalConstants, b, 0, 0)
{
    float4              gFrustumRight;
    float4              gFrustumUp;
    float4              gFrustumForward;

    int2                gResolution;
    float2              gInvViewSize;

    float               gDisocclusionFixEdgeStoppingZFraction;
    float               gDisocclusionFixEdgeStoppingNormalPower;
    float               gMaxRadius;
    int                 gFramesToFix;
};

#include "RELAX_Common.hlsl"

// Inputs
NRI_RESOURCE(Texture2D<uint2>,  gSpecularAndDiffuseIlluminationLogLuv, t, 0, 0);
NRI_RESOURCE(Texture2D<uint2>,  gSpecularAndDiffuseIlluminationResponsiveLogLuv, t, 1, 0);
NRI_RESOURCE(Texture2D<float2>, gSpecularAndDiffuse2ndMoments, t, 2, 0);
NRI_RESOURCE(Texture2D<float2>, gSpecularAndDiffuseHistoryLength, t, 3, 0);
NRI_RESOURCE(Texture2D<uint2>,  gNormalRoughnessDepth, t, 4, 0);

// Outputs
NRI_RESOURCE(RWTexture2D<uint2>,  gOutSpecularAndDiffuseIlluminationLogLuv, u, 0, 0);
NRI_RESOURCE(RWTexture2D<uint2>,  gOutSpecularAndDiffuseIlluminationResponsiveLogLuv, u, 1, 0);
NRI_RESOURCE(RWTexture2D<float2>, gOutSpecularAndDiffuse2ndMoments, u, 2, 0);

// Helper macros
#define PI 3.141593
#define linearStep(a, b, x) saturate((x - a)/(b - a))
#define smoothStep01(x) (x*x*(3.0 - 2.0*x))

// Helper functions
float smoothStep(float a, float b, float x)
{
    x = linearStep(a, b, x); return smoothStep01(x);
}

float3 getCurrentWorldPos(int2 pixelPos, float depth)
{
    float2 uv = ((float2)pixelPos + float2(0.5, 0.5)) * gInvViewSize * 2.0 - 1.0;
    return depth * (gFrustumForward.xyz + gFrustumRight.xyz * uv.x - gFrustumUp.xyz * uv.y);
}

float edgeStoppingDepth(float3 centerWorldPos, float3 centerNormal, float3 sampleWorldPos, float centerLinearZ)
{
    return (abs(dot(centerWorldPos - sampleWorldPos, centerNormal) / centerLinearZ) > gDisocclusionFixEdgeStoppingZFraction) ? 0.0 : 1.0;
}

float getDiffuseNormalWeight(float3 centerNormal, float3 pointNormal)
{
    return pow(max(0.01,dot(centerNormal, pointNormal)), max(gDisocclusionFixEdgeStoppingNormalPower, 0.01));
}

float GetRadius(float numFramesInHistory)
{
    return gMaxRadius / (numFramesInHistory + 1.0);
}

float getSpecularLobeHalfAngle(float roughness)
{
    // Defines a cone angle, where micro-normals are distributed
    float r2 = roughness * roughness;
    float r3 = roughness * r2;

    // Approximation of https://seblagarde.files.wordpress.com/2015/07/course_notes_moving_frostbite_to_pbr_v32.pdf (page 72)
    // for [0..1] domain:

    // float k = 0.75; // % of NDF volume. Is it the trimming factor from VNDF sampling?
    // return atan(m * k / (1.0 - k));

    return 3.141592 * r2 / (1.0 + 0.5*r2 + r3);
}

float2 getNormalWeightParams(float roughness, float numFramesInHistory)
{
    // This is the main parameter - cone angle
    float angle = getSpecularLobeHalfAngle(roughness);

    // Increasing angle ~10x to relax rejection of the neighbors if not enough frames in history
    angle *= 3.0 - 2.666 * saturate(numFramesInHistory / (gFramesToFix + 1.0));
    angle = min(0.5 * PI, angle);

    return float2(angle, 1.0);
}

float getSpecularNormalWeight(float2 params0, float3 n0, float3 n)
{
    float cosa = saturate(dot(n0, n));
    float a = acos(cosa);

    a = 1.0 - smoothStep(0.0, params0.x, a);

    return saturate(1.0 + (a - 1.0) * params0.y);
}


//
// Main
//

[numthreads(8, 8, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    const int2 ipos = int2(dispatchThreadId.xy);

	// Getting data at the center
    float historyLength = 255.0 * gSpecularAndDiffuseHistoryLength[ipos].g; // Using diffuse history length to control disocclusion fix
    uint2 illuminationPacked = gSpecularAndDiffuseIlluminationLogLuv[ipos];
    uint2 illuminationResponsivePacked = gSpecularAndDiffuseIlluminationResponsiveLogLuv[ipos];
    float2 centerSpecularAndDiffuse2ndMoments = gSpecularAndDiffuse2ndMoments[ipos];

    // Early out if no disocclusion detected
    if (historyLength > gFramesToFix)
    {
        gOutSpecularAndDiffuseIlluminationLogLuv[ipos] = illuminationPacked;
        gOutSpecularAndDiffuseIlluminationResponsiveLogLuv[ipos] = illuminationResponsivePacked;
        gOutSpecularAndDiffuse2ndMoments[ipos] = centerSpecularAndDiffuse2ndMoments;
        return;
    }

    // Unpacking the rest of center data
    float3 centerSpecularIlluminationResponsive;
    float3 centerDiffuseIlluminationResponsive;
    UnpackSpecularAndDiffuseFromLogLuvUint2(centerSpecularIlluminationResponsive, centerDiffuseIlluminationResponsive, illuminationResponsivePacked);

    float3 centerNormal;
    float centerRoughness;
    float centerDepth;
    UnpackNormalRoughnessDepth(centerNormal, centerRoughness, centerDepth, gNormalRoughnessDepth[ipos]);

    float3 centerWorldPos = getCurrentWorldPos(ipos, centerDepth);
    float2 normalWeightParams = getNormalWeightParams(centerRoughness, historyLength);

    // Running sparse cross-bilateral filter
    float3 specularIlluminationSum = centerSpecularIlluminationResponsive;
    float3 diffuseIlluminationSum = centerDiffuseIlluminationResponsive;
    float2 specularAndDiffuse2ndMomentsSum = centerSpecularAndDiffuse2ndMoments;

    float diffuseWSum = 1;
    float specularWSum = 1;

    float r = GetRadius(historyLength);

    [unroll]
    for (int j = -2; j <= 2; j++)
    [unroll]
    for (int i = -2; i <= 2; i++)
    {
        int dx = (int)(i * r);
        int dy = (int)(j * r);

        int2 samplePosInt = (int2)ipos + int2(dx, dy);

        if ((samplePosInt.x < 0) || (samplePosInt.x >= gResolution.x)) continue;
        if ((samplePosInt.y < 0) || (samplePosInt.y >= gResolution.y)) continue;
        if ((i == 0) && (j == 0)) continue;

        // Sampling data at the sample location
        // Since disocclusion fix works where there is no / small history, there is no / not much difference between
        // responsive and standard illumination, so we'll blur the responsive illumination for fix disocclusions in both normal and responsive illumination
        float3 sampleSpecularIllumination;
        float3 sampleDiffuseIllumination;
        UnpackSpecularAndDiffuseFromLogLuvUint2(sampleSpecularIllumination, sampleDiffuseIllumination, gSpecularAndDiffuseIlluminationResponsiveLogLuv[samplePosInt]);

        float2 sampleSpecularAndDiffuse2ndMoments = gSpecularAndDiffuse2ndMoments[samplePosInt];

        float3 sampleNormal;
        float sampleRoughnessDontCare;
        float sampleDepth;
        UnpackNormalRoughnessDepth(sampleNormal, sampleRoughnessDontCare, sampleDepth, gNormalRoughnessDepth[samplePosInt]);

        // Edge stopping functions:
        // ..normal
        float specularW = getSpecularNormalWeight(normalWeightParams, centerNormal, sampleNormal);
        float diffuseW = getDiffuseNormalWeight(centerNormal, sampleNormal);

        // ..depth
        float3 sampleWorldPos = getCurrentWorldPos(samplePosInt, sampleDepth);
        float depthWeight = edgeStoppingDepth(centerWorldPos, centerNormal, sampleWorldPos, centerDepth);
        specularW *= depthWeight;
        diffuseW *= depthWeight;

        // Summing up the result
        specularIlluminationSum += sampleSpecularIllumination * specularW;
        diffuseIlluminationSum += sampleDiffuseIllumination * diffuseW;
        specularAndDiffuse2ndMomentsSum.x += sampleSpecularAndDiffuse2ndMoments.x * specularW;
        specularAndDiffuse2ndMomentsSum.y += sampleSpecularAndDiffuse2ndMoments.y * diffuseW;

        specularWSum += specularW;
        diffuseWSum += diffuseW;
    }

    float3 outSpecularIllumination = specularIlluminationSum / specularWSum;
    float3 outDiffuseIllumination = diffuseIlluminationSum / diffuseWSum;
    float2 outSpecularAndDiffuse2ndMoments = specularAndDiffuse2ndMomentsSum / float2(specularWSum, diffuseWSum);

    uint2 outIlluminationPacked = PackSpecularAndDiffuseToLogLuvUint2(outSpecularIllumination, outDiffuseIllumination);

    // Writing out the results
    gOutSpecularAndDiffuseIlluminationLogLuv[ipos] = outIlluminationPacked;
    gOutSpecularAndDiffuseIlluminationResponsiveLogLuv[ipos] = outIlluminationPacked;
    gOutSpecularAndDiffuse2ndMoments[ipos] = outSpecularAndDiffuse2ndMoments;
}
