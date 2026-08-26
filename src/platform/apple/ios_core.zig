const std = @import("std");
const score = @import("score");

var app: ?*score.App = null;
var audio_piano: score.sample_bank.Piano = .{};
var audio_bank_storage: ?[]u8 = null;
var audio_diagnostics_enabled = std.atomic.Value(bool).init(false);
var audio_event_count = std.atomic.Value(u64).init(0);
var audio_sustain_event_count = std.atomic.Value(u64).init(0);
var audio_last_sustain_value = std.atomic.Value(u32).init(0);
var audio_nonzero_sample_count = std.atomic.Value(u64).init(0);
var audio_peak_bits = std.atomic.Value(u32).init(0);

pub export fn score_ios_api_version() u32 {
    return 3;
}

pub export fn score_ios_create(width: f32, height: f32, pixel_ratio: f32) bool {
    if (app != null) return true;
    app = score.App.create(std.heap.c_allocator, width, height, pixel_ratio) catch return false;
    if (audio_piano.isLoaded()) app.?.setSamplerStatus(1, "Accurate Salamander Grand", @intCast(audio_piano.regionCount()), audio_piano.sampleCount());
    return true;
}

pub export fn score_ios_audio_load_bank(bytes: [*]const u8, length: usize) u32 {
    if (length == 0 or length > score.sample_bank.max_bank_bytes) return 1;
    const replacement = std.heap.c_allocator.alloc(u8, length) catch return 2;
    @memcpy(replacement, bytes[0..length]);
    _ = score.sample_bank.View.open(replacement) catch {
        std.heap.c_allocator.free(replacement);
        return 3;
    };
    audio_piano.unload();
    if (audio_bank_storage) |previous| std.heap.c_allocator.free(previous);
    audio_bank_storage = replacement;
    audio_piano.load(replacement) catch unreachable;
    if (app) |instance| instance.setSamplerStatus(1, "Accurate Salamander Grand", @intCast(audio_piano.regionCount()), audio_piano.sampleCount());
    return 0;
}

pub export fn score_ios_audio_event(pitch: u8, velocity: u8, channel: u8, on: u8) void {
    if (audio_diagnostics_enabled.load(.monotonic)) {
        _ = audio_event_count.fetchAdd(1, .monotonic);
        if (on == 4 and pitch == 64) {
            _ = audio_sustain_event_count.fetchAdd(1, .monotonic);
            audio_last_sustain_value.store(velocity, .release);
        }
    }
    switch (on) {
        0 => audio_piano.noteOff(channel, pitch),
        1 => audio_piano.noteOn(channel, pitch, velocity),
        2 => audio_piano.allNotesOff(),
        3 => audio_piano.click(velocity >= 120),
        4 => audio_piano.controlChange(channel, pitch, velocity),
        else => {},
    }
}

pub export fn score_ios_audio_midi(status: u8, data1: u8, data2: u8) void {
    const message = status & 0xf0;
    const channel = status & 0x0f;
    if (message == 0x90 and data2 != 0) {
        audio_piano.noteOn(channel, data1, data2);
    } else if (message == 0x80 or (message == 0x90 and data2 == 0)) {
        audio_piano.noteOff(channel, data1);
    } else if (message == 0xb0) {
        audio_piano.controlChange(channel, data1, data2);
    }
}

pub export fn score_ios_audio_render(left: [*]f32, right: [*]f32, frame_count: usize, sample_rate: f32) void {
    audio_piano.renderStereo(left[0..frame_count], right[0..frame_count], sample_rate);
    if (!audio_diagnostics_enabled.load(.monotonic)) return;
    var nonzero: u64 = 0;
    var peak: f32 = 0;
    for (left[0..frame_count], right[0..frame_count]) |left_sample, right_sample| {
        const left_magnitude = @abs(left_sample);
        const right_magnitude = @abs(right_sample);
        if (left_magnitude > 0.000001) nonzero += 1;
        if (right_magnitude > 0.000001) nonzero += 1;
        peak = @max(peak, @max(left_magnitude, right_magnitude));
    }
    if (nonzero != 0) _ = audio_nonzero_sample_count.fetchAdd(nonzero, .monotonic);
    const peak_bits: u32 = @bitCast(peak);
    var previous = audio_peak_bits.load(.monotonic);
    while (peak_bits > previous) {
        if (audio_peak_bits.cmpxchgWeak(previous, peak_bits, .release, .monotonic)) |observed| {
            previous = observed;
        } else break;
    }
}

pub export fn score_ios_audio_reset_diagnostics() void {
    audio_event_count.store(0, .release);
    audio_sustain_event_count.store(0, .release);
    audio_last_sustain_value.store(0, .release);
    audio_nonzero_sample_count.store(0, .release);
    audio_peak_bits.store(0, .release);
    audio_diagnostics_enabled.store(true, .release);
}

pub export fn score_ios_audio_finish_diagnostics() void {
    audio_diagnostics_enabled.store(false, .release);
}

pub export fn score_ios_audio_event_count() u64 {
    return audio_event_count.load(.acquire);
}

pub export fn score_ios_audio_sustain_event_count() u64 {
    return audio_sustain_event_count.load(.acquire);
}

pub export fn score_ios_audio_last_sustain_value() u32 {
    return audio_last_sustain_value.load(.acquire);
}

pub export fn score_ios_audio_nonzero_samples() u64 {
    return audio_nonzero_sample_count.load(.acquire);
}

pub export fn score_ios_audio_peak() f32 {
    return @bitCast(audio_peak_bits.load(.acquire));
}

pub export fn score_ios_destroy() void {
    if (app) |instance| instance.destroy(std.heap.c_allocator);
    app = null;
}

pub export fn score_ios_frame(delta_seconds: f32) void {
    if (app) |instance| instance.tick(delta_seconds);
}

pub export fn score_ios_resize(width: f32, height: f32, pixel_ratio: f32) void {
    if (app) |instance| instance.resize(width, height, pixel_ratio);
}

pub export fn score_ios_pointer(kind: u32, pointer_type: u32, pointer_id: u32, x: f32, y: f32, buttons: u32, pressure: f32, tilt_x: f32, tilt_y: f32) void {
    if (app) |instance| instance.pointer(.{
        .kind = @enumFromInt(kind),
        .pointer_type = @enumFromInt(pointer_type),
        .id = pointer_id,
        .buttons = buttons,
        .x = x,
        .y = y,
        .pressure = pressure,
        .tilt_x = tilt_x,
        .tilt_y = tilt_y,
        .scroll_x = 0,
        .scroll_y = 0,
    });
}

pub export fn score_ios_key(key: u32, modifiers: u32, pressed: u32, repeat: u32) void {
    if (app) |instance| instance.key(.{ .key = key, .scancode = 0, .modifiers = modifiers, .pressed = pressed, .repeat = repeat });
}

pub export fn score_ios_midi(time_ns: u64, status: u8, data1: u8, data2: u8) void {
    if (app) |instance| instance.midiInput(time_ns, status, data1, data2);
}

pub export fn score_ios_microphone_pitch(pitch: u8, confidence: f32) void {
    if (app) |instance| instance.microphonePitch(pitch, confidence);
}

pub export fn score_ios_detect_pitch(samples: [*]const f32, frame_count: usize, sample_rate: f32, confidence: *f32) u32 {
    const detected = score.pitch.detect(samples[0..frame_count], sample_rate) orelse {
        confidence.* = 0;
        return 255;
    };
    confidence.* = detected.confidence;
    return detected.midi_note;
}

pub export fn score_ios_draw_items() ?[*]const score.render.DrawItem {
    const instance = app orelse return null;
    return instance.drawItems().ptr;
}

pub export fn score_ios_draw_count() u32 {
    const instance = app orelse return 0;
    return @intCast(instance.drawItems().len);
}

pub export fn score_ios_glyph_atlas_bytes() [*]const u8 {
    return score.glyph_atlas.pixels.ptr;
}

pub export fn score_ios_glyph_atlas_width() u32 {
    return score.glyph_atlas.width;
}

pub export fn score_ios_glyph_atlas_height() u32 {
    return score.glyph_atlas.height;
}

pub export fn score_ios_accessibility_items() ?[*]const score.accessibility.Item {
    const instance = app orelse return null;
    return instance.accessibilityItems().ptr;
}

pub export fn score_ios_accessibility_count() u32 {
    const instance = app orelse return 0;
    return @intCast(instance.accessibilityItems().len);
}

pub export fn score_ios_accessibility_activate(id: u32) void {
    if (app) |instance| instance.accessibilityActivate(id);
}

/// Device acceptance hook: exercises the same shared-core library import path
/// as a real tap without teaching the UIKit host anything about score data.
pub export fn score_ios_load_bundled(index: u32) u32 {
    const instance = app orelse return 1;
    instance.loadBundledScore(index) catch return 2;
    return 0;
}

pub export fn score_ios_host_request() u32 {
    const instance = app orelse return 0;
    return @intFromEnum(instance.takeHostRequest());
}

pub export fn score_ios_set_host_status(status: u32) void {
    if (app) |instance| instance.setHostStatus(status);
}

pub export fn score_ios_drain_playback(events: [*]score.playback.HostEvent, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.drainPlaybackEvents(events[0..capacity]);
}

pub export fn score_ios_drain_controller(outputs: [*]score.controller.Output, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.drainControllerOutputs(outputs[0..capacity]);
}

pub export fn score_ios_set_controller_target(status: u32, bytes: [*]const u8, length: usize) void {
    if (app) |instance| instance.setControllerTarget(status, bytes[0..length]);
}

pub export fn score_ios_serialize_controller(bytes: [*]u8, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.serializeControllerPreferences(bytes[0..capacity]) catch 0;
}

pub export fn score_ios_restore_controller(bytes: [*]const u8, length: usize) u32 {
    const instance = app orelse return 1;
    instance.deserializeControllerPreferences(bytes[0..length]) catch return 2;
    return 0;
}

pub export fn score_ios_import(bytes: [*]const u8, length: usize, kind: u32) u32 {
    const instance = app orelse return 1;
    const source = bytes[0..length];
    if (kind == 4) {
        instance.importMxl(source) catch return 2;
    } else if (kind == 3) {
        instance.deserialize(source) catch return 2;
    } else if (kind == 2) {
        instance.importMidi(source) catch return 2;
    } else {
        instance.importMusicXml(source) catch return 2;
    }
    return 0;
}

pub export fn score_ios_serialize(bytes: [*]u8, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.serialize(bytes[0..capacity]) catch 0;
}

pub export fn score_ios_export_musicxml(bytes: [*]u8, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.exportMusicXml(bytes[0..capacity]) catch 0;
}

pub export fn score_ios_export_take_midi(bytes: [*]u8, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.exportTakeMidi(bytes[0..capacity]) catch 0;
}

pub export fn score_ios_restore(bytes: [*]const u8, length: usize) u32 {
    const instance = app orelse return 1;
    instance.deserialize(bytes[0..length]) catch return 2;
    return 0;
}
