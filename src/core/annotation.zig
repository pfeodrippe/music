const std = @import("std");

pub const max_points = 16_384;
pub const max_strokes = 512;

pub const Point = extern struct {
    u: f32,
    v: f32,
    pressure: f32,
    time_ms: f32,
};

pub const Stroke = extern struct {
    stable_id: u64,
    first_point: u32,
    point_count: u32,
    rgba: [4]f32,
    width: f32,
    finished: u32,
    page_index: u32,
};

pub const Store = struct {
    points: [max_points]Point = undefined,
    point_count: usize = 0,
    strokes: [max_strokes]Stroke = undefined,
    stroke_count: usize = 0,
    active: ?usize = null,
    next_id: u64 = 1,
    clipped: bool = false,

    pub fn begin(self: *Store, point: Point, page_index: u32) void {
        if (self.stroke_count == self.strokes.len or self.point_count == self.points.len) {
            self.clipped = true;
            return;
        }
        const index = self.stroke_count;
        self.strokes[index] = .{
            .stable_id = self.next_id,
            .first_point = @intCast(self.point_count),
            .point_count = 0,
            .rgba = .{ 0.96, 0.39, 0.52, 0.88 },
            .width = 4,
            .finished = 0,
            .page_index = page_index,
        };
        self.next_id += 1;
        self.stroke_count += 1;
        self.active = index;
        self.append(point);
    }

    pub fn append(self: *Store, point: Point) void {
        const active = self.active orelse return;
        if (self.point_count == self.points.len) {
            self.clipped = true;
            return;
        }
        const stroke = &self.strokes[active];
        if (stroke.point_count != 0) {
            const previous = self.points[self.point_count - 1];
            const dx = point.u - previous.u;
            const dy = point.v - previous.v;
            if (dx * dx + dy * dy < 0.000002) return;
        }
        self.points[self.point_count] = point;
        self.point_count += 1;
        stroke.point_count += 1;
    }

    pub fn end(self: *Store) void {
        if (self.active) |index| self.strokes[index].finished = 1;
        self.active = null;
    }

    pub fn undoLast(self: *Store) bool {
        if (self.stroke_count == 0) return false;
        self.stroke_count -= 1;
        self.point_count = self.strokes[self.stroke_count].first_point;
        self.active = null;
        return true;
    }
};

test "annotation strokes are stored in normalized score coordinates" {
    var store: Store = .{};
    store.begin(.{ .u = 0.1, .v = 0.2, .pressure = 0.5, .time_ms = 0 }, 2);
    store.append(.{ .u = 0.2, .v = 0.3, .pressure = 0.7, .time_ms = 12 });
    store.end();
    try std.testing.expectEqual(@as(usize, 1), store.stroke_count);
    try std.testing.expectEqual(@as(u32, 2), store.strokes[0].page_index);
    try std.testing.expectEqual(@as(u32, 2), store.strokes[0].point_count);
    try std.testing.expect(store.undoLast());
    try std.testing.expectEqual(@as(usize, 0), store.point_count);
}
