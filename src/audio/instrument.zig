const std = @import("std");

pub const max_samples = 4096;
pub const max_zones = 16_384;
pub const max_selected_layers = 16;
pub const max_envelope_seconds: f32 = 3600;
pub const max_filter_cutoff_hz: f32 = 192_000;

pub const FilterType = enum(u8) {
    none = 0,
    low_pass_1p = 1,
    high_pass_1p = 2,
    low_pass_2p = 3,
    high_pass_2p = 4,
    band_pass_2p = 5,
    band_reject_2p = 6,
    low_pass_4p = 7,
    high_pass_4p = 8,
};

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

pub const SampleFormat = enum(u8) {
    wav,
    flac,
};

/// A path-owning, decoder-independent source reference produced by the SFZ
/// normalizer. Paths use forward slashes even when an SFZ was authored on
/// Windows, so the same manifest is stable on macOS, iOS, and Wasm.
pub const SampleSource = struct {
    path: []const u8,
    format: SampleFormat,
};

/// Parsed SFZ data before platform I/O resolves the sample files. The parser
/// understands the common SFZ hierarchy and maps only musical selection data
/// into the real-time Zone type. Decode/file access stays outside the core.
pub const SfzImport = struct {
    allocator: std.mem.Allocator,
    samples: []SampleSource,
    zones: []Zone,
    unsupported_opcode_count: usize,

    pub fn deinit(self: *SfzImport) void {
        for (self.samples) |sample| self.allocator.free(sample.path);
        self.allocator.free(self.samples);
        self.allocator.free(self.zones);
        self.* = undefined;
    }

    /// Binds platform-inspected audio metadata to the normalized zone map.
    /// The caller owns `assets`; the returned view remains allocation-free.
    pub fn manifest(self: *const SfzImport, assets: []const SampleAsset) !Manifest {
        if (assets.len != self.samples.len) return error.SampleMetadataCountMismatch;
        const result = Manifest{ .samples = assets, .zones = self.zones };
        try result.validate();
        return result;
    }
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
    detail_controller: u8 = 0,
    detail_low: u8 = 0,
    detail_high: u8 = 127,
    soft_low: u8 = 0,
    soft_high: u8 = 127,
    root_key: u8 = 60,
    key_track: f32 = 1,
    round_robin_group: u8 = 0,
    round_robin_index: u8 = 0,
    round_robin_count: u8 = 1,
    mic_bus: u8 = 0,
    tune_cents: i16 = 0,
    gain_db: f32 = 0,
    pan: f32 = 0,
    amp_attack_seconds: ?f32 = null,
    amp_decay_seconds: ?f32 = null,
    amp_sustain_percent: ?f32 = null,
    amp_release_seconds: ?f32 = null,
    filter_type: FilterType = .none,
    filter_cutoff_hz: ?f32 = null,
    filter_resonance_db: f32 = 0,
    filter_keytrack_cents: f32 = 0,
    filter_keycenter: u8 = 60,
    filter_velocity_track_cents: f32 = 0,
};

const ZoneTemplate = struct {
    sample_path: ?[]const u8 = null,
    trigger: Trigger = .attack,
    key_low: u8 = 0,
    key_high: u8 = 127,
    velocity_low: u8 = 1,
    velocity_high: u8 = 127,
    velocity_fade_in: u8 = 0,
    velocity_fade_out: u8 = 0,
    pedal_low: u8 = 0,
    pedal_high: u8 = 127,
    detail_controller: u8 = 0,
    detail_low: u8 = 0,
    detail_high: u8 = 127,
    soft_low: u8 = 0,
    soft_high: u8 = 127,
    root_key: u8 = 60,
    key_track: f32 = 1,
    round_robin_index: u8 = 0,
    round_robin_count: u8 = 1,
    source_group: u32 = 0,
    mic_bus: u8 = 0,
    tune_cents: i16 = 0,
    gain_db: f32 = 0,
    pan: f32 = 0,
    amp_attack_seconds: ?f32 = null,
    amp_decay_seconds: ?f32 = null,
    amp_sustain_percent: ?f32 = null,
    amp_release_seconds: ?f32 = null,
    filter_type: FilterType = .none,
    filter_cutoff_hz: ?f32 = null,
    filter_resonance_db: f32 = 0,
    filter_keytrack_cents: f32 = 0,
    filter_keycenter: u8 = 60,
    filter_velocity_track_cents: f32 = 0,
    /// An explicitly unsupported `fil_type` must disable the inferred cutoff
    /// filter regardless of SFZ opcode order. Silently turning an unknown mode
    /// into the default two-pole low-pass would materially change an imported
    /// instrument while claiming successful normalization.
    filter_type_unsupported: bool = false,
    on_cc64_low: ?u8 = null,
    on_cc64_high: ?u8 = null,
};

const SfzScope = enum {
    control,
    global,
    master,
    group,
    region,
    ignored,
};

const RoundRobinGroups = struct {
    source_ids: [32]u32 = undefined,
    len: usize = 0,

    fn resolve(self: *RoundRobinGroups, source_group: u32) !u8 {
        for (self.source_ids[0..self.len], 0..) |candidate, index| {
            if (candidate == source_group) return @intCast(index);
        }
        if (self.len == self.source_ids.len) return error.TooManyRoundRobinGroups;
        self.source_ids[self.len] = source_group;
        self.len += 1;
        return @intCast(self.len - 1);
    }
};

/// Normalize a well-defined sample-based SFZ document into shared instrument
/// zones. Unknown DSP opcodes are counted rather than guessed; sfizz can still
/// render those opcodes on native while the portable engine grows coverage.
pub fn parseSfz(allocator: std.mem.Allocator, source: []const u8) !SfzImport {
    if (source.len > 32 * 1024 * 1024) return error.SfzTooLarge;

    var samples: std.ArrayList(SampleSource) = .empty;
    errdefer {
        for (samples.items) |sample| allocator.free(sample.path);
        samples.deinit(allocator);
    }
    var zones: std.ArrayList(Zone) = .empty;
    defer zones.deinit(allocator);

    var scope: SfzScope = .ignored;
    var global: ZoneTemplate = .{};
    var master = global;
    var group = master;
    var region = group;
    var region_active = false;
    var default_path: []const u8 = "";
    var source_group: u32 = 0;
    var rr_groups: RoundRobinGroups = .{};
    var unsupported: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const comment_at = std.mem.indexOf(u8, raw_line, "//") orelse raw_line.len;
        const line = raw_line[0..comment_at];
        var cursor: usize = 0;
        while (cursor < line.len) {
            while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
            if (cursor == line.len) break;

            if (line[cursor] == '<') {
                const close = std.mem.indexOfScalarPos(u8, line, cursor + 1, '>') orelse return error.InvalidSfzHeader;
                if (region_active) {
                    try appendRegion(allocator, &samples, &zones, default_path, region, &rr_groups);
                    region_active = false;
                }
                const header = std.mem.trim(u8, line[cursor + 1 .. close], " \t\r");
                if (std.mem.eql(u8, header, "control")) {
                    scope = .control;
                } else if (std.mem.eql(u8, header, "global")) {
                    global = .{};
                    master = global;
                    group = master;
                    scope = .global;
                } else if (std.mem.eql(u8, header, "master")) {
                    master = global;
                    group = master;
                    scope = .master;
                } else if (std.mem.eql(u8, header, "group")) {
                    source_group +%= 1;
                    group = master;
                    group.source_group = source_group;
                    scope = .group;
                } else if (std.mem.eql(u8, header, "region")) {
                    region = group;
                    region_active = true;
                    scope = .region;
                } else {
                    scope = .ignored;
                }
                cursor = close + 1;
                continue;
            }

            const key_start = cursor;
            while (cursor < line.len and line[cursor] != '=' and !std.ascii.isWhitespace(line[cursor])) cursor += 1;
            if (cursor == line.len or line[cursor] != '=') {
                while (cursor < line.len and !std.ascii.isWhitespace(line[cursor])) cursor += 1;
                continue;
            }
            const key = line[key_start..cursor];
            cursor += 1;
            const value = try nextSfzValue(line, &cursor);

            if (scope == .control and std.mem.eql(u8, key, "default_path")) {
                default_path = value;
                continue;
            }
            const target: ?*ZoneTemplate = switch (scope) {
                .global => &global,
                .master => &master,
                .group => &group,
                .region => &region,
                else => null,
            };
            if (target) |template| {
                if (!try applySfzOpcode(template, key, value)) unsupported += 1;
                if (scope == .global) {
                    master = global;
                    group = master;
                } else if (scope == .master) {
                    group = master;
                }
            } else {
                unsupported += 1;
            }
        }
    }
    if (region_active) try appendRegion(allocator, &samples, &zones, default_path, region, &rr_groups);
    if (zones.items.len == 0) return error.EmptyInstrument;

    const owned_samples = try samples.toOwnedSlice(allocator);
    errdefer {
        for (owned_samples) |sample| allocator.free(sample.path);
        allocator.free(owned_samples);
    }
    const owned_zones = try zones.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .samples = owned_samples,
        .zones = owned_zones,
        .unsupported_opcode_count = unsupported,
    };
}

fn nextSfzValue(line: []const u8, cursor: *usize) ![]const u8 {
    while (cursor.* < line.len and std.ascii.isWhitespace(line[cursor.*])) cursor.* += 1;
    if (cursor.* == line.len) return error.MissingSfzValue;
    if (line[cursor.*] == '"') {
        cursor.* += 1;
        const start = cursor.*;
        const close = std.mem.indexOfScalarPos(u8, line, cursor.*, '"') orelse return error.UnterminatedSfzValue;
        cursor.* = close + 1;
        return line[start..close];
    }
    const start = cursor.*;
    while (cursor.* < line.len and !std.ascii.isWhitespace(line[cursor.*]) and line[cursor.*] != '<') cursor.* += 1;
    return line[start..cursor.*];
}

fn applySfzOpcode(template: *ZoneTemplate, key: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, key, "sample")) template.sample_path = value else if (std.mem.eql(u8, key, "key")) {
        const note = try parseMidiKey(value);
        template.key_low = note;
        template.key_high = note;
        template.root_key = note;
    } else if (std.mem.eql(u8, key, "lokey")) template.key_low = if (std.mem.eql(u8, value, "-1")) 0 else try parseMidiKey(value) else if (std.mem.eql(u8, key, "hikey")) template.key_high = if (std.mem.eql(u8, value, "-1")) 127 else try parseMidiKey(value) else if (std.mem.eql(u8, key, "pitch_keycenter")) {
        if (std.mem.eql(u8, value, "-1")) {
            template.key_track = 0;
        } else {
            template.root_key = try parseMidiKey(value);
            template.key_track = 1;
        }
    } else if (std.mem.eql(u8, key, "pitch_keytrack")) {
        const cents_per_key = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(cents_per_key)) return error.InvalidKeyTrack;
        template.key_track = cents_per_key / 100.0;
    } else if (std.mem.eql(u8, key, "lovel")) template.velocity_low = try parseMidiByte(value) else if (std.mem.eql(u8, key, "hivel")) template.velocity_high = try parseMidiByte(value) else if (std.mem.eql(u8, key, "xfin_lovel")) {
        const low = try parseMidiByte(value);
        template.velocity_fade_in = template.velocity_high -| low;
    } else if (std.mem.eql(u8, key, "xfout_hivel")) {
        const high = try parseMidiByte(value);
        template.velocity_fade_out = high -| template.velocity_low;
    } else if (std.mem.eql(u8, key, "locc64")) template.pedal_low = try parseMidiByte(value) else if (std.mem.eql(u8, key, "hicc64")) template.pedal_high = try parseMidiByte(value) else if (detailControllerOpcode(key, "locc")) |controller| {
        try setDetailRange(template, controller, true, try parseMidiByte(value));
    } else if (detailControllerOpcode(key, "hicc")) |controller| {
        try setDetailRange(template, controller, false, try parseMidiByte(value));
    } else if (std.mem.eql(u8, key, "locc67")) template.soft_low = try parseMidiByte(value) else if (std.mem.eql(u8, key, "hicc67")) template.soft_high = try parseMidiByte(value) else if (std.mem.eql(u8, key, "on_locc64")) template.on_cc64_low = try parseMidiByte(value) else if (std.mem.eql(u8, key, "on_hicc64")) template.on_cc64_high = try parseMidiByte(value) else if (std.mem.eql(u8, key, "seq_length")) template.round_robin_count = try parsePositiveByte(value) else if (std.mem.eql(u8, key, "seq_position")) {
        const position = try parsePositiveByte(value);
        template.round_robin_index = position - 1;
    } else if (std.mem.eql(u8, key, "tune")) {
        const parsed = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(parsed) or parsed < -32_768 or parsed > 32_767) return error.InvalidTune;
        template.tune_cents = @intFromFloat(@round(parsed));
    } else if (std.mem.eql(u8, key, "volume")) {
        template.gain_db = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, key, "pan")) {
        const sfz_pan = try std.fmt.parseFloat(f32, value);
        template.pan = std.math.clamp(sfz_pan / 100.0, -1, 1);
    } else if (std.mem.eql(u8, key, "ampeg_attack")) {
        template.amp_attack_seconds = try parseEnvelopeSeconds(value);
    } else if (std.mem.eql(u8, key, "ampeg_decay")) {
        template.amp_decay_seconds = try parseEnvelopeSeconds(value);
    } else if (std.mem.eql(u8, key, "ampeg_sustain")) {
        const percent = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return error.InvalidEnvelopeSustain;
        template.amp_sustain_percent = percent;
    } else if (std.mem.eql(u8, key, "ampeg_release")) {
        template.amp_release_seconds = try parseEnvelopeSeconds(value);
    } else if (std.mem.eql(u8, key, "cutoff")) {
        const cutoff = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(cutoff) or cutoff <= 0 or cutoff > max_filter_cutoff_hz) return error.InvalidFilterCutoff;
        template.filter_cutoff_hz = cutoff;
        if (!template.filter_type_unsupported and template.filter_type == .none) template.filter_type = .low_pass_2p;
    } else if (std.mem.eql(u8, key, "resonance")) {
        const resonance = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(resonance) or resonance < 0 or resonance > 60) return error.InvalidFilterResonance;
        template.filter_resonance_db = resonance;
    } else if (std.mem.eql(u8, key, "fil_type")) {
        if (parseFilterType(value)) |kind| {
            template.filter_type = kind;
            template.filter_type_unsupported = false;
        } else {
            template.filter_type = .none;
            template.filter_type_unsupported = true;
            return false;
        }
    } else if (std.mem.eql(u8, key, "fil_keytrack")) {
        const cents = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(cents) or cents < -1200 or cents > 1200) return error.InvalidFilterTracking;
        template.filter_keytrack_cents = cents;
    } else if (std.mem.eql(u8, key, "fil_keycenter")) {
        template.filter_keycenter = try parseMidiKey(value);
    } else if (std.mem.eql(u8, key, "fil_veltrack")) {
        const cents = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(cents) or cents < -9600 or cents > 9600) return error.InvalidFilterTracking;
        template.filter_velocity_track_cents = cents;
    } else if (std.mem.eql(u8, key, "trigger")) {
        if (std.mem.eql(u8, value, "release") or std.mem.eql(u8, value, "release_key")) {
            template.trigger = .release;
        } else if (std.mem.eql(u8, value, "attack") or std.mem.eql(u8, value, "first") or std.mem.eql(u8, value, "legato")) {
            template.trigger = .attack;
        } else return false;
    } else if (std.mem.eql(u8, key, "mic_bus")) {
        template.mic_bus = try std.fmt.parseInt(u8, value, 10);
    } else return false;
    return true;
}

fn parseFilterType(value: []const u8) ?FilterType {
    if (std.mem.eql(u8, value, "lpf_1p")) return .low_pass_1p;
    if (std.mem.eql(u8, value, "hpf_1p")) return .high_pass_1p;
    if (std.mem.eql(u8, value, "lpf_2p")) return .low_pass_2p;
    if (std.mem.eql(u8, value, "hpf_2p")) return .high_pass_2p;
    if (std.mem.eql(u8, value, "bpf_2p")) return .band_pass_2p;
    if (std.mem.eql(u8, value, "brf_2p")) return .band_reject_2p;
    if (std.mem.eql(u8, value, "lpf_4p")) return .low_pass_4p;
    if (std.mem.eql(u8, value, "hpf_4p")) return .high_pass_4p;
    return null;
}

fn detailControllerOpcode(key: []const u8, prefix: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const suffix = key[prefix.len..];
    const controller = std.fmt.parseInt(u8, suffix, 10) catch return null;
    return if (controller >= 20 and controller <= 23) controller else null;
}

fn setDetailRange(template: *ZoneTemplate, controller: u8, low: bool, value: u8) !void {
    if (template.detail_controller != 0 and template.detail_controller != controller) return error.MultipleDetailControllers;
    template.detail_controller = controller;
    if (low) template.detail_low = value else template.detail_high = value;
}

fn appendRegion(
    allocator: std.mem.Allocator,
    samples: *std.ArrayList(SampleSource),
    zones: *std.ArrayList(Zone),
    default_path: []const u8,
    template: ZoneTemplate,
    rr_groups: *RoundRobinGroups,
) !void {
    if (zones.items.len == max_zones) return error.ManifestTooLarge;
    const raw_path = template.sample_path orelse return error.RegionMissingSample;
    const normalized_path = try normalizeSamplePath(allocator, default_path, raw_path);
    errdefer allocator.free(normalized_path);
    const format = sampleFormat(normalized_path) orelse return error.UnsupportedSampleFormat;

    var sample_index: ?u32 = null;
    for (samples.items, 0..) |sample, index| {
        if (std.mem.eql(u8, sample.path, normalized_path)) {
            sample_index = @intCast(index);
            break;
        }
    }
    if (sample_index == null) {
        if (samples.items.len == max_samples) return error.ManifestTooLarge;
        sample_index = @intCast(samples.items.len);
        try samples.append(allocator, .{ .path = normalized_path, .format = format });
    } else {
        allocator.free(normalized_path);
    }

    var trigger = template.trigger;
    var pedal_low = template.pedal_low;
    var pedal_high = template.pedal_high;
    if (template.on_cc64_low != null or template.on_cc64_high != null) {
        pedal_low = template.on_cc64_low orelse 0;
        pedal_high = template.on_cc64_high orelse 127;
        trigger = if (pedal_low >= 64) .pedal_down else .pedal_up;
    }
    const rr_group: u8 = if (template.round_robin_count > 1) try rr_groups.resolve(template.source_group) else 0;
    try zones.append(allocator, .{
        .sample_index = sample_index.?,
        .trigger = trigger,
        .key_low = template.key_low,
        .key_high = template.key_high,
        .velocity_low = template.velocity_low,
        .velocity_high = template.velocity_high,
        .velocity_fade_in = template.velocity_fade_in,
        .velocity_fade_out = template.velocity_fade_out,
        .pedal_low = pedal_low,
        .pedal_high = pedal_high,
        .detail_controller = template.detail_controller,
        .detail_low = template.detail_low,
        .detail_high = template.detail_high,
        .soft_low = template.soft_low,
        .soft_high = template.soft_high,
        .root_key = template.root_key,
        .key_track = template.key_track,
        .round_robin_group = rr_group,
        .round_robin_index = template.round_robin_index,
        .round_robin_count = template.round_robin_count,
        .mic_bus = template.mic_bus,
        .tune_cents = template.tune_cents,
        .gain_db = template.gain_db,
        .pan = template.pan,
        .amp_attack_seconds = template.amp_attack_seconds,
        .amp_decay_seconds = template.amp_decay_seconds,
        .amp_sustain_percent = template.amp_sustain_percent,
        .amp_release_seconds = template.amp_release_seconds,
        .filter_type = if (template.filter_type_unsupported) .none else template.filter_type,
        .filter_cutoff_hz = if (template.filter_type_unsupported) null else template.filter_cutoff_hz,
        .filter_resonance_db = template.filter_resonance_db,
        .filter_keytrack_cents = template.filter_keytrack_cents,
        .filter_keycenter = template.filter_keycenter,
        .filter_velocity_track_cents = template.filter_velocity_track_cents,
    });
}

fn parseEnvelopeSeconds(value: []const u8) !f32 {
    const seconds = try std.fmt.parseFloat(f32, value);
    if (!std.math.isFinite(seconds) or seconds < 0 or seconds > max_envelope_seconds) return error.InvalidEnvelopeTime;
    return seconds;
}

fn normalizeSamplePath(allocator: std.mem.Allocator, default_path: []const u8, sample_path: []const u8) ![]u8 {
    const separator_len: usize = if (default_path.len != 0 and default_path[default_path.len - 1] != '/' and default_path[default_path.len - 1] != '\\') 1 else 0;
    const raw = try allocator.alloc(u8, default_path.len + separator_len + sample_path.len);
    defer allocator.free(raw);
    @memcpy(raw[0..default_path.len], default_path);
    if (separator_len != 0) raw[default_path.len] = '/';
    @memcpy(raw[default_path.len + separator_len ..], sample_path);
    for (raw) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };

    var compact = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(compact);
    var written: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '/' and written != 0 and compact[written - 1] == '/') continue;
        compact[written] = raw[index];
        written += 1;
    }
    var start: usize = 0;
    while (written - start >= 2 and compact[start] == '.' and compact[start + 1] == '/') start += 2;
    const result = try allocator.dupe(u8, compact[start..written]);
    allocator.free(compact);
    return result;
}

fn sampleFormat(path: []const u8) ?SampleFormat {
    if (std.ascii.endsWithIgnoreCase(path, ".wav")) return .wav;
    if (std.ascii.endsWithIgnoreCase(path, ".flac")) return .flac;
    return null;
}

fn parseMidiByte(value: []const u8) !u8 {
    const parsed = try std.fmt.parseInt(u16, value, 10);
    if (parsed > 127) return error.InvalidMidiValue;
    return @intCast(parsed);
}

fn parsePositiveByte(value: []const u8) !u8 {
    const parsed = try parseMidiByte(value);
    if (parsed == 0) return error.InvalidRoundRobin;
    return parsed;
}

fn parseMidiKey(value: []const u8) !u8 {
    if (value.len == 0) return error.InvalidMidiKey;
    if (std.ascii.isDigit(value[0])) return parseMidiByte(value);
    const letter = std.ascii.toUpper(value[0]);
    var semitone: i16 = switch (letter) {
        'C' => 0,
        'D' => 2,
        'E' => 4,
        'F' => 5,
        'G' => 7,
        'A' => 9,
        'B' => 11,
        else => return error.InvalidMidiKey,
    };
    var cursor: usize = 1;
    if (cursor < value.len and (value[cursor] == '#' or value[cursor] == 'b' or value[cursor] == 'B')) {
        semitone += if (value[cursor] == '#') 1 else -1;
        cursor += 1;
    }
    const octave = std.fmt.parseInt(i16, value[cursor..], 10) catch return error.InvalidMidiKey;
    const midi = (octave + 1) * 12 + semitone;
    if (midi < 0 or midi > 127) return error.InvalidMidiKey;
    return @intCast(midi);
}

/// Inspect a complete WAV or FLAC asset, producing immutable metadata and a
/// SHA-256 integrity identity. Decoding is deliberately separate from this
/// validation step, so platforms can use their native lossless decoders.
pub fn inspectSampleBytes(bytes: []const u8, storage: Storage) !SampleAsset {
    var content_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &content_hash, .{});
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE")) {
        var channels: u8 = 0;
        var sample_rate: u32 = 0;
        var block_align: u16 = 0;
        var frame_count: u64 = 0;
        var cursor: usize = 12;
        while (cursor + 8 <= bytes.len) {
            const chunk_size = readLe32(bytes[cursor + 4 .. cursor + 8]);
            const data_start = cursor + 8;
            const data_end = data_start +| @as(usize, chunk_size);
            if (data_end > bytes.len) return error.TruncatedSample;
            if (std.mem.eql(u8, bytes[cursor .. cursor + 4], "fmt ")) {
                if (chunk_size < 16) return error.InvalidWav;
                const format = readLe16(bytes[data_start .. data_start + 2]);
                if (format != 1 and format != 3 and format != 0xfffe) return error.UnsupportedWavEncoding;
                const parsed_channels = readLe16(bytes[data_start + 2 .. data_start + 4]);
                if (parsed_channels == 0 or parsed_channels > 8) return error.InvalidSample;
                channels = @intCast(parsed_channels);
                sample_rate = readLe32(bytes[data_start + 4 .. data_start + 8]);
                block_align = readLe16(bytes[data_start + 12 .. data_start + 14]);
            } else if (std.mem.eql(u8, bytes[cursor .. cursor + 4], "data")) {
                if (block_align == 0) return error.WavDataBeforeFormat;
                frame_count = chunk_size / block_align;
            }
            cursor = data_end + (chunk_size & 1);
        }
        const result = SampleAsset{ .content_hash = content_hash, .sample_rate = sample_rate, .frame_count = frame_count, .channels = channels, .storage = storage };
        try (Manifest{ .samples = &.{result}, .zones = &.{} }).validate();
        return result;
    }
    if (bytes.len >= 42 and std.mem.eql(u8, bytes[0..4], "fLaC")) {
        var cursor: usize = 4;
        while (cursor + 4 <= bytes.len) {
            const block_type = bytes[cursor] & 0x7f;
            const is_last = bytes[cursor] & 0x80 != 0;
            const length = (@as(usize, bytes[cursor + 1]) << 16) | (@as(usize, bytes[cursor + 2]) << 8) | bytes[cursor + 3];
            const start = cursor + 4;
            if (start + length > bytes.len) return error.TruncatedSample;
            if (block_type == 0) {
                if (length < 34) return error.InvalidFlac;
                const stream_fields = readBe64(bytes[start + 10 .. start + 18]);
                const sample_rate: u32 = @intCast((stream_fields >> 44) & 0x000f_ffff);
                const channels: u8 = @intCast(((stream_fields >> 41) & 0x7) + 1);
                const frame_count = stream_fields & 0x0000_000f_ffff_ffff;
                const result = SampleAsset{ .content_hash = content_hash, .sample_rate = sample_rate, .frame_count = frame_count, .channels = channels, .storage = storage };
                try (Manifest{ .samples = &.{result}, .zones = &.{} }).validate();
                return result;
            }
            cursor = start + length;
            if (is_last) break;
        }
        return error.MissingFlacStreamInfo;
    }
    return error.UnsupportedSampleFormat;
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readBe64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes[0..8]) |byte| value = (value << 8) | byte;
    return value;
}

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
            if (zone.key_low > zone.key_high or zone.velocity_low > zone.velocity_high or zone.pedal_low > zone.pedal_high or zone.detail_low > zone.detail_high or zone.soft_low > zone.soft_high) return error.InvalidRange;
            if (zone.detail_controller != 0 and (zone.detail_controller < 20 or zone.detail_controller > 23)) return error.InvalidDetailController;
            if (zone.root_key > 127 or zone.round_robin_count == 0 or zone.round_robin_index >= zone.round_robin_count or zone.round_robin_group >= 32) return error.InvalidRoundRobin;
            if (!std.math.isFinite(zone.gain_db) or !std.math.isFinite(zone.pan) or zone.pan < -1 or zone.pan > 1 or !std.math.isFinite(zone.key_track) or zone.key_track < -4 or zone.key_track > 4) return error.InvalidMix;
            for ([_]?f32{ zone.amp_attack_seconds, zone.amp_decay_seconds, zone.amp_release_seconds }) |seconds| if (seconds) |present| {
                if (!std.math.isFinite(present) or present < 0 or present > max_envelope_seconds) return error.InvalidEnvelopeTime;
            };
            if (zone.amp_sustain_percent) |percent| {
                if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return error.InvalidEnvelopeSustain;
            }
            if (zone.filter_cutoff_hz) |cutoff| {
                if (!std.math.isFinite(cutoff) or cutoff <= 0 or cutoff > max_filter_cutoff_hz or zone.filter_type == .none) return error.InvalidFilterCutoff;
            }
            if (!std.math.isFinite(zone.filter_resonance_db) or zone.filter_resonance_db < 0 or zone.filter_resonance_db > 60) return error.InvalidFilterResonance;
            if (zone.filter_keycenter > 127 or !std.math.isFinite(zone.filter_keytrack_cents) or zone.filter_keytrack_cents < -1200 or zone.filter_keytrack_cents > 1200 or !std.math.isFinite(zone.filter_velocity_track_cents) or zone.filter_velocity_track_cents < -9600 or zone.filter_velocity_track_cents > 9600) return error.InvalidFilterTracking;
        }
    }
};

pub const Input = struct {
    key: u8,
    velocity: u8,
    sustain: u8 = 0,
    soft: u8 = 0,
    detail: [4]u8 = [_]u8{0} ** 4,
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
            if (zone.detail_controller != 0) {
                const detail_value = input.detail[zone.detail_controller - 20];
                if (detail_value < zone.detail_low or detail_value > zone.detail_high) continue;
            }
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

test "detail-controlled SFZ layers remain disabled until their authored CC is enabled" {
    const assets = [_]SampleAsset{.{ .content_hash = [_]u8{1} ** 32, .sample_rate = 48_000, .frame_count = 2_000, .channels = 1, .storage = .preload }};
    const zones = [_]Zone{.{ .sample_index = 0, .key_low = 60, .key_high = 60, .detail_controller = 23, .detail_low = 1 }};
    const manifest = Manifest{ .samples = &assets, .zones = &zones };
    try manifest.validate();
    var selector: Selector = .{};
    try std.testing.expectEqual(@as(usize, 0), selector.select(manifest, .attack, .{ .key = 60, .velocity = 80 }).len);
    try std.testing.expectEqual(@as(usize, 1), selector.select(manifest, .attack, .{ .key = 60, .velocity = 80, .detail = .{ 0, 0, 0, 64 } }).len);
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

test "SFZ normalization preserves hierarchy paths triggers and round robins" {
    const sfz =
        \\<control> default_path="Samples\\Piano"
        \\<global> pan=25
        \\<group> lokey=C4 hikey=D4 seq_length=2 locc21=1 hicc21=127
        \\<region> sample="tone one.wav" lovel=1 hivel=80 seq_position=1
        \\<region> sample="tone one.wav" lovel=81 hivel=127 seq_position=2 trigger=release
        \\<group>
        \\<region> sample=pedal.flac key=60 on_locc64=126 on_hicc64=127
    ;
    var imported = try parseSfz(std.testing.allocator, sfz);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 2), imported.samples.len);
    try std.testing.expectEqualStrings("Samples/Piano/tone one.wav", imported.samples[0].path);
    try std.testing.expectEqual(SampleFormat.wav, imported.samples[0].format);
    try std.testing.expectEqualStrings("Samples/Piano/pedal.flac", imported.samples[1].path);
    try std.testing.expectEqual(@as(usize, 3), imported.zones.len);
    try std.testing.expectEqual(@as(u8, 60), imported.zones[0].key_low);
    try std.testing.expectEqual(@as(u8, 62), imported.zones[0].key_high);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), imported.zones[0].pan, 0.0001);
    try std.testing.expectEqual(@as(u8, 2), imported.zones[0].round_robin_count);
    try std.testing.expectEqual(@as(u8, 0), imported.zones[0].round_robin_index);
    try std.testing.expectEqual(@as(u8, 21), imported.zones[0].detail_controller);
    try std.testing.expectEqual(@as(u8, 1), imported.zones[0].detail_low);
    try std.testing.expectEqual(@as(u8, 1), imported.zones[1].round_robin_index);
    try std.testing.expectEqual(Trigger.release, imported.zones[1].trigger);
    try std.testing.expectEqual(Trigger.pedal_down, imported.zones[2].trigger);
    try std.testing.expectEqual(@as(u8, 126), imported.zones[2].pedal_low);
}

test "SFZ normalization inherits per-zone amplitude envelopes" {
    const sfz =
        \\<global> ampeg_attack=0.125 ampeg_decay=0.75 ampeg_sustain=62.5 ampeg_release=1.5
        \\<group> ampeg_attack=0.25
        \\<region> sample=tone.wav key=C4
        \\<region> sample=tail.wav key=D4 ampeg_release=3
    ;
    var imported = try parseSfz(std.testing.allocator, sfz);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 2), imported.zones.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), imported.zones[0].amp_attack_seconds.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), imported.zones[0].amp_decay_seconds.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 62.5), imported.zones[0].amp_sustain_percent.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), imported.zones[0].amp_release_seconds.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), imported.zones[1].amp_release_seconds.?, 0.0001);
}

test "SFZ normalization preserves inherited filter modes and tracking" {
    const sfz =
        \\<global> cutoff=8400 resonance=6 fil_type=lpf_4p fil_keytrack=100 fil_keycenter=C4 fil_veltrack=1200
        \\<group> cutoff=3200 fil_type=hpf_2p
        \\<region> sample=tone.wav key=D4
        \\<region> sample=tail.wav key=E4 cutoff=12000 fil_type=brf_2p
    ;
    var imported = try parseSfz(std.testing.allocator, sfz);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 2), imported.zones.len);
    try std.testing.expectEqual(FilterType.high_pass_2p, imported.zones[0].filter_type);
    try std.testing.expectApproxEqAbs(@as(f32, 3200), imported.zones[0].filter_cutoff_hz.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), imported.zones[0].filter_resonance_db, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), imported.zones[0].filter_keytrack_cents, 0.001);
    try std.testing.expectEqual(@as(u8, 60), imported.zones[0].filter_keycenter);
    try std.testing.expectApproxEqAbs(@as(f32, 1200), imported.zones[0].filter_velocity_track_cents, 0.001);
    try std.testing.expectEqual(FilterType.band_reject_2p, imported.zones[1].filter_type);
    try std.testing.expectApproxEqAbs(@as(f32, 12000), imported.zones[1].filter_cutoff_hz.?, 0.001);

    try std.testing.expectError(error.InvalidFilterCutoff, parseSfz(std.testing.allocator, "<region> sample=x.wav cutoff=0"));
    try std.testing.expectError(error.InvalidFilterResonance, parseSfz(std.testing.allocator, "<region> sample=x.wav resonance=61"));
    try std.testing.expectError(error.InvalidFilterTracking, parseSfz(std.testing.allocator, "<region> sample=x.wav fil_keytrack=1201"));
}

test "unsupported explicit SFZ filter modes never become an inferred low pass" {
    const before_cutoff =
        \\<region> sample=first.wav fil_type=exotic_6p cutoff=4200
        \\<region> sample=second.wav cutoff=5100 fil_type=exotic_6p
    ;
    var imported = try parseSfz(std.testing.allocator, before_cutoff);
    defer imported.deinit();

    try std.testing.expectEqual(@as(usize, 2), imported.zones.len);
    try std.testing.expectEqual(@as(usize, 2), imported.unsupported_opcode_count);
    for (imported.zones) |zone| {
        try std.testing.expectEqual(FilterType.none, zone.filter_type);
        try std.testing.expectEqual(@as(?f32, null), zone.filter_cutoff_hz);
    }
}

test "WAV and FLAC metadata inspection hashes lossless assets" {
    var wav = [_]u8{0} ** 48;
    @memcpy(wav[0..4], "RIFF");
    writeLe32(wav[4..8], 40);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    writeLe32(wav[16..20], 16);
    writeLe16(wav[20..22], 1);
    writeLe16(wav[22..24], 1);
    writeLe32(wav[24..28], 48_000);
    writeLe32(wav[28..32], 96_000);
    writeLe16(wav[32..34], 2);
    writeLe16(wav[34..36], 16);
    @memcpy(wav[36..40], "data");
    writeLe32(wav[40..44], 4);
    const wav_asset = try inspectSampleBytes(&wav, .preload);
    try std.testing.expectEqual(@as(u32, 48_000), wav_asset.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), wav_asset.channels);
    try std.testing.expectEqual(@as(u64, 2), wav_asset.frame_count);
    try std.testing.expect(!std.mem.allEqual(u8, &wav_asset.content_hash, 0));

    var flac = [_]u8{0} ** 42;
    @memcpy(flac[0..4], "fLaC");
    flac[4] = 0x80;
    flac[7] = 34;
    const stream_fields = (@as(u64, 96_000) << 44) | (@as(u64, 1) << 41) | (@as(u64, 23) << 36) | 1_234;
    writeBe64(flac[18..26], stream_fields);
    const flac_asset = try inspectSampleBytes(&flac, .stream);
    try std.testing.expectEqual(@as(u32, 96_000), flac_asset.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), flac_asset.channels);
    try std.testing.expectEqual(@as(u64, 1_234), flac_asset.frame_count);
    try std.testing.expect(!std.mem.eql(u8, &wav_asset.content_hash, &flac_asset.content_hash));
}

fn writeLe16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}

fn writeLe32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn writeBe64(bytes: []u8, value: u64) void {
    for (0..8) |index| bytes[index] = @truncate(value >> @intCast((7 - index) * 8));
}
