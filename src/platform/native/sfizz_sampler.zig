const std = @import("std");
const score = @import("score");

const max_frames = 8192;
const queue_capacity = 4096;

const SynthHandle = opaque {};

const Event = extern struct {
    kind: u8,
    channel: u8,
    pitch: u8,
    velocity: u8,
    controller: u8,
};

const Api = struct {
    create_synth: *const fn () callconv(.c) ?*SynthHandle,
    free: *const fn (*SynthHandle) callconv(.c) void,
    load_file: *const fn (*SynthHandle, [*:0]const u8) callconv(.c) bool,
    set_samples_per_block: *const fn (*SynthHandle, c_int) callconv(.c) void,
    set_sample_rate: *const fn (*SynthHandle, f32) callconv(.c) void,
    set_num_voices: *const fn (*SynthHandle, c_int) callconv(.c) void,
    set_volume: *const fn (*SynthHandle, f32) callconv(.c) void,
    get_num_regions: *const fn (*SynthHandle) callconv(.c) c_int,
    get_num_preloaded_samples: *const fn (*SynthHandle) callconv(.c) usize,
    send_note_on: *const fn (*SynthHandle, c_int, c_int, c_int) callconv(.c) void,
    send_note_off: *const fn (*SynthHandle, c_int, c_int, c_int) callconv(.c) void,
    send_cc: *const fn (*SynthHandle, c_int, c_int, c_int) callconv(.c) void,
    all_sound_off: *const fn (*SynthHandle) callconv(.c) void,
    render_block: *const fn (*SynthHandle, [*c][*c]f32, c_int, c_int) callconv(.c) void,

    fn load(library: *std.DynLib) !Api {
        var api: Api = undefined;
        api.create_synth = try symbol(library, @TypeOf(api.create_synth), "sfizz_create_synth");
        api.free = try symbol(library, @TypeOf(api.free), "sfizz_free");
        api.load_file = try symbol(library, @TypeOf(api.load_file), "sfizz_load_file");
        api.set_samples_per_block = try symbol(library, @TypeOf(api.set_samples_per_block), "sfizz_set_samples_per_block");
        api.set_sample_rate = try symbol(library, @TypeOf(api.set_sample_rate), "sfizz_set_sample_rate");
        api.set_num_voices = try symbol(library, @TypeOf(api.set_num_voices), "sfizz_set_num_voices");
        api.set_volume = try symbol(library, @TypeOf(api.set_volume), "sfizz_set_volume");
        api.get_num_regions = try symbol(library, @TypeOf(api.get_num_regions), "sfizz_get_num_regions");
        api.get_num_preloaded_samples = try symbol(library, @TypeOf(api.get_num_preloaded_samples), "sfizz_get_num_preloaded_samples");
        api.send_note_on = try symbol(library, @TypeOf(api.send_note_on), "sfizz_send_note_on");
        api.send_note_off = try symbol(library, @TypeOf(api.send_note_off), "sfizz_send_note_off");
        api.send_cc = try symbol(library, @TypeOf(api.send_cc), "sfizz_send_cc");
        api.all_sound_off = try symbol(library, @TypeOf(api.all_sound_off), "sfizz_all_sound_off");
        api.render_block = try symbol(library, @TypeOf(api.render_block), "sfizz_render_block");
        return api;
    }
};

/// Conventional detail controls used by the two Salamander piano packs. The
/// SFZ files label CC20...23 explicitly; keeping the values in one type avoids
/// the native host, verifier, and live tuning path silently drifting apart.
pub const PianoDetailProfile = struct {
    sampled_release: u8,
    hammer_noise: u8,
    pedal_noise: u8,
    pedal_resonance: u8,

    pub const studio: PianoDetailProfile = .{
        .sampled_release = 64,
        .hammer_noise = 64,
        .pedal_noise = 64,
        .pedal_resonance = 64,
    };

    pub const dry: PianoDetailProfile = .{
        .sampled_release = 0,
        .hammer_noise = 0,
        .pedal_noise = 0,
        .pedal_resonance = 0,
    };
};

fn symbol(library: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return library.lookup(T, name) orelse error.MissingSamplerSymbol;
}

/// Native SFZ service. The main/UI thread only writes to the SPSC event queue;
/// all sfizz MIDI calls and rendering happen on the CoreAudio callback thread.
/// This keeps the sampler's real-time contract explicit and allocation-free.
pub const Sampler = struct {
    allocator: std.mem.Allocator,
    library: std.DynLib,
    api: Api,
    handle: *SynthHandle,
    events: [queue_capacity]Event = undefined,
    write_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dropped_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    overloaded_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    applied_sampled_release: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_hammer_noise: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_pedal_noise: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_pedal_resonance: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    left: [max_frames]f32 = undefined,
    right: [max_frames]f32 = undefined,
    click_stereo: [max_frames * 2]f32 = undefined,
    click_synth: score.synth.Synth = .{},
    region_count: u32,
    preloaded_sample_count: usize,

    pub fn create(allocator: std.mem.Allocator, library_paths: []const []const u8, sfz_path: [:0]const u8) !*Sampler {
        var library = openFirst(library_paths) orelse return error.SamplerLibraryUnavailable;
        errdefer library.close();
        const api = try Api.load(&library);
        const handle = api.create_synth() orelse return error.SamplerCreateFailed;
        errdefer api.free(handle);
        api.set_samples_per_block(handle, max_frames);
        api.set_sample_rate(handle, 48_000);
        api.set_num_voices(handle, 256);
        api.set_volume(handle, 0.0);
        if (!api.load_file(handle, sfz_path.ptr)) return error.InstrumentLoadFailed;

        const sampler = try allocator.create(Sampler);
        sampler.* = .{
            .allocator = allocator,
            .library = library,
            .api = api,
            .handle = handle,
            .region_count = @intCast(@max(0, api.get_num_regions(handle))),
            .preloaded_sample_count = api.get_num_preloaded_samples(handle),
        };
        return sampler;
    }

    pub fn destroy(self: *Sampler) void {
        self.api.all_sound_off(self.handle);
        self.api.free(self.handle);
        self.library.close();
        self.allocator.destroy(self);
    }

    pub fn noteOn(self: *Sampler, channel: u8, pitch: u8, velocity: u8) void {
        self.enqueue(.{ .kind = 1, .channel = channel & 0x0f, .pitch = pitch, .velocity = velocity, .controller = 0 });
    }

    pub fn noteOff(self: *Sampler, channel: u8, pitch: u8) void {
        self.enqueue(.{ .kind = 0, .channel = channel & 0x0f, .pitch = pitch, .velocity = 64, .controller = 0 });
    }

    pub fn allNotesOff(self: *Sampler) void {
        self.enqueue(.{ .kind = 2, .channel = 0, .pitch = 0, .velocity = 0, .controller = 0 });
    }

    pub fn controlChange(self: *Sampler, channel: u8, controller: u8, value: u8) void {
        self.enqueue(.{ .kind = 4, .channel = channel & 0x0f, .pitch = 0, .velocity = value, .controller = controller });
    }

    pub fn applyPianoDetailProfile(self: *Sampler, profile: PianoDetailProfile) void {
        self.controlChange(0, 20, profile.sampled_release);
        self.controlChange(0, 21, profile.hammer_noise);
        self.controlChange(0, 22, profile.pedal_noise);
        self.controlChange(0, 23, profile.pedal_resonance);
    }

    /// Values confirmed as consumed by the audio thread, rather than merely
    /// queued by the UI thread.
    pub fn pianoDetailProfile(self: *const Sampler) PianoDetailProfile {
        return .{
            .sampled_release = self.applied_sampled_release.load(.acquire),
            .hammer_noise = self.applied_hammer_noise.load(.acquire),
            .pedal_noise = self.applied_pedal_noise.load(.acquire),
            .pedal_resonance = self.applied_pedal_resonance.load(.acquire),
        };
    }

    pub fn click(self: *Sampler, accent: bool) void {
        self.enqueue(.{ .kind = 3, .channel = 0, .pitch = 0, .velocity = if (accent) 127 else 86, .controller = 0 });
    }

    pub fn droppedEventCount(self: *const Sampler) u32 {
        return self.dropped_events.load(.acquire);
    }

    /// Counts samples whose unclamped mix exceeded the audio safety ceiling.
    /// The output is still bounded, while offline/native QA can distinguish a
    /// genuinely clean render from one whose clipping was merely hidden.
    pub fn overloadedSampleCount(self: *const Sampler) u64 {
        return self.overloaded_samples.load(.acquire);
    }

    pub fn renderInterleaved(self: *Sampler, output: []f32, frame_count: usize, channels: usize, sample_rate: f32) void {
        if (channels == 0 or frame_count == 0) return;
        const frames = @min(frame_count, max_frames);
        self.consumeEvents();
        @memset(self.left[0..frames], 0);
        @memset(self.right[0..frames], 0);
        var channel_pointers = [_][*c]f32{ self.left[0..frames].ptr, self.right[0..frames].ptr };
        self.api.render_block(self.handle, &channel_pointers, 2, @intCast(frames));
        self.click_synth.renderInterleaved(self.click_stereo[0 .. frames * 2], frames, 2, sample_rate);

        @memset(output, 0);
        for (0..frames) |frame| {
            const left = self.left[frame] + self.click_stereo[frame * 2];
            const right = self.right[frame] + self.click_stereo[frame * 2 + 1];
            if (@abs(left) > 0.98) _ = self.overloaded_samples.fetchAdd(1, .monotonic);
            if (@abs(right) > 0.98) _ = self.overloaded_samples.fetchAdd(1, .monotonic);
            if (channels == 1) {
                output[frame] = std.math.clamp((left + right) * 0.5, -0.98, 0.98);
            } else {
                output[frame * channels] = std.math.clamp(left, -0.98, 0.98);
                output[frame * channels + 1] = std.math.clamp(right, -0.98, 0.98);
                for (2..channels) |channel| output[frame * channels + channel] = 0;
            }
        }
    }

    fn enqueue(self: *Sampler, event: Event) void {
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % queue_capacity;
        if (next == self.read_index.load(.acquire)) {
            _ = self.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        self.events[write] = event;
        self.write_index.store(next, .release);
    }

    fn consumeEvents(self: *Sampler) void {
        var read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        while (read != write) {
            const event = self.events[read];
            // sfizz's first integer is an intra-render-block sample delay, not
            // a MIDI channel. This process owns one piano instrument, so every
            // queued event starts at the next callback boundary (delay zero)
            // while the original MIDI channel remains preserved in the score
            // and recording models.
            switch (event.kind) {
                0 => self.api.send_note_off(self.handle, 0, event.pitch, event.velocity),
                1 => self.api.send_note_on(self.handle, 0, event.pitch, @max(1, event.velocity)),
                2 => self.api.all_sound_off(self.handle),
                3 => self.click_synth.click(event.velocity >= 120),
                4 => {
                    self.api.send_cc(self.handle, 0, event.controller, event.velocity);
                    switch (event.controller) {
                        20 => self.applied_sampled_release.store(event.velocity, .release),
                        21 => self.applied_hammer_noise.store(event.velocity, .release),
                        22 => self.applied_pedal_noise.store(event.velocity, .release),
                        23 => self.applied_pedal_resonance.store(event.velocity, .release),
                        else => {},
                    }
                },
                else => {},
            }
            read = (read + 1) % queue_capacity;
        }
        self.read_index.store(read, .release);
    }
};

fn openFirst(paths: []const []const u8) ?std.DynLib {
    for (paths) |path| return std.DynLib.open(path) catch continue;
    return null;
}
