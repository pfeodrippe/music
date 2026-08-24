const std = @import("std");

pub const Detection = struct {
    frequency_hz: f32,
    midi_note: u8,
    confidence: f32,
    rms: f32,
};

pub const max_polyphonic_pitches: usize = 8;

pub const PolyphonicDetection = struct {
    detections: [max_polyphonic_pitches]Detection = [_]Detection{.{
        .frequency_hz = 0,
        .midi_note = 0,
        .confidence = 0,
        .rms = 0,
    }} ** max_polyphonic_pitches,
    len: usize = 0,
    rms: f32 = 0,
};

pub const AttackTracker = struct {
    active_pitch_mask: [2]u64 = [_]u64{0} ** 2,
    missing_windows: [128]u8 = [_]u8{0} ** 128,

    /// Return only newly attacked pitches. A pitch must be absent for two
    /// complete analysis windows before it may attack again, so a sustained
    /// piano tone cannot be scored repeatedly as an extra note.
    pub fn update(self: *AttackTracker, detected: PolyphonicDetection, output: []Detection) usize {
        var observed_mask = [_]u64{0} ** 2;
        var output_len: usize = 0;
        for (detected.detections[0..detected.len]) |candidate| {
            if (candidate.confidence < 0.72) continue;
            const word = candidate.midi_note / 64;
            const bit = @as(u64, 1) << @intCast(candidate.midi_note % 64);
            observed_mask[word] |= bit;
            self.missing_windows[candidate.midi_note] = 0;
            if ((self.active_pitch_mask[word] & bit) == 0 and output_len < output.len) {
                output[output_len] = candidate;
                output_len += 1;
            }
            self.active_pitch_mask[word] |= bit;
        }
        for (0..128) |pitch| {
            const word = pitch / 64;
            const bit = @as(u64, 1) << @intCast(pitch % 64);
            if ((self.active_pitch_mask[word] & bit) == 0 or (observed_mask[word] & bit) != 0) continue;
            self.missing_windows[pitch] +|= 1;
            if (self.missing_windows[pitch] >= 2) {
                self.active_pitch_mask[word] &= ~bit;
                self.missing_windows[pitch] = 0;
            }
        }
        return output_len;
    }
};

const piano_low_midi: u8 = 21;
const piano_high_midi: u8 = 108;
const analysis_window: usize = 4096;

/// Bounded, allocation-free multi-pitch analysis for live piano practice.
///
/// Each piano key is evaluated at its exact equal-tempered frequency with a
/// Hann-windowed Goertzel kernel. A second harmonic reinforces a candidate
/// only when its fundamental is already present, preventing the classic false
/// sub-octave produced by adding harmonic energy on its own. Local spectral
/// peaks are retained in energy order. This is deliberately an observation
/// aid: the caller still applies onset/release hysteresis and a confidence
/// threshold before turning a candidate into practice feedback.
pub fn detectPolyphonic(samples: []const f32, sample_rate: f32) PolyphonicDetection {
    var result: PolyphonicDetection = .{};
    if (samples.len < 512 or sample_rate <= 0) return result;
    const source = samples[samples.len - @min(samples.len, analysis_window) ..];

    var mean: f64 = 0;
    for (source) |sample| mean += sample;
    mean /= @floatFromInt(source.len);
    var energy: f64 = 0;
    var windowed: [analysis_window]f32 = [_]f32{0} ** analysis_window;
    const denominator = @as(f32, @floatFromInt(source.len - 1));
    for (source, 0..) |sample, index| {
        const centered: f32 = @floatCast(@as(f64, sample) - mean);
        energy += @as(f64, centered) * centered;
        const phase = @as(f32, @floatFromInt(index)) / denominator;
        windowed[index] = centered * (0.5 - 0.5 * @cos(std.math.tau * phase));
    }
    result.rms = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(source.len))));
    if (result.rms < 0.008) return result;

    const key_count = piano_high_midi - piano_low_midi + 1;
    var salience = [_]f32{0} ** key_count;
    var maximum: f32 = 0;
    for (&salience, 0..) |*value, offset| {
        const pitch: u8 = @intCast(offset + piano_low_midi);
        const frequency = midiFrequency(pitch);
        if (frequency >= sample_rate * 0.48) continue;
        const fundamental = goertzelPower(windowed[0..source.len], frequency, sample_rate);
        value.* = fundamental;
        if (frequency * 2 < sample_rate * 0.48) {
            const second = goertzelPower(windowed[0..source.len], frequency * 2, sample_rate);
            value.* += 0.18 * @sqrt(fundamental * second);
        }
        maximum = @max(maximum, value.*);
    }
    if (maximum <= 0.0000001) return result;

    var selected_salience = [_]f32{0} ** max_polyphonic_pitches;
    for (salience, 0..) |value, offset| {
        if (value < maximum * 0.075) continue;
        if (offset > 0 and value < salience[offset - 1]) continue;
        if (offset + 1 < salience.len and value <= salience[offset + 1]) continue;
        const amplitude = @sqrt(value);
        const confidence = std.math.clamp(amplitude / (result.rms * 0.25), 0, 1);
        if (confidence < 0.55) continue;

        var insert: usize = 0;
        while (insert < max_polyphonic_pitches and selected_salience[insert] >= value) : (insert += 1) {}
        if (insert == max_polyphonic_pitches) continue;
        var move = max_polyphonic_pitches - 1;
        while (move > insert) : (move -= 1) {
            selected_salience[move] = selected_salience[move - 1];
            result.detections[move] = result.detections[move - 1];
        }
        const pitch: u8 = @intCast(offset + piano_low_midi);
        selected_salience[insert] = value;
        result.detections[insert] = .{
            .frequency_hz = midiFrequency(pitch),
            .midi_note = pitch,
            .confidence = confidence,
            .rms = result.rms,
        };
        result.len = @min(max_polyphonic_pitches, result.len + 1);
    }
    return result;
}

fn midiFrequency(pitch: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(pitch)) - 69.0) / 12.0);
}

fn goertzelPower(samples: []const f32, frequency: f32, sample_rate: f32) f32 {
    const omega = std.math.tau * frequency / sample_rate;
    const coefficient = 2.0 * @cos(omega);
    var first: f32 = 0;
    var second: f32 = 0;
    for (samples) |sample| {
        const current = sample + coefficient * first - second;
        second = first;
        first = current;
    }
    return @max(0, first * first + second * second - coefficient * first * second) / @as(f32, @floatFromInt(samples.len * samples.len));
}

/// Normalized autocorrelation pitch detector tuned for monophonic piano
/// practice. The confidence threshold is intentionally exposed to the caller;
/// low-confidence microphone observations must never be presented as mistakes.
pub fn detect(samples: []const f32, sample_rate: f32) ?Detection {
    if (samples.len < 256 or sample_rate <= 0) return null;
    var energy: f64 = 0;
    var mean: f64 = 0;
    for (samples) |sample| mean += sample;
    mean /= @floatFromInt(samples.len);
    for (samples) |sample| {
        const centered = @as(f64, sample) - mean;
        energy += centered * centered;
    }
    const rms: f32 = @floatCast(@sqrt(energy / @as(f64, @floatFromInt(samples.len))));
    if (rms < 0.008) return null;

    const min_lag: usize = @max(2, @as(usize, @intFromFloat(sample_rate / 1200.0)));
    const max_lag: usize = @min(samples.len / 2, @as(usize, @intFromFloat(sample_rate / 45.0)));
    var best_lag: usize = 0;
    var best_correlation: f64 = 0;
    var lag = min_lag;
    while (lag <= max_lag) : (lag += 1) {
        var cross: f64 = 0;
        var left_energy: f64 = 0;
        var right_energy: f64 = 0;
        var index: usize = 0;
        while (index + lag < samples.len) : (index += 2) {
            const left = @as(f64, samples[index]) - mean;
            const right = @as(f64, samples[index + lag]) - mean;
            cross += left * right;
            left_energy += left * left;
            right_energy += right * right;
        }
        const denominator = @sqrt(left_energy * right_energy);
        if (denominator <= 0) continue;
        const correlation = cross / denominator;
        if (correlation > best_correlation) {
            best_correlation = correlation;
            best_lag = lag;
        }
    }
    if (best_lag == 0 or best_correlation < 0.45) return null;
    const frequency = sample_rate / @as(f32, @floatFromInt(best_lag));
    const midi_float = 69.0 + 12.0 * std.math.log2(frequency / 440.0);
    if (midi_float < 0 or midi_float > 127) return null;
    return .{
        .frequency_hz = frequency,
        .midi_note = @intFromFloat(@round(midi_float)),
        .confidence = @floatCast(std.math.clamp(best_correlation, 0, 1)),
        .rms = rms,
    };
}

test "detects an A4 sine wave" {
    var samples: [2048]f32 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = 0.4 * @sin(@as(f32, @floatFromInt(index)) * 440.0 / 48_000.0 * std.math.tau);
    const result = detect(&samples, 48_000) orelse return error.ExpectedPitch;
    try std.testing.expectEqual(@as(u8, 69), result.midi_note);
    try std.testing.expect(result.confidence > 0.9);
}

test "silence is not reported as a mistake" {
    const samples = [_]f32{0} ** 1024;
    try std.testing.expect(detect(&samples, 48_000) == null);
}

test "polyphonic detector reports every synthetic A major chord tone" {
    var samples: [analysis_window]f32 = undefined;
    const pitches = [_]u8{ 57, 61, 64 };
    for (&samples, 0..) |*sample, index| {
        const time = @as(f32, @floatFromInt(index)) / 48_000.0;
        sample.* = 0;
        for (pitches) |pitch| sample.* += 0.18 * @sin(std.math.tau * midiFrequency(pitch) * time);
    }
    const result = detectPolyphonic(&samples, 48_000);
    try std.testing.expect(result.len >= pitches.len);
    for (pitches) |expected| {
        var found = false;
        for (result.detections[0..result.len]) |candidate| {
            if (candidate.midi_note == expected and candidate.confidence >= 0.72) found = true;
        }
        try std.testing.expect(found);
    }
}

test "polyphonic detector rejects silence and does not invent a sub-octave" {
    const silence = [_]f32{0} ** analysis_window;
    try std.testing.expectEqual(@as(usize, 0), detectPolyphonic(&silence, 48_000).len);

    var samples: [analysis_window]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        const time = @as(f32, @floatFromInt(index)) / 48_000.0;
        sample.* = 0.35 * @sin(std.math.tau * 440.0 * time);
    }
    const result = detectPolyphonic(&samples, 48_000);
    var found_a4 = false;
    var found_a3 = false;
    for (result.detections[0..result.len]) |candidate| {
        found_a4 = found_a4 or candidate.midi_note == 69;
        found_a3 = found_a3 or candidate.midi_note == 57;
    }
    try std.testing.expect(found_a4);
    try std.testing.expect(!found_a3);
}

test "polyphonic attack tracker suppresses sustain and rearms after release" {
    var chord: PolyphonicDetection = .{};
    chord.len = 3;
    for ([_]u8{ 57, 61, 64 }, 0..) |pitch, index| chord.detections[index] = .{
        .frequency_hz = midiFrequency(pitch),
        .midi_note = pitch,
        .confidence = 0.95,
        .rms = 0.2,
    };
    var tracker: AttackTracker = .{};
    var attacks: [max_polyphonic_pitches]Detection = undefined;
    try std.testing.expectEqual(@as(usize, 3), tracker.update(chord, &attacks));
    try std.testing.expectEqual(@as(usize, 0), tracker.update(chord, &attacks));
    try std.testing.expectEqual(@as(usize, 0), tracker.update(.{}, &attacks));
    try std.testing.expectEqual(@as(usize, 0), tracker.update(.{}, &attacks));
    try std.testing.expectEqual(@as(usize, 3), tracker.update(chord, &attacks));
}
