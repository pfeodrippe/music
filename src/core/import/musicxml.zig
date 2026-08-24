const std = @import("std");
const model = @import("../model.zig");

pub const max_import_notes = 4096;
pub const max_import_lyrics = 1024;
pub const max_import_harmonies = 1024;
pub const max_import_hairpins = 1024;
pub const max_import_pedals = 2048;
pub const max_import_measures = 2048;
pub const max_import_tempos = model.max_tempo_events;
pub const max_import_parts = model.max_score_parts;

pub const ImportReport = struct {
    notes: [max_import_notes]model.Note = undefined,
    note_count: usize = 0,
    lyrics: [max_import_lyrics]model.Lyric = undefined,
    lyric_count: usize = 0,
    harmonies: [max_import_harmonies]model.Harmony = undefined,
    harmony_count: usize = 0,
    hairpins: [max_import_hairpins]model.Hairpin = undefined,
    hairpin_count: usize = 0,
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
    parts: [max_import_parts]model.ScorePart = [_]model.ScorePart{.{}} ** max_import_parts,
    part_count: usize = 0,

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
    TooManyHairpins,
    TooManyPedals,
    TooManyMeasures,
    TooManyTempos,
    TooManyParts,
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
    report.approximations += unsupportedOrnamentCount(source);
    try parsePartDefinitions(source, report);

    var stable_id: u64 = 1;
    var part_cursor: usize = 0;
    var part_index: u32 = 0;
    while (findOpenTag(source, part_cursor, "part")) |part_start| {
        if (part_index >= model.max_instrument_parts) return error.TooManyParts;
        const part_open_end = std.mem.indexOfPos(u8, source, part_start, ">") orelse return error.InvalidMusicXml;
        const part_end = std.mem.indexOfPos(u8, source, part_open_end, "</part>") orelse return error.InvalidMusicXml;
        if (part_index >= report.part_count) {
            var fallback: model.ScorePart = .{ .source_index = part_index };
            var fallback_buffer: [24]u8 = undefined;
            const fallback_name = std.fmt.bufPrint(&fallback_buffer, "Part {d}", .{part_index + 1}) catch "Part";
            fallback.setName(fallback_name);
            report.parts[report.part_count] = fallback;
            report.part_count += 1;
        }
        try parsePart(source[part_open_end + 1 .. part_end], report, part_index, report.parts[part_index].isVocal(), &stable_id);
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
            return left.start_beat < right.start_beat or
                (left.start_beat == right.start_beat and left.pedal < right.pedal) or
                (left.start_beat == right.start_beat and left.pedal == right.pedal and left.action < right.action);
        }
    }.lessThan);
    std.mem.sort(model.Hairpin, report.hairpins[0..report.hairpin_count], {}, struct {
        fn lessThan(_: void, left: model.Hairpin, right: model.Hairpin) bool {
            return left.start_beat < right.start_beat or
                (left.start_beat == right.start_beat and left.staff < right.staff) or
                (left.start_beat == right.start_beat and left.staff == right.staff and left.number < right.number);
        }
    }.lessThan);
}

fn parsePartDefinitions(source: []const u8, report: *ImportReport) Error!void {
    var cursor: usize = 0;
    var index: u32 = 0;
    while (findOpenTag(source, cursor, "score-part")) |start| {
        if (report.part_count == report.parts.len) return error.TooManyParts;
        const end = std.mem.indexOfPos(u8, source, start, "</score-part>") orelse return error.InvalidMusicXml;
        const block = source[start .. end + "</score-part>".len];
        const encoded_name = tagContent(block, "part-name") orelse tagContent(block, "instrument-name") orelse "Part";
        var part: model.ScorePart = .{ .source_index = index };
        part.name_len = @intCast(decodeXmlText(&part.name, encoded_name));
        if (containsAsciiInsensitive(part.nameSlice(), "voice") or containsAsciiInsensitive(part.nameSlice(), "vocal") or containsAsciiInsensitive(part.nameSlice(), "singer")) part.flags |= model.score_part_flag_vocal;
        if (tagContent(block, "midi-program")) |program| part.midi_program = @min(@as(u32, 128), try parseUnsigned(program));
        report.parts[report.part_count] = part;
        report.part_count += 1;
        index += 1;
        cursor = end + "</score-part>".len;
    }
}

fn parsePart(source: []const u8, report: *ImportReport, part_index: u32, vocal_guide: bool, stable_id: *u64) Error!void {
    var measure_cursor: usize = 0;
    var measure_start: f32 = 0;
    var beats: u32 = report.beats_per_measure;
    var beat_unit: u32 = report.beat_unit;
    var current_dynamic: u8 = 0;
    var current_velocity: u8 = dynamicVelocity(0);
    var current_pedal_values = [_]u8{0} ** 3;
    // MusicXML's `number` connects overlapping damper/sostenuto lines whose
    // later stop/change types do not repeat the pedal kind.
    var numbered_pedal_kinds = [_]u8{255} ** 17;
    // Wedges use the same 1...16 MusicXML numbering model so concurrent or
    // overlapping expressive spans can be closed independently across bars.
    var open_hairpins = [_]?usize{null} ** 17;
    // An ending's start/stop elements can be several measures apart. Retain
    // its pass mask while parsing the first source part so every enclosed bar
    // gets the playback condition, not just the two bracket endpoints.
    var active_ending_mask: u16 = 0;
    while (findOpenTag(source, measure_cursor, "measure")) |measure_open| {
        const open_end = std.mem.indexOfPos(u8, source, measure_open, ">") orelse return error.InvalidMusicXml;
        const measure_end = std.mem.indexOfPos(u8, source, open_end, "</measure>") orelse return error.InvalidMusicXml;
        const opening = source[measure_open .. open_end + 1];
        const body = source[open_end + 1 .. measure_end];
        if (tagContent(body, "beats")) |value| beats = @max(1, try parseUnsigned(value));
        if (tagContent(body, "beat-type")) |value| beat_unit = @max(1, try parseUnsigned(value));
        const extent = try parseMeasure(body, report, measure_start, part_index, vocal_guide, stable_id, &current_dynamic, &current_velocity, &current_pedal_values, &numbered_pedal_kinds, &open_hairpins);
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
            var measure = model.Measure{
                .start_beat = measure_start,
                .duration_beats = duration_beats,
                .number = number,
                .beats = @intCast(@min(255, beats)),
                .beat_unit = @intCast(@min(255, beat_unit)),
                .implicit = @intFromBool(implicit),
            };
            try parseMeasureRepeats(body, &measure);
            try parseMeasureEndings(body, &measure, &active_ending_mask, &report.approximations);
            report.measures[report.measure_count] = measure;
            report.measure_count += 1;
        }
        measure_start += duration_beats;
        measure_cursor = measure_end + "</measure>".len;
    }
    // Preserve malformed-but-readable source wedges as spans through the end
    // of their part instead of dropping them. The warning remains explicit.
    for (&open_hairpins) |*open| if (open.*) |index| {
        report.hairpins[index].end_beat = @max(report.hairpins[index].start_beat + 0.001, measure_start);
        report.approximations += 1;
        open.* = null;
    };
}

fn parseMeasureEndings(source: []const u8, measure: *model.Measure, active_mask: *u16, approximations: *u32) Error!void {
    measure.ending_mask = active_mask.*;
    var cursor: usize = 0;
    while (findOpenTag(source, cursor, "ending")) |start| {
        const end = std.mem.indexOfPos(u8, source, start, ">") orelse return error.InvalidMusicXml;
        const tag = source[start .. end + 1];
        const kind = attributeValue(tag, "type") orelse return error.InvalidMusicXml;
        const parsed_mask = if (attributeValue(tag, "number")) |numbers|
            parseEndingMask(numbers, approximations)
        else blk: {
            approximations.* += 1;
            break :blk @as(u16, 0);
        };

        if (std.mem.eql(u8, kind, "start")) {
            measure.ending_flags |= model.measure_ending_start;
            if (parsed_mask != 0) {
                measure.ending_mask = parsed_mask;
                active_mask.* = parsed_mask;
            }
        } else if (std.mem.eql(u8, kind, "stop") or std.mem.eql(u8, kind, "discontinue")) {
            measure.ending_flags |= if (std.mem.eql(u8, kind, "stop")) model.measure_ending_stop else model.measure_ending_discontinue;
            if (measure.ending_mask == 0) measure.ending_mask = parsed_mask;
            active_mask.* = 0;
        } else {
            approximations.* += 1;
        }
        cursor = end + 1;
    }
}

fn parseEndingMask(source: []const u8, approximations: *u32) u16 {
    var mask: u16 = 0;
    var tokens = std.mem.tokenizeAny(u8, source, ",; \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.indexOfScalar(u8, token, '-')) |dash| {
            const first = parseUnsigned(token[0..dash]) catch {
                approximations.* += 1;
                continue;
            };
            const last = parseUnsigned(token[dash + 1 ..]) catch {
                approximations.* += 1;
                continue;
            };
            if (first == 0 or first > last or last > 16) {
                approximations.* += 1;
                continue;
            }
            var pass = first;
            while (pass <= last) : (pass += 1) mask |= @as(u16, 1) << @intCast(pass - 1);
        } else {
            const pass = parseUnsigned(token) catch {
                approximations.* += 1;
                continue;
            };
            if (pass == 0 or pass > 16) {
                approximations.* += 1;
                continue;
            }
            mask |= @as(u16, 1) << @intCast(pass - 1);
        }
    }
    return mask;
}

fn parseMeasureRepeats(source: []const u8, measure: *model.Measure) Error!void {
    var cursor: usize = 0;
    while (findOpenTag(source, cursor, "repeat")) |start| {
        const end = std.mem.indexOfPos(u8, source, start, ">") orelse return error.InvalidMusicXml;
        const tag = source[start .. end + 1];
        const direction = attributeValue(tag, "direction") orelse return error.InvalidMusicXml;
        if (std.mem.eql(u8, direction, "forward")) {
            measure.repeat |= model.measure_repeat_forward;
        } else if (std.mem.eql(u8, direction, "backward")) {
            measure.repeat |= model.measure_repeat_backward;
            if (attributeValue(tag, "times")) |value| {
                measure.setRepeatPasses(@intCast(@min(@as(u32, 63), try parseUnsigned(value))));
            }
        }
        cursor = end + 1;
    }
}

fn parseMeasure(source: []const u8, report: *ImportReport, measure_start: f32, part_index: u32, vocal_guide: bool, stable_id: *u64, current_dynamic: *u8, current_velocity: *u8, current_pedal_values: *[3]u8, numbered_pedal_kinds: *[17]u8, open_hairpins: *[17]?usize) Error!f32 {
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
            const performed_velocity = soundVelocity(block);
            if (dynamicFromDirection(block)) |dynamic_code| {
                current_dynamic.* = dynamic_code;
                pending_dynamic = dynamic_code;
                if (performed_velocity == null) current_velocity.* = dynamicVelocity(dynamic_code);
            }
            if (performed_velocity) |velocity| current_velocity.* = velocity;
            if (findOpenTag(block, 0, "pedal") != null or hasPedalSound(block)) {
                const offset_units = if (tagContent(block, "offset")) |value| try parseSigned(value) else 0;
                const offset_beats = @as(f32, @floatFromInt(offset_units)) / @as(f32, @floatFromInt(divisions));
                try appendPedals(report, @max(0, measure_start + local_beat + offset_beats), block, current_pedal_values, numbered_pedal_kinds);
            }
            if (findOpenTag(block, 0, "wedge") != null) {
                const offset_units = if (tagContent(block, "offset")) |value| try parseSigned(value) else 0;
                const offset_beats = @as(f32, @floatFromInt(offset_units)) / @as(f32, @floatFromInt(divisions));
                try appendHairpinDirection(report, @max(0, measure_start + local_beat + offset_beats), part_index, vocal_guide, block, open_hairpins);
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
        const grace_attributes = if (grace) try parseGraceAttributes(block, divisions) else GraceAttributes{};
        const rest = findOpenTag(block, 0, "rest") != null;
        const start_beat = if (chord) previous_start else local_beat;
        const staff_value = if (tagContent(block, "staff")) |value| try parseUnsigned(value) else 1;
        const voice_value = if (tagContent(block, "voice")) |value| try parseUnsigned(value) else 1;
        const stored_staff: u8 = @intCast(@min(part_index * 8 + staff_value -| 1, 255));
        const stored_voice: u8 = @intCast(@min(voice_value -| 1, 255));
        const slurs = parseSlurNotation(block);

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
                .slur_start_mask = slurs.start_mask,
                .slur_stop_mask = slurs.stop_mask,
                .flags = notationFlags(block, vocal_guide, slurs) | model.note_flag_rest | if (std.mem.indexOf(u8, block, "<rest measure=\"yes\"") != null) model.note_flag_measure_rest else 0,
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
                var flags = notationFlags(block, vocal_guide, slurs);
                if (!chord and pending_dynamic != 0) flags = model.withDynamic(flags, pending_dynamic);
                if (tagContent(block, "actual-notes")) |actual_text| {
                    const actual = try parseUnsigned(actual_text);
                    const normal = if (tagContent(block, "normal-notes")) |normal_text| try parseUnsigned(normal_text) else 0;
                    flags = model.withTupletRatio(flags, @intCast(@min(actual, 15)), @intCast(@min(normal, 15)));
                }
                report.notes[report.note_count] = .{
                    .stable_id = stable_id.*,
                    .start_beat = measure_start + start_beat,
                    .duration_beats = if (grace) grace_attributes.duration_beats else @max(duration, 0.0625),
                    .pitch = @intCast(midi_wide),
                    .velocity = current_velocity.*,
                    .staff = stored_staff,
                    .voice = stored_voice,
                    .written_step = std.ascii.toUpper(step_text[0]),
                    .written_alter = @intCast(std.math.clamp(alter, -2, 2)),
                    .written_octave = @intCast(octave),
                    .dots = countOpenTags(block, "dot", 3),
                    .slur_start_mask = slurs.start_mask,
                    .slur_stop_mask = slurs.stop_mask,
                    .flags = flags,
                    .fingering = authoredFingering(block),
                    .notations = notationDetails(block) | grace_attributes.notations,
                };
                report.note_count += 1;
                stable_id.* += 1;
                if (!chord and pending_dynamic != 0) pending_dynamic = 0;
            }
            if (tagContent(block, "text")) |text| try appendLyric(report, measure_start + start_beat, text);
        }
        previous_start = start_beat;
        extent = @max(extent, start_beat + duration);
        if (!chord and !grace) local_beat += duration;
    }
    return @max(extent, local_beat);
}

const GraceAttributes = struct {
    duration_beats: f32 = 0.125,
    notations: u32 = 0,
};

fn parseGraceAttributes(block: []const u8, divisions: u32) Error!GraceAttributes {
    const start = findOpenTag(block, 0, "grace") orelse return .{};
    const end = std.mem.indexOfPos(u8, block, start, ">") orelse return error.InvalidMusicXml;
    const tag = block[start .. end + 1];
    const following = if (attributeValue(tag, "steal-time-following")) |value| try parsePercent(value) else 0;
    const previous = if (attributeValue(tag, "steal-time-previous")) |value| try parsePercent(value) else 0;
    const make_units = if (attributeValue(tag, "make-time")) |value| try parsePositiveFloat(value) else 0;
    const make_time = make_units > 0;
    return .{
        .duration_beats = if (make_time) make_units / @as(f32, @floatFromInt(@max(1, divisions))) else 0.125,
        .notations = model.withGraceTiming(0, attributeIsYes(tag, "slash"), following, previous, make_time),
    };
}

fn parsePercent(source: []const u8) Error!u8 {
    const value = try parsePositiveFloat(source);
    return @intFromFloat(@round(std.math.clamp(value, 0, 100)));
}

fn parsePositiveFloat(source: []const u8) Error!f32 {
    const value = std.fmt.parseFloat(f32, std.mem.trim(u8, source, " \t\r\n")) catch return error.InvalidNumber;
    if (!std.math.isFinite(value) or value < 0) return error.InvalidNumber;
    return value;
}

const SlurNotation = struct {
    start_mask: u8 = 0,
    stop_mask: u8 = 0,
    above: bool = false,
};

fn parseSlurNotation(block: []const u8) SlurNotation {
    var result: SlurNotation = .{};
    var cursor: usize = 0;
    while (findOpenTag(block, cursor, "slur")) |start| {
        const end = std.mem.indexOfPos(u8, block, start, ">") orelse break;
        const opening = block[start .. end + 1];
        const slur_type = attributeValue(opening, "type") orelse {
            cursor = end + 1;
            continue;
        };
        const raw_number = if (attributeValue(opening, "number")) |text|
            std.fmt.parseUnsigned(u8, text, 10) catch 1
        else
            1;
        const bit = model.slurNumberBit(raw_number);
        if (std.mem.eql(u8, slur_type, "start")) {
            result.start_mask |= bit;
            if (attributeValue(opening, "placement")) |placement| result.above = result.above or std.mem.eql(u8, placement, "above");
        } else if (std.mem.eql(u8, slur_type, "stop")) {
            result.stop_mask |= bit;
        }
        cursor = end + 1;
    }
    return result;
}

fn notationFlags(block: []const u8, vocal_guide: bool, slurs: SlurNotation) u32 {
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
    if (slurs.start_mask != 0) flags |= model.note_flag_slur_start;
    if (slurs.stop_mask != 0) flags |= model.note_flag_slur_stop;
    if (slurs.above) flags |= model.note_flag_slur_above;
    if (std.mem.indexOf(u8, block, "<tuplet type=\"start\"") != null) flags |= model.note_flag_tuplet_start;
    if (std.mem.indexOf(u8, block, "<tuplet type=\"stop\"") != null) flags |= model.note_flag_tuplet_stop;
    if (openTagContent(block, "beam")) |beam| {
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "begin")) flags |= model.note_flag_beam_begin;
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "continue")) flags |= model.note_flag_beam_continue;
        if (std.mem.eql(u8, std.mem.trim(u8, beam, " \t\r\n"), "end")) flags |= model.note_flag_beam_end;
    }
    return flags;
}

fn notationDetails(block: []const u8) u32 {
    var details: u32 = 0;
    if (findOpenTag(block, 0, "trill-mark") != null) details |= model.note_notation_trill;
    if (findOpenTag(block, 0, "turn") != null) details |= model.note_notation_turn;
    if (findOpenTag(block, 0, "inverted-turn") != null) details |= model.note_notation_inverted_turn;
    if (findOpenTag(block, 0, "mordent") != null) details |= model.note_notation_mordent;
    if (findOpenTag(block, 0, "inverted-mordent") != null) details |= model.note_notation_inverted_mordent;

    if (findOpenTag(block, 0, "arpeggiate")) |start| {
        details |= model.note_notation_arpeggiate;
        const end = std.mem.indexOfPos(u8, block, start, ">") orelse block.len - 1;
        const opening = block[start..@min(end + 1, block.len)];
        if (attributeValue(opening, "direction")) |direction| {
            if (std.mem.eql(u8, direction, "up")) details |= model.note_notation_arpeggiate_up;
            if (std.mem.eql(u8, direction, "down")) details |= model.note_notation_arpeggiate_down;
        }
    }

    const ornament_tags = [_][]const u8{ "trill-mark", "turn", "inverted-turn", "mordent", "inverted-mordent" };
    inline for (ornament_tags) |tag| {
        if (findOpenTag(block, 0, tag)) |start| {
            if (std.mem.indexOfPos(u8, block, start, ">")) |end| {
                if (attributeValue(block[start .. end + 1], "placement")) |placement| {
                    if (std.mem.eql(u8, placement, "below")) details |= model.note_notation_ornament_below;
                }
            }
        }
    }
    if (findOpenTag(block, 0, "tremolo")) |start| {
        if (std.mem.indexOfPos(u8, block, start, ">")) |open_end| {
            const opening = block[start .. open_end + 1];
            const tremolo_type = attributeValue(opening, "type") orelse "single";
            if (std.mem.eql(u8, tremolo_type, "single")) {
                if (std.mem.indexOfPos(u8, block, open_end + 1, "</tremolo>")) |close| {
                    const text = std.mem.trim(u8, block[open_end + 1 .. close], " \t\r\n");
                    const marks = std.fmt.parseUnsigned(u8, text, 10) catch 0;
                    if (marks >= 1 and marks <= 8) details = model.withSingleTremolo(details, marks);
                }
            }
        }
    }
    return details;
}

fn unsupportedTremoloCount(source: []const u8) u32 {
    var cursor: usize = 0;
    var count: u32 = 0;
    while (findOpenTag(source, cursor, "tremolo")) |start| {
        const open_end = std.mem.indexOfPos(u8, source, start, ">") orelse return count + 1;
        const opening = source[start .. open_end + 1];
        const tremolo_type = attributeValue(opening, "type") orelse "single";
        const close = std.mem.indexOfPos(u8, source, open_end + 1, "</tremolo>") orelse return count + 1;
        const text = std.mem.trim(u8, source[open_end + 1 .. close], " \t\r\n");
        const marks = std.fmt.parseUnsigned(u8, text, 10) catch 0;
        if (!std.mem.eql(u8, tremolo_type, "single") or marks < 1 or marks > 8) count += 1;
        cursor = close + "</tremolo>".len;
    }
    return count;
}

fn unsupportedOrnamentCount(source: []const u8) u32 {
    // Common keyboard ornaments are retained semantically above. Report only
    // the less common MusicXML forms that still need an explicit engine model.
    const unsupported = [_][]const u8{
        "delayed-turn",
        "delayed-inverted-turn",
        "vertical-turn",
        "shake",
        "wavy-line",
        "schleifer",
        "haydn",
        "other-ornament",
        "accidental-mark",
    };
    var count: u32 = 0;
    inline for (unsupported) |tag| count += @as(u32, countOpenTags(source, tag, 255));
    return count + unsupportedTremoloCount(source);
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

fn soundVelocity(source: []const u8) ?u8 {
    const sound_start = findOpenTag(source, 0, "sound") orelse return null;
    const sound_end = std.mem.indexOfPos(u8, source, sound_start, ">") orelse return null;
    const text = attributeValue(source[sound_start .. sound_end + 1], "dynamics") orelse return null;
    const percent = std.fmt.parseFloat(f32, text) catch return null;
    if (!std.math.isFinite(percent) or percent < 0) return null;
    return @intFromFloat(@round(std.math.clamp(percent * 90.0 / 100.0, 1, 127)));
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

fn appendHairpinDirection(report: *ImportReport, beat: f32, part_index: u32, vocal_guide: bool, source: []const u8, open_hairpins: *[17]?usize) Error!void {
    const wedge_start = findOpenTag(source, 0, "wedge") orelse return;
    const wedge_end = std.mem.indexOfPos(u8, source, wedge_start, ">") orelse return error.InvalidMusicXml;
    const wedge = source[wedge_start .. wedge_end + 1];
    const type_name = attributeValue(wedge, "type") orelse return;
    const raw_number = if (attributeValue(wedge, "number")) |value| std.fmt.parseUnsigned(usize, value, 10) catch 1 else 1;
    const number = std.math.clamp(raw_number, 1, 16);
    var flags: u8 = if (vocal_guide) model.hairpin_flag_vocal else 0;
    const direction_end = std.mem.indexOf(u8, source, ">") orelse return error.InvalidMusicXml;
    const direction_opening = source[0 .. direction_end + 1];
    if (attributeValue(direction_opening, "placement")) |placement| if (std.mem.eql(u8, placement, "above")) {
        flags |= model.hairpin_flag_above;
    };
    if (attributeIsYes(wedge, "niente")) flags |= model.hairpin_flag_niente;
    if (attributeValue(wedge, "line-type")) |line_type| {
        if (std.mem.eql(u8, line_type, "dashed")) flags |= model.hairpin_flag_dashed;
        if (std.mem.eql(u8, line_type, "dotted")) flags |= model.hairpin_flag_dotted;
    }
    const parsed_spread = if (attributeValue(wedge, "spread")) |value| std.fmt.parseFloat(f32, value) catch 0 else 0;
    const spread = if (std.math.isFinite(parsed_spread) and parsed_spread > 0) parsed_spread else 15;

    const kind: ?u8 = if (std.mem.eql(u8, type_name, "crescendo"))
        model.hairpin_crescendo
    else if (std.mem.eql(u8, type_name, "diminuendo"))
        model.hairpin_diminuendo
    else
        null;
    if (kind) |hairpin_kind| {
        if (open_hairpins[number]) |previous| {
            report.hairpins[previous].end_beat = @max(report.hairpins[previous].start_beat + 0.001, beat);
            report.approximations += 1;
        }
        if (report.hairpin_count == report.hairpins.len) return error.TooManyHairpins;
        const local_staff = if (tagContent(source, "staff")) |value| @min(try parseUnsigned(value) -| 1, model.staff_slots_per_part - 1) else 0;
        report.hairpins[report.hairpin_count] = .{
            .start_beat = beat,
            .end_beat = beat,
            .spread = spread,
            .staff = model.encodedStaff(part_index, @intCast(local_staff)),
            .kind = hairpin_kind,
            .number = @intCast(number),
            .flags = flags,
        };
        open_hairpins[number] = report.hairpin_count;
        report.hairpin_count += 1;
        return;
    }

    const index = open_hairpins[number] orelse {
        if (std.mem.eql(u8, type_name, "stop")) report.approximations += 1;
        return;
    };
    report.hairpins[index].flags |= flags & (model.hairpin_flag_niente | model.hairpin_flag_dashed | model.hairpin_flag_dotted);
    report.hairpins[index].spread = @max(report.hairpins[index].spread, spread);
    if (std.mem.eql(u8, type_name, "stop")) {
        report.hairpins[index].end_beat = @max(report.hairpins[index].start_beat + 0.001, beat);
        open_hairpins[number] = null;
    }
}

fn appendPedalEvent(report: *ImportReport, start_beat: f32, pedal: u8, value: u8, action: u8, flags: u8) Error!void {
    if (report.pedal_count == report.pedals.len) return error.TooManyPedals;
    report.pedals[report.pedal_count] = .{
        .start_beat = start_beat,
        .pedal = pedal,
        .value = value,
        .action = action,
        .flags = flags,
    };
    report.pedal_count += 1;
}

fn hasPedalSound(source: []const u8) bool {
    const sound_start = findOpenTag(source, 0, "sound") orelse return false;
    const sound_end = std.mem.indexOfPos(u8, source, sound_start, ">") orelse return false;
    const opening = source[sound_start .. sound_end + 1];
    return attributeValue(opening, "damper-pedal") != null or
        attributeValue(opening, "sostenuto-pedal") != null or
        attributeValue(opening, "soft-pedal") != null;
}

fn pedalSoundValue(opening: []const u8, comptime name: []const u8) ?u8 {
    const text = attributeValue(opening, name) orelse return null;
    if (std.mem.eql(u8, text, "yes") or std.mem.eql(u8, text, "true")) return 127;
    if (std.mem.eql(u8, text, "no") or std.mem.eql(u8, text, "false")) return 0;
    const percent = std.fmt.parseFloat(f32, text) catch return null;
    if (!std.math.isFinite(percent) or percent < 0) return null;
    return @intFromFloat(@round(std.math.clamp(percent, 0, 100) * 127.0 / 100.0));
}

fn pedalAction(type_name: []const u8) ?u8 {
    if (std.mem.eql(u8, type_name, "start") or std.mem.eql(u8, type_name, "sostenuto")) return model.pedal_action_start;
    if (std.mem.eql(u8, type_name, "stop")) return model.pedal_action_stop;
    if (std.mem.eql(u8, type_name, "change")) return model.pedal_action_change;
    if (std.mem.eql(u8, type_name, "continue")) return model.pedal_action_continue;
    if (std.mem.eql(u8, type_name, "resume")) return model.pedal_action_resume;
    if (std.mem.eql(u8, type_name, "discontinue")) return model.pedal_action_discontinue;
    return null;
}

fn inferredPedalAction(previous: u8, value: u8) u8 {
    if (previous == 0 and value != 0) return model.pedal_action_start;
    if (previous != 0 and value == 0) return model.pedal_action_stop;
    return model.pedal_action_change;
}

fn defaultPedalValue(action: u8, previous: u8) u8 {
    return switch (action) {
        model.pedal_action_stop, model.pedal_action_discontinue => 0,
        model.pedal_action_continue, model.pedal_action_change => if (previous != 0) previous else 127,
        else => 127,
    };
}

fn appendPedals(report: *ImportReport, start_beat: f32, source: []const u8, current_values: *[3]u8, numbered_kinds: *[17]u8) Error!void {
    var notation_kind: ?u8 = null;
    var notation_action: ?u8 = null;
    var notation_flags: u8 = 0;
    var notation_number: usize = 0;

    if (findOpenTag(source, 0, "pedal")) |pedal_start| {
        const pedal_end = std.mem.indexOfPos(u8, source, pedal_start, ">") orelse return error.InvalidMusicXml;
        const opening = source[pedal_start .. pedal_end + 1];
        const type_name = attributeValue(opening, "type") orelse "";
        notation_action = pedalAction(type_name);
        if (attributeIsYes(opening, "line")) notation_flags |= model.pedal_flag_line;
        if (attributeIsYes(opening, "sign")) notation_flags |= model.pedal_flag_sign;
        if (attributeValue(opening, "number")) |text| notation_number = @min(16, std.fmt.parseUnsigned(usize, text, 10) catch 0);

        if (std.mem.eql(u8, type_name, "sostenuto")) {
            notation_kind = model.pedal_sostenuto;
        } else if (notation_number != 0 and numbered_kinds[notation_number] != 255) {
            notation_kind = numbered_kinds[notation_number];
        }
    }

    var sound_values = [_]?u8{ null, null, null };
    if (findOpenTag(source, 0, "sound")) |sound_start| {
        const sound_end = std.mem.indexOfPos(u8, source, sound_start, ">") orelse return error.InvalidMusicXml;
        const sound = source[sound_start .. sound_end + 1];
        sound_values[model.pedal_sustain] = pedalSoundValue(sound, "damper-pedal");
        sound_values[model.pedal_sostenuto] = pedalSoundValue(sound, "sostenuto-pedal");
        sound_values[model.pedal_soft] = pedalSoundValue(sound, "soft-pedal");
    }

    if (notation_kind == null) {
        var sole_kind: ?u8 = null;
        for (sound_values, 0..) |value, kind| if (value != null) {
            if (sole_kind != null) {
                sole_kind = null;
                break;
            }
            sole_kind = @intCast(kind);
        };
        notation_kind = sole_kind orelse if (notation_action != null) model.pedal_sustain else null;
    }

    var emitted = [_]bool{false} ** 3;
    for (sound_values, 0..) |maybe_value, kind_index| {
        const value = maybe_value orelse continue;
        const kind: u8 = @intCast(kind_index);
        const action = if (notation_kind != null and notation_kind.? == kind and notation_action != null)
            notation_action.?
        else
            inferredPedalAction(current_values[kind_index], value);
        try appendPedalEvent(report, start_beat, kind, value, action, if (notation_kind != null and notation_kind.? == kind) notation_flags else 0);
        current_values[kind_index] = value;
        emitted[kind_index] = true;
    }

    if (notation_kind) |kind| if (!emitted[kind]) {
        const action = notation_action orelse return;
        const value = defaultPedalValue(action, current_values[kind]);
        try appendPedalEvent(report, start_beat, kind, value, action, notation_flags);
        current_values[kind] = value;
    };

    if (notation_number != 0 and notation_kind != null and notation_action != null) {
        switch (notation_action.?) {
            model.pedal_action_start, model.pedal_action_resume => numbered_kinds[notation_number] = notation_kind.?,
            model.pedal_action_stop, model.pedal_action_discontinue => numbered_kinds[notation_number] = 255,
            else => {},
        }
    }
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

test "imports continuous MusicXML performance dynamics without flattening velocities" {
    const xml =
        \\<?xml version="1.0"?><score-partwise version="4.0">
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<direction print-object="no"><direction-type><other-direction>performance</other-direction></direction-type><sound dynamics="50"/></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff></note>
        \\<direction placement="below"><direction-type><dynamics><f/></dynamics></direction-type><sound dynamics="66.667"/></direction>
        \\<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff></note>
        \\<direction print-object="no"><direction-type><other-direction>performance</other-direction></direction-type><sound dynamics="120"/></direction>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff></note>
        \\</measure></part></score-partwise>
    ;
    const imported = try parse(xml);
    try std.testing.expectEqual(@as(usize, 3), imported.note_count);
    try std.testing.expectEqual(@as(u8, 45), imported.notes[0].velocity);
    try std.testing.expectEqual(@as(u8, 60), imported.notes[1].velocity);
    try std.testing.expectEqual(@as(u8, 108), imported.notes[2].velocity);
    try std.testing.expectEqual(model.dynamic_f, model.dynamic(imported.notes[1].flags));
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

test "preserves common ornaments and directional arpeggiation without approximation" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><notations><ornaments><trill-mark placement="below"/><turn placement="below"/><inverted-turn/><mordent/><inverted-mordent/></ornaments><arpeggiate direction="down"/></notations></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(u32, 0), report.approximations);
    try std.testing.expectEqual(
        model.note_notation_ornament_mask | model.note_notation_ornament_below | model.note_notation_arpeggiate | model.note_notation_arpeggiate_down,
        report.notes[0].notations,
    );
}

test "preserves single-note tremolo while reporting another unsupported ornament" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><notations><ornaments><shake/><tremolo type="single">3</tremolo></ornaments></notations></note></measure></part>
        \\</score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(u32, 1), report.approximations);
    try std.testing.expectEqual(@as(u8, 3), model.singleTremoloMarks(report.notes[0]));
}

test "reports double-note unmeasured and invalid tremolos explicitly" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration><notations><ornaments><tremolo type="start">2</tremolo></ornaments></notations></note>
        \\<note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration><notations><ornaments><tremolo type="unmeasured">0</tremolo></ornaments></notations></note>
        \\<note><pitch><step>E</step><octave>5</octave></pitch><duration>1</duration><notations><ornaments><tremolo type="single">9</tremolo></ornaments></notations></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(u32, 3), report.approximations);
    for (report.notes[0..report.note_count]) |note| try std.testing.expectEqual(@as(u8, 0), model.singleTremoloMarks(note));
}

test "imports independently numbered overlapping slurs regardless of attribute order" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff><notations><slur number="1" placement="above" type="start"/></notations></note>
        \\<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff><notations><slur placement="above" type="start" number="2"/></notations></note>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff><notations><slur type="stop" number="2"/></notations></note>
        \\<note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff><notations><slur number="1" type="stop"/></notations></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 4), report.note_count);
    try std.testing.expectEqual(model.slurNumberBit(1), report.notes[0].slur_start_mask);
    try std.testing.expectEqual(model.slurNumberBit(2), report.notes[1].slur_start_mask);
    try std.testing.expectEqual(model.slurNumberBit(2), report.notes[2].slur_stop_mask);
    try std.testing.expectEqual(model.slurNumberBit(1), report.notes[3].slur_stop_mask);
    try std.testing.expect((report.notes[0].flags & model.note_flag_slur_above) != 0);
    try std.testing.expect((report.notes[1].flags & model.note_flag_slur_above) != 0);
}

test "imports timed lyrics and marks named vocal parts as guides" {
    const fixture =
        \\<?xml version="1.0"?>
        \\<score-partwise version="4.0">
        \\<part-list>
        \\<score-part id="P1"><part-name>Piano</part-name><midi-instrument><midi-program>1</midi-program></midi-instrument></score-part>
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
    try std.testing.expectEqual(@as(usize, 2), report.part_count);
    try std.testing.expectEqualStrings("Piano", report.parts[0].nameSlice());
    try std.testing.expectEqual(@as(u32, 1), report.parts[0].midi_program);
    try std.testing.expectEqualStrings("Vocal guide", report.parts[1].nameSlice());
    try std.testing.expect(report.parts[1].isVocal());
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

test "imports numbered MusicXML hairpins across measures with optical metadata" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1">
        \\<measure number="1"><attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<direction placement="above"><direction-type><wedge type="crescendo" number="2" spread="12" niente="yes" line-type="dashed"/></direction-type><staff>2</staff></direction>
        \\<note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><staff>2</staff></note></measure>
        \\<measure number="2"><direction placement="above"><direction-type><wedge type="stop" number="2" spread="18" line-type="dashed"/></direction-type><offset>2</offset><staff>2</staff></direction>
        \\<note><pitch><step>D</step><octave>3</octave></pitch><duration>4</duration><staff>2</staff></note></measure>
        \\</part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 1), report.hairpin_count);
    const hairpin = report.hairpins[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0), hairpin.start_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), hairpin.end_beat, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), hairpin.spread, 0.001);
    try std.testing.expectEqual(model.hairpin_crescendo, hairpin.kind);
    try std.testing.expectEqual(@as(u8, 2), hairpin.number);
    try std.testing.expectEqual(@as(u8, 1), hairpin.staff % model.staff_slots_per_part);
    try std.testing.expect((hairpin.flags & model.hairpin_flag_above) != 0);
    try std.testing.expect((hairpin.flags & model.hairpin_flag_niente) != 0);
    try std.testing.expect((hairpin.flags & model.hairpin_flag_dashed) != 0);
}

test "imports semantic sostenuto soft and continuous three-pedal sound positions" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<direction placement="below"><direction-type><words font-style="italic">una corda</words></direction-type><sound soft-pedal="50"/></direction>
        \\<direction placement="below"><direction-type><pedal type="sostenuto" number="2" line="yes"/></direction-type><sound sostenuto-pedal="yes"/></direction>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<direction placement="below"><direction-type><other-direction print-object="no">soft pedal curve</other-direction></direction-type><sound soft-pedal="75"/></direction>
        \\<direction placement="below"><direction-type><pedal type="stop" number="2" line="yes"/></direction-type></direction>
        \\<note><pitch><step>G</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<direction placement="below"><direction-type><words font-style="italic">tre corde</words></direction-type><sound soft-pedal="no"/></direction>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 5), report.pedal_count);
    try std.testing.expectEqual(model.pedal_sostenuto, report.pedals[0].pedal);
    try std.testing.expectEqual(model.pedal_action_start, report.pedals[0].action);
    try std.testing.expectEqual(@as(u8, 127), report.pedals[0].value);
    try std.testing.expect((report.pedals[0].flags & model.pedal_flag_line) != 0);
    try std.testing.expectEqual(model.pedal_soft, report.pedals[1].pedal);
    try std.testing.expectEqual(model.pedal_action_start, report.pedals[1].action);
    try std.testing.expectEqual(@as(u8, 64), report.pedals[1].value);
    try std.testing.expectEqual(model.pedal_sostenuto, report.pedals[2].pedal);
    try std.testing.expectEqual(model.pedal_action_stop, report.pedals[2].action);
    try std.testing.expectEqual(@as(u8, 0), report.pedals[2].value);
    try std.testing.expectEqual(model.pedal_soft, report.pedals[3].pedal);
    try std.testing.expectEqual(model.pedal_action_change, report.pedals[3].action);
    try std.testing.expectEqual(@as(u8, 95), report.pedals[3].value);
    try std.testing.expectEqual(model.pedal_soft, report.pedals[4].pedal);
    try std.testing.expectEqual(model.pedal_action_stop, report.pedals[4].action);
    try std.testing.expectEqual(@as(u8, 0), report.pedals[4].value);
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

test "imports forward and counted backward repeat barlines" {
    const fixture =
        \\<score-partwise version="4.0"><part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1">
        \\<measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<barline location="left"><repeat direction="forward"/></barline>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note></measure>
        \\<measure number="2"><note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration></note>
        \\<barline location="right"><repeat direction="backward" times="3"/></barline></measure>
        \\</part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(usize, 2), report.measure_count);
    try std.testing.expect(report.measures[0].hasForwardRepeat());
    try std.testing.expect(!report.measures[0].hasBackwardRepeat());
    try std.testing.expect(report.measures[1].hasBackwardRepeat());
    try std.testing.expectEqual(@as(u8, 3), report.measures[1].repeatPasses());
}

test "imports numbered alternate endings without approximation" {
    const fixture =
        \\<score-partwise version="4.0"><part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1">
        \\<measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<barline location="left"><repeat direction="forward"/></barline><note><rest/><duration>4</duration></note></measure>
        \\<measure number="2"><note><rest/><duration>4</duration></note></measure>
        \\<measure number="3"><barline location="left"><ending number="1" type="start">1.</ending></barline><note><rest/><duration>4</duration></note>
        \\<barline location="right"><ending number="1" type="stop"/><repeat direction="backward"/></barline></measure>
        \\<measure number="4"><barline location="left"><ending number="2" type="start">2.</ending></barline><note><rest/><duration>4</duration></note>
        \\<barline location="right"><ending number="2" type="discontinue"/></barline></measure>
        \\</part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(u32, 0), report.approximations);
    try std.testing.expectEqual(@as(usize, 4), report.measure_count);
    try std.testing.expectEqual(@as(u16, 1), report.measures[2].ending_mask);
    try std.testing.expect(report.measures[2].endingStarts());
    try std.testing.expect(report.measures[2].endingStops());
    try std.testing.expectEqual(@as(u16, 2), report.measures[3].ending_mask);
    try std.testing.expect((report.measures[3].ending_flags & model.measure_ending_discontinue) != 0);
}

test "imports performed grace attributes without consuming metric time" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<note><grace slash="yes" steal-time-following="33"/><pitch><step>D</step><octave>5</octave></pitch><voice>1</voice><type>eighth</type></note>
        \\<note><pitch><step>E</step><octave>5</octave></pitch><duration>4</duration><voice>1</voice></note>
        \\</measure></part></score-partwise>
    ;
    const report = try parse(fixture);
    try std.testing.expectEqual(@as(u32, 0), report.approximations);
    try std.testing.expectEqual(@as(usize, 2), report.note_count);
    try std.testing.expect((report.notes[0].flags & model.note_flag_grace) != 0);
    try std.testing.expect((report.notes[0].notations & model.note_notation_grace_slash) != 0);
    try std.testing.expectEqual(@as(u8, 33), model.graceFollowingPercent(report.notes[0]));
    try std.testing.expectEqual(@as(f32, 0), report.notes[0].start_beat);
    try std.testing.expectEqual(@as(f32, 0), report.notes[1].start_beat);
    try std.testing.expectApproxEqAbs(@as(f32, 1), report.notes[1].duration_beats, 0.001);
}
