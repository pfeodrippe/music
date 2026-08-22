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
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
            const continue_from_previous = (note.flags & model.note_flag_tie_stop) != 0 and hasConnectedTie(notes, note, false);
            const continue_into_next = (note.flags & model.note_flag_tie_start) != 0 and hasConnectedTie(notes, note, true);
            const required = @as(usize, @intFromBool(!continue_from_previous)) + @as(usize, @intFromBool(!continue_into_next));
            if (timeline.len + required > max_events) return error.TooManyPlaybackEvents;
            if (!continue_from_previous) {
                timeline.events[timeline.len] = .{ .beat = note.start_beat, .pitch = note.pitch, .velocity = note.velocity, .channel = note.voice, .on = 1, .stable_note_id = note.stable_id };
                timeline.len += 1;
            }
            if (!continue_into_next) {
                timeline.events[timeline.len] = .{ .beat = note.start_beat + note.duration_beats, .pitch = note.pitch, .velocity = 0, .channel = note.voice, .on = 0, .stable_note_id = note.stable_id };
                timeline.len += 1;
            }
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

pub fn hasConnectedTie(notes: []const model.Note, source: model.Note, forward: bool) bool {
    const boundary = if (forward) source.start_beat + source.duration_beats else source.start_beat;
    for (notes) |candidate| {
        if (candidate.stable_id == source.stable_id or candidate.pitch != source.pitch or candidate.staff != source.staff or candidate.voice != source.voice) continue;
        if ((candidate.flags & model.note_flag_rest) != 0) continue;
        if (forward) {
            if ((candidate.flags & model.note_flag_tie_stop) != 0 and @abs(candidate.start_beat - boundary) < 0.001) return true;
        } else if ((candidate.flags & model.note_flag_tie_start) != 0 and @abs(candidate.start_beat + candidate.duration_beats - boundary) < 0.001) {
            return true;
        }
    }
    return false;
}

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

test "rests do not enter instrument playback" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_rest },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 2), timeline.len);
}

test "connected MusicXML tie segments sustain without re-attacking" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_start },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_stop | model.note_flag_tie_start },
        .{ .stable_id = 3, .start_beat = 2, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_stop },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 2), timeline.len);
    try std.testing.expectEqual(@as(u8, 1), timeline.events[0].on);
    try std.testing.expectEqual(@as(f32, 0), timeline.events[0].beat);
    try std.testing.expectEqual(@as(u8, 0), timeline.events[1].on);
    try std.testing.expectEqual(@as(f32, 3), timeline.events[1].beat);
}

test "dangling tie marks cannot leave playback notes stuck" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_start },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 2), timeline.len);
    try std.testing.expectEqual(@as(u8, 1), timeline.events[0].on);
    try std.testing.expectEqual(@as(u8, 0), timeline.events[1].on);
}
