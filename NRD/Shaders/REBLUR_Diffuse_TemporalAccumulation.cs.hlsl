/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE( cbuffer, globalConstants, b, 0, 0 )
{
    float4x4 gViewToClip;
    float4 gFrustum;
    float2 gInvScreenSize;
    float2 gScreenSize;
    uint gBools;
    float gIsOrtho;
    float gUnproject;
    float gDebug;
    float gInf;
    float gPlaneDistSensitivity;
    uint gFrameIndex;
    float gFramerateScale;

    float4x4 gWorldToViewPrev;
    float4x4 gWorldToClipPrev;
    float4x4 gViewToWorld;
    float4x4 gWorldToClip;
    float4 gCameraDelta;
    float2 gMotionVectorScale;
    float gJitterDelta;
    float gCheckerboardResolveAccumSpeed;
    float gDisocclusionThreshold;
    float gDiffMaxAccumulatedFrameNum;
    float gDiffNoisinessBlurrinessBalance;
    uint gDiffCheckerboard;
};

#include "REBLUR_Common.hlsl"

// Inputs
NRI_RESOURCE( Texture2D<float4>, gIn_Normal_Roughness, t, 0, 0 );
NRI_RESOURCE( Texture2D<float>, gIn_ViewZ, t, 1, 0 );
NRI_RESOURCE( Texture2D<float3>, gIn_ObjectMotion, t, 2, 0 );
NRI_RESOURCE( Texture2D<uint2>, gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds, t, 3, 0 );
NRI_RESOURCE( Texture2D<float4>, gIn_History_Diff, t, 4, 0 );
NRI_RESOURCE( Texture2D<float4>, gIn_Diff, t, 5, 0 );

// Outputs
NRI_RESOURCE( RWTexture2D<float>, gOut_InternalData, u, 0, 0 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Diff, u, 1, 0 );

void Preload( int2 sharedId, int2 globalId )
{
    s_Normal_Roughness[ sharedId.y ][ sharedId.x ] = _NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ globalId ] );
    s_ViewZ[ sharedId.y ][ sharedId.x ] = gIn_ViewZ[ globalId ];
}

[numthreads( GROUP_X, GROUP_Y, 1 )]
void main( int2 threadId : SV_GroupThreadId, int2 pixelPos : SV_DispatchThreadId, uint threadIndex : SV_GroupIndex )
{
    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvScreenSize;

    PRELOAD_INTO_SMEM;

    // Early out
    int2 smemPos = threadId + BORDER;
    float viewZ = s_ViewZ[ smemPos.y ][ smemPos.x ];

    [branch]
    if( abs( viewZ ) > abs( gInf ) )
    {
        #if( BLACK_OUT_INF_PIXELS == 1 )
            gOut_Diff[ pixelPos ] = 0;
        #endif
        gOut_InternalData[ pixelPos ] = PackDiffInternalData( );
        return;
    }

    // Center position
    float3 Xv = STL::Geometry::ReconstructViewPosition( pixelUv, gFrustum, viewZ, gIsOrtho );
    float3 X = STL::Geometry::AffineTransform( gViewToWorld, Xv );
    float invDistToPoint = STL::Math::Rsqrt( STL::Math::LengthSquared( Xv ) );

    // Normal and roughness
    float4 normalAndRoughness = s_Normal_Roughness[ smemPos.y ][ smemPos.x ];
    float3 N = normalAndRoughness.xyz;
    float roughness = normalAndRoughness.w;

    // Flat normal
    float3 Nflat = N;

    [unroll]
    for( int dy = 0; dy <= BORDER * 2; dy++ )
    {
        [unroll]
        for( int dx = 0; dx <= BORDER * 2; dx++ )
        {
            if( dx == BORDER && dy == BORDER )
                continue;

            int2 pos = threadId + int2( dx, dy );
            Nflat += s_Normal_Roughness[ pos.y ][ pos.x ].xyz; // yes, no weight
        }
    }

    Nflat = normalize( Nflat );

    // Compute previous position for surface motion
    float3 motionVector = gIn_ObjectMotion[ pixelPos ] * gMotionVectorScale.xyy;
    float2 pixelUvPrev = STL::Geometry::GetPrevUvFromMotion( pixelUv, X, gWorldToClipPrev, motionVector, IsWorldSpaceMotion() );
    float isInScreen = IsInScreen( pixelUvPrev );
    float2 pixelMotion = pixelUvPrev - pixelUv;
    float3 Xprev = X + motionVector * float( IsWorldSpaceMotion() );

    // Previous data ( Catmull-Rom )
    STL::Filtering::CatmullRom catmullRomFilterAtPrevPos = STL::Filtering::GetCatmullRomFilter( saturate( pixelUvPrev ), gScreenSize );
    float2 catmullRomFilterAtPrevPosGatherOrigin = catmullRomFilterAtPrevPos.origin * gInvScreenSize;
    uint4 prevPackRed0 = gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds.GatherRed( gNearestClamp, catmullRomFilterAtPrevPosGatherOrigin, float2( 1, 1 ) ).wzxy;
    uint4 prevPackRed1 = gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds.GatherRed( gNearestClamp, catmullRomFilterAtPrevPosGatherOrigin, float2( 3, 1 ) ).wzxy;
    uint4 prevPackRed2 = gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds.GatherRed( gNearestClamp, catmullRomFilterAtPrevPosGatherOrigin, float2( 1, 3 ) ).wzxy;
    uint4 prevPackRed3 = gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds.GatherRed( gNearestClamp, catmullRomFilterAtPrevPosGatherOrigin, float2( 3, 3 ) ).wzxy;

    float4 prevViewZ0 = UnpackViewZ( prevPackRed0 );
    float4 prevViewZ1 = UnpackViewZ( prevPackRed1 );
    float4 prevViewZ2 = UnpackViewZ( prevPackRed2 );
    float4 prevViewZ3 = UnpackViewZ( prevPackRed3 );

    float4 diffPrevAccumSpeeds = UnpackDiffAccumSpeed( uint4( prevPackRed0.w, prevPackRed1.z, prevPackRed2.y, prevPackRed3.x ) );

    // Previous normal, roughness and accum speed ( bilinear )
    STL::Filtering::Bilinear bilinearFilterAtPrevPos = STL::Filtering::GetBilinearFilter( saturate( pixelUvPrev ), gScreenSize );
    float2 bilinearFilterAtPrevPosGatherOrigin = ( bilinearFilterAtPrevPos.origin + 1.0 ) * gInvScreenSize;
    uint4 prevPackGreen = gIn_Prev_ViewZ_Normal_Roughness_AccumSpeeds.GatherGreen( gNearestClamp, bilinearFilterAtPrevPosGatherOrigin ).wzxy;
    float3 prevNormal00 = UnpackNormalRoughness( prevPackGreen.x ).xyz;
    float3 prevNormal10 = UnpackNormalRoughness( prevPackGreen.y ).xyz;
    float3 prevNormal01 = UnpackNormalRoughness( prevPackGreen.z ).xyz;
    float3 prevNormal11 = UnpackNormalRoughness( prevPackGreen.w ).xyz;

    float3 prevNflat = prevNormal00 + prevNormal10 + prevNormal01 + prevNormal11;
    prevNflat = normalize( prevNflat );

    // Plane distance based disocclusion for surface motion
    float parallax = ComputeParallax( pixelUv, Xprev, gCameraDelta.xyz, gWorldToClip );
    float2 disocclusionThresholds = GetDisocclusionThresholds( gDisocclusionThreshold, gJitterDelta, viewZ, parallax, Nflat, X, invDistToPoint );
    float3 Xvprev = STL::Geometry::AffineTransform( gWorldToViewPrev, Xprev );
    float NoXprev1 = abs( dot( Nflat, Xprev ) ); // = dot( Nvflatprev, Xvprev ), "abs" is needed here only to get "max" absolute value in the next line
    float NoXprev2 = abs( dot( prevNflat, Xprev ) );
    float NoXprev = max( NoXprev1, NoXprev2 ) * invDistToPoint;
    float NoVprev = NoXprev * STL::Math::PositiveRcp( abs( Xvprev.z ) ); // = dot( Nvflatprev, Xvprev / Xvprev.z )
    float4 planeDist0 = abs( NoVprev * abs( prevViewZ0 ) - NoXprev );
    float4 planeDist1 = abs( NoVprev * abs( prevViewZ1 ) - NoXprev );
    float4 planeDist2 = abs( NoVprev * abs( prevViewZ2 ) - NoXprev );
    float4 planeDist3 = abs( NoVprev * abs( prevViewZ3 ) - NoXprev );
    float4 occlusion0 = saturate( isInScreen - step( disocclusionThresholds.x, planeDist0 ) );
    float4 occlusion1 = saturate( isInScreen - step( disocclusionThresholds.x, planeDist1 ) );
    float4 occlusion2 = saturate( isInScreen - step( disocclusionThresholds.x, planeDist2 ) );
    float4 occlusion3 = saturate( isInScreen - step( disocclusionThresholds.x, planeDist3 ) );

    // Avoid "got stuck in history" effect under slow motion when only 1 sample is valid from 2x2 footprint and there is a big difference between
    // foreground and background surfaces. Instead of final scalar accum speed scaling we can apply it to accum speeds from the previous frame
    float4 planeDist2x2 = float4( planeDist0.w, planeDist1.z, planeDist2.y, planeDist3.x );
    planeDist2x2 = STL::Math::LinearStep( 0.2, disocclusionThresholds.x, planeDist2x2 );

    float footprintAvg = STL::Filtering::ApplyBilinearFilter( planeDist2x2.x, planeDist2x2.y, planeDist2x2.z, planeDist2x2.w, bilinearFilterAtPrevPos );
    float fmin = min( bilinearFilterAtPrevPos.weights.x, bilinearFilterAtPrevPos.weights.y ) + 0.01;
    float fmax = max( bilinearFilterAtPrevPos.weights.x, bilinearFilterAtPrevPos.weights.y ) + 0.01;
    footprintAvg = lerp( footprintAvg, 1.0, STL::Math::LinearStep( 0.05, 0.5, fmin / fmax ) );

    diffPrevAccumSpeeds *= footprintAvg;

    // Ignore backfacing history
    float4 cosa;
    cosa.x = dot( N, prevNormal00.xyz );
    cosa.y = dot( N, prevNormal10.xyz );
    cosa.z = dot( N, prevNormal01.xyz );
    cosa.w = dot( N, prevNormal11.xyz );

    float4 frontFacing = STL::Math::LinearStep( disocclusionThresholds.y, 0.001, cosa );
    occlusion0.w *= frontFacing.x;
    occlusion1.z *= frontFacing.y;
    occlusion2.y *= frontFacing.z;
    occlusion3.x *= frontFacing.w;

    float4 diffOcclusion2x2 = float4( occlusion0.w, occlusion1.z, occlusion2.y, occlusion3.x );

    // Sample diffuse history
    float2 catmullRomFilterAtPrevPosOrigin = ( catmullRomFilterAtPrevPos.origin + 0.5 ) * gInvScreenSize;
    float4 d10 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 1, 0 ) );
    float4 d20 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 2, 0 ) );
    float4 d01 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 0, 1 ) );
    float4 d11 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 1, 1 ) );
    float4 d21 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 2, 1 ) );
    float4 d31 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 3, 1 ) );
    float4 d02 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 0, 2 ) );
    float4 d12 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 1, 2 ) );
    float4 d22 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 2, 2 ) );
    float4 d32 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 3, 2 ) );
    float4 d13 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 1, 3 ) );
    float4 d23 = gIn_History_Diff.SampleLevel( gNearestClamp, catmullRomFilterAtPrevPosOrigin, 0, int2( 2, 3 ) );

    float4 diffWeights = STL::Filtering::GetBilinearCustomWeights( bilinearFilterAtPrevPos, diffOcclusion2x2 );
    float4 diffHistory = STL::Filtering::ApplyBilinearCustomWeights( d11, d21, d12, d22, diffWeights );
    float4 diffHistoryCatRom = STL::Filtering::ApplyCatmullRomFilterNoCorners( catmullRomFilterAtPrevPos, d10, d20, d01, d11, d21, d31, d02, d12, d22, d32, d13, d23 );
    diffHistory = MixLinearAndCatmullRom( diffHistory, diffHistoryCatRom, occlusion0, occlusion1, occlusion2, occlusion3 );

    // Accumulation speeds
    float diffAccumSpeed;
    float diffAccumSpeedFade = GetAccumSpeed( diffPrevAccumSpeeds, diffWeights, gDiffMaxAccumulatedFrameNum, gDiffNoisinessBlurrinessBalance, 1.0, diffAccumSpeed );

    // Noisy signal with reconstruction (if needed)
    uint checkerboard = STL::Sequence::CheckerBoard( pixelPos, gFrameIndex );

    float4 diff = gIn_Diff[ pixelPos ];
    bool diffHasData = gDiffCheckerboard == 2 || checkerboard == gDiffCheckerboard;
    if( !diffHasData )
    {
        float2 temporalAccumulationParams = GetTemporalAccumulationParams( isInScreen, diffAccumSpeed, parallax );
        float historyWeight = gCheckerboardResolveAccumSpeed * temporalAccumulationParams.x;

        diff = lerp( diff, diffHistory, historyWeight );
    }

    // Diffuse accumulation
    diffAccumSpeed = GetSpecAccumSpeed( diffAccumSpeed, 1.0, 0.0, 0.0 );
    float diffAccumSpeedNonLinear = 1.0 / ( diffAccumSpeedFade * diffAccumSpeed + 1.0 );

    float4 diffResult;
    diffResult.xyz = lerp( diffHistory.xyz, diff.xyz, diffAccumSpeedNonLinear );
    diffResult.w = lerp( diffHistory.w, diff.w, max( diffAccumSpeedNonLinear, HIT_DIST_MIN_ACCUM_SPEED( 1.0 ) ) );

    // Get rid of possible negative values
    diffResult.xyz = _NRD_YCoCgToLinear( diffResult.xyz );
    diffResult.w = max( diffResult.w, 0.0 );
    diffResult.xyz = _NRD_LinearToYCoCg( diffResult.xyz );

    // Output
    gOut_InternalData[ pixelPos ] = PackDiffInternalData( diffAccumSpeed );
    gOut_Diff[ pixelPos ] = diffResult;
}
