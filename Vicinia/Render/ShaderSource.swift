// Vicinia — Metal shader source, compiled on device at renderer start with
// MTLDevice.makeLibrary(source:options:) because the build Mac's Xcode has no
// Metal Toolchain component (build-time .metal compilation unavailable).
// SPDX-License-Identifier: MIT

enum ShaderSource {
    static let metal = #"""
// Vicinia — stripe composition and 4:4:4 Y'CbCr → R'G'B' conversion.
// SPDX-License-Identifier: MIT
// Technique (shader conversion from CoreVideo planes) per Apple's Metal video
// sample guidance; no 4:2:0 assumption: luma and CbCr planes are full size.

#include <metal_stdlib>
using namespace metal;

struct StripeQuad {
    float4 dst;   // x0, y0, x1, y1 in NDC
    float4 src;   // u0, v0, u1, v1 in normalized texture coordinates
};

struct ColorParams {
    float4 r;        // coefficients for (Y, Cb, Cr) of R
    float4 g;
    float4 b;
    float4 offsets;  // Y offset, C offset, Y scale, C scale
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut stripe_vertex(uint vid [[vertex_id]], constant StripeQuad &q [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    VertexOut o;
    o.position = float4(mix(q.dst.x, q.dst.z, corner.x), mix(q.dst.y, q.dst.w, corner.y), 0.0, 1.0);
    o.uv = float2(mix(q.src.x, q.src.z, corner.x), mix(q.src.y, q.src.w, corner.y));
    return o;
}

fragment half4 ycbcr444_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::sample> luma [[texture(0)]],
                                 texture2d<float, access::sample> chroma [[texture(1)]],
                                 constant ColorParams &c [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float y = (luma.sample(s, in.uv).r - c.offsets.x) * c.offsets.z;
    float2 cbcr = (chroma.sample(s, in.uv).rg - c.offsets.y) * c.offsets.w;
    float3 ycc = float3(y, cbcr.x, cbcr.y);
    float3 rgb = float3(dot(c.r.xyz, ycc), dot(c.g.xyz, ycc), dot(c.b.xyz, ycc));
    return half4(half3(saturate(rgb)), 1.0h);
}
fragment half4 cursor_fragment(VertexOut in [[stage_in]], texture2d<half> sprite [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return sprite.sample(s, in.uv);
}
"""#
}
