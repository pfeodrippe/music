const std = @import("std");

pub const max_draw_items = 16_384;

pub const Kind = enum(u32) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    glow = 3,
    treble_clef = 4,
    bass_clef = 5,
};

/// ABI-stable instance consumed directly by every GPU backend.
/// Three vec4 values deliberately match WGSL storage-buffer layout.
pub const DrawItem = extern struct {
    rect: [4]f32,
    color: [4]f32,
    params: [4]f32,
};

pub const Color = [4]f32;

pub const Packet = struct {
    items: [max_draw_items]DrawItem = undefined,
    len: usize = 0,
    clipped: bool = false,

    pub fn reset(self: *Packet) void {
        self.len = 0;
        self.clipped = false;
    }

    pub fn slice(self: *const Packet) []const DrawItem {
        return self.items[0..self.len];
    }

    pub fn add(
        self: *Packet,
        kind: Kind,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Color,
        radius: f32,
        pulse: f32,
    ) void {
        if (self.len == self.items.len) {
            self.clipped = true;
            return;
        }
        self.items[self.len] = .{
            .rect = .{ x, y, width, height },
            .color = color,
            .params = .{ @floatFromInt(@intFromEnum(kind)), radius, pulse, 0 },
        };
        self.len += 1;
    }

    pub fn rect(self: *Packet, x: f32, y: f32, width: f32, height: f32, color: Color) void {
        self.add(.rect, x, y, width, height, color, 0, 0);
    }

    pub fn rounded(self: *Packet, x: f32, y: f32, width: f32, height: f32, radius: f32, color: Color) void {
        self.add(.rounded_rect, x, y, width, height, color, radius, 0);
    }

    pub fn ellipse(self: *Packet, x: f32, y: f32, width: f32, height: f32, color: Color) void {
        self.add(.ellipse, x, y, width, height, color, 0, 0);
    }

    pub fn glow(self: *Packet, x: f32, y: f32, width: f32, height: f32, radius: f32, color: Color, pulse: f32) void {
        self.add(.glow, x, y, width, height, color, radius, pulse);
    }

    pub fn trebleClef(self: *Packet, x: f32, y: f32, width: f32, height: f32, color: Color) void {
        self.add(.treble_clef, x, y, width, height, color, 0, 0);
    }

    pub fn bassClef(self: *Packet, x: f32, y: f32, width: f32, height: f32, color: Color) void {
        self.add(.bass_clef, x, y, width, height, color, 0, 0);
    }

    pub fn text(self: *Packet, x: f32, y: f32, value: []const u8, scale: f32, color: Color) void {
        var cursor = x;
        for (value) |raw| {
            if (raw == '\n') {
                cursor = x;
                continue;
            }
            const columns = glyph(std.ascii.toUpper(raw));
            for (columns, 0..) |bits, column| {
                for (0..7) |row| {
                    if ((bits & (@as(u8, 1) << @intCast(row))) != 0) {
                        self.rect(
                            cursor + @as(f32, @floatFromInt(column)) * scale,
                            y + @as(f32, @floatFromInt(row)) * scale,
                            scale * 0.82,
                            scale * 0.82,
                            color,
                        );
                    }
                }
            }
            cursor += scale * 6;
        }
    }

    pub fn textWidth(value: []const u8, scale: f32) f32 {
        return @as(f32, @floatFromInt(value.len)) * scale * 6;
    }
};

/// Compact 5x7 development font. Production swaps this for an SDF atlas while
/// retaining the same text draw API and GPU packet format.
fn glyph(char: u8) [5]u8 {
    return switch (char) {
        'A' => .{ 0x7e, 0x09, 0x09, 0x09, 0x7e },
        'B' => .{ 0x7f, 0x49, 0x49, 0x49, 0x36 },
        'C' => .{ 0x3e, 0x41, 0x41, 0x41, 0x22 },
        'D' => .{ 0x7f, 0x41, 0x41, 0x22, 0x1c },
        'E' => .{ 0x7f, 0x49, 0x49, 0x49, 0x41 },
        'F' => .{ 0x7f, 0x09, 0x09, 0x09, 0x01 },
        'G' => .{ 0x3e, 0x41, 0x49, 0x49, 0x7a },
        'H' => .{ 0x7f, 0x08, 0x08, 0x08, 0x7f },
        'I' => .{ 0x41, 0x41, 0x7f, 0x41, 0x41 },
        'J' => .{ 0x20, 0x40, 0x41, 0x3f, 0x01 },
        'K' => .{ 0x7f, 0x08, 0x14, 0x22, 0x41 },
        'L' => .{ 0x7f, 0x40, 0x40, 0x40, 0x40 },
        'M' => .{ 0x7f, 0x02, 0x0c, 0x02, 0x7f },
        'N' => .{ 0x7f, 0x04, 0x08, 0x10, 0x7f },
        'O' => .{ 0x3e, 0x41, 0x41, 0x41, 0x3e },
        'P' => .{ 0x7f, 0x09, 0x09, 0x09, 0x06 },
        'Q' => .{ 0x3e, 0x41, 0x51, 0x21, 0x5e },
        'R' => .{ 0x7f, 0x09, 0x19, 0x29, 0x46 },
        'S' => .{ 0x46, 0x49, 0x49, 0x49, 0x31 },
        'T' => .{ 0x01, 0x01, 0x7f, 0x01, 0x01 },
        'U' => .{ 0x3f, 0x40, 0x40, 0x40, 0x3f },
        'V' => .{ 0x1f, 0x20, 0x40, 0x20, 0x1f },
        'W' => .{ 0x7f, 0x20, 0x18, 0x20, 0x7f },
        'X' => .{ 0x63, 0x14, 0x08, 0x14, 0x63 },
        'Y' => .{ 0x03, 0x04, 0x78, 0x04, 0x03 },
        'Z' => .{ 0x61, 0x51, 0x49, 0x45, 0x43 },
        '0' => .{ 0x3e, 0x51, 0x49, 0x45, 0x3e },
        '1' => .{ 0x00, 0x42, 0x7f, 0x40, 0x00 },
        '2' => .{ 0x62, 0x51, 0x49, 0x49, 0x46 },
        '3' => .{ 0x22, 0x41, 0x49, 0x49, 0x36 },
        '4' => .{ 0x18, 0x14, 0x12, 0x7f, 0x10 },
        '5' => .{ 0x2f, 0x49, 0x49, 0x49, 0x31 },
        '6' => .{ 0x3e, 0x49, 0x49, 0x49, 0x32 },
        '7' => .{ 0x01, 0x71, 0x09, 0x05, 0x03 },
        '8' => .{ 0x36, 0x49, 0x49, 0x49, 0x36 },
        '9' => .{ 0x26, 0x49, 0x49, 0x49, 0x3e },
        '-' => .{ 0x08, 0x08, 0x08, 0x08, 0x08 },
        '+' => .{ 0x08, 0x08, 0x3e, 0x08, 0x08 },
        ':' => .{ 0x00, 0x36, 0x36, 0x00, 0x00 },
        '.' => .{ 0x00, 0x40, 0x60, 0x00, 0x00 },
        '/' => .{ 0x60, 0x18, 0x06, 0x01, 0x00 },
        '!' => .{ 0x00, 0x00, 0x5f, 0x00, 0x00 },
        '?' => .{ 0x02, 0x01, 0x51, 0x09, 0x06 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0x7f, 0x41, 0x5d, 0x41, 0x7f },
    };
}

test "draw packet has a stable GPU ABI" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(DrawItem));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DrawItem));
}

test "packet clipping is explicit" {
    var packet: Packet = .{};
    for (0..max_draw_items + 1) |_| packet.rect(0, 0, 1, 1, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(max_draw_items, packet.len);
    try std.testing.expect(packet.clipped);
}
