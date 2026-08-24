const std = @import("std");
const score = @import("score");
const sampler_api = @import("sfizz_sampler");
const Sampler = sampler_api.Sampler;
const PianoDetailProfile = sampler_api.PianoDetailProfile;

const sample_rate: u32 = 48_000;
const channels: usize = 2;
const block_frames: usize = 256;
const output_seconds: usize = 42;
const proof_seconds: usize = 12;
const max_score_file_bytes: usize = 256 * 1024 * 1024;
const max_sample_file_bytes: usize = 512 * 1024 * 1024;

const PackIssue = struct {
    path: []const u8,
    reason: []const u8,
};

const SfzMacro = struct {
    name: []u8,
    value: []u8,
};

fn deinitSfzMacros(allocator: std.mem.Allocator, macros: *std.ArrayList(SfzMacro)) void {
    for (macros.items) |macro| {
        allocator.free(macro.name);
        allocator.free(macro.value);
    }
    macros.deinit(allocator);
}

fn setSfzMacro(allocator: std.mem.Allocator, macros: *std.ArrayList(SfzMacro), name: []const u8, value: []const u8) !void {
    for (macros.items) |*macro| {
        if (!std.mem.eql(u8, macro.name, name)) continue;
        const replacement = try allocator.dupe(u8, value);
        allocator.free(macro.value);
        macro.value = replacement;
        return;
    }
    if (macros.items.len == 512) return error.TooManySfzMacros;
    try macros.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, value) });
}

fn lookupSfzMacro(macros: []const SfzMacro, name: []const u8) ?[]const u8 {
    var index = macros.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, macros[index].name, name)) return macros[index].value;
    }
    return null;
}

fn appendExpandedSfz(writer: *std.Io.Writer, text: []const u8, macros: []const SfzMacro) !void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (text[cursor] != '$') {
            try writer.writeByte(text[cursor]);
            cursor += 1;
            continue;
        }
        const name_start = cursor;
        cursor += 1;
        while (cursor < text.len and (std.ascii.isAlphanumeric(text[cursor]) or text[cursor] == '_')) cursor += 1;
        const name = text[name_start..cursor];
        if (lookupSfzMacro(macros, name)) |value| {
            try writer.writeAll(value);
        } else {
            try writer.writeAll(name);
        }
    }
}

fn expandSfzFile(
    init: std.process.Init,
    root_directory: []const u8,
    path: []const u8,
    depth: usize,
    macros: *std.ArrayList(SfzMacro),
    output: *std.Io.Writer.Allocating,
) !void {
    if (depth > 16) return error.SfzIncludeDepthExceeded;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(32 * 1024 * 1024));
    defer init.gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const comment_at = std.mem.indexOf(u8, raw_line, "//") orelse raw_line.len;
        const line = raw_line[0..comment_at];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#define")) {
            var fields = std.mem.tokenizeAny(u8, trimmed["#define".len..], " \t\r");
            const name = fields.next() orelse return error.InvalidSfzDefine;
            const value = fields.next() orelse return error.InvalidSfzDefine;
            try setSfzMacro(init.gpa, macros, name, value);
            continue;
        }

        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "#include")) |include_at| {
            try appendExpandedSfz(&output.writer, line[cursor..include_at], macros.items);
            var quote_start = include_at + "#include".len;
            while (quote_start < line.len and std.ascii.isWhitespace(line[quote_start])) quote_start += 1;
            if (quote_start == line.len or line[quote_start] != '"') return error.InvalidSfzInclude;
            quote_start += 1;
            const quote_end = std.mem.indexOfScalarPos(u8, line, quote_start, '"') orelse return error.InvalidSfzInclude;
            const include_relative = line[quote_start..quote_end];
            const include_path = try std.fs.path.join(init.gpa, &.{ root_directory, include_relative });
            defer init.gpa.free(include_path);
            try expandSfzFile(init, root_directory, include_path, depth + 1, macros, output);
            cursor = quote_end + 1;
        }
        try appendExpandedSfz(&output.writer, line[cursor..], macros.items);
        try output.writer.writeByte('\n');
        if (output.written().len > 32 * 1024 * 1024) return error.SfzTooLarge;
    }
}

fn expandSfzSource(init: std.process.Init, sfz_path: []const u8) ![]u8 {
    var macros: std.ArrayList(SfzMacro) = .empty;
    defer deinitSfzMacros(init.gpa, &macros);
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    errdefer output.deinit();
    const root_directory = std.fs.path.dirname(sfz_path) orelse ".";
    try expandSfzFile(init, root_directory, sfz_path, 0, &macros, &output);
    return output.toOwnedSlice();
}

const ScoreEventKind = enum(u8) {
    control_change,
    note_off,
    note_on,
};

const ScoreEvent = struct {
    frame: usize,
    kind: ScoreEventKind,
    pitch_or_controller: u8,
    value: u8,
};

const Harness = struct {
    sampler: *Sampler,
    output: []f32,
    frame_cursor: usize = 0,

    fn render(self: *Harness, frame_count: usize) ![]f32 {
        if (self.frame_cursor + frame_count > self.output.len / channels) return error.VerificationBufferTooSmall;
        const start = self.frame_cursor * channels;
        var remaining = frame_count;
        while (remaining != 0) {
            const count = @min(remaining, block_frames);
            const offset = self.frame_cursor * channels;
            self.sampler.renderInterleaved(self.output[offset .. offset + count * channels], count, channels, sample_rate);
            self.frame_cursor += count;
            remaining -= count;
        }
        return self.output[start .. self.frame_cursor * channels];
    }

    fn seconds(self: *Harness, value: f32) ![]f32 {
        return self.render(@intFromFloat(value * sample_rate));
    }

    fn reset(self: *Harness) !void {
        self.sampler.allNotesOff();
        _ = try self.seconds(0.12);
    }

    fn append(self: *Harness, samples: []const f32) !void {
        if (samples.len % channels != 0 or self.frame_cursor + samples.len / channels > self.output.len / channels) return error.VerificationBufferTooSmall;
        const start = self.frame_cursor * channels;
        @memcpy(self.output[start .. start + samples.len], samples);
        self.frame_cursor += samples.len / channels;
    }

    fn rendered(self: *const Harness) []const f32 {
        return self.output[0 .. self.frame_cursor * channels];
    }
};

const Gate = struct {
    passed: bool = true,
    failures: [16][]const u8 = undefined,
    failure_count: usize = 0,

    fn require(self: *Gate, condition: bool, message: []const u8) void {
        if (condition) return;
        self.passed = false;
        if (self.failure_count < self.failures.len) {
            self.failures[self.failure_count] = message;
            self.failure_count += 1;
        }
    }
};

const ReplayComparison = struct {
    bit_exact: bool,
    max_abs_error: f32,
    normalized_rms_error: f32,
    correlation: f32,
};

fn compareReplay(left: []const f32, right: []const f32) ReplayComparison {
    var max_abs_error: f32 = 0;
    var error_energy: f64 = 0;
    var left_energy: f64 = 0;
    var right_energy: f64 = 0;
    var cross_energy: f64 = 0;
    for (left, right) |a, b| {
        const difference = a - b;
        max_abs_error = @max(max_abs_error, @abs(difference));
        error_energy += @as(f64, difference) * difference;
        left_energy += @as(f64, a) * a;
        right_energy += @as(f64, b) * b;
        cross_energy += @as(f64, a) * b;
    }
    const reference_energy = @max(left_energy, right_energy);
    return .{
        .bit_exact = std.mem.eql(f32, left, right),
        .max_abs_error = max_abs_error,
        .normalized_rms_error = if (reference_energy == 0) 0 else @floatCast(@sqrt(error_energy / reference_energy)),
        .correlation = if (left_energy == 0 or right_energy == 0) 0 else @floatCast(cross_energy / @sqrt(left_energy * right_energy)),
    };
}

fn writeJsonFloat(writer: *std.Io.Writer, value: f32) !void {
    if (std.math.isFinite(value)) {
        try writer.print("{d:.3}", .{value});
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u00{x:0>2}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn pedalReleaseProbe(harness: *Harness, value: u8) !score.audio_quality.Stats {
    try harness.reset();
    harness.sampler.controlChange(0, 20, 0);
    harness.sampler.controlChange(0, 21, 0);
    harness.sampler.controlChange(0, 22, 0);
    harness.sampler.controlChange(0, 23, 0);
    harness.sampler.noteOn(0, 60, 96);
    _ = try harness.seconds(0.3);
    harness.sampler.controlChange(0, 64, value);
    harness.sampler.noteOff(0, 60);
    const release = try harness.seconds(2.2);
    const tail_samples = @as(usize, sample_rate) * channels / 2;
    return score.audio_quality.analyze(release[release.len - tail_samples ..]);
}

fn renderDeterministicAttack(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.controlChange(0, 20, 0);
    sampler.controlChange(0, 21, 0);
    sampler.controlChange(0, 22, 0);
    sampler.controlChange(0, 23, 0);
    sampler.noteOn(3, 64, 82);
    var frame_cursor: usize = 0;
    while (frame_cursor < output.len / channels) {
        const count = @min(block_frames, output.len / channels - frame_cursor);
        const start = frame_cursor * channels;
        sampler.renderInterleaved(output[start .. start + count * channels], count, channels, sample_rate);
        frame_cursor += count;
    }
}

fn renderFrames(sampler: *Sampler, output: []f32) void {
    std.debug.assert(output.len % channels == 0);
    var frame_cursor: usize = 0;
    while (frame_cursor < output.len / channels) {
        const count = @min(block_frames, output.len / channels - frame_cursor);
        const start = frame_cursor * channels;
        sampler.renderInterleaved(output[start .. start + count * channels], count, channels, sample_rate);
        frame_cursor += count;
    }
}

fn discardFrames(sampler: *Sampler, frame_count: usize) void {
    var scratch: [block_frames * channels]f32 = undefined;
    var remaining = frame_count;
    while (remaining != 0) {
        const count = @min(block_frames, remaining);
        sampler.renderInterleaved(scratch[0 .. count * channels], count, channels, sample_rate);
        remaining -= count;
    }
}

fn renderDetailProbe(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    controller: u8,
    enabled: bool,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.controlChange(0, 64, 0);
    sampler.applyPianoDetailProfile(.dry);
    if (enabled) sampler.controlChange(0, controller, 64);
    @memset(output, 0);
    // Commit the CC profile in its own audio block before scheduling the
    // probe note. sfizz resolves trigger=release region eligibility from the
    // established controller state; co-scheduling the CC and note at delay 0
    // can leave CC20's sampled-release master on its previous value.
    discardFrames(sampler, block_frames);
    if (controller == 20 or controller == 21) {
        // Release and hammer layers are streamed release-triggered regions.
        // Prime the exact region once so this offline gate measures its PCM
        // rather than storage-thread startup latency.
        sampler.controlChange(0, controller, 64);
        discardFrames(sampler, block_frames);
        sampler.noteOn(0, 60, 92);
        discardFrames(sampler, @intFromFloat(0.12 * @as(f32, @floatFromInt(sample_rate))));
        sampler.noteOff(0, 60);
        discardFrames(sampler, @intFromFloat(1.0 * @as(f32, @floatFromInt(sample_rate))));
        sampler.allNotesOff();
        discardFrames(sampler, block_frames);
        sampler.controlChange(0, controller, if (enabled) 64 else 0);
        discardFrames(sampler, block_frames);
    }

    switch (controller) {
        20, 21 => {
            sampler.noteOn(0, 60, 92);
            discardFrames(sampler, @intFromFloat(0.35 * @as(f32, @floatFromInt(sample_rate))));
            sampler.noteOff(0, 60);
            renderFrames(sampler, output);
        },
        22 => {
            // Consume the profile before the pedal edges so this buffer
            // contains only the down/up mechanism, not a piano note.
            discardFrames(sampler, block_frames);
            const half = output.len / 2;
            sampler.controlChange(0, 64, 127);
            renderFrames(sampler, output[0..half]);
            sampler.controlChange(0, 64, 0);
            renderFrames(sampler, output[half..]);
        },
        23 => {
            sampler.controlChange(0, 64, 127);
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOn(0, pitch, 76);
            discardFrames(sampler, @intFromFloat(0.35 * @as(f32, @floatFromInt(sample_rate))));
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOff(0, pitch);
            renderFrames(sampler, output);
        },
        else => return error.UnsupportedDetailController,
    }
}

fn renderRepedalProbe(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    sfz_path: [:0]const u8,
    repedal: bool,
    output: []f32,
) !void {
    const sampler = try Sampler.create(allocator, library_paths, sfz_path);
    defer sampler.destroy();
    sampler.applyPianoDetailProfile(.dry);
    sampler.controlChange(0, 64, 0);
    discardFrames(sampler, block_frames);
    // Prime the streamed note tail and sfizz's repedal state machine once in
    // both comparison instances. This removes first-use disk timing from the
    // measured dry/caught decision.
    sampler.noteOn(0, 60, 92);
    discardFrames(sampler, @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate))));
    sampler.noteOff(0, 60);
    discardFrames(sampler, @intFromFloat(0.02 * @as(f32, @floatFromInt(sample_rate))));
    sampler.controlChange(0, 64, 127);
    discardFrames(sampler, @intFromFloat(1.0 * @as(f32, @floatFromInt(sample_rate))));
    sampler.controlChange(0, 64, 0);
    sampler.allNotesOff();
    discardFrames(sampler, @intFromFloat(0.1 * @as(f32, @floatFromInt(sample_rate))));

    sampler.noteOn(0, 60, 92);
    discardFrames(sampler, @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate))));
    sampler.noteOff(0, 60);
    // Catch the physically releasing strings before the one-second damped
    // off-time expires. A 20 ms gap is long enough to enter release while
    // remaining inside sfizz's deterministic repedal window.
    discardFrames(sampler, @intFromFloat(0.02 * @as(f32, @floatFromInt(sample_rate))));
    if (repedal) sampler.controlChange(0, 64, 127);
    renderFrames(sampler, output);
}

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const command = arguments.next() orelse return samplerUsage();
    if (std.mem.eql(u8, command, "verify")) return runVerify(init, &arguments);
    if (std.mem.eql(u8, command, "render")) return runRender(init, &arguments);
    if (std.mem.eql(u8, command, "render-score")) return runRenderScore(init, &arguments);
    if (std.mem.eql(u8, command, "inspect-pack")) return runInspectPack(init, &arguments);
    if (std.mem.eql(u8, command, "portable-pack")) return runPortablePack(init, &arguments);
    if (std.mem.eql(u8, command, "portable-verify")) return runPortableVerify(init, &arguments);
    return samplerUsage();
}

fn samplerUsage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  score-sampler-workbench verify [REPORT.json] [EVIDENCE.wav] [PIANO.sfz]
        \\  score-sampler-workbench render [OUTPUT.wav] [PIANO.sfz]
        \\  score-sampler-workbench render-score SCORE.mxl OUTPUT.wav [PIANO.sfz] [--start-beat N] [--end-beat N] [--tail-seconds N] [--quarter-bpm N] [--detail RELEASE:HAMMER:PEDAL_NOISE:RESONANCE]
        \\  score-sampler-workbench inspect-pack PIANO.sfz [REPORT.json]
        \\  score-sampler-workbench portable-pack PIANO.sfz OUTPUT.scorebank
        \\  score-sampler-workbench portable-verify BANK.scorebank [EVIDENCE.wav]
        \\
    , .{});
    return error.InvalidArguments;
}

fn renderPortableFrames(piano: *score.sample_bank.Piano, output: []f32, frame_cursor: *usize, frames: usize) ![]f32 {
    if (frame_cursor.* + frames > output.len / channels) return error.VerificationBufferTooSmall;
    const start = frame_cursor.* * channels;
    piano.renderInterleaved(output[start .. start + frames * channels], frames, channels, @floatFromInt(sample_rate));
    frame_cursor.* += frames;
    return output[start .. frame_cursor.* * channels];
}

fn portableTriggerRms(bank: score.sample_bank.View, trigger: score.sample_bank.Trigger) f32 {
    var sum_squares: f64 = 0;
    var sample_count: u64 = 0;
    for (0..bank.region_count) |index| {
        const region = bank.region(index) catch continue;
        if (region.trigger != trigger) continue;
        const descriptor = bank.sample(region.sample_index);
        const frames = @min(@as(usize, descriptor.frame_count), @as(usize, descriptor.sample_rate) / 4);
        for (0..frames) |frame| {
            const sample = bank.pcm(descriptor, frame);
            sum_squares += @as(f64, sample) * sample;
        }
        sample_count += frames;
    }
    return if (sample_count == 0) 0 else @floatCast(@sqrt(sum_squares / @as(f64, @floatFromInt(sample_count))));
}

fn runPortableVerify(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const bank_path = arguments.next() orelse return error.InvalidArguments;
    const evidence_path = arguments.next() orelse ".zig-cache/verification/portable-grand.wav";
    if (arguments.next() != null) return error.InvalidArguments;
    const bank_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, bank_path, init.gpa, .limited(score.sample_bank.max_bank_bytes));
    defer init.gpa.free(bank_bytes);
    const bank = try score.sample_bank.View.open(bank_bytes);
    if (bank.format_version != score.sample_bank.version) return error.PortablePackObsoleteFormat;
    var release_region_count: usize = 0;
    var hammer_region_count: usize = 0;
    var resonance_region_count: usize = 0;
    var pedal_down_region_count: usize = 0;
    var pedal_up_region_count: usize = 0;
    var authored_attack_envelopes: usize = 0;
    var authored_release_envelopes: usize = 0;
    var authored_filter_regions: usize = 0;
    for (0..bank.region_count) |index| {
        const region = try bank.region(index);
        switch (region.trigger) {
            .release => release_region_count += 1,
            .hammer_release => hammer_region_count += 1,
            .pedal_resonance => resonance_region_count += 1,
            .pedal_down => pedal_down_region_count += 1,
            .pedal_up => pedal_up_region_count += 1,
            .attack => {},
        }
        if (region.amp_attack_millis != score.sample_bank.envelope_millis_legacy) authored_attack_envelopes += 1;
        if (region.amp_release_millis != score.sample_bank.envelope_millis_legacy) authored_release_envelopes += 1;
        if (region.filter_type != .none) authored_filter_regions += 1;
    }
    if (release_region_count < 68 or hammer_region_count < 88 or resonance_region_count < 69 or pedal_down_region_count == 0 or pedal_up_region_count == 0) return error.PortablePackAcousticLayersMissing;
    if (authored_attack_envelopes < resonance_region_count or authored_release_envelopes < 704) return error.PortablePackEnvelopeDataMissing;
    const release_asset_rms = portableTriggerRms(bank, .release);
    const hammer_asset_rms = portableTriggerRms(bank, .hammer_release);
    const resonance_asset_rms = portableTriggerRms(bank, .pedal_resonance);
    if (release_asset_rms < 0.00001 or hammer_asset_rms < 0.00001 or resonance_asset_rms < 0.00001) return error.PortablePackAcousticLayerSilent;
    var key: u16 = portable_first_key;
    while (key <= portable_last_key) : (key += 1) for (portable_velocity_targets) |target| {
        var found = false;
        for (0..bank.region_count) |index| {
            const region = try bank.region(index);
            const encoded_center: u8 = @truncate(region.flags & score.sample_bank.region_flag_velocity_center_mask);
            if (region.trigger == .attack and key >= region.key_low and key <= region.key_high and encoded_center == target) {
                found = true;
                break;
            }
        }
        if (!found) return error.PortablePackVelocityCentersMissing;
    };
    var piano: score.sample_bank.Piano = .{};
    try piano.load(bank_bytes);

    const resonance_probe_frames = sample_rate / 2;
    const dry_probe = try init.gpa.alloc(f32, resonance_probe_frames * channels);
    defer init.gpa.free(dry_probe);
    const resonant_probe = try init.gpa.alloc(f32, resonance_probe_frames * channels);
    defer init.gpa.free(resonant_probe);
    var dry_piano: score.sample_bank.Piano = .{};
    try dry_piano.load(bank_bytes);
    dry_piano.noteOn(0, 60, 86);
    dry_piano.renderInterleaved(dry_probe, resonance_probe_frames, channels, @floatFromInt(sample_rate));
    var resonant_piano: score.sample_bank.Piano = .{};
    try resonant_piano.load(bank_bytes);
    // Set the already-consumed controller state directly so both probes start
    // with identical room/output histories; this isolates note resonance from
    // the separately verified pedal-down mechanism sample.
    resonant_piano.sustain[0] = 127;
    resonant_piano.noteOn(0, 60, 86);
    resonant_piano.renderInterleaved(resonant_probe, resonance_probe_frames, channels, @floatFromInt(sample_rate));
    const resonance_comparison = compareReplay(dry_probe, resonant_probe);
    if (resonance_comparison.max_abs_error < 0.00001 or resonance_comparison.normalized_rms_error < 0.0005) return error.PortablePackResonanceInactive;
    const total_frames = sample_rate * 7;
    const output = try init.gpa.alloc(f32, total_frames * channels);
    defer init.gpa.free(output);
    @memset(output, 0);
    var cursor: usize = 0;

    const low_start = cursor * channels;
    piano.noteOn(0, 60, 32);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 4 / 5);
    piano.noteOff(0, 60);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 2 / 5);
    const low_end = cursor * channels;
    piano.allNotesOff();
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate / 5);

    const high_start = cursor * channels;
    piano.noteOn(0, 60, 116);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 4 / 5);
    piano.noteOff(0, 60);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 2 / 5);
    const high_end = cursor * channels;
    piano.allNotesOff();
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate / 5);

    piano.controlChange(0, 64, 127);
    for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| piano.noteOn(0, pitch, 86);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate / 2);
    for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| piano.noteOff(0, pitch);
    const sustained_start = cursor * channels;
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 3 / 2);
    const sustained_end = cursor * channels;
    piano.controlChange(0, 64, 0);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate);

    piano.allNotesOff();
    _ = try renderPortableFrames(&piano, output, &cursor, 128);
    const mechanism_start = cursor * channels;
    piano.controlChange(0, 64, 127);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 3 / 10);
    piano.controlChange(0, 64, 0);
    _ = try renderPortableFrames(&piano, output, &cursor, sample_rate * 3 / 10);
    const mechanism_end = cursor * channels;
    _ = try renderPortableFrames(&piano, output, &cursor, total_frames - cursor);

    const low = score.audio_quality.analyze(output[low_start..low_end]);
    const high = score.audio_quality.analyze(output[high_start..high_end]);
    const sustained = score.audio_quality.analyze(output[sustained_start..sustained_end]);
    const mechanism = score.audio_quality.analyze(output[mechanism_start..mechanism_end]);
    const overall = score.audio_quality.analyze(output[0 .. cursor * channels]);
    const attack = score.audio_quality.attackLatency(output[high_start..high_end], channels, sample_rate, -42, 0.00002);
    if (overall.non_finite_samples != 0 or overall.clipped_samples != 0 or overall.peak < 0.01) return error.PortablePackInvalidSignal;
    if (!attack.audible or attack.milliseconds > 25) return error.PortablePackAttackTooLate;
    if (!(high.rms > low.rms * 1.08)) return error.PortablePackVelocityLayersCollapsed;
    if (sustained.rms < 0.0002) return error.PortablePackPedalTailMissing;
    if (mechanism.rms < 0.00001) return error.PortablePackPedalMechanismSilent;
    const wav_bytes = try score.wav.encodePcm16(init.gpa, output[0 .. cursor * channels], sample_rate, channels);
    defer init.gpa.free(wav_bytes);
    if (std.fs.path.dirname(evidence_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = evidence_path, .data = wav_bytes });
    std.log.info("portable bank v{d} verified: {d} samples / {d} regions ({d} release + {d} hammer + {d} resonance + pedal mechanisms; {d} attack + {d} release envelopes; {d} filtered regions) / layer RMS {d:.5}/{d:.5}/{d:.5} / resonance delta {d:.5} / peak {d:.3} / quiet {d:.2} dBFS / loud {d:.2} dBFS / sustain {d:.2} dBFS / mechanism {d:.2} dBFS / attack {d:.2} ms -> {s}", .{
        bank.format_version, piano.sampleCount(), piano.regionCount(), release_region_count, hammer_region_count, resonance_region_count, authored_attack_envelopes, authored_release_envelopes, authored_filter_regions, release_asset_rms, hammer_asset_rms, resonance_asset_rms, resonance_comparison.normalized_rms_error, overall.peak, low.rmsDbfs(), high.rmsDbfs(), sustained.rmsDbfs(), mechanism.rmsDbfs(), attack.milliseconds, evidence_path,
    });
}

const portable_velocity_targets = [_]u8{ 24, 36, 49, 61, 73, 88, 104, 124 };
const portable_first_key: u8 = 21;
const portable_last_key: u8 = 108;
const portable_last_damped_key: u8 = 88;
const portable_last_resonance_key: u8 = 89;
const portable_tail_seconds: f32 = 6.0;

fn portableVelocityRange(index: usize) struct { low: u8, high: u8 } {
    const low: u8 = if (index == 0) 1 else @intCast((@as(u16, portable_velocity_targets[index - 1]) + portable_velocity_targets[index]) / 2 + 1);
    const high: u8 = if (index + 1 == portable_velocity_targets.len) 127 else @intCast((@as(u16, portable_velocity_targets[index]) + portable_velocity_targets[index + 1]) / 2);
    return .{ .low = low, .high = high };
}

fn selectPortableZone(zones: []const score.instrument.Zone, trigger: score.instrument.Trigger, key: u8, velocity: u8) ?score.instrument.Zone {
    var nearest: ?score.instrument.Zone = null;
    var nearest_distance: u16 = std.math.maxInt(u16);
    for (zones) |zone| {
        if (zone.trigger != trigger or zone.detail_controller != 0 or key < zone.key_low or key > zone.key_high or zone.soft_low > 0) continue;
        if (velocity >= zone.velocity_low and velocity <= zone.velocity_high) return zone;
        const distance: u16 = if (velocity < zone.velocity_low) zone.velocity_low - velocity else velocity - zone.velocity_high;
        if (distance < nearest_distance) {
            nearest = zone;
            nearest_distance = distance;
        }
    }
    return nearest;
}

fn selectPortableDetailZone(zones: []const score.instrument.Zone, trigger: score.instrument.Trigger, controller: u8, key: u8, velocity: u8) ?score.instrument.Zone {
    var nearest: ?score.instrument.Zone = null;
    var nearest_distance: u16 = std.math.maxInt(u16);
    for (zones) |zone| {
        if (zone.trigger != trigger or zone.detail_controller != controller or 64 < zone.detail_low or 64 > zone.detail_high or key < zone.key_low or key > zone.key_high or zone.soft_low > 0) continue;
        if (velocity >= zone.velocity_low and velocity <= zone.velocity_high) return zone;
        const distance: u16 = if (velocity < zone.velocity_low) zone.velocity_low - velocity else velocity - zone.velocity_high;
        if (distance < nearest_distance) {
            nearest = zone;
            nearest_distance = distance;
        }
    }
    return nearest;
}

fn appendPortableZone(
    allocator: std.mem.Allocator,
    source_to_portable: []i32,
    selected_sources: *std.ArrayList(u32),
    portable_regions: *std.ArrayList(score.sample_bank.Region),
    source_zone: score.instrument.Zone,
    trigger: score.sample_bank.Trigger,
    key_low: u8,
    key_high: u8,
    velocity_low: u8,
    velocity_high: u8,
    velocity_center: u8,
    gain_adjust_db: f32,
) !void {
    var portable_index = source_to_portable[source_zone.sample_index];
    if (portable_index < 0) {
        portable_index = @intCast(selected_sources.items.len);
        source_to_portable[source_zone.sample_index] = portable_index;
        try selected_sources.append(allocator, source_zone.sample_index);
    }
    try portable_regions.append(allocator, .{
        .sample_index = @intCast(portable_index),
        .key_low = key_low,
        .key_high = key_high,
        .root_key = source_zone.root_key,
        .velocity_low = velocity_low,
        .velocity_high = velocity_high,
        .trigger = trigger,
        .soft_low = 0,
        .soft_high = 127,
        .tune_cents = source_zone.tune_cents,
        .gain_centibels = @intFromFloat(std.math.clamp((source_zone.gain_db + gain_adjust_db) * 100.0, -32768, 32767)),
        .pan_milli = @intFromFloat(std.math.clamp(source_zone.pan * 10.0, -1000, 1000)),
        .flags = velocity_center,
        .amp_attack_millis = portableEnvelopeMillis(source_zone.amp_attack_seconds),
        .amp_decay_millis = portableEnvelopeMillis(source_zone.amp_decay_seconds),
        .amp_release_millis = portableEnvelopeMillis(source_zone.amp_release_seconds),
        .amp_sustain_permille = portableSustainPermille(source_zone.amp_sustain_percent),
        .filter_cutoff_millihz = portableFilterCutoff(source_zone.filter_cutoff_hz),
        .filter_resonance_centibels = @intFromFloat(@round(std.math.clamp(source_zone.filter_resonance_db * 100, 0, 6000))),
        .filter_keytrack_cents = @intFromFloat(@round(std.math.clamp(source_zone.filter_keytrack_cents, -1200, 1200))),
        .filter_velocity_track_cents = @intFromFloat(@round(std.math.clamp(source_zone.filter_velocity_track_cents, -9600, 9600))),
        .filter_keycenter = source_zone.filter_keycenter,
        // SFZ permits a mode declaration before a later cutoff. A zone with no
        // actual cutoff remains sonically unfiltered in the portable bank.
        .filter_type = if (source_zone.filter_cutoff_hz == null) .none else portableFilterType(source_zone.filter_type),
    });
}

fn portableEnvelopeMillis(seconds: ?f32) u32 {
    const present = seconds orelse return score.sample_bank.envelope_millis_legacy;
    return @intFromFloat(@round(std.math.clamp(present * 1000, 0, @as(f32, @floatFromInt(std.math.maxInt(u32) - 1)))));
}

fn portableSustainPermille(percent: ?f32) u16 {
    const present = percent orelse return score.sample_bank.envelope_sustain_full;
    return @intFromFloat(@round(std.math.clamp(present * 10, 0, @as(f32, score.sample_bank.envelope_sustain_full))));
}

fn portableFilterCutoff(hertz: ?f32) u32 {
    const present = hertz orelse return score.sample_bank.filter_cutoff_disabled;
    return @intFromFloat(@round(std.math.clamp(present * 1000, 1, 192_000_000)));
}

fn portableFilterType(kind: score.instrument.FilterType) score.sample_bank.FilterType {
    return switch (kind) {
        .none => .none,
        .low_pass_1p => .low_pass_1p,
        .high_pass_1p => .high_pass_1p,
        .low_pass_2p => .low_pass_2p,
        .high_pass_2p => .high_pass_2p,
        .band_pass_2p => .band_pass_2p,
        .band_reject_2p => .band_reject_2p,
        .low_pass_4p => .low_pass_4p,
        .high_pass_4p => .high_pass_4p,
    };
}

fn firstAudibleFrame(samples: []const f32) usize {
    const search = @min(samples.len, 8192);
    for (samples[0..search], 0..) |sample, index| {
        if (@abs(sample) >= 0.00003) return index -| 96;
    }
    return 0;
}

/// Compile a licensed local SFZ into the path-free PCM bank consumed by the
/// browser and iOS real-time Zig sampler. Eight recorded velocity layers cover
/// every acoustic-piano key; sampled key-release and pedal-mechanism zones add
/// the physical noises that make practice playback respond like an instrument.
/// Duplicate source samples are stored once.
fn runPortablePack(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const sfz_path = arguments.next() orelse return error.InvalidArguments;
    const output_path = arguments.next() orelse return error.InvalidArguments;
    if (arguments.next() != null) return error.InvalidArguments;

    const sfz_bytes = try expandSfzSource(init, sfz_path);
    defer init.gpa.free(sfz_bytes);
    var imported = try score.instrument.parseSfz(init.gpa, sfz_bytes);
    defer imported.deinit();

    const source_to_portable = try init.gpa.alloc(i32, imported.samples.len);
    defer init.gpa.free(source_to_portable);
    @memset(source_to_portable, -1);
    var selected_sources: std.ArrayList(u32) = .empty;
    defer selected_sources.deinit(init.gpa);
    var portable_regions: std.ArrayList(score.sample_bank.Region) = .empty;
    defer portable_regions.deinit(init.gpa);

    var key: u16 = portable_first_key;
    while (key <= portable_last_key) : (key += 1) {
        for (portable_velocity_targets, 0..) |velocity, layer| {
            const source_zone = selectPortableZone(imported.zones, .attack, @intCast(key), velocity) orelse return error.PortablePackMissingKeyLayer;
            const range = portableVelocityRange(layer);
            try appendPortableZone(init.gpa, source_to_portable, &selected_sources, &portable_regions, source_zone, .attack, @intCast(key), @intCast(key), range.low, range.high, velocity, 0);
        }
        if (key <= portable_last_damped_key) {
            const release_zone = selectPortableDetailZone(imported.zones, .release, 20, @intCast(key), 88) orelse return error.PortablePackMissingReleaseLayer;
            try appendPortableZone(init.gpa, source_to_portable, &selected_sources, &portable_regions, release_zone, .release, @intCast(key), @intCast(key), 1, 127, 0, 0);
        }
        const hammer_zone = selectPortableDetailZone(imported.zones, .release, 21, @intCast(key), 88) orelse return error.PortablePackMissingHammerLayer;
        try appendPortableZone(init.gpa, source_to_portable, &selected_sources, &portable_regions, hammer_zone, .hammer_release, @intCast(key), @intCast(key), 1, 127, 0, 0);
        if (key <= portable_last_resonance_key) {
            const resonance_zone = selectPortableDetailZone(imported.zones, .attack, 23, @intCast(key), 2) orelse return error.PortablePackMissingResonanceLayer;
            try appendPortableZone(init.gpa, source_to_portable, &selected_sources, &portable_regions, resonance_zone, .pedal_resonance, @intCast(key), @intCast(key), 1, 127, 0, -18);
        }
    }
    for ([_]score.instrument.Trigger{ .pedal_down, .pedal_up }) |trigger| {
        const source_zone = selectPortableDetailZone(imported.zones, trigger, 22, 60, 127) orelse return error.PortablePackMissingPedalMechanism;
        try appendPortableZone(init.gpa, source_to_portable, &selected_sources, &portable_regions, source_zone, if (trigger == .pedal_down) .pedal_down else .pedal_up, 0, 127, 1, 127, 0, 0);
    }

    var descriptors = try init.gpa.alloc(score.sample_bank.Sample, selected_sources.items.len);
    defer init.gpa.free(descriptors);
    var pcm: std.Io.Writer.Allocating = .init(init.gpa);
    defer pcm.deinit();
    const sfz_directory = std.fs.path.dirname(sfz_path) orelse ".";
    var peak: f32 = 0;
    for (selected_sources.items, 0..) |source_index, portable_index| {
        const source = imported.samples[source_index];
        if (source.format != .wav) return error.PortablePackRequiresWav;
        const resolved_path = try std.fs.path.join(init.gpa, &.{ sfz_directory, source.path });
        defer init.gpa.free(resolved_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, resolved_path, init.gpa, .limited(max_sample_file_bytes));
        defer init.gpa.free(bytes);
        var decoded = try score.wav.decode(init.gpa, bytes);
        defer decoded.deinit();
        const start = firstAudibleFrame(decoded.samples);
        const maximum_frames: usize = @intFromFloat(@as(f32, @floatFromInt(decoded.sample_rate)) * portable_tail_seconds);
        const frame_count = @min(decoded.samples.len - start, maximum_frames);
        if (frame_count < 256) return error.PortablePackSampleTooShort;
        const data_offset = pcm.written().len;
        const fade_frames = @min(frame_count / 4, @as(usize, decoded.sample_rate) / 3);
        var encoded: [2]u8 = undefined;
        for (decoded.samples[start .. start + frame_count], 0..) |raw_sample, frame| {
            const fade = if (frame + fade_frames > frame_count)
                @as(f32, @floatFromInt(frame_count - frame)) / @as(f32, @floatFromInt(fade_frames))
            else
                1.0;
            const sample = raw_sample * fade;
            peak = @max(peak, @abs(sample));
            score.sample_bank.writePcm16(&encoded, 0, sample);
            try pcm.writer.writeAll(&encoded);
        }
        descriptors[portable_index] = .{
            .data_offset = @intCast(data_offset),
            .frame_count = @intCast(frame_count),
            .sample_rate = decoded.sample_rate,
            .loop_start = 0,
            .loop_end = 0,
        };
    }

    const sample_table_offset = score.sample_bank.header_size;
    const region_table_offset = sample_table_offset + descriptors.len * score.sample_bank.sample_descriptor_size;
    const pcm_offset = region_table_offset + portable_regions.items.len * score.sample_bank.region_descriptor_size;
    const total_size = pcm_offset + pcm.written().len;
    if (total_size > score.sample_bank.max_bank_bytes) return error.PortablePackTooLarge;
    const output = try init.gpa.alloc(u8, total_size);
    defer init.gpa.free(output);
    @memset(output, 0);
    score.sample_bank.writeHeader(output, @intCast(descriptors.len), @intCast(portable_regions.items.len), @intCast(sample_table_offset), @intCast(region_table_offset), @intCast(pcm_offset));
    for (descriptors, 0..) |descriptor, index| score.sample_bank.writeSample(output, sample_table_offset + index * score.sample_bank.sample_descriptor_size, descriptor);
    for (portable_regions.items, 0..) |region, index| score.sample_bank.writeRegion(output, region_table_offset + index * score.sample_bank.region_descriptor_size, region);
    @memcpy(output[pcm_offset..], pcm.written());
    _ = try score.sample_bank.View.open(output);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
    std.log.info("portable sampled grand: {d} source samples / {d} regions / {d:.1} MiB / peak {d:.3} -> {s}", .{
        descriptors.len,
        portable_regions.items.len,
        @as(f64, @floatFromInt(total_size)) / (1024 * 1024),
        peak,
        output_path,
    });
}

fn runInspectPack(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const sfz_path = arguments.next() orelse return error.InvalidArguments;
    const report_path = arguments.next() orelse ".zig-cache/verification/instrument-pack.json";
    if (arguments.next() != null) return error.InvalidArguments;

    const sfz_bytes = try expandSfzSource(init, sfz_path);
    defer init.gpa.free(sfz_bytes);
    var imported = try score.instrument.parseSfz(init.gpa, sfz_bytes);
    defer imported.deinit();
    const assets = try init.gpa.alloc(score.instrument.SampleAsset, imported.samples.len);
    defer init.gpa.free(assets);

    var issues: std.ArrayList(PackIssue) = .empty;
    defer issues.deinit(init.gpa);
    var pack_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var wav_count: usize = 0;
    var flac_count: usize = 0;
    var total_bytes: u64 = 0;
    const sfz_directory = std.fs.path.dirname(sfz_path) orelse ".";
    for (imported.samples, 0..) |sample, index| {
        const resolved_path = try std.fs.path.join(init.gpa, &.{ sfz_directory, sample.path });
        defer init.gpa.free(resolved_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, resolved_path, init.gpa, .limited(max_sample_file_bytes)) catch |err| {
            try issues.append(init.gpa, .{ .path = sample.path, .reason = @errorName(err) });
            continue;
        };
        defer init.gpa.free(bytes);
        const asset = score.instrument.inspectSampleBytes(bytes, .stream) catch |err| {
            try issues.append(init.gpa, .{ .path = sample.path, .reason = @errorName(err) });
            continue;
        };
        assets[index] = asset;
        total_bytes += bytes.len;
        switch (sample.format) {
            .wav => wav_count += 1,
            .flac => flac_count += 1,
        }
        pack_hasher.update(sample.path);
        pack_hasher.update(&asset.content_hash);
    }

    var digest: [32]u8 = undefined;
    pack_hasher.final(&digest);
    const valid = issues.items.len == 0;
    if (valid) _ = try imported.manifest(assets);

    var json: std.Io.Writer.Allocating = .init(init.gpa);
    defer json.deinit();
    const writer = &json.writer;
    try writer.writeAll("{\n  \"schema\": 1,\n  \"valid\": ");
    try writer.writeAll(if (valid) "true" else "false");
    try writer.writeAll(",\n  \"sfz\": ");
    try writeJsonString(writer, sfz_path);
    try writer.print(",\n  \"samples\": {d},\n  \"zones\": {d},\n  \"wav_samples\": {d},\n  \"flac_samples\": {d},\n  \"asset_bytes\": {d},\n  \"unsupported_opcodes\": {d},\n  \"pack_sha256\": \"", .{
        imported.samples.len,
        imported.zones.len,
        wav_count,
        flac_count,
        total_bytes,
        imported.unsupported_opcode_count,
    });
    for (digest) |byte| try writer.print("{x:0>2}", .{byte});
    try writer.writeAll("\",\n  \"issues\": [");
    for (issues.items, 0..) |issue, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, issue.path);
        try writer.writeAll(",\"reason\":");
        try writeJsonString(writer, issue.reason);
        try writer.writeAll("}");
    }
    try writer.writeAll("]\n}\n");
    if (std.fs.path.dirname(report_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = json.written() });
    std.log.info("instrument pack {s}: {d} samples / {d} zones / {d} issues; report {s}", .{
        if (valid) "valid" else "invalid",
        imported.samples.len,
        imported.zones.len,
        issues.items.len,
        report_path,
    });
    if (!valid) return error.InstrumentPackInvalid;
}

fn scoreEventLessThan(_: void, left: ScoreEvent, right: ScoreEvent) bool {
    if (left.frame != right.frame) return left.frame < right.frame;
    return @intFromEnum(left.kind) < @intFromEnum(right.kind);
}

fn scoreSecondsAtBeat(report: *const score.musicxml.ImportReport, requested_beat: f32) f32 {
    const beat = @max(0, requested_beat);
    if (beat == 0) return 0;
    const fallback_quarter = score.model.quarterTempoFromPulse(report.tempo_bpm, report.tempo_beat_unit);
    if (report.tempo_count == 0) return beat * 60.0 / @max(1, fallback_quarter);

    var seconds: f32 = 0;
    var cursor: f32 = 0;
    var current_bpm = @max(1, report.tempos[0].bpm);
    for (report.tempos[0..report.tempo_count]) |tempo| {
        const change_beat = std.math.clamp(tempo.start_beat, cursor, beat);
        if (change_beat > cursor) {
            seconds += (change_beat - cursor) * 60.0 / current_bpm;
            cursor = change_beat;
        }
        if (tempo.start_beat > beat) break;
        current_bpm = @max(1, tempo.bpm);
    }
    if (cursor < beat) seconds += (beat - cursor) * 60.0 / current_bpm;
    return seconds;
}

fn scoreFrameAtBeat(report: *const score.musicxml.ImportReport, start_seconds: f32, beat: f32) usize {
    const relative_seconds = @max(0, scoreSecondsAtBeat(report, beat) - start_seconds);
    return @intFromFloat(@round(relative_seconds * @as(f32, @floatFromInt(sample_rate))));
}

fn readScoreInto(init: std.process.Init, path: []const u8, report: *score.musicxml.ImportReport) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_score_file_bytes));
    defer init.gpa.free(bytes);
    if (std.mem.endsWith(u8, path, ".mxl")) {
        const xml = try score.mxl.extract(init.gpa, bytes);
        defer init.gpa.free(xml);
        return score.musicxml.parseInto(xml, report);
    }
    return score.musicxml.parseInto(bytes, report);
}

fn scorePedalController(pedal: u8) ?u8 {
    return switch (pedal) {
        score.model.pedal_sustain => 64,
        score.model.pedal_sostenuto => 66,
        score.model.pedal_soft => 67,
        else => null,
    };
}

fn parseDetailProfile(value: []const u8) !PianoDetailProfile {
    var fields = std.mem.splitScalar(u8, value, ':');
    const sampled_release = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const hammer_noise = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const pedal_noise = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    const pedal_resonance = try std.fmt.parseInt(u8, fields.next() orelse return error.InvalidDetailProfile, 10);
    if (fields.next() != null or sampled_release > 127 or hammer_noise > 127 or pedal_noise > 127 or pedal_resonance > 127) return error.InvalidDetailProfile;
    return .{
        .sampled_release = sampled_release,
        .hammer_noise = hammer_noise,
        .pedal_noise = pedal_noise,
        .pedal_resonance = pedal_resonance,
    };
}

fn runRenderScore(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const score_path = arguments.next() orelse return error.InvalidArguments;
    const output_path = arguments.next() orelse return error.InvalidArguments;
    var sfz_path: [:0]const u8 = "local-content/instruments/AccurateSalamanderGrandPianoV6.2beta2/sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz";
    var start_beat: f32 = 0;
    var end_beat: f32 = 42;
    var tail_seconds: f32 = 2.5;
    var quarter_bpm_override: ?f32 = null;
    var detail_profile = PianoDetailProfile.studio;
    var sfz_seen = false;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--start-beat")) {
            start_beat = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--end-beat")) {
            end_beat = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--tail-seconds")) {
            tail_seconds = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--quarter-bpm")) {
            quarter_bpm_override = try std.fmt.parseFloat(f32, arguments.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, argument, "--detail")) {
            detail_profile = try parseDetailProfile(arguments.next() orelse return error.MissingValue);
        } else if (!sfz_seen and !std.mem.startsWith(u8, argument, "--")) {
            sfz_path = argument;
            sfz_seen = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (!std.math.isFinite(start_beat) or !std.math.isFinite(end_beat) or !std.math.isFinite(tail_seconds) or start_beat < 0 or end_beat <= start_beat or tail_seconds < 0) return error.InvalidArguments;
    if (quarter_bpm_override) |bpm| if (!std.math.isFinite(bpm) or bpm <= 0) return error.InvalidArguments;

    const report = try init.gpa.create(score.musicxml.ImportReport);
    defer init.gpa.destroy(report);
    try readScoreInto(init, score_path, report);
    if (quarter_bpm_override) |bpm| {
        report.tempo_count = 1;
        report.tempos[0] = .{ .start_beat = 0, .bpm = bpm };
    }
    const start_seconds = scoreSecondsAtBeat(report, start_beat);
    const range_seconds = scoreSecondsAtBeat(report, end_beat) - start_seconds;
    if (range_seconds <= 0) return error.InvalidArguments;

    var events: std.ArrayList(ScoreEvent) = .empty;
    defer events.deinit(init.gpa);
    var scheduled_notes: usize = 0;
    for (report.notes[0..report.note_count]) |note| {
        if ((note.flags & (score.model.note_flag_rest | score.model.note_flag_vocal_guide)) != 0) continue;
        const note_end = note.start_beat + @max(0.001, note.duration_beats);
        if (note.start_beat < start_beat or note.start_beat >= end_beat or note_end <= start_beat) continue;
        try events.append(init.gpa, .{
            .frame = scoreFrameAtBeat(report, start_seconds, note.start_beat),
            .kind = .note_on,
            .pitch_or_controller = note.pitch,
            .value = @max(1, note.velocity),
        });
        try events.append(init.gpa, .{
            .frame = scoreFrameAtBeat(report, start_seconds, @min(end_beat, note_end)),
            .kind = .note_off,
            .pitch_or_controller = note.pitch,
            .value = 64,
        });
        scheduled_notes += 1;
    }
    for (report.pedals[0..report.pedal_count]) |pedal| {
        if (pedal.start_beat < start_beat or pedal.start_beat >= end_beat) continue;
        const controller = scorePedalController(pedal.pedal) orelse continue;
        const pedal_frame = scoreFrameAtBeat(report, start_seconds, pedal.start_beat);
        if (pedal.action == score.model.pedal_action_change and pedal.value != 0) {
            // MusicXML change-pedal is an up/down repedal. Give sfizz one
            // millisecond of rendered controller-up state so damped voices
            // are actually released before the pedal is depressed again.
            try events.append(init.gpa, .{
                .frame = pedal_frame,
                .kind = .control_change,
                .pitch_or_controller = controller,
                .value = 0,
            });
        }
        try events.append(init.gpa, .{
            .frame = pedal_frame + if (pedal.action == score.model.pedal_action_change and pedal.value != 0) sample_rate / 1000 else 0,
            .kind = .control_change,
            .pitch_or_controller = controller,
            .value = pedal.value,
        });
    }
    std.mem.sort(ScoreEvent, events.items, {}, scoreEventLessThan);

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();
    sampler.applyPianoDetailProfile(detail_profile);
    sampler.controlChange(0, 64, 0);
    sampler.controlChange(0, 66, 0);
    sampler.controlChange(0, 67, 0);

    const musical_frames: usize = @intFromFloat(@ceil(range_seconds * @as(f32, @floatFromInt(sample_rate))));
    const tail_frames: usize = @intFromFloat(@ceil(tail_seconds * @as(f32, @floatFromInt(sample_rate))));
    const frame_count = musical_frames + tail_frames;
    const output = try init.gpa.alloc(f32, frame_count * channels);
    defer init.gpa.free(output);
    @memset(output, 0);

    var event_index: usize = 0;
    var frame: usize = 0;
    while (frame < frame_count) {
        while (event_index < events.items.len and events.items[event_index].frame <= frame) : (event_index += 1) {
            const event = events.items[event_index];
            switch (event.kind) {
                .control_change => sampler.controlChange(0, event.pitch_or_controller, event.value),
                .note_off => sampler.noteOff(0, event.pitch_or_controller),
                .note_on => sampler.noteOn(0, event.pitch_or_controller, event.value),
            }
        }
        const next_event_frame = if (event_index < events.items.len) @min(frame_count, events.items[event_index].frame) else frame_count;
        const count = @min(block_frames, @max(@as(usize, 1), next_event_frame - frame));
        sampler.renderInterleaved(output[frame * channels .. (frame + count) * channels], count, channels, sample_rate);
        frame += count;
    }

    const encoded = try score.wav.encodePcm16(init.gpa, output, sample_rate, channels);
    defer init.gpa.free(encoded);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });
    const stats = score.audio_quality.analyze(output);
    std.log.info(
        "rendered score {s} -> {s}: beats={d:.3}..{d:.3} seconds={d:.3} notes={d} pedals={d} detail={d}:{d}:{d}:{d} peak={d:.2}dBFS overloads={d} limited_frames={d} invalid_output={d}",
        .{ score_path, output_path, start_beat, end_beat, range_seconds, scheduled_notes, report.pedal_count, detail_profile.sampled_release, detail_profile.hammer_noise, detail_profile.pedal_noise, detail_profile.pedal_resonance, stats.peakDbfs(), sampler.overloadedSampleCount(), sampler.limitedFrameCount(), sampler.invalidOutputSampleCount() },
    );
}

fn runRender(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const output_path = arguments.next() orelse ".zig-cache/verification/salamander-grand-proof.wav";
    const sfz_path = arguments.next() orelse "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    if (arguments.next() != null) return error.TooManyArguments;

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();

    const frame_count = @as(usize, sample_rate) * proof_seconds;
    const output = try init.gpa.alloc(f32, frame_count * channels);
    defer init.gpa.free(output);
    @memset(output, 0);

    sampler.controlChange(0, 64, 112);
    const phrase = [_]u8{ 36, 48, 55, 60, 64, 67, 72, 76, 79, 84 };
    var next_note: usize = 0;
    var pedal_released = false;
    var chord_started = false;
    var chord_released = false;
    var frame: usize = 0;
    while (frame < frame_count) {
        while (next_note < phrase.len and frame >= next_note * sample_rate / 2) : (next_note += 1) {
            sampler.noteOn(0, phrase[next_note], @intCast(38 + next_note * 8));
            if (next_note >= 3) sampler.noteOff(0, phrase[next_note - 3]);
        }
        if (!pedal_released and frame >= sample_rate * 6) {
            pedal_released = true;
            sampler.controlChange(0, 64, 0);
            for (phrase) |pitch| sampler.noteOff(0, pitch);
        }
        if (!chord_started and frame >= sample_rate * 7) {
            chord_started = true;
            for ([_]u8{ 48, 55, 60, 64, 67 }, 0..) |pitch, index| sampler.noteOn(0, pitch, @intCast(58 + index * 6));
        }
        if (!chord_released and frame >= sample_rate * 9) {
            chord_released = true;
            for ([_]u8{ 48, 55, 60, 64, 67 }) |pitch| sampler.noteOff(0, pitch);
        }
        const count = @min(block_frames, frame_count - frame);
        sampler.renderInterleaved(output[frame * channels .. (frame + count) * channels], count, channels, sample_rate);
        frame += count;
    }

    const encoded = try score.wav.encodePcm16(init.gpa, output, sample_rate, channels);
    defer init.gpa.free(encoded);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });
    std.log.info("rendered {s}: {d} regions, {d} preloaded samples", .{ output_path, sampler.region_count, sampler.preloaded_sample_count });
}

fn runVerify(init: std.process.Init, arguments: *std.process.Args.Iterator) !void {
    const report_path = arguments.next() orelse ".zig-cache/verification/sampler-quality.json";
    const wav_path = arguments.next() orelse ".zig-cache/verification/sampler-quality.wav";
    const sfz_path = arguments.next() orelse "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    if (arguments.next() != null) return error.TooManyArguments;

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();

    const output = try init.gpa.alloc(f32, output_seconds * sample_rate * channels);
    defer init.gpa.free(output);
    @memset(output, 0);
    var harness = Harness{ .sampler = sampler, .output = output };
    var gate: Gate = .{};
    const continuous_pedal_profile = std.mem.indexOf(u8, sfz_path, "AccurateSalamander") != null and std.mem.indexOf(u8, sfz_path, "/sfz_live/") != null;

    const baseline = score.audio_quality.analyze(try harness.seconds(0.2));
    gate.require(baseline.rms < 0.000001, "idle output is not silent");

    const velocities = [_]u8{ 8, 24, 40, 56, 72, 88, 104, 120 };
    var velocity_stats: [velocities.len]score.audio_quality.Stats = undefined;
    for (velocities, 0..) |velocity, index| {
        try harness.reset();
        sampler.noteOn(0, 60, velocity);
        velocity_stats[index] = score.audio_quality.analyze(try harness.seconds(0.32));
        sampler.noteOff(0, 60);
        _ = try harness.seconds(0.28);
    }
    var rising_steps: usize = 0;
    for (velocity_stats[1..], 0..) |stats, index| {
        if (stats.rms > velocity_stats[index].rms * 1.015) rising_steps += 1;
    }
    const velocity_range_db = score.audio_quality.ratioDb(velocity_stats[velocity_stats.len - 1].rms, velocity_stats[0].rms);
    gate.require(rising_steps >= 5, "velocity layers are not sufficiently monotonic");
    gate.require(velocity_range_db >= 12, "velocity response has insufficient dynamic range");

    try harness.reset();
    sampler.controlChange(0, 22, 127);
    sampler.noteOn(0, 60, 96);
    _ = try harness.seconds(0.35);
    sampler.controlChange(0, 64, 127);
    sampler.noteOff(0, 60);
    const sustain_hold = score.audio_quality.analyze(try harness.seconds(0.85));
    sampler.controlChange(0, 64, 0);
    const sustain_release_full = try harness.seconds(1.4);
    const release_tail_start = sustain_release_full.len * 2 / 3;
    const sustain_release_tail = score.audio_quality.analyze(sustain_release_full[release_tail_start..]);
    const sustain_release_db = score.audio_quality.ratioDb(sustain_hold.rms, sustain_release_tail.rms);
    gate.require(sustain_hold.rms > 0.0001, "sustain pedal did not hold audible energy");
    gate.require(sustain_release_db >= 2.5, "pedal-up did not produce a measurable release decay");

    // Accurate-Salamander documents an explicit Disklavier-calibrated curve:
    // 0/32 are dry, 42/54/62 are progressively half-pedaled, and 64+ is full.
    const pedal_values = [_]u8{ 0, 32, 42, 54, 62, 64, 127 };
    var pedal_curve_stats: [pedal_values.len]score.audio_quality.Stats = undefined;
    for (pedal_values, 0..) |value, index| pedal_curve_stats[index] = try pedalReleaseProbe(&harness, value);
    const pedal_up_release = pedal_curve_stats[0];
    const pedal_half_release = pedal_curve_stats[3];
    const pedal_full_release = pedal_curve_stats[pedal_curve_stats.len - 1];
    if (continuous_pedal_profile) {
        gate.require(pedal_curve_stats[1].rms <= pedal_up_release.rms * 1.15, "documented dry pedal range changed release unexpectedly");
        gate.require(pedal_half_release.rms > pedal_up_release.rms * 1.15, "half pedal does not extend release over pedal-up");
        gate.require(pedal_curve_stats[5].rms > pedal_half_release.rms * 1.15, "full-pedal threshold is not measurably longer than half pedal");
        gate.require(pedal_full_release.rms >= pedal_curve_stats[5].rms * 0.85, "full pedal loses release energy above its threshold");
    }

    const detail_controllers = [_]u8{ 20, 21, 22, 23 };
    var detail_comparisons = [_]ReplayComparison{.{
        .bit_exact = true,
        .max_abs_error = 0,
        .normalized_rms_error = 0,
        .correlation = 1,
    }} ** detail_controllers.len;
    if (continuous_pedal_profile) {
        const detail_frames: usize = @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate)));
        const detail_dry = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(detail_dry);
        const detail_enabled = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(detail_enabled);
        const best_detail_dry = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(best_detail_dry);
        const best_detail_enabled = try init.gpa.alloc(f32, detail_frames * channels);
        defer init.gpa.free(best_detail_enabled);
        for (detail_controllers, 0..) |controller, index| {
            var best: ReplayComparison = .{ .bit_exact = true, .max_abs_error = 0, .normalized_rms_error = 0, .correlation = 1 };
            for (0..3) |attempt| {
                try renderDetailProbe(init.gpa, &library_paths, sfz_path, controller, false, detail_dry);
                try renderDetailProbe(init.gpa, &library_paths, sfz_path, controller, true, detail_enabled);
                const candidate = compareReplay(detail_dry, detail_enabled);
                if (attempt == 0 or candidate.max_abs_error > best.max_abs_error) {
                    best = candidate;
                    @memcpy(best_detail_dry, detail_dry);
                    @memcpy(best_detail_enabled, detail_enabled);
                }
                if (candidate.max_abs_error > 0.000001 and candidate.normalized_rms_error > 0.0005) break;
            }
            detail_comparisons[index] = best;
            // These are deliberately modest machine gates: they prove the
            // named acoustic layer changes real PCM. Audible balance remains
            // a separate listening acceptance step.
            gate.require(detail_comparisons[index].max_abs_error > 0.000001, "enabled piano detail layer did not change rendered PCM");
            gate.require(detail_comparisons[index].normalized_rms_error > 0.0005, "enabled piano detail layer is below the measurable floor");
            try harness.append(best_detail_dry);
            try harness.append(best_detail_enabled);
        }
    }

    var repedal_comparison: ReplayComparison = .{
        .bit_exact = true,
        .max_abs_error = 0,
        .normalized_rms_error = 0,
        .correlation = 1,
    };
    var repedal_dry_stats: score.audio_quality.Stats = score.audio_quality.analyze(&.{});
    var repedal_caught_stats: score.audio_quality.Stats = score.audio_quality.analyze(&.{});
    if (continuous_pedal_profile) {
        const repedal_frames: usize = @intFromFloat(0.8 * @as(f32, @floatFromInt(sample_rate)));
        const repedal_dry = try init.gpa.alloc(f32, repedal_frames * channels);
        defer init.gpa.free(repedal_dry);
        const repedal_caught = try init.gpa.alloc(f32, repedal_frames * channels);
        defer init.gpa.free(repedal_caught);
        try renderRepedalProbe(init.gpa, &library_paths, sfz_path, false, repedal_dry);
        try renderRepedalProbe(init.gpa, &library_paths, sfz_path, true, repedal_caught);
        repedal_dry_stats = score.audio_quality.analyze(repedal_dry);
        repedal_caught_stats = score.audio_quality.analyze(repedal_caught);
        repedal_comparison = compareReplay(repedal_dry, repedal_caught);
        gate.require(repedal_caught_stats.rms > repedal_dry_stats.rms * 1.15, "repedaling did not catch and extend the releasing note");
        gate.require(repedal_comparison.normalized_rms_error > 0.0005, "repedaling did not measurably change rendered PCM");
        try harness.append(repedal_dry);
        try harness.append(repedal_caught);
    }

    // Disable optional random/mechanical layers and render each attack through
    // a fresh engine. Reusing one sampler would compare a new note against the
    // first note's live release tail and advanced round-robin state, which is
    // not an identical initial condition and made this gate nondeterministic.
    const deterministic_frames: usize = @intFromFloat(0.22 * @as(f32, @floatFromInt(sample_rate)));
    const deterministic_a = try init.gpa.alloc(f32, deterministic_frames * channels);
    defer init.gpa.free(deterministic_a);
    const deterministic_b = try init.gpa.alloc(f32, deterministic_frames * channels);
    defer init.gpa.free(deterministic_b);
    try renderDeterministicAttack(init.gpa, &library_paths, sfz_path, deterministic_a);
    try renderDeterministicAttack(init.gpa, &library_paths, sfz_path, deterministic_b);
    const replay_comparison = compareReplay(deterministic_a, deterministic_b);
    const attack_latency = score.audio_quality.attackLatency(deterministic_a, channels, sample_rate, -60, 0.000001);
    const spectral_a = score.audio_quality.spectralFingerprint(deterministic_a, channels, sample_rate);
    const spectral_b = score.audio_quality.spectralFingerprint(deterministic_b, channels, sample_rate);
    const spectral_distance = score.audio_quality.spectralDistance(spectral_a, spectral_b);
    const deterministic_replay = replay_comparison.bit_exact;
    const stable_midi_replay = replay_comparison.correlation >= 0.90 and replay_comparison.normalized_rms_error <= 0.50;
    std.log.info("MIDI replay comparison: exact={} max_error={d:.8} normalized_rms_error={d:.8} correlation={d:.8}", .{
        deterministic_replay,
        replay_comparison.max_abs_error,
        replay_comparison.normalized_rms_error,
        replay_comparison.correlation,
    });
    gate.require(score.audio_quality.analyze(deterministic_a).rms > 0.0001, "nonzero MIDI channel rendered silence");
    gate.require(stable_midi_replay, "identical MIDI attack replay is not stable");
    gate.require(attack_latency.audible, "MIDI attack has no measurable audible onset");
    gate.require(attack_latency.audible and attack_latency.milliseconds <= 35, "sample attack latency exceeds 35 ms");
    gate.require(spectral_a.total_energy > 0 and std.math.isFinite(spectral_a.centroid_hz), "MIDI attack has no measurable spectral fingerprint");
    gate.require(spectral_distance <= 0.40, "fresh MIDI attacks have unstable spectral balance");

    try harness.reset();
    sampler.controlChange(0, 22, 127);
    sampler.controlChange(0, 64, 0);
    _ = try harness.seconds(0.08);
    sampler.controlChange(0, 64, 127);
    const pedal_down = score.audio_quality.analyze(try harness.seconds(0.35));
    sampler.controlChange(0, 64, 0);
    const pedal_up = score.audio_quality.analyze(try harness.seconds(0.35));
    gate.require(@max(pedal_down.rms, pedal_up.rms) > 0.00001, "pedal mechanical samples are silent");

    try harness.reset();
    const scheduled_dropped_before = sampler.droppedEventCount();
    const scheduled_late_before = sampler.lateEventCount();
    for (0..24) |index| {
        const scheduled_pitch: u8 = @intCast(48 + index % 12);
        const delay = @as(f32, @floatFromInt(index)) * 0.0017;
        sampler.noteOnDelayed(0, scheduled_pitch, 28, delay);
        sampler.noteOffDelayed(0, scheduled_pitch, delay + 0.045);
    }
    const scheduled_stress = score.audio_quality.analyze(try harness.seconds(0.18));
    const scheduled_dropped_delta = sampler.droppedEventCount() - scheduled_dropped_before;
    const scheduled_late_delta = sampler.lateEventCount() - scheduled_late_before;
    gate.require(scheduled_dropped_delta == 0, "sample-accurate timing queue dropped scheduled events");
    gate.require(scheduled_late_delta == 0, "sample-accurate timing queue delivered future events late");
    gate.require(scheduled_stress.rms > 0.00001, "scheduled timing stress rendered silence");

    try harness.reset();
    const dropped_before = sampler.droppedEventCount();
    const overloaded_before = sampler.overloadedSampleCount();
    const limited_before = sampler.limitedFrameCount();
    const invalid_before = sampler.invalidOutputSampleCount();
    var pitch: u8 = 36;
    while (pitch <= 92) : (pitch += 4) sampler.noteOn(0, pitch, 52);
    const stress = score.audio_quality.analyze(try harness.seconds(0.7));
    pitch = 36;
    while (pitch <= 92) : (pitch += 4) sampler.noteOff(0, pitch);
    _ = try harness.seconds(0.5);
    const dropped_delta = sampler.droppedEventCount() - dropped_before;
    const overloaded_delta = sampler.overloadedSampleCount() - overloaded_before;
    const limited_delta = sampler.limitedFrameCount() - limited_before;
    const invalid_delta = sampler.invalidOutputSampleCount() - invalid_before;
    gate.require(dropped_delta == 0, "real-time event queue dropped MIDI events");
    gate.require(overloaded_delta == 0, "stress chord overloaded the unclamped mix");
    gate.require(invalid_delta == 0, "master stage repaired non-finite sampler output");
    gate.require(stress.rms > 0.0001, "stress chord rendered silence");

    const complete = score.audio_quality.analyze(harness.rendered());
    gate.require(complete.non_finite_samples == 0, "render contains NaN or infinity");
    gate.require(complete.clipped_samples == 0, "render contains clipped PCM samples");

    const pcm = try score.wav.encodePcm16(init.gpa, harness.rendered(), sample_rate, channels);
    defer init.gpa.free(pcm);
    if (std.fs.path.dirname(wav_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = wav_path, .data = pcm });

    var json: std.Io.Writer.Allocating = .init(init.gpa);
    defer json.deinit();
    const writer = &json.writer;
    try writer.print(
        "{{\n  \"schema\": 3,\n  \"passed\": {s},\n  \"instrument\": \"{s}\",\n  \"regions\": {d},\n  \"preloaded_samples\": {d},\n  \"sample_rate\": {d},\n  \"rendered_frames\": {d},\n",
        .{ if (gate.passed) "true" else "false", sfz_path, sampler.region_count, sampler.preloaded_sample_count, sample_rate, harness.frame_cursor },
    );
    try writer.print("  \"complete\": {{\"peak_dbfs\":{d:.3},\"rms_dbfs\":{d:.3},\"dc\":{d:.8},\"non_finite\":{d},\"clipped\":{d}}},\n", .{ complete.peakDbfs(), complete.rmsDbfs(), complete.dc, complete.non_finite_samples, complete.clipped_samples });
    try writer.writeAll("  \"velocity_sweep\": [");
    for (velocities, 0..) |velocity, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"velocity\":{d},\"peak_dbfs\":{d:.3},\"rms_dbfs\":{d:.3}}}", .{ velocity, velocity_stats[index].peakDbfs(), velocity_stats[index].rmsDbfs() });
    }
    try writer.print("],\n  \"velocity_rising_steps\": {d},\n  \"velocity_range_db\": {d:.3},\n", .{ rising_steps, velocity_range_db });
    try writer.writeAll("  \"pedal\": {\"hold_rms_dbfs\":");
    try writeJsonFloat(writer, sustain_hold.rmsDbfs());
    try writer.writeAll(",\"release_tail_rms_dbfs\":");
    try writeJsonFloat(writer, sustain_release_tail.rmsDbfs());
    try writer.writeAll(",\"hold_release_db\":");
    try writeJsonFloat(writer, sustain_release_db);
    try writer.writeAll(",\"down_noise_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_down.rmsDbfs());
    try writer.writeAll(",\"up_noise_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_up.rmsDbfs());
    try writer.print(",\"continuous_profile\":{s},\"up_release_rms_dbfs\":", .{if (continuous_pedal_profile) "true" else "false"});
    try writeJsonFloat(writer, pedal_up_release.rmsDbfs());
    try writer.writeAll(",\"half_release_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_half_release.rmsDbfs());
    try writer.writeAll(",\"full_release_rms_dbfs\":");
    try writeJsonFloat(writer, pedal_full_release.rmsDbfs());
    try writer.writeAll(",\"curve\":[");
    for (pedal_values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"cc64\":{d},\"release_rms_dbfs\":", .{value});
        try writeJsonFloat(writer, pedal_curve_stats[index].rmsDbfs());
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
    try writer.writeAll("},\n");
    const detail_names = [_][]const u8{ "sampled_release", "hammer_noise", "pedal_noise", "pedal_resonance" };
    try writer.print("  \"piano_detail_profile\": {{\"available\":{s},\"layers\":[", .{if (continuous_pedal_profile) "true" else "false"});
    for (detail_names, detail_comparisons, 0..) |name, comparison, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"changes_pcm\":{s},\"max_abs_error\":{d:.8},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}}", .{
            name,
            if (!comparison.bit_exact) "true" else "false",
            comparison.max_abs_error,
            comparison.normalized_rms_error,
            comparison.correlation,
        });
    }
    try writer.writeAll("]},\n");
    try writer.writeAll("  \"repedaling\": {\"dry_rms_dbfs\":");
    try writeJsonFloat(writer, repedal_dry_stats.rmsDbfs());
    try writer.writeAll(",\"caught_rms_dbfs\":");
    try writeJsonFloat(writer, repedal_caught_stats.rmsDbfs());
    try writer.print(",\"changes_pcm\":{s},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}},\n", .{
        if (!repedal_comparison.bit_exact) "true" else "false",
        repedal_comparison.normalized_rms_error,
        repedal_comparison.correlation,
    });
    try writer.print(
        "  \"deterministic_midi_replay\": {s},\n  \"midi_replay\": {{\"stable\":{s},\"bit_exact\":{s},\"max_abs_error\":{d:.8},\"normalized_rms_error\":{d:.8},\"correlation\":{d:.8}}},\n",
        .{
            if (deterministic_replay) "true" else "false",
            if (stable_midi_replay) "true" else "false",
            if (deterministic_replay) "true" else "false",
            replay_comparison.max_abs_error,
            replay_comparison.normalized_rms_error,
            replay_comparison.correlation,
        },
    );
    try writer.print("  \"attack_latency\": {{\"audible\":{s},\"frame\":{d},\"milliseconds\":{d:.3},\"threshold\":{d:.8},\"peak\":{d:.8}}},\n", .{
        if (attack_latency.audible) "true" else "false",
        attack_latency.frame_index,
        attack_latency.milliseconds,
        attack_latency.threshold,
        attack_latency.peak,
    });
    try writer.writeAll("  \"spectral_fingerprint\": {\"centroid_hz\":");
    try writeJsonFloat(writer, spectral_a.centroid_hz);
    try writer.print(",\"fresh_attack_distance\":{d:.6},\"bands\":[", .{spectral_distance});
    for (score.audio_quality.spectral_band_centers_hz, spectral_a.normalized_energy, 0..) |frequency, energy, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"center_hz\":{d:.0},\"normalized_energy\":{d:.8}}}", .{ frequency, energy });
    }
    try writer.writeAll("]},\n");
    try writer.print("  \"scheduled_timing\": {{\"rms_dbfs\":{d:.3},\"dropped_events\":{d},\"late_events\":{d}}},\n", .{ scheduled_stress.rmsDbfs(), scheduled_dropped_delta, scheduled_late_delta });
    try writer.print("  \"stress\": {{\"rms_dbfs\":{d:.3},\"dropped_events\":{d},\"overloaded_samples\":{d},\"limited_frames\":{d},\"invalid_output_samples\":{d}}},\n  \"evidence_pcm_crc32\": \"{x:0>8}\",\n  \"failures\": [", .{ stress.rmsDbfs(), dropped_delta, overloaded_delta, limited_delta, invalid_delta, std.hash.crc.Crc32.hash(pcm) });
    for (gate.failures[0..gate.failure_count], 0..) |failure, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("\"{s}\"", .{failure});
    }
    try writer.writeAll("]\n}\n");
    if (std.fs.path.dirname(report_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = json.written() });

    std.log.info("sampler verification {s}: {s}; {d} regions / {d} samples", .{ if (gate.passed) "passed" else "failed", report_path, sampler.region_count, sampler.preloaded_sample_count });
    if (!gate.passed) return error.SamplerQualityGateFailed;
}
