// SPDX-License-Identifier: AGPL-3.0-only
//
// Video shaders:
//  - ycbcr_to_rgb: YCbCr -> RGB, optionally cropping away detected black bars
//  - present_sharpen: places the picture on screen with contrast-adaptive
//    sharpening (in the spirit of AMD FidelityFX CAS) and, in Smart mode,
//    fills the unused screen area with a soft glow of the picture's own
//    colours (like YouTube's Ambient mode).

#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

// One oversized triangle covering the whole target.
vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct ConvertParams {
    float4 row0;     // R = dot(row0.xyz, (y, cb, cr))
    float4 row1;     // G
    float4 row2;     // B
    float4 range;    // x: luma offset, y: luma scale, z: chroma offset, w: chroma scale
    float4 crop;     // x, y, w, h of the source region to keep (uv), for black-bar trimming
};

fragment float4 ycbcr_to_rgb(VOut in [[stage_in]],
                             texture2d<float> lumaTex [[texture(0)]],
                             texture2d<float> chromaTex [[texture(1)]],
                             constant ConvertParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = p.crop.xy + in.uv * p.crop.zw;
    float y = (lumaTex.sample(s, uv).r - p.range.x) * p.range.y;
    float2 c = (chromaTex.sample(s, uv).rg - p.range.z) * p.range.w;
    float3 ycc = float3(y, c.x, c.y);
    float3 rgb = float3(dot(p.row0.xyz, ycc), dot(p.row1.xyz, ycc), dot(p.row2.xyz, ycc));
    return float4(saturate(rgb), 1.0);
}

struct PresentParams {
    float2 texel;        // 1 / source size
    float sharpness;     // 0 = off, 1 = max
    float ambient;       // 1 = glow outside the picture, 0 = black
    float4 contentRect;  // where the picture sits in the output, uv (x, y, w, h)
    float glowLevel;     // mip level used for the glow (very blurred)
    float glowStrength;  // brightness of the glow, 0...1
    float2 pad;
};

static float3 ambient_glow(float2 vuv, texture2d<float> glowSrc, constant PresentParams &p) {
    constexpr sampler gs(filter::linear, mip_filter::linear, address::clamp_to_edge);
    // Sample just inside the nearest picture edge, heavily blurred via a high mip level.
    float2 inside = clamp(vuv, float2(0.03), float2(0.97));
    float3 c = glowSrc.sample(gs, inside, level(p.glowLevel)).rgb;
    // Fade out with distance from the picture so the glow reads as light, not image.
    float2 outside = max(max(-vuv, vuv - 1.0), 0.0);
    float d = length(outside * float2(p.contentRect.z, p.contentRect.w)) * 6.0;
    float fade = exp(-d * 1.6);
    return c * p.glowStrength * mix(0.35, 1.0, fade);
}

fragment float4 present_sharpen(VOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                texture2d<float> glowSrc [[texture(1)]],
                                constant PresentParams &p [[buffer(0)]]) {
    float2 vuv = (in.uv - p.contentRect.xy) / p.contentRect.zw;
    if (any(vuv < 0.0) || any(vuv > 1.0)) {
        if (p.ambient < 0.5) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        return float4(ambient_glow(vuv, glowSrc, p), 1.0);
    }

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, vuv).rgb;
    if (p.sharpness <= 0.001) {
        return float4(c, 1.0);
    }
    float3 n = src.sample(s, vuv + float2(0.0, -p.texel.y)).rgb;
    float3 so = src.sample(s, vuv + float2(0.0,  p.texel.y)).rgb;
    float3 e = src.sample(s, vuv + float2( p.texel.x, 0.0)).rgb;
    float3 w = src.sample(s, vuv + float2(-p.texel.x, 0.0)).rgb;

    float3 mn = min(c, min(min(n, so), min(e, w)));
    float3 mx = max(c, max(max(n, so), max(e, w)));
    // Less sharpening where local contrast is already high (avoids halos).
    float3 amp = saturate(min(mn, 1.0 - mx) / max(mx, 1e-4));
    amp = sqrt(amp);
    float peak = -1.0 / mix(8.0, 5.0, saturate(p.sharpness));
    float3 wt = amp * peak;
    float3 outc = (c + (n + so + e + w) * wt) / (1.0 + 4.0 * wt);
    return float4(saturate(outc), 1.0);
}
