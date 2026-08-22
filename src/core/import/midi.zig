const std = @import("std");
const model = @import("../model.zig");
const musicxml = @import("musicxml.zig");

pub const MidiReport = struct {
    notes: [musicxml.max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    ticks_per_quarter: u16 = 480,
    tempo_bpm: f32 = 120,
    title: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,

    pub fn titleSlice(self: *const MidiReport) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Error = error{ InvalidMidi, TooManyNotes, UnsupportedTimeDivision };

const Active = struct { tick: u64 = 0, velocity: u8 = 0, active: bool = false };

pub fn parse(source: []const u8) Error!MidiReport {
    if (source.len < 14 or !std.mem.eql(u8, source[0..4], "MThd")) return error.InvalidMidi;
    const header_length = readU32(source, 4) orelse return error.InvalidMidi;
    if (header_length < 6 or 8 + header_length > source.len) return error.InvalidMidi;
    const track_count = readU16(source, 10) orelse return error.InvalidMidi;
    const division = readU16(source, 12) orelse return error.InvalidMidi;
    if ((division & 0x8000) != 0) return error.UnsupportedTimeDivision;

    var report: MidiReport = .{ .ticks_per_quarter = division };
    var active: [16][128]Active = [_][128]Active{[_]Active{.{}} ** 128} ** 16;
    var offset: usize = 8 + header_length;
    var next_stable_id: u64 = 1;
    for (0..track_count) |_| {
        if (offset + 8 > source.len or !std.mem.eql(u8, source[offset .. offset + 4], "MTrk")) return error.InvalidMidi;
        const track_length = readU32(source, offset + 4) orelse return error.InvalidMidi;
        offset += 8;
        if (offset + track_length > source.len) return error.InvalidMidi;
        const end = offset + track_length;
        var tick: u64 = 0;
        var running_status: u8 = 0;
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
                    if (micros != 0) report.tempo_bpm = 60_000_000.0 / @as(f32, @floatFromInt(micros));
                } else if (kind == 0x03 and report.title_len == 0 and length != 0) {
                    report.title_len = @min(report.title.len, @as(usize, @intCast(length)));
                    @memcpy(report.title[0..report.title_len], source[offset .. offset + report.title_len]);
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
            if (message == 0x90 and data2 != 0) {
                active[channel][data1] = .{ .tick = tick, .velocity = data2, .active = true };
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
                    };
                    report.note_count += 1;
                    next_stable_id += 1;
                    active[channel][data1].active = false;
                }
            }
        }
        offset = end;
    }
    if (report.note_count == 0) return error.InvalidMidi;
    std.mem.sort(model.Note, report.notes[0..report.note_count], {}, struct {
        fn lessThan(_: void, left: model.Note, right: model.Note) bool {
            return left.start_beat < right.start_beat or (left.start_beat == right.start_beat and left.pitch < right.pitch);
        }
    }.lessThan);
    return report;
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
