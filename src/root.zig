pub const App = @import("core/app.zig").App;
pub const model = @import("core/model.zig");
pub const practice = @import("core/practice.zig");
pub const recording = @import("core/recording.zig");
pub const render = @import("render/packet.zig");
pub const platform = @import("platform/api.zig");
pub const gpu = @import("platform/gpu.zig");
pub const hot_reload = @import("hot_reload/abi.zig");
pub const musicxml = @import("core/import/musicxml.zig");
pub const midi = @import("core/import/midi.zig");
pub const mxl = @import("core/import/mxl.zig");
pub const playback = @import("core/playback/timeline.zig");
pub const command = @import("core/command.zig");
pub const annotation = @import("core/annotation.zig");
pub const accessibility = @import("core/accessibility.zig");
pub const native_format = @import("core/persistence/native.zig");
pub const synth = @import("audio/synth.zig");
pub const pitch = @import("audio/pitch.zig");

test {
    _ = @import("core/app.zig");
    _ = @import("core/model.zig");
    _ = @import("core/practice.zig");
    _ = @import("core/recording.zig");
    _ = @import("render/packet.zig");
    _ = @import("platform/gpu.zig");
    _ = @import("hot_reload/abi.zig");
    _ = @import("core/import/musicxml.zig");
    _ = @import("core/import/midi.zig");
    _ = @import("core/import/mxl.zig");
    _ = @import("core/playback/timeline.zig");
    _ = @import("core/command.zig");
    _ = @import("core/annotation.zig");
    _ = @import("core/accessibility.zig");
    _ = @import("core/persistence/native.zig");
    _ = @import("audio/synth.zig");
    _ = @import("audio/pitch.zig");
}
