const std = @import("std");
const score = @import("score");

const max_file_bytes = 256 * 1024 * 1024;
const max_xml_bytes = 32 * 1024 * 1024;
const opening_end_beat: f32 = 42;

const BassMode = enum {
    preserve,
    replace_where_fragment_has_notes,
};

const EnrichOptions = struct {
    end_beat: f32 = opening_end_beat,
    quarter_bpm: ?f32 = null,
    bass_mode: BassMode = .preserve,
};

const EnrichSummary = struct {
    removed_treble: usize = 0,
    removed_bass: usize = 0,
    added_treble: usize = 0,
    added_bass: usize = 0,
    target_treble_staff: u8 = 0,
    target_bass_staff: u8 = 1,
    output_notes: usize = 0,
};

const TempoPlan = struct {
    pulse_bpm: f32,
    pulse_unit: u8,
    first_quarter_bpm: f32,
    resume_beat: f32,
    resume_quarter_bpm: f32,
};

const BeatRange = struct { start: f32, end: f32 };

const CsvPitch = struct {
    start_seconds: f32,
    end_seconds: f32,
    pitch: u8,
    velocity: u8 = 64,
    source_index: u8 = 0,
};

const RecordingAnchor = struct {
    measure_number: u32,
    start_seconds: f32,
    end_seconds: f32,
};

const JsonAnchor = struct {
    measure: []const u8,
    recording_start_seconds: f32,
    recording_end_seconds: f32,
};

const JsonAnchorDocument = struct {
    measures: []const JsonAnchor,
};

const Replacement = struct {
    source: BeatRange,
    target: BeatRange,
};

const AudioAlignment = struct {
    score_instrument_notes: usize = 0,
    compared_notes: usize = 0,
    exact_pitch_matches: usize = 0,
    pitch_class_matches: usize = 0,
    assumed_tempo_bpm: f32 = 0,
    score_duration_seconds: f32 = 0,
    active_audio_duration_seconds: f32 = 0,
    start_beat: f32 = 0,
    end_beat: f32 = std.math.inf(f32),
};

const SpanIssue = struct {
    beat: f32 = 0,
    measure: u32 = 0,
    staff: u8 = 0,
    low: u8 = 0,
    high: u8 = 0,
};

const PlayabilitySummary = struct {
    instrumental_notes: usize = 0,
    onset_groups: usize = 0,
    wide_spans: usize = 0,
    extreme_spans: usize = 0,
    dense_chords: usize = 0,
    outside_piano_range: usize = 0,
    invalid_durations: usize = 0,
    dynamic_notes: usize = 0,
    articulated_notes: usize = 0,
    fingered_notes: usize = 0,
    max_span: u8 = 0,
    max_simultaneous: u8 = 0,
    fastest_gap_beats: f32 = std.math.inf(f32),
    min_pitch: [2]u8 = .{ 127, 127 },
    max_pitch: [2]u8 = .{ 0, 0 },
    span_issues: [16]SpanIssue = [_]SpanIssue{.{}} ** 16,
    span_issue_count: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const command = arguments.next() orelse return usage();
    if (std.mem.eql(u8, command, "inspect")) {
        const input_path = arguments.next() orelse return usage();
        if (arguments.next() != null) return error.UnknownArgument;
        const report = try readReport(init, input_path);
        printReport(input_path, &report);
        return;
    }
    if (std.mem.eql(u8, command, "playability")) {
        const input_path = arguments.next() orelse return usage();
        if (arguments.next() != null) return error.UnknownArgument;
        const report = try init.gpa.create(score.musicxml.ImportReport);
        defer init.gpa.destroy(report);
        try readReportInto(init, input_path, report);
        printPlayability(input_path, report);
        return;
    }
    if (std.mem.eql(u8, command, "revoice")) {
        try runRevoice(init, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "opening-performance")) {
        try runOpeningPerformance(init, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "splice-opening")) {
        try runSpliceOpening(init, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "pattern-fragment")) {
        try runPatternFragment(init, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "enrich-opening")) {
        const target_path = arguments.next() orelse return usage();
        const fragment_path = arguments.next() orelse return usage();
        const output_path = arguments.next() orelse return usage();
        var options: EnrichOptions = .{};
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--end-beat")) {
                options.end_beat = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--quarter-bpm")) {
                options.quarter_bpm = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--replace-fragment-bass")) {
                options.bass_mode = .replace_where_fragment_has_notes;
            } else {
                return error.UnknownArgument;
            }
        }
        const target = try readReport(init, target_path);
        const fragment = try readReport(init, fragment_path);
        var result = try enrichOpening(init.gpa, &target, &fragment, options);
        defer result.notes.deinit(init.gpa);
        defer result.harmonies.deinit(init.gpa);
        try writeMxl(init, output_path, &target, result.notes.items, target.lyrics[0..target.lyric_count], result.harmonies.items, target.pedals[0..target.pedal_count], target.measures[0..target.measure_count], options.quarter_bpm, null);
        std.debug.print(
            "Wrote {s}: treble -{d}/+{d}, bass -{d}/+{d}, {d} total events; target staves {d}/{d}\n",
            .{ output_path, result.summary.removed_treble, result.summary.added_treble, result.summary.removed_bass, result.summary.added_bass, result.summary.output_notes, result.summary.target_treble_staff, result.summary.target_bass_staff },
        );
        const output_report = try readReport(init, output_path);
        printReport(output_path, &output_report);
        return;
    }
    if (std.mem.eql(u8, command, "evidence")) {
        const score_path = arguments.next() orelse return usage();
        var csv_paths: [8][]const u8 = undefined;
        var csv_count: usize = 0;
        var start_beat: f32 = 0;
        var end_beat: f32 = opening_end_beat;
        var quarter_bpm: f32 = 147;
        var tolerance_seconds: f32 = 0.08;
        var anchor_path: ?[]const u8 = null;
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--csv")) {
                if (csv_count == csv_paths.len) return error.TooManyCsvInputs;
                csv_paths[csv_count] = arguments.next() orelse return error.MissingValue;
                csv_count += 1;
            } else if (std.mem.eql(u8, argument, "--start-beat")) {
                start_beat = try parseNonNegativeFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--end-beat")) {
                end_beat = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--quarter-bpm")) {
                quarter_bpm = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--tolerance")) {
                tolerance_seconds = try parseNonNegativeFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--anchors")) {
                anchor_path = arguments.next() orelse return error.MissingValue;
            } else {
                return error.UnknownArgument;
            }
        }
        if (csv_count == 0 or end_beat <= start_beat) return error.InvalidArguments;
        const report = try readReport(init, score_path);
        try compareCsvEvidence(init, score_path, &report, csv_paths[0..csv_count], .{ .start = start_beat, .end = end_beat }, quarter_bpm, tolerance_seconds, anchor_path);
        return;
    }
    if (std.mem.eql(u8, command, "audio-evidence")) {
        try runAudioEvidence(init, &arguments);
        return;
    }
    if (std.mem.eql(u8, command, "enrich-evidence")) {
        const target_path = arguments.next() orelse return usage();
        const output_path = arguments.next() orelse return usage();
        var csv_paths: [8][]const u8 = undefined;
        var csv_count: usize = 0;
        var start_beat: f32 = 0;
        var end_beat: f32 = 0;
        var grid: f32 = 0.5;
        var onset_tolerance: f32 = 0.12;
        var minimum_sources: u8 = 2;
        var anchor_path: ?[]const u8 = null;
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--csv")) {
                if (csv_count == csv_paths.len) return error.TooManyCsvInputs;
                csv_paths[csv_count] = arguments.next() orelse return error.MissingValue;
                csv_count += 1;
            } else if (std.mem.eql(u8, argument, "--anchors")) {
                anchor_path = arguments.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, argument, "--start-beat")) {
                start_beat = try parseNonNegativeFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--end-beat")) {
                end_beat = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--grid")) {
                grid = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--onset-tolerance")) {
                onset_tolerance = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--min-sources")) {
                minimum_sources = try std.fmt.parseUnsigned(u8, arguments.next() orelse return error.MissingValue, 10);
            } else {
                return error.UnknownArgument;
            }
        }
        if (csv_count == 0 or anchor_path == null or end_beat <= start_beat or minimum_sources == 0 or minimum_sources > csv_count) return error.InvalidArguments;
        const target = try readReport(init, target_path);
        var result = try enrichFromEvidence(init, &target, csv_paths[0..csv_count], anchor_path.?, .{ .start = start_beat, .end = end_beat }, grid, onset_tolerance, minimum_sources);
        defer result.notes.deinit(init.gpa);
        try writeMxl(init, output_path, &target, result.notes.items, target.lyrics[0..target.lyric_count], target.harmonies[0..target.harmony_count], target.pedals[0..target.pedal_count], target.measures[0..target.measure_count], null, null);
        std.debug.print("Wrote {s}: added={d} treble={d} bass={d} corroborated by >= {d} sources\n", .{ output_path, result.added_treble + result.added_bass, result.added_treble, result.added_bass, minimum_sources });
        const output_report = try readReport(init, output_path);
        printReport(output_path, &output_report);
        return;
    }
    if (std.mem.eql(u8, command, "find-repeats")) {
        const score_path = arguments.next() orelse return usage();
        var pattern_start: f32 = 0;
        var pattern_end: f32 = opening_end_beat;
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--pattern-start")) {
                pattern_start = try parseNonNegativeFloat(arguments.next() orelse return error.MissingValue);
            } else if (std.mem.eql(u8, argument, "--pattern-end")) {
                pattern_end = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else {
                return error.UnknownArgument;
            }
        }
        if (pattern_end <= pattern_start) return error.InvalidBeatRange;
        const report = try readReport(init, score_path);
        printExactTrebleRepeats(score_path, &report, .{ .start = pattern_start, .end = pattern_end });
        return;
    }
    if (std.mem.eql(u8, command, "enrich-repeats")) {
        const target_path = arguments.next() orelse return usage();
        const fragment_path = arguments.next() orelse return usage();
        const output_path = arguments.next() orelse return usage();
        var patterns: [8]BeatRange = undefined;
        var pattern_count: usize = 0;
        var quarter_bpm: ?f32 = null;
        while (arguments.next()) |argument| {
            if (std.mem.eql(u8, argument, "--pattern")) {
                if (pattern_count == patterns.len) return error.TooManyPatterns;
                patterns[pattern_count] = try parseBeatRange(arguments.next() orelse return error.MissingValue);
                pattern_count += 1;
            } else if (std.mem.eql(u8, argument, "--quarter-bpm")) {
                quarter_bpm = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
            } else {
                return error.UnknownArgument;
            }
        }
        if (pattern_count == 0) return error.InvalidArguments;
        const target = try readReport(init, target_path);
        const fragment = try readReport(init, fragment_path);
        var result = try enrichExactRepeats(init.gpa, &target, &fragment, patterns[0..pattern_count]);
        defer result.notes.deinit(init.gpa);
        defer result.harmonies.deinit(init.gpa);
        try writeMxl(init, output_path, &target, result.notes.items, target.lyrics[0..target.lyric_count], result.harmonies.items, target.pedals[0..target.pedal_count], target.measures[0..target.measure_count], quarter_bpm, null);
        std.debug.print("Wrote {s}: replacements={d} treble -{d}/+{d}, total events={d}\n", .{ output_path, result.replacement_count, result.removed_treble, result.added_treble, result.notes.items.len });
        const output_report = try readReport(init, output_path);
        printReport(output_path, &output_report);
        return;
    }
    return usage();
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  score-workbench inspect SCORE.musicxml|SCORE.mxl
        \\  score-workbench playability SCORE.musicxml|SCORE.mxl
        \\  score-workbench revoice INPUT.mxl OUTPUT.mxl --beat N [--beat N ...] --pitch MIDI --from-staff N --to-staff N
        \\  score-workbench opening-performance INPUT.mxl OUTPUT.mxl [--repeat-start-measure 4] [--repeat-end-measure 13] [--pedal-value 54]
        \\  score-workbench splice-opening TARGET.mxl FRAGMENT.musicxml|mxl OUTPUT.mxl --target-end-beat N [--repeat-count N]
        \\  score-workbench pattern-fragment TEMPLATE.mxl PATTERN.txt OUTPUT.mxl
        \\  score-workbench enrich-opening TARGET.mxl FRAGMENT.mxl OUTPUT.mxl [--end-beat 42] [--quarter-bpm 147] [--replace-fragment-bass]
        \\  score-workbench evidence SCORE.mxl --csv EVENTS.csv [--csv EVENTS.csv ...] [--anchors REVIEW.json] [--start-beat 0] [--end-beat 42] [--quarter-bpm 147] [--tolerance 0.08]
        \\  score-workbench audio-evidence INPUT.wav [--score SCORE.musicxml|SCORE.mxl] [--output REPORT.json] [--start-beat N] [--end-beat N]
        \\  score-workbench enrich-evidence TARGET.mxl OUTPUT.mxl --anchors REVIEW.json --csv EVENTS.csv [--csv EVENTS.csv ...] --start-beat N --end-beat N [--grid 0.5] [--onset-tolerance 0.12] [--min-sources 2]
        \\  score-workbench find-repeats SCORE.mxl [--pattern-start 0] [--pattern-end 42]
        \\  score-workbench enrich-repeats TARGET.mxl FRAGMENT.mxl OUTPUT.mxl --pattern START:END [--pattern START:END ...] [--quarter-bpm 147]
        \\
    , .{});
    return error.InvalidArguments;
}

fn parsePitchList(text_value: []const u8, output: *[32]u8) !usize {
    var count: usize = 0;
    var values = std.mem.splitScalar(u8, text_value, ',');
    while (values.next()) |value| {
        if (count == output.len) return error.TooManyPitchArguments;
        output[count] = try std.fmt.parseUnsigned(u8, std.mem.trim(u8, value, " \t\r"), 10);
        if (output[count] > 127) return error.InvalidArguments;
        count += 1;
    }
    if (count == 0) return error.InvalidArguments;
    return count;
}

fn parseOptionalPitchList(text_value: []const u8, output: *[32]u8) !usize {
    if (std.mem.eql(u8, text_value, "-")) return 0;
    return parsePitchList(text_value, output);
}

fn runPatternFragment(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const template_path = arguments.next() orelse return usage();
    const pattern_path = arguments.next() orelse return usage();
    const output_path = arguments.next() orelse return usage();
    if (arguments.next() != null) return error.UnknownArgument;
    const template = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(template);
    try readReportInto(init, template_path, template);
    const pattern_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, pattern_path, init.gpa, .limited(256 * 1024));
    defer init.gpa.free(pattern_bytes);

    var notes: std.ArrayList(score.model.Note) = .empty;
    defer notes.deinit(init.gpa);
    var harmonies: std.ArrayList(score.model.Harmony) = .empty;
    defer harmonies.deinit(init.gpa);
    var pedals: std.ArrayList(score.model.PedalEvent) = .empty;
    defer pedals.deinit(init.gpa);
    var measures: std.ArrayList(score.model.Measure) = .empty;
    defer measures.deinit(init.gpa);
    var cursor: f32 = 0;
    var measure_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, pattern_bytes, '\n');
    while (lines.next()) |untrimmed| {
        const line = std.mem.trim(u8, untrimmed, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [8][]const u8 = undefined;
        var field_count: usize = 0;
        var field_iterator = std.mem.splitScalar(u8, line, '|');
        while (field_iterator.next()) |field| {
            if (field_count == fields.len) return error.InvalidArguments;
            fields[field_count] = std.mem.trim(u8, field, " \t\r");
            field_count += 1;
        }
        if (field_count != fields.len or fields[1].len != 1 or (fields[4].len != 1 and !std.mem.eql(u8, fields[4], "-"))) return error.InvalidArguments;
        const beats = try std.fmt.parseUnsigned(u8, fields[0], 10);
        if (beats == 0) return error.InvalidArguments;
        const root_alter = try std.fmt.parseInt(i8, fields[2], 10);
        const bass_alter = try std.fmt.parseInt(i8, fields[5], 10);
        var right_pitches: [32]u8 = undefined;
        const right_count = try parsePitchList(fields[6], &right_pitches);
        var left_pitches: [32]u8 = undefined;
        const left_count = try parseOptionalPitchList(fields[7], &left_pitches);
        if (left_count > 5) return error.InvalidArguments;

        try measures.append(init.gpa, .{
            .start_beat = cursor,
            .duration_beats = @floatFromInt(beats),
            .number = measure_number,
            .beats = beats,
            .beat_unit = 4,
        });
        var harmony: score.model.Harmony = .{
            .start_beat = cursor,
            .root_step = fields[1][0],
            .root_alter = root_alter,
            .bass_step = if (std.mem.eql(u8, fields[4], "-")) 0 else fields[4][0],
            .bass_alter = bass_alter,
        };
        harmony.setKind(fields[3]);
        if (std.mem.eql(u8, fields[3], "minor-seventh")) {
            harmony.setText("m7");
        } else if (std.mem.eql(u8, fields[3], "dominant-13th")) {
            harmony.setText("13");
        }
        try harmonies.append(init.gpa, harmony);
        try pedals.append(init.gpa, .{
            .start_beat = cursor,
            .pedal = score.model.pedal_sustain,
            .value = 54,
            .action = if (measure_number == 1) score.model.pedal_action_start else score.model.pedal_action_change,
            .flags = score.model.pedal_flag_line | score.model.pedal_flag_sign,
        });

        const right_duration = @as(f32, @floatFromInt(beats)) / @as(f32, @floatFromInt(right_count));
        for (right_pitches[0..right_count], 0..) |pitch, pitch_index| {
            var flags: u32 = if (pitch_index % 2 == 0) score.model.note_flag_beam_begin else score.model.note_flag_beam_end;
            if (notes.items.len == 0) flags = score.model.withDynamic(flags, score.model.dynamic_mf);
            const phrase_accent = pitch_index == 0 or pitch_index == right_count / 2;
            var note: score.model.Note = .{
                .stable_id = notes.items.len + 1,
                .start_beat = cursor + @as(f32, @floatFromInt(pitch_index)) * right_duration,
                .duration_beats = right_duration * 0.92,
                .pitch = pitch,
                .velocity = if (phrase_accent) 86 else 76,
                .staff = 0,
                .voice = 0,
                .flags = flags,
            };
            applyPitchSpelling(&note, template.key_fifths);
            try notes.append(init.gpa, note);
        }
        if (left_count != 0) {
            const left_duration = @as(f32, @floatFromInt(beats)) / 2.0;
            for (0..2) |half| {
                for (left_pitches[0..left_count], 0..) |pitch, pitch_index| {
                    var note: score.model.Note = .{
                        .stable_id = notes.items.len + 1,
                        .start_beat = cursor + @as(f32, @floatFromInt(half)) * left_duration,
                        .duration_beats = left_duration * 0.94,
                        .pitch = pitch,
                        .velocity = if (pitch_index == 0) 72 else 66,
                        .staff = 1,
                        .voice = 0,
                    };
                    applyPitchSpelling(&note, template.key_fifths);
                    try notes.append(init.gpa, note);
                }
            }
        }
        cursor += @floatFromInt(beats);
        measure_number += 1;
    }
    if (measures.items.len == 0) return error.InvalidArguments;
    try pedals.append(init.gpa, .{
        // Keep the terminal controller inside the final measure. An event at
        // the exact right edge would be serialized into a phantom fallback
        // measure by MusicXML's half-open measure routing.
        .start_beat = @max(0, cursor - 0.001),
        .pedal = score.model.pedal_sustain,
        .value = 0,
        .action = score.model.pedal_action_stop,
        .flags = score.model.pedal_flag_line | score.model.pedal_flag_sign,
    });
    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    for (notes.items, 0..) |*note, index| note.stable_id = index + 1;
    try writeMxl(init, output_path, template, notes.items, &.{}, harmonies.items, pedals.items, measures.items, 147, null);
    const output_report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(output_report);
    try readReportInto(init, output_path, output_report);
    std.debug.print("Wrote {s}: {d} measures, {d:.3} beats, {d} piano notes, {d} harmony changes\n", .{ output_path, measures.items.len, cursor, notes.items.len, harmonies.items.len });
    printReport(output_path, output_report);
}

fn runSpliceOpening(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const target_path = arguments.next() orelse return usage();
    const fragment_path = arguments.next() orelse return usage();
    const output_path = arguments.next() orelse return usage();
    var target_end_beat: ?f32 = null;
    var repeat_count: u32 = 1;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--target-end-beat")) {
            target_end_beat = try parsePositiveFloat(arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--repeat-count")) {
            repeat_count = try std.fmt.parseUnsigned(u32, arguments.next() orelse return error.MissingValue, 10);
            if (repeat_count == 0 or repeat_count > 32) return error.InvalidArguments;
        } else {
            return error.UnknownArgument;
        }
    }
    const target_cut = target_end_beat orelse return error.MissingValue;
    const target = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(target);
    try readReportInto(init, target_path, target);
    const fragment = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(fragment);
    try readReportInto(init, fragment_path, fragment);
    const fragment_duration = scoreEnd(fragment);
    if (fragment_duration <= 0 or target_cut >= scoreEnd(target)) return error.InvalidArguments;
    const replacement_duration = fragment_duration * @as(f32, @floatFromInt(repeat_count));
    const shift = replacement_duration - target_cut;

    var notes: std.ArrayList(score.model.Note) = .empty;
    defer notes.deinit(init.gpa);
    for (0..repeat_count) |repeat_index| {
        const offset = fragment_duration * @as(f32, @floatFromInt(repeat_index));
        for (fragment.notes[0..fragment.note_count]) |source| {
            var note = source;
            note.start_beat += offset;
            if (repeat_index > 0 and @abs(source.start_beat) < 0.0001 and (source.flags & score.model.note_flag_rest) == 0) {
                note.flags = score.model.withDynamic(note.flags & 0x0fff_ffff, score.model.dynamic_f);
                note.velocity = 94;
            }
            try notes.append(init.gpa, note);
        }
    }
    for (target.notes[0..target.note_count]) |source| {
        if (source.start_beat < target_cut - 0.0001) continue;
        var note = source;
        note.start_beat += shift;
        try notes.append(init.gpa, note);
    }
    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    for (notes.items, 0..) |*note, index| note.stable_id = index + 1;

    var lyrics: std.ArrayList(score.model.Lyric) = .empty;
    defer lyrics.deinit(init.gpa);
    for (0..repeat_count) |repeat_index| {
        const offset = fragment_duration * @as(f32, @floatFromInt(repeat_index));
        for (fragment.lyrics[0..fragment.lyric_count]) |source| {
            var lyric = source;
            lyric.start_beat += offset;
            try lyrics.append(init.gpa, lyric);
        }
    }
    for (target.lyrics[0..target.lyric_count]) |source| {
        if (source.start_beat < target_cut - 0.0001) continue;
        var lyric = source;
        lyric.start_beat += shift;
        try lyrics.append(init.gpa, lyric);
    }

    var harmonies: std.ArrayList(score.model.Harmony) = .empty;
    defer harmonies.deinit(init.gpa);
    for (0..repeat_count) |repeat_index| {
        const offset = fragment_duration * @as(f32, @floatFromInt(repeat_index));
        for (fragment.harmonies[0..fragment.harmony_count]) |source| {
            var harmony = source;
            harmony.start_beat += offset;
            try harmonies.append(init.gpa, harmony);
        }
    }
    for (target.harmonies[0..target.harmony_count]) |source| {
        if (source.start_beat < target_cut - 0.0001) continue;
        var harmony = source;
        harmony.start_beat += shift;
        try harmonies.append(init.gpa, harmony);
    }
    std.mem.sort(score.model.Harmony, harmonies.items, {}, harmonyLessThan);

    var pedals: std.ArrayList(score.model.PedalEvent) = .empty;
    defer pedals.deinit(init.gpa);
    for (0..repeat_count) |repeat_index| {
        const offset = fragment_duration * @as(f32, @floatFromInt(repeat_index));
        for (fragment.pedals[0..fragment.pedal_count]) |source| {
            var pedal = source;
            pedal.start_beat += offset;
            try pedals.append(init.gpa, pedal);
        }
    }
    for (target.pedals[0..target.pedal_count]) |source| {
        if (source.start_beat < target_cut - 0.0001) continue;
        var pedal = source;
        pedal.start_beat += shift;
        try pedals.append(init.gpa, pedal);
    }
    std.mem.sort(score.model.PedalEvent, pedals.items, {}, struct {
        fn lessThan(_: void, left: score.model.PedalEvent, right: score.model.PedalEvent) bool {
            if (left.start_beat != right.start_beat) return left.start_beat < right.start_beat;
            return left.action < right.action;
        }
    }.lessThan);

    var measures: std.ArrayList(score.model.Measure) = .empty;
    defer measures.deinit(init.gpa);
    for (0..repeat_count) |repeat_index| {
        const offset = fragment_duration * @as(f32, @floatFromInt(repeat_index));
        for (fragment.measures[0..fragment.measure_count]) |source| {
            var measure = source;
            measure.start_beat += offset;
            try measures.append(init.gpa, measure);
        }
    }
    for (target.measures[0..target.measure_count]) |source| {
        if (source.start_beat < target_cut - 0.0001) continue;
        var measure = source;
        measure.start_beat += shift;
        try measures.append(init.gpa, measure);
    }
    for (measures.items, 0..) |*measure, index| measure.number = @intCast(index + 1);

    try writeMxl(init, output_path, target, notes.items, lyrics.items, harmonies.items, pedals.items, measures.items, null, null);
    const output_report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(output_report);
    try readReportInto(init, output_path, output_report);
    std.debug.print("Wrote {s}: replaced beats 0..{d:.3} with {d} x {d:.3}-beat fragment ({d:.3} beats), shifted remainder by {d:.3} beats\n", .{ output_path, target_cut, repeat_count, fragment_duration, replacement_duration, shift });
    printReport(output_path, output_report);
}

fn runRevoice(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const input_path = arguments.next() orelse return usage();
    const output_path = arguments.next() orelse return usage();
    var beats: [16]f32 = undefined;
    var beat_count: usize = 0;
    var pitch: ?u8 = null;
    var from_staff: ?u8 = null;
    var to_staff: ?u8 = null;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--beat")) {
            if (beat_count == beats.len) return error.TooManyBeatArguments;
            beats[beat_count] = try parseNonNegativeFloat(arguments.next() orelse return error.MissingValue);
            beat_count += 1;
        } else if (std.mem.eql(u8, argument, "--pitch")) {
            pitch = try std.fmt.parseUnsigned(u8, arguments.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--from-staff")) {
            from_staff = try std.fmt.parseUnsigned(u8, arguments.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--to-staff")) {
            to_staff = try std.fmt.parseUnsigned(u8, arguments.next() orelse return error.MissingValue, 10);
        } else {
            return error.UnknownArgument;
        }
    }
    if (beat_count == 0 or pitch == null or from_staff == null or to_staff == null or from_staff.? == to_staff.?) return error.InvalidArguments;
    const report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(report);
    try readReportInto(init, input_path, report);
    var notes: std.ArrayList(score.model.Note) = .empty;
    defer notes.deinit(init.gpa);
    try notes.appendSlice(init.gpa, report.notes[0..report.note_count]);
    const changed = revoiceNotes(notes.items, beats[0..beat_count], pitch.?, from_staff.?, to_staff.?);
    if (changed != beat_count) return error.RevoiceMatchCount;
    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    try writeMxl(init, output_path, report, notes.items, report.lyrics[0..report.lyric_count], report.harmonies[0..report.harmony_count], report.pedals[0..report.pedal_count], report.measures[0..report.measure_count], null, null);
    std.debug.print("Wrote {s}: revoiced={d} pitch={d} staff={d}->{d}\n", .{ output_path, changed, pitch.?, from_staff.?, to_staff.? });
}

fn runOpeningPerformance(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const input_path = arguments.next() orelse return usage();
    const output_path = arguments.next() orelse return usage();
    var repeat_start_measure: u32 = 4;
    var repeat_end_measure: u32 = 13;
    var pedal_value: u8 = 54;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--repeat-start-measure")) {
            repeat_start_measure = try std.fmt.parseUnsigned(u32, arguments.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--repeat-end-measure")) {
            repeat_end_measure = try std.fmt.parseUnsigned(u32, arguments.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, argument, "--pedal-value")) {
            pedal_value = try std.fmt.parseUnsigned(u8, arguments.next() orelse return error.MissingValue, 10);
            if (pedal_value == 0 or pedal_value > 127) return error.InvalidArguments;
        } else {
            return error.UnknownArgument;
        }
    }

    const report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(report);
    try readReportInto(init, input_path, report);
    const treble_staff = findInstrumentStaff(report, false) orelse return error.TargetTrebleMissing;
    const bass_staff = findInstrumentStaff(report, true) orelse return error.TargetBassMissing;
    if (repeat_end_measure <= repeat_start_measure) return error.InvalidArguments;
    const repeat_start = measureStartByNumber(report, repeat_start_measure) orelse return error.RepeatMeasureMissing;
    const insertion_beat = measureStartByNumber(report, repeat_end_measure) orelse return error.RepeatMeasureMissing;
    const repeat_duration = insertion_beat - repeat_start;
    if (repeat_duration <= 0) return error.InvalidRepeatRange;
    const opening_end = insertion_beat + repeat_duration;

    var notes: std.ArrayList(score.model.Note) = .empty;
    defer notes.deinit(init.gpa);
    var removed_attack_notes: usize = 0;
    for (report.notes[0..report.note_count]) |note| {
        // Recording-derived opening evidence begins with the inner Db alone;
        // Ab enters on the following pick and the low Db is delayed. The OMR
        // fragment had stacked all three at time zero, producing a blunt
        // piano chord instead of the recording's unfolding guitar figure.
        const remove_stacked_opening = @abs(note.start_beat) < 0.0001 and
            ((note.staff == treble_staff and note.pitch == 68) or (note.staff == bass_staff and note.pitch == 49)) and
            (note.flags & (score.model.note_flag_rest | score.model.note_flag_vocal_guide)) == 0;
        if (remove_stacked_opening) {
            removed_attack_notes += 1;
            continue;
        }
        var shifted = note;
        if (shifted.start_beat >= insertion_beat - 0.0001) shifted.start_beat += repeat_duration;
        try notes.append(init.gpa, shifted);
        if (note.start_beat >= repeat_start - 0.0001 and note.start_beat < insertion_beat - 0.0001) {
            var repeated = note;
            repeated.start_beat = insertion_beat + (note.start_beat - repeat_start);
            try notes.append(init.gpa, repeated);
        }
    }
    if (removed_attack_notes != 2) return error.UnexpectedOpeningVoicing;
    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    for (notes.items, 0..) |*note, index| note.stable_id = index + 1;

    var lyrics: std.ArrayList(score.model.Lyric) = .empty;
    defer lyrics.deinit(init.gpa);
    for (report.lyrics[0..report.lyric_count]) |lyric| {
        var shifted = lyric;
        if (shifted.start_beat >= insertion_beat - 0.0001) shifted.start_beat += repeat_duration;
        try lyrics.append(init.gpa, shifted);
    }

    var harmonies: std.ArrayList(score.model.Harmony) = .empty;
    defer harmonies.deinit(init.gpa);
    for (report.harmonies[0..report.harmony_count]) |harmony| {
        var shifted = harmony;
        if (shifted.start_beat >= insertion_beat - 0.0001) shifted.start_beat += repeat_duration;
        try harmonies.append(init.gpa, shifted);
        if (harmony.start_beat >= repeat_start - 0.0001 and harmony.start_beat < insertion_beat - 0.0001) {
            var repeated = harmony;
            repeated.start_beat = insertion_beat + (harmony.start_beat - repeat_start);
            try harmonies.append(init.gpa, repeated);
        }
    }
    std.mem.sort(score.model.Harmony, harmonies.items, {}, harmonyLessThan);

    var measures: std.ArrayList(score.model.Measure) = .empty;
    defer measures.deinit(init.gpa);
    for (report.measures[0..report.measure_count]) |measure| {
        if (measure.start_beat < insertion_beat - 0.0001) try measures.append(init.gpa, measure);
    }
    for (report.measures[0..report.measure_count]) |measure| {
        if (measure.start_beat < repeat_start - 0.0001 or measure.start_beat >= insertion_beat - 0.0001) continue;
        var repeated = measure;
        repeated.start_beat = insertion_beat + (measure.start_beat - repeat_start);
        try measures.append(init.gpa, repeated);
    }
    for (report.measures[0..report.measure_count]) |measure| {
        if (measure.start_beat < insertion_beat - 0.0001) continue;
        var shifted = measure;
        shifted.start_beat += repeat_duration;
        try measures.append(init.gpa, shifted);
    }
    for (measures.items, 0..) |*measure, index| measure.number = @intCast(index + 1);

    var marked_mf = false;
    var marked_f = false;
    for (notes.items) |*note| {
        if ((note.flags & (score.model.note_flag_rest | score.model.note_flag_vocal_guide)) != 0 or note.start_beat >= opening_end) continue;
        if (!marked_mf) {
            note.flags = score.model.withDynamic(note.flags & 0x0fff_ffff, score.model.dynamic_mf);
            note.velocity = 78;
            marked_mf = true;
        } else if (!marked_f and note.start_beat >= insertion_beat) {
            note.flags = score.model.withDynamic(note.flags & 0x0fff_ffff, score.model.dynamic_f);
            note.velocity = 94;
            marked_f = true;
        }
    }
    if (!marked_mf) return error.OpeningHasNoInstrumentNotes;

    var pedals: std.ArrayList(score.model.PedalEvent) = .empty;
    defer pedals.deinit(init.gpa);
    for (report.pedals[0..report.pedal_count]) |pedal| {
        if (pedal.start_beat < insertion_beat - 0.0001) continue;
        var shifted = pedal;
        shifted.start_beat += repeat_duration;
        if (shifted.start_beat >= opening_end) try pedals.append(init.gpa, shifted);
    }
    const pedal_flags = score.model.pedal_flag_line | score.model.pedal_flag_sign;
    try pedals.append(init.gpa, .{
        .start_beat = 0,
        .pedal = score.model.pedal_sustain,
        .value = pedal_value,
        .action = score.model.pedal_action_start,
        .flags = pedal_flags,
    });
    var last_change: f32 = 0;
    var added_changes: usize = 0;
    for (harmonies.items) |harmony| {
        if (harmony.start_beat <= 0.001 or harmony.start_beat >= opening_end or harmony.start_beat - last_change < 0.25) continue;
        try pedals.append(init.gpa, .{
            .start_beat = harmony.start_beat,
            .pedal = score.model.pedal_sustain,
            .value = pedal_value,
            .action = score.model.pedal_action_change,
            .flags = pedal_flags,
        });
        last_change = harmony.start_beat;
        added_changes += 1;
    }
    try pedals.append(init.gpa, .{
        .start_beat = opening_end,
        .pedal = score.model.pedal_sustain,
        .value = 0,
        .action = score.model.pedal_action_stop,
        .flags = pedal_flags,
    });
    std.mem.sort(score.model.PedalEvent, pedals.items, {}, struct {
        fn lessThan(_: void, left: score.model.PedalEvent, right: score.model.PedalEvent) bool {
            if (left.start_beat != right.start_beat) return left.start_beat < right.start_beat;
            return left.action < right.action;
        }
    }.lessThan);

    try writeMxl(init, output_path, report, notes.items, lyrics.items, harmonies.items, pedals.items, measures.items, null, null);
    const output_report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(output_report);
    try readReportInto(init, output_path, output_report);
    var first_vocal_beat = std.math.inf(f32);
    for (output_report.notes[0..output_report.note_count]) |note| {
        if ((note.flags & score.model.note_flag_vocal_guide) == 0 or (note.flags & score.model.note_flag_rest) != 0) continue;
        first_vocal_beat = @min(first_vocal_beat, note.start_beat);
    }
    const first_vocal_seconds = if (std.math.isFinite(first_vocal_beat)) reportSecondsAtBeat(output_report, first_vocal_beat) else std.math.inf(f32);
    std.debug.print(
        "Wrote {s}: removed stacked opening notes={d}, inserted measures {d}..{d} ({d:.1} beats) at beat {d:.1}, first vocal beat={d:.1} ({d:.3}s), dynamics=mf/f, pedal start+{d} changes+stop, continuous CC64={d}\n",
        .{ output_path, removed_attack_notes, repeat_start_measure, repeat_end_measure - 1, repeat_duration, insertion_beat, first_vocal_beat, first_vocal_seconds, added_changes, pedal_value },
    );
    printReport(output_path, output_report);
}

fn runAudioEvidence(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const audio_path = arguments.next() orelse return error.MissingAudioPath;
    var score_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var start_beat: f32 = 0;
    var end_beat: f32 = std.math.inf(f32);
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--score")) {
            score_path = arguments.next() orelse return error.MissingScorePath;
        } else if (std.mem.eql(u8, argument, "--output")) {
            output_path = arguments.next() orelse return error.MissingOutputPath;
        } else if (std.mem.eql(u8, argument, "--start-beat")) {
            start_beat = try parseNonNegativeFloat(arguments.next() orelse return error.MissingStartBeat);
        } else if (std.mem.eql(u8, argument, "--end-beat")) {
            end_beat = try parsePositiveFloat(arguments.next() orelse return error.MissingEndBeat);
        } else {
            return error.UnknownArgument;
        }
    }
    if (end_beat <= start_beat) return error.InvalidBeatRange;

    // ImportReport intentionally owns fixed-capacity notation buffers. Keeping
    // one inline in this function makes the Debug stack frame large enough to
    // collide with the offline analyzer's own working set on macOS. Put the
    // optional report on the heap so this command is reliable in hot-reload
    // development builds as well as optimized review builds.
    var imported_report: ?*score.musicxml.ImportReport = null;
    defer if (imported_report) |report| init.gpa.destroy(report);
    if (score_path) |path| {
        const report = try init.gpa.create(score.musicxml.ImportReport);
        errdefer init.gpa.destroy(report);
        try readReportInto(init, path, report);
        imported_report = report;
    }

    const audio_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, audio_path, init.gpa, .limited(2 * 1024 * 1024 * 1024));
    defer init.gpa.free(audio_bytes);
    var decoded = try score.wav.decode(init.gpa, audio_bytes);
    defer decoded.deinit();
    var analysis = try score.transcribe.analyze(init.gpa, decoded.samples, decoded.sample_rate);
    defer analysis.deinit();

    var alignment: ?AudioAlignment = null;
    if (imported_report) |report| alignment = alignAudioScore(&analysis, report, start_beat, end_beat);

    var allocating: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating.deinit();
    const writer = &allocating.writer;
    try writer.writeAll("{\n  \"schema\": 2,\n  \"analysis_kind\": \"polyphonic-evidence-not-authoritative-transcription\",");
    try writer.print("\n  \"sample_rate\": {d},\n  \"duration_seconds\": {d:.4},\n  \"active_audio\": {{\"start_seconds\":{d:.4},\"end_seconds\":{d:.4}}},\n  \"estimated_tempo_bpm\": {d:.2},\n  \"tempo_confidence\": {d:.4},", .{ decoded.sample_rate, analysis.duration_seconds, analysis.active_start_seconds, analysis.active_end_seconds, analysis.estimated_tempo_bpm, analysis.tempo_confidence });
    try writer.writeAll("\n  \"tempo_candidates\": [");
    for (analysis.tempo_candidates[0..analysis.tempo_candidate_count], 0..) |candidate, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{{\"bpm\":{d:.2},\"relative_score\":{d:.4}}}", .{ candidate.bpm, candidate.relative_score });
    }
    try writer.writeAll("],\n  \"tempo_segments\": [");
    for (analysis.tempo_segments, 0..) |segment, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{{\"start_seconds\":{d:.3},\"end_seconds\":{d:.3},\"bpm\":{d:.2},\"confidence\":{d:.4}}}", .{ segment.start_seconds, segment.end_seconds, segment.bpm, segment.confidence });
    }
    try writer.writeAll("],\n  \"onsets_seconds\": [");
    for (analysis.onsets, 0..) |onset, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{d:.4}", .{onset});
    }
    try writer.writeAll("],\n  \"frames\": [\n");
    for (analysis.frames, 0..) |frame, frame_index| {
        if (frame_index != 0) try writer.writeAll(",\n");
        try writer.print("    {{\"time\":{d:.4},\"rms\":{d:.6},\"onset\":{d:.6},\"bass\":", .{ frame.time_seconds, frame.rms, frame.onset_strength });
        if (frame.bass_pitch == 255) try writer.writeAll("null") else try writer.print("{d}", .{frame.bass_pitch});
        try writer.writeAll(",\"pitches\":[");
        for (frame.pitches[0..frame.pitch_count], 0..) |pitch, pitch_index| {
            if (pitch_index != 0) try writer.writeAll(",");
            try writer.print("{d}", .{pitch});
        }
        try writer.writeAll("],\"chroma\":[");
        for (frame.chroma, 0..) |value, chroma_index| {
            if (chroma_index != 0) try writer.writeAll(",");
            try writer.print("{d:.5}", .{value});
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("\n  ],\n  \"score_alignment\": ");
    if (alignment) |value| {
        const exact_ratio = if (value.compared_notes == 0) 0 else @as(f32, @floatFromInt(value.exact_pitch_matches)) / @as(f32, @floatFromInt(value.compared_notes));
        const class_ratio = if (value.compared_notes == 0) 0 else @as(f32, @floatFromInt(value.pitch_class_matches)) / @as(f32, @floatFromInt(value.compared_notes));
        try writer.print("{{\"start_beat\":{d:.3},\"end_beat\":", .{value.start_beat});
        if (std.math.isFinite(value.end_beat)) try writer.print("{d:.3}", .{value.end_beat}) else try writer.writeAll("null");
        try writer.print(",\"score_instrument_notes\":{d},\"compared_notes\":{d},\"assumed_tempo_bpm\":{d:.2},\"score_duration_seconds\":{d:.3},\"active_audio_duration_seconds\":{d:.3},\"duration_delta_seconds\":{d:.3},\"exact_pitch_matches\":{d},\"pitch_class_matches\":{d},\"exact_ratio\":{d:.4},\"pitch_class_ratio\":{d:.4}}}", .{ value.score_instrument_notes, value.compared_notes, value.assumed_tempo_bpm, value.score_duration_seconds, value.active_audio_duration_seconds, value.active_audio_duration_seconds - value.score_duration_seconds, value.exact_pitch_matches, value.pitch_class_matches, exact_ratio, class_ratio });
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("\n}\n");

    const json = allocating.written();
    if (output_path) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = json });
        std.debug.print("Wrote {d} frames and {d} onsets to {s}\n", .{ analysis.frames.len, analysis.onsets.len, path });
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
    }
}

fn alignAudioScore(analysis: *const score.transcribe.Analysis, report: *const score.musicxml.ImportReport, start_beat: f32, requested_end_beat: f32) AudioAlignment {
    var result: AudioAlignment = .{ .start_beat = start_beat, .end_beat = requested_end_beat };
    if (analysis.frames.len == 0) return result;
    const tempo = if (report.tempo_count != 0) report.tempos[0].bpm else score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit);
    result.assumed_tempo_bpm = tempo;
    result.active_audio_duration_seconds = @max(0, analysis.active_end_seconds - analysis.active_start_seconds);
    const start_seconds = reportSecondsAtBeat(report, start_beat);
    if (std.math.isFinite(requested_end_beat)) {
        result.score_duration_seconds = reportSecondsAtBeat(report, requested_end_beat) - start_seconds;
    } else if (report.measure_count != 0) {
        const last = report.measures[report.measure_count - 1];
        result.score_duration_seconds = reportSecondsAtBeat(report, last.start_beat + last.duration_beats) - start_seconds;
    }
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        if (note.start_beat < start_beat or note.start_beat >= requested_end_beat) continue;
        result.score_instrument_notes += 1;
        const time = analysis.active_start_seconds + reportSecondsAtBeat(report, note.start_beat) - start_seconds;
        if (time < analysis.active_start_seconds or time > analysis.active_end_seconds) continue;
        result.compared_notes += 1;
        var nearest = &analysis.frames[0];
        var nearest_distance = @abs(nearest.time_seconds - time);
        for (analysis.frames[1..]) |*frame| {
            const distance = @abs(frame.time_seconds - time);
            if (distance < nearest_distance) {
                nearest = frame;
                nearest_distance = distance;
            }
        }
        var exact = false;
        for (nearest.pitches[0..nearest.pitch_count]) |pitch| if (pitch == note.pitch) {
            exact = true;
        };
        if (exact) result.exact_pitch_matches += 1;
        if (exact or nearest.chroma[note.pitch % 12] >= 0.075) result.pitch_class_matches += 1;
    }
    return result;
}

fn reportSecondsAtBeat(report: *const score.musicxml.ImportReport, requested_beat: f32) f32 {
    const beat = @max(0, requested_beat);
    if (beat == 0) return 0;
    const fallback_quarter = score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit);
    if (report.tempo_count == 0) return beat * 60.0 / @max(1, fallback_quarter);

    var seconds: f32 = 0;
    var cursor: f32 = 0;
    var current_bpm = @max(1, report.tempos[0].bpm);
    for (report.tempos[0..report.tempo_count]) |event| {
        const change_beat = std.math.clamp(event.start_beat, cursor, beat);
        if (change_beat > cursor) {
            seconds += (change_beat - cursor) * 60.0 / current_bpm;
            cursor = change_beat;
        }
        if (event.start_beat > beat) break;
        current_bpm = @max(1, event.bpm);
    }
    if (cursor < beat) seconds += (beat - cursor) * 60.0 / current_bpm;
    return seconds;
}

fn parsePositiveFloat(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, text);
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidNumber;
    return value;
}

fn parseNonNegativeFloat(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, text);
    if (!std.math.isFinite(value) or value < 0) return error.InvalidNumber;
    return value;
}

fn parseBeatRange(text: []const u8) !BeatRange {
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidBeatRange;
    const start = try parseNonNegativeFloat(text[0..separator]);
    const end = try parsePositiveFloat(text[separator + 1 ..]);
    if (end <= start) return error.InvalidBeatRange;
    return .{ .start = start, .end = end };
}

fn readReport(init: std.process.Init, path: []const u8) !score.musicxml.ImportReport {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_file_bytes));
    defer init.gpa.free(bytes);
    if (std.mem.endsWith(u8, path, ".mxl")) {
        const xml = try score.mxl.extract(init.gpa, bytes);
        defer init.gpa.free(xml);
        return score.musicxml.parse(xml);
    }
    return score.musicxml.parse(bytes);
}

fn readReportInto(init: std.process.Init, path: []const u8, report: *score.musicxml.ImportReport) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_file_bytes));
    defer init.gpa.free(bytes);
    if (std.mem.endsWith(u8, path, ".mxl")) {
        const xml = try score.mxl.extract(init.gpa, bytes);
        defer init.gpa.free(xml);
        return score.musicxml.parseInto(xml, report);
    }
    return score.musicxml.parseInto(bytes, report);
}

fn compareCsvEvidence(
    init: std.process.Init,
    score_path: []const u8,
    report: *const score.musicxml.ImportReport,
    csv_paths: []const []const u8,
    range: BeatRange,
    quarter_bpm: f32,
    tolerance_seconds: f32,
    anchor_path: ?[]const u8,
) !void {
    var anchors: std.ArrayList(RecordingAnchor) = .empty;
    defer anchors.deinit(init.gpa);
    if (anchor_path) |path| try readRecordingAnchors(init, path, &anchors);
    var evidence: std.ArrayList(CsvPitch) = .empty;
    defer evidence.deinit(init.gpa);
    const start_seconds = range.start * 60.0 / quarter_bpm;
    const end_seconds = range.end * 60.0 / quarter_bpm;
    for (csv_paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_file_bytes));
        defer init.gpa.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, ',');
            const event_start = std.fmt.parseFloat(f32, fields.next() orelse continue) catch continue;
            const event_end = std.fmt.parseFloat(f32, fields.next() orelse continue) catch continue;
            const pitch = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 10) catch continue;
            if (anchors.items.len == 0 and (event_end + tolerance_seconds < start_seconds or event_start - tolerance_seconds > end_seconds)) continue;
            try evidence.append(init.gpa, .{ .start_seconds = event_start, .end_seconds = event_end, .pitch = pitch });
        }
    }

    var compared: usize = 0;
    var exact_matches: usize = 0;
    var pitch_class_matches: usize = 0;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        if (note.start_beat < range.start or note.start_beat >= range.end) continue;
        compared += 1;
        const time = if (anchors.items.len == 0)
            note.start_beat * 60.0 / quarter_bpm
        else
            anchoredNoteTime(report, anchors.items, note.start_beat) orelse continue;
        var exact = false;
        var pitch_class = false;
        for (evidence.items) |event| {
            if (event.start_seconds - tolerance_seconds > time or event.end_seconds + tolerance_seconds < time) continue;
            if (event.pitch % 12 == note.pitch % 12) pitch_class = true;
            if (event.pitch == note.pitch) exact = true;
        }
        exact_matches += @intFromBool(exact);
        pitch_class_matches += @intFromBool(pitch_class);
    }
    const exact_ratio = if (compared == 0) 0 else @as(f32, @floatFromInt(exact_matches)) / @as(f32, @floatFromInt(compared));
    const pitch_class_ratio = if (compared == 0) 0 else @as(f32, @floatFromInt(pitch_class_matches)) / @as(f32, @floatFromInt(compared));
    std.debug.print(
        "{s}: CSV evidence sources={d} events={d} anchors={d} beats={d:.3}..{d:.3} seconds={d:.3}..{d:.3} tempo-quarter={d:.3} notes={d} exact={d} ({d:.4}) pitch-class={d} ({d:.4}) tolerance={d:.3}s\n",
        .{ score_path, csv_paths.len, evidence.items.len, anchors.items.len, range.start, range.end, start_seconds, end_seconds, quarter_bpm, compared, exact_matches, exact_ratio, pitch_class_matches, pitch_class_ratio, tolerance_seconds },
    );
}

fn readRecordingAnchors(init: std.process.Init, path: []const u8, output: *std.ArrayList(RecordingAnchor)) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_file_bytes));
    defer init.gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(JsonAnchorDocument, init.gpa, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try output.ensureTotalCapacity(init.gpa, parsed.value.measures.len);
    for (parsed.value.measures) |anchor| {
        const number = std.fmt.parseUnsigned(u32, anchor.measure, 10) catch continue;
        if (anchor.recording_end_seconds <= anchor.recording_start_seconds) continue;
        try output.append(init.gpa, .{ .measure_number = number, .start_seconds = anchor.recording_start_seconds, .end_seconds = anchor.recording_end_seconds });
    }
}

fn anchoredNoteTime(report: *const score.musicxml.ImportReport, anchors: []const RecordingAnchor, beat: f32) ?f32 {
    const measure_index = score.model.measureIndexAt(report.measures[0..report.measure_count], beat) orelse return null;
    const measure = report.measures[measure_index];
    const anchor = for (anchors) |candidate| {
        if (candidate.measure_number == measure.number) break candidate;
    } else return null;
    const fraction = std.math.clamp((beat - measure.start_beat) / @max(0.0001, measure.duration_beats), 0, 1);
    return anchor.start_seconds + fraction * (anchor.end_seconds - anchor.start_seconds);
}

const EvidenceEnrichResult = struct {
    notes: std.ArrayList(score.model.Note),
    added_treble: usize = 0,
    added_bass: usize = 0,
};

fn enrichFromEvidence(
    init: std.process.Init,
    target: *const score.musicxml.ImportReport,
    csv_paths: []const []const u8,
    anchor_path: []const u8,
    range: BeatRange,
    grid: f32,
    onset_tolerance: f32,
    minimum_sources: u8,
) !EvidenceEnrichResult {
    const treble_staff = findInstrumentStaff(target, false) orelse return error.TargetTrebleMissing;
    const bass_staff = findInstrumentStaff(target, true) orelse return error.TargetBassMissing;
    var anchors: std.ArrayList(RecordingAnchor) = .empty;
    defer anchors.deinit(init.gpa);
    try readRecordingAnchors(init, anchor_path, &anchors);
    var evidence: std.ArrayList(CsvPitch) = .empty;
    defer evidence.deinit(init.gpa);
    for (csv_paths, 0..) |path, source_index| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_file_bytes));
        defer init.gpa.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, ',');
            const start_seconds = std.fmt.parseFloat(f32, fields.next() orelse continue) catch continue;
            const end_seconds = std.fmt.parseFloat(f32, fields.next() orelse continue) catch continue;
            const pitch = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 10) catch continue;
            const velocity = std.fmt.parseUnsigned(u8, fields.next() orelse continue, 10) catch 64;
            if (pitch < 24 or pitch > 108) continue;
            try evidence.append(init.gpa, .{
                .start_seconds = start_seconds,
                .end_seconds = end_seconds,
                .pitch = pitch,
                .velocity = velocity,
                .source_index = @intCast(source_index),
            });
        }
    }

    var result = EvidenceEnrichResult{ .notes = .empty };
    errdefer result.notes.deinit(init.gpa);
    try result.notes.ensureTotalCapacity(init.gpa, target.note_count + @as(usize, @intFromFloat((range.end - range.start) / grid + 1)) * 2);
    try result.notes.appendSlice(init.gpa, target.notes[0..target.note_count]);

    var beat = @ceil(range.start / grid) * grid;
    while (beat < range.end - 0.0001) : (beat += grid) {
        const time = anchoredNoteTime(target, anchors.items, beat) orelse continue;
        var source_masks = [_]u8{0} ** 128;
        var velocity_sums = [_]u32{0} ** 128;
        var velocity_counts = [_]u16{0} ** 128;
        for (evidence.items) |event| {
            if (@abs(event.start_seconds - time) > onset_tolerance) continue;
            source_masks[event.pitch] |= @as(u8, 1) << @intCast(event.source_index);
            velocity_sums[event.pitch] += event.velocity;
            velocity_counts[event.pitch] += 1;
        }

        var best_bass: ?u8 = null;
        var best_treble: ?u8 = null;
        for (24..109) |pitch_index| {
            const pitch: u8 = @intCast(pitch_index);
            const sources: u8 = @intCast(@popCount(source_masks[pitch]));
            if (sources < minimum_sources or existingInstrumentPitchAt(target, pitch, beat, grid)) continue;
            const slot = if (pitch < 60) &best_bass else &best_treble;
            if (slot.* == null or evidencePitchBetter(pitch, slot.*.?, source_masks, velocity_sums)) slot.* = pitch;
        }

        const measure_index = score.model.measureIndexAt(target.measures[0..target.measure_count], beat) orelse continue;
        const measure = target.measures[measure_index];
        const duration = @min(grid, measure.start_beat + measure.duration_beats - beat);
        if (duration <= 0.0001) continue;
        if (best_bass != null and staffHasAttackAt(target, bass_staff, beat, grid)) best_bass = null;
        if (best_treble != null and staffHasAttackAt(target, treble_staff, beat, grid)) best_treble = null;
        if (best_bass) |pitch| {
            try result.notes.append(init.gpa, evidenceNote(pitch, beat, duration, bass_staff, target.key_fifths, velocity_sums[pitch], velocity_counts[pitch]));
            result.added_bass += 1;
        }
        if (best_treble) |pitch| {
            try result.notes.append(init.gpa, evidenceNote(pitch, beat, duration, treble_staff, target.key_fifths, velocity_sums[pitch], velocity_counts[pitch]));
            result.added_treble += 1;
        }
    }
    std.mem.sort(score.model.Note, result.notes.items, {}, noteLessThan);
    for (result.notes.items, 0..) |*note, index| note.stable_id = index + 1;
    return result;
}

fn staffHasAttackAt(report: *const score.musicxml.ImportReport, staff: u8, beat: f32, grid: f32) bool {
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & score.model.note_flag_vocal_guide) != 0 or note.staff != staff) continue;
        if (@abs(note.start_beat - beat) <= grid * 0.2) return true;
    }
    return false;
}

fn existingInstrumentPitchAt(report: *const score.musicxml.ImportReport, pitch: u8, beat: f32, grid: f32) bool {
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0 or note.pitch != pitch) continue;
        if (@abs(note.start_beat - beat) <= grid * 0.2) return true;
        if (note.start_beat < beat and note.start_beat + note.duration_beats > beat + 0.0001) return true;
    }
    return false;
}

fn evidencePitchBetter(candidate: u8, current: u8, masks: [128]u8, velocity_sums: [128]u32) bool {
    const candidate_sources = @popCount(masks[candidate]);
    const current_sources = @popCount(masks[current]);
    if (candidate_sources != current_sources) return candidate_sources > current_sources;
    if (velocity_sums[candidate] != velocity_sums[current]) return velocity_sums[candidate] > velocity_sums[current];
    return candidate < current;
}

fn applyPitchSpelling(note: *score.model.Note, key_fifths: i8) void {
    const pitch_class = note.pitch % 12;
    const sharp_steps = [_]u8{ 'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B' };
    const sharp_alters = [_]i8{ 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 };
    const flat_steps = [_]u8{ 'C', 'D', 'D', 'E', 'E', 'F', 'G', 'G', 'A', 'A', 'B', 'B' };
    const flat_alters = [_]i8{ 0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0 };
    const use_flats = key_fifths < 0;
    note.written_step = if (use_flats) flat_steps[pitch_class] else sharp_steps[pitch_class];
    note.written_alter = if (use_flats) flat_alters[pitch_class] else sharp_alters[pitch_class];
    note.written_octave = @intCast(note.pitch / 12 -| 1);
}

fn evidenceNote(pitch: u8, beat: f32, duration: f32, staff: u8, key_fifths: i8, velocity_sum: u32, velocity_count: u16) score.model.Note {
    const average = if (velocity_count == 0) 64 else velocity_sum / velocity_count;
    var result: score.model.Note = .{
        .stable_id = 0,
        .start_beat = beat,
        .duration_beats = duration,
        .pitch = pitch,
        .velocity = @intCast(std.math.clamp(average, 40, 112)),
        .staff = staff,
        .voice = 3,
    };
    applyPitchSpelling(&result, key_fifths);
    return result;
}

const RepeatEnrichResult = struct {
    notes: std.ArrayList(score.model.Note),
    harmonies: std.ArrayList(score.model.Harmony),
    replacement_count: usize,
    removed_treble: usize,
    added_treble: usize,
};

fn enrichExactRepeats(
    allocator: std.mem.Allocator,
    target: *const score.musicxml.ImportReport,
    fragment: *const score.musicxml.ImportReport,
    patterns: []const BeatRange,
) !RepeatEnrichResult {
    const target_treble = findInstrumentStaff(target, false) orelse return error.TargetTrebleMissing;
    const fragment_treble = findInstrumentStaff(fragment, false) orelse return error.FragmentTrebleMissing;
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);
    for (patterns) |pattern| {
        if (pattern.end > scoreEnd(fragment) + 0.0001) return error.PatternOutsideFragment;
        for (target.measures[0..target.measure_count]) |measure| {
            const candidate = BeatRange{ .start = measure.start_beat, .end = measure.start_beat + (pattern.end - pattern.start) };
            if (candidate.end > scoreEnd(target) + 0.0001 or !trebleRangesEqual(target, target_treble, pattern, candidate)) continue;
            var overlaps = false;
            for (replacements.items) |existing| {
                if (candidate.start < existing.target.end - 0.0001 and candidate.end > existing.target.start + 0.0001) {
                    overlaps = true;
                    break;
                }
            }
            if (!overlaps) try replacements.append(allocator, .{ .source = pattern, .target = candidate });
        }
    }

    var notes: std.ArrayList(score.model.Note) = .empty;
    errdefer notes.deinit(allocator);
    try notes.ensureTotalCapacity(allocator, target.note_count + fragment.note_count * replacements.items.len);
    var removed_treble: usize = 0;
    for (target.notes[0..target.note_count]) |note| {
        const replace = note.staff == target_treble and (note.flags & score.model.note_flag_vocal_guide) == 0 and beatInReplacement(note.start_beat, replacements.items);
        if (replace) {
            removed_treble += 1;
        } else {
            try notes.append(allocator, note);
        }
    }
    var added_treble: usize = 0;
    for (replacements.items) |replacement| {
        for (fragment.notes[0..fragment.note_count]) |source_note| {
            if (source_note.staff != fragment_treble or (source_note.flags & score.model.note_flag_vocal_guide) != 0) continue;
            if (source_note.start_beat < replacement.source.start or source_note.start_beat >= replacement.source.end) continue;
            var note = source_note;
            note.start_beat = replacement.target.start + (source_note.start_beat - replacement.source.start);
            note.duration_beats = @min(note.duration_beats, replacement.target.end - note.start_beat);
            note.staff = target_treble;
            note.selected = 0;
            try notes.append(allocator, note);
            added_treble += 1;
        }
    }
    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    for (notes.items, 0..) |*note, index| note.stable_id = index + 1;

    var harmonies: std.ArrayList(score.model.Harmony) = .empty;
    errdefer harmonies.deinit(allocator);
    try harmonies.ensureTotalCapacity(allocator, target.harmony_count + fragment.harmony_count * replacements.items.len);
    for (target.harmonies[0..target.harmony_count]) |harmony| {
        if (!beatInReplacement(harmony.start_beat, replacements.items)) try harmonies.append(allocator, harmony);
    }
    for (replacements.items) |replacement| {
        for (fragment.harmonies[0..fragment.harmony_count]) |source_harmony| {
            if (source_harmony.start_beat < replacement.source.start or source_harmony.start_beat >= replacement.source.end) continue;
            var harmony = source_harmony;
            harmony.start_beat = replacement.target.start + (source_harmony.start_beat - replacement.source.start);
            try harmonies.append(allocator, harmony);
        }
    }
    std.mem.sort(score.model.Harmony, harmonies.items, {}, harmonyLessThan);
    return .{ .notes = notes, .harmonies = harmonies, .replacement_count = replacements.items.len, .removed_treble = removed_treble, .added_treble = added_treble };
}

fn beatInReplacement(beat: f32, replacements: []const Replacement) bool {
    for (replacements) |replacement| if (beat >= replacement.target.start and beat < replacement.target.end) return true;
    return false;
}

fn printExactTrebleRepeats(score_path: []const u8, report: *const score.musicxml.ImportReport, pattern: BeatRange) void {
    const treble = findInstrumentStaff(report, false) orelse {
        std.debug.print("{s}: no instrumental treble staff\n", .{score_path});
        return;
    };
    var matches: usize = 0;
    std.debug.print("{s}: exact treble repeats of beats {d:.3}..{d:.3}:", .{ score_path, pattern.start, pattern.end });
    for (report.measures[0..report.measure_count]) |measure| {
        const candidate = BeatRange{ .start = measure.start_beat, .end = measure.start_beat + (pattern.end - pattern.start) };
        if (candidate.end > scoreEnd(report) + 0.0001) continue;
        if (!trebleRangesEqual(report, treble, pattern, candidate)) continue;
        std.debug.print(" measure={d}@{d:.3}", .{ measure.number, measure.start_beat });
        matches += 1;
    }
    std.debug.print(" matches={d}\n", .{matches});
}

fn trebleRangesEqual(report: *const score.musicxml.ImportReport, staff: u8, left: BeatRange, right: BeatRange) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        const left_note = nextPitchedInRange(report, staff, left, &left_index);
        const right_note = nextPitchedInRange(report, staff, right, &right_index);
        if (left_note == null or right_note == null) return left_note == null and right_note == null;
        const a = left_note.?;
        const b = right_note.?;
        if (@abs((a.start_beat - left.start) - (b.start_beat - right.start)) > 0.001) return false;
        if (@abs(a.duration_beats - b.duration_beats) > 0.001 or a.pitch != b.pitch) return false;
    }
}

fn nextPitchedInRange(report: *const score.musicxml.ImportReport, staff: u8, range: BeatRange, cursor: *usize) ?score.model.Note {
    while (cursor.* < report.note_count) : (cursor.* += 1) {
        const note = report.notes[cursor.*];
        if (note.start_beat >= range.end) return null;
        if (note.start_beat < range.start or note.staff != staff or (note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        cursor.* += 1;
        return note;
    }
    return null;
}

const EnrichResult = struct {
    notes: std.ArrayList(score.model.Note),
    harmonies: std.ArrayList(score.model.Harmony),
    summary: EnrichSummary,
};

fn enrichOpening(
    allocator: std.mem.Allocator,
    target: *const score.musicxml.ImportReport,
    fragment: *const score.musicxml.ImportReport,
    options: EnrichOptions,
) !EnrichResult {
    const target_treble = findInstrumentStaff(target, false) orelse return error.TargetTrebleMissing;
    const target_bass = findInstrumentStaff(target, true) orelse return error.TargetBassMissing;
    const fragment_treble = findInstrumentStaff(fragment, false) orelse return error.FragmentTrebleMissing;
    const fragment_bass = findInstrumentStaff(fragment, true);
    const fragment_bass_range = if (fragment_bass) |staff| staffActiveRange(fragment, staff, options.end_beat) else null;

    var notes: std.ArrayList(score.model.Note) = .empty;
    errdefer notes.deinit(allocator);
    try notes.ensureTotalCapacity(allocator, target.note_count + fragment.note_count);
    var summary: EnrichSummary = .{ .target_treble_staff = target_treble, .target_bass_staff = target_bass };

    for (target.notes[0..target.note_count]) |note| {
        const instrumental = (note.flags & score.model.note_flag_vocal_guide) == 0;
        if (instrumental and note.staff == target_treble and note.start_beat < options.end_beat) {
            summary.removed_treble += 1;
            continue;
        }
        if (instrumental and note.staff == target_bass and shouldReplaceBass(note, fragment_bass_range, options)) {
            summary.removed_bass += 1;
            continue;
        }
        try notes.append(allocator, note);
    }

    for (fragment.notes[0..fragment.note_count]) |source_note| {
        if ((source_note.flags & score.model.note_flag_vocal_guide) != 0 or source_note.start_beat >= options.end_beat) continue;
        var note = source_note;
        note.duration_beats = @min(note.duration_beats, options.end_beat - note.start_beat);
        note.selected = 0;
        if (note.staff == fragment_treble) {
            note.staff = target_treble;
            summary.added_treble += 1;
        } else if (fragment_bass != null and note.staff == fragment_bass.?) {
            if (options.bass_mode == .preserve) continue;
            note.staff = target_bass;
            summary.added_bass += 1;
        } else {
            continue;
        }
        try notes.append(allocator, note);
    }

    std.mem.sort(score.model.Note, notes.items, {}, noteLessThan);
    for (notes.items, 0..) |*note, index| note.stable_id = index + 1;

    var harmonies: std.ArrayList(score.model.Harmony) = .empty;
    errdefer harmonies.deinit(allocator);
    try harmonies.ensureTotalCapacity(allocator, target.harmony_count + fragment.harmony_count);
    for (target.harmonies[0..target.harmony_count]) |harmony| {
        if (harmony.start_beat >= options.end_beat) try harmonies.append(allocator, harmony);
    }
    for (fragment.harmonies[0..fragment.harmony_count]) |harmony| {
        if (harmony.start_beat < options.end_beat) try harmonies.append(allocator, harmony);
    }
    std.mem.sort(score.model.Harmony, harmonies.items, {}, harmonyLessThan);

    summary.output_notes = notes.items.len;
    return .{ .notes = notes, .harmonies = harmonies, .summary = summary };
}

fn shouldReplaceBass(note: score.model.Note, range: ?BeatRange, options: EnrichOptions) bool {
    if (options.bass_mode != .replace_where_fragment_has_notes) return false;
    const active = range orelse return false;
    return note.start_beat >= active.start and note.start_beat < @min(active.end, options.end_beat);
}

fn staffActiveRange(report: *const score.musicxml.ImportReport, staff: u8, end_beat: f32) ?BeatRange {
    var start: f32 = end_beat;
    var end: f32 = 0;
    var found = false;
    for (report.notes[0..report.note_count]) |note| {
        if (note.staff != staff or note.start_beat >= end_beat or (note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        start = @min(start, note.start_beat);
        end = @max(end, note.start_beat + note.duration_beats);
        found = true;
    }
    return if (found) .{ .start = start, .end = end } else null;
}

fn findInstrumentStaff(report: *const score.musicxml.ImportReport, bass: bool) ?u8 {
    var counts = [_]usize{0} ** 256;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        if (((note.staff & 1) == 1) != bass) continue;
        counts[note.staff] += 1;
    }
    var result: ?u8 = null;
    var best: usize = 0;
    for (counts, 0..) |count, index| {
        if (count > best) {
            best = count;
            result = @intCast(index);
        }
    }
    return result;
}

fn writeMxl(
    init: std.process.Init,
    output_path: []const u8,
    target: *const score.musicxml.ImportReport,
    notes: []const score.model.Note,
    lyrics: []const score.model.Lyric,
    harmonies: []const score.model.Harmony,
    pedals: []const score.model.PedalEvent,
    measures: []const score.model.Measure,
    quarter_bpm_override: ?f32,
    tempo_plan: ?TempoPlan,
) !void {
    var meta: score.model.DocumentMeta = .{};
    meta.setTitle(target.titleSlice());
    meta.setCreator(target.creatorSlice());
    meta.beats_per_measure = target.beats_per_measure;
    meta.beat_unit = target.beat_unit;
    meta.key_fifths = target.key_fifths;
    meta.tempo_beat_unit = if (tempo_plan) |plan| plan.pulse_unit else if (quarter_bpm_override != null) 4 else target.tempo_beat_unit;

    const original_quarter = if (target.tempo_count != 0) target.tempos[0].bpm else score.model.quarterTempoFromPulse(target.tempo_bpm, target.tempo_beat_unit);
    const output_quarter = if (tempo_plan) |plan| plan.first_quarter_bpm else quarter_bpm_override orelse original_quarter;
    var transport: score.model.Transport = .{ .tempo_bpm = if (tempo_plan) |plan| plan.pulse_bpm else score.model.pulseTempoFromQuarter(output_quarter, meta.tempo_beat_unit) };
    var playback: score.model.PlaybackBounds = .{
        .end_beat = slicesEnd(notes, measures),
        .tempo_base_bpm = output_quarter,
        .tempo_count = if (tempo_plan != null) 2 else @intCast(@max(@as(usize, 1), target.tempo_count)),
        .tempo_beat_unit = meta.tempo_beat_unit,
    };
    if (tempo_plan) |plan| {
        playback.tempos[0] = .{ .start_beat = 0, .bpm = plan.first_quarter_bpm };
        playback.tempos[1] = .{ .start_beat = plan.resume_beat, .bpm = plan.resume_quarter_bpm };
    } else if (target.tempo_count == 0) {
        playback.tempos[0] = .{ .start_beat = 0, .bpm = output_quarter };
    } else {
        const scale = output_quarter / @max(1, original_quarter);
        for (target.tempos[0..target.tempo_count], 0..) |tempo, index| playback.tempos[index] = .{ .start_beat = tempo.start_beat, .bpm = tempo.bpm * scale };
    }
    transport.loop_end = @min(8, playback.end_beat);

    const xml = try init.gpa.alloc(u8, max_xml_bytes);
    defer init.gpa.free(xml);
    const xml_len = try score.musicxml_export.write(
        xml,
        &meta,
        &transport,
        notes,
        lyrics,
        harmonies,
        pedals,
        measures,
        &playback,
    );
    const package = try init.gpa.alloc(u8, xml_len + 4096);
    defer init.gpa.free(package);
    const package_len = try score.mxl_export.write(package, xml[0..xml_len]);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = package[0..package_len] });
}

fn slicesEnd(notes: []const score.model.Note, measures: []const score.model.Measure) f32 {
    var result: f32 = 4;
    if (measures.len != 0) {
        const last = measures[measures.len - 1];
        result = @max(result, last.start_beat + last.duration_beats);
    }
    for (notes) |note| result = @max(result, note.start_beat + note.duration_beats);
    return result;
}

fn scoreEnd(report: *const score.musicxml.ImportReport) f32 {
    if (report.measure_count != 0) {
        const last = report.measures[report.measure_count - 1];
        return last.start_beat + last.duration_beats;
    }
    var result: f32 = 4;
    for (report.notes[0..report.note_count]) |note| result = @max(result, note.start_beat + note.duration_beats);
    return result;
}

fn measureStartByNumber(report: *const score.musicxml.ImportReport, number: u32) ?f32 {
    for (report.measures[0..report.measure_count]) |measure| {
        if (measure.number == number) return measure.start_beat;
    }
    return null;
}

fn printReport(path: []const u8, report: *const score.musicxml.ImportReport) void {
    var pitched: usize = 0;
    var vocal: usize = 0;
    var rests: usize = 0;
    var staff_counts = [_]usize{0} ** 256;
    var voice_seen = [_][256]bool{[_]bool{false} ** 256} ** 256;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & score.model.note_flag_rest) != 0) rests += 1 else pitched += 1;
        if ((note.flags & score.model.note_flag_vocal_guide) != 0) vocal += 1;
        staff_counts[note.staff] += 1;
        voice_seen[note.staff][note.voice] = true;
    }
    std.debug.print(
        "{s}: title=\"{s}\" creator=\"{s}\" measures={d} events={d} pitched={d} rests={d} vocal={d} harmonies={d} pedals={d} tempo={d:.3} pulse-unit={d} quarter={d:.3} end={d:.3}\n",
        .{ path, report.titleSlice(), report.creatorSlice(), report.measure_count, report.note_count, pitched, rests, vocal, report.harmony_count, report.pedal_count, report.tempo_bpm, report.tempo_beat_unit, score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit), scoreEnd(report) },
    );
    for (staff_counts, 0..) |count, staff| {
        if (count == 0) continue;
        var voices: usize = 0;
        for (voice_seen[staff]) |seen| voices += @intFromBool(seen);
        std.debug.print("  staff {d}: events={d} voices={d}\n", .{ staff, count, voices });
    }
}

fn playabilitySummary(report: *const score.musicxml.ImportReport) PlayabilitySummary {
    var result: PlayabilitySummary = .{};
    var last_onset = [_]f32{0} ** 2;
    var have_last_onset = [_]bool{false} ** 2;

    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0 or note.staff > 1) continue;
        result.instrumental_notes += 1;
        if (note.pitch < 21 or note.pitch > 108) result.outside_piano_range += 1;
        if (note.duration_beats <= 0 or !std.math.isFinite(note.duration_beats)) result.invalid_durations += 1;
        result.min_pitch[note.staff] = @min(result.min_pitch[note.staff], note.pitch);
        result.max_pitch[note.staff] = @max(result.max_pitch[note.staff], note.pitch);
        if (score.model.dynamic(note.flags) != 0) result.dynamic_notes += 1;
        if ((note.flags & (score.model.note_flag_staccato | score.model.note_flag_accent | score.model.note_flag_tenuto | score.model.note_flag_marcato | score.model.note_flag_fermata | score.model.note_flag_slur_start | score.model.note_flag_slur_stop)) != 0) result.articulated_notes += 1;
        if (note.fingering != 0) result.fingered_notes += 1;
    }

    var index: usize = 0;
    while (index < report.note_count) {
        const onset = report.notes[index].start_beat;
        var end = index + 1;
        while (end < report.note_count and @abs(report.notes[end].start_beat - onset) < 0.0001) : (end += 1) {}

        for (0..2) |staff| {
            var pitches = [_]bool{false} ** 128;
            var unique: u8 = 0;
            var low: u8 = 127;
            var high: u8 = 0;
            for (report.notes[index..end]) |note| {
                if (note.staff != staff or (note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
                if (!pitches[note.pitch]) {
                    pitches[note.pitch] = true;
                    unique += 1;
                    low = @min(low, note.pitch);
                    high = @max(high, note.pitch);
                }
            }
            if (unique == 0) continue;
            result.onset_groups += 1;
            result.max_simultaneous = @max(result.max_simultaneous, unique);
            const span = high - low;
            result.max_span = @max(result.max_span, span);
            if (span > 12) {
                result.wide_spans += 1;
                if (result.span_issue_count < result.span_issues.len) {
                    const measure = if (score.model.measureIndexAt(report.measures[0..report.measure_count], onset)) |measure_index| report.measures[measure_index].number else 0;
                    result.span_issues[result.span_issue_count] = .{ .beat = onset, .measure = measure, .staff = @intCast(staff), .low = low, .high = high };
                    result.span_issue_count += 1;
                }
            }
            if (span > 16) result.extreme_spans += 1;
            if (unique > 5) result.dense_chords += 1;
            if (have_last_onset[staff]) result.fastest_gap_beats = @min(result.fastest_gap_beats, onset - last_onset[staff]);
            last_onset[staff] = onset;
            have_last_onset[staff] = true;
        }
        index = end;
    }
    return result;
}

fn printPlayability(path: []const u8, report: *const score.musicxml.ImportReport) void {
    const result = playabilitySummary(report);
    const quarter_bpm = score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit);
    const fastest_ms = if (std.math.isFinite(result.fastest_gap_beats)) result.fastest_gap_beats * 60_000.0 / quarter_bpm else 0;
    const technical_pass = result.outside_piano_range == 0 and result.invalid_durations == 0 and result.wide_spans == 0 and result.dense_chords == 0;
    std.debug.print(
        "{s}: technical_playability={s} publication_readiness=REVIEW_REQUIRED instrumental_notes={d} onset_groups={d} qpm={d:.2}\n",
        .{ path, if (technical_pass) "PASS" else "REVIEW", result.instrumental_notes, result.onset_groups, quarter_bpm },
    );
    std.debug.print(
        "  ranges: treble={d}..{d} bass={d}..{d}; max_one-hand_span={d} semitones; max_simultaneous={d}; fastest_onset_gap={d:.2} beats/{d:.1} ms\n",
        .{ result.min_pitch[0], result.max_pitch[0], result.min_pitch[1], result.max_pitch[1], result.max_span, result.max_simultaneous, result.fastest_gap_beats, fastest_ms },
    );
    std.debug.print(
        "  review flags: spans>octave={d} spans>major10th={d} chords>5={d} outside_88_keys={d} invalid_duration={d}\n",
        .{ result.wide_spans, result.extreme_spans, result.dense_chords, result.outside_piano_range, result.invalid_durations },
    );
    std.debug.print(
        "  authored interpretation: dynamic_notes={d}/{d} articulated_notes={d}/{d} fingered_notes={d}/{d} pedal_events={d}\n",
        .{ result.dynamic_notes, result.instrumental_notes, result.articulated_notes, result.instrumental_notes, result.fingered_notes, result.instrumental_notes, report.pedal_count },
    );
    for (result.span_issues[0..result.span_issue_count]) |issue| {
        std.debug.print("  span review: measure={d} beat={d:.3} hand={s} pitches={d}..{d} span={d}\n", .{ issue.measure, issue.beat, if (issue.staff == 0) "right" else "left", issue.low, issue.high, issue.high - issue.low });
    }
    if (!technical_pass) std.debug.print("  Technical REVIEW means redistribution or notation repair is required before pianist sign-off.\n", .{});
    if (report.pedal_count == 0 or result.dynamic_notes == 0) std.debug.print("  Publication remains REVIEW_REQUIRED: recording-faithful dynamics/pedal directions are incomplete.\n", .{});
}

fn revoiceNotes(notes: []score.model.Note, beats: []const f32, pitch: u8, from_staff: u8, to_staff: u8) usize {
    var changed: usize = 0;
    for (notes) |*note| {
        if (note.pitch != pitch or note.staff != from_staff or (note.flags & (score.model.note_flag_vocal_guide | score.model.note_flag_rest)) != 0) continue;
        for (beats) |beat| {
            if (@abs(note.start_beat - beat) > 0.0001) continue;
            note.staff = to_staff;
            changed += 1;
            break;
        }
    }
    return changed;
}

fn noteLessThan(_: void, left: score.model.Note, right: score.model.Note) bool {
    if (left.start_beat != right.start_beat) return left.start_beat < right.start_beat;
    if (left.staff != right.staff) return left.staff < right.staff;
    if (left.voice != right.voice) return left.voice < right.voice;
    return left.pitch < right.pitch;
}

fn harmonyLessThan(_: void, left: score.model.Harmony, right: score.model.Harmony) bool {
    return left.start_beat < right.start_beat;
}

test "opening enrichment replaces treble while preserving vocal and bass" {
    var target: score.musicxml.ImportReport = .{};
    target.note_count = 3;
    target.notes[0] = .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 72, .velocity = 80, .staff = 0, .voice = 0, .flags = score.model.note_flag_vocal_guide };
    target.notes[1] = .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 65, .velocity = 80, .staff = 8, .voice = 0 };
    target.notes[2] = .{ .stable_id = 3, .start_beat = 0, .duration_beats = 1, .pitch = 41, .velocity = 80, .staff = 9, .voice = 0 };
    var fragment: score.musicxml.ImportReport = .{};
    fragment.note_count = 2;
    fragment.notes[0] = .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 68, .velocity = 80, .staff = 0, .voice = 0 };
    fragment.notes[1] = .{ .stable_id = 2, .start_beat = 0.5, .duration_beats = 0.5, .pitch = 73, .velocity = 80, .staff = 0, .voice = 1 };
    var result = try enrichOpening(std.testing.allocator, &target, &fragment, .{ .end_beat = 4 });
    defer result.notes.deinit(std.testing.allocator);
    defer result.harmonies.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), result.notes.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.summary.removed_treble);
    try std.testing.expectEqual(@as(usize, 2), result.summary.added_treble);
    try std.testing.expectEqual(@as(usize, 0), result.summary.removed_bass);
}

test "evidence notes use the score key's enharmonic spelling" {
    const flat = evidenceNote(66, 0, 0.5, 1, -5, 90, 1);
    try std.testing.expectEqual(@as(u8, 'G'), flat.written_step);
    try std.testing.expectEqual(@as(i8, -1), flat.written_alter);
    try std.testing.expectEqual(@as(i8, 4), flat.written_octave);

    const sharp = evidenceNote(66, 0, 0.5, 1, 2, 90, 1);
    try std.testing.expectEqual(@as(u8, 'F'), sharp.written_step);
    try std.testing.expectEqual(@as(i8, 1), sharp.written_alter);
    try std.testing.expectEqual(@as(i8, 4), sharp.written_octave);
}

test "optional pitch lists preserve intentionally empty accompaniment bars" {
    var pitches: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try parseOptionalPitchList("-", &pitches));
    try std.testing.expectEqual(@as(usize, 2), try parseOptionalPitchList("37,49", &pitches));
    try std.testing.expectEqual(@as(u8, 37), pitches[0]);
    try std.testing.expectEqual(@as(u8, 49), pitches[1]);
}

test "playability audit distinguishes wide and extreme one-hand spans" {
    var report: score.musicxml.ImportReport = .{};
    report.note_count = 5;
    report.notes[0] = .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 48, .velocity = 80, .staff = 0, .voice = 0 };
    report.notes[1] = .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 61, .velocity = 80, .staff = 0, .voice = 0 };
    report.notes[2] = .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 40, .velocity = 80, .staff = 1, .voice = 0 };
    report.notes[3] = .{ .stable_id = 4, .start_beat = 1, .duration_beats = 1, .pitch = 57, .velocity = 80, .staff = 1, .voice = 0 };
    report.notes[4] = .{ .stable_id = 5, .start_beat = 2, .duration_beats = 1, .pitch = 64, .velocity = 80, .staff = 0, .voice = 0, .flags = score.model.note_flag_vocal_guide };
    const result = playabilitySummary(&report);
    try std.testing.expectEqual(@as(usize, 4), result.instrumental_notes);
    try std.testing.expectEqual(@as(usize, 2), result.onset_groups);
    try std.testing.expectEqual(@as(usize, 2), result.wide_spans);
    try std.testing.expectEqual(@as(usize, 1), result.extreme_spans);
    try std.testing.expectEqual(@as(u8, 17), result.max_span);
    try std.testing.expectEqual(@as(usize, 2), result.span_issue_count);
}

test "revoice moves only exact instrumental onset matches" {
    var notes = [_]score.model.Note{
        .{ .stable_id = 1, .start_beat = 8, .duration_beats = 0.5, .pitch = 58, .velocity = 80, .staff = 1, .voice = 1 },
        .{ .stable_id = 2, .start_beat = 10, .duration_beats = 0.5, .pitch = 58, .velocity = 80, .staff = 1, .voice = 1 },
        .{ .stable_id = 3, .start_beat = 10, .duration_beats = 0.5, .pitch = 58, .velocity = 80, .staff = 1, .voice = 1, .flags = score.model.note_flag_rest },
    };
    const changed = revoiceNotes(&notes, &.{ 8, 10 }, 58, 1, 0);
    try std.testing.expectEqual(@as(usize, 2), changed);
    try std.testing.expectEqual(@as(u8, 0), notes[0].staff);
    try std.testing.expectEqual(@as(u8, 0), notes[1].staff);
    try std.testing.expectEqual(@as(u8, 1), notes[2].staff);
}

test "score timing integrates authored quarter tempo changes independently from displayed pulse" {
    var report: score.musicxml.ImportReport = .{ .tempo_bpm = 147, .tempo_beat_unit = 8 };
    report.tempos[0] = .{ .start_beat = 0, .bpm = 73.5 };
    report.tempos[1] = .{ .start_beat = 42, .bpm = 147 };
    report.tempo_count = 2;
    try std.testing.expectApproxEqAbs(@as(f32, 34.2857), reportSecondsAtBeat(&report, 42), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 35.9184), reportSecondsAtBeat(&report, 46), 0.001);
}
