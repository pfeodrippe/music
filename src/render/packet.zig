const std = @import("std");
const atlas = @import("glyph_atlas.zig");

pub const max_draw_items = 16_384;

pub const Kind = enum(u32) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    glow = 3,
    glyph = 4,
    /// GPU-expanded line segment. rect contains x1,y1,x2,y2 and params.y is
    /// thickness; this keeps stems/beams/spanners analytic on every backend.
    line = 5,
};

/// ABI-stable instance consumed directly by every GPU backend.
/// Four vec4 values deliberately match WGSL/Metal storage-buffer layout.
pub const DrawItem = extern struct {
    rect: [4]f32,
    color: [4]f32,
    params: [4]f32,
    uv: [4]f32,
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
            .uv = .{ 0, 0, 0, 0 },
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

    pub fn line(self: *Packet, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: Color) void {
        if (self.len == self.items.len) {
            self.clipped = true;
            return;
        }
        self.items[self.len] = .{
            .rect = .{ x1, y1, x2, y2 },
            .color = color,
            .params = .{ @floatFromInt(@intFromEnum(Kind.line)), thickness, 0, 0 },
            .uv = .{ 0, 0, 0, 0 },
        };
        self.len += 1;
    }

    pub fn musicGlyph(self: *Packet, codepoint: u21, origin_x: f32, baseline_y: f32, em_size: f32, color: Color) void {
        const glyph = atlas.findMusic(codepoint) orelse return;
        self.atlasGlyph(glyph, origin_x, baseline_y, em_size, color);
    }

    pub fn text(self: *Packet, x: f32, y: f32, value: []const u8, scale: f32, color: Color) void {
        const em_size = scale * 10;
        const baseline = y + em_size * 0.84;
        var cursor = x;
        var byte_index: usize = 0;
        while (byte_index < value.len) {
            const codepoint = nextCodepoint(value, &byte_index);
            if (codepoint == '\n') {
                cursor = x;
                continue;
            }
            const glyph = atlas.findUi(codepoint) orelse atlas.findUi('?') orelse continue;
            self.atlasGlyph(glyph, cursor, baseline, em_size, color);
            cursor += glyph.advance * em_size;
        }
    }

    pub fn textWidth(value: []const u8, scale: f32) f32 {
        const em_size = scale * 10;
        var width: f32 = 0;
        var byte_index: usize = 0;
        while (byte_index < value.len) {
            const codepoint = nextCodepoint(value, &byte_index);
            if (atlas.findUi(codepoint) orelse atlas.findUi('?')) |glyph| width += glyph.advance * em_size;
        }
        return width;
    }

    fn nextCodepoint(value: []const u8, index: *usize) u21 {
        const first = value[index.*];
        index.* += 1;
        if (first < 0x80) return first;
        if (first & 0xe0 == 0xc0 and index.* < value.len) {
            const second = value[index.*];
            if (second & 0xc0 == 0x80) {
                index.* += 1;
                return (@as(u21, first & 0x1f) << 6) | @as(u21, second & 0x3f);
            }
        } else if (first & 0xf0 == 0xe0 and index.* + 1 < value.len) {
            const second = value[index.*];
            const third = value[index.* + 1];
            if (second & 0xc0 == 0x80 and third & 0xc0 == 0x80) {
                index.* += 2;
                return (@as(u21, first & 0x0f) << 12) | (@as(u21, second & 0x3f) << 6) | @as(u21, third & 0x3f);
            }
        } else if (first & 0xf8 == 0xf0 and index.* + 2 < value.len) {
            const second = value[index.*];
            const third = value[index.* + 1];
            const fourth = value[index.* + 2];
            if (second & 0xc0 == 0x80 and third & 0xc0 == 0x80 and fourth & 0xc0 == 0x80) {
                index.* += 3;
                return (@as(u21, first & 0x07) << 18) | (@as(u21, second & 0x3f) << 12) | (@as(u21, third & 0x3f) << 6) | @as(u21, fourth & 0x3f);
            }
        }
        return '?';
    }

    fn atlasGlyph(self: *Packet, glyph: atlas.Glyph, origin_x: f32, baseline_y: f32, em_size: f32, color: Color) void {
        if (glyph.plane[0] == glyph.plane[2] or glyph.plane[1] == glyph.plane[3]) return;
        if (self.len == self.items.len) {
            self.clipped = true;
            return;
        }
        self.items[self.len] = .{
            .rect = .{
                origin_x + glyph.plane[0] * em_size,
                baseline_y + glyph.plane[1] * em_size,
                (glyph.plane[2] - glyph.plane[0]) * em_size,
                (glyph.plane[3] - glyph.plane[1]) * em_size,
            },
            .color = color,
            .params = .{ @floatFromInt(@intFromEnum(Kind.glyph)), atlas.pixel_range, 0, 0 },
            .uv = glyph.uv,
        };
        self.len += 1;
    }
};

test "draw packet has a stable GPU ABI" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(DrawItem));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(DrawItem));
}

test "packet clipping is explicit" {
    var packet: Packet = .{};
    for (0..max_draw_items + 1) |_| packet.rect(0, 0, 1, 1, .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(max_draw_items, packet.len);
    try std.testing.expect(packet.clipped);
}
