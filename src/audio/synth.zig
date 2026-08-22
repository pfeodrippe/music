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

    pub fn noteOn(self: *Synth, channel: u8, pitch: u8, velocity: u8) void {
        self.enqueue(.{ .kind = 1, .pitch = pitch, .velocity = velocity, .channel = channel });
    }

    pub fn noteOff(self: *Synth, channel: u8, pitch: u8) void {
        self.enqueue(.{ .kind = 0, .pitch = pitch, .velocity = 0, .channel = channel });
    }

    pub fn allNotesOff(self: *Synth) void {
        self.enqueue(.{ .kind = 2, .pitch = 0, .velocity = 0, .channel = 0 });
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
                const tone = @sin(angle) + 0.32 * @sin(angle * 2.0) + 0.12 * @sin(angle * 3.0) + 0.045 * @sin(angle * 5.0);
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
                voice.releasing = true;
            };
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
            .releasing = false,
            .active = true,
            .age = self.voice_age,
        };
        self.voice_age += 1;
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
