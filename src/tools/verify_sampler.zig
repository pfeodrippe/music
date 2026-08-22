const std = @import("std");
const score = @import("score");
const Sampler = @import("sfizz_sampler").Sampler;

const sample_rate: u32 = 48_000;
const channels: usize = 2;
const block_frames: usize = 256;
const output_seconds: usize = 21;

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

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
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

    const pedal_up_release = try pedalReleaseProbe(&harness, 0);
    // Accurate-Salamander's documented curve reaches full sustain at 64; 54
    // is its intentionally intermediate Disklavier-calibrated half-pedal point.
    const pedal_half_release = try pedalReleaseProbe(&harness, 54);
    const pedal_full_release = try pedalReleaseProbe(&harness, 127);
    const continuous_pedal_profile = std.mem.indexOf(u8, sfz_path, "AccurateSalamander") != null and std.mem.indexOf(u8, sfz_path, "/sfz_live/") != null;
    if (continuous_pedal_profile) {
        gate.require(pedal_half_release.rms > pedal_up_release.rms * 1.15, "half pedal does not extend release over pedal-up");
        gate.require(pedal_full_release.rms > pedal_half_release.rms * 1.15, "full pedal is not measurably longer than half pedal");
    }

    // Disable optional random/mechanical layers for an exact replay check. A
    // production performance may intentionally select alternate pedal noises,
    // but identical MIDI into the deterministic attack path must be bit-exact.
    sampler.controlChange(0, 20, 0);
    sampler.controlChange(0, 21, 0);
    sampler.controlChange(0, 22, 0);
    try harness.reset();
    sampler.noteOn(3, 64, 82);
    const deterministic_a = try harness.seconds(0.22);
    sampler.noteOff(3, 64);
    _ = try harness.seconds(0.18);
    try harness.reset();
    sampler.noteOn(3, 64, 82);
    const deterministic_b = try harness.seconds(0.22);
    sampler.noteOff(3, 64);
    _ = try harness.seconds(0.18);
    const deterministic_replay = std.mem.eql(f32, deterministic_a, deterministic_b);
    gate.require(score.audio_quality.analyze(deterministic_a).rms > 0.0001, "nonzero MIDI channel rendered silence");
    gate.require(deterministic_replay, "identical MIDI attack replay is not bit-exact");

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
        "{{\n  \"schema\": 1,\n  \"passed\": {s},\n  \"instrument\": \"{s}\",\n  \"regions\": {d},\n  \"preloaded_samples\": {d},\n  \"sample_rate\": {d},\n  \"rendered_frames\": {d},\n",
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
    try writer.writeAll("},\n");
    try writer.print("  \"deterministic_midi_replay\": {s},\n", .{if (deterministic_replay) "true" else "false"});
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
