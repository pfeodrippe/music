const std = @import("std");

pub const max_samples = 4096;
pub const max_zones = 16_384;
pub const max_selected_layers = 16;

pub const Trigger = enum(u8) {
    attack,
    release,
    pedal_down,
    pedal_up,
};

pub const Storage = enum(u8) {
    preload,
    stream,
};

pub const SampleAsset = struct {
    content_hash: [32]u8,
    sample_rate: u32,
    frame_count: u64,
    channels: u8,
    storage: Storage,
};

/// Normalized zone shared by grand pianos, electric pianos, strings,
/// percussion, and user packs. Platform I/O resolves `sample_index`; the real-
/// time selector never owns paths, decoders, files, or allocations.
pub const Zone = struct {
    sample_index: u32,
    trigger: Trigger = .attack,
    key_low: u8 = 0,
    key_high: u8 = 127,
    velocity_low: u8 = 1,
    velocity_high: u8 = 127,
    velocity_fade_in: u8 = 0,
    velocity_fade_out: u8 = 0,
    pedal_low: u8 = 0,
    pedal_high: u8 = 127,
    soft_low: u8 = 0,
    soft_high: u8 = 127,
    root_key: u8 = 60,
    round_robin_group: u8 = 0,
    round_robin_index: u8 = 0,
    round_robin_count: u8 = 1,
    mic_bus: u8 = 0,
    tune_cents: i16 = 0,
    gain_db: f32 = 0,
    pan: f32 = 0,
};

pub const Manifest = struct {
    samples: []const SampleAsset,
    zones: []const Zone,

    pub fn validate(self: Manifest) !void {
        if (self.samples.len > max_samples or self.zones.len > max_zones) return error.ManifestTooLarge;
        for (self.samples) |sample| {
            if (sample.sample_rate < 4_000 or sample.sample_rate > 384_000) return error.InvalidSampleRate;
            if (sample.channels == 0 or sample.channels > 8 or sample.frame_count == 0) return error.InvalidSample;
        }
        for (self.zones) |zone| {
            if (zone.sample_index >= self.samples.len) return error.MissingSample;
            if (zone.key_low > zone.key_high or zone.velocity_low > zone.velocity_high or zone.pedal_low > zone.pedal_high or zone.soft_low > zone.soft_high) return error.InvalidRange;
            if (zone.root_key > 127 or zone.round_robin_count == 0 or zone.round_robin_index >= zone.round_robin_count or zone.round_robin_group >= 32) return error.InvalidRoundRobin;
            if (!std.math.isFinite(zone.gain_db) or !std.math.isFinite(zone.pan) or zone.pan < -1 or zone.pan > 1) return error.InvalidMix;
        }
    }
};

pub const Input = struct {
    key: u8,
    velocity: u8,
    sustain: u8 = 0,
    soft: u8 = 0,
};

pub const Layer = struct {
    zone_index: u32,
    weight: f32,
};

pub const Selection = struct {
    layers: [max_selected_layers]Layer = undefined,
    len: usize = 0,

    pub fn slice(self: *const Selection) []const Layer {
        return self.layers[0..self.len];
    }
};

pub const Selector = struct {
    round_robin: [32]u32 = [_]u32{0} ** 32,

    pub fn select(self: *Selector, manifest: Manifest, trigger: Trigger, input: Input) Selection {
        var result: Selection = .{};
        var used_groups = [_]bool{false} ** 32;
        for (manifest.zones, 0..) |zone, index| {
            if (zone.trigger != trigger or input.key < zone.key_low or input.key > zone.key_high or input.velocity < zone.velocity_low or input.velocity > zone.velocity_high or input.sustain < zone.pedal_low or input.sustain > zone.pedal_high or input.soft < zone.soft_low or input.soft > zone.soft_high) continue;
            const group = zone.round_robin_group;
            const wanted: u8 = @intCast(self.round_robin[group] % zone.round_robin_count);
            if (zone.round_robin_index != wanted) continue;
            if (result.len == result.layers.len) break;
            result.layers[result.len] = .{ .zone_index = @intCast(index), .weight = velocityWeight(zone, input.velocity) };
            result.len += 1;
            used_groups[group] = true;
        }
        for (used_groups, 0..) |used, group| if (used) {
            self.round_robin[group] +%= 1;
        };
        return result;
    }
};

fn velocityWeight(zone: Zone, velocity: u8) f32 {
    var weight: f32 = 1;
    if (zone.velocity_fade_in != 0 and velocity < zone.velocity_low +| zone.velocity_fade_in) {
        weight *= @as(f32, @floatFromInt(velocity -| zone.velocity_low)) / @as(f32, @floatFromInt(zone.velocity_fade_in));
    }
    if (zone.velocity_fade_out != 0 and velocity > zone.velocity_high -| zone.velocity_fade_out) {
        weight *= @as(f32, @floatFromInt(zone.velocity_high -| velocity)) / @as(f32, @floatFromInt(zone.velocity_fade_out));
    }
    // Equal-power zone crossfades keep perceived energy steadier than linear
    // amplitude interpolation when adjacent velocity layers overlap.
    return @sqrt(std.math.clamp(weight, 0, 1));
}

test "validates and selects overlapping velocity layers" {
    const assets = [_]SampleAsset{
        .{ .content_hash = [_]u8{1} ** 32, .sample_rate = 96_000, .frame_count = 10_000, .channels = 2, .storage = .stream },
        .{ .content_hash = [_]u8{2} ** 32, .sample_rate = 96_000, .frame_count = 10_000, .channels = 2, .storage = .stream },
    };
    const zones = [_]Zone{
        .{ .sample_index = 0, .key_low = 60, .key_high = 60, .velocity_low = 1, .velocity_high = 80, .velocity_fade_out = 24 },
        .{ .sample_index = 1, .key_low = 60, .key_high = 60, .velocity_low = 56, .velocity_high = 127, .velocity_fade_in = 24 },
    };
    const manifest = Manifest{ .samples = &assets, .zones = &zones };
    try manifest.validate();
    var selector: Selector = .{};
    const selection = selector.select(manifest, .attack, .{ .key = 60, .velocity = 68 });
    try std.testing.expectEqual(@as(usize, 2), selection.len);
    try std.testing.expect(selection.layers[0].weight > 0 and selection.layers[0].weight < 1);
    try std.testing.expect(selection.layers[1].weight > 0 and selection.layers[1].weight < 1);
}

test "round robin and pedal trigger selection are deterministic" {
    const assets = [_]SampleAsset{
        .{ .content_hash = [_]u8{1} ** 32, .sample_rate = 48_000, .frame_count = 2_000, .channels = 1, .storage = .preload },
        .{ .content_hash = [_]u8{2} ** 32, .sample_rate = 48_000, .frame_count = 2_000, .channels = 1, .storage = .preload },
        .{ .content_hash = [_]u8{3} ** 32, .sample_rate = 48_000, .frame_count = 2_000, .channels = 1, .storage = .preload },
    };
    const zones = [_]Zone{
        .{ .sample_index = 0, .round_robin_group = 1, .round_robin_index = 0, .round_robin_count = 2 },
        .{ .sample_index = 1, .round_robin_group = 1, .round_robin_index = 1, .round_robin_count = 2 },
        .{ .sample_index = 2, .trigger = .pedal_down, .pedal_low = 64 },
    };
    const manifest = Manifest{ .samples = &assets, .zones = &zones };
    try manifest.validate();
    var selector: Selector = .{};
    try std.testing.expectEqual(@as(u32, 0), selector.select(manifest, .attack, .{ .key = 64, .velocity = 90 }).layers[0].zone_index);
    try std.testing.expectEqual(@as(u32, 1), selector.select(manifest, .attack, .{ .key = 64, .velocity = 90 }).layers[0].zone_index);
    try std.testing.expectEqual(@as(usize, 1), selector.select(manifest, .pedal_down, .{ .key = 64, .velocity = 90, .sustain = 100 }).len);
}
