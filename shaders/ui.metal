#include <metal_stdlib>
using namespace metal;

// Packed fields exactly match Odin's 48-byte Vertex on both Mac architectures.
struct Vertex {
    packed_float2 pos;
    packed_float2 uv;
    packed_float4 color;
    packed_float2 stroke;
    packed_float2 clip_x;
};
struct Fragment {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 stroke [[flat]];
    float2 clip_x [[flat]];
};
vertex Fragment ui_vertex(uint index [[vertex_id]],
                          const device Vertex *vertices [[buffer(0)]],
                          constant float2 &extent [[buffer(1)]]) {
    Vertex v = vertices[index];
    Fragment out;
    float2 position = float2(v.pos) / extent * 2.0 - 1.0;
    // Metal's viewport maps positive clip-space Y to the top of the drawable.
    out.position = float4(position.x, -position.y, 0.0, 1.0);
    out.uv = float2(v.uv);
    out.color = float4(v.color);
    out.stroke = float2(v.stroke);
    out.clip_x = float2(v.clip_x);
    return out;
}
fragment float4 ui_fragment(Fragment in [[stage_in]],
                           texture2d<float> atlas [[texture(0)]]) {
    if (in.clip_x.y > in.clip_x.x &&
        (in.position.x < in.clip_x.x || in.position.x >= in.clip_x.y)) discard_fragment();
    if (in.stroke.x < 0.0) {
        float height = clamp(in.uv.y, 0.0, 1.0);
        float3 tint = in.color.rgb;
        if (in.stroke.x == -1.0) {
            float value = clamp(in.uv.x, 0.0, 1.0);
            float3 green = float3(0.43, 0.83, 0.64);
            float3 amber = float3(0.96, 0.72, 0.39);
            float3 red = float3(0.96, 0.36, 0.36);
            tint = value <= 0.5 ? mix(green, amber, value * 2.0)
                                : mix(amber, red, (value - 0.5) * 2.0);
        }
        return float4(tint, in.color.a * mix(0.03, 0.08, height));
    }
    float coverage;
    if (in.stroke.x > 0.0) {
        float2 nearest = float2(clamp(in.uv.x, 0.0, in.stroke.y), 0.0);
        float distance = length(in.uv - nearest) - in.stroke.x;
        coverage = clamp(0.5 - distance, 0.0, 1.0);
    } else {
        constexpr sampler font_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);
        coverage = atlas.sample(font_sampler, in.uv).r;
    }
    return float4(in.color.rgb, in.color.a * coverage);
}
