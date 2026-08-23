const std = @import("std");
const model = @import("../model.zig");
const musicxml = @import("musicxml.zig");

pub const MidiReport = struct {
    notes: [musicxml.max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    pedals: [musicxml.max_import_pedals]model.PedalEvent = undefined,
    pedal_count: usize = 0,
    ticks_per_quarter: u16 = 480,
    tempo_bpm: f32 = 120,
    tempos: [model.max_tempo_events]model.TempoEvent = undefined,
    tempo_count: usize = 0,
    beats_per_measure: u8 = 4,
    beat_unit: u8 = 4,
    key_fifths: i8 = 0,
    title: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,

    pub fn titleSlice(self: *const MidiReport) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Error = error{ InvalidMidi, TooManyNotes, TooManyPedals, TooManyTempos, UnsupportedTimeDivision };

const Active = struct { tick: u64 = 0, velocity: u8 = 0, flags: u32 = 0, active: bool = false };
const RawPedal = struct {
    tick: u64,
    sequence: u32,
    pedal: u8,
    value: u8,
};

pub fn parse(source: []const u8) Error!MidiReport {
    if (source.len < 14 or !std.mem.eql(u8, source[0..4], "MThd")) return error.InvalidMidi;
    const header_length = readU32(source, 4) orelse return error.InvalidMidi;
    if (header_length < 6 or 8 + header_length > source.len) return error.InvalidMidi;
    const track_count = readU16(source, 10) orelse return error.InvalidMidi;
    const division = readU16(source, 12) orelse return error.InvalidMidi;
    if ((division & 0x8000) != 0) return error.UnsupportedTimeDivision;

    var report: MidiReport = .{ .ticks_per_quarter = division };
    var raw_pedals: [musicxml.max_import_pedals]RawPedal = undefined;
    var raw_pedal_count: usize = 0;
    var event_sequence: u32 = 0;
    var offset: usize = 8 + header_length;
    var next_stable_id: u64 = 1;
    for (0..track_count) |_| {
        // Standard MIDI tracks have independent delta-time streams. Keeping
        // note lifetimes track-local prevents an unterminated note in one
        // Type-1 track from consuming a note-off in another track that happens
        // to use the same channel and pitch.
        var active: [16][128]Active = [_][128]Active{[_]Active{.{}} ** 128} ** 16;
        if (offset + 8 > source.len or !std.mem.eql(u8, source[offset .. offset + 4], "MTrk")) return error.InvalidMidi;
        const track_length = readU32(source, offset + 4) orelse return error.InvalidMidi;
        offset += 8;
        if (offset + track_length > source.len) return error.InvalidMidi;
        const end = offset + track_length;
        var tick: u64 = 0;
        var running_status: u8 = 0;
        var track_vocal_guide = false;
        while (offset < end) {
            const delta = readVariable(source, &offset, end) orelse return error.InvalidMidi;
            tick += delta;
            if (offset >= end) return error.InvalidMidi;
            var status = source[offset];
            if ((status & 0x80) != 0) {
                offset += 1;
                running_status = status;
            } else {
                if (running_status == 0) return error.InvalidMidi;
                status = running_status;
            }
            if (status == 0xff) {
                running_status = 0;
                if (offset >= end) return error.InvalidMidi;
                const kind = source[offset];
                offset += 1;
                const length = readVariable(source, &offset, end) orelse return error.InvalidMidi;
                if (offset + length > end) return error.InvalidMidi;
                if (kind == 0x51 and length == 3) {
                    const micros = (@as(u32, source[offset]) << 16) | (@as(u32, source[offset + 1]) << 8) | source[offset + 2];
                    if (micros != 0) {
                        const bpm = 60_000_000.0 / @as(f32, @floatFromInt(micros));
                        const start_beat = @as(f32, @floatFromInt(tick)) / @as(f32, @floatFromInt(division));
                        var replaced = false;
                        for (report.tempos[0..report.tempo_count]) |*tempo| {
                            if (@abs(tempo.start_beat - start_beat) <= 0.0001) {
                                tempo.bpm = bpm;
                                replaced = true;
                                break;
                            }
                        }
                        if (!replaced) {
                            if (report.tempo_count == report.tempos.len) return error.TooManyTempos;
                            report.tempos[report.tempo_count] = .{ .start_beat = start_beat, .bpm = bpm };
                            report.tempo_count += 1;
                        }
                        if (report.tempo_count == 1 or start_beat <= 0.0001) report.tempo_bpm = bpm;
                    }
                } else if (kind == 0x03 and length != 0) {
                    const track_name = source[offset .. offset + @as(usize, @intCast(length))];
                    track_vocal_guide = containsIgnoreCase(track_name, "vocal");
                    if (report.title_len == 0) {
                        report.title_len = @min(report.title.len, track_name.len);
                        @memcpy(report.title[0..report.title_len], track_name[0..report.title_len]);
                    }
                } else if (kind == 0x58 and length == 4) {
                    report.beats_per_measure = @max(1, source[offset]);
                    if (source[offset + 1] <= 5) report.beat_unit = @as(u8, 1) << @intCast(source[offset + 1]);
                } else if (kind == 0x59 and length == 2) {
                    const fifths: i8 = @bitCast(source[offset]);
                    report.key_fifths = std.math.clamp(fifths, -7, 7);
                }
                offset += @intCast(length);
                continue;
            }
            if (status == 0xf0 or status == 0xf7) {
                running_status = 0;
                const length = readVariable(source, &offset, end) orelse return error.InvalidMidi;
                if (offset + length > end) return error.InvalidMidi;
                offset += @intCast(length);
                continue;
            }
            const message = status & 0xf0;
            const channel = status & 0x0f;
            const data_len: usize = if (message == 0xc0 or message == 0xd0) 1 else 2;
            if (offset + data_len > end) return error.InvalidMidi;
            const data1 = source[offset];
            const data2: u8 = if (data_len == 2) source[offset + 1] else 0;
            offset += data_len;
            if (data1 >= 0x80 or (data_len == 2 and data2 >= 0x80)) return error.InvalidMidi;
            event_sequence +%= 1;
            if (message == 0x90 and data2 != 0) {
                active[channel][data1] = .{ .tick = tick, .velocity = data2, .flags = if (track_vocal_guide) model.note_flag_vocal_guide else 0, .active = true };
            } else if (message == 0x80 or (message == 0x90 and data2 == 0)) {
                const started = active[channel][data1];
                if (started.active and tick >= started.tick) {
                    if (report.note_count == report.notes.len) return error.TooManyNotes;
                    report.notes[report.note_count] = .{
                        .stable_id = next_stable_id,
                        .start_beat = @as(f32, @floatFromInt(started.tick)) / @as(f32, @floatFromInt(division)),
                        .duration_beats = @max(@as(f32, @floatFromInt(tick - started.tick)) / @as(f32, @floatFromInt(division)), 0.0625),
                        .pitch = data1,
                        .velocity = started.velocity,
                        .staff = if (data1 < 60) 1 else 0,
                        .voice = channel,
                        .flags = started.flags,
                    };
                    report.note_count += 1;
                    next_stable_id += 1;
                    active[channel][data1].active = false;
                }
            } else if (message == 0xb0) {
                const pedal: ?u8 = switch (data1) {
                    64 => model.pedal_sustain,
                    66 => model.pedal_sostenuto,
                    67 => model.pedal_soft,
                    else => null,
                };
                if (pedal) |kind| {
                    if (raw_pedal_count == raw_pedals.len) return error.TooManyPedals;
                    raw_pedals[raw_pedal_count] = .{ .tick = tick, .sequence = event_sequence, .pedal = kind, .value = data2 };
                    raw_pedal_count += 1;
                }
            }
        }
        offset = end;
    }
    if (report.note_count == 0) return error.InvalidMidi;
    if (report.tempo_count == 0) {
        report.tempos[0] = .{ .start_beat = 0, .bpm = report.tempo_bpm };
        report.tempo_count = 1;
    }
    std.mem.sort(model.TempoEvent, report.tempos[0..report.tempo_count], {}, struct {
        fn lessThan(_: void, left: model.TempoEvent, right: model.TempoEvent) bool {
            return left.start_beat < right.start_beat;
        }
    }.lessThan);
    std.mem.sort(model.Note, report.notes[0..report.note_count], {}, struct {
        fn lessThan(_: void, left: model.Note, right: model.Note) bool {
            return left.start_beat < right.start_beat or (left.start_beat == right.start_beat and left.pitch < right.pitch);
        }
    }.lessThan);
    std.mem.sort(RawPedal, raw_pedals[0..raw_pedal_count], {}, struct {
        fn lessThan(_: void, left: RawPedal, right: RawPedal) bool {
            return left.tick < right.tick or (left.tick == right.tick and left.sequence < right.sequence);
        }
    }.lessThan);
    var previous = [_]u8{0} ** 3;
    for (raw_pedals[0..raw_pedal_count]) |raw| {
        const before = previous[raw.pedal];
        const was_down = before >= 64;
        const is_down = raw.value >= 64;
        const action: u8 = if (!was_down and is_down)
            model.pedal_action_start
        else if (was_down and !is_down)
            model.pedal_action_stop
        else
            model.pedal_action_change;
        report.pedals[report.pedal_count] = .{
            .start_beat = @as(f32, @floatFromInt(raw.tick)) / @as(f32, @floatFromInt(division)),
            .pedal = raw.pedal,
            .value = raw.value,
            .action = action,
            .flags = model.pedal_flag_line,
        };
        report.pedal_count += 1;
        previous[raw.pedal] = raw.value;
    }
    return report;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn readU16(source: []const u8, offset: usize) ?u16 {
    if (offset + 2 > source.len) return null;
    return (@as(u16, source[offset]) << 8) | source[offset + 1];
}

fn readU32(source: []const u8, offset: usize) ?u32 {
    if (offset + 4 > source.len) return null;
    return (@as(u32, source[offset]) << 24) | (@as(u32, source[offset + 1]) << 16) | (@as(u32, source[offset + 2]) << 8) | source[offset + 3];
}

fn readVariable(source: []const u8, offset: *usize, end: usize) ?u64 {
    var value: u64 = 0;
    for (0..4) |_| {
        if (offset.* >= end or offset.* >= source.len) return null;
        const byte = source[offset.*];
        offset.* += 1;
        value = (value << 7) | (byte & 0x7f);
        if ((byte & 0x80) == 0) return value;
    }
    return null;
}

test "imports a minimal type-0 MIDI track" {
    const fixture = [_]u8{
        'M',  'T',  'h',  'd', 0,   0,    0,    6,    0,    0,    0,    1,    1,    0xe0,
        'M',  'T',  'r',  'k', 0,   0,    0,    20,   0x00, 0xff, 0x51, 0x03, 0x07, 0xa1,
        0x20, 0x00, 0x90, 60,  100, 0x83, 0x60, 0x80, 60,   0,    0x00, 0xff, 0x2f, 0x00,
    };
    const report = try parse(&fixture);
    try std.testing.expectEqual(@as(usize, 1), report.note_count);
    try std.testing.expectEqual(@as(u8, 60), report.notes[0].pitch);
    try std.testing.expectApproxEqAbs(@as(f32, 1), report.notes[0].duration_beats, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 120), report.tempo_bpm, 0.01);
}

test "imports ordered continuous three-pedal MIDI automation" {
    const fixture = [_]u8{
        'M',  'T',  'h',  'd',  0,    0,    0,    6,    0,    0,    0,    1,    1,    0xe0,
        'M',  'T',  'r',  'k',  0,    0,    0,    42,   0x00, 0xb0, 64,   127,  0x00, 0xb0,
        66,   96,   0x00, 0xb0, 67,   80,   0x00, 0x90, 60,   100,  0x81, 0x70, 0xb0, 64,
        32,   0x00, 0xb0, 64,   0,    0x00, 0xb0, 66,   0,    0x00, 0xb0, 67,   0,    0x81,
        0x70, 0x80, 60,   0,    0x00, 0xff, 0x2f, 0x00,
    };
    const report = try parse(&fixture);
    try std.testing.expectEqual(@as(usize, 7), report.pedal_count);
    try std.testing.expectEqual(model.pedal_sustain, report.pedals[0].pedal);
    try std.testing.expectEqual(model.pedal_action_start, report.pedals[0].action);
    try std.testing.expectEqual(model.pedal_sostenuto, report.pedals[1].pedal);
    try std.testing.expectEqual(model.pedal_soft, report.pedals[2].pedal);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), report.pedals[3].start_beat, 0.001);
    try std.testing.expectEqual(@as(u8, 32), report.pedals[3].value);
    try std.testing.expectEqual(model.pedal_action_stop, report.pedals[3].action);
    try std.testing.expectEqual(model.pedal_action_change, report.pedals[4].action);
}

test "type-1 tracks cannot close each other's active notes" {
    const fixture = [_]u8{
        'M',  'T',  'h', 'd', 0,   0,    0,    6, 0, 1,    0,  2,    1,  0xe0,
        'M',  'T',  'r', 'k', 0,   0,    0,    8, 0, 0x90, 60, 90,   0,  0xff,
        0x2f, 0,    'M', 'T', 'r', 'k',  0,    0, 0, 12,   0,  0x90, 60, 100,
        0x78, 0x80, 60,  0,   0,   0xff, 0x2f, 0,
    };
    const report = try parse(&fixture);
    try std.testing.expectEqual(@as(usize, 1), report.note_count);
    try std.testing.expectEqual(@as(u8, 100), report.notes[0].velocity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), report.notes[0].duration_beats, 0.001);
}

test "rejects malformed channel data bytes before table indexing" {
    const fixture = [_]u8{
        'M',  'T', 'h', 'd', 0, 0, 0, 6, 0, 0,    0,    1,  1, 0xe0,
        'M',  'T', 'r', 'k', 0, 0, 0, 8, 0, 0x90, 0xff, 90, 0, 0xff,
        0x2f, 0,
    };
    try std.testing.expectError(error.InvalidMidi, parse(&fixture));
}
