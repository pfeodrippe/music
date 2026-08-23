const std = @import("std");
const score = @import("score");
const sampler_api = @import("sfizz_sampler");
const Sampler = sampler_api.Sampler;
const PianoDetailProfile = sampler_api.PianoDetailProfile;

const sample_rate: u32 = 48_000;
const channels: usize = 2;
const block_frames: usize = 256;
const output_seconds: usize = 42;
const proof_seconds: usize = 12;
const max_score_file_bytes: usize = 256 * 1024 * 1024;

const ScoreEventKind = enum(u8) {
    control_change,
    note_off,
    note_on,
};

const ScoreEvent = struct {
    frame: usize,
    kind: ScoreEventKind,
    pitch_or_controller: u8,
    value: u8,
};

const Harness = struct {
    sampler: *Sampler,
    output: []f32,
    frame_cursor: usize = 0,

    fn render(self: *Harness, frame_count: usize) ![]f32 {
        if (self.frame_cursor + frame_count > self.output.len / channels) return error.VerificationBufferTooSmall;
        const start = self.frame_cursor * channels;
        var remaining = frame_count;
        while (remaining != 0) {
            const count = @min(remaining, block_frames);
            const offset = self.frame_cursor * channels;
            self.sampler.renderInterleaved(self.output[offset .. offset + count * channels], count, channels, sample_rate);
            self.frame_cursor += count;
            remaining -= count;
        }
        return self.output[start .. self.frame_cursor * channels];
    }

    fn seconds(self: *Harness, value: f32) ![]f32 {
        return self.render(@intFromFloat(value * sample_rate));
    }

    fn reset(self: *Harness) !void {
        self.sampler.allNotesOff();
        _ = try self.seconds(0.12);
    }

    fn append(self: *Harness, samples: []const f32) !void {
        if (samples.len % channels != 0 or self.frame_cursor + samples.len / channels > self.output.len / channels) return error.VerificationBufferTooSmall;
        const start = self.frame_cursor * channels;
        @memcpy(self.output[start .. start + samples.len], samples);
        self.frame_cursor += samples.len / channels;
    }

    fn rendered(self: *const Harness) []const f32 {
        return self.output[0 .. self.frame_cursor * channels];
    }
};

const Gate = struct {
    passed: bool = true,
    failures: [16][]const u8 = undefined,
    failure_count: usize = 0,

    fn require(self: *Gate, condition: bool, message: []const u8) void {
        if (condition) return;
        self.passed = false;
        if (self.failure_count < self.failures.len) {
            self.failures[self.failure_count] = message;
            self.failure_count += 1;
        }
    }
};

const ReplayComparison = struct {
    bit_exact: bool,
    max_abs_error: f32,
    normalized_rms_error: f32,
    correlation: f32,
};

fn compareReplay(left: []const f32, right: []const f32) ReplayComparison {
    var max_abs_error: f32 = 0;
    var error_energy: f64 = 0;
    var left_energy: f64 = 0;
    var right_energy: f64 = 0;
    var cross_energy: f64 = 0;
    for (left, right) |a, b| {
        const difference = a - b;
        max_abs_error = @max(max_abs_error, @abs(difference));
        error_energy += @as(f64, difference) * difference;
        left_energy += @as(f64, a) * a;
        right_energy += @as(f64, b) * b;
        cross_energy += @as(f64, a) * b;
    }
    const reference_energy = @max(left_energy, right_energy);
    return .{
        .bit_exact = std.mem.eql(f32, left, right),
        .max_abs_error = max_abs_error,
        .normalized_rms_error = if (reference_energy == 0) 0 else @floatCast(@sqrt(error_energy / reference_energy)),
        .correlation = if (left_energy == 0 or right_energy == 0) 0 else @floatCast(cross_energy / @sqrt(left_energy * right_energy)),
    };
}

fn writeJsonFloat(writer: *std.Io.Writer, value: f32) !void {
    if (std.math.isFinite(value)) {
        try writer.print("{d:.3}", .{value});
    } else {
        try writer.writeAll("null");
    }
}

fn pedalReleaseProbe(harness: *Harness, value: u8) !score.audio_quality.Stats {
    try harness.reset();
    harness.sampler.controlChange(0, 20, 0);
    harness.sampler.controlChange(0, 21, 0);
    harness.sampler.controlChange(0, 22, 0);
    harness.sampler.controlChange(0, 23, 0);
    harness.sampler.noteOn(0, 60, 96);
    _ = try harness.seconds(0.3);
    harness.sampler.controlChange(0, 64, value);
    harness.sampler.noteOff(0, 60);
    const release = try harness.seconds(2.2);
    const tail_samples = @as(usize, sample_rate) * channels / 2;
    return score.audio_quality.analyze(release[release.len - tail_samples ..]);
}

fn renderDeterministicAttack(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.controlChange(0, 20, 0);
    sampler.controlChange(0, 21, 0);
    sampler.controlChange(0, 22, 0);
    sampler.controlChange(0, 23, 0);
    sampler.noteOn(3, 64, 82);
    var frame_cursor: usize = 0;
    while (frame_cursor < output.len / channels) {
        const count = @min(block_frames, output.len / channels - frame_cursor);
        const start = frame_cursor * channels;
        sampler.renderInterleaved(output[start .. start + count * channels], count, channels, sample_rate);
        frame_cursor += count;
    }
}

fn renderFrames(sampler: *Sampler, output: []f32) void {
    std.debug.assert(output.len % channels == 0);
    var frame_cursor: usize = 0;
    while (frame_cursor < output.len / channels) {
        const count = @min(block_frames, output.len / channels - frame_cursor);
        const start = frame_cursor * channels;
        sampler.renderInterleaved(output[start .. start + count * channels], count, channels, sample_rate);
        frame_cursor += count;
    }
}

fn discardFrames(sampler: *Sampler, frame_count: usize) void {
    var scratch: [block_frames * channels]f32 = undefined;
    var remaining = frame_count;
    while (remaining != 0) {
        const count = @min(block_frames, remaining);
        sampler.renderInterleaved(scratch[0 .. count * channels], count, channels, sample_rate);
        remaining -= count;
    }
}

fn renderDetailProbe(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    controller: u8,
    enabled: bool,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.controlChange(0, 64, 0);
    sampler.applyPianoDetailProfile(.dry);
    if (enabled) sampler.controlChange(0, controller, 64);
    @memset(output, 0);
    // Commit the CC profile in its own audio block before scheduling the
    // probe note. sfizz resolves trigger=release region eligibility from the
    // established controller state; co-scheduling the CC and note at delay 0
    // can leave CC20's sampled-release master on its previous value.
    discardFrames(sampler, block_frames);
    if (controller == 20 or controller == 21) {
        // Release and hammer layers are streamed release-triggered regions.
        // Prime the exact region once so this offline gate measures its PCM
        // rather than storage-thread startup latency.
        sampler.controlChange(0, controller, 64);
        discardFrames(sampler, block_frames);
        sampler.noteOn(0, 60, 92);
        discardFrames(sampler, @intFromFloat(0.12 * @as(f32, @floatFromInt(sample_rate))));
        sampler.noteOff(0, 60);
        discardFrames(sampler, @intFromFloat(1.0 * @as(f32, @floatFromInt(sample_rate))));
        sampler.allNotesOff();
        discardFrames(sampler, block_frames);
        sampler.controlChange(0, controller, if (enabled) 64 else 0);
        discardFrames(sampler, block_frames);
    }

    switch (controller) {
        20, 21 => {
            sampler.noteOn(0, 60, 92);
            discardFrames(sampler, @intFromFloat(0.35 * @as(f32, @floatFromInt(sample_rate))));
            sampler.noteOff(0, 60);
            renderFrames(sampler, output);
        },
        22 => {
            // Consume the profile before the pedal edges so this buffer
            // contains only the down/up mechanism, not a piano note.
            discardFrames(sampler, block_frames);
            const half = output.len / 2;
            sampler.controlChange(0, 64, 127);
            renderFrames(sampler, output[0..half]);
            sampler.controlChange(0, 64, 0);
            renderFrames(sampler, output[half..]);
        },
        23 => {
            sampler.controlChange(0, 64, 127);
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOn(0, pitch, 76);
            discardFrames(sampler, @intFromFloat(0.35 * @as(f32, @floatFromInt(sample_rate))));
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOff(0, pitch);
            renderFrames(sampler, output);
        },
        else => return error.UnsupportedDetailController,
    }
}

fn renderRepedalProbe(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    repedal: bool,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.applyPianoDetailProfile(.dry);
    sampler.controlChange(0, 64, 0);
    discardFrames(sampler, block_frames);
    // Prime the streamed note tail and sfizz's repedal state machine once in
    // both comparison instances. This removes first-use disk timing from the
    // measured dry/caught decision.
    sampler.noteOn(0, 60, 92);
    discardFrames(sampler, @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate))));
    sampler.noteOff(0, 60);
    discardFrames(sampler, @intFromFloat(0.02 * @as(f32, @floatFromInt(sample_rate))));
    sampler.controlChange(0, 64, 127);
    discardFrames(sampler, @intFromFloat(1.0 * @as(f32, @floatFromInt(sample_rate))));
    sampler.controlChange(0, 64, 0);
    sampler.allNotesOff();
    discardFrames(sampler, @intFromFloat(0.1 * @as(f32, @floatFromInt(sample_rate))));

    sampler.noteOn(0, 60, 92);
    discardFrames(sampler, @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate))));
    sampler.noteOff(0, 60);
    // Catch the physically releasing strings before the one-second damped
    // off-time expires. A 20 ms gap is long enough to enter release while
    // remaining inside sfizz's deterministic repedal window.
    discardFrames(sampler, @intFromFloat(0.02 * @as(f32, @floatFromInt(sample_rate))));
    if (repedal) sampler.controlChange(0, 64, 127);
    renderFrames(sampler, output);
}

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const command = arguments.next() orelse return samplerUsage();
    if (std.mem.eql(u8, command, "verify")) return runVerify(init, &arguments);
    if (std.mem.eql(u8, command, "render")) return runRender(init, &arguments);
    if (std.mem.eql(u8, command, "render-score")) return runRenderScore(init, &arguments);
    return samplerUsage();
}

fn samplerUsage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  score-sampler-workbench verify [REPORT.json] [EVIDENCE.wav] [PIANO.sfz]
        \\  score-sampler-workbench render [OUTPUT.wav] [PIANO.sfz]
        \\  score-sampler-workbench render-score SCORE.mxl OUTPUT.wav [PIANO.sfz] [--start-beat N] [--end-beat N] [--tail-seconds N] [--quarter-bpm N] [--detail RELEASE:HAMMER:PEDAL_NOISE:RESONANCE]
        \\
    , .{});
    return error.InvalidArguments;
}

fn scoreEventLessThan(_: void, left: ScoreEvent, right: ScoreEvent) bool {
    if (left.frame != right.frame) return left.frame < right.frame;
    return @intFromEnum(left.kind) < @intFromEnum(right.kind);
}

fn scoreSecondsAtBeat(report: *const score.musicxml.ImportReport, requested_beat: f32) f32 {
    const beat = @max(0, requested_beat);
    if (beat == 0) return 0;
    const fallback_quarter = score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit);
    if (report.tempo_count == 0) return beat * 60.0 / @max(1, fallback_quarter);

    var seconds: f32 = 0;
    var cursor: f32 = 0;
    var current_bpm = @max(1, report.tempos[0].bpm);
    for (report.tempos[0..report.tempo_count]) |tempo| {
        const change_beat = std.math.clamp(tempo.start_beat, cursor, beat);
        if (change_beat > cursor) {
            seconds += (change_beat - cursor) * 60.0 / current_bpm;
            cursor = change_beat;
        }
        if (tempo.start_beat > beat) break;
        current_bpm = @max(1, tempo.bpm);
    }
    if (cursor < beat) seconds += (beat - cursor) * 60.0 / current_bpm;
    return seconds;
}

fn scoreFrameAtBeat(report: *const score.musicxml.ImportReport, start_seconds: f32, beat: f32) usize {
    const relative_seconds = @max(0, scoreSecondsAtBeat(report, beat) - start_seconds);
    return @intFromFloat(@round(relative_seconds * @as(f32, @floatFromInt(sample_rate))));
}

fn readScoreInto(init: std.process.Init, path: []const u8, report: *score.musicxml.ImportReport) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_score_file_bytes));
    defer init.gpa.free(bytes);
    if (std.mem.endsWith(u8, path, ".mxl")) {
        const xml = try score.mxl.extract(init.gpa, bytes);
        defer init.gpa.free(xml);
        return score.musicxml.parseInto(xml, report);
    }
    return score.musicxml.parseInto(bytes, report);
}

fn scorePedalController(pedal: u8) ?u8 {
    return switch (pedal) {
        score.model.pedal_sustain => 64,
        score.model.pedal_sostenuto => 66,
        score.model.pedal_soft => 67,
        else => null,
    };
}

fn parseDetailProfile(value: []const u8) !PianoDetailProfile {
    var fields = std.mem.splitScalar(u8, value, ':');
    const sampled_release = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const hammer_noise = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const pedal_noise = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const pedal_resonance = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    if (fields.next() != null or sampled_release > 127 or hammer_noise > 127 or pedal_noise > 127 or pedal_resonance > 127) return error.InvalidDetailProfile;
    return .{
        .sampled_release = sampled_release,
        .hammer_noise = hammer_noise,
        .pedal_noise = pedal_noise,
        .pedal_resonance = pedal_resonance,
    };
}

fn runRenderScore(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const score_path = arguments.next() orelse return error.InvalidArguments;
    const output_path = arguments.next() orelse return error.InvalidArguments;
    var sfz_path: [:0]const u8 = "local-content/instruments/AccurateSalamanderGrandPianoV6.2beta2/sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz";
    var start_beat: f32 = 0;
    var end_beat: f32 = 42;
    var tail_seconds: f32 = 2.5;
    var quarter_bpm_override: ?f32 = null;
    var detail_profile = PianoDetailProfile.studio;
    var sfz_seen = false;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--start-beat")) {
            start_beat = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--end-beat")) {
            end_beat = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--tail-seconds")) {
            tail_seconds = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--quarter-bpm")) {
            quarter_bpm_override = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--detail")) {
            detail_profile = try parseDetailProfile(arguments.next() orelse return error.MissingValue);
        } else if (!sfz_seen and !std.mem.startsWith(u8, argument, "--")) {
            sfz_path = argument;
            sfz_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (!std.math.isFinite(start_beat) or !std.math.isFinite(end_beat) or !std.math.isFinite(tail_seconds) or start_beat < 0 or end_beat <= start_beat or tail_seconds < 0) return error.InvalidArguments;
    if (quarter_bpm_override) |bpm| if (!std.math.isFinite(bpm) or bpm <= 0) return error.InvalidArguments;

    const report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(report);
    try readScoreInto(init, score_path, report);
    if (quarter_bpm_override) |bpm| {
        report.tempo_count = 1;
        report.tempos[0] = .{ .start_beat = 0, .bpm = bpm };
    }
    const start_seconds = scoreSecondsAtBeat(report, start_beat);
    const range_seconds = scoreSecondsAtBeat(report, end_beat) - start_seconds;
    if (range_seconds <= 0) return error.InvalidArguments;

    var events: std.ArrayList(ScoreEvent) = .empty;
    defer events.deinit(init.gpa);
    var scheduled_notes: usize = 0;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_rest | score.model.note_flag_vocal_guide)) != 0) continue;
        const note_end = note.start_beat + @max(0.001, note.duration_beats);
        if (note.start_beat < start_beat or note.start_beat >= end_beat or note_end <= start_beat) continue;
        try events.append(init.gpa, .{
            .frame = scoreFrameAtBeat(report, start_seconds, note.start_beat),
            .kind = .note_on,
            .pitch_or_controller = note.pitch,
            .value = @max(1, note.velocity),
        });
        try events.append(init.gpa, .{
            .frame = scoreFrameAtBeat(report, start_seconds, @min(end_beat, note_end)),
            .kind = .note_off,
            .pitch_or_controller = note.pitch,
            .value = 64,
        });
        scheduled_notes += 1;
    }
    for (report.pedals[0..report.pedal_count]) |pedal| {
        if (pedal.start_beat < start_beat or pedal.start_beat >= end_beat) continue;
        const controller = scorePedalController(pedal.pedal) orelse continue;
        const pedal_frame = scoreFrameAtBeat(report, start_seconds, pedal.start_beat);
        if (pedal.action == score.model.pedal_action_change and pedal.value != 0) {
            // MusicXML change-pedal is an up/down repedal. Give sfizz one
            // millisecond of rendered controller-up state so damped voices
            // are actually released before the pedal is depressed again.
            try events.append(init.gpa, .{
                .frame = pedal_frame,
                .kind = .control_change,
                .pitch_or_controller = controller,
                .value = 0,
            });
        }
        try events.append(init.gpa, .{
            .frame = pedal_frame + if (pedal.action == score.model.pedal_action_change and pedal.value != 0) sample_rate / 1000 else 0,
            .kind = .control_change,
            .pitch_or_controller = controller,
            .value = pedal.value,
        });
    }
    std.mem.sort(ScoreEvent, events.items, {}, scoreEventLessThan);

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();
    sampler.applyPianoDetailProfile(detail_profile);
    sampler.controlChange(0, 64, 0);
    sampler.controlChange(0, 66, 0);
    sampler.controlChange(0, 67, 0);

    const musical_frames: usize = @intFromFloat(@ceil(range_seconds * @as(f32, @floatFromInt(sample_rate))));
    const tail_frames: usize = @intFromFloat(@ceil(tail_seconds * @as(f32, @floatFromInt(sample_rate))));
    const frame_count = musical_frames + tail_frames;
    const output = try init.gpa.alloc(f32, frame_count * channels);
    defer init.gpa.free(output);
    @memset(output, 0);

    var event_index: usize = 0;
    var frame: usize = 0;
    while (frame < frame_count) {
        while (event_index < events.items.len and events.items[event_index].frame <= frame) : (event_index += 1) {
            const event = events.items[event_index];
            switch (event.kind) {
                .control_change => sampler.controlChange(0, event.pitch_or_controller, event.value),
                .note_off => sampler.noteOff(0, event.pitch_or_controller),
                .note_on => sampler.noteOn(0, event.pitch_or_controller, event.value),
            }
        }
        const next_event_frame = if (event_index < events.items.len) @min(frame_count, events.items[event_index].frame) else frame_count;
        const count = @min(block_frames, @max(@as(usize, 1), next_event_frame - frame));
        sampler.renderInterleaved(output[frame * channels .. (frame + count) * channels], count, channels, sample_rate);
        frame += count;
    }

    const encoded = try score.wav.encodePcm16(init.gpa, output, sample_rate, channels);
    defer init.gpa.free(encoded);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });
    const stats = score.audio_quality.analyze(output);
    std.log.info(
        "rendered score {s} -> {s}: beats={d:.3}..{d:.3} seconds={d:.3} notes={d} pedals={d} detail={d}:{d}:{d}:{d} peak={d:.2}dBFS overloads={d}",
        .{ score_path, output_path, start_beat, end_beat, range_seconds, scheduled_notes, report.pedal_count, detail_profile.sampled_release, detail_profile.hammer_noise, detail_profile.pedal_noise, detail_profile.pedal_resonance, stats.peakDbfs(), sampler.overloadedSampleCount() },
    );
}

fn runRender(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const output_path = arguments.next() orelse ".zig-cache/verification/salamander-grand-proof.wav";
    const sfz_path = arguments.next() orelse "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    if (arguments.next() != null) return error.TooManyArguments;

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();

    const frame_count = @as(usize, sample_rate) * proof_seconds;
    const output = try init.gpa.alloc(f32, frame_count * channels);
    defer init.gpa.free(output);
    @memset(output, 0);

    sampler.controlChange(0, 64, 112);
    const phrase = [_]u8{ 36, 48, 55, 60, 64, 67, 72, 76, 79, 84 };
    var next_note: usize = 0;
    var pedal_released = false;
    var chord_started = false;
    var chord_released = false;
    var frame: usize = 0;
    while (frame < frame_count) {
        while (next_note < phrase.len and frame >= next_note * sample_rate / 2) : (next_note += 1) {
            sampler.noteOn(0, phrase[next_note], @intCast(38 + next_note * 8));
            if (next_note >= 3) sampler.noteOff(0, phrase[next_note - 3]);
        }
        if (!pedal_released and frame >= sample_rate * 6) {
            pedal_released = true;
            sampler.controlChange(0, 64, 0);
            for (phrase) |pitch| sampler.noteOff(0, pitch);
        }
        if (!chord_started and frame >= sample_rate * 7) {
            chord_started = true;
            for ([_]u8{ 48, 55, 60, 64, 67 }, 0..) |pitch, index| sampler.noteOn(0, pitch, @intCast(58 + index * 6));
        }
        if (!chord_released and frame >= sample_rate * 9) {
            chord_released = true;
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOff(0, pitch);
        }
        const count = @min(block_frames, frame_count - frame);
        sampler.renderInterleaved(output[frame * channels .. (frame + count) * channels], count, channels, sample_rate);
        frame += count;
    }

    const encoded = try score.wav.encodePcm16(init.gpa, output, sample_rate, channels);
    defer init.gpa.free(encoded);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });
    std.log.info("rendered {s}: {d} regions, {d} preloaded samples", .{ output_path, sampler.region_count, sampler.preloaded_sample_count });
}

fn runVerify(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const report_path = arguments.next() orelse ".zig-cache/verification/sampler-quality.json";
    const wav_path = arguments.next() orelse ".zig-cache/verification/sampler-quality.wav";
    const sfz_path = arguments.next() orelse "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    if (arguments.next() != null) return error.TooManyArguments;

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();

    const output = try init.gpa.alloc(f32, output_seconds * sample_rate * channels);
    defer init.gpa.free(output);
    @memset(output, 0);
    var harness = Harness{ .sampler = sampler, .output = output };
    var gate: Gate = .{};
    const continuous_pedal_profile = std.mem.indexOf(u8, sfz_path, "AccurateSalamander") != null and std.mem.indexOf(u8, sfz_path, "/sfz_live/") != null;

    const baseline = score.audio_quality.analyze(try harness.seconds(0.2));
    gate.require(baseline.rms < 0.000001, "idle output is not silent");

    const velocities = [_]u8{ 8, 24, 40, 56, 72, 88, 104, 120 };
    var velocity_stats: [velocities.len]score.audio_quality.Stats = undefined;
    for (velocities, 0..) |velocity, index| {
        try harness.reset();
        sampler.noteOn(0, 60, velocity);
        velocity_stats[index] = score.audio_quality.analyze(try harness.seconds(0.32));
        sampler.noteOff(0, 60);
        _ = try harness.seconds(0.28);
    }
    var rising_steps: usize = 0;
    for (velocity_stats[1..], 0..) |stats, index| {
        if (stats.rms > velocity_stats[index].rms * 1.015) rising_steps += 1;
    }
    const velocity_range_db = score.audio_quality.ratioDb(velocity_stats[velocity_stats.len - 1].rms, velocity_stats[0].rms);
    gate.require(rising_steps >= 5, "velocity layers are not sufficiently monotonic");
    gate.require(velocity_range_db >= 12, "velocity response has insufficient dynamic range");

    try harness.reset();
    sampler.controlChange(0, 22, 127);
    sampler.noteOn(0, 60, 96);
    _ = try harness.seconds(0.35);
    sampler.controlChange(0, 64, 127);
    sampler.noteOff(0, 60);
    const sustain_hold = score.audio_quality.analyze(try harness.seconds(0.85));
    sampler.controlChange(0, 64, 0);
    const sustain_release_full = try harness.seconds(1.4);
    const release_tail_start = sustain_release_full.len * 2 / 3;
    const sustain_release_tail = score.audio_quality.analyze(sustain_release_full[release_tail_start..]);
    const sustain_release_db = score.audio_quality.ratioDb(sustain_hold.rms, sustain_release_tail.rms);
    gate.require(sustain_hold.rms > 0.0001, "sustain pedal did not hold audible energy");
    gate.require(sustain_release_db >= 2.5, "pedal-up did not produce a measurable release decay");

    // Accurate-Salamander documents an explicit Disklavier-calibrated curve:
    // 0/32 are dry, 42/54/62 are progressively half-pedaled, and 64+ is full.
    const pedal_values = [_]u8{ 0, 32, 42, 54, 62, 64, 127 };
    var pedal_curve_stats: [pedal_values.len]score.audio_quality.Stats = undefined;
    for (pedal_values, 0..) |value, index| pedal_curve_stats[index] = try pedalReleaseProbe(&harness, value);
    const pedal_up_release = pedal_curve_stats[0];
    const pedal_half_release = pedal_curve_stats[3];
    const pedal_full_release = pedal_curve_stats[pedal_curve_stats.len - 1];
    if (continuous_pedal_profile) {
        gate.require(pedal_curve_stats[1].rms <= pedal_up_release.rms * 1.15, "documented dry pedal range changed release unexpectedly");
        gate.require(pedal_half_release.rms > pedal_up_release.rms * 1.15, "half pedal does not extend release over pedal-up");
        gate.require(pedal_curve_stats[5].rms > pedal_half_release.rms * 1.15, "full-pedal threshold is not measurably longer than half pedal");
        gate.require(pedal_full_release.rms >= pedal_curve_stats[5].rms * 0.85, "full pedal loses release energy above its threshold");
    }

    const detail_controllers = [_]u8{ 20, 21, 22, 23 };
    var detail_comparisons = [_]ReplayComparison{.{
        .bit_exact = true,
        .max_abs_error = 0,
        .normalized_rms_error = 0,
        .correlation = 1,
    }} ** detail_controllers.len;
    if (continuous_pedal_profile) {
        const detail_frames: usize = @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate)));
        const detail_dry = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(detail_dry);
        const detail_enabled = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(detail_enabled);
        for (detail_controllers, 0..) |controller, index| {
            try renderDetailProbe(init.gpa, &library_paths, sfz_path, controller, false, detail_dry);
            try renderDetailProbe(init.gpa, &library_paths, sfz_path, controller, true, detail_enabled);
            detail_comparisons[index] = compareReplay(detail_dry, detail_enabled);
            // These are deliberately modest machine gates: they prove the
            // named acoustic layer changes real PCM. Audible balance remains
            // a separate listening acceptance step.
            gate.require(detail_comparisons[index].max_abs_error > 0.000001, "enabled piano detail layer did not change rendered PCM");
            gate.require(detail_comparisons[index].normalized_rms_error > 0.0005, "enabled piano detail layer is below the measurable floor");
            try harness.append(detail_dry);
            try harness.append(detail_enabled);
        }
    }

    var repedal_comparison: ReplayComparison = .{
        .bit_exact = true,
        .max_abs_error = 0,
        .normalized_rms_error = 0,
        .correlation = 1,
    };
    var repedal_dry_stats: score.audio_quality.Stats = score.audio_quality.analyze(&.{});
    var repedal_caught_stats: score.audio_quality.Stats = score.audio_quality.analyze(&.{});
    if (continuous_pedal_profile) {
        const repedal_frames: usize = @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate)));
        const repedal_dry = try init.gpa.alloc(f32, repedal_frames * channels);
        defer init.gpa.free(repedal_dry);
        const repedal_caught = try init.gpa.alloc(f32, repedal_frames * channels);
        defer init.gpa.free(repedal_caught);
        try renderRepedalProbe(init.gpa, &library_paths, sfz_path, false, repedal_dry);
        try renderRepedalProbe(init.gpa, &library_paths, sfz_path, true, repedal_caught);
        repedal_dry_stats = score.audio_quality.analyze(repedal_dry);
        repedal_caught_stats = score.audio_quality.analyze(repedal_caught);
        repedal_comparison = compareReplay(repedal_dry, repedal_caught);
        gate.require(repedal_caught_stats.rms > repedal_dry_stats.rms * 1.15, "repedaling did not catch and extend the releasing note");
        gate.require(repedal_comparison.normalized_rms_error > 0.0005, "repedaling did not measurably change rendered PCM");
        try harness.append(repedal_dry);
        try harness.append(repedal_caught);
    }

    // Disable optional random/mechanical layers and render each attack through
    // a fresh engine. Reusing one sampler would compare a new note against the
    // first note's live release tail and advanced round-robin state, which is
    // not an identical initial condition and made this gate nondeterministic.
    const deterministic_frames: usize = @intFromFloat(0.22 * @as(f32, @floatFromInt(sample_rate)));
    const deterministic_a = try init.gpa.alloc(f32, deterministic_frames * channels);
    defer init.gpa.free(deterministic_a);
    const deterministic_b = try init.gpa.alloc(f32, deterministic_frames * channels);
    defer init.gpa.free(deterministic_b);
    try renderDeterministicAttack(init.gpa, &library_paths, sfz_path, deterministic_a);
    try renderDeterministicAttack(init.gpa, &library_paths, sfz_path, deterministic_b);
    const replay_comparison = compareReplay(deterministic_a, deterministic_b);
    const deterministic_replay = replay_comparison.bit_exact;
    const stable_midi_replay = replay_comparison.correlation >= 0.90 and replay_comparison.normalized_rms_error <= 0.50;
    std.log.info("MIDI replay comparison: exact={} max_error={d:.8} normalized_rms_error={d:.8} correlation={d:.8}", .{
        deterministic_replay,
        replay_comparison.max_abs_error,
        replay_comparison.normalized_rms_error,
        replay_comparison.correlation,
    });
    gate.require(score.audio_quality.analyze(deterministic_a).rms > 0.0001, "nonzero MIDI channel rendered silence");
    gate.require(stable_midi_replay, "identical MIDI attack replay is not stable");

    try harness.reset();
    sampler.controlChange(0, 22, 127);
    sampler.controlChange(0, 64, 0);
    _ = try harness.seconds(0.08);
    sampler.controlChange(0, 64, 127);
    const pedal_down = score.audio_quality.analyze(try harness.seconds(0.35));
    sampler.controlChange(0, 64, 0);
    const pedal_up = score.audio_quality.analyze(try harness.seconds(0.35));
    gate.require(@max(pedal_down.rms, pedal_up.rms) > 0.00001, "pedal mechanical samples are silent");

    try harness.reset();
    const dropped_before = sampler.droppedEventCount();
    const overloaded_before = sampler.overloadedSampleCount();
    var pitch: u8 = 36;
    while (pitch <= 92) : (pitch += 4) sampler.noteOn(0, pitch, 52);
    const stress = score.audio_quality.analyze(try harness.seconds(0.7));
    pitch = 36;
    while (pitch <= 92) : (pitch += 4) sampler.noteOff(0, pitch);
    _ = try harness.seconds(0.5);
    const dropped_delta = sampler.droppedEventCount() - dropped_before;
    const overloaded_delta = sampler.overloadedSampleCount() - overloaded_before;
    gate.require(dropped_delta == 0, "real-time event queue dropped MIDI events");
    gate.require(overloaded_delta == 0, "stress chord overloaded the unclamped mix");
    gate.require(stress.rms > 0.0001, "stress chord rendered silence");

    const complete = score.audio_quality.analyze(harness.rendered());
    gate.require(complete.non_finite_samples == 0, "render contains NaN or infinity");
    gate.require(complete.clipped_samples == 0, "render contains clipped PCM samples");

    const pcm = try score.wav.encodePcm16(init.gpa, harness.rendered(), sample_rate, channels);
    defer init.gpa.free(pcm);
    if (std.fs.path.dirname(wav_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = wav_path, .data = pcm });

    var json: std.Io.Writer.Allocating = .init(init.gpa);
    defer json.deinit();
    const writer = &json.writer;
    try writer.print(
        "{{\n  \"schema\": 2,\n  \"passed\": {s},\n  \"instrument\": \"{s}\",\n  \"regions\": {d},\n  \"preloaded_samples\": {d},\n  \"sample_rate\": {d},\n  \"rendered_frames\": {d},\n",
        .{ if (gate.passed) "true" else "false", sfz_path, sampler.region_count, sampler.preloaded_sample_count, sample_rate, harness.frame_cursor },
    );
    try writer.print("  \"complete\": {{\"peak_dbfs\":{d:.3},\"rms_dbfs\":{d:.3},\"dc\":{d:.8},\"non_finite\":{d},\"clipped\":{d}}},\n", .{ complete.peakDbfs(), complete.rmsDbfs(), complete.dc, complete.non_finite_samples, complete.clipped_samples });
    try writer.writeAll("  \"velocity_sweep\": [");
    for (velocities, 0..) |velocity, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"velocity\":{d},\"peak_dbfs\":{d:.3},\"rms_dbfs\":{d:.3}}}", .{ velocity, velocity_stats[index].peakDbfs(), velocity_stats[index].rmsDbfs() });
    }
    try writer.print("],\n  \"velocity_rising_steps\": {d},\n  \"velocity_range_db\": {d:.3},\n", .{ rising_steps, velocity_range_db });
    try writer.writeAll("  \"pedal\": {\"hold_rms_dbfs\":");
    try writeJsonFloat(writer, sustain_hold.rmsDbfs());
    try writer.writeAll(",\"release_tail_rms_dbfs\":");
    try writeJsonFloat(writer, sustain_release_tail.rmsDbfs());
    try writer.writeAll(",\"hold_release_db\":");
    try writeJsonFloat(writer, sustain_release_db);
    try writer.writeAll(",\"down_noise_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_down.rmsDbfs());
    try writer.writeAll(",\"up_noise_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_up.rmsDbfs());
    try writer.print(",\"continuous_profile\":{s},\"up_release_rms_dbfs\":", .{if (continuous_pedal_profile) "true" else "false"});
    try writeJsonFloat(writer, pedal_up_release.rmsDbfs());
    try writer.writeAll(",\"half_release_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_half_release.rmsDbfs());
    try writer.writeAll(",\"full_release_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_full_release.rmsDbfs());
    try writer.writeAll(",\"curve\":[");
    for (pedal_values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"cc64\":{d},\"release_rms_dbfs\":", .{value});
        try writeJsonFloat(writer, pedal_curve_stats[index].rmsDbfs());
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    try writer.writeAll("},\n");
    const detail_names = [_][]const u8{ "sampled_release", "hammer_noise", "pedal_noise", "pedal_resonance" };
    try writer.print("  \"piano_detail_profile\": {{\"available\":{s},\"layers\":[", .{if (continuous_pedal_profile) "true" else "false"});
    for (detail_names, detail_comparisons, 0..) |name, comparison, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"changes_pcm\":{s},\"max_abs_error\":{d:.8},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}}", .{
            name,
            if (!comparison.bit_exact) "true" else "false",
            comparison.max_abs_error,
            comparison.normalized_rms_error,
            comparison.correlation,
        });
    }
    try writer.writeAll("]},\n");
    try writer.writeAll("  \"repedaling\": {\"dry_rms_dbfs\":");
    try writeJsonFloat(writer, repedal_dry_stats.rmsDbfs());
    try writer.writeAll(",\"caught_rms_dbfs\":");
    try writeJsonFloat(writer, repedal_caught_stats.rmsDbfs());
    try writer.print(",\"changes_pcm\":{s},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}},\n", .{
        if (!repedal_comparison.bit_exact) "true" else "false",
        repedal_comparison.normalized_rms_error,
        repedal_comparison.correlation,
    });
    try writer.print(
        "  \"deterministic_midi_replay\": {s},\n  \"midi_replay\": {{\"stable\":{s},\"bit_exact\":{s},\"max_abs_error\":{d:.8},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}},\n",
        .{
            if (deterministic_replay) "true" else "false",
            if (stable_midi_replay) "true" else "false",
            if (deterministic_replay) "true" else "false",
            replay_comparison.max_abs_error,
            replay_comparison.normalized_rms_error,
            replay_comparison.correlation,
        },
    );
    try writer.print("  \"stress\": {{\"rms_dbfs\":{d:.3},\"dropped_events\":{d},\"overloaded_samples\":{d}}},\n  \"evidence_pcm_crc32\": \"{x:0>8}\",\n  \"failures\": [", .{ stress.rmsDbfs(), dropped_delta, overloaded_delta, std.hash.crc.Crc32.hash(pcm) });
    for (gate.failures[0..gate.failure_count], 0..) |failure, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{failure});
    }
    try writer.writeAll("]\n}\n");
    if (std.fs.path.dirname(report_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = json.written() });

    std.log.info("sampler verification {s}: {s}; {d} regions / {d} samples", .{ if (gate.passed) "passed" else "failed", report_path, sampler.region_count, sampler.preloaded_sample_count });
    if (!gate.passed) return error.SamplerQualityGateFailed;
}
