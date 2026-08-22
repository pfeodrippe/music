const synth_module = @import("synth.zig");
const pitch_module = @import("pitch.zig");

const max_render_frames = 128;
const pitch_window_frames = 2048;

var synth: synth_module.Synth = .{};
var output: [max_render_frames]f32 = [_]f32{0} ** max_render_frames;
var pitch_input: [pitch_window_frames]f32 = [_]f32{0} ** pitch_window_frames;
var last_pitch: u32 = 255;
var last_confidence: f32 = 0;

pub export fn score_audio_reset() void {
    synth = .{};
    @memset(&output, 0);
    last_pitch = 255;
    last_confidence = 0;
}

pub export fn score_audio_midi(status: u32, data1: u32, data2: u32) void {
    const message: u8 = @truncate(status & 0xf0);
    const channel: u8 = @truncate(status & 0x0f);
    const note: u8 = @truncate(data1);
    const velocity: u8 = @truncate(data2);
    if (message == 0x90 and velocity != 0) {
        synth.noteOn(channel, note, velocity);
    } else if (message == 0x80 or (message == 0x90 and velocity == 0)) {
        synth.noteOff(channel, note);
    } else if (message == 0xb0 and note == 123) {
        synth.allNotesOff();
    }
}

pub export fn score_audio_all_notes_off() void {
    synth.allNotesOff();
}

pub export fn score_audio_click(accent: u32) void {
    synth.click(accent != 0);
}

pub export fn score_audio_render(frame_count: u32, sample_rate: f32) usize {
    const frames = @min(@as(usize, frame_count), output.len);
    synth.renderInterleaved(output[0..frames], frames, 1, sample_rate);
    return @intFromPtr(&output);
}

pub export fn score_pitch_input_pointer() usize {
    return @intFromPtr(&pitch_input);
}

pub export fn score_pitch_input_capacity() u32 {
    return pitch_input.len;
}

pub export fn score_pitch_analyze(frame_count: u32, sample_rate: f32) u32 {
    const frames = @min(@as(usize, frame_count), pitch_input.len);
    const detected = pitch_module.detect(pitch_input[0..frames], sample_rate) orelse {
        last_pitch = 255;
        last_confidence = 0;
        return last_pitch;
    };
    last_pitch = detected.midi_note;
    last_confidence = detected.confidence;
    return last_pitch;
}

pub export fn score_pitch_confidence() f32 {
    return last_confidence;
}
