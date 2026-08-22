const hot = @import("../hot_reload/abi.zig");
const transport = @import("transport.zig");
const practice = @import("practice.zig");
const ui = @import("../core/ui.zig");
const model = @import("../core/model.zig");
const render = @import("../render/packet.zig");
const annotation = @import("../core/annotation.zig");

const all_systems = transport.systems ++ practice.systems;

const development_plugin = hot.PluginDescriptor{
    .abi = hot.abi_version,
    .generation = 1,
    .systems = &all_systems,
    .system_count = all_systems.len,
    .draw = drawFrame,
};

fn drawFrame(context: *hot.FrameContext) callconv(.c) void {
    const packet: *render.Packet = @ptrCast(@alignCast(context.packet));
    const state: *const model.UiState = @ptrCast(@alignCast(context.ui_state));
    const transport_state: *const model.Transport = @ptrCast(@alignCast(context.transport));
    const practice_state: *const model.PracticeState = @ptrCast(@alignCast(context.practice));
    const meta: *const model.DocumentMeta = @ptrCast(@alignCast(context.document_meta));
    const notes: [*]const model.Note = @ptrCast(@alignCast(context.notes));
    const lyrics: [*]const model.Lyric = @ptrCast(@alignCast(context.lyrics));
    const annotations: *const annotation.Store = @ptrCast(@alignCast(context.annotations));
    ui.draw(packet, state, transport_state, practice_state, meta, notes[0..context.note_count], lyrics[0..context.lyric_count], annotations, context.time_seconds);
}

/// Development dynamic-library entrypoint is exported by `plugin_root.zig`.
/// Release builds call this descriptor statically and contain no loader.
pub fn descriptor() *const hot.PluginDescriptor {
    return &development_plugin;
}
