const std = @import("std");

pub const max_midi_events = 65_536;

pub const MidiEvent = extern struct {
    time_ns: u64,
    sequence: u32,
    kind: u8,
    channel: u8,
    data1: u8,
    data2: u8,
};

pub const AudioSpan = extern struct {
    start_time_ns: u64,
    frame_offset: u64,
    frame_count: u32,
    channels: u16,
    sample_rate: u16,
};

pub const Take = struct {
    started_ns: u64 = 0,
    stopped_ns: u64 = 0,
    tempo_bpm: f32 = 120,
    midi: [max_midi_events]MidiEvent = undefined,
    midi_len: usize = 0,
    midi_overflow: bool = false,
    audio_frames: u64 = 0,

    pub fn reset(self: *Take, now_ns: u64) void {
        self.started_ns = now_ns;
        self.stopped_ns = 0;
        self.midi_len = 0;
        self.midi_overflow = false;
        self.audio_frames = 0;
    }

    pub fn pushMidi(self: *Take, event: MidiEvent) void {
        if (self.midi_len == self.midi.len) {
            self.midi_overflow = true;
            return;
        }
        self.midi[self.midi_len] = event;
        self.midi_len += 1;
    }

    pub fn durationNs(self: *const Take) u64 {
        if (self.stopped_ns <= self.started_ns) return 0;
        return self.stopped_ns - self.started_ns;
    }
};

test "MIDI capture retains ordering metadata" {
    var take: Take = .{};
    take.reset(100);
    take.pushMidi(.{ .time_ns = 120, .sequence = 1, .kind = 0x90, .channel = 0, .data1 = 60, .data2 = 100 });
    take.pushMidi(.{ .time_ns = 140, .sequence = 2, .kind = 0x80, .channel = 0, .data1 = 60, .data2 = 0 });
    try std.testing.expectEqual(@as(usize, 2), take.midi_len);
    try std.testing.expect(take.midi[0].sequence < take.midi[1].sequence);
}
