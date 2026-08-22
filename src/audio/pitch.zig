const std = @import("std");

pub const Detection = struct {
    frequency_hz: f32,
    midi_note: u8,
    confidence: f32,
    rms: f32,
};

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
