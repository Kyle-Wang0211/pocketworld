#include <metal_stdlib>

using namespace metal;

struct CaptureGlassQuadInput {
  float4 position [[attribute(0)]];
  float2 texcoord0 [[attribute(1)]];
};

struct CaptureGlassRasterData {
  float4 position [[position]];
  float2 texcoord0;
};

struct CaptureGlassSymbols {
  float4 captureViewport;
  float4 captureGlassRect;
  float4 captureGlassOptics;
};

vertex CaptureGlassRasterData captureGlassVertex(
  CaptureGlassQuadInput input [[stage_in]]) {
  CaptureGlassRasterData output;
  output.position = input.position;
  output.texcoord0 = input.texcoord0;
  return output;
}

fragment half4 captureGlassFragment(
  CaptureGlassRasterData input [[stage_in]],
  constant CaptureGlassSymbols &symbols [[buffer(0)]],
  texture2d<half> sceneColor [[texture(0)]]) {
  constexpr sampler sceneSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
  );

  const float2 rasterPixels = input.position.xy;
  const float2 fullFrameUV = rasterPixels * symbols.captureViewport.zw;
  const float2 centerPixels = symbols.captureGlassRect.xy;
  const float2 halfSizePixels = symbols.captureGlassRect.zw;
  const float radiusPixels = clamp(
    symbols.captureGlassOptics.x,
    0.0f,
    min(halfSizePixels.x, halfSizePixels.y)
  );

  const float2 localPixels = rasterPixels - centerPixels;
  const float2 roundedBox =
    abs(localPixels) - max(halfSizePixels - radiusPixels, float2(0.0f));
  const float2 outsideCorner = max(roundedBox, float2(0.0f));
  const float outsideLength = length(outsideCorner);
  const float signedDistance = outsideLength
    + min(max(roundedBox.x, roundedBox.y), 0.0f)
    - radiusPixels;

  const float2 localSign = select(
    float2(-1.0f),
    float2(1.0f),
    localPixels >= float2(0.0f)
  );
  const float chooseHorizontal = step(roundedBox.y, roundedBox.x);
  const float2 sideNormal = mix(
    float2(0.0f, localSign.y),
    float2(localSign.x, 0.0f),
    chooseHorizontal
  );
  const float2 cornerNormal = localSign
    * outsideCorner / max(outsideLength, 1.0e-5f);
  const float2 analyticNormal = mix(
    sideNormal,
    cornerNormal,
    step(1.0e-5f, outsideLength)
  );

  const float inside = step(signedDistance, 0.0f)
    * step(0.5f, symbols.captureGlassOptics.w);
  const float boundaryDepth = max(-signedDistance, 0.0f);
  const float edgeBand = 1.0f - smoothstep(
    0.0f,
    max(radiusPixels, 1.0f),
    boundaryDepth
  );
  const float requestedDisplacement =
    symbols.captureGlassOptics.y * edgeBand;
  const float seamSafeDisplacement = min(
    requestedDisplacement,
    boundaryDepth * 0.75f
  );
  const float2 displacedUV = fullFrameUV
    + analyticNormal * seamSafeDisplacement * inside
      * symbols.captureViewport.zw;

  half4 sampledColor = sceneColor.sample(sceneSampler, displacedUV);
  const half tintAlpha = half(symbols.captureGlassOptics.z * inside);
  sampledColor.rgb = mix(sampledColor.rgb, half3(1.0h), tintAlpha);
  const half edgeLight = half(
    inside
      * (1.0f - smoothstep(0.0f, 2.0f, boundaryDepth))
      * 0.025f
  );
  sampledColor.rgb = min(sampledColor.rgb + edgeLight, half3(1.0h));
  return sampledColor;
}
