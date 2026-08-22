const std = @import("std");
const score = @import("score");

var app: ?*score.App = null;

pub export fn score_ios_api_version() u32 {
    return 1;
}

pub export fn score_ios_create(width: f32, height: f32, pixel_ratio: f32) bool {
    if (app != null) return true;
    app = score.App.create(std.heap.c_allocator, width, height, pixel_ratio) catch return false;
    return true;
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

pub export fn score_ios_restore(bytes: [*]const u8, length: usize) u32 {
    const instance = app orelse return 1;
    instance.deserialize(bytes[0..length]) catch return 2;
    return 0;
}
