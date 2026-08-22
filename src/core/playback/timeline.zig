const std = @import("std");
const model = @import("../model.zig");

pub const max_events = 8192;

pub const Event = extern struct {
    beat: f32,
    pitch: u8,
    velocity: u8,
    channel: u8,
    on: u8,
    stable_note_id: u64,
};

pub const Timeline = struct {
    events: [max_events]Event = undefined,
    len: usize = 0,

    pub fn build(notes: []const model.Note) !Timeline {
        var timeline: Timeline = .{};
        for (notes) |note| {
            if ((note.flags & model.note_flag_vocal_guide) != 0) continue;
            if (timeline.len + 2 > max_events) return error.TooManyPlaybackEvents;
            timeline.events[timeline.len] = .{ .beat = note.start_beat, .pitch = note.pitch, .velocity = note.velocity, .channel = note.voice, .on = 1, .stable_note_id = note.stable_id };
            timeline.len += 1;
            timeline.events[timeline.len] = .{ .beat = note.start_beat + note.duration_beats, .pitch = note.pitch, .velocity = 0, .channel = note.voice, .on = 0, .stable_note_id = note.stable_id };
            timeline.len += 1;
        }
        std.mem.sort(Event, timeline.events[0..timeline.len], {}, struct {
            fn lessThan(_: void, left: Event, right: Event) bool {
                if (left.beat != right.beat) return left.beat < right.beat;
                return left.on < right.on; // note-off before note-on at one tick
            }
        }.lessThan);
        return timeline;
    }
};

pub const HostEvent = extern struct {
    pitch: u8,
    velocity: u8,
    channel: u8,
    on: u8,
};

test "playback orders note-off before the next note-on" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 62, .velocity = 80, .staff = 0, .voice = 0 },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 4), timeline.len);
    try std.testing.expectEqual(@as(u8, 0), timeline.events[1].on);
    try std.testing.expectEqual(@as(u8, 1), timeline.events[2].on);
}

test "vocal guide notes do not enter instrument playback" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 72, .velocity = 80, .staff = 8, .voice = 0, .flags = model.note_flag_vocal_guide },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 2), timeline.len);
    try std.testing.expectEqual(@as(u8, 60), timeline.events[0].pitch);
}
