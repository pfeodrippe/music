const std = @import("std");
const synth_module = @import("synth.zig");
const pitch_module = @import("pitch.zig");
const sample_bank = @import("sample_bank.zig");

const max_render_frames = 128;
const pitch_window_frames = 2048;

var fallback_synth: synth_module.Synth = .{};
var piano: sample_bank.Piano = .{};
var bank_storage: ?[]u8 = null;
var pending_bank_storage: ?[]u8 = null;
var output: [max_render_frames * 2]f32 = [_]f32{0} ** (max_render_frames * 2);
var pitch_input: [pitch_window_frames]f32 = [_]f32{0} ** pitch_window_frames;
var last_pitch: u32 = 255;
var last_confidence: f32 = 0;

pub export fn score_audio_reset() void {
    fallback_synth = .{};
    piano.allNotesOff();
    @memset(&output, 0);
    last_pitch = 255;
    last_confidence = 0;
}

pub export fn score_audio_bank_allocate(length: u32) usize {
    if (length == 0 or length > sample_bank.max_bank_bytes) return 0;
    if (pending_bank_storage) |bytes| std.heap.wasm_allocator.free(bytes);
    const bytes = std.heap.wasm_allocator.alloc(u8, length) catch {
        pending_bank_storage = null;
        return 0;
    };
    pending_bank_storage = bytes;
    return @intFromPtr(bytes.ptr);
}

pub export fn score_audio_bank_commit(length: u32) u32 {
    const bytes = pending_bank_storage orelse return 1;
    if (length != bytes.len) {
        std.heap.wasm_allocator.free(bytes);
        pending_bank_storage = null;
        return 1;
    }
    piano.load(bytes) catch {
        std.heap.wasm_allocator.free(bytes);
        pending_bank_storage = null;
        return 2;
    };
    if (bank_storage) |previous| std.heap.wasm_allocator.free(previous);
    bank_storage = bytes;
    pending_bank_storage = null;
    return 0;
}

pub export fn score_audio_bank_samples() u32 {
    return @intCast(piano.sampleCount());
}
pub export fn score_audio_bank_regions() u32 {
    return @intCast(piano.regionCount());
}
pub export fn score_audio_channels() u32 {
    return 2;
}

pub export fn score_audio_midi(status: u32, data1: u32, data2: u32) void {
    const message: u8 = @truncate(status & 0xf0);
    const channel: u8 = @truncate(status & 0x0f);
    const note: u8 = @truncate(data1);
    const velocity: u8 = @truncate(data2);
    if (message == 0x90 and velocity != 0) {
        if (piano.isLoaded()) piano.noteOn(channel, note, velocity) else fallback_synth.noteOn(channel, note, velocity);
    } else if (message == 0x80 or (message == 0x90 and velocity == 0)) {
        if (piano.isLoaded()) piano.noteOff(channel, note) else fallback_synth.noteOff(channel, note);
    } else if (message == 0xb0) {
        if (piano.isLoaded()) piano.controlChange(channel, note, velocity) else fallback_synth.controlChange(channel, note, velocity);
    }
}

pub export fn score_audio_all_notes_off() void {
    if (piano.isLoaded()) piano.allNotesOff() else fallback_synth.allNotesOff();
}

pub export fn score_audio_click(accent: u32) void {
    if (piano.isLoaded()) piano.click(accent != 0) else fallback_synth.click(accent != 0);
}

pub export fn score_audio_render(frame_count: u32, sample_rate: f32) usize {
    const frames = @min(@as(usize, frame_count), max_render_frames);
    if (piano.isLoaded()) {
        piano.renderInterleaved(output[0 .. frames * 2], frames, 2, sample_rate);
    } else {
        fallback_synth.renderInterleaved(output[0 .. frames * 2], frames, 2, sample_rate);
    }
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
