const std = @import("std");

pub const Decoded = struct {
    sample_rate: u32,
    samples: []f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Decoded) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidWave,
    UnsupportedEncoding,
    InvalidChannelCount,
    InvalidSampleRate,
    TruncatedData,
};

pub fn decode(allocator: std.mem.Allocator, source: []const u8) (Error || std.mem.Allocator.Error)!Decoded {
    if (source.len < 12 or !std.mem.eql(u8, source[0..4], "RIFF") or !std.mem.eql(u8, source[8..12], "WAVE")) return error.InvalidWave;
    var format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var block_align: u16 = 0;
    var data: ?[]const u8 = null;
    var cursor: usize = 12;
    while (cursor + 8 <= source.len) {
        const id = source[cursor .. cursor + 4];
        const size: usize = readU32(source[cursor + 4 .. cursor + 8]);
        const start = cursor + 8;
        if (size > source.len -| start) return error.TruncatedData;
        const chunk = source[start .. start + size];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (chunk.len < 16) return error.InvalidWave;
            format = readU16(chunk[0..2]);
            channels = readU16(chunk[2..4]);
            sample_rate = readU32(chunk[4..8]);
            block_align = readU16(chunk[12..14]);
            bits_per_sample = readU16(chunk[14..16]);
        } else if (std.mem.eql(u8, id, "data")) {
            data = chunk;
        }
        cursor = start + size + (size & 1);
    }
    const encoded = data orelse return error.InvalidWave;
    if (channels == 0 or channels > 32) return error.InvalidChannelCount;
    if (sample_rate < 4_000 or sample_rate > 384_000) return error.InvalidSampleRate;
    const bytes_per_sample = bits_per_sample / 8;
    if (block_align == 0 or bytes_per_sample == 0 or block_align < channels * bytes_per_sample) return error.UnsupportedEncoding;
    if (!((format == 1 and (bits_per_sample == 16 or bits_per_sample == 24 or bits_per_sample == 32)) or (format == 3 and bits_per_sample == 32))) return error.UnsupportedEncoding;

    const frame_count = encoded.len / block_align;
    const samples = try allocator.alloc(f32, frame_count);
    errdefer allocator.free(samples);
    for (samples, 0..) |*output, frame| {
        var mixed: f32 = 0;
        const frame_start = frame * block_align;
        for (0..channels) |channel| {
            const offset = frame_start + channel * bytes_per_sample;
            mixed += switch (format) {
                3 => @bitCast(readU32(encoded[offset .. offset + 4])),
                else => switch (bits_per_sample) {
                    16 => @as(f32, @floatFromInt(readI16(encoded[offset .. offset + 2]))) / 32768.0,
                    24 => @as(f32, @floatFromInt(readI24(encoded[offset .. offset + 3]))) / 8_388_608.0,
                    32 => @as(f32, @floatFromInt(readI32(encoded[offset .. offset + 4]))) / 2_147_483_648.0,
                    else => unreachable,
                },
            };
        }
        output.* = std.math.clamp(mixed / @as(f32, @floatFromInt(channels)), -1, 1);
    }
    return .{ .sample_rate = sample_rate, .samples = samples, .allocator = allocator };
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readI16(bytes: []const u8) i16 {
    return @bitCast(readU16(bytes));
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readI24(bytes: []const u8) i32 {
    const raw = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
    return if ((raw & 0x800000) != 0) @bitCast(raw | 0xff000000) else @intCast(raw);
}

fn readI32(bytes: []const u8) i32 {
    return @bitCast(readU32(bytes));
}

test "decodes and downmixes PCM16 wave data" {
    const fixture = "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++ "\x01\x00" ++ "\x02\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\xee\x02\x00" ++ "\x04\x00" ++ "\x10\x00" ++
        "data" ++ "\x04\x00\x00\x00" ++ "\x00\x40\x00\x20";
    var decoded = try decode(std.testing.allocator, fixture);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), decoded.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), decoded.samples[0], 0.0001);
}
