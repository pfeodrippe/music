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
        try buildInto(&timeline, notes);
        return timeline;
    }

    /// Builds directly into caller-owned storage. Native and iOS keep this
    /// large fixed-capacity timeline in the heap-resident App so importing a
    /// full score never materializes it on the platform UI thread's stack.
    pub fn buildInto(timeline: *Timeline, notes: []const model.Note) !void {
        timeline.len = 0;
        for (notes) |note| {
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
            const performed = model.performedNoteRange(notes, note);
            const tremolo_marks = model.singleTremoloMarks(note);
            if (tremolo_marks != 0) {
                const interval = model.singleTremoloInterval(note);
                const attack_count = model.singleTremoloAttackCount(note, performed.end - performed.start);
                if (timeline.len + attack_count * 2 > max_events) return error.TooManyPlaybackEvents;
                for (0..attack_count) |attack_index| {
                    const attack_start = performed.start + @as(f32, @floatFromInt(attack_index)) * interval;
                    if (attack_start >= performed.end - 0.0001) break;
                    const attack_end = @min(performed.end, attack_start + interval * 0.86);
                    timeline.events[timeline.len] = .{ .beat = attack_start, .pitch = note.pitch, .velocity = note.velocity, .channel = note.voice, .on = 1, .stable_note_id = note.stable_id };
                    timeline.events[timeline.len + 1] = .{ .beat = @max(attack_start + 0.005, attack_end), .pitch = note.pitch, .velocity = 0, .channel = note.voice, .on = 0, .stable_note_id = note.stable_id };
                    timeline.len += 2;
                }
                continue;
            }
            const continue_from_previous = (note.flags & model.note_flag_tie_stop) != 0 and hasConnectedTie(notes, note, false);
            const continue_into_next = (note.flags & model.note_flag_tie_start) != 0 and hasConnectedTie(notes, note, true);
            const required = @as(usize, @intFromBool(!continue_from_previous)) + @as(usize, @intFromBool(!continue_into_next));
            if (timeline.len + required > max_events) return error.TooManyPlaybackEvents;
            if (!continue_from_previous) {
                timeline.events[timeline.len] = .{ .beat = performed.start, .pitch = note.pitch, .velocity = note.velocity, .channel = note.voice, .on = 1, .stable_note_id = note.stable_id };
                timeline.len += 1;
            }
            if (!continue_into_next) {
                timeline.events[timeline.len] = .{ .beat = performed.end, .pitch = note.pitch, .velocity = 0, .channel = note.voice, .on = 0, .stable_note_id = note.stable_id };
                timeline.len += 1;
            }
        }
        std.mem.sort(Event, timeline.events[0..timeline.len], {}, struct {
            fn lessThan(_: void, left: Event, right: Event) bool {
                if (left.beat != right.beat) return left.beat < right.beat;
                return left.on < right.on; // note-off before note-on at one tick
            }
        }.lessThan);
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

/// Native hosts use the scheduling metadata; portable ABI drains intentionally
/// expose only `HostEvent`, keeping the current Wasm/iOS four-byte event ABI.
pub const ScheduledHostEvent = struct {
    event: HostEvent,
    delay_seconds: f32 = 0,
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

test "native timeline performs an appoggiatura instead of a chord" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.125, .pitch = 62, .velocity = 72, .staff = 0, .voice = 0, .flags = model.note_flag_grace, .notations = model.withGraceTiming(0, false, 25, 0, false) },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 84, .staff = 0, .voice = 0 },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 4), timeline.len);
    try std.testing.expectEqual(@as(u8, 62), timeline.events[0].pitch);
    try std.testing.expectEqual(@as(u8, 1), timeline.events[0].on);
    try std.testing.expectApproxEqAbs(@as(f32, 0), timeline.events[0].beat, 0.0001);
    try std.testing.expectEqual(@as(u8, 62), timeline.events[1].pitch);
    try std.testing.expectEqual(@as(u8, 0), timeline.events[1].on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), timeline.events[1].beat, 0.0001);
    try std.testing.expectEqual(@as(u8, 64), timeline.events[2].pitch);
    try std.testing.expectEqual(@as(u8, 1), timeline.events[2].on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), timeline.events[2].beat, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), timeline.events[3].beat, 0.0001);
}

test "native timeline performs a three-mark single-note tremolo as 32nd attacks" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 86, .staff = 0, .voice = 0, .notations = model.withSingleTremolo(0, 3) },
    };
    const timeline = try Timeline.build(&notes);
    try std.testing.expectEqual(@as(usize, 16), timeline.len);
    for (0..8) |index| {
        const attack = timeline.events[index * 2];
        const release = timeline.events[index * 2 + 1];
        try std.testing.expectEqual(@as(u8, 1), attack.on);
        try std.testing.expectEqual(@as(u8, 0), release.on);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(index)) * 0.125, attack.beat, 0.0001);
        try std.testing.expect(release.beat > attack.beat);
        try std.testing.expect(release.beat < attack.beat + 0.125);
    }
}
