const std = @import("std");

pub const target_sample_rate: u32 = 8_000;
pub const feature_hz: u32 = 4;
pub const max_candidates: usize = 6;

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
    const duration = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(target_sample_rate));

    const onset_hop: usize = target_sample_rate / 100;
    const onset_window: usize = target_sample_rate / 50;
    const envelope_len = if (samples.len <= onset_window) 1 else (samples.len - onset_window) / onset_hop + 1;
    const envelope = try allocator.alloc(f32, envelope_len);
    defer allocator.free(envelope);
    var previous_energy: f32 = 0;
    var envelope_mean: f32 = 0;
    for (envelope, 0..) |*value, index| {
        const start = @min(index * onset_hop, samples.len -| 1);
        const end = @min(start + onset_window, samples.len);
        var energy: f32 = 0;
        var high_pass: f32 = 0;
        var previous: f32 = samples[start];
        for (samples[start..end]) |sample| {
            energy += sample * sample;
            const delta = sample - previous;
            high_pass += delta * delta;
            previous = sample;
        }
        energy = @log(1.0 + 500.0 * (energy + 0.35 * high_pass) / @as(f32, @floatFromInt(@max(1, end - start))));
        value.* = @max(0, energy - previous_energy);
        previous_energy = energy;
        envelope_mean += value.*;
    }
    envelope_mean /= @as(f32, @floatFromInt(envelope.len));
    var variance: f32 = 0;
    for (envelope) |value| variance += (value - envelope_mean) * (value - envelope_mean);
    const envelope_std = @sqrt(variance / @as(f32, @floatFromInt(envelope.len)));

    var onset_list: std.ArrayList(f32) = .empty;
    defer onset_list.deinit(allocator);
    var last_onset: f32 = -10;
    for (envelope, 0..) |value, index| {
        if (index == 0 or index + 1 == envelope.len) continue;
        const time = @as(f32, @floatFromInt(index * onset_hop)) / @as(f32, @floatFromInt(target_sample_rate));
        if (value > envelope_mean + 0.72 * envelope_std and value >= envelope[index - 1] and value > envelope[index + 1] and time - last_onset >= 0.065) {
            try onset_list.append(allocator, time);
            last_onset = time;
        }
    }
    const tempo = if (onset_list.items.len >= 4) estimateTempo(envelope, 100, envelope_mean) else Tempo{ .bpm = 0, .confidence = 0 };

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
        const envelope_index = @min(envelope.len - 1, center / onset_hop);
        frame.* = .{
            .time_seconds = @as(f32, @floatFromInt(center)) / @as(f32, @floatFromInt(target_sample_rate)),
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

const Tempo = struct { bpm: f32, confidence: f32 };

fn estimateTempo(envelope: []const f32, envelope_rate: u32, mean: f32) Tempo {
    var best_bpm: u32 = 60;
    var best_score: f32 = 0;
    var total_score: f32 = 0;
    for (45..181) |bpm| {
        const lag = @max(1, envelope_rate * 60 / bpm);
        if (lag >= envelope.len) continue;
        var score: f32 = 0;
        for (lag..envelope.len) |index| score += @max(0, envelope[index] - mean) * @max(0, envelope[index - lag] - mean);
        total_score += score;
        if (score > best_score) {
            best_score = score;
            best_bpm = @intCast(bpm);
        }
    }
    return .{ .bpm = @floatFromInt(best_bpm), .confidence = if (total_score > 0) std.math.clamp(best_score * 136.0 / total_score, 0, 1) else 0 };
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
