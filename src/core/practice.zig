const std = @import("std");

pub const Rating = enum(u8) {
    perfect,
    correct,
    early,
    late,
    wrong_pitch,
};

pub const Result = struct {
    rating: Rating,
    pitch_delta: i8,
    timing_delta_ms: f32,
    confidence: f32,
};

pub fn assess(expected_pitch: u8, expected_time_ms: f64, played_pitch: u8, played_time_ms: f64, confidence: f32) Result {
    const pitch_delta_wide = @as(i16, played_pitch) - @as(i16, expected_pitch);
    const pitch_delta: i8 = @intCast(std.math.clamp(pitch_delta_wide, -127, 127));
    const timing: f32 = @floatCast(played_time_ms - expected_time_ms);
    const rating: Rating = if (pitch_delta != 0)
        .wrong_pitch
    else if (@abs(timing) <= 45)
        .perfect
    else if (@abs(timing) <= 105)
        .correct
    else if (timing < 0)
        .early
    else
        .late;
    return .{
        .rating = rating,
        .pitch_delta = pitch_delta,
        .timing_delta_ms = timing,
        .confidence = std.math.clamp(confidence, 0, 1),
    };
}

test "practice assessment separates pitch and timing" {
    try std.testing.expectEqual(Rating.perfect, assess(60, 1000, 60, 1028, 0.9).rating);
    try std.testing.expectEqual(Rating.early, assess(60, 1000, 60, 850, 0.9).rating);
    try std.testing.expectEqual(Rating.late, assess(60, 1000, 60, 1150, 0.9).rating);
    try std.testing.expectEqual(Rating.wrong_pitch, assess(60, 1000, 61, 1000, 0.9).rating);
}
