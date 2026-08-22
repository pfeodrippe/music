const model = @import("../core/model.zig");
const hot = @import("../hot_reload/abi.zig");

pub const stable_id: u64 = 0x53434f52455f0001;

const unused = hot.QueryTerm{ .component = .transport, .access = .none };
pub const systems = [_]hot.SystemDescriptor{.{
    .stable_id = stable_id,
    .name = "Score.AdvanceTransport",
    .phase = 0,
    .terms = .{
        .{ .component = .transport, .access = .read_write },
        unused,
        unused,
        unused,
        unused,
        unused,
        unused,
        unused,
    },
    .term_count = 1,
    .callback = advance,
}};

const builtin_plugin = hot.PluginDescriptor{
    .abi = hot.abi_version,
    .generation = 0,
    .systems = &systems,
    .system_count = systems.len,
};

pub fn descriptor() *const hot.PluginDescriptor {
    return &builtin_plugin;
}

fn advance(context: *hot.SystemContext) callconv(.c) void {
    const raw = context.columns[0] orelse return;
    const transports: [*]model.Transport = @ptrCast(@alignCast(raw));
    for (0..context.entity_count) |index| {
        const transport = &transports[index];
        if (transport.playing == 0) continue;
        transport.cursor_beat += context.delta_seconds * transport.tempo_bpm / 60.0;
        if (transport.loop_enabled != 0 and transport.cursor_beat >= transport.loop_end) {
            transport.cursor_beat = transport.loop_start + @mod(transport.cursor_beat - transport.loop_start, transport.loop_end - transport.loop_start);
        }
    }
}
