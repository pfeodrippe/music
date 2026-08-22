#include <metal_stdlib>
using namespace metal;

struct ScoreUniforms {
    float2 viewport;
    float time;
    float pixelRatio;
};

struct ScoreDrawItemGPU {
    float4 rect;
    float4 color;
    float4 params;
    float4 uv;
};

struct ScoreVertexOutput {
    float4 position [[position]];
    float2 local;
    float4 color;
    float4 params [[flat]];
    float2 screen;
    float2 rectSize [[flat]];
    float time [[flat]];
    float2 atlasUV;
    float4 atlasRect [[flat]];
};

float scoreSegmentDistance(float2 point, float2 start, float2 end) {
    float2 fromStart = point - start;
    float2 segment = end - start;
    float along = clamp(dot(fromStart, segment) / dot(segment, segment), 0.0f, 1.0f);
    return length(fromStart - segment * along);
}

float scoreMedian(float3 value) {
    return max(min(value.r, value.g), min(max(value.r, value.g), value.b));
}

vertex ScoreVertexOutput scoreVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant ScoreUniforms &uniforms [[buffer(0)]],
    device const ScoreDrawItemGPU *items [[buffer(1)]]) {
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    ScoreDrawItemGPU item = items[instanceID];
    float2 local = corners[vertexID];
    float2 pixel = item.rect.xy + local * item.rect.zw;
    ScoreVertexOutput output;
    output.position = float4(pixel.x / uniforms.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / uniforms.viewport.y * 2.0, 0, 1);
    output.local = local;
    output.color = item.color;
    output.params = item.params;
    output.screen = pixel;
    output.rectSize = item.rect.zw;
    output.time = uniforms.time;
    output.atlasUV = mix(item.uv.xy, item.uv.zw, local);
    output.atlasRect = item.uv;
    return output;
}

fragment float4 scoreFragment(
    ScoreVertexOutput input [[stage_in]],
    texture2d<float> glyphAtlas [[texture(0)]],
    sampler glyphSampler [[sampler(0)]]) {
    uint kind = uint(input.params.x + 0.5);
    float alpha = input.color.a;
    if (kind == 1) {
        float radius = min(input.params.y, min(input.rectSize.x, input.rectSize.y) * 0.5);
        float2 centered = (input.local - float2(0.5)) * input.rectSize;
        float2 inset = input.rectSize * 0.5 - float2(radius);
        float2 q = abs(centered) - inset;
        float rounded = length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - radius;
        alpha *= 1.0 - smoothstep(-0.85, 0.85, rounded);
    } else if (kind == 2) {
        float distance = length((input.local - float2(0.5)) * 2.0);
        alpha *= 1.0 - smoothstep(0.88, 1.0, distance);
    } else if (kind == 3) {
        float distance = length((input.local - float2(0.5)) * 2.0);
        float breathing = 0.86 + 0.14 * sin(input.time * 3.2 + input.params.z);
        alpha *= (1.0 - smoothstep(0.15, 1.0, distance)) * breathing;
    } else if (kind == 4) {
        float4 sample = glyphAtlas.sample(glyphSampler, input.atlasUV);
        float2 atlasDimensions = float2(glyphAtlas.get_width(), glyphAtlas.get_height());
        float2 atlasPixels = max((input.atlasRect.zw - input.atlasRect.xy) * atlasDimensions, float2(1.0));
        float screenScale = max(0.001, min(input.rectSize.x / atlasPixels.x, input.rectSize.y / atlasPixels.y));
        float screenDistance = (scoreMedian(sample.rgb) - 0.5) * input.params.y * screenScale;
        alpha *= clamp(screenDistance + 0.5, 0.0, 1.0);
    }
    float grain = (fract(sin(dot(input.screen, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.012;
    return float4(clamp(input.color.rgb + float3(grain), float3(0), float3(1)), alpha);
}
