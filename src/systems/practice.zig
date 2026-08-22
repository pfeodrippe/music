const model = @import("../core/model.zig");
const hot = @import("../hot_reload/abi.zig");

pub const stable_id: u64 = 0x53434f52455f0002;

const unused = hot.QueryTerm{ .component = .practice_state, .access = .none };
pub const systems = [_]hot.SystemDescriptor{.{
    .stable_id = stable_id,
    .name = "Score.DecayPracticeConfidence",
    .phase = 0,
    .terms = .{
        .{ .component = .practice_state, .access = .read_write },
        .{ .component = .transport, .access = .read },
        unused,
        unused,
        unused,
        unused,
        unused,
        unused,
    },
    .term_count = 2,
    .callback = decayConfidence,
}};

fn decayConfidence(context: *hot.SystemContext) callconv(.c) void {
    const practice_raw = context.columns[0] orelse return;
    const transport_raw = context.columns[1] orelse return;
    const practices: [*]model.PracticeState = @ptrCast(@alignCast(practice_raw));
    const transports: [*]const model.Transport = @ptrCast(@alignCast(transport_raw));
    for (0..context.entity_count) |index| {
        if (transports[index].playing == 0 and transports[index].recording == 0) {
            practices[index].confidence = @max(0, practices[index].confidence - context.delta_seconds * 0.12);
        }
    }
}
