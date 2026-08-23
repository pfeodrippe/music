const std = @import("std");
const model = @import("../model.zig");
const annotation = @import("../annotation.zig");
const musicxml = @import("../import/musicxml.zig");
const recording = @import("../recording.zig");

pub const magic = "SCOREAPP";
pub const current_version: u32 = 15;
const header_size = 20;

pub const Snapshot = struct {
    meta: model.DocumentMeta = .{},
    transport: model.Transport = .{},
    notes: [musicxml.max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    lyrics: [musicxml.max_import_lyrics]model.Lyric = undefined,
    lyric_count: usize = 0,
    harmonies: [musicxml.max_import_harmonies]model.Harmony = undefined,
    harmony_count: usize = 0,
    pedals: [musicxml.max_import_pedals]model.PedalEvent = undefined,
    pedal_count: usize = 0,
    measures: [musicxml.max_import_measures]model.Measure = undefined,
    measure_count: usize = 0,
    tempos: [model.max_tempo_events]model.TempoEvent = undefined,
    tempo_count: usize = 0,
    tempo_base_bpm: f32 = 72,
    annotations: annotation.Store = .{},
    take: recording.Take = .{},
};

pub const Error = error{
    BufferTooSmall,
    InvalidMagic,
    UnsupportedVersion,
    InvalidLength,
    ChecksumMismatch,
    InvalidData,
    TooManyNotes,
    TooManyLyrics,
    TooManyHarmonies,
    TooManyPedals,
    TooManyMeasures,
    TooManyTempos,
    TooManyStrokes,
    TooManyPoints,
    TooManyMidiEvents,
};

pub fn encode(snapshot: *const Snapshot, output: []u8) Error!usize {
    if (output.len < header_size) return error.BufferTooSmall;
    var writer = Writer{ .buffer = output, .offset = header_size };
    try writer.bytes(snapshot.meta.titleSlice());
    try writer.bytes(snapshot.meta.creatorSlice());
    try writer.u32(snapshot.meta.source_kind);
    try writer.u32(snapshot.meta.import_warnings);
    try writer.f32(snapshot.transport.cursor_beat);
    try writer.f32(snapshot.transport.tempo_bpm);
    try writer.f32(snapshot.transport.loop_start);
    try writer.f32(snapshot.transport.loop_end);
    try writer.u32(snapshot.transport.playing);
    try writer.u32(snapshot.transport.recording);
    try writer.u32(snapshot.transport.loop_enabled);
    try writer.u32(snapshot.transport.count_in_bars);
    try writer.u32(@intCast(snapshot.note_count));
    for (snapshot.notes[0..snapshot.note_count]) |note| try writer.note(note);
    try writer.u32(@intCast(snapshot.annotations.stroke_count));
    try writer.u32(@intCast(snapshot.annotations.point_count));
    for (snapshot.annotations.strokes[0..snapshot.annotations.stroke_count]) |stroke| {
        try writer.u64(stroke.stable_id);
        try writer.u32(stroke.first_point);
        try writer.u32(stroke.point_count);
        for (stroke.rgba) |channel| try writer.f32(channel);
        try writer.f32(stroke.width);
        try writer.u32(stroke.finished);
        try writer.u32(stroke.page_index);
    }
    for (snapshot.annotations.points[0..snapshot.annotations.point_count]) |point| {
        try writer.f32(point.u);
        try writer.f32(point.v);
        try writer.f32(point.pressure);
        try writer.f32(point.time_ms);
    }
    try writer.u64(snapshot.take.started_ns);
    try writer.u64(snapshot.take.stopped_ns);
    try writer.u64(snapshot.take.audio_frames);
    try writer.f32(snapshot.take.tempo_bpm);
    try writer.u32(@intCast(snapshot.take.midi_len));
    try writer.u32(if (snapshot.take.midi_overflow) 1 else 0);
    for (snapshot.take.midi[0..snapshot.take.midi_len]) |event| {
        try writer.u64(event.time_ns);
        try writer.u32(event.sequence);
        const message = try writer.reserve(4);
        message[0] = event.kind;
        message[1] = event.channel;
        message[2] = event.data1;
        message[3] = event.data2;
    }
    const notation = try writer.reserve(4);
    notation[0] = snapshot.meta.beats_per_measure;
    notation[1] = snapshot.meta.beat_unit;
    notation[2] = @bitCast(snapshot.meta.key_fifths);
    notation[3] = @max(@as(u8, 1), snapshot.meta.tempo_beat_unit);
    try writer.u32(snapshot.transport.metronome_enabled);
    try writer.u32(@intCast(snapshot.lyric_count));
    for (snapshot.lyrics[0..snapshot.lyric_count]) |lyric| {
        try writer.f32(lyric.start_beat);
        try writer.bytes(lyric.textSlice());
    }
    try writer.u32(@intCast(snapshot.harmony_count));
    for (snapshot.harmonies[0..snapshot.harmony_count]) |harmony| {
        try writer.f32(harmony.start_beat);
        const fields = try writer.reserve(8);
        fields[0] = harmony.root_step;
        fields[1] = @bitCast(harmony.root_alter);
        fields[2] = harmony.bass_step;
        fields[3] = @bitCast(harmony.bass_alter);
        fields[4] = @bitCast(harmony.inversion);
        fields[5] = 0;
        fields[6] = 0;
        fields[7] = 0;
        try writer.bytes(harmony.kindSlice());
        try writer.bytes(harmony.textSlice());
    }
    try writer.u32(@intCast(snapshot.pedal_count));
    for (snapshot.pedals[0..snapshot.pedal_count]) |pedal| {
        try writer.f32(pedal.start_beat);
        const fields = try writer.reserve(4);
        fields[0] = pedal.pedal;
        fields[1] = pedal.value;
        fields[2] = pedal.action;
        fields[3] = pedal.flags;
    }
    try writer.u32(@intCast(snapshot.measure_count));
    for (snapshot.measures[0..snapshot.measure_count]) |measure| {
        try writer.f32(measure.start_beat);
        try writer.f32(measure.duration_beats);
        try writer.u32(measure.number);
        const fields = try writer.reserve(4);
        fields[0] = measure.beats;
        fields[1] = measure.beat_unit;
        fields[2] = measure.implicit;
        fields[3] = measure.reserved;
    }
    try writer.f32(snapshot.tempo_base_bpm);
    try writer.u32(@intCast(snapshot.tempo_count));
    for (snapshot.tempos[0..snapshot.tempo_count]) |tempo| {
        try writer.f32(tempo.start_beat);
        try writer.f32(tempo.bpm);
    }

    const payload = output[header_size..writer.offset];
    @memcpy(output[0..8], magic);
    writeInt(u32, output[8..12], current_version);
    writeInt(u32, output[12..16], @intCast(payload.len));
    writeInt(u32, output[16..20], std.hash.crc.Crc32.hash(payload));
    return writer.offset;
}

pub fn decode(source: []const u8, snapshot: *Snapshot) Error!void {
    if (source.len < header_size or !std.mem.eql(u8, source[0..8], magic)) return error.InvalidMagic;
    const version = readInt(u32, source[8..12]);
    if (version == 0 or version > current_version) return error.UnsupportedVersion;
    const payload_len: usize = readInt(u32, source[12..16]);
    if (payload_len > source.len - header_size) return error.InvalidLength;
    const payload = source[header_size .. header_size + payload_len];
    if (std.hash.crc.Crc32.hash(payload) != readInt(u32, source[16..20])) return error.ChecksumMismatch;

    var reader = Reader{ .buffer = payload };
    snapshot.* = .{};
    snapshot.meta.setTitle(try reader.bytes());
    snapshot.meta.setCreator(try reader.bytes());
    snapshot.meta.source_kind = try reader.u32();
    snapshot.meta.import_warnings = try reader.u32();
    snapshot.transport.cursor_beat = try reader.f32();
    snapshot.transport.tempo_bpm = try reader.f32();
    snapshot.transport.loop_start = try reader.f32();
    snapshot.transport.loop_end = try reader.f32();
    snapshot.transport.playing = try reader.u32();
    snapshot.transport.recording = try reader.u32();
    snapshot.transport.loop_enabled = try reader.u32();
    snapshot.transport.count_in_bars = try reader.u32();
    snapshot.note_count = try reader.u32();
    if (snapshot.note_count > snapshot.notes.len) return error.TooManyNotes;
    for (snapshot.notes[0..snapshot.note_count]) |*note| note.* = try reader.note(version);
    snapshot.annotations.stroke_count = try reader.u32();
    snapshot.annotations.point_count = try reader.u32();
    if (snapshot.annotations.stroke_count > snapshot.annotations.strokes.len) return error.TooManyStrokes;
    if (snapshot.annotations.point_count > snapshot.annotations.points.len) return error.TooManyPoints;
    for (snapshot.annotations.strokes[0..snapshot.annotations.stroke_count]) |*stroke| {
        stroke.stable_id = try reader.u64();
        stroke.first_point = try reader.u32();
        stroke.point_count = try reader.u32();
        for (&stroke.rgba) |*channel| channel.* = try reader.f32();
        stroke.width = try reader.f32();
        stroke.finished = try reader.u32();
        stroke.page_index = if (version >= 3) try reader.u32() else 0;
    }
    for (snapshot.annotations.points[0..snapshot.annotations.point_count]) |*point| {
        point.u = try reader.f32();
        point.v = try reader.f32();
        point.pressure = try reader.f32();
        point.time_ms = try reader.f32();
    }
    if (version == 1) {
        if (reader.offset != payload.len) return error.InvalidData;
        return;
    }
    snapshot.take.started_ns = try reader.u64();
    snapshot.take.stopped_ns = try reader.u64();
    snapshot.take.audio_frames = try reader.u64();
    if (version >= 11) snapshot.take.tempo_bpm = try reader.f32();
    snapshot.take.midi_len = try reader.u32();
    snapshot.take.midi_overflow = (try reader.u32()) != 0;
    if (snapshot.take.midi_len > snapshot.take.midi.len) return error.TooManyMidiEvents;
    for (snapshot.take.midi[0..snapshot.take.midi_len]) |*event| {
        event.time_ns = try reader.u64();
        event.sequence = try reader.u32();
        const message = try reader.take(4);
        event.kind = message[0];
        event.channel = message[1];
        event.data1 = message[2];
        event.data2 = message[3];
    }
    if (version >= 4) {
        const notation = try reader.take(4);
        snapshot.meta.beats_per_measure = notation[0];
        snapshot.meta.beat_unit = notation[1];
        snapshot.meta.key_fifths = @bitCast(notation[2]);
        snapshot.meta.tempo_beat_unit = if (version >= 14 and notation[3] != 0) notation[3] else 4;
    }
    if (version >= 5) snapshot.transport.metronome_enabled = try reader.u32();
    if (version >= 6) {
        snapshot.lyric_count = try reader.u32();
        if (snapshot.lyric_count > snapshot.lyrics.len) return error.TooManyLyrics;
        for (snapshot.lyrics[0..snapshot.lyric_count]) |*lyric| {
            lyric.* = .{ .start_beat = try reader.f32() };
            lyric.setText(try reader.bytes());
        }
    }
    if (version >= 8) {
        snapshot.harmony_count = try reader.u32();
        if (snapshot.harmony_count > snapshot.harmonies.len) return error.TooManyHarmonies;
        for (snapshot.harmonies[0..snapshot.harmony_count]) |*harmony| {
            harmony.* = .{ .start_beat = try reader.f32() };
            const fields = try reader.take(8);
            harmony.root_step = fields[0];
            harmony.root_alter = @bitCast(fields[1]);
            harmony.bass_step = fields[2];
            harmony.bass_alter = @bitCast(fields[3]);
            harmony.inversion = @bitCast(fields[4]);
            harmony.setKind(try reader.bytes());
            harmony.setText(try reader.bytes());
        }
    }
    if (version >= 10) {
        snapshot.pedal_count = try reader.u32();
        if (snapshot.pedal_count > snapshot.pedals.len) return error.TooManyPedals;
        for (snapshot.pedals[0..snapshot.pedal_count]) |*pedal| {
            pedal.* = .{ .start_beat = try reader.f32() };
            const fields = try reader.take(4);
            pedal.pedal = fields[0];
            pedal.value = fields[1];
            pedal.action = fields[2];
            pedal.flags = fields[3];
        }
    }
    if (version >= 12) {
        snapshot.measure_count = try reader.u32();
        if (snapshot.measure_count > snapshot.measures.len) return error.TooManyMeasures;
        for (snapshot.measures[0..snapshot.measure_count]) |*measure| {
            measure.* = .{
                .start_beat = try reader.f32(),
                .duration_beats = try reader.f32(),
                .number = try reader.u32(),
            };
            const fields = try reader.take(4);
            measure.beats = fields[0];
            measure.beat_unit = fields[1];
            measure.implicit = fields[2];
            measure.reserved = fields[3];
        }
    }
    if (version >= 13) {
        snapshot.tempo_base_bpm = try reader.f32();
        snapshot.tempo_count = try reader.u32();
        if (snapshot.tempo_count > snapshot.tempos.len) return error.TooManyTempos;
        for (snapshot.tempos[0..snapshot.tempo_count]) |*tempo| {
            tempo.* = .{ .start_beat = try reader.f32(), .bpm = try reader.f32() };
        }
    } else {
        snapshot.tempo_base_bpm = snapshot.transport.tempo_bpm;
        snapshot.tempo_count = 1;
        snapshot.tempos[0] = .{ .start_beat = 0, .bpm = snapshot.transport.tempo_bpm };
    }
    snapshot.annotations.next_id = 1;
    for (snapshot.annotations.strokes[0..snapshot.annotations.stroke_count]) |stroke| snapshot.annotations.next_id = @max(snapshot.annotations.next_id, stroke.stable_id + 1);
    if (reader.offset != payload.len) return error.InvalidData;
    return;
}

const Writer = struct {
    buffer: []u8,
    offset: usize,

    fn reserve(self: *Writer, len: usize) Error![]u8 {
        if (len > self.buffer.len -| self.offset) return error.BufferTooSmall;
        const result = self.buffer[self.offset .. self.offset + len];
        self.offset += len;
        return result;
    }

    fn bytes(self: *Writer, value: []const u8) Error!void {
        try self.u32(@intCast(value.len));
        @memcpy(try self.reserve(value.len), value);
    }

    fn @"u32"(self: *Writer, value: u32) Error!void {
        writeInt(u32, try self.reserve(4), value);
    }

    fn @"u64"(self: *Writer, value: u64) Error!void {
        writeInt(u64, try self.reserve(8), value);
    }

    fn @"f32"(self: *Writer, value: f32) Error!void {
        try self.u32(@bitCast(value));
    }

    fn note(self: *Writer, value: model.Note) Error!void {
        try self.u64(value.stable_id);
        try self.f32(value.start_beat);
        try self.f32(value.duration_beats);
        const quartet = try self.reserve(4);
        quartet[0] = value.pitch;
        quartet[1] = value.velocity;
        quartet[2] = value.staff;
        quartet[3] = value.voice;
        const spelling = try self.reserve(4);
        spelling[0] = value.written_step;
        spelling[1] = @bitCast(value.written_alter);
        spelling[2] = @bitCast(value.written_octave);
        spelling[3] = value.dots;
        try self.u32(@intCast(value.selected));
        try self.u32(value.flags);
        const technique = try self.reserve(4);
        technique[0] = value.fingering;
        technique[1] = 0;
        technique[2] = 0;
        technique[3] = 0;
    }
};

const Reader = struct {
    buffer: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, len: usize) Error![]const u8 {
        if (len > self.buffer.len -| self.offset) return error.InvalidData;
        const result = self.buffer[self.offset .. self.offset + len];
        self.offset += len;
        return result;
    }

    fn bytes(self: *Reader) Error![]const u8 {
        return self.take(try self.u32());
    }

    fn @"u32"(self: *Reader) Error!u32 {
        return readInt(u32, try self.take(4));
    }

    fn @"u64"(self: *Reader) Error!u64 {
        return readInt(u64, try self.take(8));
    }

    fn @"f32"(self: *Reader) Error!f32 {
        return @bitCast(try self.u32());
    }

    fn note(self: *Reader, version: u32) Error!model.Note {
        const stable_id = try self.u64();
        const start = try self.f32();
        const duration = try self.f32();
        const quartet = try self.take(4);
        const spelling = if (version >= 9) try self.take(4) else null;
        const selected = try self.u32();
        const flags = if (version >= 7) try self.u32() else 0;
        const technique = if (version >= 15) try self.take(4) else null;
        return .{
            .stable_id = stable_id,
            .start_beat = start,
            .duration_beats = duration,
            .pitch = quartet[0],
            .velocity = quartet[1],
            .staff = quartet[2],
            .voice = quartet[3],
            .written_step = if (spelling) |value| value[0] else 0,
            .written_alter = if (spelling) |value| @bitCast(value[1]) else 0,
            .written_octave = if (spelling) |value| @bitCast(value[2]) else -1,
            .dots = if (spelling) |value| value[3] else 0,
            .selected = if (selected != 0) 1 else 0,
            .flags = flags,
            .fingering = if (technique) |value| if (value[0] >= 1 and value[0] <= 5) value[0] else 0 else 0,
        };
    }
};

fn writeInt(comptime T: type, destination: []u8, value: T) void {
    for (0..@sizeOf(T)) |index| destination[index] = @truncate(value >> @intCast(index * 8));
}

fn readInt(comptime T: type, source: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |index| value |= @as(T, source[index]) << @intCast(index * 8);
    return value;
}

test "native document round trips notes, transport and anchored ink" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.meta.setTitle("Round Trip");
    snapshot.meta.tempo_beat_unit = 8;
    snapshot.transport.tempo_bpm = 84;
    snapshot.transport.metronome_enabled = 0;
    snapshot.notes[0] = .{ .stable_id = 9, .start_beat = 1.5, .duration_beats = 0.75, .pitch = 63, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'E', .written_alter = -1, .written_octave = 4, .dots = 1, .flags = model.note_flag_beam_begin | model.note_flag_tie_start, .fingering = 4 };
    snapshot.note_count = 1;
    snapshot.lyrics[0] = .{ .start_beat = 1.5 };
    snapshot.lyrics[0].setText("sing this");
    snapshot.lyric_count = 1;
    snapshot.harmonies[0] = .{ .start_beat = 1, .root_step = 'B', .root_alter = -1, .bass_step = 'D', .bass_alter = -1 };
    snapshot.harmonies[0].setKind("minor-seventh");
    snapshot.harmonies[0].setText("m7");
    snapshot.harmony_count = 1;
    snapshot.pedals[0] = .{ .start_beat = 1.25, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start, .flags = model.pedal_flag_line };
    snapshot.pedal_count = 1;
    snapshot.measures[0] = .{ .start_beat = 0, .duration_beats = 1, .number = 0, .beats = 4, .beat_unit = 4, .implicit = 1 };
    snapshot.measures[1] = .{ .start_beat = 1, .duration_beats = 2, .number = 1, .beats = 2, .beat_unit = 4 };
    snapshot.measure_count = 2;
    snapshot.tempo_base_bpm = 120;
    snapshot.tempos[0] = .{ .start_beat = 0, .bpm = 120 };
    snapshot.tempos[1] = .{ .start_beat = 2, .bpm = 108 };
    snapshot.tempo_count = 2;
    snapshot.annotations.beginScore(.{ .u = 12.5, .v = 0.3, .pressure = 0.8, .time_ms = 10 }, 1);
    snapshot.annotations.end();
    var bytes: [4096]u8 = undefined;
    const len = try encode(snapshot, &bytes);
    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..len], decoded);
    try std.testing.expectEqualStrings("Round Trip", decoded.meta.titleSlice());
    try std.testing.expectEqual(@as(u8, 8), decoded.meta.tempo_beat_unit);
    try std.testing.expectEqual(@as(u8, 63), decoded.notes[0].pitch);
    try std.testing.expectEqual(@as(u8, 'E'), decoded.notes[0].written_step);
    try std.testing.expectEqual(@as(i8, -1), decoded.notes[0].written_alter);
    try std.testing.expectEqual(@as(i8, 4), decoded.notes[0].written_octave);
    try std.testing.expectEqual(@as(u8, 1), decoded.notes[0].dots);
    try std.testing.expectEqual(@as(u8, 4), decoded.notes[0].fingering);
    try std.testing.expect((decoded.notes[0].flags & model.note_flag_tie_start) != 0);
    try std.testing.expectEqualStrings("sing this", decoded.lyrics[0].textSlice());
    try std.testing.expectEqual(@as(usize, 1), decoded.harmony_count);
    try std.testing.expectEqualStrings("minor-seventh", decoded.harmonies[0].kindSlice());
    try std.testing.expectEqual(@as(i8, -1), decoded.harmonies[0].bass_alter);
    try std.testing.expectEqual(@as(usize, 1), decoded.pedal_count);
    try std.testing.expectEqual(model.pedal_action_start, decoded.pedals[0].action);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), decoded.pedals[0].start_beat, 0.001);
    try std.testing.expectEqual(@as(usize, 2), decoded.measure_count);
    try std.testing.expectEqual(@as(u32, 0), decoded.measures[0].number);
    try std.testing.expectEqual(@as(u8, 1), decoded.measures[0].implicit);
    try std.testing.expectEqual(@as(u8, 2), decoded.measures[1].beats);
    try std.testing.expectEqual(@as(usize, 2), decoded.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 120), decoded.tempo_base_bpm, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 108), decoded.tempos[1].bpm, 0.001);
    try std.testing.expectEqual(@as(usize, 1), decoded.annotations.point_count);
    try std.testing.expect(annotation.isScoreSpace(decoded.annotations.strokes[0]));
    try std.testing.expectEqual(@as(u32, 1), annotation.pageIndex(decoded.annotations.strokes[0]));
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), decoded.annotations.points[0].u, 0.001);
    try std.testing.expectEqual(@as(u32, 0), decoded.transport.metronome_enabled);
}

test "native document persists synchronized MIDI take metadata" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.take.reset(1_000);
    snapshot.take.tempo_bpm = 93.5;
    snapshot.take.pushMidi(.{ .time_ns = 1_250, .sequence = 0, .kind = 0x90, .channel = 2, .data1 = 67, .data2 = 96 });
    snapshot.take.stopped_ns = 2_000;
    var bytes: [4096]u8 = undefined;
    const len = try encode(snapshot, &bytes);
    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..len], decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.take.midi_len);
    try std.testing.expectEqual(@as(u8, 67), decoded.take.midi[0].data1);
    try std.testing.expectEqual(@as(u8, 2), decoded.take.midi[0].channel);
    try std.testing.expectApproxEqAbs(@as(f32, 93.5), decoded.take.tempo_bpm, 0.001);
}

test "version 14 native documents migrate with automatic fingering" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.notes[0] = .{ .stable_id = 3, .start_beat = 2, .duration_beats = 1, .pitch = 65, .velocity = 80, .staff = 0, .voice = 0, .fingering = 5 };
    snapshot.note_count = 1;
    var bytes: [4096]u8 = undefined;
    const encoded_len = try encode(snapshot, &bytes);

    var note_start: usize = header_size;
    for (0..2) |_| {
        const text_len: usize = readInt(u32, bytes[note_start .. note_start + 4]);
        note_start += 4 + text_len;
    }
    note_start += 8 + 16 + 16;
    try std.testing.expectEqual(@as(u32, 1), readInt(u32, bytes[note_start .. note_start + 4]));
    note_start += 4;
    const technique_start = note_start + 32;
    std.mem.copyForwards(u8, bytes[technique_start .. encoded_len - 4], bytes[technique_start + 4 .. encoded_len]);
    const legacy_len = encoded_len - 4;
    writeInt(u32, bytes[8..12], 14);
    writeInt(u32, bytes[12..16], @intCast(legacy_len - header_size));
    writeInt(u32, bytes[16..20], std.hash.crc.Crc32.hash(bytes[header_size..legacy_len]));

    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..legacy_len], decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.note_count);
    try std.testing.expectEqual(@as(u8, 65), decoded.notes[0].pitch);
    try std.testing.expectEqual(@as(u8, 0), decoded.notes[0].fingering);
}

test "checksum rejects torn journals" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.meta.setTitle("Checksum");
    var bytes: [1024]u8 = undefined;
    const len = try encode(snapshot, &bytes);
    bytes[len - 1] ^= 0xff;
    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try std.testing.expectError(error.ChecksumMismatch, decode(bytes[0..len], decoded));
}
