pub const BackendKind = enum(u32) {
    webgpu_browser,
    dawn_metal,
    dawn_vulkan,
    dawn_d3d12,
    metal_ios,
};

pub const HostRequest = enum(u32) {
    none = 0,
    open_score = 1,
    choose_midi = 2,
    choose_microphone = 3,
    export_score = 4,
    export_take = 5,
    start_recording = 6,
    stop_recording = 7,
    replay_take = 8,
    open_instrument = 9,
};

test "portable host request ABI stays stable" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 5), @intFromEnum(HostRequest.export_take));
    try testing.expectEqual(@as(u32, 6), @intFromEnum(HostRequest.start_recording));
    try testing.expectEqual(@as(u32, 9), @intFromEnum(HostRequest.open_instrument));
}

pub const PointerKind = enum(u32) { move, down, up, cancel, scroll };
pub const PointerType = enum(u32) { mouse, pen, touch };

pub const PointerEvent = extern struct {
    kind: PointerKind,
    pointer_type: PointerType,
    id: u32,
    buttons: u32,
    x: f32,
    y: f32,
    pressure: f32,
    tilt_x: f32,
    tilt_y: f32,
    scroll_x: f32,
    scroll_y: f32,
};

pub const KeyEvent = extern struct {
    key: u32,
    scancode: u32,
    modifiers: u32,
    pressed: u32,
    repeat: u32,
};

pub const HostCapabilities = extern struct {
    backend: BackendKind,
    has_midi: u32,
    has_microphone: u32,
    has_audio_output: u32,
    has_pen: u32,
    persistent_storage: u32,
};

pub const AudioIo = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin_capture: *const fn (*anyopaque) anyerror!void,
        end_capture: *const fn (*anyopaque) anyerror!void,
        schedule_midi: *const fn (*anyopaque, u64, u8, u8, u8) void,
    };
};

pub const Storage = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, []const u8, []u8) anyerror!usize,
        atomic_store: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    };
};
