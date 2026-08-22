struct Globals {
    viewport: vec2f,
    time: f32,
    pixel_ratio: f32,
}

struct Item {
    rect: vec4f,
    color: vec4f,
    params: vec4f,
    uv: vec4f,
}

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) color: vec4f,
    @location(2) @interpolate(flat) params: vec4f,
    @location(3) screen: vec2f,
    @location(4) @interpolate(flat) rect_size: vec2f,
    @location(5) atlas_uv: vec2f,
    @location(6) @interpolate(flat) atlas_rect: vec4f,
}

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var<storage, read> items: array<Item>;
@group(0) @binding(2) var glyph_atlas: texture_2d<f32>;
@group(0) @binding(3) var glyph_sampler: sampler;

fn sd_segment(point: vec2f, start: vec2f, end: vec2f) -> f32 {
    let from_start = point - start;
    let segment = end - start;
    let along = clamp(dot(from_start, segment) / dot(segment, segment), 0.0, 1.0);
    return length(from_start - segment * along);
}

fn median(value: vec3f) -> f32 {
    return max(min(value.r, value.g), min(max(value.r, value.g), value.b));
}

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @builtin(instance_index) instance_index: u32) -> VertexOutput {
    let corners = array<vec2f, 6>(
        vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
        vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0)
    );
    let item = items[instance_index];
    let local = corners[vertex_index];
    let pixel = item.rect.xy + local * item.rect.zw;
    let ndc = vec2f(
        pixel.x / globals.viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / globals.viewport.y * 2.0
    );
    var output: VertexOutput;
    output.position = vec4f(ndc, 0.0, 1.0);
    output.local = local;
    output.color = item.color;
    output.params = item.params;
    output.screen = pixel;
    output.rect_size = item.rect.zw;
    output.atlas_uv = mix(item.uv.xy, item.uv.zw, local);
    output.atlas_rect = item.uv;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
    let kind = u32(input.params.x + 0.5);
    var alpha = input.color.a;
    if (kind == 1u) {
        let radius = min(input.params.y, min(input.rect_size.x, input.rect_size.y) * 0.5);
        let centered = (input.local - vec2f(0.5)) * input.rect_size;
        let inset = input.rect_size * 0.5 - vec2f(radius);
        let q = abs(centered) - inset;
        let rounded = length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        alpha *= 1.0 - smoothstep(-0.85, 0.85, rounded);
    } else if (kind == 2u) {
        let distance = length((input.local - vec2f(0.5)) * 2.0);
        alpha *= 1.0 - smoothstep(0.88, 1.0, distance);
    } else if (kind == 3u) {
        let distance = length((input.local - vec2f(0.5)) * 2.0);
        let breathing = 0.86 + 0.14 * sin(globals.time * 3.2 + input.params.z);
        alpha *= (1.0 - smoothstep(0.15, 1.0, distance)) * breathing;
    } else if (kind == 4u) {
        let sample = textureSampleLevel(glyph_atlas, glyph_sampler, input.atlas_uv, 0.0);
        let atlas_dimensions = vec2f(textureDimensions(glyph_atlas));
        let atlas_pixels = max((input.atlas_rect.zw - input.atlas_rect.xy) * atlas_dimensions, vec2f(1.0));
        let screen_scale = max(0.001, min(input.rect_size.x / atlas_pixels.x, input.rect_size.y / atlas_pixels.y));
        let screen_distance = (median(sample.rgb) - 0.5) * input.params.y * screen_scale;
        alpha *= clamp(screen_distance + 0.5, 0.0, 1.0);
    }
    let grain = (fract(sin(dot(input.screen, vec2f(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.012;
    return vec4f(clamp(input.color.rgb + vec3f(grain), vec3f(0.0), vec3f(1.0)), alpha);
}
