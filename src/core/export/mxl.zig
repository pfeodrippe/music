const std = @import("std");

pub const Error = error{OutputTooSmall};

const container_xml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    \\  <rootfiles>
    \\    <rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/>
    \\  </rootfiles>
    \\</container>
;

const Entry = struct {
    name: []const u8,
    data: []const u8,
    offset: u32 = 0,
};

/// Writes a deterministic, standards-based compressed-MusicXML package.
/// Entries use ZIP's STORE method: this keeps the portable implementation
/// small while remaining a fully valid `.mxl` file for notation software.
pub fn write(output: []u8, musicxml: []const u8) Error!usize {
    var entries = [_]Entry{
        .{ .name = "mimetype", .data = "application/vnd.recordare.musicxml" },
        .{ .name = "META-INF/container.xml", .data = container_xml },
        .{ .name = "score.musicxml", .data = musicxml },
    };
    var cursor: usize = 0;
    for (&entries) |*entry| {
        entry.offset = std.math.cast(u32, cursor) orelse return error.OutputTooSmall;
        try localHeader(output, &cursor, entry.name, entry.data);
    }
    const central_offset = std.math.cast(u32, cursor) orelse return error.OutputTooSmall;
    for (entries) |entry| try centralHeader(output, &cursor, entry);
    const central_size = std.math.cast(u32, cursor - central_offset) orelse return error.OutputTooSmall;
    try le(output, &cursor, u32, 0x06054b50);
    try le(output, &cursor, u16, 0);
    try le(output, &cursor, u16, 0);
    try le(output, &cursor, u16, entries.len);
    try le(output, &cursor, u16, entries.len);
    try le(output, &cursor, u32, central_size);
    try le(output, &cursor, u32, central_offset);
    try le(output, &cursor, u16, 0);
    return cursor;
}

fn localHeader(output: []u8, cursor: *usize, name: []const u8, data: []const u8) Error!void {
    const size = std.math.cast(u32, data.len) orelse return error.OutputTooSmall;
    try le(output, cursor, u32, 0x04034b50);
    try le(output, cursor, u16, 20);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u32, std.hash.crc.Crc32.hash(data));
    try le(output, cursor, u32, size);
    try le(output, cursor, u32, size);
    try le(output, cursor, u16, name.len);
    try le(output, cursor, u16, 0);
    try bytes(output, cursor, name);
    try bytes(output, cursor, data);
}

fn centralHeader(output: []u8, cursor: *usize, entry: Entry) Error!void {
    const size = std.math.cast(u32, entry.data.len) orelse return error.OutputTooSmall;
    try le(output, cursor, u32, 0x02014b50);
    try le(output, cursor, u16, 20);
    try le(output, cursor, u16, 20);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u32, std.hash.crc.Crc32.hash(entry.data));
    try le(output, cursor, u32, size);
    try le(output, cursor, u32, size);
    try le(output, cursor, u16, entry.name.len);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u16, 0);
    try le(output, cursor, u32, 0);
    try le(output, cursor, u32, entry.offset);
    try bytes(output, cursor, entry.name);
}

fn le(output: []u8, cursor: *usize, comptime T: type, value: anytype) Error!void {
    if (cursor.* > output.len or @sizeOf(T) > output.len - cursor.*) return error.OutputTooSmall;
    const typed: T = @intCast(value);
    for (0..@sizeOf(T)) |index| output[cursor.* + index] = @truncate(typed >> @intCast(index * 8));
    cursor.* += @sizeOf(T);
}

fn bytes(output: []u8, cursor: *usize, value: []const u8) Error!void {
    if (cursor.* > output.len or value.len > output.len - cursor.*) return error.OutputTooSmall;
    @memcpy(output[cursor.* .. cursor.* + value.len], value);
    cursor.* += value.len;
}

test "MXL writer round-trips through the portable ZIP reader" {
    const extractor = @import("../import/mxl.zig");
    const source = "<?xml version=\"1.0\"?><score-partwise version=\"4.0\"/>";
    var package: [2048]u8 = undefined;
    const len = try write(&package, source);
    try std.testing.expectEqualStrings("PK\x03\x04", package[0..4]);
    const extracted = try extractor.extract(std.testing.allocator, package[0..len]);
    defer std.testing.allocator.free(extracted);
    try std.testing.expectEqualStrings(source, extracted);
}

test "MXL writer reports insufficient output capacity" {
    var tiny: [32]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, write(&tiny, "<score-partwise/>"));
}
