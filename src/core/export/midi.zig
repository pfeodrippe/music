const std = @import("std");
const model = @import("../model.zig");
const musicxml = @import("../import/musicxml.zig");
const timeline = @import("../playback/timeline.zig");
const recording = @import("../recording.zig");

pub const ticks_per_quarter: u16 = 480;

pub const Error = error{
    OutputTooSmall,
    TooManyEvents,
    InvalidTempo,
    InvalidTime,
    InvalidMeter,
    InvalidMidiEvent,
};

const max_note_events = musicxml.max_import_notes * 2;
const max_piano_events = max_note_events + musicxml.max_import_pedals;

const Event = struct {
    tick: u32,
    sequence: u32,
    priority: u8,
    status: u8,
    data1: u8,
    data2: u8,
    data_len: u8 = 2,
};

const Writer = struct {
    output: []u8,
    position: usize = 0,

    fn bytes(self: *Writer, value: []const u8) Error!void {
        if (self.position + value.len > self.output.len) return error.OutputTooSmall;
        @memcpy(self.output[self.position .. self.position + value.len], value);
        self.position += value.len;
    }

    fn byte(self: *Writer, value: u8) Error!void {
        if (self.position == self.output.len) return error.OutputTooSmall;
        self.output[self.position] = value;
        self.position += 1;
    }

    fn u16be(self: *Writer, value: u16) Error!void {
        try self.byte(@truncate(value >> 8));
        try self.byte(@truncate(value));
    }

    fn u32be(self: *Writer, value: u32) Error!void {
        try self.byte(@truncate(value >> 24));
        try self.byte(@truncate(value >> 16));
        try self.byte(@truncate(value >> 8));
        try self.byte(@truncate(value));
    }

    fn patchU32be(self: *Writer, offset: usize, value: u32) void {
        self.output[offset] = @truncate(value >> 24);
        self.output[offset + 1] = @truncate(value >> 16);
        self.output[offset + 2] = @truncate(value >> 8);
        self.output[offset + 3] = @truncate(value);
    }

    fn variable(self: *Writer, value: u32) Error!void {
        if (value > 0x0fff_ffff) return error.InvalidTime;
        var encoded: [4]u8 = undefined;
        var remaining = value;
        var start: usize = encoded.len - 1;
        encoded[start] = @truncate(remaining & 0x7f);
        remaining >>= 7;
        while (remaining != 0) {
            if (start == 0) return error.InvalidTime;
            start -= 1;
            encoded[start] = @as(u8, @truncate(remaining & 0x7f)) | 0x80;
            remaining >>= 7;
        }
        try self.bytes(encoded[start..]);
    }
};

pub fn write(output: []u8, meta: *const model.DocumentMeta, tempo_bpm: f32, playback: *const model.PlaybackBounds, notes: []const model.Note, pedals: []const model.PedalEvent) Error!usize {
    if (!std.math.isFinite(tempo_bpm) or tempo_bpm <= 0) return error.InvalidTempo;

    var piano_events: [max_piano_events]Event = undefined;
    var piano_count: usize = 0;
    var vocal_events: [max_note_events]Event = undefined;
    var vocal_count: usize = 0;
    var sequence: u32 = 0;

    for (notes) |note| {
        if ((note.flags & model.note_flag_rest) != 0) continue;
        const connected_from_previous = (note.flags & model.note_flag_tie_stop) != 0 and timeline.hasConnectedTie(notes, note, false);
        const connected_into_next = (note.flags & model.note_flag_tie_start) != 0 and timeline.hasConnectedTie(notes, note, true);
        const vocal = (note.flags & model.note_flag_vocal_guide) != 0;
        const channel: u8 = if (vocal) 1 else if ((note.voice & 0x0f) == 9) 0 else note.voice & 0x0f;
        const start = try beatTick(note.start_beat);
        const end = @max(start +| 1, try beatTick(note.start_beat + note.duration_beats));
        if (!connected_from_previous) {
            const event: Event = .{ .tick = start, .sequence = sequence, .priority = 2, .status = 0x90 | channel, .data1 = note.pitch, .data2 = @max(1, @min(note.velocity, 127)) };
            sequence +%= 1;
            if (vocal) try appendEvent(&vocal_events, &vocal_count, event) else try appendEvent(&piano_events, &piano_count, event);
        }
        if (!connected_into_next) {
            const event: Event = .{ .tick = end, .sequence = sequence, .priority = 1, .status = 0x80 | channel, .data1 = note.pitch, .data2 = 0 };
            sequence +%= 1;
            if (vocal) try appendEvent(&vocal_events, &vocal_count, event) else try appendEvent(&piano_events, &piano_count, event);
        }
    }

    for (pedals) |pedal| {
        const controller: u8 = switch (pedal.pedal) {
            model.pedal_sostenuto => 66,
            model.pedal_soft => 67,
            else => 64,
        };
        try appendEvent(&piano_events, &piano_count, .{
            .tick = try beatTick(pedal.start_beat),
            .sequence = sequence,
            .priority = 0,
            .status = 0xb0,
            .data1 = controller,
            .data2 = @min(pedal.value, 127),
        });
        sequence +%= 1;
    }

    sortEvents(piano_events[0..piano_count]);
    sortEvents(vocal_events[0..vocal_count]);

    var writer: Writer = .{ .output = output };
    try writer.bytes("MThd");
    try writer.u32be(6);
    try writer.u16be(1);
    try writer.u16be(if (vocal_count == 0) 2 else 3);
    try writer.u16be(ticks_per_quarter);
    try writeConductorTrack(&writer, meta, tempo_bpm, meta.tempo_beat_unit, playback);
    try writeEventTrack(&writer, "Piano", 0, 0, piano_events[0..piano_count]);
    if (vocal_count != 0) try writeEventTrack(&writer, "Vocal Guide", 1, 53, vocal_events[0..vocal_count]);
    return writer.position;
}

/// Writes the raw, timestamped controller/keyboard performance captured during
/// a take. Unlike score export, this intentionally preserves human timing and
/// does not quantize events to notation positions.
pub fn writeTake(output: []u8, meta: *const model.DocumentMeta, take: *const recording.Take) Error!usize {
    if (take.midi_len > take.midi.len) return error.TooManyEvents;
    if (!std.math.isFinite(take.tempo_bpm) or take.tempo_bpm <= 0) return error.InvalidTempo;

    var events: [recording.max_midi_events]Event = undefined;
    var event_count: usize = 0;
    var base_ns: u64 = std.math.maxInt(u64);
    for (take.midi[0..take.midi_len]) |captured| base_ns = @min(base_ns, captured.time_ns);
    if (take.midi_len == 0) base_ns = 0;

    for (take.midi[0..take.midi_len]) |captured| {
        const data_len: u8 = switch (captured.kind) {
            0x80, 0x90, 0xa0, 0xb0, 0xe0 => 2,
            0xc0, 0xd0 => 1,
            else => return error.InvalidMidiEvent,
        };
        if (captured.channel >= 16 or captured.data1 >= 128 or (data_len == 2 and captured.data2 >= 128)) return error.InvalidMidiEvent;
        try appendEvent(&events, &event_count, .{
            .tick = try nanosecondsTick(captured.time_ns -| base_ns, take.tempo_bpm),
            .sequence = captured.sequence,
            .priority = 0,
            .status = captured.kind | captured.channel,
            .data1 = captured.data1,
            .data2 = captured.data2,
            .data_len = data_len,
        });
    }
    sortEvents(events[0..event_count]);

    var writer: Writer = .{ .output = output };
    try writer.bytes("MThd");
    try writer.u32be(6);
    try writer.u16be(1);
    try writer.u16be(2);
    try writer.u16be(ticks_per_quarter);
    // Recorded take tempo is already stored in canonical quarter-note units.
    try writeConductorTrack(&writer, meta, take.tempo_bpm, 4, null);
    try writeEventTrack(&writer, "Recorded MIDI Take", 0, 0, events[0..event_count]);
    return writer.position;
}

fn appendEvent(events: []Event, count: *usize, event: Event) Error!void {
    if (count.* == events.len) return error.TooManyEvents;
    events[count.*] = event;
    count.* += 1;
}

fn sortEvents(events: []Event) void {
    std.mem.sort(Event, events, {}, struct {
        fn lessThan(_: void, left: Event, right: Event) bool {
            if (left.tick != right.tick) return left.tick < right.tick;
            if (left.priority != right.priority) return left.priority < right.priority;
            return left.sequence < right.sequence;
        }
    }.lessThan);
}

fn beatTick(beat: f32) Error!u32 {
    if (!std.math.isFinite(beat) or beat < 0) return error.InvalidTime;
    const scaled = @as(f64, beat) * @as(f64, ticks_per_quarter);
    if (scaled > 0x0fff_ffff) return error.InvalidTime;
    return @intFromFloat(@round(scaled));
}

fn nanosecondsTick(delta_ns: u64, tempo_bpm: f32) Error!u32 {
    const beats = @as(f64, @floatFromInt(delta_ns)) * @as(f64, tempo_bpm) / (60.0 * @as(f64, std.time.ns_per_s));
    const scaled = beats * @as(f64, ticks_per_quarter);
    if (!std.math.isFinite(scaled) or scaled > 0x0fff_ffff) return error.InvalidTime;
    return @intFromFloat(@round(scaled));
}

fn beginTrack(writer: *Writer) Error!struct { length_offset: usize, data_start: usize } {
    try writer.bytes("MTrk");
    const length_offset = writer.position;
    try writer.u32be(0);
    return .{ .length_offset = length_offset, .data_start = writer.position };
}

fn endTrack(writer: *Writer, length_offset: usize, data_start: usize) Error!void {
    try writer.bytes(&.{ 0, 0xff, 0x2f, 0 });
    const length = writer.position - data_start;
    if (length > std.math.maxInt(u32)) return error.OutputTooSmall;
    writer.patchU32be(length_offset, @intCast(length));
}

fn writeMetaText(writer: *Writer, kind: u8, value: []const u8) Error!void {
    try writer.bytes(&.{ 0, 0xff, kind });
    if (value.len > 0x0fff_ffff) return error.OutputTooSmall;
    try writer.variable(@intCast(value.len));
    try writer.bytes(value);
}

fn writeConductorTrack(writer: *Writer, meta: *const model.DocumentMeta, tempo_bpm: f32, tempo_beat_unit: u8, playback: ?*const model.PlaybackBounds) Error!void {
    const track = try beginTrack(writer);
    try writeMetaText(writer, 0x03, meta.titleSlice());

    const editable_quarter = model.quarterTempoFromPulse(tempo_bpm, tempo_beat_unit);
    var initial_bpm = editable_quarter;
    if (playback) |map| {
        const count = @min(@as(usize, map.tempo_count), map.tempos.len);
        const scale = editable_quarter / @max(1, map.tempo_base_bpm);
        for (map.tempos[0..count]) |tempo| {
            if (tempo.start_beat > 0.0001) break;
            initial_bpm = tempo.bpm * scale;
        }
    }
    try writeTempoMeta(writer, 0, initial_bpm);

    const denominator_power = try meterPower(meta.beat_unit);
    try writer.bytes(&.{ 0, 0xff, 0x58, 4, @max(1, meta.beats_per_measure), denominator_power, 24, 8 });
    const key: i8 = std.math.clamp(meta.key_fifths, -7, 7);
    try writer.bytes(&.{ 0, 0xff, 0x59, 2, @bitCast(key), 0 });
    var previous_tick: u32 = 0;
    if (playback) |map| {
        const count = @min(@as(usize, map.tempo_count), map.tempos.len);
        const scale = editable_quarter / @max(1, map.tempo_base_bpm);
        for (map.tempos[0..count]) |tempo| {
            const tick = try beatTick(@max(0, tempo.start_beat));
            if (tick == 0) continue;
            try writeTempoMeta(writer, tick - previous_tick, tempo.bpm * scale);
            previous_tick = tick;
        }
    }
    try endTrack(writer, track.length_offset, track.data_start);
}

fn writeTempoMeta(writer: *Writer, delta: u32, bpm: f32) Error!void {
    if (!std.math.isFinite(bpm) or bpm <= 0) return error.InvalidTempo;
    const micros_float = 60_000_000.0 / @as(f64, bpm);
    if (micros_float < 1 or micros_float > 0x00ff_ffff) return error.InvalidTempo;
    const micros: u32 = @intFromFloat(@round(micros_float));
    try writer.variable(delta);
    try writer.bytes(&.{ 0xff, 0x51, 3, @truncate(micros >> 16), @truncate(micros >> 8), @truncate(micros) });
}

fn meterPower(denominator: u8) Error!u8 {
    if (denominator == 0 or (denominator & (denominator - 1)) != 0) return error.InvalidMeter;
    var value = denominator;
    var power: u8 = 0;
    while (value > 1) : (value >>= 1) power += 1;
    return power;
}

fn writeEventTrack(writer: *Writer, name: []const u8, channel: u8, program: u8, events: []const Event) Error!void {
    const track = try beginTrack(writer);
    try writeMetaText(writer, 0x03, name);
    try writer.bytes(&.{ 0, 0xc0 | (channel & 0x0f), program });
    var previous_tick: u32 = 0;
    for (events) |event| {
        try writer.variable(event.tick - previous_tick);
        try writer.byte(event.status);
        try writer.byte(event.data1);
        if (event.data_len == 2) try writer.byte(event.data2);
        previous_tick = event.tick;
    }
    try endTrack(writer, track.length_offset, track.data_start);
}

test "writes a deterministic type-1 MIDI score with vocal guide and pedals" {
    const importer = @import("../import/midi.zig");
    var meta: model.DocumentMeta = .{ .beats_per_measure = 6, .beat_unit = 8, .key_fifths = -5 };
    meta.setTitle("Roundtrip");
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 91, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 0.5, .duration_beats = 0.5, .pitch = 72, .velocity = 78, .staff = 8, .voice = 0, .flags = model.note_flag_vocal_guide },
    };
    const pedals = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start },
        .{ .start_beat = 0.5, .pedal = model.pedal_soft, .value = 72, .action = model.pedal_action_start },
        .{ .start_beat = 2, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop },
    };
    var playback: model.PlaybackBounds = .{ .tempo_base_bpm = 132 };
    playback.tempos[0] = .{ .start_beat = 0, .bpm = 132 };
    playback.tempos[1] = .{ .start_beat = 2, .bpm = 120 };
    playback.tempo_count = 2;
    var encoded: [4096]u8 = undefined;
    const length = try write(&encoded, &meta, 132, &playback, &notes, &pedals);
    try std.testing.expectEqualStrings("MThd", encoded[0..4]);
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqualStrings("Roundtrip", report.titleSlice());
    try std.testing.expectApproxEqAbs(@as(f32, 132), report.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expect((report.notes[1].flags & model.note_flag_vocal_guide) != 0);
    try std.testing.expectEqual(@as(usize, 3), report.pedal_count);
    try std.testing.expectEqual(@as(u8, 72), report.pedals[1].value);
    try std.testing.expectEqual(@as(u8, 6), report.beats_per_measure);
    try std.testing.expectEqual(@as(u8, 8), report.beat_unit);
    try std.testing.expectEqual(@as(i8, -5), report.key_fifths);
    try std.testing.expectEqual(@as(usize, 2), report.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 120), report.tempos[1].bpm, 0.01);
}

test "MIDI conductor normalizes an eighth-note display pulse to quarter tempo" {
    const importer = @import("../import/midi.zig");
    var meta: model.DocumentMeta = .{ .tempo_beat_unit = 8 };
    meta.setTitle("Eighth pulse");
    const notes = [_]model.Note{.{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 61, .velocity = 90, .staff = 0, .voice = 0 }};
    var playback: model.PlaybackBounds = .{ .tempo_base_bpm = 73.5, .tempo_beat_unit = 8 };
    playback.tempos[0] = .{ .start_beat = 0, .bpm = 73.5 };
    var encoded: [2048]u8 = undefined;
    const length = try write(&encoded, &meta, 147, &playback, &notes, &.{});
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), report.tempo_bpm, 0.01);
}

test "connected tie segments export as one MIDI attack and release" {
    const importer = @import("../import/midi.zig");
    const meta: model.DocumentMeta = .{};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_start },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_tie_stop },
    };
    var encoded: [2048]u8 = undefined;
    const playback: model.PlaybackBounds = .{ .tempo_base_bpm = 120 };
    const length = try write(&encoded, &meta, 120, &playback, &notes, &.{});
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqual(@as(usize, 1), report.note_count);
    try std.testing.expectApproxEqAbs(@as(f32, 2), report.notes[0].duration_beats, 0.001);
}

test "recorded take export preserves human timing and pedal controllers" {
    const importer = @import("../import/midi.zig");
    var meta: model.DocumentMeta = .{};
    meta.setTitle("Human Take");
    var take: recording.Take = .{ .tempo_bpm = 90 };
    take.pushMidi(.{ .time_ns = 1_000_000_000, .sequence = 0, .kind = 0x90, .channel = 2, .data1 = 60, .data2 = 101 });
    take.pushMidi(.{ .time_ns = 1_250_000_000, .sequence = 1, .kind = 0xb0, .channel = 2, .data1 = 64, .data2 = 83 });
    take.pushMidi(.{ .time_ns = 1_500_000_000, .sequence = 2, .kind = 0x80, .channel = 2, .data1 = 60, .data2 = 0 });
    take.pushMidi(.{ .time_ns = 1_500_000_000, .sequence = 3, .kind = 0xb0, .channel = 2, .data1 = 64, .data2 = 0 });
    var encoded: [4096]u8 = undefined;
    const length = try writeTake(&encoded, &meta, &take);
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqualStrings("Human Take", report.titleSlice());
    try std.testing.expectApproxEqAbs(@as(f32, 90), report.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(usize, 1), report.note_count);
    try std.testing.expectEqual(@as(u8, 2), report.notes[0].voice);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), report.notes[0].duration_beats, 0.001);
    try std.testing.expectEqual(@as(usize, 2), report.pedal_count);
    try std.testing.expectEqual(@as(u8, 83), report.pedals[0].value);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), report.pedals[0].start_beat, 0.001);
}
