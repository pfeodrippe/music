const std = @import("std");

pub const max_phrase_attacks = 24;
pub const max_chord_tones = 5;

pub const Attack = struct {
    beat: f32,
    pitch: u8,
};

fn isBlackKey(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn fingerKeyCost(pitch: u8, finger: u8) f32 {
    if (!isBlackKey(pitch)) return 0;
    return switch (finger) {
        1 => 1.35,
        5 => 0.55,
        2, 3, 4 => 0,
        else => unreachable,
    };
}

fn startCost(attack: Attack, finger: u8) f32 {
    const center_distance: f32 = @floatFromInt(@abs(@as(i8, @intCast(finger)) - 3));
    return fingerKeyCost(attack.pitch, finger) + center_distance * 0.06;
}

fn reachableSemitones(finger_distance: u8) u8 {
    return switch (finger_distance) {
        0 => 2,
        1 => 4,
        2 => 7,
        3 => 10,
        else => 14,
    };
}

fn isThumbCross(oriented_delta: i16, from: u8, to: u8) bool {
    if (oriented_delta > 0) return from >= 3 and to == 1;
    return from == 1 and to >= 3;
}

fn transitionCost(previous: Attack, next: Attack, from: u8, to: u8, left: bool) f32 {
    const gap = next.beat - previous.beat;
    if (gap > 3.0) return 0.12 + startCost(next, to);

    const raw_delta = @as(i16, next.pitch) - @as(i16, previous.pitch);
    if (raw_delta == 0) {
        if (from == to) return fingerKeyCost(next.pitch, to) * 0.25;
        const finger_distance: f32 = @floatFromInt(@abs(@as(i8, @intCast(to)) - @as(i8, @intCast(from))));
        return 0.9 + finger_distance * 0.22 + fingerKeyCost(next.pitch, to);
    }

    const oriented_delta: i16 = if (left) -raw_delta else raw_delta;
    const finger_delta = @as(i8, @intCast(to)) - @as(i8, @intCast(from));
    const semitones: u8 = @intCast(@abs(raw_delta));
    const finger_distance: u8 = @intCast(@abs(finger_delta));
    var cost: f32 = fingerKeyCost(next.pitch, to);

    if ((oriented_delta > 0 and finger_delta > 0) or (oriented_delta < 0 and finger_delta < 0)) {
        const desired: u8 = std.math.clamp((semitones + 1) / 2, 1, 4);
        cost += @as(f32, @floatFromInt(@abs(@as(i8, @intCast(finger_distance)) - @as(i8, @intCast(desired))))) * 0.42;
    } else if (isThumbCross(oriented_delta, from, to) and semitones <= 5) {
        // Thumb-under / finger-over is useful for extending a scalar phrase,
        // but should lose to an ordinary in-position transition when both fit.
        cost += 0.48 + @as(f32, @floatFromInt(@abs(@as(i8, @intCast(semitones)) - 2))) * 0.14;
        const crossing_finger = if (oriented_delta > 0) from else to;
        if (crossing_finger > 3) cost += @as(f32, @floatFromInt(crossing_finger - 3)) * 0.65;
    } else if (finger_delta == 0) {
        cost += 2.8 + @as(f32, @floatFromInt(semitones)) * 0.22;
    } else {
        cost += 5.2 + @as(f32, @floatFromInt(semitones)) * 0.18;
    }

    const reach = reachableSemitones(finger_distance);
    if (semitones > reach) cost += @as(f32, @floatFromInt(semitones - reach)) * 0.85;
    if (semitones >= 8 and from != 1 and from != 5 and to != 1 and to != 5) cost += 1.8;
    return cost;
}

/// Choose one finger (1 thumb ... 5 little finger) for each attack in a
/// monophonic hand guide. The caller supplies a short phrase window; no heap
/// allocation is performed, so this is safe to evaluate while composing the
/// per-frame GPU packet.
pub fn optimize(attacks: []const Attack, left: bool, fingers: []u8) void {
    std.debug.assert(attacks.len <= max_phrase_attacks);
    std.debug.assert(fingers.len >= attacks.len);
    if (attacks.len == 0) return;

    var costs: [max_phrase_attacks][5]f32 = undefined;
    var previous_finger: [max_phrase_attacks][5]u8 = undefined;
    const raw_phrase_delta = @as(i16, attacks[attacks.len - 1].pitch) - @as(i16, attacks[0].pitch);
    const phrase_delta: i16 = if (left) -raw_phrase_delta else raw_phrase_delta;
    for (0..5) |finger_index| {
        const finger: u8 = @intCast(finger_index + 1);
        const boundary_bias: f32 = if (phrase_delta > 0)
            @as(f32, @floatFromInt(finger - 1)) * 0.12
        else if (phrase_delta < 0)
            @as(f32, @floatFromInt(5 - finger)) * 0.12
        else
            0;
        costs[0][finger_index] = startCost(attacks[0], finger) + boundary_bias;
        previous_finger[0][finger_index] = finger;
    }

    for (1..attacks.len) |attack_index| {
        for (0..5) |to_index| {
            const to: u8 = @intCast(to_index + 1);
            var best_cost = std.math.inf(f32);
            var best_from: u8 = 1;
            for (0..5) |from_index| {
                const from: u8 = @intCast(from_index + 1);
                const candidate = costs[attack_index - 1][from_index] + transitionCost(attacks[attack_index - 1], attacks[attack_index], from, to, left);
                if (candidate < best_cost) {
                    best_cost = candidate;
                    best_from = from;
                }
            }
            costs[attack_index][to_index] = best_cost;
            previous_finger[attack_index][to_index] = best_from;
        }
    }

    const first_end_bias: f32 = if (phrase_delta > 0) 0.48 else 0;
    var final_finger: u8 = 1;
    var final_cost = costs[attacks.len - 1][0] + first_end_bias;
    for (1..5) |finger_index| {
        const candidate_finger: u8 = @intCast(finger_index + 1);
        const boundary_bias: f32 = if (phrase_delta > 0)
            @as(f32, @floatFromInt(5 - candidate_finger)) * 0.12
        else if (phrase_delta < 0)
            @as(f32, @floatFromInt(candidate_finger - 1)) * 0.12
        else
            0;
        const candidate_cost = costs[attacks.len - 1][finger_index] + boundary_bias;
        if (candidate_cost < final_cost) {
            final_cost = candidate_cost;
            final_finger = @intCast(finger_index + 1);
        }
    }
    var attack_index = attacks.len;
    var finger = final_finger;
    while (attack_index > 0) {
        attack_index -= 1;
        fingers[attack_index] = finger;
        finger = previous_finger[attack_index][finger - 1];
    }
}

fn chordAssignmentCost(pitches: []const u8, candidate: []const u8, left: bool, anchor_pitch: u8, anchor_finger: u8) f32 {
    var cost: f32 = 0;
    for (pitches, candidate) |pitch, finger| {
        // Simultaneous voicings offer more alternatives than a melodic line;
        // give black-key thumb avoidance enough weight to beat a merely
        // convenient phrase anchor when another distinct-finger shape fits.
        cost += fingerKeyCost(pitch, finger) * 1.5;
        if (pitch == anchor_pitch and anchor_finger >= 1 and anchor_finger <= 5) {
            cost += @as(f32, @floatFromInt(@abs(@as(i8, @intCast(finger)) - @as(i8, @intCast(anchor_finger))))) * 0.72;
        }
    }
    for (1..pitches.len) |index| {
        const semitones: u8 = pitches[index] - pitches[index - 1];
        const finger_distance: u8 = @intCast(@abs(@as(i8, @intCast(candidate[index])) - @as(i8, @intCast(candidate[index - 1]))));
        const desired: u8 = std.math.clamp((semitones + 1) / 2, 1, 4);
        cost += @as(f32, @floatFromInt(@abs(@as(i8, @intCast(finger_distance)) - @as(i8, @intCast(desired))))) * 0.34;
        const reach = reachableSemitones(finger_distance);
        if (semitones > reach) cost += @as(f32, @floatFromInt(semitones - reach)) * 1.1;
    }

    const span = pitches[pitches.len - 1] - pitches[0];
    if (span >= 7) {
        const low_boundary: u8 = if (left) 5 else 1;
        const high_boundary: u8 = if (left) 1 else 5;
        cost += @as(f32, @floatFromInt(@abs(@as(i8, @intCast(candidate[0])) - @as(i8, @intCast(low_boundary))))) * 0.68;
        cost += @as(f32, @floatFromInt(@abs(@as(i8, @intCast(candidate[candidate.len - 1])) - @as(i8, @intCast(high_boundary))))) * 0.68;
    }
    return cost;
}

/// Assign distinct fingers to a sorted, unique simultaneous hand chord. The
/// phrase optimizer supplies an anchor for continuity into and out of the
/// chord; all possible five-finger combinations are cheap enough to enumerate
/// without allocation. More than five distinct pitches is not a playable
/// single-hand chord and must be redistributed by the caller.
pub fn optimizeChord(pitches: []const u8, left: bool, anchor_pitch: u8, anchor_finger: u8, fingers: []u8) void {
    std.debug.assert(pitches.len > 0 and pitches.len <= max_chord_tones);
    std.debug.assert(fingers.len >= pitches.len);
    for (1..pitches.len) |index| std.debug.assert(pitches[index - 1] < pitches[index]);
    if (pitches.len == 1) {
        fingers[0] = if (anchor_finger >= 1 and anchor_finger <= 5) anchor_finger else 3;
        return;
    }

    var best: [max_chord_tones]u8 = undefined;
    var best_cost = std.math.inf(f32);
    var mask: u8 = 1;
    while (mask < 32) : (mask += 1) {
        if (@as(usize, @popCount(mask)) != pitches.len) continue;
        var ascending: [max_chord_tones]u8 = undefined;
        var count: usize = 0;
        for (1..6) |finger_value| {
            const finger: u8 = @intCast(finger_value);
            if ((mask & (@as(u8, 1) << @intCast(finger - 1))) == 0) continue;
            ascending[count] = finger;
            count += 1;
        }
        var candidate: [max_chord_tones]u8 = undefined;
        for (0..pitches.len) |index| candidate[index] = if (left) ascending[pitches.len - 1 - index] else ascending[index];
        const cost = chordAssignmentCost(pitches, candidate[0..pitches.len], left, anchor_pitch, anchor_finger);
        if (cost < best_cost) {
            best_cost = cost;
            @memcpy(best[0..pitches.len], candidate[0..pitches.len]);
        }
    }
    @memcpy(fingers[0..pitches.len], best[0..pitches.len]);
}

test "right and left five-note positions mirror each other" {
    const attacks = [_]Attack{
        .{ .beat = 0, .pitch = 60 },
        .{ .beat = 1, .pitch = 62 },
        .{ .beat = 2, .pitch = 64 },
        .{ .beat = 3, .pitch = 65 },
        .{ .beat = 4, .pitch = 67 },
    };
    var right: [attacks.len]u8 = undefined;
    var left: [attacks.len]u8 = undefined;
    optimize(&attacks, false, &right);
    optimize(&attacks, true, &left);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, &right);
    try std.testing.expectEqualSlices(u8, &.{ 5, 4, 3, 2, 1 }, &left);
}

test "scale continuation uses a thumb crossing" {
    const attacks = [_]Attack{
        .{ .beat = 0, .pitch = 60 },
        .{ .beat = 0.5, .pitch = 62 },
        .{ .beat = 1, .pitch = 64 },
        .{ .beat = 1.5, .pitch = 65 },
        .{ .beat = 2, .pitch = 67 },
        .{ .beat = 2.5, .pitch = 69 },
        .{ .beat = 3, .pitch = 71 },
        .{ .beat = 3.5, .pitch = 72 },
    };
    var fingers: [attacks.len]u8 = undefined;
    optimize(&attacks, false, &fingers);
    var crossed = false;
    for (1..fingers.len) |index| {
        if (fingers[index - 1] >= 3 and fingers[index] == 1) crossed = true;
    }
    try std.testing.expect(crossed);
    try std.testing.expectEqual(@as(u8, 5), fingers[fingers.len - 1]);
}

test "repeated notes keep a stable finger" {
    const attacks = [_]Attack{
        .{ .beat = 0, .pitch = 60 },
        .{ .beat = 0.5, .pitch = 60 },
        .{ .beat = 1, .pitch = 60 },
    };
    var fingers: [attacks.len]u8 = undefined;
    optimize(&attacks, false, &fingers);
    try std.testing.expectEqual(fingers[0], fingers[1]);
    try std.testing.expectEqual(fingers[1], fingers[2]);
}

test "octave leaps use the outside fingers" {
    const attacks = [_]Attack{
        .{ .beat = 0, .pitch = 60 },
        .{ .beat = 1, .pitch = 72 },
    };
    var right: [attacks.len]u8 = undefined;
    var left: [attacks.len]u8 = undefined;
    optimize(&attacks, false, &right);
    optimize(&attacks, true, &left);
    try std.testing.expectEqualSlices(u8, &.{ 1, 5 }, &right);
    try std.testing.expectEqualSlices(u8, &.{ 5, 1 }, &left);
}

test "black keys avoid the thumb when a central finger fits" {
    const attacks = [_]Attack{
        .{ .beat = 0, .pitch = 61 },
        .{ .beat = 1, .pitch = 63 },
        .{ .beat = 2, .pitch = 66 },
    };
    var fingers: [attacks.len]u8 = undefined;
    optimize(&attacks, false, &fingers);
    for (fingers) |finger| try std.testing.expect(finger != 1);
}

test "major triads use complete mirrored chord fingering" {
    const pitches = [_]u8{ 60, 64, 67 };
    var right: [pitches.len]u8 = undefined;
    var left: [pitches.len]u8 = undefined;
    optimizeChord(&pitches, false, 60, 1, &right);
    optimizeChord(&pitches, true, 60, 5, &left);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 5 }, &right);
    try std.testing.expectEqualSlices(u8, &.{ 5, 3, 1 }, &left);
}

test "black-key triad avoids a thumb where a playable alternative exists" {
    const pitches = [_]u8{ 61, 65, 68 };
    var right: [pitches.len]u8 = undefined;
    optimizeChord(&pitches, false, 61, 1, &right);
    try std.testing.expect(right[0] != 1);
    for (1..right.len) |index| try std.testing.expect(right[index - 1] < right[index]);
}

test "single chord tone preserves phrase anchor" {
    const pitches = [_]u8{61};
    var fingers: [1]u8 = undefined;
    optimizeChord(&pitches, false, 61, 4, &fingers);
    try std.testing.expectEqual(@as(u8, 4), fingers[0]);
}
