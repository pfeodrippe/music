const std = @import("std");

pub const abi_version: u32 = 3;
pub const max_query_terms = 8;

pub const ComponentKey = enum(u32) {
    transport = 1,
    ui_state = 2,
    practice_state = 3,
    note = 4,
    annotation = 5,
    capture_state = 6,
    document_meta = 7,
};

pub const Access = enum(u32) { read, write, read_write, none };

pub const QueryTerm = extern struct {
    component: ComponentKey,
    access: Access,
    optional: u32 = 0,
    source: u32 = 0,
};

pub const SystemContext = extern struct {
    delta_seconds: f32,
    entity_count: u32,
    columns: [max_query_terms]?*anyopaque,
};

pub const SystemCallback = *const fn (*SystemContext) callconv(.c) void;

/// Opaque frame boundary shared by the host and the development module. The
/// module owns screen composition; the host owns durable application state and
/// the GPU resources. That lets UI code reload without recreating the world.
pub const FrameContext = extern struct {
    packet: *anyopaque,
    ui_state: *const anyopaque,
    transport: *const anyopaque,
    practice: *const anyopaque,
    document_meta: *const anyopaque,
    notes: *const anyopaque,
    note_count: u32,
    lyrics: *const anyopaque,
    lyric_count: u32,
    annotations: *const anyopaque,
    time_seconds: f32,
};

pub const DrawCallback = *const fn (*FrameContext) callconv(.c) void;

pub const SystemDescriptor = extern struct {
    stable_id: u64,
    name: [*:0]const u8,
    phase: u32,
    terms: [max_query_terms]QueryTerm,
    term_count: u32,
    callback: SystemCallback,
};

pub const PluginDescriptor = extern struct {
    abi: u32,
    generation: u32,
    systems: [*]const SystemDescriptor,
    system_count: u32,
    draw: ?DrawCallback,
};

pub fn compatible(descriptor: *const PluginDescriptor) bool {
    return descriptor.abi == abi_version and descriptor.system_count <= 1024;
}

test "hot reload ABI rejects mismatched modules" {
    const empty_systems = [_]SystemDescriptor{};
    var descriptor = PluginDescriptor{
        .abi = abi_version + 1,
        .generation = 1,
        .systems = &empty_systems,
        .system_count = 0,
        .draw = null,
    };
    try std.testing.expect(!compatible(&descriptor));
    descriptor.abi = abi_version;
    try std.testing.expect(compatible(&descriptor));
}
