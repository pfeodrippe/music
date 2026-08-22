const std = @import("std");

pub const target_sample_rate: u32 = 8_000;
pub const feature_hz: u32 = 4;
pub const max_candidates: usize = 6;
pub const max_tempo_candidates: usize = 5;
const tempo_sample_rate: u32 = 44_100;
const onset_fft_size: usize = 4_096;
const onset_hop: usize = 512;

pub const TempoCandidate = struct {
    bpm: f32,
    relative_score: f32,
};

pub const FeatureFrame = struct {
    time_seconds: f32,
    rms: f32,
    onset_strength: f32,
    bass_pitch: u8,
    pitch_count: u8,
    pitches: [max_candidates]u8,
    chroma: [12]f32,
};

pub const Analysis = struct {
    duration_seconds: f32,
    estimated_tempo_bpm: f32,
    tempo_confidence: f32,
    tempo_candidate_count: u8,
    tempo_candidates: [max_tempo_candidates]TempoCandidate,
    frames: []FeatureFrame,
    onsets: []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.onsets);
        self.* = undefined;
    }
};

pub fn analyze(allocator: std.mem.Allocator, source: []const f32, source_rate: u32) !Analysis {
    if (source.len == 0 or source_rate < 4_000) return error.InvalidAudio;
    const samples = try resample(allocator, source, source_rate, target_sample_rate);
    defer allocator.free(samples);
    const tempo_samples = try resample(allocator, source, source_rate, tempo_sample_rate);
    defer allocator.free(tempo_samples);
    const duration = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(target_sample_rate));

    const envelope = try spectralFluxEnvelope(allocator, tempo_samples);
    defer allocator.free(envelope);
    var envelope_mean: f32 = 0;
    for (envelope) |value| envelope_mean += value;
    envelope_mean /= @as(f32, @floatFromInt(envelope.len));
    var variance: f32 = 0;
    for (envelope) |value| variance += (value - envelope_mean) * (value - envelope_mean);
    const envelope_std = @sqrt(variance / @as(f32, @floatFromInt(envelope.len)));

    var onset_list: std.ArrayList(f32) = .empty;
    defer onset_list.deinit(allocator);
    var last_onset: f32 = -10;
    for (envelope, 0..) |value, index| {
        if (index == 0 or index + 1 == envelope.len) continue;
        const time = @as(f32, @floatFromInt(index * onset_hop)) / @as(f32, @floatFromInt(tempo_sample_rate));
        if (value > envelope_mean + 0.72 * envelope_std and value >= envelope[index - 1] and value > envelope[index + 1] and time - last_onset >= 0.065) {
            try onset_list.append(allocator, time);
            last_onset = time;
        }
    }
    const envelope_rate = @as(f32, @floatFromInt(tempo_sample_rate)) / @as(f32, @floatFromInt(onset_hop));
    const tempo = if (onset_list.items.len >= 4) estimateTempo(envelope, envelope_rate, envelope_mean) else Tempo{ .bpm = 0, .confidence = 0 };

    const frame_hop: usize = target_sample_rate / feature_hz;
    const window_size: usize = 1024;
    const frame_count = @max(1, (samples.len + frame_hop - 1) / frame_hop);
    const frames = try allocator.alloc(FeatureFrame, frame_count);
    errdefer allocator.free(frames);
    var windowed: [window_size]f32 = undefined;
    for (frames, 0..) |*frame, frame_index| {
        const center = frame_index * frame_hop;
        const start = center -| window_size / 2;
        var rms: f32 = 0;
        for (&windowed, 0..) |*sample, offset| {
            const source_index = start + offset;
            const raw = if (source_index < samples.len) samples[source_index] else 0;
            const phase = @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(window_size - 1));
            const hann = 0.5 - 0.5 * @cos(std.math.tau * phase);
            sample.* = raw * hann;
            rms += raw * raw;
        }
        rms = @sqrt(rms / window_size);
        var energies: [88]f32 = undefined;
        var maximum: f32 = 0;
        var bass_pitch: u8 = 255;
        var bass_energy: f32 = 0;
        var chroma = [_]f32{0} ** 12;
        for (&energies, 0..) |*energy, offset| {
            const pitch: u8 = @intCast(offset + 21);
            const frequency = midiFrequency(pitch);
            const fundamental = goertzel(&windowed, frequency, target_sample_rate);
            var value = fundamental;
            if (frequency * 2 < @as(f32, @floatFromInt(target_sample_rate)) * 0.48) {
                const second = goertzel(&windowed, frequency * 2, target_sample_rate);
                // Reinforce a harmonic only when its fundamental is actually
                // present. Adding second-harmonic energy directly creates a
                // false sub-octave for every pure tone and vocal overtone.
                value += 0.18 * @sqrt(fundamental * second);
            }
            energy.* = value;
            maximum = @max(maximum, value);
            chroma[pitch % 12] += @sqrt(@max(0, value));
            if (pitch <= 59 and value > bass_energy) {
                bass_energy = value;
                bass_pitch = pitch;
            }
        }
        if (bass_energy < maximum * 0.055) bass_pitch = 255;
        var pitches = [_]u8{255} ** max_candidates;
        var selected_energy = [_]f32{0} ** max_candidates;
        var pitch_count: u8 = 0;
        if (maximum > 0.0000001 and rms > 0.0004) {
            for (energies, 0..) |energy, offset| {
                if (energy < maximum * 0.075) continue;
                if (offset > 0 and energy < energies[offset - 1]) continue;
                if (offset + 1 < energies.len and energy <= energies[offset + 1]) continue;
                var insert: usize = 0;
                while (insert < max_candidates and selected_energy[insert] >= energy) : (insert += 1) {}
                if (insert == max_candidates) continue;
                var move = max_candidates - 1;
                while (move > insert) : (move -= 1) {
                    selected_energy[move] = selected_energy[move - 1];
                    pitches[move] = pitches[move - 1];
                }
                selected_energy[insert] = energy;
                pitches[insert] = @intCast(offset + 21);
                pitch_count = @intCast(@min(max_candidates, @as(usize, pitch_count) + 1));
            }
        }
        var chroma_total: f32 = 0;
        for (chroma) |value| chroma_total += value;
        if (chroma_total > 0) {
            for (&chroma) |*value| value.* /= chroma_total;
        }
        const frame_time = @as(f32, @floatFromInt(center)) / @as(f32, @floatFromInt(target_sample_rate));
        const envelope_index = @min(envelope.len - 1, @as(usize, @intFromFloat(frame_time * envelope_rate)));
        frame.* = .{
            .time_seconds = frame_time,
            .rms = rms,
            .onset_strength = envelope[envelope_index],
            .bass_pitch = bass_pitch,
            .pitch_count = pitch_count,
            .pitches = pitches,
            .chroma = chroma,
        };
    }

    return .{
        .duration_seconds = duration,
        .estimated_tempo_bpm = tempo.bpm,
        .tempo_confidence = tempo.confidence,
        .tempo_candidate_count = tempo.candidate_count,
        .tempo_candidates = tempo.candidates,
        .frames = frames,
        .onsets = try onset_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn resample(allocator: std.mem.Allocator, source: []const f32, source_rate: u32, destination_rate: u32) ![]f32 {
    const count = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(source.len)) * @as(f64, @floatFromInt(destination_rate)) / @as(f64, @floatFromInt(source_rate)))));
    const output = try allocator.alloc(f32, count);
    const ratio = @as(f64, @floatFromInt(source_rate)) / @as(f64, @floatFromInt(destination_rate));
    for (output, 0..) |*sample, index| {
        const position = @as(f64, @floatFromInt(index)) * ratio;
        const base: usize = @min(source.len - 1, @as(usize, @intFromFloat(@floor(position))));
        const next = @min(source.len - 1, base + 1);
        const fraction: f32 = @floatCast(position - @floor(position));
        sample.* = source[base] + (source[next] - source[base]) * fraction;
    }
    return output;
}

fn spectralFluxEnvelope(allocator: std.mem.Allocator, samples: []const f32) ![]f32 {
    const frame_count = if (samples.len <= onset_fft_size) 1 else (samples.len - onset_fft_size) / onset_hop + 1;
    const envelope = try allocator.alloc(f32, frame_count);
    errdefer allocator.free(envelope);
    var previous = [_]f32{0} ** (onset_fft_size / 2 + 1);
    var real: [onset_fft_size]f32 = undefined;
    var imaginary = [_]f32{0} ** onset_fft_size;
    for (envelope, 0..) |*flux, frame_index| {
        const start = @min(frame_index * onset_hop, samples.len -| 1);
        var energy: f32 = 0;
        for (&real, 0..) |*value, offset| {
            const sample = if (start + offset < samples.len) samples[start + offset] else 0;
            const phase = @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(onset_fft_size - 1));
            value.* = sample * (0.5 - 0.5 * @cos(std.math.tau * phase));
            energy += sample * sample;
        }
        @memset(&imaginary, 0);
        fft(&real, &imaginary);
        flux.* = 0;
        const rms = @sqrt(energy / onset_fft_size);
        for (previous[1..], 1..) |*old, bin| {
            const magnitude = if (rms < 0.0003) 0 else @log(1.0 + 10.0 * @sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]));
            flux.* += @max(0, magnitude - old.*);
            old.* = magnitude;
        }
    }
    return envelope;
}

fn fft(real: *[onset_fft_size]f32, imaginary: *[onset_fft_size]f32) void {
    var target: usize = 0;
    for (1..onset_fft_size) |index| {
        var bit = onset_fft_size >> 1;
        while ((target & bit) != 0) : (bit >>= 1) target ^= bit;
        target ^= bit;
        if (index < target) {
            std.mem.swap(f32, &real[index], &real[target]);
            std.mem.swap(f32, &imaginary[index], &imaginary[target]);
        }
    }
    var width: usize = 2;
    while (width <= onset_fft_size) : (width <<= 1) {
        const angle = -std.math.tau / @as(f32, @floatFromInt(width));
        const step_real = @cos(angle);
        const step_imaginary = @sin(angle);
        var block: usize = 0;
        while (block < onset_fft_size) : (block += width) {
            var weight_real: f32 = 1;
            var weight_imaginary: f32 = 0;
            for (0..width / 2) |offset| {
                const even = block + offset;
                const odd = even + width / 2;
                const odd_real = real[odd] * weight_real - imaginary[odd] * weight_imaginary;
                const odd_imaginary = real[odd] * weight_imaginary + imaginary[odd] * weight_real;
                const even_real = real[even];
                const even_imaginary = imaginary[even];
                real[even] = even_real + odd_real;
                imaginary[even] = even_imaginary + odd_imaginary;
                real[odd] = even_real - odd_real;
                imaginary[odd] = even_imaginary - odd_imaginary;
                const next_weight_real = weight_real * step_real - weight_imaginary * step_imaginary;
                weight_imaginary = weight_real * step_imaginary + weight_imaginary * step_real;
                weight_real = next_weight_real;
            }
        }
    }
}

fn midiFrequency(pitch: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(pitch)) - 69.0) / 12.0);
}

fn goertzel(samples: []const f32, frequency: f32, sample_rate: u32) f32 {
    const omega = std.math.tau * frequency / @as(f32, @floatFromInt(sample_rate));
    const coefficient = 2.0 * @cos(omega);
    var s1: f32 = 0;
    var s2: f32 = 0;
    for (samples) |sample| {
        const current = sample + coefficient * s1 - s2;
        s2 = s1;
        s1 = current;
    }
    return @max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2) / @as(f32, @floatFromInt(samples.len * samples.len));
}

const Tempo = struct {
    bpm: f32,
    confidence: f32,
    candidate_count: u8 = 0,
    candidates: [max_tempo_candidates]TempoCandidate = [_]TempoCandidate{.{ .bpm = 0, .relative_score = 0 }} ** max_tempo_candidates,
};

fn estimateTempo(envelope: []const f32, envelope_rate: f32, mean: f32) Tempo {
    const minimum_bpm: u32 = 45;
    const maximum_bpm: u32 = 180;
    var scores = [_]f32{0} ** (maximum_bpm - minimum_bpm + 1);
    for (minimum_bpm..maximum_bpm + 1) |bpm| {
        const lag = envelope_rate * 60 / @as(f32, @floatFromInt(bpm));
        const lag_floor: usize = @intFromFloat(@floor(lag));
        if (lag_floor + 1 >= envelope.len) continue;
        const fraction = lag - @as(f32, @floatFromInt(lag_floor));
        var score: f32 = 0;
        for (lag_floor + 1..envelope.len) |index| {
            const previous = envelope[index - lag_floor - 1] * fraction + envelope[index - lag_floor] * (1 - fraction);
            score += @max(0, envelope[index] - mean) * @max(0, previous - mean);
        }
        scores[bpm - minimum_bpm] = score;
    }

    var result: Tempo = .{ .bpm = 0, .confidence = 0 };
    var candidate_scores = [_]f32{0} ** max_tempo_candidates;
    while (result.candidate_count < max_tempo_candidates) {
        var best_index: ?usize = null;
        var best_score: f32 = 0;
        for (scores, 0..) |score, index| {
            if (score <= 0) continue;
            if (index > 0 and score < scores[index - 1]) continue;
            if (index + 1 < scores.len and score <= scores[index + 1]) continue;
            const bpm: i32 = @intCast(index + minimum_bpm);
            var separated = true;
            for (result.candidates[0..result.candidate_count]) |candidate| {
                if (@abs(@as(f32, @floatFromInt(bpm)) - candidate.bpm) < 4) separated = false;
            }
            if (separated and score > best_score) {
                best_score = score;
                best_index = index;
            }
        }
        const index = best_index orelse break;
        const slot = result.candidate_count;
        result.candidates[slot] = .{ .bpm = @floatFromInt(index + minimum_bpm), .relative_score = best_score };
        candidate_scores[slot] = best_score;
        result.candidate_count += 1;
        scores[index] = -1;
    }
    if (result.candidate_count == 0) return result;
    result.bpm = result.candidates[0].bpm;
    const best_score = candidate_scores[0];
    for (result.candidates[0..result.candidate_count]) |*candidate| candidate.relative_score /= best_score;
    if (result.candidate_count == 1) {
        result.confidence = 1;
    } else {
        // Confidence is separation from the next distinct tempo peak. It is
        // intentionally low for half/double-time ambiguity instead of being
        // inflated by the total number of BPM bins searched.
        result.confidence = std.math.clamp(1.0 - candidate_scores[1] / best_score, 0, 1);
    }
    return result;
}

test "analysis finds a sustained A4 candidate" {
    const rate: u32 = 8_000;
    const samples = try std.testing.allocator.alloc(f32, rate);
    defer std.testing.allocator.free(samples);
    for (samples, 0..) |*sample, index| sample.* = 0.4 * @sin(std.math.tau * 440.0 * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(rate)));
    var result = try analyze(std.testing.allocator, samples, rate);
    defer result.deinit();
    var found = false;
    for (result.frames) |frame| for (frame.pitches[0..frame.pitch_count]) |pitch| if (pitch == 69) {
        found = true;
    };
    try std.testing.expect(found);
}

test "tempo estimator handles distinct song pulses" {
    var envelope = [_]f32{0} ** 2_000;
    for ([_]u32{ 90, 147 }) |expected_bpm| {
        @memset(&envelope, 0);
        var pulse: usize = 0;
        var pulse_count: usize = 0;
        while (true) : (pulse += 1) {
            const index: usize = @intFromFloat(@round(@as(f32, @floatFromInt(pulse * 100 * 60)) / @as(f32, @floatFromInt(expected_bpm))));
            if (index >= envelope.len) break;
            envelope[index] = 1;
            pulse_count += 1;
        }
        const mean = @as(f32, @floatFromInt(pulse_count)) / @as(f32, @floatFromInt(envelope.len));
        const tempo = estimateTempo(&envelope, 100, mean);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected_bpm)), tempo.bpm, 1);
        try std.testing.expect(tempo.candidate_count >= 1);
    }
}
