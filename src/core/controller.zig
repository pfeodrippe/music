const std = @import("std");

/// Controller output stays platform-neutral. The shared core creates complete
/// OSC datagrams or three-byte MIDI messages; hosts only deliver the bytes.
pub const OutputKind = enum(u32) {
    osc = 1,
    midi = 2,
};

pub const max_datagram_bytes = 128;

pub const Output = extern struct {
    kind: OutputKind = .osc,
    length: u32 = 0,
    bytes: [max_datagram_bytes]u8 = [_]u8{0} ** max_datagram_bytes,

    pub fn payload(self: *const Output) []const u8 {
        return self.bytes[0..@min(@as(usize, self.length), self.bytes.len)];
    }
};

pub const TransportButton = enum(u8) {
    stop,
    play,
    record,
    loop,
    click,
    undo,
    redo,
    save,
};

pub fn midi(status: u8, data1: u8, data2: u8) Output {
    var output = Output{ .kind = .midi, .length = 3 };
    output.bytes[0] = status;
    output.bytes[1] = data1;
    output.bytes[2] = data2;
    return output;
}

pub fn oscNoArguments(address: []const u8) !Output {
    var output = Output{ .kind = .osc };
    var cursor: usize = 0;
    try appendOscString(&output.bytes, &cursor, address);
    try appendOscString(&output.bytes, &cursor, ",");
    output.length = @intCast(cursor);
    return output;
}

pub fn oscInt(address: []const u8, value: i32) !Output {
    var output = Output{ .kind = .osc };
    var cursor: usize = 0;
    try appendOscString(&output.bytes, &cursor, address);
    try appendOscString(&output.bytes, &cursor, ",i");
    if (cursor + 4 > output.bytes.len) return error.OscMessageTooLong;
    std.mem.writeInt(i32, output.bytes[cursor..][0..4], value, .big);
    cursor += 4;
    output.length = @intCast(cursor);
    return output;
}

pub fn note(protocol: u32, channel: u8, note_number: u8, velocity: u8) !Output {
    if (protocol == 1) {
        var address_buffer: [48]u8 = undefined;
        const address = try std.fmt.bufPrint(&address_buffer, "/vkb_midi/{d}/note/{d}", .{ @as(u16, channel) + 1, note_number });
        return oscInt(address, velocity);
    }
    return midi(0x90 | (channel & 0x0f), note_number, velocity);
}

pub fn drum(protocol: u32, channel: u8, note_number: u8, velocity: u8) !Output {
    if (protocol == 1) {
        var address_buffer: [48]u8 = undefined;
        const address = try std.fmt.bufPrint(&address_buffer, "/vkb_midi/{d}/drum/{d}", .{ @as(u16, channel) + 1, note_number });
        return oscInt(address, velocity);
    }
    return midi(0x90 | (channel & 0x0f), note_number, velocity);
}

pub fn cc(protocol: u32, channel: u8, controller_number: u8, value: u8) !Output {
    if (protocol == 1) {
        var address_buffer: [48]u8 = undefined;
        const address = try std.fmt.bufPrint(&address_buffer, "/vkb_midi/{d}/cc/{d}", .{ @as(u16, channel) + 1, controller_number });
        return oscInt(address, value);
    }
    return midi(0xb0 | (channel & 0x0f), controller_number, value);
}

/// Per-note pressure keeps expressive Pencil/controller gestures independent
/// when several pads are held. DrivenByMoss exposes the same poly-aftertouch
/// semantic over OSC; generic MIDI uses the standard 0xA0 channel message.
pub fn aftertouch(protocol: u32, channel: u8, note_number: u8, pressure: u8) !Output {
    if (protocol == 1) {
        var address_buffer: [56]u8 = undefined;
        const address = try std.fmt.bufPrint(&address_buffer, "/vkb_midi/{d}/aftertouch/{d}", .{ @as(u16, channel) + 1, note_number });
        return oscInt(address, pressure);
    }
    return midi(0xa0 | (channel & 0x0f), note_number, pressure);
}

pub fn clip(protocol: u32, track: u8, scene: u8, pressed: bool) !Output {
    if (protocol == 1) {
        var address_buffer: [48]u8 = undefined;
        const address = try std.fmt.bufPrint(&address_buffer, "/track/{d}/clip/{d}/launch", .{ @as(u16, track) + 1, @as(u16, scene) + 1 });
        return oscInt(address, @intFromBool(pressed));
    }
    const controller_number: u8 = 36 + scene * 4 + track;
    return midi(0xb0, controller_number, if (pressed) 127 else 0);
}

pub fn action(protocol: u32, index: u8, pressed: bool) !Output {
    if (protocol == 1) {
        if (!pressed) return error.ReleaseNotRequired;
        return oscInt("/action", @as(i32, index) + 1);
    }
    return midi(0xb0, 52 + index, if (pressed) 127 else 0);
}

pub fn transport(protocol: u32, button: TransportButton, pressed: bool) !Output {
    if (protocol == 1) {
        if (!pressed) return error.ReleaseNotRequired;
        return switch (button) {
            .stop => oscNoArguments("/stop"),
            .play => oscInt("/playbutton", 1),
            .record => oscNoArguments("/record"),
            .loop => oscInt("/repeat", 1),
            .click => oscInt("/click", 1),
            .undo => oscNoArguments("/undo"),
            .redo => oscNoArguments("/redo"),
            .save => oscNoArguments("/project/save"),
        };
    }
    return midi(0xb0, 20 + @intFromEnum(button), if (pressed) 127 else 0);
}

fn appendOscString(destination: []u8, cursor: *usize, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidOscString;
    const encoded_length = std.mem.alignForward(usize, value.len + 1, 4);
    if (cursor.* + encoded_length > destination.len) return error.OscMessageTooLong;
    @memcpy(destination[cursor.* .. cursor.* + value.len], value);
    @memset(destination[cursor.* + value.len .. cursor.* + encoded_length], 0);
    cursor.* += encoded_length;
}

test "OSC encoder emits padded big-endian integer datagrams" {
    const output = try oscInt("/playbutton", 1);
    try std.testing.expectEqual(OutputKind.osc, output.kind);
    try std.testing.expectEqual(@as(usize, 20), output.payload().len);
    try std.testing.expectEqualSlices(u8, &.{
        '/', 'p', 'l', 'a', 'y', 'b', 'u', 't', 't', 'o', 'n', 0,
        ',', 'i', 0, 0,
        0, 0, 0, 1,
    }, output.payload());
}

test "controller mappings support OSC, generic MIDI, clips, and releases" {
    const osc_note = try note(1, 0, 36, 104);
    try std.testing.expect(std.mem.startsWith(u8, osc_note.payload(), "/vkb_midi/1/note/36"));
    try std.testing.expectEqual(@as(i32, 104), std.mem.readInt(i32, osc_note.payload()[osc_note.payload().len - 4 ..][0..4], .big));

    const midi_note = try note(0, 2, 64, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x92, 64, 0 }, midi_note.payload());

    const osc_drum = try drum(1, 9, 38, 121);
    try std.testing.expect(std.mem.startsWith(u8, osc_drum.payload(), "/vkb_midi/10/drum/38"));
    const midi_drum = try drum(0, 9, 38, 121);
    try std.testing.expectEqualSlices(u8, &.{ 0x99, 38, 121 }, midi_drum.payload());

    const osc_cc = try cc(1, 2, 74, 99);
    try std.testing.expect(std.mem.startsWith(u8, osc_cc.payload(), "/vkb_midi/3/cc/74"));
    const midi_cc = try cc(0, 2, 74, 99);
    try std.testing.expectEqualSlices(u8, &.{ 0xb2, 74, 99 }, midi_cc.payload());

    const osc_pressure = try aftertouch(1, 0, 48, 76);
    try std.testing.expect(std.mem.startsWith(u8, osc_pressure.payload(), "/vkb_midi/1/aftertouch/48"));
    const midi_pressure = try aftertouch(0, 4, 48, 76);
    try std.testing.expectEqualSlices(u8, &.{ 0xa4, 48, 76 }, midi_pressure.payload());

    const clip_press = try clip(1, 2, 3, true);
    try std.testing.expect(std.mem.startsWith(u8, clip_press.payload(), "/track/3/clip/4/launch"));
    const clip_release = try clip(1, 2, 3, false);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, clip_release.payload()[clip_release.payload().len - 4 ..][0..4], .big));

    try std.testing.expectError(error.ReleaseNotRequired, action(1, 0, false));
    try std.testing.expectError(error.ReleaseNotRequired, transport(1, .play, false));
}
