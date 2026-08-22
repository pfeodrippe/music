const std = @import("std");

pub const max_uncompressed_size = 64 * 1024 * 1024;

pub const Error = error{
    InvalidZip,
    UnsupportedCompression,
    MusicXmlNotFound,
    EntryTooLarge,
    ChecksumMismatch,
    DecompressionFailed,
};

/// Extracts the MusicXML root document from an MXL/ZIP package. ZIP metadata
/// is read from the central directory so data-descriptor archives work too.
/// The caller owns the returned allocation.
pub fn extract(allocator: std.mem.Allocator, source: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
    const eocd = findEndOfCentralDirectory(source) orelse return error.InvalidZip;
    const entry_count = readLe(u16, source, eocd + 10) orelse return error.InvalidZip;
    const directory_offset: usize = readLe(u32, source, eocd + 16) orelse return error.InvalidZip;
    var cursor = directory_offset;
    for (0..entry_count) |_| {
        if (readLe(u32, source, cursor) != 0x02014b50) return error.InvalidZip;
        const method = readLe(u16, source, cursor + 10) orelse return error.InvalidZip;
        const expected_crc = readLe(u32, source, cursor + 16) orelse return error.InvalidZip;
        const compressed_size: usize = readLe(u32, source, cursor + 20) orelse return error.InvalidZip;
        const uncompressed_size: usize = readLe(u32, source, cursor + 24) orelse return error.InvalidZip;
        const name_length: usize = readLe(u16, source, cursor + 28) orelse return error.InvalidZip;
        const extra_length: usize = readLe(u16, source, cursor + 30) orelse return error.InvalidZip;
        const comment_length: usize = readLe(u16, source, cursor + 32) orelse return error.InvalidZip;
        const local_offset: usize = readLe(u32, source, cursor + 42) orelse return error.InvalidZip;
        if (cursor + 46 + name_length + extra_length + comment_length > source.len) return error.InvalidZip;
        const name = source[cursor + 46 .. cursor + 46 + name_length];
        if (isScoreDocument(name)) {
            if (uncompressed_size == 0 or uncompressed_size > max_uncompressed_size) return error.EntryTooLarge;
            const local_name_length: usize = readLe(u16, source, local_offset + 26) orelse return error.InvalidZip;
            const local_extra_length: usize = readLe(u16, source, local_offset + 28) orelse return error.InvalidZip;
            const data_offset = local_offset + 30 + local_name_length + local_extra_length;
            if (data_offset > source.len or compressed_size > source.len - data_offset) return error.InvalidZip;
            const compressed = source[data_offset .. data_offset + compressed_size];
            const output = try allocator.alloc(u8, uncompressed_size);
            errdefer allocator.free(output);
            switch (method) {
                0 => {
                    if (compressed.len != output.len) return error.InvalidZip;
                    @memcpy(output, compressed);
                },
                8 => {
                    var input: std.Io.Reader = .fixed(compressed);
                    var writer: std.Io.Writer = .fixed(output);
                    var decompressor: std.compress.flate.Decompress = .init(&input, .raw, &.{});
                    const written = decompressor.reader.streamRemaining(&writer) catch return error.DecompressionFailed;
                    if (written != output.len) return error.DecompressionFailed;
                },
                else => return error.UnsupportedCompression,
            }
            if (std.hash.crc.Crc32.hash(output) != expected_crc) return error.ChecksumMismatch;
            return output;
        }
        cursor += 46 + name_length + extra_length + comment_length;
    }
    return error.MusicXmlNotFound;
}

fn isScoreDocument(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "META-INF/")) return false;
    return std.mem.endsWith(u8, name, ".musicxml") or std.mem.endsWith(u8, name, ".xml");
}

fn findEndOfCentralDirectory(source: []const u8) ?usize {
    if (source.len < 22) return null;
    const minimum = source.len - @min(source.len, 65_557);
    var cursor = source.len - 22;
    while (true) {
        if (readLe(u32, source, cursor) == 0x06054b50) return cursor;
        if (cursor == minimum) break;
        cursor -= 1;
    }
    return null;
}

fn readLe(comptime T: type, source: []const u8, offset: usize) ?T {
    if (offset > source.len or @sizeOf(T) > source.len - offset) return null;
    var value: T = 0;
    for (0..@sizeOf(T)) |index| value |= @as(T, source[offset + index]) << @intCast(index * 8);
    return value;
}

test "rejects non-ZIP MXL input" {
    try std.testing.expectError(error.InvalidZip, extract(std.testing.allocator, "not a zip"));
}
