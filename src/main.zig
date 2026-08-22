const std = @import("std");
const score = @import("score");

pub fn main() !void {
    const app = try score.App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    for (0..360) |_| app.tick(1.0 / 60.0);
    const transport = app.transportSnapshot();
    std.debug.print("Score engine: {d} GPU instances, beat {d:.2}, Flecs world active\n", .{ app.drawItems().len, transport.cursor_beat });
}
