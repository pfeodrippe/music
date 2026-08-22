const std = @import("std");
const score = @import("score");
const Sampler = @import("sfizz_sampler").Sampler;

const sample_rate = 48_000;
const channels = 2;
const block_frames = 256;
const duration_seconds = 12;

pub fn main(init: std.process.Init) !void {
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    const output_path = arguments.next() orelse ".zig-cache/verification/salamander-grand-proof.wav";
    const sfz_path = arguments.next() orelse "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    if (arguments.next() != null) return error.TooManyArguments;

    const library_paths = [_][]const u8{"zig-out/lib/libsfizz.dylib"};
    const sampler = try Sampler.create(init.gpa, &library_paths, sfz_path);
    defer sampler.destroy();

    const frame_count = sample_rate * duration_seconds;
    const output = try init.gpa.alloc(f32, frame_count * channels);
    defer init.gpa.free(output);
    @memset(output, 0);

    sampler.controlChange(0, 64, 112);
    const phrase = [_]u8{ 36, 48, 55, 60, 64, 67, 72, 76, 79, 84 };
    var next_note: usize = 0;
    var pedal_released = false;
    var chord_started = false;
    var chord_released = false;
    var frame: usize = 0;
    while (frame < frame_count) {
        while (next_note < phrase.len and frame >= next_note * sample_rate / 2) : (next_note += 1) {
            sampler.noteOn(0, phrase[next_note], @intCast(38 + next_note * 8));
            if (next_note >= 3) sampler.noteOff(0, phrase[next_note - 3]);
        }
        if (!pedal_released and frame >= sample_rate * 6) {
            pedal_released = true;
            sampler.controlChange(0, 64, 0);
            for (phrase) |pitch| sampler.noteOff(0, pitch);
        }
        if (!chord_started and frame >= sample_rate * 7) {
            chord_started = true;
            sampler.noteOn(0, 48, 58);
            sampler.noteOn(0, 55, 64);
            sampler.noteOn(0, 60, 70);
            sampler.noteOn(0, 64, 76);
            sampler.noteOn(0, 67, 82);
        }
        if (!chord_released and frame >= sample_rate * 9) {
            chord_released = true;
            sampler.noteOff(0, 48);
            sampler.noteOff(0, 55);
            sampler.noteOff(0, 60);
            sampler.noteOff(0, 64);
            sampler.noteOff(0, 67);
        }
        const count = @min(block_frames, frame_count - frame);
        sampler.renderInterleaved(output[frame * channels .. (frame + count) * channels], count, channels, sample_rate);
        frame += count;
    }

    const encoded = try score.wav.encodePcm16(init.gpa, output, sample_rate, channels);
    defer init.gpa.free(encoded);
    if (std.fs.path.dirname(output_path)) |directory| try std.Io.Dir.cwd().createDirPath(init.io, directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });
    std.log.info("rendered {s}: {d} regions, {d} preloaded samples", .{ output_path, sampler.region_count, sampler.preloaded_sample_count });
}
