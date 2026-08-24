const std = @import("std");
const effects = @import("effects.zig");

/// Compact, read-only sample bank shared by the WebAudio worklet and the iOS
/// AVAudio callback. The format intentionally contains no paths or platform
/// objects: a normalized region table is followed by little-endian PCM16.
pub const magic = "SCBNK001";
pub const version: u32 = 2;
pub const header_size: usize = 32;
pub const sample_descriptor_size: usize = 20;
pub const region_descriptor_size: usize = 20;
pub const max_bank_bytes: usize = 256 * 1024 * 1024;
pub const max_samples: usize = 1024;
pub const max_regions: usize = 4096;
pub const max_voices: usize = 128;
pub const region_flag_velocity_center_mask: u16 = 0x00ff;

pub const Trigger = enum(u8) {
    attack = 0,
    release = 1,
    pedal_down = 2,
    pedal_up = 3,
    hammer_release = 4,
    pedal_resonance = 5,
};

pub const Sample = struct {
    data_offset: u32,
    frame_count: u32,
    sample_rate: u32,
    loop_start: u32,
    loop_end: u32,
};

pub const Region = struct {
    sample_index: u32,
    key_low: u8,
    key_high: u8,
    root_key: u8,
    velocity_low: u8,
    velocity_high: u8,
    trigger: Trigger,
    soft_low: u8,
    soft_high: u8,
    tune_cents: i16,
    gain_centibels: i16,
    pan_milli: i16,
    flags: u16,
};

pub const View = struct {
    bytes: []const u8,
    sample_count: usize,
    region_count: usize,
    sample_table_offset: usize,
    region_table_offset: usize,
    pcm_offset: usize,

    pub fn open(bytes: []const u8) !View {
        if (bytes.len < header_size or bytes.len > max_bank_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidSampleBank;
        if (readU32(bytes, 8) != version) return error.UnsupportedSampleBank;
        const sample_count: usize = readU32(bytes, 12);
        const region_count: usize = readU32(bytes, 16);
        const sample_table_offset: usize = readU32(bytes, 20);
        const region_table_offset: usize = readU32(bytes, 24);
        const pcm_offset: usize = readU32(bytes, 28);
        if (sample_count == 0 or sample_count > max_samples or region_count == 0 or region_count > max_regions) return error.InvalidSampleBank;
        if (sample_table_offset < header_size or region_table_offset < sample_table_offset or pcm_offset < region_table_offset) return error.InvalidSampleBank;
        if (sample_descriptor_size * sample_count > region_table_offset - sample_table_offset) return error.InvalidSampleBank;
        if (region_descriptor_size * region_count > pcm_offset - region_table_offset or pcm_offset > bytes.len) return error.InvalidSampleBank;
        const view: View = .{
            .bytes = bytes,
            .sample_count = sample_count,
            .region_count = region_count,
            .sample_table_offset = sample_table_offset,
            .region_table_offset = region_table_offset,
            .pcm_offset = pcm_offset,
        };
        for (0..sample_count) |index| {
            const descriptor = view.sample(index);
            if (descriptor.sample_rate < 4_000 or descriptor.sample_rate > 384_000 or descriptor.frame_count < 2) return error.InvalidSampleBank;
            const start = @as(usize, descriptor.data_offset);
            const byte_count = @as(usize, descriptor.frame_count) * 2;
            if (start > bytes.len - pcm_offset or byte_count > bytes.len - pcm_offset - start) return error.InvalidSampleBank;
            if ((descriptor.loop_start != 0 or descriptor.loop_end != 0) and (descriptor.loop_start >= descriptor.loop_end or descriptor.loop_end > descriptor.frame_count)) return error.InvalidSampleBank;
        }
        for (0..region_count) |index| {
            const zone = try view.region(index);
            if (zone.sample_index >= sample_count or zone.key_low > zone.key_high or zone.velocity_low > zone.velocity_high or zone.soft_low > zone.soft_high) return error.InvalidSampleBank;
        }
        return view;
    }

    pub fn sample(self: View, index: usize) Sample {
        std.debug.assert(index < self.sample_count);
        const offset = self.sample_table_offset + index * sample_descriptor_size;
        return .{
            .data_offset = readU32(self.bytes, offset),
            .frame_count = readU32(self.bytes, offset + 4),
            .sample_rate = readU32(self.bytes, offset + 8),
            .loop_start = readU32(self.bytes, offset + 12),
            .loop_end = readU32(self.bytes, offset + 16),
        };
    }

    pub fn region(self: View, index: usize) !Region {
        if (index >= self.region_count) return error.InvalidRegionIndex;
        const offset = self.region_table_offset + index * region_descriptor_size;
        if (self.bytes[offset + 9] > @intFromEnum(Trigger.pedal_resonance)) return error.InvalidSampleBank;
        const trigger: Trigger = @enumFromInt(self.bytes[offset + 9]);
        return .{
            .sample_index = readU32(self.bytes, offset),
            .key_low = self.bytes[offset + 4],
            .key_high = self.bytes[offset + 5],
            .root_key = self.bytes[offset + 6],
            .velocity_low = self.bytes[offset + 7],
            .velocity_high = self.bytes[offset + 8],
            .trigger = trigger,
            .soft_low = self.bytes[offset + 10],
            .soft_high = self.bytes[offset + 11],
            .tune_cents = readI16(self.bytes, offset + 12),
            .gain_centibels = readI16(self.bytes, offset + 14),
            .pan_milli = readI16(self.bytes, offset + 16),
            .flags = readU16(self.bytes, offset + 18),
        };
    }

    pub fn pcm(self: View, descriptor: Sample, frame: usize) f32 {
        if (frame >= descriptor.frame_count) return 0;
        const offset = self.pcm_offset + @as(usize, descriptor.data_offset) + frame * 2;
        return @as(f32, @floatFromInt(readI16(self.bytes, offset))) / 32768.0;
    }
};

const Event = extern struct { kind: u8, key: u8, value: u8, channel: u8 };
const event_capacity = 1024;

const Voice = struct {
    sample_index: u32 = 0,
    position: f64 = 0,
    increment: f64 = 1,
    gain_left: f32 = 0,
    gain_right: f32 = 0,
    envelope: f32 = 0,
    pitch: u8 = 0,
    velocity: u8 = 0,
    channel: u8 = 0,
    key_down: bool = false,
    sustain_latched: bool = false,
    sostenuto_latched: bool = false,
    releasing: bool = false,
    one_shot: bool = false,
    active: bool = false,
    age: u64 = 0,
    last_left: f32 = 0,
    last_right: f32 = 0,
    steal_left: f32 = 0,
    steal_right: f32 = 0,
};

const VelocityBlend = struct {
    lower: ?Region = null,
    upper: ?Region = null,
    lower_gain: f32 = 0,
    upper_gain: f32 = 0,
};

const StereoRoom = struct {
    left: [4096]f32 = [_]f32{0} ** 4096,
    right: [4096]f32 = [_]f32{0} ** 4096,
    cursor: usize = 0,

    fn reset(self: *StereoRoom) void {
        @memset(&self.left, 0);
        @memset(&self.right, 0);
        self.cursor = 0;
    }

    fn process(self: *StereoRoom, dry_left: f32, dry_right: f32, wet: f32) [2]f32 {
        const read_left = (self.cursor + 4096 - 3343) % 4096;
        const read_right = (self.cursor + 4096 - 3677) % 4096;
        const room_left = self.left[read_left];
        const room_right = self.right[read_right];
        self.left[self.cursor] = dry_left + room_right * 0.57;
        self.right[self.cursor] = dry_right + room_left * 0.59;
        self.cursor = (self.cursor + 1) % 4096;
        return .{ dry_left + room_left * wet, dry_right + room_right * wet };
    }
};

/// Allocation-free portable sampled instrument. Loading validates one immutable
/// bank; the audio callback only consumes a lock-free event queue and reads it.
pub const Piano = struct {
    bank: ?View = null,
    events: [event_capacity]Event = undefined,
    write_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dropped_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
    voice_age: u64 = 1,
    sustain: [16]u8 = [_]u8{0} ** 16,
    sostenuto: [16]u8 = [_]u8{0} ** 16,
    soft: [16]u8 = [_]u8{0} ** 16,
    click_phase: f32 = 0,
    click_envelope: f32 = 0,
    click_frequency: f32 = 1320,
    click_gain: f32 = 0,
    room: StereoRoom = .{},
    output_chain: effects.StereoOutputChain = effects.StereoOutputChain.init(48_000),
    configured_sample_rate: f32 = 48_000,

    pub fn load(self: *Piano, bytes: []const u8) !void {
        const replacement = try View.open(bytes);
        self.discardQueuedEvents();
        self.allNotesOffImmediate();
        self.bank = replacement;
    }

    pub fn unload(self: *Piano) void {
        self.discardQueuedEvents();
        self.bank = null;
        self.allNotesOffImmediate();
    }

    pub fn isLoaded(self: *const Piano) bool {
        return self.bank != null;
    }
    pub fn sampleCount(self: *const Piano) usize {
        return if (self.bank) |bank| bank.sample_count else 0;
    }
    pub fn regionCount(self: *const Piano) usize {
        return if (self.bank) |bank| bank.region_count else 0;
    }

    pub fn noteOn(self: *Piano, channel: u8, pitch: u8, velocity: u8) void {
        self.enqueue(.{ .kind = 1, .key = pitch, .value = velocity, .channel = channel & 0x0f });
    }
    pub fn noteOff(self: *Piano, channel: u8, pitch: u8) void {
        self.enqueue(.{ .kind = 0, .key = pitch, .value = 0, .channel = channel & 0x0f });
    }
    pub fn allNotesOff(self: *Piano) void {
        self.enqueue(.{ .kind = 2, .key = 0, .value = 0, .channel = 0 });
    }
    pub fn click(self: *Piano, accent: bool) void {
        self.enqueue(.{ .kind = 3, .key = 0, .value = if (accent) 127 else 86, .channel = 0 });
    }
    pub fn controlChange(self: *Piano, channel: u8, controller: u8, value: u8) void {
        self.enqueue(.{ .kind = 4, .key = controller, .value = value, .channel = channel & 0x0f });
    }

    pub fn renderStereo(self: *Piano, left: []f32, right: []f32, sample_rate: f32) void {
        std.debug.assert(left.len == right.len);
        self.consumeEvents(sample_rate);
        @memset(left, 0);
        @memset(right, 0);
        if (sample_rate <= 0) return;
        if (@abs(sample_rate - self.configured_sample_rate) > 1) {
            self.configured_sample_rate = sample_rate;
            self.output_chain = .init(sample_rate);
            self.room.reset();
        }
        const click_decay = @exp(-1.0 / (sample_rate * 0.045));
        const steal_decay = @exp(-1.0 / (sample_rate * 0.0035));
        for (left, right) |*left_sample, *right_sample| {
            var mixed_left: f32 = 0;
            var mixed_right: f32 = 0;
            if (self.bank) |bank| for (&self.voices) |*voice| {
                if (!voice.active) continue;
                const sample = bank.sample(voice.sample_index);
                const frame: usize = @intFromFloat(voice.position);
                if (frame + 1 >= sample.frame_count) {
                    voice.active = false;
                    continue;
                }
                const fraction: f32 = @floatCast(voice.position - @floor(voice.position));
                const a = bank.pcm(sample, frame);
                const b = bank.pcm(sample, frame + 1);
                const value = a + (b - a) * fraction;
                voice.position += voice.increment;
                if (voice.one_shot) {
                    voice.envelope += (1 - voice.envelope) * 0.04;
                } else if (voice.key_down) {
                    voice.envelope += (1 - voice.envelope) * 0.016;
                } else if (voice.sustain_latched or voice.sostenuto_latched) {
                    const pedal = @as(f32, @floatFromInt(self.sustain[voice.channel])) / 127.0;
                    voice.envelope *= @exp(-1.0 / (sample_rate * (7 + pedal * 18)));
                } else {
                    voice.releasing = true;
                    const half = @as(f32, @floatFromInt(@min(self.sustain[voice.channel], 63))) / 63.0;
                    voice.envelope *= @exp(-1.0 / (sample_rate * (0.22 + half * half * 1.8)));
                }
                if (voice.envelope < 0.00008) {
                    voice.active = false;
                    continue;
                }
                const main_left = value * voice.gain_left * voice.envelope;
                const main_right = value * voice.gain_right * voice.envelope;
                mixed_left += main_left + voice.steal_left;
                mixed_right += main_right + voice.steal_right;
                voice.last_left = main_left + voice.steal_left;
                voice.last_right = main_right + voice.steal_right;
                voice.steal_left *= steal_decay;
                voice.steal_right *= steal_decay;
                if (@abs(voice.steal_left) < 0.000001) voice.steal_left = 0;
                if (@abs(voice.steal_right) < 0.000001) voice.steal_right = 0;
            };
            if (self.click_envelope > 0.0004) {
                self.click_phase += self.click_frequency / sample_rate;
                if (self.click_phase >= 1) self.click_phase -= @floor(self.click_phase);
                const angle = self.click_phase * std.math.tau;
                const tone = (@sin(angle) + 0.34 * @sin(angle * 2.7)) * self.click_gain * self.click_envelope;
                mixed_left += tone;
                mixed_right += tone;
                self.click_envelope *= click_decay;
            } else self.click_envelope = 0;
            var sustain_sum: u16 = 0;
            for (self.sustain) |value| sustain_sum += value;
            const wet = 0.075 + @as(f32, @floatFromInt(sustain_sum)) / (16 * 127) * 0.12;
            const room = self.room.process(mixed_left * 0.24, mixed_right * 0.24, wet);
            left_sample.* = room[0];
            right_sample.* = room[1];
        }
        self.output_chain.post_instrument.process(left, right);
        _ = self.output_chain.master.process(left, right);
    }

    pub fn renderInterleaved(self: *Piano, output: []f32, frame_count: usize, channels: usize, sample_rate: f32) void {
        if (channels == 0 or output.len < frame_count * channels) return;
        var left: [256]f32 = undefined;
        var right: [256]f32 = undefined;
        var cursor: usize = 0;
        while (cursor < frame_count) {
            const count = @min(left.len, frame_count - cursor);
            self.renderStereo(left[0..count], right[0..count], sample_rate);
            for (0..count) |frame| {
                output[(cursor + frame) * channels] = left[frame];
                if (channels > 1) output[(cursor + frame) * channels + 1] = right[frame];
                for (2..channels) |channel| output[(cursor + frame) * channels + channel] = (left[frame] + right[frame]) * 0.5;
            }
            cursor += count;
        }
    }

    fn enqueue(self: *Piano, event: Event) void {
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % event_capacity;
        if (next == self.read_index.load(.acquire)) {
            _ = self.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        self.events[write] = event;
        self.write_index.store(next, .release);
    }

    fn discardQueuedEvents(self: *Piano) void {
        self.read_index.store(self.write_index.load(.acquire), .release);
    }

    fn consumeEvents(self: *Piano, sample_rate: f32) void {
        var read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        while (read != write) {
            self.apply(self.events[read], sample_rate);
            read = (read + 1) % event_capacity;
        }
        self.read_index.store(read, .release);
    }

    fn apply(self: *Piano, event: Event, sample_rate: f32) void {
        switch (event.kind) {
            0 => self.releaseKey(event.channel, event.key, sample_rate),
            1 => self.startVoice(event.channel, event.key, event.value, sample_rate),
            2 => self.allNotesOffImmediate(),
            3 => {
                self.click_phase = 0;
                self.click_envelope = 1;
                self.click_frequency = if (event.value >= 120) 1760 else 1320;
                self.click_gain = if (event.value >= 120) 0.82 else 0.56;
            },
            4 => self.applyControlChange(event.channel, event.key, event.value, sample_rate),
            else => {},
        }
    }

    fn startVoice(self: *Piano, channel: u8, pitch: u8, velocity: u8, sample_rate: f32) void {
        const blend = self.selectAttackBlend(pitch, @max(velocity, 1), self.soft[channel]) orelse return;
        if (blend.lower) |region| self.startRegionVoice(region, .attack, channel, pitch, velocity, sample_rate, blend.lower_gain);
        if (blend.upper) |region| self.startRegionVoice(region, .attack, channel, pitch, velocity, sample_rate, blend.upper_gain);
        if (self.sustain[channel] >= 22) {
            const scaled: u16 = @as(u16, velocity) * self.sustain[channel] / 127;
            self.startTriggeredVoice(.pedal_resonance, channel, pitch, @intCast(@max(scaled, 1)), sample_rate);
        }
    }

    fn startTriggeredVoice(self: *Piano, trigger: Trigger, channel: u8, pitch: u8, velocity: u8, sample_rate: f32) void {
        const region = self.selectRegion(trigger, pitch, @max(velocity, 1), self.soft[channel]) orelse return;
        self.startRegionVoice(region, trigger, channel, pitch, velocity, sample_rate, 1);
    }

    fn startRegionVoice(self: *Piano, region: Region, trigger: Trigger, channel: u8, pitch: u8, velocity: u8, sample_rate: f32, layer_gain: f32) void {
        if (layer_gain <= 0.0001) return;
        const bank = self.bank orelse return;
        const sample = bank.sample(region.sample_index);
        const slot = self.acquireVoice();
        const steal_left = if (slot.active) slot.last_left else 0;
        const steal_right = if (slot.active) slot.last_right else 0;
        const semitones = @as(f64, @floatFromInt(@as(i16, pitch) - @as(i16, region.root_key))) + @as(f64, @floatFromInt(region.tune_cents)) / 100.0;
        const increment = @as(f64, @floatFromInt(sample.sample_rate)) / @as(f64, sample_rate) * std.math.pow(f64, 2, semitones / 12.0);
        const velocity_gain = std.math.sqrt(@as(f32, @floatFromInt(velocity)) / 127.0);
        const region_gain = std.math.pow(f32, 10, @as(f32, @floatFromInt(region.gain_centibels)) / 2000.0);
        const soft_gain = 1 - 0.22 * (@as(f32, @floatFromInt(self.soft[channel])) / 127.0);
        const pan = std.math.clamp(@as(f32, @floatFromInt(region.pan_milli)) / 1000.0 + (@as(f32, @floatFromInt(pitch)) - 64) / 160.0, -0.85, 0.85);
        slot.* = .{
            .sample_index = region.sample_index,
            .position = 0,
            .increment = increment,
            .gain_left = velocity_gain * layer_gain * region_gain * soft_gain * std.math.sqrt((1 - pan) * 0.5),
            .gain_right = velocity_gain * layer_gain * region_gain * soft_gain * std.math.sqrt((1 + pan) * 0.5),
            .envelope = 0,
            .pitch = pitch,
            .velocity = velocity,
            .channel = channel,
            .key_down = trigger == .attack or trigger == .pedal_resonance,
            .one_shot = trigger != .attack and trigger != .pedal_resonance,
            .age = self.voice_age,
            .active = true,
            .steal_left = steal_left,
            .steal_right = steal_right,
        };
        self.voice_age +%= 1;
    }

    fn acquireVoice(self: *Piano) *Voice {
        var candidate = &self.voices[0];
        for (&self.voices) |*voice| {
            if (!voice.active) return voice;
            if (shouldStealBefore(voice, candidate)) candidate = voice;
        }
        return candidate;
    }

    fn shouldStealBefore(candidate: *const Voice, current: *const Voice) bool {
        const candidate_class = stealClass(candidate);
        const current_class = stealClass(current);
        if (candidate_class != current_class) return candidate_class < current_class;
        if (candidate.envelope != current.envelope) return candidate.envelope < current.envelope;
        return candidate.age < current.age;
    }

    fn stealClass(voice: *const Voice) u8 {
        if (voice.one_shot) return 0;
        if (!voice.key_down and !voice.sustain_latched and !voice.sostenuto_latched) return 1;
        if (!voice.key_down) return 2;
        return 3;
    }

    fn regionVelocityCenter(region: Region) u8 {
        const encoded: u8 = @truncate(region.flags & region_flag_velocity_center_mask);
        if (encoded >= 1 and encoded <= 127) return encoded;
        return @intCast((@as(u16, region.velocity_low) + region.velocity_high) / 2);
    }

    fn selectAttackBlend(self: *const Piano, pitch: u8, velocity: u8, soft: u8) ?VelocityBlend {
        const bank = self.bank orelse return null;
        var lower: ?Region = null;
        var upper: ?Region = null;
        var lower_center: i16 = -1;
        var upper_center: i16 = 256;
        for (0..bank.region_count) |index| {
            const region = bank.region(index) catch continue;
            if (region.trigger != .attack or pitch < region.key_low or pitch > region.key_high or soft < region.soft_low or soft > region.soft_high) continue;
            const center: i16 = regionVelocityCenter(region);
            if (center <= velocity and center > lower_center) {
                lower = region;
                lower_center = center;
            }
            if (center >= velocity and center < upper_center) {
                upper = region;
                upper_center = center;
            }
        }
        if (lower == null and upper == null) return null;
        if (lower == null) return .{ .lower = upper, .lower_gain = 1 };
        if (upper == null or lower_center == upper_center) return .{ .lower = lower, .lower_gain = 1 };
        const position = @as(f32, @floatFromInt(@as(i16, velocity) - lower_center)) / @as(f32, @floatFromInt(upper_center - lower_center));
        return .{
            .lower = lower,
            .upper = upper,
            .lower_gain = std.math.sqrt(1 - position),
            .upper_gain = std.math.sqrt(position),
        };
    }

    fn releaseKey(self: *Piano, channel: u8, pitch: u8, sample_rate: f32) void {
        var release_velocity: u8 = 0;
        for (&self.voices) |*voice| if (voice.active and voice.channel == channel and voice.pitch == pitch) {
            if (voice.one_shot) continue;
            release_velocity = @max(release_velocity, voice.velocity);
            voice.key_down = false;
            voice.sustain_latched = self.sustain[channel] >= 64;
            voice.releasing = !voice.sustain_latched and !voice.sostenuto_latched;
        };
        // A held damper pedal prevents the key damper from contacting the
        // string, so sampled key-release noise starts only when the damper is
        // currently available. Pedal-up has its own mechanism sample.
        if (release_velocity != 0 and self.sustain[channel] < 64) {
            self.startTriggeredVoice(.release, channel, pitch, release_velocity, sample_rate);
            self.startTriggeredVoice(.hammer_release, channel, pitch, release_velocity, sample_rate);
        }
    }

    fn selectRegion(self: *const Piano, trigger: Trigger, pitch: u8, velocity: u8, soft: u8) ?Region {
        const bank = self.bank orelse return null;
        var best: ?Region = null;
        var best_distance: u16 = std.math.maxInt(u16);
        for (0..bank.region_count) |index| {
            const region = bank.region(index) catch continue;
            if (region.trigger != trigger or pitch < region.key_low or pitch > region.key_high or soft < region.soft_low or soft > region.soft_high) continue;
            if (velocity >= region.velocity_low and velocity <= region.velocity_high) return region;
            const distance: u16 = if (velocity < region.velocity_low) region.velocity_low - velocity else velocity - region.velocity_high;
            if (distance < best_distance) {
                best = region;
                best_distance = distance;
            }
        }
        return best;
    }

    fn applyControlChange(self: *Piano, channel: u8, controller: u8, value: u8, sample_rate: f32) void {
        switch (controller) {
            64 => {
                const was_down = self.sustain[channel] >= 64;
                self.sustain[channel] = value;
                if (!was_down and value >= 64) {
                    self.startTriggeredVoice(.pedal_down, channel, 60, 127, sample_rate);
                    for (&self.voices) |*voice| if (voice.active and voice.channel == channel and !voice.key_down and !voice.sostenuto_latched) {
                        voice.sustain_latched = true;
                        voice.releasing = false;
                    };
                } else {
                    if (was_down and value < 64) self.startTriggeredVoice(.pedal_up, channel, 60, 127, sample_rate);
                    self.updateUnheld(channel);
                }
            },
            66 => {
                const was_down = self.sostenuto[channel] >= 64;
                self.sostenuto[channel] = value;
                if (!was_down and value >= 64) {
                    for (&self.voices) |*voice| if (voice.active and voice.channel == channel and voice.key_down) {
                        voice.sostenuto_latched = true;
                    };
                } else if (was_down and value < 64) {
                    for (&self.voices) |*voice| if (voice.active and voice.channel == channel) {
                        voice.sostenuto_latched = false;
                    };
                    self.updateUnheld(channel);
                }
            },
            67 => self.soft[channel] = value,
            120, 123 => {
                for (&self.voices) |*voice| if (voice.active and voice.channel == channel) {
                    voice.key_down = false;
                    voice.sustain_latched = false;
                    voice.sostenuto_latched = false;
                    voice.releasing = true;
                };
                self.sustain[channel] = 0;
                self.sostenuto[channel] = 0;
            },
            else => {},
        }
    }

    fn updateUnheld(self: *Piano, channel: u8) void {
        for (&self.voices) |*voice| if (voice.active and voice.channel == channel and !voice.key_down and !voice.sostenuto_latched) {
            voice.sustain_latched = self.sustain[channel] >= 64;
            voice.releasing = !voice.sustain_latched;
        };
    }

    fn allNotesOffImmediate(self: *Piano) void {
        for (&self.voices) |*voice| voice.* = .{};
        self.sustain = [_]u8{0} ** 16;
        self.sostenuto = [_]u8{0} ** 16;
        self.soft = [_]u8{0} ** 16;
        self.click_envelope = 0;
        self.room.reset();
        self.output_chain.reset();
    }
};

pub fn writeHeader(output: []u8, sample_count: u32, region_count: u32, sample_table_offset: u32, region_table_offset: u32, pcm_offset: u32) void {
    std.debug.assert(output.len >= header_size);
    @memcpy(output[0..8], magic);
    writeU32(output, 8, version);
    writeU32(output, 12, sample_count);
    writeU32(output, 16, region_count);
    writeU32(output, 20, sample_table_offset);
    writeU32(output, 24, region_table_offset);
    writeU32(output, 28, pcm_offset);
}

pub fn writeSample(output: []u8, offset: usize, sample: Sample) void {
    writeU32(output, offset, sample.data_offset);
    writeU32(output, offset + 4, sample.frame_count);
    writeU32(output, offset + 8, sample.sample_rate);
    writeU32(output, offset + 12, sample.loop_start);
    writeU32(output, offset + 16, sample.loop_end);
}

pub fn writeRegion(output: []u8, offset: usize, region: Region) void {
    writeU32(output, offset, region.sample_index);
    output[offset + 4] = region.key_low;
    output[offset + 5] = region.key_high;
    output[offset + 6] = region.root_key;
    output[offset + 7] = region.velocity_low;
    output[offset + 8] = region.velocity_high;
    output[offset + 9] = @intFromEnum(region.trigger);
    output[offset + 10] = region.soft_low;
    output[offset + 11] = region.soft_high;
    writeI16(output, offset + 12, region.tune_cents);
    writeI16(output, offset + 14, region.gain_centibels);
    writeI16(output, offset + 16, region.pan_milli);
    writeU16(output, offset + 18, region.flags);
}

pub fn writePcm16(output: []u8, offset: usize, sample: f32) void {
    const value: i16 = @intFromFloat(std.math.clamp(sample, -1, 0.999969) * 32768);
    writeI16(output, offset, value);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn readI16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(readU16(bytes, offset));
}
fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}
fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}
fn writeI16(bytes: []u8, offset: usize, value: i16) void {
    writeU16(bytes, offset, @bitCast(value));
}
fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn testBank(allocator: std.mem.Allocator) ![]u8 {
    const sample_table = header_size;
    const region_table = sample_table + sample_descriptor_size;
    const pcm_offset = region_table + region_descriptor_size;
    const bytes = try allocator.alloc(u8, pcm_offset + 256 * 2);
    @memset(bytes, 0);
    writeHeader(bytes, 1, 1, sample_table, region_table, pcm_offset);
    writeSample(bytes, sample_table, .{ .data_offset = 0, .frame_count = 256, .sample_rate = 48_000, .loop_start = 0, .loop_end = 0 });
    writeRegion(bytes, region_table, .{ .sample_index = 0, .key_low = 0, .key_high = 127, .root_key = 69, .velocity_low = 1, .velocity_high = 127, .trigger = .attack, .soft_low = 0, .soft_high = 127, .tune_cents = 0, .gain_centibels = 0, .pan_milli = 0, .flags = 0 });
    for (0..256) |frame| writePcm16(bytes, pcm_offset + frame * 2, @sin(@as(f32, @floatFromInt(frame)) * std.math.tau * 440 / 48_000));
    return bytes;
}

fn testTriggerBank(allocator: std.mem.Allocator) ![]u8 {
    const sample_table = header_size;
    const region_table = sample_table + sample_descriptor_size;
    const region_count = 6;
    const pcm_offset = region_table + region_descriptor_size * region_count;
    const bytes = try allocator.alloc(u8, pcm_offset + 256 * 2);
    @memset(bytes, 0);
    writeHeader(bytes, 1, region_count, sample_table, region_table, pcm_offset);
    writeSample(bytes, sample_table, .{ .data_offset = 0, .frame_count = 256, .sample_rate = 48_000, .loop_start = 0, .loop_end = 0 });
    for ([_]Trigger{ .attack, .release, .pedal_down, .pedal_up, .hammer_release, .pedal_resonance }, 0..) |trigger, index| {
        writeRegion(bytes, region_table + index * region_descriptor_size, .{ .sample_index = 0, .key_low = 0, .key_high = 127, .root_key = 69, .velocity_low = 1, .velocity_high = 127, .trigger = trigger, .soft_low = 0, .soft_high = 127, .tune_cents = 0, .gain_centibels = 0, .pan_milli = 0, .flags = 0 });
    }
    for (0..256) |frame| writePcm16(bytes, pcm_offset + frame * 2, @sin(@as(f32, @floatFromInt(frame)) * std.math.tau * 440 / 48_000));
    return bytes;
}

fn testVelocityBank(allocator: std.mem.Allocator) ![]u8 {
    const sample_table = header_size;
    const region_table = sample_table + sample_descriptor_size;
    const region_count = 2;
    const pcm_offset = region_table + region_descriptor_size * region_count;
    const bytes = try allocator.alloc(u8, pcm_offset + 256 * 2);
    @memset(bytes, 0);
    writeHeader(bytes, 1, region_count, sample_table, region_table, pcm_offset);
    writeSample(bytes, sample_table, .{ .data_offset = 0, .frame_count = 256, .sample_rate = 48_000, .loop_start = 0, .loop_end = 0 });
    writeRegion(bytes, region_table, .{ .sample_index = 0, .key_low = 60, .key_high = 60, .root_key = 60, .velocity_low = 1, .velocity_high = 63, .trigger = .attack, .soft_low = 0, .soft_high = 127, .tune_cents = 0, .gain_centibels = 0, .pan_milli = 0, .flags = 32 });
    writeRegion(bytes, region_table + region_descriptor_size, .{ .sample_index = 0, .key_low = 60, .key_high = 60, .root_key = 60, .velocity_low = 64, .velocity_high = 127, .trigger = .attack, .soft_low = 0, .soft_high = 127, .tune_cents = 0, .gain_centibels = 0, .pan_milli = 0, .flags = 96 });
    for (0..256) |frame| writePcm16(bytes, pcm_offset + frame * 2, @sin(@as(f32, @floatFromInt(frame)) * std.math.tau * 261.626 / 48_000));
    return bytes;
}

test "sample bank validates and portable piano renders sampled audio" {
    const bytes = try testBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const view = try View.open(bytes);
    try std.testing.expectEqual(@as(usize, 1), view.sample_count);
    var piano: Piano = .{};
    try piano.load(bytes);
    piano.noteOn(0, 69, 100);
    var left: [128]f32 = undefined;
    var right: [128]f32 = undefined;
    piano.renderStereo(&left, &right, 48_000);
    var energy: f32 = 0;
    for (left) |sample| energy += @abs(sample);
    try std.testing.expect(energy > 0.01);
    var right_energy: f32 = 0;
    for (right) |sample| right_energy += @abs(sample);
    try std.testing.expect(right_energy > 0.01);
}

test "portable piano applies sustain and pedal release" {
    const bytes = try testBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);
    var left: [32]f32 = undefined;
    var right: [32]f32 = undefined;
    piano.noteOn(0, 60, 90);
    piano.controlChange(0, 64, 127);
    piano.noteOff(0, 60);
    piano.renderStereo(&left, &right, 48_000);
    try std.testing.expect(piano.voices[0].sustain_latched);
    piano.controlChange(0, 64, 0);
    piano.renderStereo(&left, &right, 48_000);
    try std.testing.expect(!piano.voices[0].active or !piano.voices[0].sustain_latched);
    try std.testing.expect(piano.voices[0].releasing or !piano.voices[0].active);
}

test "sample-bank hot swap rejects invalid data without losing the live bank" {
    const bytes = try testBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);
    const invalid = [_]u8{0} ** header_size;
    try std.testing.expectError(error.InvalidSampleBank, piano.load(&invalid));
    try std.testing.expect(piano.isLoaded());
    try std.testing.expectEqual(@as(usize, 1), piano.sampleCount());
}

test "sample-bank hot swap discards events queued for the previous instrument" {
    const bytes = try testBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);
    piano.noteOn(0, 69, 127);
    try piano.load(bytes);
    var left: [32]f32 = undefined;
    var right: [32]f32 = undefined;
    piano.renderStereo(&left, &right, 48_000);
    for (left, right) |left_sample, right_sample| {
        try std.testing.expectEqual(@as(f32, 0), left_sample);
        try std.testing.expectEqual(@as(f32, 0), right_sample);
    }
}

test "portable piano plays sampled key release and pedal mechanisms" {
    const bytes = try testTriggerBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);
    var left: [32]f32 = undefined;
    var right: [32]f32 = undefined;
    piano.noteOn(0, 69, 96);
    piano.renderStereo(&left, &right, 48_000);
    piano.noteOff(0, 69);
    piano.renderStereo(&left, &right, 48_000);
    var release_voices: usize = 0;
    for (piano.voices) |voice| if (voice.active and voice.one_shot) {
        release_voices += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), release_voices);

    piano.allNotesOff();
    piano.renderStereo(&left, &right, 48_000);
    piano.controlChange(0, 64, 127);
    piano.renderStereo(&left, &right, 48_000);
    piano.controlChange(0, 64, 0);
    piano.renderStereo(&left, &right, 48_000);
    var mechanism_voices: usize = 0;
    for (piano.voices) |voice| if (voice.active and voice.one_shot) {
        mechanism_voices += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), mechanism_voices);

    piano.controlChange(0, 64, 127);
    piano.renderStereo(&left, &right, 48_000);
    piano.noteOn(0, 69, 96);
    piano.renderStereo(&left, &right, 48_000);
    var sustained_layers: usize = 0;
    for (piano.voices) |voice| if (voice.active and !voice.one_shot) {
        sustained_layers += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), sustained_layers);
}

test "portable piano continuously blends recorded velocity layers" {
    const bytes = try testVelocityBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);

    piano.startVoice(0, 60, 32, 48_000);
    var active_layers: usize = 0;
    for (piano.voices) |voice| if (voice.active) {
        active_layers += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), active_layers);

    piano.allNotesOffImmediate();
    piano.startVoice(0, 60, 64, 48_000);
    active_layers = 0;
    var left_gain: f32 = 0;
    var right_gain: f32 = 0;
    for (piano.voices) |voice| if (voice.active) {
        active_layers += 1;
        if (left_gain == 0) left_gain = voice.gain_left else right_gain = voice.gain_left;
    };
    try std.testing.expectEqual(@as(usize, 2), active_layers);
    try std.testing.expectApproxEqRel(left_gain, right_gain, 0.0001);
}

test "portable voice stealing protects held notes and declicks the replacement" {
    const bytes = try testBank(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var piano: Piano = .{};
    try piano.load(bytes);
    for (&piano.voices, 0..) |*voice, index| voice.* = .{
        .active = true,
        .key_down = true,
        .pitch = 1,
        .envelope = 1,
        .age = index + 1,
    };
    piano.voices[7].key_down = false;
    piano.voices[7].releasing = true;
    piano.voices[7].envelope = 0.01;
    piano.voices[7].last_left = 0.25;
    piano.voices[7].last_right = -0.2;

    piano.startVoice(0, 69, 100, 48_000);
    try std.testing.expectEqual(@as(u8, 69), piano.voices[7].pitch);
    try std.testing.expectEqual(@as(f32, 0.25), piano.voices[7].steal_left);
    try std.testing.expectEqual(@as(f32, -0.2), piano.voices[7].steal_right);
    try std.testing.expect(piano.voices[0].active and piano.voices[0].key_down and piano.voices[0].pitch == 1);
}
