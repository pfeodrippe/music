struct Globals {
    viewport: vec2f,
    time: f32,
    pixel_ratio: f32,
}

struct Item {
    rect: vec4f,
    color: vec4f,
    params: vec4f,
}

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) color: vec4f,
    @location(2) @interpolate(flat) params: vec4f,
    @location(3) screen: vec2f,
    @location(4) @interpolate(flat) rect_size: vec2f,
}

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var<storage, read> items: array<Item>;

fn sd_segment(point: vec2f, start: vec2f, end: vec2f) -> f32 {
    let from_start = point - start;
    let segment = end - start;
    let along = clamp(dot(from_start, segment) / dot(segment, segment), 0.0, 1.0);
    return length(from_start - segment * along);
}

fn ellipse_ring(point: vec2f, center: vec2f, scale: vec2f, width: f32) -> f32 {
    return abs(length((point - center) / scale) - 1.0) * min(scale.x, scale.y) - width;
}

fn filled_ellipse(point: vec2f, center: vec2f, scale: vec2f) -> f32 {
    return (length((point - center) / scale) - 1.0) * min(scale.x, scale.y);
}

fn treble_clef_distance(point: vec2f) -> f32 {
    var distance = sd_segment(point, vec2f(0.12, -0.88), vec2f(0.12, 0.80)) - 0.052;
    distance = min(distance, ellipse_ring(point, vec2f(0.11, -0.59), vec2f(0.34, 0.32), 0.055));
    distance = min(distance, ellipse_ring(point, vec2f(-0.04, 0.13), vec2f(0.62, 0.34), 0.070));
    distance = min(distance, sd_segment(point, vec2f(0.09, -0.30), vec2f(-0.38, -0.02)) - 0.063);
    distance = min(distance, sd_segment(point, vec2f(-0.38, -0.02), vec2f(-0.42, 0.22)) - 0.063);
    distance = min(distance, sd_segment(point, vec2f(-0.42, 0.22), vec2f(-0.08, 0.39)) - 0.063);
    distance = min(distance, sd_segment(point, vec2f(-0.08, 0.39), vec2f(0.42, 0.34)) - 0.063);
    distance = min(distance, ellipse_ring(point, vec2f(0.08, 0.72), vec2f(0.34, 0.15), 0.052));
    return distance;
}

fn bass_clef_distance(point: vec2f) -> f32 {
    var distance = ellipse_ring(point, vec2f(-0.18, -0.18), vec2f(0.49, 0.39), 0.085);
    distance = min(distance, filled_ellipse(point, vec2f(-0.47, -0.19), vec2f(0.14, 0.14)));
    distance = min(distance, sd_segment(point, vec2f(0.12, -0.01), vec2f(-0.01, 0.35)) - 0.075);
    distance = min(distance, sd_segment(point, vec2f(-0.01, 0.35), vec2f(-0.31, 0.65)) - 0.068);
    distance = min(distance, filled_ellipse(point, vec2f(0.55, -0.20), vec2f(0.075, 0.075)));
    distance = min(distance, filled_ellipse(point, vec2f(0.55, 0.20), vec2f(0.075, 0.075)));
    return distance;
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
    } else if (kind == 4u || kind == 5u) {
        let point = (input.local - vec2f(0.5)) * 2.0;
        let distance = select(bass_clef_distance(point), treble_clef_distance(point), kind == 4u);
        let antialias = 2.0 / max(1.0, min(input.rect_size.x, input.rect_size.y));
        alpha *= 1.0 - smoothstep(-antialias, antialias, distance);
    }
    let grain = (fract(sin(dot(input.screen, vec2f(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.012;
    return vec4f(clamp(input.color.rgb + vec3f(grain), vec3f(0.0), vec3f(1.0)), alpha);
}
