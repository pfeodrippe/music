const std = @import("std");

/// Allocation-free stereo DC blocker for post-instrument buses. The cutoff is
/// deliberately sub-audible: it protects the master stage from offset without
/// thinning the piano's low register.
pub const StereoDcBlocker = struct {
    coefficient: f32 = 0,
    previous_input: [2]f32 = .{ 0, 0 },
    previous_output: [2]f32 = .{ 0, 0 },

    pub fn init(sample_rate: f32, cutoff_hz: f32) StereoDcBlocker {
        const rate = @max(1, sample_rate);
        const cutoff = std.math.clamp(cutoff_hz, 0, rate * 0.45);
        return .{ .coefficient = @exp(-2 * std.math.pi * cutoff / rate) };
    }

    pub fn reset(self: *StereoDcBlocker) void {
        self.previous_input = .{ 0, 0 };
        self.previous_output = .{ 0, 0 };
    }

    pub fn process(self: *StereoDcBlocker, left: []f32, right: []f32) void {
        std.debug.assert(left.len == right.len);
        for (left, right) |*left_sample, *right_sample| {
            const input = [2]f32{ finiteOrZero(left_sample.*), finiteOrZero(right_sample.*) };
            const output = [2]f32{
                input[0] - self.previous_input[0] + self.coefficient * self.previous_output[0],
                input[1] - self.previous_input[1] + self.coefficient * self.previous_output[1],
            };
            self.previous_input = input;
            self.previous_output = output;
            left_sample.* = output[0];
            right_sample.* = output[1];
        }
    }
};

pub const LimiterStats = struct {
    limited_frames: usize = 0,
    non_finite_samples: usize = 0,
    minimum_gain: f32 = 1,
};

/// Stereo-linked, zero-allocation safety limiter. Gain reduction attacks on
/// the current sample and releases smoothly, so it bounds accidental summing
/// peaks without hard-clipping or changing ordinary piano dynamics.
pub const StereoSafetyLimiter = struct {
    ceiling: f32 = 0.98,
    release_coefficient: f32 = 0,
    gain: f32 = 1,

    pub fn init(sample_rate: f32, ceiling: f32, release_ms: f32) StereoSafetyLimiter {
        const rate = @max(1, sample_rate);
        const release_seconds = @max(0.001, release_ms / 1000);
        return .{
            .ceiling = std.math.clamp(ceiling, 0.1, 0.999),
            .release_coefficient = @exp(-1 / (release_seconds * rate)),
        };
    }

    pub fn reset(self: *StereoSafetyLimiter) void {
        self.gain = 1;
    }

    pub fn process(self: *StereoSafetyLimiter, left: []f32, right: []f32) LimiterStats {
        std.debug.assert(left.len == right.len);
        var stats: LimiterStats = .{};
        for (left, right) |*left_sample, *right_sample| {
            var l = left_sample.*;
            var r = right_sample.*;
            if (!std.math.isFinite(l)) {
                l = 0;
                stats.non_finite_samples += 1;
            }
            if (!std.math.isFinite(r)) {
                r = 0;
                stats.non_finite_samples += 1;
            }

            const peak = @max(@abs(l), @abs(r));
            const target = if (peak > self.ceiling) self.ceiling / peak else @as(f32, 1);
            if (target < self.gain) {
                self.gain = target;
            } else {
                self.gain = target + self.release_coefficient * (self.gain - target);
            }
            if (self.gain < 0.99999) stats.limited_frames += 1;
            stats.minimum_gain = @min(stats.minimum_gain, self.gain);
            left_sample.* = l * self.gain;
            right_sample.* = r * self.gain;
        }
        return stats;
    }
};

/// Shared post-instrument and master stages. Instrument buses receive only the
/// transparent DC blocker; dry UI/metronome signals join afterward and the
/// stereo-linked master limiter protects the final sum.
pub const StereoOutputChain = struct {
    post_instrument: StereoDcBlocker,
    master: StereoSafetyLimiter,

    pub fn init(sample_rate: f32) StereoOutputChain {
        return .{
            .post_instrument = .init(sample_rate, 15),
            .master = .init(sample_rate, 0.98, 120),
        };
    }

    pub fn reset(self: *StereoOutputChain) void {
        self.post_instrument.reset();
        self.master.reset();
    }
};

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

test "DC blocker rejects offset without allocating or producing invalid samples" {
    var blocker = StereoDcBlocker.init(48_000, 15);
    var left = [_]f32{1} ** 48_000;
    var right = [_]f32{-1} ** 48_000;
    blocker.process(&left, &right);
    try std.testing.expect(@abs(left[left.len - 1]) < 0.0001);
    try std.testing.expect(@abs(right[right.len - 1]) < 0.0001);
    try std.testing.expect(std.math.isFinite(left[12_345]));
}

test "stereo limiter is linked bounded and preserves normal dynamics" {
    var limiter = StereoSafetyLimiter.init(48_000, 0.98, 120);
    var left = [_]f32{ 0.25, 2.0, 0.5 };
    var right = [_]f32{ -0.5, 1.0, -0.25 };
    const stats = limiter.process(&left, &right);
    try std.testing.expectEqual(@as(f32, 0.25), left[0]);
    try std.testing.expectEqual(@as(f32, -0.5), right[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.98), left[1], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.49), right[1], 0.000001);
    try std.testing.expect(stats.limited_frames >= 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.49), stats.minimum_gain, 0.000001);
    for (left, right) |l, r| {
        try std.testing.expect(@abs(l) <= 0.98);
        try std.testing.expect(@abs(r) <= 0.98);
    }
}

test "effects state is invariant to render block boundaries" {
    var whole_chain = StereoOutputChain.init(48_000);
    var split_chain = StereoOutputChain.init(48_000);
    var whole_left = [_]f32{ 0.1, 0.3, 1.4, -0.2, 0.6, 0.1 };
    var whole_right = [_]f32{ -0.2, 0.4, 0.7, -0.1, 0.3, -0.5 };
    var split_left = whole_left;
    var split_right = whole_right;

    whole_chain.post_instrument.process(&whole_left, &whole_right);
    _ = whole_chain.master.process(&whole_left, &whole_right);
    split_chain.post_instrument.process(split_left[0..2], split_right[0..2]);
    _ = split_chain.master.process(split_left[0..2], split_right[0..2]);
    split_chain.post_instrument.process(split_left[2..], split_right[2..]);
    _ = split_chain.master.process(split_left[2..], split_right[2..]);

    try std.testing.expectEqualSlices(f32, &whole_left, &split_left);
    try std.testing.expectEqualSlices(f32, &whole_right, &split_right);
}
