const std = @import("std");

pub const abi_version: u32 = 1;
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
    };
    try std.testing.expect(!compatible(&descriptor));
    descriptor.abi = abi_version;
    try std.testing.expect(compatible(&descriptor));
}
