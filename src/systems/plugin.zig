const hot = @import("../hot_reload/abi.zig");
const transport = @import("transport.zig");
const practice = @import("practice.zig");
const ui = @import("../core/ui.zig");
const model = @import("../core/model.zig");
const render = @import("../render/packet.zig");
const annotation = @import("../core/annotation.zig");
const glyph_atlas = @import("../render/glyph_atlas.zig");
const std = @import("std");

const all_systems = transport.systems ++ practice.systems;

const development_plugin = hot.PluginDescriptor{
    .abi = hot.abi_version,
    // Bump whenever the reloadable systems/screen-composition module changes;
    // the host logs and validates the newly loaded descriptor without moving
    // the Flecs world or GPU resources out of the long-lived executable.
    .generation = 22,
    .glyph_atlas_hash = glyph_atlas.content_hash,
    .systems = &all_systems,
    .system_count = all_systems.len,
    .draw = drawFrame,
    .dev_command = devCommand,
};

fn drawFrame(context: *hot.FrameContext) callconv(.c) void {
    const packet: *render.Packet = @ptrCast(@alignCast(context.packet));
    const state: *const model.UiState = @ptrCast(@alignCast(context.ui_state));
    const transport_state: *const model.Transport = @ptrCast(@alignCast(context.transport));
    const practice_state: *const model.PracticeState = @ptrCast(@alignCast(context.practice));
    const meta: *const model.DocumentMeta = @ptrCast(@alignCast(context.document_meta));
    const notes: [*]const model.Note = @ptrCast(@alignCast(context.notes));
    const lyrics: [*]const model.Lyric = @ptrCast(@alignCast(context.lyrics));
    const harmonies: [*]const model.Harmony = @ptrCast(@alignCast(context.harmonies));
    const hairpins: [*]const model.Hairpin = @ptrCast(@alignCast(context.hairpins));
    const pedals: [*]const model.PedalEvent = @ptrCast(@alignCast(context.pedals));
    const measures: [*]const model.Measure = @ptrCast(@alignCast(context.measures));
    const annotations: *const annotation.Store = @ptrCast(@alignCast(context.annotations));
    ui.draw(packet, state, transport_state, practice_state, meta, notes[0..context.note_count], lyrics[0..context.lyric_count], harmonies[0..context.harmony_count], hairpins[0..context.hairpin_count], pedals[0..context.pedal_count], measures[0..context.measure_count], annotations, context.time_seconds);
}

/// This hook is compiled into the replaceable dylib. Add short-lived
/// development operations here, rebuild `zig build systems`, then invoke them
/// with `score-devctl plugin ...` without restarting the app or Flecs world.
fn devCommand(context: *hot.DevCommandContext) callconv(.c) void {
    const command = context.command[0..context.command_len];
    if (std.mem.eql(u8, command, "ping")) {
        pluginResponse(context, "ok hot-plugin generation={d}", .{development_plugin.generation});
        return;
    }
    if (std.mem.eql(u8, command, "reset-practice")) {
        const practice_state: *model.PracticeState = @ptrCast(@alignCast(context.practice));
        practice_state.* = .{};
        pluginResponse(context, "ok practice reset", .{});
        return;
    }
    if (std.mem.eql(u8, command, "library-close")) {
        const ui_state: *model.UiState = @ptrCast(@alignCast(context.ui_state));
        ui_state.library_open = 0;
        pluginResponse(context, "ok score library closed", .{});
        return;
    }
    if (std.mem.startsWith(u8, command, "transpose ")) {
        const semitones = std.fmt.parseInt(i8, std.mem.trim(u8, command[10..], " \t\r\n"), 10) catch {
            pluginResponse(context, "error transpose expects integer semitones", .{});
            return;
        };
        const notes: [*]model.Note = @ptrCast(@alignCast(context.notes));
        var changed: u32 = 0;
        for (notes[0..context.note_count]) |*note| {
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
            note.pitch = @intCast(std.math.clamp(@as(i16, note.pitch) + semitones, 0, 127));
            changed += 1;
        }
        pluginResponse(context, "ok transposed={d} semitones={d}", .{ changed, semitones });
        return;
    }
    pluginResponse(context, "error unknown plugin command", .{});
}

fn pluginResponse(context: *hot.DevCommandContext, comptime format: []const u8, arguments: anytype) void {
    const output = context.response[0..context.response_capacity];
    const value = std.fmt.bufPrint(output, format, arguments) catch return;
    context.response_len = @intCast(value.len);
}

/// Development dynamic-library entrypoint is exported by `plugin_root.zig`.
/// Release builds call this descriptor statically and contain no loader.
pub fn descriptor() *const hot.PluginDescriptor {
    return &development_plugin;
}
