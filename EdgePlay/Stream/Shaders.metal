// SPDX-License-Identifier: AGPL-3.0-only
//
// Video shaders: YCbCr -> RGB conversion and a contrast-adaptive sharpening
// present pass (in the spirit of AMD FidelityFX CAS) that also does the final
// bilinear scale when MetalFX isn't available.

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
};

fragment float4 ycbcr_to_rgb(VOut in [[stage_in]],
                             texture2d<float> lumaTex [[texture(0)]],
                             texture2d<float> chromaTex [[texture(1)]],
                             constant ConvertParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = (lumaTex.sample(s, in.uv).r - p.range.x) * p.range.y;
    float2 c = (chromaTex.sample(s, in.uv).rg - p.range.z) * p.range.w;
    float3 ycc = float3(y, c.x, c.y);
    float3 rgb = float3(dot(p.row0.xyz, ycc), dot(p.row1.xyz, ycc), dot(p.row2.xyz, ycc));
    return float4(saturate(rgb), 1.0);
}

struct PresentParams {
    float2 texel;      // 1 / source size
    float sharpness;   // 0 = off, 1 = max
    float pad;
};

fragment float4 present_sharpen(VOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, in.uv).rgb;
    if (p.sharpness <= 0.001) {
        return float4(c, 1.0);
    }
    float3 n = src.sample(s, in.uv + float2(0.0, -p.texel.y)).rgb;
    float3 so = src.sample(s, in.uv + float2(0.0,  p.texel.y)).rgb;
    float3 e = src.sample(s, in.uv + float2( p.texel.x, 0.0)).rgb;
    float3 w = src.sample(s, in.uv + float2(-p.texel.x, 0.0)).rgb;

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
