#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Port of the Figma "Organic edge blur" custom effect (sticker stats map,
// Figma 10:80). Edges fade to transparent along a wavy boundary while blurring
// progressively more toward the outside. Lengths are in points, like the
// original, which works in logical (render-scale independent) units.

static half4 sampleOrZero(SwiftUI::Layer layer, float2 p, float2 dims) {
    float2 inside = step(float2(0.0), p) * step(p, dims);
    return layer.sample(p) * half(inside.x * inside.y);
}

[[ stitchable ]] half4 organicEdgeBlur(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float blurStrength,
    float edgeWidth,
    float falloff,
    float wavesOn,
    float waveAmount,
    float waveScale
) {
    float2 dims = max(size, float2(1.0));
    float2 p = position;
    float4 inputColor = float4(layer.sample(p));

    float shorter = min(dims.x, dims.y);
    float width = max(shorter * edgeWidth * 0.01, 0.001);
    float wavelength = max(shorter * waveScale * 0.01, 0.001);
    float2 wavePhase = p * (6.2831853 / wavelength);
    float waveEnabled = wavesOn >= 0.5 ? 1.0 : 0.0;
    float amp = width * waveAmount * 0.01 * waveEnabled;
    float leftWave = amp * (0.65 * sin(wavePhase.y + 0.7) + 0.35 * sin(wavePhase.y * 0.57 + 2.1));
    float rightWave = amp * (0.65 * sin(wavePhase.y * 0.93 + 3.4) + 0.35 * sin(wavePhase.y * 0.49 + 0.5));
    float topWave = amp * (0.65 * sin(wavePhase.x * 0.87 + 1.3) + 0.35 * sin(wavePhase.x * 0.51 + 4.2));
    float bottomWave = amp * (0.65 * sin(wavePhase.x * 1.07 + 4.1) + 0.35 * sin(wavePhase.x * 0.63 + 2.7));
    float leftMask = 1.0 - smoothstep(0.0, width + leftWave, p.x);
    float rightMask = 1.0 - smoothstep(0.0, width + rightWave, dims.x - p.x);
    float topMask = 1.0 - smoothstep(0.0, width + topWave, p.y);
    float bottomMask = 1.0 - smoothstep(0.0, width + bottomWave, dims.y - p.y);
    float edgeMask = 1.0 - (1.0 - leftMask) * (1.0 - rightMask) * (1.0 - topMask) * (1.0 - bottomMask);

    float progression = pow(clamp(edgeMask, 0.0, 1.0), falloff);
    // Wave-modulated widths leave the physical boundaries anchored at zero alpha.
    float opacity = 1.0 - smoothstep(0.0, 1.0, progression);
    float sigma = blurStrength * progression;
    // Keep the unaffected center exact and avoid all filter taps there.
    if (sigma <= 0.001) {
        return half4(inputColor * opacity);
    }

    float4 blurred = float4(0.0);
    for (int i = 0; i < 96; i++) {
        float fraction = (float(i) + 0.5) / 96.0;
        float radius = sqrt(-2.0 * log(1.0 - fraction * 0.99));
        float angle = float(i) * 2.39996323;
        float2 offset = float2(cos(angle), sin(angle)) * radius * sigma;
        blurred += float4(sampleOrZero(layer, p + offset, dims));
    }
    blurred /= 96.0;
    float3 straightColor = blurred.rgb / max(blurred.a, 0.00001);
    float4 softened = float4(straightColor * inputColor.a, inputColor.a);
    float activation = smoothstep(0.0, 0.35, sigma);
    // Preserve source coverage, then fade premultiplied RGB and alpha together.
    return half4(mix(inputColor, softened, activation) * opacity);
}
