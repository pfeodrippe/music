const std = @import("std");
const score = @import("../root.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

var app: ?*score.App = null;

pub export fn score_init(width: f32, height: f32, pixel_ratio: f32) bool {
    if (app != null) return true;
    app = score.App.create(std.heap.c_allocator, width, height, pixel_ratio) catch return false;
    return true;
}

pub export fn score_shutdown() void {
    if (app) |instance| instance.destroy(std.heap.c_allocator);
    app = null;
}

pub export fn score_frame(delta_seconds: f32) void {
    if (app) |instance| instance.tick(delta_seconds);
}

pub export fn score_resize(width: f32, height: f32, pixel_ratio: f32) void {
    if (app) |instance| instance.resize(width, height, pixel_ratio);
}

pub export fn score_pointer(kind: u32, pointer_type: u32, id: u32, x: f32, y: f32, buttons: u32, pressure: f32, tilt_x: f32, tilt_y: f32, scroll_x: f32, scroll_y: f32) void {
    if (app) |instance| instance.pointer(.{
        .kind = @enumFromInt(kind),
        .pointer_type = @enumFromInt(pointer_type),
        .id = id,
        .buttons = buttons,
        .x = x,
        .y = y,
        .pressure = pressure,
        .tilt_x = tilt_x,
        .tilt_y = tilt_y,
        .scroll_x = scroll_x,
        .scroll_y = scroll_y,
    });
}

pub export fn score_key(key: u32, scancode: u32, modifiers: u32, pressed: u32, repeat: u32) void {
    if (app) |instance| instance.key(.{ .key = key, .scancode = scancode, .modifiers = modifiers, .pressed = pressed, .repeat = repeat });
}

pub export fn score_midi(time_ns: u64, status: u8, data1: u8, data2: u8) void {
    if (app) |instance| instance.midiInput(time_ns, status, data1, data2);
}

pub export fn score_microphone_pitch(pitch: u8, confidence: f32) void {
    if (app) |instance| instance.microphonePitch(pitch, confidence);
}

pub export fn score_host_request() u32 {
    const instance = app orelse return 0;
    return @intFromEnum(instance.takeHostRequest());
}

pub export fn score_host_status(status: u32) void {
    if (app) |instance| instance.setHostStatus(status);
}

pub export fn score_drain_playback(pointer: [*]score.playback.HostEvent, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.drainPlaybackEvents(pointer[0..capacity]);
}

pub export fn score_draw_items() ?[*]const score.render.DrawItem {
    const instance = app orelse return null;
    return instance.drawItems().ptr;
}

pub export fn score_draw_count() u32 {
    const instance = app orelse return 0;
    return @intCast(instance.drawItems().len);
}

pub export fn score_accessibility_items() ?[*]const score.accessibility.Item {
    const instance = app orelse return null;
    return instance.accessibilityItems().ptr;
}

pub export fn score_accessibility_count() u32 {
    const instance = app orelse return 0;
    return @intCast(instance.accessibilityItems().len);
}

pub export fn score_accessibility_activate(id: u32) void {
    if (app) |instance| instance.accessibilityActivate(id);
}

pub export fn score_alloc(length: usize) ?[*]u8 {
    return @ptrCast(c.malloc(length));
}

pub export fn score_free(pointer: ?*anyopaque) void {
    c.free(pointer);
}

pub export fn score_import(pointer: [*]const u8, length: usize, kind: u32) u32 {
    const instance = app orelse return 1;
    const bytes = pointer[0..length];
    if (kind == 4 or (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04"))) {
        instance.importMxl(bytes) catch return 2;
    } else if (kind == 3 or (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], score.native_format.magic))) {
        instance.deserialize(bytes) catch return 2;
    } else if (kind == 2 or (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "MThd"))) {
        instance.importMidi(bytes) catch return 2;
    } else {
        instance.importMusicXml(bytes) catch return 2;
    }
    return 0;
}

pub export fn score_serialize(pointer: [*]u8, capacity: usize) usize {
    const instance = app orelse return 0;
    return instance.serialize(pointer[0..capacity]) catch 0;
}

pub export fn score_restore(pointer: [*]const u8, length: usize) u32 {
    const instance = app orelse return 1;
    instance.deserialize(pointer[0..length]) catch return 2;
    return 0;
}
