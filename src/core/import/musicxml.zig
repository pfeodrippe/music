const std = @import("std");
const model = @import("../model.zig");

pub const max_import_notes = 4096;

pub const ImportReport = struct {
    notes: [max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    divisions: u32 = 1,
    tempo_bpm: f32 = 72,
    title: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,
    creator: [96]u8 = [_]u8{0} ** 96,
    creator_len: usize = 0,
    skipped_notes: u32 = 0,
    approximations: u32 = 0,
    beats_per_measure: u8 = 4,
    beat_unit: u8 = 4,
    key_fifths: i8 = 0,

    pub fn titleSlice(self: *const ImportReport) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn creatorSlice(self: *const ImportReport) []const u8 {
        return self.creator[0..self.creator_len];
    }
};

pub const Error = error{
    InvalidMusicXml,
    TooManyNotes,
    InvalidNumber,
};

/// Allocation-free MusicXML importer for the semantic subset used by the
/// engine today. Unknown elements stay in the original source blob owned by
/// persistence; the report makes approximations explicit.
pub fn parse(source: []const u8) Error!ImportReport {
    if (std.mem.indexOf(u8, source, "<score-partwise") == null) return error.InvalidMusicXml;
    var report: ImportReport = .{};
    if (tagContent(source, "work-title") orelse tagContent(source, "movement-title")) |title| copyText(&report.title, &report.title_len, title);
    if (creatorContent(source)) |creator| copyText(&report.creator, &report.creator_len, creator);
    if (tagContent(source, "divisions")) |value| report.divisions = @max(1, try parseUnsigned(value));
    if (tempoFromSound(source)) |tempo| report.tempo_bpm = tempo;
    if (tagContent(source, "beats")) |value| report.beats_per_measure = @intCast(@min(32, try parseUnsigned(value)));
    if (tagContent(source, "beat-type")) |value| report.beat_unit = @intCast(@min(32, try parseUnsigned(value)));
    if (tagContent(source, "fifths")) |value| report.key_fifths = @intCast(std.math.clamp(try parseSigned(value), -7, 7));
    if (std.mem.indexOf(u8, source, "<tuplet") != null or std.mem.indexOf(u8, source, "<time-modification") != null) report.approximations += 1;
    if (std.mem.indexOf(u8, source, "<ornaments") != null) report.approximations += 1;

    var stable_id: u64 = 1;
    var part_cursor: usize = 0;
    var part_index: u32 = 0;
    while (findOpenTag(source, part_cursor, "part")) |part_start| {
        const part_open_end = std.mem.indexOfPos(u8, source, part_start, ">") orelse return error.InvalidMusicXml;
        const part_end = std.mem.indexOfPos(u8, source, part_open_end, "</part>") orelse return error.InvalidMusicXml;
        try parsePart(source[part_open_end + 1 .. part_end], &report, part_index, &stable_id);
        part_cursor = part_end + "</part>".len;
        part_index += 1;
    }
    if (report.note_count == 0) return error.InvalidMusicXml;
    std.mem.sort(model.Note, report.notes[0..report.note_count], {}, struct {
        fn lessThan(_: void, left: model.Note, right: model.Note) bool {
            return left.start_beat < right.start_beat or (left.start_beat == right.start_beat and left.pitch < right.pitch);
        }
    }.lessThan);
    return report;
}

fn parsePart(source: []const u8, report: *ImportReport, part_index: u32, stable_id: *u64) Error!void {
    var measure_cursor: usize = 0;
    var measure_start: f32 = 0;
    while (findOpenTag(source, measure_cursor, "measure")) |measure_open| {
        const open_end = std.mem.indexOfPos(u8, source, measure_open, ">") orelse return error.InvalidMusicXml;
        const measure_end = std.mem.indexOfPos(u8, source, open_end, "</measure>") orelse return error.InvalidMusicXml;
        const extent = try parseMeasure(source[open_end + 1 .. measure_end], report, measure_start, part_index, stable_id);
        measure_start += @max(extent, 0.0625);
        measure_cursor = measure_end + "</measure>".len;
    }
}

fn parseMeasure(source: []const u8, report: *ImportReport, measure_start: f32, part_index: u32, stable_id: *u64) Error!f32 {
    var divisions = report.divisions;
    if (tagContent(source, "divisions")) |value| {
        divisions = @max(1, try parseUnsigned(value));
        report.divisions = divisions;
    }
    const unitsToBeats = struct {
        fn convert(units: u32, divisor: u32) f32 {
            return @as(f32, @floatFromInt(units)) / @as(f32, @floatFromInt(divisor));
        }
    }.convert;

    var cursor: usize = 0;
    var local_beat: f32 = 0;
    var extent: f32 = 0;
    var previous_start: f32 = 0;
    while (cursor < source.len) {
        const next_note = findOpenTag(source, cursor, "note");
        const next_backup = findOpenTag(source, cursor, "backup");
        const next_forward = findOpenTag(source, cursor, "forward");
        const next = smallestPosition(next_note, next_backup, next_forward) orelse break;
        if (next_backup != null and next == next_backup.?) {
            const end = std.mem.indexOfPos(u8, source, next, "</backup>") orelse return error.InvalidMusicXml;
            const block = source[next..end];
            const units = if (tagContent(block, "duration")) |value| try parseUnsigned(value) else 0;
            local_beat = @max(0, local_beat - unitsToBeats(units, divisions));
            cursor = end + "</backup>".len;
            continue;
        }
        if (next_forward != null and next == next_forward.?) {
            const end = std.mem.indexOfPos(u8, source, next, "</forward>") orelse return error.InvalidMusicXml;
            const block = source[next..end];
            const units = if (tagContent(block, "duration")) |value| try parseUnsigned(value) else 0;
            local_beat += unitsToBeats(units, divisions);
            extent = @max(extent, local_beat);
            cursor = end + "</forward>".len;
            continue;
        }

        const open_end = std.mem.indexOfPos(u8, source, next, ">") orelse return error.InvalidMusicXml;
        const end = std.mem.indexOfPos(u8, source, open_end, "</note>") orelse return error.InvalidMusicXml;
        const block = source[open_end + 1 .. end];
        cursor = end + "</note>".len;
        const duration_units = if (tagContent(block, "duration")) |duration| try parseUnsigned(duration) else 0;
        const duration = unitsToBeats(duration_units, divisions);
        const chord = findOpenTag(block, 0, "chord") != null;
        const grace = findOpenTag(block, 0, "grace") != null;
        const rest = findOpenTag(block, 0, "rest") != null;
        const start_beat = if (chord) previous_start else local_beat;

        if (!rest) {
            const step_text = tagContent(block, "step") orelse {
                report.skipped_notes += 1;
                if (!chord and !grace) local_beat += duration;
                continue;
            };
            const octave_text = tagContent(block, "octave") orelse {
                report.skipped_notes += 1;
                if (!chord and !grace) local_beat += duration;
                continue;
            };
            const octave = try parseSigned(octave_text);
            const alter = if (tagContent(block, "alter")) |value| try parseSigned(value) else 0;
            const semitone = stepToSemitone(step_text[0]) orelse {
                report.skipped_notes += 1;
                continue;
            };
            const midi_wide = (octave + 1) * 12 + semitone + alter;
            if (midi_wide < 0 or midi_wide > 127) {
                report.skipped_notes += 1;
            } else {
                if (report.note_count == report.notes.len) return error.TooManyNotes;
                const staff_value = if (tagContent(block, "staff")) |value| try parseUnsigned(value) else 1;
                const voice_value = if (tagContent(block, "voice")) |value| try parseUnsigned(value) else 1;
                report.notes[report.note_count] = .{
                    .stable_id = stable_id.*,
                    .start_beat = measure_start + start_beat,
                    .duration_beats = if (grace) 0.125 else @max(duration, 0.0625),
                    .pitch = @intCast(midi_wide),
                    .velocity = 88,
                    .staff = @intCast(@min(part_index * 8 + staff_value -| 1, 255)),
                    .voice = @intCast(@min(voice_value -| 1, 255)),
                };
                report.note_count += 1;
                stable_id.* += 1;
                if (grace) report.approximations += 1;
            }
        }
        previous_start = start_beat;
        extent = @max(extent, start_beat + duration);
        if (!chord and !grace) local_beat += duration;
    }
    return @max(extent, local_beat);
}

fn smallestPosition(a: ?usize, b: ?usize, c: ?usize) ?usize {
    var result: ?usize = null;
    for ([_]?usize{ a, b, c }) |candidate| {
        if (candidate) |value| result = if (result) |current| @min(current, value) else value;
    }
    return result;
}

fn findOpenTag(source: []const u8, start: usize, comptime tag: []const u8) ?usize {
    const needle = "<" ++ tag;
    var cursor = start;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |position| {
        const after = position + needle.len;
        if (after < source.len and (source[after] == '>' or source[after] == '/' or std.ascii.isWhitespace(source[after]))) return position;
        cursor = after;
    }
    return null;
}

fn tagContent(source: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    const start = std.mem.indexOf(u8, source, open) orelse return null;
    const content_start = start + open.len;
    const end = std.mem.indexOfPos(u8, source, content_start, close) orelse return null;
    return std.mem.trim(u8, source[content_start..end], " \t\r\n");
}

fn creatorContent(source: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "<creator")) |start| {
        const open_end = std.mem.indexOfPos(u8, source, start, ">") orelse return null;
        const close = std.mem.indexOfPos(u8, source, open_end, "</creator>") orelse return null;
        const opening = source[start..open_end];
        if (std.mem.indexOf(u8, opening, "composer") != null) return std.mem.trim(u8, source[open_end + 1 .. close], " \t\r\n");
        cursor = close + 1;
    }
    return null;
}

fn tempoFromSound(source: []const u8) ?f32 {
    const marker = "tempo=\"";
    const start = std.mem.indexOf(u8, source, marker) orelse return null;
    const value_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, source, value_start, "\"") orelse return null;
    return std.fmt.parseFloat(f32, source[value_start..end]) catch null;
}

fn copyText(destination: []u8, length: *usize, source: []const u8) void {
    length.* = @min(destination.len, source.len);
    @memcpy(destination[0..length.*], source[0..length.*]);
}

fn parseUnsigned(source: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, source, " \t\r\n"), 10) catch error.InvalidNumber;
}

fn parseSigned(source: []const u8) Error!i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, source, " \t\r\n"), 10) catch error.InvalidNumber;
}

fn stepToSemitone(step: u8) ?i32 {
    return switch (step) {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        else => null,
    };
}

test "imports a generated MusicXML melody with chords and rests" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<score-partwise version="4.0">
        \\<work><work-title>Generated Study</work-title></work>
        \\<identification><creator type="composer">Score Tests</creator></identification>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>2</divisions></attributes>
        \\<direction><sound tempo="84"/></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice><staff>1</staff></note>
        \\<note><chord/><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration></note>
        \\<note><rest/><duration>1</duration></note>
        \\<note><pitch><step>G</step><alter>1</alter><octave>4</octave></pitch><duration>1</duration></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 3), report.note_count);
    try std.testing.expectEqual(@as(u8, 60), report.notes[0].pitch);
    try std.testing.expectEqual(@as(u8, 64), report.notes[1].pitch);
    try std.testing.expectEqual(@as(u8, 68), report.notes[2].pitch);
    try std.testing.expectEqual(@as(f32, 0), report.notes[1].start_beat);
    try std.testing.expectEqualStrings("Generated Study", report.titleSlice());
}

test "MusicXML backup voices and multiple parts share musical time" {
    const fixture =
        \\<score-partwise version="4.0"><part-list>
        \\<score-part id="P1"><part-name>Right</part-name></score-part>
        \\<score-part id="P2"><part-name>Left</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice></note>
        \\<backup><duration>2</duration></backup>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration><voice>2</voice></note>
        \\</measure></part>
        \\<part id="P2"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>3</octave></pitch><duration>2</duration><staff>2</staff></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 3), report.note_count);
    try std.testing.expectEqual(@as(f32, 0), report.notes[0].start_beat);
    try std.testing.expectEqual(@as(f32, 0), report.notes[1].start_beat);
    try std.testing.expectEqual(@as(f32, 0), report.notes[2].start_beat);
    var found_second_part = false;
    for (report.notes[0..report.note_count]) |note| found_second_part = found_second_part or note.staff >= 8;
    try std.testing.expect(found_second_part);
}
