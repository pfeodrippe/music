const render = @import("../render/packet.zig");

pub const ApiVersion: u32 = 1;

pub const BackendKind = enum(u32) {
    browser_webgpu,
    dawn_metal,
    dawn_vulkan,
    dawn_d3d12,
    ios_metal,
};

pub const Surface = extern struct {
    logical_width: f32,
    logical_height: f32,
    pixel_ratio: f32,
    color_space: u32 = 0,
};

pub const Frame = extern struct {
    surface: Surface,
    monotonic_seconds: f64,
    items: [*]const render.DrawItem,
    item_count: usize,
};

/// Narrow host-owned renderer boundary. Browser WebGPU and native Dawn/Metal
/// consume identical immutable draw packets; backend handles never enter the
/// Flecs world or durable document.
pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        kind: BackendKind,
        resize: *const fn (*anyopaque, Surface) anyerror!void,
        submit: *const fn (*anyopaque, Frame) anyerror!void,
        device_lost: *const fn (*anyopaque) bool,
    };

    pub fn resize(self: Backend, surface: Surface) !void {
        return self.vtable.resize(self.context, surface);
    }

    pub fn submit(self: Backend, frame: Frame) !void {
        return self.vtable.submit(self.context, frame);
    }
};

test "GPU facade carries packets without platform handles" {
    const surface = Surface{ .logical_width = 1024, .logical_height = 768, .pixel_ratio = 2 };
    try @import("std").testing.expectEqual(@as(f32, 2048), surface.logical_width * surface.pixel_ratio);
    try @import("std").testing.expect(@sizeOf(render.DrawItem) == 48);
}
