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
};

struct ScoreVertexOutput {
    float4 position [[position]];
    float2 local;
    float4 color;
    float4 params [[flat]];
    float2 screen;
    float2 rectSize [[flat]];
    float time [[flat]];
};

float scoreSegmentDistance(float2 point, float2 start, float2 end) {
    float2 fromStart = point - start;
    float2 segment = end - start;
    float along = clamp(dot(fromStart, segment) / dot(segment, segment), 0.0f, 1.0f);
    return length(fromStart - segment * along);
}

float scoreEllipseRing(float2 point, float2 center, float2 scale, float width) {
    return abs(length((point - center) / scale) - 1.0f) * min(scale.x, scale.y) - width;
}

float scoreFilledEllipse(float2 point, float2 center, float2 scale) {
    return (length((point - center) / scale) - 1.0f) * min(scale.x, scale.y);
}

float scoreTrebleClefDistance(float2 point) {
    float distance = scoreSegmentDistance(point, float2(0.12, -0.88), float2(0.12, 0.80)) - 0.052;
    distance = min(distance, scoreEllipseRing(point, float2(0.11, -0.59), float2(0.34, 0.32), 0.055));
    distance = min(distance, scoreEllipseRing(point, float2(-0.04, 0.13), float2(0.62, 0.34), 0.070));
    distance = min(distance, scoreSegmentDistance(point, float2(0.09, -0.30), float2(-0.38, -0.02)) - 0.063);
    distance = min(distance, scoreSegmentDistance(point, float2(-0.38, -0.02), float2(-0.42, 0.22)) - 0.063);
    distance = min(distance, scoreSegmentDistance(point, float2(-0.42, 0.22), float2(-0.08, 0.39)) - 0.063);
    distance = min(distance, scoreSegmentDistance(point, float2(-0.08, 0.39), float2(0.42, 0.34)) - 0.063);
    distance = min(distance, scoreEllipseRing(point, float2(0.08, 0.72), float2(0.34, 0.15), 0.052));
    return distance;
}

float scoreBassClefDistance(float2 point) {
    float distance = scoreEllipseRing(point, float2(-0.18, -0.18), float2(0.49, 0.39), 0.085);
    distance = min(distance, scoreFilledEllipse(point, float2(-0.47, -0.19), float2(0.14, 0.14)));
    distance = min(distance, scoreSegmentDistance(point, float2(0.12, -0.01), float2(-0.01, 0.35)) - 0.075);
    distance = min(distance, scoreSegmentDistance(point, float2(-0.01, 0.35), float2(-0.31, 0.65)) - 0.068);
    distance = min(distance, scoreFilledEllipse(point, float2(0.55, -0.20), float2(0.075, 0.075)));
    distance = min(distance, scoreFilledEllipse(point, float2(0.55, 0.20), float2(0.075, 0.075)));
    return distance;
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
    return output;
}

fragment float4 scoreFragment(ScoreVertexOutput input [[stage_in]]) {
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
    } else if (kind == 4 || kind == 5) {
        float2 point = (input.local - float2(0.5)) * 2.0;
        float distance = kind == 4 ? scoreTrebleClefDistance(point) : scoreBassClefDistance(point);
        float antialias = 2.0 / max(1.0, min(input.rectSize.x, input.rectSize.y));
        alpha *= 1.0 - smoothstep(-antialias, antialias, distance);
    }
    float grain = (fract(sin(dot(input.screen, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.012;
    return float4(clamp(input.color.rgb + float3(grain), float3(0), float3(1)), alpha);
}
