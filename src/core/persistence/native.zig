const std = @import("std");
const model = @import("../model.zig");
const annotation = @import("../annotation.zig");
const musicxml = @import("../import/musicxml.zig");
const recording = @import("../recording.zig");

pub const magic = "SCOREAPP";
pub const current_version: u32 = 21;
const header_size = 20;

/// Deliberately small, platform-independent reading state. These fields are
/// safe to restore across native/WebGPU frontends; transient device, pointer,
/// modal, and sampler state remains owned by the active platform host.
pub const ViewPreferences = struct {
    view_start_beat: f32 = 0,
    zoom: f32 = 1,
    continuous_pan_fraction: f32 = 0,
    tool: model.Tool = .read,
    score_view_mode: model.ScoreViewMode = .paged,
    focus_score: u32 = 0,
    keyboard_visible: u32 = 1,
    vocal_guide_visible: u32 = 1,
    pedal_guide_visible: u32 = 1,
    selected_part: u32 = 0,
};

pub const Snapshot = struct {
    meta: model.DocumentMeta = .{},
    transport: model.Transport = .{},
    notes: [musicxml.max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    lyrics: [musicxml.max_import_lyrics]model.Lyric = undefined,
    lyric_count: usize = 0,
    harmonies: [musicxml.max_import_harmonies]model.Harmony = undefined,
    harmony_count: usize = 0,
    hairpins: [musicxml.max_import_hairpins]model.Hairpin = undefined,
    hairpin_count: usize = 0,
    pedals: [musicxml.max_import_pedals]model.PedalEvent = undefined,
    pedal_count: usize = 0,
    measures: [musicxml.max_import_measures]model.Measure = undefined,
    measure_count: usize = 0,
    tempos: [model.max_tempo_events]model.TempoEvent = undefined,
    tempo_count: usize = 0,
    tempo_base_bpm: f32 = 72,
    parts: [model.max_score_parts]model.ScorePart = [_]model.ScorePart{.{}} ** model.max_score_parts,
    part_count: usize = 0,
    annotations: annotation.Store = .{},
    take: recording.Take = .{},
    view: ViewPreferences = .{},
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
    TooManyHairpins,
    TooManyPedals,
    TooManyMeasures,
    TooManyTempos,
    TooManyParts,
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
        fields[3] = measure.repeat;
        try writer.u32(@as(u32, measure.ending_mask) | (@as(u32, measure.ending_flags) << 16));
    }
    try writer.f32(snapshot.tempo_base_bpm);
    try writer.u32(@intCast(snapshot.tempo_count));
    for (snapshot.tempos[0..snapshot.tempo_count]) |tempo| {
        try writer.f32(tempo.start_beat);
        try writer.f32(tempo.bpm);
    }
    try writer.u32(@intCast(snapshot.part_count));
    for (snapshot.parts[0..snapshot.part_count]) |part| {
        try writer.u32(part.source_index);
        try writer.u32(part.flags);
        try writer.u32(part.midi_program);
        try writer.bytes(part.nameSlice());
    }
    try writer.u32(@intCast(snapshot.hairpin_count));
    for (snapshot.hairpins[0..snapshot.hairpin_count]) |hairpin| {
        try writer.f32(hairpin.start_beat);
        try writer.f32(hairpin.end_beat);
        try writer.f32(hairpin.spread);
        const fields = try writer.reserve(4);
        fields[0] = hairpin.staff;
        fields[1] = hairpin.kind;
        fields[2] = hairpin.number;
        fields[3] = hairpin.flags;
    }
    try writer.f32(snapshot.view.view_start_beat);
    try writer.f32(snapshot.view.zoom);
    try writer.f32(snapshot.view.continuous_pan_fraction);
    try writer.u32(@intFromEnum(snapshot.view.tool));
    try writer.u32(@intFromEnum(snapshot.view.score_view_mode));
    try writer.u32(snapshot.view.focus_score);
    try writer.u32(snapshot.view.keyboard_visible);
    try writer.u32(snapshot.view.vocal_guide_visible);
    try writer.u32(snapshot.view.pedal_guide_visible);
    try writer.u32(snapshot.view.selected_part);

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
            measure.repeat = fields[3];
            if (version >= 20) {
                const ending = try reader.u32();
                measure.ending_mask = @truncate(ending);
                measure.ending_flags = @truncate(ending >> 16);
            }
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
    if (version >= 17) {
        snapshot.part_count = try reader.u32();
        if (snapshot.part_count > snapshot.parts.len) return error.TooManyParts;
        for (snapshot.parts[0..snapshot.part_count]) |*part| {
            part.* = .{
                .source_index = try reader.u32(),
                .flags = try reader.u32(),
                .midi_program = try reader.u32(),
            };
            part.setName(try reader.bytes());
        }
    } else {
        deriveLegacyParts(snapshot);
    }
    if (version >= 18) {
        snapshot.hairpin_count = try reader.u32();
        if (snapshot.hairpin_count > snapshot.hairpins.len) return error.TooManyHairpins;
        for (snapshot.hairpins[0..snapshot.hairpin_count]) |*hairpin| {
            hairpin.* = .{
                .start_beat = try reader.f32(),
                .end_beat = try reader.f32(),
                .spread = try reader.f32(),
            };
            const fields = try reader.take(4);
            hairpin.staff = fields[0];
            hairpin.kind = fields[1];
            hairpin.number = fields[2];
            hairpin.flags = fields[3];
        }
    }
    if (version >= 21) {
        snapshot.view.view_start_beat = try reader.f32();
        snapshot.view.zoom = try reader.f32();
        snapshot.view.continuous_pan_fraction = try reader.f32();
        if (!std.math.isFinite(snapshot.view.view_start_beat) or
            !std.math.isFinite(snapshot.view.zoom) or
            !std.math.isFinite(snapshot.view.continuous_pan_fraction)) return error.InvalidData;
        snapshot.view.tool = switch (try reader.u32()) {
            0 => .read,
            1 => .edit,
            2 => .annotate,
            3 => .practice,
            else => return error.InvalidData,
        };
        snapshot.view.score_view_mode = switch (try reader.u32()) {
            0 => .paged,
            1 => .continuous,
            else => return error.InvalidData,
        };
        snapshot.view.focus_score = if ((try reader.u32()) != 0) 1 else 0;
        snapshot.view.keyboard_visible = if ((try reader.u32()) != 0) 1 else 0;
        snapshot.view.vocal_guide_visible = if ((try reader.u32()) != 0) 1 else 0;
        snapshot.view.pedal_guide_visible = if ((try reader.u32()) != 0) 1 else 0;
        snapshot.view.selected_part = try reader.u32();
        if (snapshot.view.selected_part >= model.max_instrument_parts) return error.InvalidData;
    }
    snapshot.annotations.next_id = 1;
    for (snapshot.annotations.strokes[0..snapshot.annotations.stroke_count]) |stroke| snapshot.annotations.next_id = @max(snapshot.annotations.next_id, stroke.stable_id + 1);
    if (reader.offset != payload.len) return error.InvalidData;
    return;
}

fn deriveLegacyParts(snapshot: *Snapshot) void {
    var present: u32 = 0;
    var vocal: u32 = 0;
    for (snapshot.notes[0..snapshot.note_count]) |note| {
        const bit = @as(u32, 1) << @intCast(model.notePart(note));
        present |= bit;
        if ((note.flags & model.note_flag_vocal_guide) != 0) vocal |= bit;
    }
    if (present == 0) present = 1;
    for (0..model.max_instrument_parts) |source_index| {
        const bit = @as(u32, 1) << @intCast(source_index);
        if ((present & bit) == 0 or snapshot.part_count == snapshot.parts.len) continue;
        var part: model.ScorePart = .{ .source_index = @intCast(source_index) };
        if ((vocal & bit) != 0) {
            part.flags |= model.score_part_flag_vocal;
            part.setName("Vocal guide");
        } else if (@popCount(present & ~vocal) == 1) {
            part.midi_program = 1;
            part.setName("Piano");
        } else {
            var name_buffer: [24]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "Part {d}", .{source_index + 1}) catch "Part";
            part.setName(name);
        }
        snapshot.parts[snapshot.part_count] = part;
        snapshot.part_count += 1;
    }
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
        technique[1] = value.slur_start_mask;
        technique[2] = value.slur_stop_mask;
        technique[3] = 0;
        try self.u32(value.notations);
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
        const notations = if (version >= 19) try self.u32() else 0;
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
            .slur_start_mask = if (version >= 16) technique.?[1] else 0,
            .slur_stop_mask = if (version >= 16) technique.?[2] else 0,
            .notations = notations,
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
    snapshot.notes[0] = .{ .stable_id = 9, .start_beat = 1.5, .duration_beats = 0.75, .pitch = 63, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'E', .written_alter = -1, .written_octave = 4, .dots = 1, .flags = model.note_flag_beam_begin | model.note_flag_tie_start | model.note_flag_slur_start, .fingering = 4, .slur_start_mask = model.slurNumberBit(2) | model.slurNumberBit(4), .notations = model.withSingleTremolo(model.note_notation_trill | model.note_notation_arpeggiate_up, 4) };
    snapshot.note_count = 1;
    snapshot.lyrics[0] = .{ .start_beat = 1.5 };
    snapshot.lyrics[0].setText("sing this");
    snapshot.lyric_count = 1;
    snapshot.harmonies[0] = .{ .start_beat = 1, .root_step = 'B', .root_alter = -1, .bass_step = 'D', .bass_alter = -1 };
    snapshot.harmonies[0].setKind("minor-seventh");
    snapshot.harmonies[0].setText("m7");
    snapshot.harmony_count = 1;
    snapshot.hairpins[0] = .{ .start_beat = 1.25, .end_beat = 2.75, .spread = 18, .staff = 0, .kind = model.hairpin_crescendo, .number = 2, .flags = model.hairpin_flag_above | model.hairpin_flag_niente };
    snapshot.hairpin_count = 1;
    snapshot.pedals[0] = .{ .start_beat = 1.25, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start, .flags = model.pedal_flag_line };
    snapshot.pedal_count = 1;
    snapshot.measures[0] = .{ .start_beat = 0, .duration_beats = 1, .number = 0, .beats = 4, .beat_unit = 4, .implicit = 1, .repeat = model.measure_repeat_forward, .ending_mask = 1, .ending_flags = model.measure_ending_start };
    snapshot.measures[1] = .{ .start_beat = 1, .duration_beats = 2, .number = 1, .beats = 2, .beat_unit = 4, .repeat = model.measure_repeat_backward, .ending_mask = 1, .ending_flags = model.measure_ending_stop };
    snapshot.measures[1].setRepeatPasses(3);
    snapshot.measure_count = 2;
    snapshot.tempo_base_bpm = 120;
    snapshot.tempos[0] = .{ .start_beat = 0, .bpm = 120 };
    snapshot.tempos[1] = .{ .start_beat = 2, .bpm = 108 };
    snapshot.tempo_count = 2;
    snapshot.parts[0] = .{ .source_index = 0, .midi_program = 1 };
    snapshot.parts[0].setName("Piano");
    snapshot.parts[1] = .{ .source_index = 1, .midi_program = 49 };
    snapshot.parts[1].setName("Strings");
    snapshot.part_count = 2;
    snapshot.view = .{
        .view_start_beat = 18,
        .zoom = 0.65,
        .continuous_pan_fraction = 0.375,
        .tool = .practice,
        .score_view_mode = .continuous,
        .focus_score = 1,
        .keyboard_visible = 0,
        .vocal_guide_visible = 0,
        .pedal_guide_visible = 1,
        .selected_part = 1,
    };
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
    try std.testing.expectEqual(model.slurNumberBit(2) | model.slurNumberBit(4), decoded.notes[0].slur_start_mask);
    try std.testing.expectEqual(@as(u8, 4), model.singleTremoloMarks(decoded.notes[0]));
    try std.testing.expectEqual(model.note_notation_trill | model.note_notation_arpeggiate_up, decoded.notes[0].notations & (model.note_notation_ornament_mask | model.note_notation_arpeggiate_mask));
    try std.testing.expect((decoded.notes[0].flags & model.note_flag_tie_start) != 0);
    try std.testing.expectEqualStrings("sing this", decoded.lyrics[0].textSlice());
    try std.testing.expectEqual(@as(usize, 1), decoded.harmony_count);
    try std.testing.expectEqualStrings("minor-seventh", decoded.harmonies[0].kindSlice());
    try std.testing.expectEqual(@as(i8, -1), decoded.harmonies[0].bass_alter);
    try std.testing.expectEqual(@as(usize, 1), decoded.hairpin_count);
    try std.testing.expectApproxEqAbs(@as(f32, 2.75), decoded.hairpins[0].end_beat, 0.001);
    try std.testing.expectEqual(model.hairpin_flag_above | model.hairpin_flag_niente, decoded.hairpins[0].flags);
    try std.testing.expectEqual(@as(usize, 1), decoded.pedal_count);
    try std.testing.expectEqual(model.pedal_action_start, decoded.pedals[0].action);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), decoded.pedals[0].start_beat, 0.001);
    try std.testing.expectEqual(@as(usize, 2), decoded.measure_count);
    try std.testing.expectEqual(@as(u32, 0), decoded.measures[0].number);
    try std.testing.expectEqual(@as(u8, 1), decoded.measures[0].implicit);
    try std.testing.expectEqual(@as(u8, 2), decoded.measures[1].beats);
    try std.testing.expect(decoded.measures[0].hasForwardRepeat());
    try std.testing.expect(decoded.measures[1].hasBackwardRepeat());
    try std.testing.expectEqual(@as(u8, 3), decoded.measures[1].repeatPasses());
    try std.testing.expectEqual(@as(u16, 1), decoded.measures[0].ending_mask);
    try std.testing.expect(decoded.measures[0].endingStarts());
    try std.testing.expect(decoded.measures[1].endingStops());
    try std.testing.expectEqual(@as(usize, 2), decoded.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 120), decoded.tempo_base_bpm, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 108), decoded.tempos[1].bpm, 0.001);
    try std.testing.expectEqual(@as(usize, 2), decoded.part_count);
    try std.testing.expectEqualStrings("Piano", decoded.parts[0].nameSlice());
    try std.testing.expectEqual(@as(u32, 1), decoded.parts[0].midi_program);
    try std.testing.expectEqualStrings("Strings", decoded.parts[1].nameSlice());
    try std.testing.expectEqual(@as(u32, 49), decoded.parts[1].midi_program);
    try std.testing.expectEqual(@as(usize, 1), decoded.annotations.point_count);
    try std.testing.expect(annotation.isScoreSpace(decoded.annotations.strokes[0]));
    try std.testing.expectEqual(@as(u32, 1), annotation.pageIndex(decoded.annotations.strokes[0]));
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), decoded.annotations.points[0].u, 0.001);
    try std.testing.expectEqual(@as(u32, 0), decoded.transport.metronome_enabled);
    try std.testing.expectApproxEqAbs(@as(f32, 18), decoded.view.view_start_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), decoded.view.zoom, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), decoded.view.continuous_pan_fraction, 0.001);
    try std.testing.expectEqual(model.Tool.practice, decoded.view.tool);
    try std.testing.expectEqual(model.ScoreViewMode.continuous, decoded.view.score_view_mode);
    try std.testing.expectEqual(@as(u32, 1), decoded.view.focus_score);
    try std.testing.expectEqual(@as(u32, 0), decoded.view.keyboard_visible);
    try std.testing.expectEqual(@as(u32, 0), decoded.view.vocal_guide_visible);
    try std.testing.expectEqual(@as(u32, 1), decoded.view.pedal_guide_visible);
    try std.testing.expectEqual(@as(u32, 1), decoded.view.selected_part);
}

test "version 15 native documents migrate without invented slur numbers" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.notes[0] = .{ .stable_id = 3, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = model.note_flag_slur_start, .slur_start_mask = model.slurNumberBit(3) };
    snapshot.note_count = 1;
    var bytes: [4096]u8 = undefined;
    const encoded_len = try encode(snapshot, &bytes);
    var note_start: usize = header_size;
    for (0..2) |_| {
        const text_len: usize = readInt(u32, bytes[note_start .. note_start + 4]);
        note_start += 4 + text_len;
    }
    note_start += 8 + 16 + 16 + 4;
    const notation_start = note_start + 36;
    std.mem.copyForwards(u8, bytes[notation_start .. encoded_len - 4], bytes[notation_start + 4 .. encoded_len]);
    // v19 appended the notation word, v17 an empty part table, v18 an empty
    // hairpin table, and v21 the 40-byte view tail. Remove them for v15.
    const len = encoded_len - 52;
    writeInt(u32, bytes[12..16], @intCast(len - header_size));
    writeInt(u32, bytes[8..12], 15);
    writeInt(u32, bytes[16..20], std.hash.crc.Crc32.hash(bytes[header_size..len]));
    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..len], decoded);
    try std.testing.expectEqual(@as(u8, 0), decoded.notes[0].slur_start_mask);
    try std.testing.expectEqual(@as(u8, 1), model.slurStartMask(decoded.notes[0]));
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

test "version 20 native documents keep default reading preferences" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.measures[0] = .{ .start_beat = 0, .duration_beats = 4, .number = 1, .beats = 4, .beat_unit = 4, .ending_mask = 2, .ending_flags = model.measure_ending_start };
    snapshot.measure_count = 1;
    snapshot.view = .{ .zoom = 0.55, .score_view_mode = .continuous, .keyboard_visible = 0 };
    var bytes: [4096]u8 = undefined;
    const encoded_len = try encode(snapshot, &bytes);
    const legacy_len = encoded_len - 40;
    writeInt(u32, bytes[8..12], 20);
    writeInt(u32, bytes[12..16], @intCast(legacy_len - header_size));
    writeInt(u32, bytes[16..20], std.hash.crc.Crc32.hash(bytes[header_size..legacy_len]));

    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..legacy_len], decoded);
    try std.testing.expectEqual(@as(u16, 2), decoded.measures[0].ending_mask);
    try std.testing.expectEqual(model.ScoreViewMode.paged, decoded.view.score_view_mode);
    try std.testing.expectApproxEqAbs(@as(f32, 1), decoded.view.zoom, 0.001);
    try std.testing.expectEqual(@as(u32, 1), decoded.view.keyboard_visible);
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
    std.mem.copyForwards(u8, bytes[technique_start .. encoded_len - 8], bytes[technique_start + 8 .. encoded_len]);
    // Strip the v15 note-technique quartet, v19 notation word, the empty v17
    // part/v18 hairpin tables, and the v21 40-byte view tail.
    const legacy_len = encoded_len - 56;
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
