const std = @import("std");

pub const Stats = struct {
    sample_count: usize,
    peak: f32,
    rms: f32,
    dc: f32,
    non_finite_samples: usize,
    clipped_samples: usize,

    pub fn peakDbfs(self: Stats) f32 {
        return amplitudeDbfs(self.peak);
    }

    pub fn rmsDbfs(self: Stats) f32 {
        return amplitudeDbfs(self.rms);
    }
};

/// Backend-neutral render statistics used by offline sampler acceptance tests.
/// Values are measured before PCM encoding so NaN/Inf and overload failures
/// cannot disappear behind integer conversion.
pub fn analyze(samples: []const f32) Stats {
    if (samples.len == 0) return .{
        .sample_count = 0,
        .peak = 0,
        .rms = 0,
        .dc = 0,
        .non_finite_samples = 0,
        .clipped_samples = 0,
    };
    var peak: f32 = 0;
    var sum: f64 = 0;
    var sum_squares: f64 = 0;
    var finite_count: usize = 0;
    var non_finite: usize = 0;
    var clipped: usize = 0;
    for (samples) |sample| {
        if (!std.math.isFinite(sample)) {
            non_finite += 1;
            continue;
        }
        const magnitude = @abs(sample);
        peak = @max(peak, magnitude);
        if (magnitude >= 0.999) clipped += 1;
        sum += sample;
        sum_squares += @as(f64, sample) * sample;
        finite_count += 1;
    }
    if (finite_count == 0) return .{
        .sample_count = samples.len,
        .peak = 0,
        .rms = 0,
        .dc = 0,
        .non_finite_samples = non_finite,
        .clipped_samples = clipped,
    };
    const count: f64 = @floatFromInt(finite_count);
    return .{
        .sample_count = samples.len,
        .peak = peak,
        .rms = @floatCast(@sqrt(sum_squares / count)),
        .dc = @floatCast(sum / count),
        .non_finite_samples = non_finite,
        .clipped_samples = clipped,
    };
}

pub fn amplitudeDbfs(amplitude: f32) f32 {
    if (!(amplitude > 0) or !std.math.isFinite(amplitude)) return -std.math.inf(f32);
    return 20 * @log10(amplitude);
}

pub fn ratioDb(numerator: f32, denominator: f32) f32 {
    if (!(numerator > 0) or std.math.isNan(numerator)) return -std.math.inf(f32);
    // A measurable signal compared with exact digital silence is an infinite
    // positive reduction. Returning -inf here inverted successful decay gates
    // for instruments whose release reaches zero inside the probe window.
    if (denominator == 0) return std.math.inf(f32);
    if (!(denominator > 0) or std.math.isNan(denominator)) return -std.math.inf(f32);
    return 20 * @log10(numerator / denominator);
}

test "render statistics expose level DC clipping and invalid samples" {
    const stats = analyze(&.{ -1, -0.5, 0.5, 1, std.math.nan(f32) });
    try std.testing.expectEqual(@as(usize, 5), stats.sample_count);
    try std.testing.expectEqual(@as(usize, 1), stats.non_finite_samples);
    try std.testing.expectEqual(@as(usize, 2), stats.clipped_samples);
    try std.testing.expectApproxEqAbs(@as(f32, 1), stats.peak, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), stats.dc, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.790569), stats.rms, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0206), ratioDb(1, 0.5), 0.001);
    try std.testing.expect(std.math.isPositiveInf(ratioDb(1, 0)));
}
