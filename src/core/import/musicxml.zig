const std = @import("std");
const model = @import("../model.zig");

pub const max_import_notes = 4096;
pub const max_import_lyrics = 1024;
pub const max_import_harmonies = 1024;
pub const max_import_pedals = 2048;
pub const max_import_measures = 2048;
pub const max_import_tempos = model.max_tempo_events;

pub const ImportReport = struct {
    notes: [max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    lyrics: [max_import_lyrics]model.Lyric = undefined,
    lyric_count: usize = 0,
    harmonies: [max_import_harmonies]model.Harmony = undefined,
    harmony_count: usize = 0,
    pedals: [max_import_pedals]model.PedalEvent = undefined,
    pedal_count: usize = 0,
    measures: [max_import_measures]model.Measure = undefined,
    measure_count: usize = 0,
    tempos: [max_import_tempos]model.TempoEvent = undefined,
    tempo_count: usize = 0,
    divisions: u32 = 1,
    /// Human-facing metronome pulse. Tempo events below remain quarter-note
    /// rates so transport and MIDI timing have one canonical unit.
    tempo_bpm: f32 = 72,
    tempo_beat_unit: u8 = 4,
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
    TooManyHarmonies,
    TooManyPedals,
    TooManyMeasures,
    TooManyTempos,
    InvalidNumber,
};

/// Allocation-free MusicXML importer for the semantic subset used by the
/// engine today. Unknown elements stay in the original source blob owned by
/// persistence; the report makes approximations explicit.
pub fn parse(source: []const u8) Error!ImportReport {
    var report: ImportReport = undefined;
    try parseInto(source, &report);
    return report;
}

/// Parses into caller-owned storage so tools can keep the fixed-capacity
/// report off their Debug stacks.
pub fn parseInto(source: []const u8, report: *ImportReport) Error!void {
    if (std.mem.indexOf(u8, source, "<score-partwise") == null) return error.InvalidMusicXml;
    report.* = .{};
    if (tagContent(source, "work-title") orelse tagContent(source, "movement-title") orelse nthOpenTagContent(source, "credit-words", 0)) |title| copyText(&report.title, &report.title_len, title);
    if (creatorContent(source) orelse nthOpenTagContent(source, "credit-words", 1)) |creator| copyText(&report.creator, &report.creator_len, creator);
    if (tagContent(source, "divisions")) |value| report.divisions = @max(1, try parseUnsigned(value));
    if (tagContent(source, "beats")) |value| report.beats_per_measure = @intCast(@min(32, try parseUnsigned(value)));
    if (tagContent(source, "beat-type")) |value| report.beat_unit = @intCast(@min(32, try parseUnsigned(value)));
    if (tagContent(source, "fifths")) |value| report.key_fifths = @intCast(std.math.clamp(try parseSigned(value), -7, 7));
    if (std.mem.indexOf(u8, source, "<ornaments") != null) report.approximations += 1;

    var stable_id: u64 = 1;
    var part_cursor: usize = 0;
    var part_index: u32 = 0;
    while (findOpenTag(source, part_cursor, "part")) |part_start| {
        const part_open_end = std.mem.indexOfPos(u8, source, part_start, ">") orelse return error.InvalidMusicXml;
        const part_end = std.mem.indexOfPos(u8, source, part_open_end, "</part>") orelse return error.InvalidMusicXml;
        try parsePart(source[part_open_end + 1 .. part_end], report, part_index, partIsVocalGuide(source, part_index), &stable_id);
        part_cursor = part_end + "</part>".len;
        part_index += 1;
    }
    if (report.tempo_count == 0) try appendTempo(report, 0, model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit));
    std.mem.sort(model.TempoEvent, report.tempos[0..report.tempo_count], {}, struct {
        fn lessThan(_: void, left: model.TempoEvent, right: model.TempoEvent) bool {
            return left.start_beat < right.start_beat;
        }
    }.lessThan);
    if (report.note_count == 0) return error.InvalidMusicXml;
    std.mem.sort(model.Note, report.notes[0..report.note_count], {}, struct {
        fn lessThan(_: void, left: model.Note, right: model.Note) bool {
            return left.start_beat < right.start_beat or (left.start_beat == right.start_beat and left.pitch < right.pitch);
        }
    }.lessThan);
    std.mem.sort(model.PedalEvent, report.pedals[0..report.pedal_count], {}, struct {
        fn lessThan(_: void, left: model.PedalEvent, right: model.PedalEvent) bool {
            return left.start_beat < right.start_beat or (left.start_beat == right.start_beat and left.action < right.action);
        }
    }.lessThan);
}

fn parsePart(source: []const u8, report: *ImportReport, part_index: u32, vocal_guide: bool, stable_id: *u64) Error!void {
    var measure_cursor: usize = 0;
    var measure_start: f32 = 0;
    var beats: u32 = report.beats_per_measure;
    var beat_unit: u32 = report.beat_unit;
    var current_dynamic: u8 = 0;
    while (findOpenTag(source, measure_cursor, "measure")) |measure_open| {
        const open_end = std.mem.indexOfPos(u8, source, measure_open, ">") orelse return error.InvalidMusicXml;
        const measure_end = std.mem.indexOfPos(u8, source, open_end, "</measure>") orelse return error.InvalidMusicXml;
        const opening = source[measure_open .. open_end + 1];
        const body = source[open_end + 1 .. measure_end];
        if (tagContent(body, "beats")) |value| beats = @max(1, try parseUnsigned(value));
        if (tagContent(body, "beat-type")) |value| beat_unit = @max(1, try parseUnsigned(value));
        const extent = try parseMeasure(body, report, measure_start, part_index, vocal_guide, stable_id, &current_dynamic);
        // A regular MusicXML measure occupies its declared metrical duration.
        // Advancing by recognized note extent makes one missing OMR rest shift
        // every later bar and desynchronize parts. Explicit implicit measures
        // (normally pickups) intentionally occupy only their encoded extent.
        const nominal_beats = @as(f32, @floatFromInt(beats * 4)) / @as(f32, @floatFromInt(beat_unit));
        const implicit = std.mem.indexOf(u8, opening, "implicit=\"yes\"") != null;
        const duration_beats = if (implicit) @max(extent, 0.0625) else @max(nominal_beats, 0.0625);
        if (part_index == 0) {
            if (report.measure_count == report.measures.len) return error.TooManyMeasures;
            const sequential_number: u32 = @intCast(report.measure_count + 1);
            const number = if (attributeValue(opening, "number")) |value| parseUnsigned(value) catch sequential_number else sequential_number;
            report.measures[report.measure_count] = .{
                .start_beat = measure_start,
                .duration_beats = duration_beats,
                .number = number,
                .beats = @intCast(@min(255, beats)),
                .beat_unit = @intCast(@min(255, beat_unit)),
                .implicit = @intFromBool(implicit),
            };
            report.measure_count += 1;
        }
        measure_start += duration_beats;
        measure_cursor = measure_end + "</measure>".len;
    }
}

fn parseMeasure(source: []const u8, report: *ImportReport, measure_start: f32, part_index: u32, vocal_guide: bool, stable_id: *u64, current_dynamic: *u8) Error!f32 {
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

    // Some engraving tools duplicate a sung phrase as both direction words
    // and per-note `<lyric>` syllables. The per-note events carry the precise
    // timing; importing both draws the same sentence twice in one lyric lane.
    // Direction words remain a useful fallback for lead sheets that have no
    // semantic lyric elements in this measure.
    if (findOpenTag(source, 0, "lyric") == null) try parseDirectionLyrics(source, report, measure_start, divisions);

    var cursor: usize = 0;
    var local_beat: f32 = 0;
    var extent: f32 = 0;
    var previous_start: f32 = 0;
    var pending_dynamic: u8 = 0;
    while (cursor < source.len) {
        const next_note = findOpenTag(source, cursor, "note");
        const next_backup = findOpenTag(source, cursor, "backup");
        const next_forward = findOpenTag(source, cursor, "forward");
        const next_harmony = findOpenTag(source, cursor, "harmony");
        const next_direction = findOpenTag(source, cursor, "direction");
        const next = smallestPosition(next_note, next_backup, next_forward, next_harmony, next_direction) orelse break;
        if (next_direction != null and next == next_direction.?) {
            const end = std.mem.indexOfPos(u8, source, next, "</direction>") orelse return error.InvalidMusicXml;
            const block = source[next..end];
            if (dynamicFromDirection(block)) |dynamic_code| {
                current_dynamic.* = dynamic_code;
                pending_dynamic = dynamic_code;
            }
            if (findOpenTag(block, 0, "pedal") != null) {
                const offset_units = if (tagContent(block, "offset")) |value| try parseSigned(value) else 0;
                const offset_beats = @as(f32, @floatFromInt(offset_units)) / @as(f32, @floatFromInt(divisions));
                try appendPedal(report, @max(0, measure_start + local_beat + offset_beats), block);
            }
            if (part_index == 0) {
                if (tempoFromDirection(block)) |tempo| {
                    const offset_units = if (tagContent(block, "offset")) |value| try parseSigned(value) else 0;
                    const offset_beats = @as(f32, @floatFromInt(offset_units)) / @as(f32, @floatFromInt(divisions));
                    const start_beat = @max(0, measure_start + local_beat + offset_beats);
                    try appendTempo(report, start_beat, tempo.quarter_bpm);
                    if (report.tempo_count == 1 or start_beat <= 0.0001) {
                        report.tempo_bpm = tempo.pulse_bpm;
                        report.tempo_beat_unit = tempo.beat_unit;
                    }
                }
            }
            cursor = end + "</direction>".len;
            continue;
        }
        if (next_backup != null and next == next_backup.?) {
            const end = std.mem.indexOfPos(u8, source, next, "</backup>") orelse return error.InvalidMusicXml;
            const block = source[next..end];
            const units = if (tagContent(block, "duration")) |value| try parseUnsigned(value) else 0;
            local_beat = @max(0, local_beat - unitsToBeats(units, divisions));
            cursor = end + "</backup>".len;
            continue;
        }
        if (next_harmony != null and next == next_harmony.?) {
            const open_end = std.mem.indexOfPos(u8, source, next, ">") orelse return error.InvalidMusicXml;
            const end = std.mem.indexOfPos(u8, source, open_end, "</harmony>") orelse return error.InvalidMusicXml;
            try appendHarmony(report, measure_start + local_beat, source[next .. end + "</harmony>".len], divisions);
            cursor = end + "</harmony>".len;
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
        const staff_value = if (tagContent(block, "staff")) |value| try parseUnsigned(value) else 1;
        const voice_value = if (tagContent(block, "voice")) |value| try parseUnsigned(value) else 1;
        const stored_staff: u8 = @intCast(@min(part_index * 8 + staff_value -| 1, 255));
        const stored_voice: u8 = @intCast(@min(voice_value -| 1, 255));

        if (rest) {
            if (report.note_count == report.notes.len) return error.TooManyNotes;
            var rest_step: u8 = 0;
            var rest_octave: i8 = -1;
            if (tagContent(block, "display-step")) |value| rest_step = std.ascii.toUpper(value[0]);
            if (tagContent(block, "display-octave")) |value| rest_octave = @intCast(std.math.clamp(try parseSigned(value), -1, 9));
            report.notes[report.note_count] = .{
                .stable_id = stable_id.*,
                .start_beat = measure_start + start_beat,
                .duration_beats = @max(duration, 0.0625),
                .pitch = if ((stored_staff & 1) == 0) 71 else 50,
                .velocity = 0,
                .staff = stored_staff,
                .voice = stored_voice,
                .written_step = rest_step,
                .written_octave = rest_octave,
                .dots = countOpenTags(block, "dot", 3),
                .flags = notationFlags(block, vocal_guide) | model.note_flag_rest | if (std.mem.indexOf(u8, block, "<rest measure=\"yes\"") != null) model.note_flag_measure_rest else 0,
            };
            report.note_count += 1;
            stable_id.* += 1;
        } else {
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
                var flags = notationFlags(block, vocal_guide);
                if (!chord and pending_dynamic != 0) flags = model.withDynamic(flags, pending_dynamic);
                if (tagContent(block, "actual-notes")) |actual_text| {
                    const actual = try parseUnsigned(actual_text);
                    const normal = if (tagContent(block, "normal-notes")) |normal_text| try parseUnsigned(normal_text) else 0;
                    flags = model.withTupletRatio(flags, @intCast(@min(actual, 15)), @intCast(@min(normal, 15)));
                }
                report.notes[report.note_count] = .{
                    .stable_id = stable_id.*,
                    .start_beat = measure_start + start_beat,
                    .duration_beats = if (grace) 0.125 else @max(duration, 0.0625),
                    .pitch = @intCast(midi_wide),
                    .velocity = dynamicVelocity(current_dynamic.*),
                    .staff = stored_staff,
                    .voice = stored_voice,
                    .written_step = std.ascii.toUpper(step_text[0]),
                    .written_alter = @intCast(std.math.clamp(alter, -2, 2)),
                    .written_octave = @intCast(octave),
                    .dots = countOpenTags(block, "dot", 3),
                    .flags = flags,
                    .fingering = authoredFingering(block),
                };
                report.note_count += 1;
                stable_id.* += 1;
                if (!chord and pending_dynamic != 0) pending_dynamic = 0;
                if (grace) report.approximations += 1;
            }
            if (tagContent(block, "text")) |text| try appendLyric(report, measure_start + start_beat, text);
        }
        previous_start = start_beat;
        extent = @max(extent, start_beat + duration);
        if (!chord and !grace) local_beat += duration;
    }
    return @max(extent, local_beat);
}

fn notationFlags(block: []const u8, vocal_guide: bool) u32 {
    var flags: u32 = if (vocal_guide or findOpenTag(block, 0, "cue") != null) model.note_flag_vocal_guide else 0;
    if (findOpenTag(block, 0, "grace") != null) flags |= model.note_flag_grace;
    if (std.mem.indexOf(u8, block, "<tie type=\"start\"") != null or std.mem.indexOf(u8, block, "<tied type=\"start\"") != null) flags |= model.note_flag_tie_start;
    if (std.mem.indexOf(u8, block, "<tie type=\"stop\"") != null or std.mem.indexOf(u8, block, "<tied type=\"stop\"") != null) flags |= model.note_flag_tie_stop;
    if (findOpenTag(block, 0, "accidental") != null) flags |= model.note_flag_explicit_accidental;
    if (findOpenTag(block, 0, "staccato") != null) flags |= model.note_flag_staccato;
    if (findOpenTag(block, 0, "accent") != null) flags |= model.note_flag_accent;
    if (findOpenTag(block, 0, "tenuto") != null) flags |= model.note_flag_tenuto;
    if (findOpenTag(block, 0, "strong-accent") != null) flags |= model.note_flag_marcato;
    if (findOpenTag(block, 0, "fermata") != null) flags |= model.note_flag_fermata;
    if (std.mem.indexOf(u8, block, "<slur type=\"start\"") != null) flags |= model.note_flag_slur_start;
    if (std.mem.indexOf(u8, block, "<slur type=\"stop\"") != null) flags |= model.note_flag_slur_stop;
    if (std.mem.indexOf(u8, block, "<slur type=\"start\" placement=\"above\"") != null or std.mem.indexOf(u8, block, "<slur placement=\"above\" type=\"start\"") != null) flags |= model.note_flag_slur_above;
    if (std.mem.indexOf(u8, block, "<tuplet type=\"start\"") != null) flags |= model.note_flag_tuplet_start;
    if (std.mem.indexOf(u8, block, "<tuplet type=\"stop\"") != null) flags |= model.note_flag_tuplet_stop;
    if (openTagContent(block, "beam")) |beam| {
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "begin")) flags |= model.note_flag_beam_begin;
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "continue")) flags |= model.note_flag_beam_continue;
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "end")) flags |= model.note_flag_beam_end;
    }
    return flags;
}

fn authoredFingering(block: []const u8) u8 {
    const text = tagContent(block, "fingering") orelse return 0;
    const value = std.fmt.parseUnsigned(u8, std.mem.trim(u8, text, " \t\r\n"), 10) catch return 0;
    return if (value >= 1 and value <= 5) value else 0;
}

fn dynamicFromDirection(block: []const u8) ?u8 {
    if (findOpenTag(block, 0, "ppp") != null) return model.dynamic_ppp;
    if (findOpenTag(block, 0, "pp") != null) return model.dynamic_pp;
    if (findOpenTag(block, 0, "p") != null) return model.dynamic_p;
    if (findOpenTag(block, 0, "mp") != null) return model.dynamic_mp;
    if (findOpenTag(block, 0, "mf") != null) return model.dynamic_mf;
    if (findOpenTag(block, 0, "fff") != null) return model.dynamic_fff;
    if (findOpenTag(block, 0, "ff") != null) return model.dynamic_ff;
    if (findOpenTag(block, 0, "f") != null) return model.dynamic_f;
    if (findOpenTag(block, 0, "sfz") != null) return model.dynamic_sfz;
    return null;
}

fn dynamicVelocity(dynamic_code: u8) u8 {
    return switch (dynamic_code) {
        model.dynamic_ppp => 28,
        model.dynamic_pp => 38,
        model.dynamic_p => 48,
        model.dynamic_mp => 62,
        model.dynamic_mf => 78,
        model.dynamic_f => 94,
        model.dynamic_ff => 108,
        model.dynamic_fff, model.dynamic_sfz => 120,
        else => 88,
    };
}

fn openTagContent(source: []const u8, comptime tag: []const u8) ?[]const u8 {
    const start = findOpenTag(source, 0, tag) orelse return null;
    const open_end = std.mem.indexOfPos(u8, source, start, ">") orelse return null;
    const close = std.mem.indexOfPos(u8, source, open_end + 1, "</" ++ tag ++ ">") orelse return null;
    return std.mem.trim(u8, source[open_end + 1 .. close], " \t\r\n");
}

fn nthOpenTagContent(source: []const u8, comptime tag: []const u8, wanted: usize) ?[]const u8 {
    var cursor: usize = 0;
    var index: usize = 0;
    while (findOpenTag(source, cursor, tag)) |start| {
        const open_end = std.mem.indexOfPos(u8, source, start, ">") orelse return null;
        const close = std.mem.indexOfPos(u8, source, open_end + 1, "</" ++ tag ++ ">") orelse return null;
        if (index == wanted) return std.mem.trim(u8, source[open_end + 1 .. close], " \t\r\n");
        cursor = close + ("</" ++ tag ++ ">").len;
        index += 1;
    }
    return null;
}

fn countOpenTags(source: []const u8, comptime name: []const u8, maximum: u8) u8 {
    var cursor: usize = 0;
    var count: u8 = 0;
    while (count < maximum) {
        const found = findOpenTag(source, cursor, name) orelse break;
        count += 1;
        cursor = found + name.len + 1;
    }
    return count;
}

fn partIsVocalGuide(source: []const u8, wanted_index: u32) bool {
    var cursor: usize = 0;
    var index: u32 = 0;
    while (findOpenTag(source, cursor, "score-part")) |start| {
        const end = std.mem.indexOfPos(u8, source, start, "</score-part>") orelse return false;
        if (index == wanted_index) {
            const name = tagContent(source[start..end], "part-name") orelse return false;
            return containsAsciiInsensitive(name, "voice") or containsAsciiInsensitive(name, "vocal") or containsAsciiInsensitive(name, "singer");
        }
        index += 1;
        cursor = end + "</score-part>".len;
    }
    return false;
}

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var equal = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(byte)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn parseDirectionLyrics(source: []const u8, report: *ImportReport, measure_start: f32, divisions: u32) Error!void {
    var cursor: usize = 0;
    while (findOpenTag(source, cursor, "direction")) |start| {
        const end = std.mem.indexOfPos(u8, source, start, "</direction>") orelse return error.InvalidMusicXml;
        const block = source[start..end];
        if (tagContent(block, "words")) |words| {
            const offset_units = if (tagContent(block, "offset")) |value| try parseSigned(value) else 0;
            const offset_beats = @as(f32, @floatFromInt(offset_units)) / @as(f32, @floatFromInt(divisions));
            try appendLyric(report, @max(0, measure_start + offset_beats), words);
        }
        cursor = end + "</direction>".len;
    }
}

fn appendLyric(report: *ImportReport, start_beat: f32, source: []const u8) Error!void {
    if (source.len == 0) return;
    if (report.lyric_count == report.lyrics.len) return error.TooManyNotes;
    var lyric: model.Lyric = .{ .start_beat = start_beat };
    lyric.text_len = @intCast(decodeXmlText(&lyric.text, source));
    report.lyrics[report.lyric_count] = lyric;
    report.lyric_count += 1;
}

fn appendHarmony(report: *ImportReport, start_beat: f32, source: []const u8, divisions: u32) Error!void {
    if (report.harmony_count == report.harmonies.len) return error.TooManyHarmonies;
    const root = tagContent(source, "root-step") orelse return;
    if (root.len == 0 or root[0] < 'A' or root[0] > 'G') return;
    var harmony: model.Harmony = .{ .start_beat = start_beat, .root_step = root[0] };
    if (tagContent(source, "root-alter")) |value| harmony.root_alter = @intCast(std.math.clamp(try parseSigned(value), -2, 2));
    if (tagContent(source, "bass-step")) |value| if (value.len != 0 and value[0] >= 'A' and value[0] <= 'G') {
        harmony.bass_step = value[0];
    };
    if (tagContent(source, "bass-alter")) |value| harmony.bass_alter = @intCast(std.math.clamp(try parseSigned(value), -2, 2));
    if (tagContent(source, "inversion")) |value| harmony.inversion = @intCast(std.math.clamp(try parseSigned(value), -1, 15));
    if (tagContent(source, "offset")) |value| {
        harmony.start_beat += @as(f32, @floatFromInt(try parseSigned(value))) / @as(f32, @floatFromInt(divisions));
    }
    if (findOpenTag(source, 0, "kind")) |kind_start| {
        const open_end = std.mem.indexOfPos(u8, source, kind_start, ">") orelse return error.InvalidMusicXml;
        const close = std.mem.indexOfPos(u8, source, open_end, "</kind>") orelse return error.InvalidMusicXml;
        const kind_value = std.mem.trim(u8, source[open_end + 1 .. close], " \t\r\n");
        harmony.kind_len = @intCast(decodeXmlText(&harmony.kind, kind_value));
        const opening = source[kind_start .. open_end + 1];
        harmony.text_len = @intCast(decodeXmlText(&harmony.text, attributeValue(opening, "text") orelse harmonyDisplayText(kind_value)));
    } else {
        harmony.setKind("major");
    }
    report.harmonies[report.harmony_count] = harmony;
    report.harmony_count += 1;
}

fn appendPedal(report: *ImportReport, start_beat: f32, source: []const u8) Error!void {
    if (report.pedal_count == report.pedals.len) return error.TooManyPedals;
    const start = findOpenTag(source, 0, "pedal") orelse return;
    const open_end = std.mem.indexOfPos(u8, source, start, ">") orelse return error.InvalidMusicXml;
    const opening = source[start .. open_end + 1];
    const type_name = attributeValue(opening, "type") orelse return;
    const action: u8 = if (std.mem.eql(u8, type_name, "start"))
        model.pedal_action_start
    else if (std.mem.eql(u8, type_name, "stop"))
        model.pedal_action_stop
    else if (std.mem.eql(u8, type_name, "change"))
        model.pedal_action_change
    else if (std.mem.eql(u8, type_name, "continue"))
        model.pedal_action_continue
    else if (std.mem.eql(u8, type_name, "resume"))
        model.pedal_action_resume
    else if (std.mem.eql(u8, type_name, "discontinue"))
        model.pedal_action_discontinue
    else
        return;
    var flags: u8 = 0;
    if (attributeIsYes(opening, "line")) flags |= model.pedal_flag_line;
    if (attributeIsYes(opening, "sign")) flags |= model.pedal_flag_sign;
    var value: u8 = if (action == model.pedal_action_stop or action == model.pedal_action_discontinue) 0 else 127;
    if (findOpenTag(source, 0, "sound")) |sound_start| {
        const sound_end = std.mem.indexOfPos(u8, source, sound_start, ">") orelse return error.InvalidMusicXml;
        if (attributeValue(source[sound_start .. sound_end + 1], "damper-pedal")) |text| {
            const percent = std.fmt.parseFloat(f32, text) catch -1;
            if (std.math.isFinite(percent) and percent >= 0) value = @intFromFloat(@round(std.math.clamp(percent, 0, 100) * 127.0 / 100.0));
        }
    }
    report.pedals[report.pedal_count] = .{
        .start_beat = start_beat,
        .pedal = model.pedal_sustain,
        .value = value,
        .action = action,
        .flags = flags,
    };
    report.pedal_count += 1;
}

fn attributeIsYes(opening: []const u8, comptime name: []const u8) bool {
    const value = attributeValue(opening, name) orelse return false;
    return std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
}

fn harmonyDisplayText(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "major")) return "";
    if (std.mem.eql(u8, kind, "minor")) return "m";
    if (std.mem.eql(u8, kind, "major-seventh")) return "maj7";
    if (std.mem.eql(u8, kind, "minor-seventh")) return "m7";
    if (std.mem.eql(u8, kind, "dominant")) return "7";
    if (std.mem.eql(u8, kind, "dominant-13th")) return "13";
    if (std.mem.eql(u8, kind, "major-sixth")) return "6";
    if (std.mem.eql(u8, kind, "suspended-fourth")) return "sus4";
    if (std.mem.eql(u8, kind, "suspended-second")) return "sus2";
    if (std.mem.eql(u8, kind, "diminished")) return "dim";
    if (std.mem.eql(u8, kind, "augmented")) return "aug";
    return kind;
}

fn smallestPosition(a: ?usize, b: ?usize, c: ?usize, d: ?usize, e: ?usize) ?usize {
    var result: ?usize = null;
    for ([_]?usize{ a, b, c, d, e }) |candidate| {
        if (candidate) |value| result = if (result) |current| @min(current, value) else value;
    }
    return result;
}

fn attributeValue(opening: []const u8, comptime name: []const u8) ?[]const u8 {
    const marker = name ++ "=\"";
    const start = std.mem.indexOf(u8, opening, marker) orelse return null;
    const value_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, opening, value_start, "\"") orelse return null;
    return opening[value_start..end];
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

const DirectionTempo = struct {
    quarter_bpm: f32,
    pulse_bpm: f32,
    beat_unit: u8,
};

fn tempoFromDirection(source: []const u8) ?DirectionTempo {
    const sound_quarter = tempoFromSound(source);
    const pulse = if (tagContent(source, "per-minute")) |value|
        std.fmt.parseFloat(f32, value) catch return null
    else
        sound_quarter orelse return null;
    if (!std.math.isFinite(pulse) or pulse <= 0) return null;
    const beat_unit = if (tagContent(source, "beat-unit")) |value| tempoBeatUnit(value) orelse 4 else 4;
    const calculated_quarter = model.quarterTempoFromPulse(pulse, beat_unit);
    const quarter = sound_quarter orelse calculated_quarter;
    if (!std.math.isFinite(quarter) or quarter <= 0) return null;
    return .{ .quarter_bpm = quarter, .pulse_bpm = pulse, .beat_unit = beat_unit };
}

fn tempoBeatUnit(source: []const u8) ?u8 {
    const value = std.mem.trim(u8, source, " \t\r\n");
    if (std.mem.eql(u8, value, "whole")) return 1;
    if (std.mem.eql(u8, value, "half")) return 2;
    if (std.mem.eql(u8, value, "quarter")) return 4;
    if (std.mem.eql(u8, value, "eighth")) return 8;
    if (std.mem.eql(u8, value, "16th")) return 16;
    if (std.mem.eql(u8, value, "32nd")) return 32;
    if (std.mem.eql(u8, value, "64th")) return 64;
    if (std.mem.eql(u8, value, "128th")) return 128;
    return null;
}

fn appendTempo(report: *ImportReport, start_beat: f32, bpm: f32) Error!void {
    if (!std.math.isFinite(start_beat) or !std.math.isFinite(bpm) or bpm <= 0) return error.InvalidNumber;
    // A direction may carry both metronome text and a sound tempo. It is one
    // transition, and a later direction at the same beat intentionally wins.
    for (report.tempos[0..report.tempo_count]) |*event| {
        if (@abs(event.start_beat - start_beat) <= 0.0001) {
            event.bpm = bpm;
            return;
        }
    }
    if (report.tempo_count == report.tempos.len) return error.TooManyTempos;
    report.tempos[report.tempo_count] = .{ .start_beat = start_beat, .bpm = bpm };
    report.tempo_count += 1;
}

fn copyText(destination: []u8, length: *usize, source: []const u8) void {
    length.* = decodeXmlText(destination, source);
}

fn decodeXmlText(destination: []u8, source: []const u8) usize {
    var length = @min(destination.len, source.len);
    @memcpy(destination[0..length], source[0..length]);
    // Older private drafts passed encoded text through the exporter several
    // times. Decode common entities until stable so one import/export cycle
    // repairs those layers instead of preserving or multiplying them.
    for (0..8) |_| {
        var read: usize = 0;
        var write: usize = 0;
        var changed = false;
        while (read < length) {
            const remaining = destination[read..length];
            const decoded: ?struct { value: u8, consumed: usize } = if (std.mem.startsWith(u8, remaining, "&amp;"))
                .{ .value = '&', .consumed = 5 }
            else if (std.mem.startsWith(u8, remaining, "&lt;"))
                .{ .value = '<', .consumed = 4 }
            else if (std.mem.startsWith(u8, remaining, "&gt;"))
                .{ .value = '>', .consumed = 4 }
            else if (std.mem.startsWith(u8, remaining, "&quot;"))
                .{ .value = '"', .consumed = 6 }
            else if (std.mem.startsWith(u8, remaining, "&apos;"))
                .{ .value = '\'', .consumed = 6 }
            else
                null;
            if (decoded) |entity| {
                destination[write] = entity.value;
                write += 1;
                read += entity.consumed;
                changed = true;
            } else {
                destination[write] = destination[read];
                write += 1;
                read += 1;
            }
        }
        length = write;
        if (!changed) break;
    }
    return length;
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
        \\<direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>90</per-minute></metronome></direction-type></direction>
        \\<note><rest/><duration>1</duration></note>
        \\<note><pitch><step>G</step><alter>1</alter><octave>4</octave></pitch><duration>1</duration></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 4), report.note_count);
    try std.testing.expectEqual(@as(u8, 60), report.notes[0].pitch);
    try std.testing.expectEqual(@as(u8, 64), report.notes[1].pitch);
    try std.testing.expect((report.notes[2].flags & model.note_flag_rest) != 0);
    try std.testing.expectEqual(@as(f32, 1), report.notes[2].start_beat);
    try std.testing.expectEqual(@as(f32, 0.5), report.notes[2].duration_beats);
    try std.testing.expectEqual(@as(u8, 68), report.notes[3].pitch);
    try std.testing.expectEqual(@as(f32, 0), report.notes[1].start_beat);
    try std.testing.expectEqual(@as(usize, 2), report.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 84), report.tempos[0].bpm, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), report.tempos[1].start_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), report.tempos[1].bpm, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 84), report.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(u8, 4), report.tempo_beat_unit);
    try std.testing.expectEqualStrings("Generated Study", report.titleSlice());
}

test "imports printed eighth pulse separately from quarter-note playback tempo" {
    const fixture =
        \\<score-partwise version="4.0">
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<direction><direction-type><metronome><beat-unit>eighth</beat-unit><per-minute>147</per-minute></metronome></direction-type><sound tempo="73.5"/></direction>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>4</duration></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectApproxEqAbs(@as(f32, 147), report.tempo_bpm, 0.001);
    try std.testing.expectEqual(@as(u8, 8), report.tempo_beat_unit);
    try std.testing.expectEqual(@as(usize, 1), report.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), report.tempos[0].bpm, 0.001);
}

test "falls back to MusicXML page credits for title and composer" {
    const fixture =
        \\<score-partwise><credit><credit-words>Minuet in G Major</credit-words></credit>
        \\<credit><credit-words>Christian Petzold</credit-words></credit>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration></note></measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqualStrings("Minuet in G Major", report.titleSlice());
    try std.testing.expectEqualStrings("Christian Petzold", report.creatorSlice());
}

test "preserves professional note spelling dots beams accidentals and ties" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>8</divisions><key><fifths>-5</fifths></key><time><beats>6</beats><beat-type>4</beat-type></time></attributes>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>5</octave></pitch><duration>6</duration><dot/><accidental>flat</accidental><tie type="start"/><beam number="1">begin</beam><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification><notations><tied type="start"/><slur type="start" placement="above"/><articulations><staccato/><accent/></articulations><tuplet type="start"/><technical><fingering>4</fingering></technical></notations></note>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>5</octave></pitch><duration>2</duration><tie type="stop"/><beam number="1">end</beam><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification><notations><tied type="stop"/><slur type="stop"/><tuplet type="stop"/></notations></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expectEqual(@as(u8, 'D'), report.notes[0].written_step);
    try std.testing.expectEqual(@as(i8, -1), report.notes[0].written_alter);
    try std.testing.expectEqual(@as(i8, 5), report.notes[0].written_octave);
    try std.testing.expectEqual(@as(u8, 1), report.notes[0].dots);
    try std.testing.expectEqual(@as(u8, 4), report.notes[0].fingering);
    try std.testing.expect((report.notes[0].flags & model.note_flag_explicit_accidental) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_tie_start) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_beam_begin) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_staccato) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_accent) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_slur_start) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_slur_above) != 0);
    try std.testing.expect((report.notes[0].flags & model.note_flag_tuplet_start) != 0);
    try std.testing.expectEqual(@as(u8, 3), model.tupletActual(report.notes[0].flags));
    try std.testing.expectEqual(@as(u8, 2), model.tupletNormal(report.notes[0].flags));
    try std.testing.expect((report.notes[1].flags & model.note_flag_tie_stop) != 0);
    try std.testing.expect((report.notes[1].flags & model.note_flag_beam_end) != 0);
    try std.testing.expect((report.notes[1].flags & model.note_flag_slur_stop) != 0);
    try std.testing.expect((report.notes[1].flags & model.note_flag_tuplet_stop) != 0);
}

test "imports timed lyrics and marks named vocal parts as guides" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<score-partwise version="4.0">
        \\<part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part>
        \\<score-part id="P2"><part-name>Vocal guide</part-name></score-part>
        \\</part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<direction><direction-type><words>Some way</words></direction-type><offset>2</offset></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note></measure></part>
        \\<part id="P2"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><lyric><text>baby</text></lyric></note></measure></part>
        \\</score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expectEqual(@as(usize, 2), report.lyric_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), report.lyrics[0].start_beat, 0.001);
    try std.testing.expectEqualStrings("Some way", report.lyrics[0].textSlice());
    try std.testing.expect((report.notes[1].flags & model.note_flag_vocal_guide) != 0);
}

test "semantic note lyrics suppress duplicate direction-word phrases" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Vocal guide</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<direction><direction-type><words>same sung phrase</words></direction-type></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><lyric><text>same</text></lyric></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 1), report.lyric_count);
    try std.testing.expectEqualStrings("same", report.lyrics[0].textSlice());
}

test "imports semantic MusicXML harmony with slash bass and offset" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<harmony><root><root-step>B</root-step><root-alter>-1</root-alter></root><kind text="m7">minor-seventh</kind><bass><bass-step>D</bass-step><bass-alter>-1</bass-alter></bass><offset>2</offset></harmony>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>4</duration></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 1), report.harmony_count);
    const harmony = report.harmonies[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), harmony.start_beat, 0.001);
    try std.testing.expectEqual(@as(u8, 'B'), harmony.root_step);
    try std.testing.expectEqual(@as(i8, -1), harmony.root_alter);
    try std.testing.expectEqual(@as(u8, 'D'), harmony.bass_step);
    try std.testing.expectEqualStrings("minor-seventh", harmony.kindSlice());
    try std.testing.expectEqualStrings("m7", harmony.textSlice());
}

test "imports timed MusicXML pedal start change and stop directions" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<direction placement="below"><direction-type><pedal type="start" line="yes"/></direction-type><sound damper-pedal="42.52"/></direction>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<direction placement="below"><direction-type><pedal type="change" line="yes"/></direction-type><offset>2</offset></direction>
        \\<direction placement="below"><direction-type><pedal type="stop" line="yes"/></direction-type></direction>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 3), report.pedal_count);
    try std.testing.expectApproxEqAbs(@as(f32, 1), report.pedals[0].start_beat, 0.001);
    try std.testing.expectEqual(model.pedal_action_start, report.pedals[0].action);
    try std.testing.expectEqual(@as(u8, 54), report.pedals[0].value);
    try std.testing.expect((report.pedals[0].flags & model.pedal_flag_line) != 0);
    try std.testing.expectApproxEqAbs(@as(f32, 2), report.pedals[1].start_beat, 0.001);
    try std.testing.expectEqual(model.pedal_action_stop, report.pedals[1].action);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), report.pedals[2].start_beat, 0.001);
    try std.testing.expectEqual(model.pedal_action_change, report.pedals[2].action);
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

test "declared meter keeps later measures aligned when a measure is underfilled" {
    const fixture =
        \\<score-partwise version="4.0"><part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1">
        \\<measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note></measure>
        \\<measure number="2"><attributes><time><beats>2</beats><beat-type>4</beat-type></time></attributes>
        \\<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration></note></measure>
        \\<measure number="3"><note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration></note></measure>
        \\</part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 3), report.note_count);
    try std.testing.expectEqual(@as(f32, 0), report.notes[0].start_beat);
    try std.testing.expectEqual(@as(f32, 4), report.notes[1].start_beat);
    try std.testing.expectEqual(@as(f32, 6), report.notes[2].start_beat);
    try std.testing.expectEqual(@as(usize, 3), report.measure_count);
    try std.testing.expectEqual(@as(f32, 4), report.measures[0].duration_beats);
    try std.testing.expectEqual(@as(f32, 2), report.measures[1].duration_beats);
    try std.testing.expectEqual(@as(f32, 6), report.measures[2].start_beat);
    try std.testing.expectEqual(@as(u8, 2), report.measures[1].beats);
    try std.testing.expectEqual(@as(u8, 4), report.measures[1].beat_unit);
}

test "nested legacy XML entities decode to user-facing text" {
    const xml =
        \\<?xml version="1.0"?>
        \\<score-partwise version="4.0"><work><work-title>A &amp;amp; B</work-title></work>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<direction><direction-type><words>You&amp;amp;amp;apos;re</words></direction-type></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note></measure></part></score-partwise>
    ;
    const report = try parse(xml);
    try std.testing.expectEqualStrings("A & B", report.titleSlice());
    try std.testing.expectEqual(@as(usize, 1), report.lyric_count);
    try std.testing.expectEqualStrings("You're", report.lyrics[0].textSlice());
}

test "implicit pickup advances by encoded extent" {
    const fixture =
        \\<score-partwise version="4.0"><part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1">
        \\<measure number="0" implicit="yes"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration></note></measure>
        \\<measure number="1"><note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note></measure>
        \\</part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expectEqual(@as(f32, 0), report.notes[0].start_beat);
    try std.testing.expectEqual(@as(f32, 1), report.notes[1].start_beat);
    try std.testing.expectEqual(@as(usize, 2), report.measure_count);
    try std.testing.expectEqual(@as(u32, 0), report.measures[0].number);
    try std.testing.expectEqual(@as(u8, 1), report.measures[0].implicit);
    try std.testing.expectEqual(@as(f32, 1), report.measures[0].duration_beats);
    try std.testing.expectEqual(@as(f32, 1), report.measures[1].start_beat);
}
