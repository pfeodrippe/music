const std = @import("std");
const score = @import("score");

const Alignment = struct {
    expected_notes: usize = 0,
    exact_pitch_matches: usize = 0,
    pitch_class_matches: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const audio_path = args.next() orelse {
        std.debug.print("usage: score-audio-analyze INPUT.wav [--score SCORE.musicxml|SCORE.mxl] [--output REPORT.json]\n", .{});
        return error.MissingAudioPath;
    };
    var score_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--score")) {
            score_path = args.next() orelse return error.MissingScorePath;
        } else if (std.mem.eql(u8, argument, "--output")) {
            output_path = args.next() orelse return error.MissingOutputPath;
        } else {
            return error.UnknownArgument;
        }
    }

    const audio_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, audio_path, init.gpa, .limited(2 * 1024 * 1024 * 1024));
    defer init.gpa.free(audio_bytes);
    var decoded = try score.wav.decode(init.gpa, audio_bytes);
    defer decoded.deinit();
    var analysis = try score.transcribe.analyze(init.gpa, decoded.samples, decoded.sample_rate);
    defer analysis.deinit();

    var alignment: ?Alignment = null;
    if (score_path) |path| {
        const score_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(256 * 1024 * 1024));
        defer init.gpa.free(score_bytes);
        if (std.mem.endsWith(u8, path, ".mxl")) {
            const xml = try score.mxl.extract(init.gpa, score_bytes);
            defer init.gpa.free(xml);
            const report = try score.musicxml.parse(xml);
            alignment = alignScore(&analysis, &report);
        } else {
            const report = try score.musicxml.parse(score_bytes);
            alignment = alignScore(&analysis, &report);
        }
    }

    var allocating: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating.deinit();
    const writer = &allocating.writer;
    try writer.writeAll("{\n  \"schema\": 1,\n  \"analysis_kind\": \"polyphonic-evidence-not-authoritative-transcription\",");
    try writer.print("\n  \"sample_rate\": {d},\n  \"duration_seconds\": {d:.4},\n  \"estimated_tempo_bpm\": {d:.2},\n  \"tempo_confidence\": {d:.4},", .{ decoded.sample_rate, analysis.duration_seconds, analysis.estimated_tempo_bpm, analysis.tempo_confidence });
    try writer.writeAll("\n  \"onsets_seconds\": [");
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
        const exact_ratio = if (value.expected_notes == 0) 0 else @as(f32, @floatFromInt(value.exact_pitch_matches)) / @as(f32, @floatFromInt(value.expected_notes));
        const class_ratio = if (value.expected_notes == 0) 0 else @as(f32, @floatFromInt(value.pitch_class_matches)) / @as(f32, @floatFromInt(value.expected_notes));
        try writer.print("{{\"expected_instrument_notes\":{d},\"exact_pitch_matches\":{d},\"pitch_class_matches\":{d},\"exact_ratio\":{d:.4},\"pitch_class_ratio\":{d:.4}}}", .{ value.expected_notes, value.exact_pitch_matches, value.pitch_class_matches, exact_ratio, class_ratio });
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

fn alignScore(analysis: *const score.transcribe.Analysis, report: *const score.musicxml.ImportReport) Alignment {
    var result: Alignment = .{};
    if (analysis.frames.len == 0) return result;
    const tempo = if (report.tempo_bpm > 1) report.tempo_bpm else analysis.estimated_tempo_bpm;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & score.model.note_flag_vocal_guide) != 0) continue;
        result.expected_notes += 1;
        const time = note.start_beat * 60.0 / tempo;
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
