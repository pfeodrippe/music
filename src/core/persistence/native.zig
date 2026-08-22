const std = @import("std");
const model = @import("../model.zig");
const annotation = @import("../annotation.zig");
const musicxml = @import("../import/musicxml.zig");
const recording = @import("../recording.zig");

pub const magic = "SCOREAPP";
pub const current_version: u32 = 5;
const header_size = 20;

pub const Snapshot = struct {
    meta: model.DocumentMeta = .{},
    transport: model.Transport = .{},
    notes: [musicxml.max_import_notes]model.Note = undefined,
    note_count: usize = 0,
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
    notation[3] = 0;
    try writer.u32(snapshot.transport.metronome_enabled);

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
    for (snapshot.notes[0..snapshot.note_count]) |*note| note.* = try reader.note();
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
    }
    if (version >= 5) snapshot.transport.metronome_enabled = try reader.u32();
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
        try self.u32(value.selected);
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

    fn note(self: *Reader) Error!model.Note {
        const stable_id = try self.u64();
        const start = try self.f32();
        const duration = try self.f32();
        const quartet = try self.take(4);
        return .{
            .stable_id = stable_id,
            .start_beat = start,
            .duration_beats = duration,
            .pitch = quartet[0],
            .velocity = quartet[1],
            .staff = quartet[2],
            .voice = quartet[3],
            .selected = try self.u32(),
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
    snapshot.transport.tempo_bpm = 84;
    snapshot.transport.metronome_enabled = 0;
    snapshot.notes[0] = .{ .stable_id = 9, .start_beat = 1.5, .duration_beats = 0.5, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0 };
    snapshot.note_count = 1;
    snapshot.annotations.begin(.{ .u = 0.2, .v = 0.3, .pressure = 0.8, .time_ms = 10 }, 1);
    snapshot.annotations.end();
    var bytes: [4096]u8 = undefined;
    const len = try encode(snapshot, &bytes);
    const decoded = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(decoded);
    try decode(bytes[0..len], decoded);
    try std.testing.expectEqualStrings("Round Trip", decoded.meta.titleSlice());
    try std.testing.expectEqual(@as(u8, 64), decoded.notes[0].pitch);
    try std.testing.expectEqual(@as(usize, 1), decoded.annotations.point_count);
    try std.testing.expectEqual(@as(u32, 1), decoded.annotations.strokes[0].page_index);
    try std.testing.expectEqual(@as(u32, 0), decoded.transport.metronome_enabled);
}

test "native document persists synchronized MIDI take metadata" {
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    snapshot.take.reset(1_000);
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
