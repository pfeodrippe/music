const std = @import("std");

/// Fixed-capacity min heap for real-time audio scheduling. Storage is embedded,
/// `push`/`pop` are O(log n), and neither operation allocates or locks.
pub fn FixedMinHeap(comptime T: type, comptime capacity: usize, comptime before: fn (T, T) bool) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        len: usize = 0,

        pub fn push(self: *Self, value: T) bool {
            if (self.len == capacity) return false;
            var index = self.len;
            self.len += 1;
            while (index != 0) {
                const parent = (index - 1) / 2;
                if (!before(value, self.items[parent])) break;
                self.items[index] = self.items[parent];
                index = parent;
            }
            self.items[index] = value;
            return true;
        }

        pub fn peek(self: *const Self) ?T {
            return if (self.len == 0) null else self.items[0];
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const result = self.items[0];
            self.len -= 1;
            if (self.len == 0) return result;

            const replacement = self.items[self.len];
            var index: usize = 0;
            while (true) {
                const left = index * 2 + 1;
                if (left >= self.len) break;
                const right = left + 1;
                const child = if (right < self.len and before(self.items[right], self.items[left])) right else left;
                if (!before(self.items[child], replacement)) break;
                self.items[index] = self.items[child];
                index = child;
            }
            self.items[index] = replacement;
            return result;
        }
    };
}

/// Converts a wall-time offset to the score engine's absolute audio-frame
/// domain without wrapping on malformed or extreme input.
pub fn dueFrame(rendered_frames: u64, delay_seconds: f32, sample_rate: f32) u64 {
    if (!std.math.isFinite(delay_seconds) or delay_seconds <= 0 or !std.math.isFinite(sample_rate) or sample_rate <= 0) return rendered_frames;
    const frames_f64 = @as(f64, delay_seconds) * @as(f64, sample_rate);
    const delay_frames: u64 = if (frames_f64 >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
        std.math.maxInt(u64)
    else
        @intFromFloat(@max(0, @round(frames_f64)));
    return rendered_frames +| delay_frames;
}

/// Returns an intra-block offset for an event due in this render block.
/// `null` means the event belongs to a later block; a past event is clamped to
/// frame zero and reported separately by the caller's telemetry.
pub fn blockOffset(due_frame: u64, block_start: u64, frame_count: usize) ?u32 {
    const block_end = block_start +| frame_count;
    if (due_frame >= block_end) return null;
    if (due_frame <= block_start) return 0;
    return @intCast(due_frame - block_start);
}

const TestEvent = struct {
    due: u64,
    sequence: u64,
};

fn testBefore(a: TestEvent, b: TestEvent) bool {
    return a.due < b.due or (a.due == b.due and a.sequence < b.sequence);
}

test "fixed audio heap orders frames and preserves equal-frame sequence" {
    var heap: FixedMinHeap(TestEvent, 5, testBefore) = .{};
    try std.testing.expect(heap.push(.{ .due = 20, .sequence = 2 }));
    try std.testing.expect(heap.push(.{ .due = 10, .sequence = 3 }));
    try std.testing.expect(heap.push(.{ .due = 20, .sequence = 1 }));
    try std.testing.expectEqual(@as(u64, 10), heap.pop().?.due);
    try std.testing.expectEqual(@as(u64, 1), heap.pop().?.sequence);
    try std.testing.expectEqual(@as(u64, 2), heap.pop().?.sequence);
    try std.testing.expect(heap.pop() == null);
}

test "audio frame conversion clamps past events and defers future blocks" {
    try std.testing.expectEqual(@as(u64, 49_440), dueFrame(48_000, 0.03, 48_000));
    try std.testing.expectEqual(@as(?u32, 0), blockOffset(99, 100, 256));
    try std.testing.expectEqual(@as(?u32, 55), blockOffset(155, 100, 256));
    try std.testing.expectEqual(@as(?u32, null), blockOffset(356, 100, 256));
}
