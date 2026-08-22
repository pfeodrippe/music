const std = @import("std");

pub const max_voices = 48;
const queue_capacity = 1024;

const Event = extern struct {
    kind: u8,
    pitch: u8,
    velocity: u8,
    channel: u8,
};

const Voice = struct {
    pitch: u8 = 0,
    channel: u8 = 0,
    phase: f32 = 0,
    gain: f32 = 0,
    envelope: f32 = 0,
    key_down: bool = false,
    sostenuto_latched: bool = false,
    soft_amount: f32 = 0,
    releasing: bool = false,
    active: bool = false,
    age: u64 = 0,
};

pub const Synth = struct {
    events: [queue_capacity]Event = undefined,
    write_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    voices: [max_voices]Voice = [_]Voice{.{}} ** max_voices,
    voice_age: u64 = 1,
    master_gain: f32 = 0.20,
    dropped_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    click_phase: f32 = 0,
    click_envelope: f32 = 0,
    click_frequency: f32 = 1320,
    click_gain: f32 = 0,
    sustain: [16]u8 = [_]u8{0} ** 16,
    sostenuto: [16]u8 = [_]u8{0} ** 16,
    una_corda: [16]u8 = [_]u8{0} ** 16,

    pub fn noteOn(self: *Synth, channel: u8, pitch: u8, velocity: u8) void {
        self.enqueue(.{ .kind = 1, .pitch = pitch, .velocity = velocity, .channel = channel });
    }

    pub fn noteOff(self: *Synth, channel: u8, pitch: u8) void {
        self.enqueue(.{ .kind = 0, .pitch = pitch, .velocity = 0, .channel = channel });
    }

    pub fn allNotesOff(self: *Synth) void {
        self.enqueue(.{ .kind = 2, .pitch = 0, .velocity = 0, .channel = 0 });
    }

    pub fn controlChange(self: *Synth, channel: u8, controller: u8, value: u8) void {
        self.enqueue(.{ .kind = 4, .pitch = controller, .velocity = value, .channel = channel & 0x0f });
    }

    pub fn click(self: *Synth, accent: bool) void {
        self.enqueue(.{ .kind = 3, .pitch = 0, .velocity = if (accent) 127 else 86, .channel = 0 });
    }

    pub fn renderInterleaved(self: *Synth, output: []f32, frame_count: usize, channels: usize, sample_rate: f32) void {
        self.consumeEvents();
        @memset(output, 0);
        if (channels == 0 or sample_rate <= 0) return;
        const click_decay = @exp(-1.0 / (sample_rate * 0.045));
        for (0..frame_count) |frame| {
            var mixed: f32 = 0;
            for (&self.voices) |*voice| {
                if (!voice.active) continue;
                const frequency = 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(voice.pitch)) - 69.0) / 12.0);
                voice.phase += frequency / sample_rate;
                if (voice.phase >= 1) voice.phase -= @floor(voice.phase);
                const angle = voice.phase * std.math.tau;
                const brightness = 1.0 - 0.36 * voice.soft_amount;
                const tone = @sin(angle) + brightness * (0.32 * @sin(angle * 2.0) + 0.12 * @sin(angle * 3.0) + 0.045 * @sin(angle * 5.0));
                if (voice.releasing) {
                    voice.envelope *= 0.99935;
                    if (voice.envelope < 0.0005) voice.active = false;
                } else {
                    voice.envelope += (1.0 - voice.envelope) * 0.0045;
                }
                mixed += tone * voice.gain * voice.envelope;
            }
            if (self.click_envelope > 0.0004) {
                self.click_phase += self.click_frequency / sample_rate;
                if (self.click_phase >= 1) self.click_phase -= @floor(self.click_phase);
                const click_angle = self.click_phase * std.math.tau;
                const click_tone = @sin(click_angle) + 0.34 * @sin(click_angle * 2.7);
                mixed += click_tone * self.click_gain * self.click_envelope;
                self.click_envelope *= click_decay;
            } else {
                self.click_envelope = 0;
            }
            mixed = std.math.clamp(mixed * self.master_gain, -0.92, 0.92);
            for (0..channels) |channel| output[frame * channels + channel] = mixed;
        }
    }

    fn enqueue(self: *Synth, event: Event) void {
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % queue_capacity;
        if (next == self.read_index.load(.acquire)) {
            _ = self.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        self.events[write] = event;
        self.write_index.store(next, .release);
    }

    fn consumeEvents(self: *Synth) void {
        var read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        while (read != write) {
            self.apply(self.events[read]);
            read = (read + 1) % queue_capacity;
        }
        self.read_index.store(read, .release);
    }

    fn apply(self: *Synth, event: Event) void {
        if (event.kind == 2) {
            for (&self.voices) |*voice| if (voice.active) {
                voice.releasing = true;
            };
            self.sustain = [_]u8{0} ** 16;
            self.sostenuto = [_]u8{0} ** 16;
            self.una_corda = [_]u8{0} ** 16;
            self.click_envelope = 0;
            return;
        }
        if (event.kind == 3) {
            self.click_phase = 0;
            self.click_envelope = 1;
            self.click_frequency = if (event.velocity >= 120) 1760 else 1320;
            self.click_gain = if (event.velocity >= 120) 0.82 else 0.56;
            return;
        }
        if (event.kind == 0) {
            for (&self.voices) |*voice| if (voice.active and voice.pitch == event.pitch and voice.channel == event.channel) {
                voice.key_down = false;
                if (self.sustain[event.channel] < 64 and !voice.sostenuto_latched) voice.releasing = true;
            };
            return;
        }
        if (event.kind == 4) {
            self.applyControlChange(event.channel, event.pitch, event.velocity);
            return;
        }
        var slot: *Voice = &self.voices[0];
        for (&self.voices) |*voice| {
            if (!voice.active) {
                slot = voice;
                break;
            }
            if (voice.age < slot.age) slot = voice;
        }
        slot.* = .{
            .pitch = event.pitch,
            .channel = event.channel,
            .phase = 0,
            .gain = @as(f32, @floatFromInt(event.velocity)) / 127.0,
            .envelope = 0,
            .key_down = true,
            .sostenuto_latched = false,
            .soft_amount = @as(f32, @floatFromInt(self.una_corda[event.channel])) / 127.0,
            .releasing = false,
            .active = true,
            .age = self.voice_age,
        };
        self.voice_age += 1;
    }

    fn applyControlChange(self: *Synth, channel: u8, controller: u8, value: u8) void {
        switch (controller) {
            64 => {
                self.sustain[channel] = value;
                if (value < 64) self.releaseUnheld(channel);
            },
            66 => {
                const was_down = self.sostenuto[channel] >= 64;
                self.sostenuto[channel] = value;
                if (!was_down and value >= 64) {
                    for (&self.voices) |*voice| {
                        if (voice.active and voice.channel == channel and voice.key_down) voice.sostenuto_latched = true;
                    }
                } else if (was_down and value < 64) {
                    for (&self.voices) |*voice| {
                        if (!voice.active or voice.channel != channel) continue;
                        voice.sostenuto_latched = false;
                    }
                    self.releaseUnheld(channel);
                }
            },
            67 => self.una_corda[channel] = value,
            120, 123 => {
                for (&self.voices) |*voice| {
                    if (voice.active and voice.channel == channel) {
                        voice.key_down = false;
                        voice.sostenuto_latched = false;
                        voice.releasing = true;
                    }
                }
                self.sustain[channel] = 0;
                self.sostenuto[channel] = 0;
            },
            else => {},
        }
    }

    fn releaseUnheld(self: *Synth, channel: u8) void {
        for (&self.voices) |*voice| {
            if (voice.active and voice.channel == channel and !voice.key_down and !voice.sostenuto_latched) voice.releasing = true;
        }
    }
};

test "synth produces audio after a note event and releases it" {
    var synth: Synth = .{};
    synth.noteOn(0, 69, 100);
    var output: [512 * 2]f32 = undefined;
    synth.renderInterleaved(&output, 512, 2, 48_000);
    var energy: f32 = 0;
    for (output) |sample| energy += @abs(sample);
    try std.testing.expect(energy > 0.1);
    synth.noteOff(0, 69);
    synth.renderInterleaved(&output, 512, 2, 48_000);
    try std.testing.expect(synth.voices[0].releasing);
}

test "metronome click is synthesized and can be stopped immediately" {
    var synth: Synth = .{};
    synth.click(true);
    var output: [256]f32 = undefined;
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    var energy: f32 = 0;
    for (output) |sample| energy += @abs(sample);
    try std.testing.expect(energy > 1);
    synth.allNotesOff();
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expectEqual(@as(f32, 0), synth.click_envelope);
}

test "sustain holds released keys until pedal up" {
    var synth: Synth = .{};
    var output: [64]f32 = undefined;
    synth.noteOn(0, 60, 100);
    synth.controlChange(0, 64, 127);
    synth.noteOff(0, 60);
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expect(!synth.voices[0].key_down);
    try std.testing.expect(!synth.voices[0].releasing);
    synth.controlChange(0, 64, 0);
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expect(synth.voices[0].releasing);
}

test "sostenuto latches only keys already held" {
    var synth: Synth = .{};
    var output: [64]f32 = undefined;
    synth.noteOn(0, 60, 100);
    synth.controlChange(0, 66, 127);
    synth.noteOn(0, 64, 100);
    synth.noteOff(0, 60);
    synth.noteOff(0, 64);
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expect(synth.voices[0].sostenuto_latched);
    try std.testing.expect(!synth.voices[0].releasing);
    try std.testing.expect(!synth.voices[1].sostenuto_latched);
    try std.testing.expect(synth.voices[1].releasing);
    synth.controlChange(0, 66, 0);
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expect(synth.voices[0].releasing);
}

test "una corda state is captured per new voice" {
    var synth: Synth = .{};
    var output: [32]f32 = undefined;
    synth.controlChange(0, 67, 96);
    synth.noteOn(0, 60, 100);
    synth.renderInterleaved(&output, output.len, 1, 48_000);
    try std.testing.expectApproxEqAbs(@as(f32, 96.0 / 127.0), synth.voices[0].soft_amount, 0.0001);
}
