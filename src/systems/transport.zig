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
        .{ .component = .playback_bounds, .access = .read },
        unused,
        unused,
        unused,
        unused,
        unused,
        unused,
    },
    .term_count = 2,
    .callback = advance,
}};

const builtin_plugin = hot.PluginDescriptor{
    .abi = hot.abi_version,
    .generation = 0,
    .systems = &systems,
    .system_count = systems.len,
    .draw = null,
    .dev_command = null,
};

pub fn descriptor() *const hot.PluginDescriptor {
    return &builtin_plugin;
}

fn advance(context: *hot.SystemContext) callconv(.c) void {
    const transport_raw = context.columns[0] orelse return;
    const bounds_raw = context.columns[1] orelse return;
    const transports: [*]model.Transport = @ptrCast(@alignCast(transport_raw));
    const bounds: [*]const model.PlaybackBounds = @ptrCast(@alignCast(bounds_raw));
    for (0..context.entity_count) |index| {
        const transport = &transports[index];
        if (transport.playing == 0) continue;
        var remaining_seconds = @max(0, context.delta_seconds);
        // Consume the host frame in authored-tempo slices. This is exact at a
        // tempo boundary even when a large debug frame crosses several events.
        while (remaining_seconds > 0.000001) {
            const effective_bpm = model.effectiveTempoAt(&bounds[index], transport, transport.cursor_beat);
            var next_beat = bounds[index].end_beat;
            const tempo_count = @min(@as(usize, bounds[index].tempo_count), bounds[index].tempos.len);
            for (bounds[index].tempos[0..tempo_count]) |event| {
                if (event.start_beat > transport.cursor_beat + 0.0001) {
                    next_beat = @min(next_beat, event.start_beat);
                    break;
                }
            }
            const beats_available = @max(0, next_beat - transport.cursor_beat);
            const seconds_available = beats_available * 60.0 / effective_bpm;
            if (seconds_available <= 0.000001 or remaining_seconds < seconds_available) {
                transport.cursor_beat += remaining_seconds * effective_bpm / 60.0;
                remaining_seconds = 0;
            } else {
                transport.cursor_beat = next_beat;
                remaining_seconds -= seconds_available;
            }
        }
        if (transport.loop_enabled != 0 and transport.cursor_beat >= transport.loop_end) {
            transport.cursor_beat = transport.loop_start + @mod(transport.cursor_beat - transport.loop_start, transport.loop_end - transport.loop_start);
        } else if (transport.loop_enabled == 0 and transport.cursor_beat >= bounds[index].end_beat) {
            transport.cursor_beat = bounds[index].end_beat;
            transport.playing = 0;
        }
    }
}
