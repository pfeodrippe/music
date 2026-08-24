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

pub const AttackLatency = struct {
    audible: bool = false,
    frame_index: usize = 0,
    milliseconds: f32 = 0,
    threshold: f32 = 0,
    peak: f32 = 0,
};

pub const spectral_band_centers_hz = [_]f32{ 128, 256, 512, 1024, 2048, 4096, 8192, 12_000 };

pub const SpectralFingerprint = struct {
    normalized_energy: [spectral_band_centers_hz.len]f32 = [_]f32{0} ** spectral_band_centers_hz.len,
    centroid_hz: f32 = 0,
    total_energy: f64 = 0,
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

/// Measure the first audible sample frame relative to the attack's own peak.
/// The absolute floor keeps digital silence and denormal noise from becoming a
/// fake zero-latency result, while the relative threshold remains useful for
/// quiet and loud velocity layers alike.
pub fn attackLatency(samples: []const f32, channels: usize, sample_rate: u32, relative_db: f32, absolute_floor: f32) AttackLatency {
    if (channels == 0 or sample_rate == 0 or samples.len < channels) return .{};
    const frame_count = samples.len / channels;
    var peak: f32 = 0;
    for (0..frame_count) |frame| {
        for (samples[frame * channels ..][0..channels]) |sample| {
            if (std.math.isFinite(sample)) peak = @max(peak, @abs(sample));
        }
    }
    const relative_gain = std.math.pow(f32, 10, @min(0, relative_db) / 20);
    const threshold = @max(@max(0, absolute_floor), peak * relative_gain);
    if (!(peak > threshold)) return .{ .threshold = threshold, .peak = peak };
    for (0..frame_count) |frame| {
        var frame_peak: f32 = 0;
        for (samples[frame * channels ..][0..channels]) |sample| {
            if (std.math.isFinite(sample)) frame_peak = @max(frame_peak, @abs(sample));
        }
        if (frame_peak < threshold) continue;
        return .{
            .audible = true,
            .frame_index = frame,
            .milliseconds = @as(f32, @floatFromInt(frame)) * 1000 / @as(f32, @floatFromInt(sample_rate)),
            .threshold = threshold,
            .peak = peak,
        };
    }
    return .{ .threshold = threshold, .peak = peak };
}

/// A compact, backend-neutral attack spectrum. The verifier does not claim
/// that eight probe bands replace listening or a full FFT; they provide a
/// stable numeric fingerprint that catches gross brightness/body regressions
/// between otherwise identical sampler renders.
pub fn spectralFingerprint(samples: []const f32, channels: usize, sample_rate: u32) SpectralFingerprint {
    if (channels == 0 or sample_rate == 0 or samples.len < channels) return .{};
    const frame_count = @min(samples.len / channels, 8192);
    if (frame_count < 2) return .{};
    var result: SpectralFingerprint = .{};
    var raw_energy: [spectral_band_centers_hz.len]f64 = [_]f64{0} ** spectral_band_centers_hz.len;
    const denominator: f64 = @floatFromInt(frame_count - 1);
    for (spectral_band_centers_hz, 0..) |frequency, band| {
        if (frequency >= @as(f32, @floatFromInt(sample_rate)) * 0.5) continue;
        const phase_step = 2.0 * std.math.pi * @as(f64, frequency) / @as(f64, @floatFromInt(sample_rate));
        var real: f64 = 0;
        var imaginary: f64 = 0;
        for (0..frame_count) |frame| {
            var mono: f64 = 0;
            for (samples[frame * channels ..][0..channels]) |sample| {
                if (std.math.isFinite(sample)) mono += sample;
            }
            mono /= @as(f64, @floatFromInt(channels));
            const position: f64 = @floatFromInt(frame);
            const window = 0.5 - 0.5 * @cos(2.0 * std.math.pi * position / denominator);
            const phase = phase_step * position;
            real += mono * window * @cos(phase);
            imaginary -= mono * window * @sin(phase);
        }
        raw_energy[band] = real * real + imaginary * imaginary;
        result.total_energy += raw_energy[band];
    }
    if (!(result.total_energy > 0) or !std.math.isFinite(result.total_energy)) return result;
    var centroid: f64 = 0;
    for (spectral_band_centers_hz, raw_energy, 0..) |frequency, energy, band| {
        result.normalized_energy[band] = @floatCast(energy / result.total_energy);
        centroid += @as(f64, frequency) * energy;
    }
    result.centroid_hz = @floatCast(centroid / result.total_energy);
    return result;
}

pub fn spectralDistance(left: SpectralFingerprint, right: SpectralFingerprint) f32 {
    var distance: f32 = 0;
    for (left.normalized_energy, right.normalized_energy) |a, b| distance += @abs(a - b);
    return distance * 0.5;
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

test "attack latency uses frame peaks across channels" {
    const samples = [_]f32{ 0, 0, 0, 0, 0.1, -0.2, 0.4, -0.1 };
    const latency = attackLatency(&samples, 2, 1000, -40, 0.001);
    try std.testing.expect(latency.audible);
    try std.testing.expectEqual(@as(usize, 2), latency.frame_index);
    try std.testing.expectApproxEqAbs(@as(f32, 2), latency.milliseconds, 0.0001);
}

test "spectral fingerprint identifies a dominant probe band" {
    const sample_rate: u32 = 8192;
    var samples: [4096]f32 = undefined;
    for (&samples, 0..) |*sample, frame| {
        const phase = 2.0 * std.math.pi * 256.0 * @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(sample_rate));
        sample.* = @floatCast(@sin(phase));
    }
    const fingerprint = spectralFingerprint(&samples, 1, sample_rate);
    try std.testing.expect(fingerprint.total_energy > 0);
    try std.testing.expect(fingerprint.normalized_energy[1] > 0.99);
    try std.testing.expectApproxEqAbs(@as(f32, 256), fingerprint.centroid_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), spectralDistance(fingerprint, fingerprint), 0.000001);
}
