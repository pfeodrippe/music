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
const max_expanded_events = max_note_events * 4;
const max_expanded_occurrences = musicxml.max_import_measures * 8;
const max_expanded_tempos = model.max_tempo_events * 8;
const max_piano_events = max_expanded_events + musicxml.max_import_pedals * 4;

const MeasureOccurrence = struct {
    source_start: f32,
    source_end: f32,
    output_start: f32,
};

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
    return writeWithMeasures(output, meta, tempo_bpm, playback, notes, pedals, &.{});
}

pub fn writeWithMeasures(output: []u8, meta: *const model.DocumentMeta, tempo_bpm: f32, playback: *const model.PlaybackBounds, notes: []const model.Note, pedals: []const model.PedalEvent, measures: []const model.Measure) Error!usize {
    if (!std.math.isFinite(tempo_bpm) or tempo_bpm <= 0) return error.InvalidTempo;

    var piano_events: [max_piano_events]Event = undefined;
    var piano_count: usize = 0;
    var vocal_events: [max_expanded_events]Event = undefined;
    var vocal_count: usize = 0;
    var sequence: u32 = 0;

    var occurrences: [max_expanded_occurrences]MeasureOccurrence = undefined;
    const occurrence_count = try buildMeasureOccurrences(measures, &occurrences);
    const played_occurrences = occurrences[0..occurrence_count];

    if (played_occurrences.len == 0) {
        for (notes) |note| {
            const performed = model.performedNoteRange(notes, note);
            try appendMappedNote(notes, note, @max(0, performed.start), performed.end - performed.start, &piano_events, &piano_count, &vocal_events, &vocal_count, &sequence);
        }
    } else {
        for (played_occurrences) |occurrence| {
            for (notes) |note| {
                if (note.start_beat < occurrence.source_start - 0.0001 or note.start_beat >= occurrence.source_end - 0.0001) continue;
                const performed = model.performedNoteRange(notes, note);
                const mapped_start = @max(0, occurrence.output_start + performed.start - occurrence.source_start);
                try appendMappedNote(notes, note, mapped_start, performed.end - performed.start, &piano_events, &piano_count, &vocal_events, &vocal_count, &sequence);
            }
        }
    }

    if (played_occurrences.len == 0) {
        for (pedals) |pedal| try appendMappedPedal(pedal, pedal.start_beat, &piano_events, &piano_count, &sequence);
    } else {
        for (played_occurrences) |occurrence| {
            for (pedals) |pedal| {
                if (pedal.start_beat < occurrence.source_start - 0.0001 or pedal.start_beat >= occurrence.source_end - 0.0001) continue;
                try appendMappedPedal(pedal, occurrence.output_start + @max(0, pedal.start_beat - occurrence.source_start), &piano_events, &piano_count, &sequence);
            }
        }
    }

    sortEvents(piano_events[0..piano_count]);
    sortEvents(vocal_events[0..vocal_count]);

    var writer: Writer = .{ .output = output };
    try writer.bytes("MThd");
    try writer.u32be(6);
    try writer.u16be(1);
    try writer.u16be(if (vocal_count == 0) 2 else 3);
    try writer.u16be(ticks_per_quarter);
    var expanded_tempos: [max_expanded_tempos]model.TempoEvent = undefined;
    const expanded_tempo_count = if (played_occurrences.len == 0) @as(usize, 0) else try buildExpandedTempoMap(playback, played_occurrences, &expanded_tempos);
    try writeConductorTrackExpanded(&writer, meta, tempo_bpm, meta.tempo_beat_unit, playback, expanded_tempos[0..expanded_tempo_count]);
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

fn buildMeasureOccurrences(measures: []const model.Measure, output: []MeasureOccurrence) Error!usize {
    var has_repeat = false;
    for (measures) |measure| has_repeat = has_repeat or measure.hasForwardRepeat() or measure.hasBackwardRepeat();
    if (!has_repeat or measures.len == 0) return 0;
    if (measures.len > musicxml.max_import_measures) return error.TooManyEvents;

    var traversals = [_]u8{0} ** musicxml.max_import_measures;
    var count: usize = 0;
    var measure_index: usize = 0;
    var output_beat: f32 = 0;
    while (measure_index < measures.len) {
        const route_measure = measures[measure_index];
        if (route_measure.ending_mask != 0) {
            if (endingRepeatMeasure(measures, measure_index)) |repeat_measure| {
                const pass = traversals[repeat_measure] + 1;
                if (!route_measure.endingIncludesPass(pass)) {
                    const destination = endingDestinationMeasure(measures, measure_index, pass);
                    if (destination > repeat_measure) traversals[repeat_measure] = 0;
                    measure_index = destination;
                    continue;
                }
            }
        }
        if (count == output.len) return error.TooManyEvents;
        const measure = route_measure;
        const duration = @max(0.0001, measure.duration_beats);
        output[count] = .{
            .source_start = measure.start_beat,
            .source_end = measure.start_beat + duration,
            .output_start = output_beat,
        };
        count += 1;
        output_beat += duration;

        if (measure.hasBackwardRepeat() and traversals[measure_index] < measure.repeatPasses() - 1) {
            traversals[measure_index] += 1;
            measure_index = repeatTargetMeasure(measures, measure_index);
        } else {
            if (measure.hasBackwardRepeat()) traversals[measure_index] = 0;
            measure_index += 1;
        }
    }
    return count;
}

fn endingRepeatMeasure(measures: []const model.Measure, ending_measure: usize) ?usize {
    var index = ending_measure;
    while (index < measures.len) : (index += 1) {
        if (measures[index].hasBackwardRepeat()) return index;
        if (index > ending_measure and measures[index].endingStarts()) return null;
    }
    return null;
}

fn endingDestinationMeasure(measures: []const model.Measure, ending_measure: usize, pass: u8) usize {
    var index = ending_measure + 1;
    while (index < measures.len) : (index += 1) {
        if (measures[index].ending_mask != 0) {
            if (measures[index].endingIncludesPass(pass)) return index;
            continue;
        }
        return index;
    }
    return measures.len;
}

fn repeatTargetMeasure(measures: []const model.Measure, backward_measure: usize) usize {
    var index = @min(backward_measure + 1, measures.len);
    while (index != 0) {
        index -= 1;
        if (measures[index].hasForwardRepeat()) return index;
    }
    return 0;
}

fn appendMappedNote(notes: []const model.Note, note: model.Note, mapped_start: f32, mapped_duration: f32, piano_events: *[max_piano_events]Event, piano_count: *usize, vocal_events: *[max_expanded_events]Event, vocal_count: *usize, sequence: *u32) Error!void {
    if ((note.flags & model.note_flag_rest) != 0) return;
    const vocal = (note.flags & model.note_flag_vocal_guide) != 0;
    const channel: u8 = if (vocal) 1 else if ((note.voice & 0x0f) == 9) 0 else note.voice & 0x0f;
    const tremolo_marks = model.singleTremoloMarks(note);
    if (tremolo_marks != 0) {
        const interval = model.singleTremoloInterval(note);
        const attack_count = model.singleTremoloAttackCount(note, mapped_duration);
        for (0..attack_count) |attack_index| {
            const attack_start = mapped_start + @as(f32, @floatFromInt(attack_index)) * interval;
            if (attack_start >= mapped_start + mapped_duration - 0.0001) break;
            const attack_end = @min(mapped_start + mapped_duration, attack_start + interval * 0.86);
            const start = try beatTick(attack_start);
            const end = @max(start +| 1, try beatTick(@max(attack_start + 0.005, attack_end)));
            const on: Event = .{ .tick = start, .sequence = sequence.*, .priority = 2, .status = 0x90 | channel, .data1 = note.pitch, .data2 = @max(1, @min(note.velocity, 127)) };
            sequence.* +%= 1;
            const off: Event = .{ .tick = end, .sequence = sequence.*, .priority = 1, .status = 0x80 | channel, .data1 = note.pitch, .data2 = 0 };
            sequence.* +%= 1;
            if (vocal) {
                try appendEvent(vocal_events, vocal_count, on);
                try appendEvent(vocal_events, vocal_count, off);
            } else {
                try appendEvent(piano_events, piano_count, on);
                try appendEvent(piano_events, piano_count, off);
            }
        }
        return;
    }
    const connected_from_previous = (note.flags & model.note_flag_tie_stop) != 0 and timeline.hasConnectedTie(notes, note, false);
    const connected_into_next = (note.flags & model.note_flag_tie_start) != 0 and timeline.hasConnectedTie(notes, note, true);
    const start = try beatTick(mapped_start);
    const end = @max(start +| 1, try beatTick(mapped_start + @max(0.005, mapped_duration)));
    if (!connected_from_previous) {
        const event: Event = .{ .tick = start, .sequence = sequence.*, .priority = 2, .status = 0x90 | channel, .data1 = note.pitch, .data2 = @max(1, @min(note.velocity, 127)) };
        sequence.* +%= 1;
        if (vocal) try appendEvent(vocal_events, vocal_count, event) else try appendEvent(piano_events, piano_count, event);
    }
    if (!connected_into_next) {
        const event: Event = .{ .tick = end, .sequence = sequence.*, .priority = 1, .status = 0x80 | channel, .data1 = note.pitch, .data2 = 0 };
        sequence.* +%= 1;
        if (vocal) try appendEvent(vocal_events, vocal_count, event) else try appendEvent(piano_events, piano_count, event);
    }
}

fn appendMappedPedal(pedal: model.PedalEvent, mapped_start: f32, piano_events: *[max_piano_events]Event, piano_count: *usize, sequence: *u32) Error!void {
    const controller: u8 = switch (pedal.pedal) {
        model.pedal_sostenuto => 66,
        model.pedal_soft => 67,
        else => 64,
    };
    try appendEvent(piano_events, piano_count, .{
        .tick = try beatTick(mapped_start),
        .sequence = sequence.*,
        .priority = 0,
        .status = 0xb0,
        .data1 = controller,
        .data2 = @min(pedal.value, 127),
    });
    sequence.* +%= 1;
}

fn buildExpandedTempoMap(playback: *const model.PlaybackBounds, occurrences: []const MeasureOccurrence, output: []model.TempoEvent) Error!usize {
    const source_count = @min(@as(usize, playback.tempo_count), playback.tempos.len);
    var count: usize = 0;
    for (occurrences) |occurrence| {
        var entry_bpm = playback.tempo_base_bpm;
        for (playback.tempos[0..source_count]) |event| {
            if (event.start_beat > occurrence.source_start + 0.0001) break;
            entry_bpm = event.bpm;
        }
        if (count == output.len) return error.TooManyEvents;
        output[count] = .{ .start_beat = occurrence.output_start, .bpm = entry_bpm };
        count += 1;
        for (playback.tempos[0..source_count]) |event| {
            if (event.start_beat <= occurrence.source_start + 0.0001) continue;
            if (event.start_beat >= occurrence.source_end - 0.0001) break;
            if (count == output.len) return error.TooManyEvents;
            output[count] = .{
                .start_beat = occurrence.output_start + event.start_beat - occurrence.source_start,
                .bpm = event.bpm,
            };
            count += 1;
        }
    }
    return count;
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
    return writeConductorTrackExpanded(writer, meta, tempo_bpm, tempo_beat_unit, playback, &.{});
}

fn writeConductorTrackExpanded(writer: *Writer, meta: *const model.DocumentMeta, tempo_bpm: f32, tempo_beat_unit: u8, playback: ?*const model.PlaybackBounds, expanded_tempos: []const model.TempoEvent) Error!void {
    const track = try beginTrack(writer);
    try writeMetaText(writer, 0x03, meta.titleSlice());

    const editable_quarter = model.quarterTempoFromPulse(tempo_bpm, tempo_beat_unit);
    var initial_bpm = editable_quarter;
    const source_tempos: []const model.TempoEvent = if (expanded_tempos.len != 0)
        expanded_tempos
    else if (playback) |map|
        map.tempos[0..@min(@as(usize, map.tempo_count), map.tempos.len)]
    else
        &.{};
    const source_base = if (playback) |map| @max(1, map.tempo_base_bpm) else editable_quarter;
    const scale = editable_quarter / source_base;
    for (source_tempos) |tempo| {
        if (tempo.start_beat > 0.0001) break;
        initial_bpm = tempo.bpm * scale;
    }
    try writeTempoMeta(writer, 0, initial_bpm);

    const denominator_power = try meterPower(meta.beat_unit);
    try writer.bytes(&.{ 0, 0xff, 0x58, 4, @max(1, meta.beats_per_measure), denominator_power, 24, 8 });
    const key: i8 = std.math.clamp(meta.key_fifths, -7, 7);
    try writer.bytes(&.{ 0, 0xff, 0x59, 2, @bitCast(key), 0 });
    var previous_tick: u32 = 0;
    for (source_tempos) |tempo| {
        const tick = try beatTick(@max(0, tempo.start_beat));
        if (tick == 0) continue;
        try writeTempoMeta(writer, tick - previous_tick, tempo.bpm * scale);
        previous_tick = tick;
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

test "Standard MIDI unfolds counted score repeats with tempo and pedal events" {
    const importer = @import("../import/midi.zig");
    var meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    meta.setTitle("Repeated MIDI");
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 4, .pitch = 60, .velocity = 88, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 4, .pitch = 62, .velocity = 86, .staff = 0, .voice = 0 },
    };
    const pedals = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start },
        .{ .start_beat = 3.5, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop },
    };
    var measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1, .repeat = model.measure_repeat_forward },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2, .repeat = model.measure_repeat_backward },
    };
    measures[1].setRepeatPasses(3);
    var playback: model.PlaybackBounds = .{ .tempo_base_bpm = 60 };
    playback.tempos[0] = .{ .start_beat = 0, .bpm = 60 };
    playback.tempos[1] = .{ .start_beat = 4, .bpm = 90 };
    playback.tempo_count = 2;
    var encoded: [8192]u8 = undefined;
    const length = try writeWithMeasures(&encoded, &meta, 60, &playback, &notes, &pedals, &measures);
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqual(@as(usize, 6), report.note_count);
    const expected_starts = [_]f32{ 0, 4, 8, 12, 16, 20 };
    for (expected_starts, report.notes[0..report.note_count]) |expected, note| try std.testing.expectApproxEqAbs(expected, note.start_beat, 0.001);
    try std.testing.expectEqual(@as(usize, 6), report.pedal_count);
    var found_repeated_sixty = false;
    var found_repeated_ninety = false;
    for (report.tempos[0..report.tempo_count]) |tempo| {
        found_repeated_sixty = found_repeated_sixty or (@abs(tempo.start_beat - 8) < 0.001 and @abs(tempo.bpm - 60) < 0.01);
        found_repeated_ninety = found_repeated_ninety or (@abs(tempo.start_beat - 12) < 0.001 and @abs(tempo.bpm - 90) < 0.01);
    }
    try std.testing.expect(found_repeated_sixty);
    try std.testing.expect(found_repeated_ninety);
}

test "Standard MIDI follows first and second alternate endings" {
    const importer = @import("../import/midi.zig");
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 88, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 1, .pitch = 62, .velocity = 88, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 8, .duration_beats = 1, .pitch = 64, .velocity = 88, .staff = 0, .voice = 0 },
        .{ .stable_id = 4, .start_beat = 12, .duration_beats = 1, .pitch = 65, .velocity = 88, .staff = 0, .voice = 0 },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1, .repeat = model.measure_repeat_forward },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
        .{ .start_beat = 8, .duration_beats = 4, .number = 3, .repeat = model.measure_repeat_backward, .ending_mask = 1, .ending_flags = model.measure_ending_start | model.measure_ending_stop },
        .{ .start_beat = 12, .duration_beats = 4, .number = 4, .ending_mask = 2, .ending_flags = model.measure_ending_start | model.measure_ending_stop },
    };
    var encoded: [8192]u8 = undefined;
    const playback: model.PlaybackBounds = .{ .tempo_base_bpm = 120 };
    const length = try writeWithMeasures(&encoded, &meta, 120, &playback, &notes, &.{}, &measures);
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqual(@as(usize, 6), report.note_count);
    const expected_pitches = [_]u8{ 60, 62, 64, 60, 62, 65 };
    const expected_starts = [_]f32{ 0, 4, 8, 12, 16, 20 };
    for (expected_pitches, expected_starts, report.notes[0..report.note_count]) |pitch, start, note| {
        try std.testing.expectEqual(pitch, note.pitch);
        try std.testing.expectApproxEqAbs(start, note.start_beat, 0.001);
    }
}

test "Standard MIDI performs grace before its shortened principal" {
    const importer = @import("../import/midi.zig");
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.125, .pitch = 62, .velocity = 72, .staff = 0, .voice = 0, .flags = model.note_flag_grace, .notations = model.withGraceTiming(0, false, 25, 0, false) },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 84, .staff = 0, .voice = 0 },
    };
    var encoded: [4096]u8 = undefined;
    const playback: model.PlaybackBounds = .{ .tempo_base_bpm = 120 };
    const length = try write(&encoded, &meta, 120, &playback, &notes, &.{});
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expectEqual(@as(u8, 62), report.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f32, 0), report.notes[0].start_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), report.notes[0].duration_beats, 0.001);
    try std.testing.expectEqual(@as(u8, 64), report.notes[1].pitch);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), report.notes[1].start_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), report.notes[1].duration_beats, 0.001);
}

test "Standard MIDI expands a three-mark single-note tremolo into 32nd attacks" {
    const importer = @import("../import/midi.zig");
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 86, .staff = 0, .voice = 0, .notations = model.withSingleTremolo(0, 3) },
    };
    var encoded: [4096]u8 = undefined;
    const playback: model.PlaybackBounds = .{ .tempo_base_bpm = 120 };
    const length = try write(&encoded, &meta, 120, &playback, &notes, &.{});
    const report = try importer.parse(encoded[0..length]);
    try std.testing.expectEqual(@as(usize, 8), report.note_count);
    for (report.notes[0..report.note_count], 0..) |note, index| {
        try std.testing.expectEqual(@as(u8, 60), note.pitch);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(index)) * 0.125, note.start_beat, 0.001);
        try std.testing.expect(note.duration_beats > 0.1 and note.duration_beats < 0.125);
    }
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
