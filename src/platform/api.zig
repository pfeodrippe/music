pub const BackendKind = enum(u32) {
    webgpu_browser,
    dawn_metal,
    dawn_vulkan,
    dawn_d3d12,
    metal_ios,
};

pub const HostRequest = enum(u32) {
    none,
    open_score,
    choose_midi,
    choose_microphone,
    export_score,
    start_recording,
    stop_recording,
    replay_take,
};

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
