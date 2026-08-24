const std = @import("std");
const score = @import("score");
const schedule = score.audio_schedule;
const effects = score.audio_effects;

const max_frames = 8192;
const queue_capacity = 4096;

const SynthHandle = opaque {};

const Event = struct {
    kind: u8,
    channel: u8,
    pitch: u8,
    velocity: u8,
    controller: u8,
    report_late: bool = false,
    due_frame: u64 = 0,
    sequence: u64 = 0,
};

fn eventBefore(a: Event, b: Event) bool {
    return a.due_frame < b.due_frame or (a.due_frame == b.due_frame and a.sequence < b.sequence);
}

const PendingEvents = schedule.FixedMinHeap(Event, queue_capacity, eventBefore);

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
    pending_events: PendingEvents = .{},
    write_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rendered_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    late_events: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    overloaded_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    limited_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    invalid_output_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    applied_sampled_release: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_hammer_noise: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_pedal_noise: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    applied_pedal_resonance: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    left: [max_frames]f32 = undefined,
    right: [max_frames]f32 = undefined,
    click_stereo: [max_frames * 2]f32 = undefined,
    click_delays: [queue_capacity]u32 = undefined,
    click_accents: [queue_capacity]bool = undefined,
    click_delay_count: usize = 0,
    click_synth: score.synth.Synth = .{},
    output_chain: effects.StereoOutputChain,
    region_count: u32,
    preloaded_sample_count: usize,
    write_sequence: u64 = 0,
    sample_rate: f32 = 48_000,

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
        const region_count: u32 = @intCast(@max(0, api.get_num_regions(handle)));
        if (region_count == 0) return error.EmptyInstrument;

        const sampler = try allocator.create(Sampler);
        sampler.* = .{
            .allocator = allocator,
            .library = library,
            .api = api,
            .handle = handle,
            .region_count = region_count,
            .preloaded_sample_count = api.get_num_preloaded_samples(handle),
            .output_chain = .init(48_000),
        };
        return sampler;
    }

    pub fn destroy(self: *Sampler) void {
        self.api.all_sound_off(self.handle);
        self.api.free(self.handle);
        self.library.close();
        self.allocator.destroy(self);
    }

    /// Reconfigure sfizz and every sample-rate-dependent output stage while
    /// CoreAudio is stopped. Device changes intentionally silence voices and
    /// discard queued events: retaining their frame deadlines across clock
    /// domains would produce wrong pitch, timing, or a burst on the new route.
    pub fn setSampleRate(self: *Sampler, requested_rate: f32) void {
        const rate = std.math.clamp(requested_rate, 8_000, 384_000);
        if (@abs(rate - self.sample_rate) < 0.5) return;
        self.api.all_sound_off(self.handle);
        self.api.set_sample_rate(self.handle, rate);
        const write = self.write_index.load(.acquire);
        self.read_index.store(write, .release);
        self.pending_events = .{};
        self.rendered_frames.store(0, .release);
        self.click_delay_count = 0;
        self.click_synth = .{};
        self.output_chain = .init(rate);
        self.sample_rate = rate;
        self.applyPianoDetailProfile(self.pianoDetailProfile());
    }

    pub fn noteOn(self: *Sampler, channel: u8, pitch: u8, velocity: u8) void {
        self.noteOnDelayed(channel, pitch, velocity, 0);
    }

    pub fn noteOnDelayed(self: *Sampler, channel: u8, pitch: u8, velocity: u8, delay_seconds: f32) void {
        self.enqueue(.{ .kind = 1, .channel = channel & 0x0f, .pitch = pitch, .velocity = velocity, .controller = 0 }, delay_seconds);
    }

    pub fn noteOff(self: *Sampler, channel: u8, pitch: u8) void {
        self.noteOffDelayed(channel, pitch, 0);
    }

    pub fn noteOffDelayed(self: *Sampler, channel: u8, pitch: u8, delay_seconds: f32) void {
        self.enqueue(.{ .kind = 0, .channel = channel & 0x0f, .pitch = pitch, .velocity = 64, .controller = 0 }, delay_seconds);
    }

    pub fn allNotesOff(self: *Sampler) void {
        self.allNotesOffDelayed(0);
    }

    pub fn allNotesOffDelayed(self: *Sampler, delay_seconds: f32) void {
        self.enqueue(.{ .kind = 2, .channel = 0, .pitch = 0, .velocity = 0, .controller = 0 }, delay_seconds);
    }

    pub fn controlChange(self: *Sampler, channel: u8, controller: u8, value: u8) void {
        self.controlChangeDelayed(channel, controller, value, 0);
    }

    pub fn controlChangeDelayed(self: *Sampler, channel: u8, controller: u8, value: u8, delay_seconds: f32) void {
        self.enqueue(.{ .kind = 4, .channel = channel & 0x0f, .pitch = 0, .velocity = value, .controller = controller }, delay_seconds);
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
        self.clickDelayed(accent, 0);
    }

    pub fn clickDelayed(self: *Sampler, accent: bool, delay_seconds: f32) void {
        self.enqueue(.{ .kind = 3, .channel = 0, .pitch = 0, .velocity = if (accent) 127 else 86, .controller = 0 }, delay_seconds);
    }

    pub fn droppedEventCount(self: *const Sampler) u32 {
        return self.dropped_events.load(.acquire);
    }

    pub fn lateEventCount(self: *const Sampler) u32 {
        return self.late_events.load(.acquire);
    }

    /// Counts samples whose unclamped mix exceeded the audio safety ceiling.
    /// The output is still bounded, while offline/native QA can distinguish a
    /// genuinely clean render from one whose clipping was merely hidden.
    pub fn overloadedSampleCount(self: *const Sampler) u64 {
        return self.overloaded_samples.load(.acquire);
    }

    pub fn limitedFrameCount(self: *const Sampler) u64 {
        return self.limited_frames.load(.acquire);
    }

    pub fn invalidOutputSampleCount(self: *const Sampler) u64 {
        return self.invalid_output_samples.load(.acquire);
    }

    pub fn renderInterleaved(self: *Sampler, output: []f32, frame_count: usize, channels: usize, sample_rate: f32) void {
        if (channels == 0 or frame_count == 0) return;
        const frames = @min(frame_count, max_frames);
        self.consumeEvents(frames);
        @memset(self.left[0..frames], 0);
        @memset(self.right[0..frames], 0);
        var channel_pointers = [_][*c]f32{ self.left[0..frames].ptr, self.right[0..frames].ptr };
        self.api.render_block(self.handle, &channel_pointers, 2, @intCast(frames));
        self.output_chain.post_instrument.process(self.left[0..frames], self.right[0..frames]);
        self.renderScheduledClicks(frames, sample_rate);

        @memset(output, 0);
        for (0..frames) |frame| {
            const left = self.left[frame] + self.click_stereo[frame * 2];
            const right = self.right[frame] + self.click_stereo[frame * 2 + 1];
            if (@abs(left) > 0.98) _ = self.overloaded_samples.fetchAdd(1, .monotonic);
            if (@abs(right) > 0.98) _ = self.overloaded_samples.fetchAdd(1, .monotonic);
            self.left[frame] = left;
            self.right[frame] = right;
        }
        const limiter_stats = self.output_chain.master.process(self.left[0..frames], self.right[0..frames]);
        if (limiter_stats.limited_frames != 0) _ = self.limited_frames.fetchAdd(limiter_stats.limited_frames, .monotonic);
        if (limiter_stats.non_finite_samples != 0) _ = self.invalid_output_samples.fetchAdd(limiter_stats.non_finite_samples, .monotonic);
        for (0..frames) |frame| {
            const left = self.left[frame];
            const right = self.right[frame];
            if (channels == 1) {
                output[frame] = (left + right) * 0.5;
            } else {
                output[frame * channels] = left;
                output[frame * channels + 1] = right;
                for (2..channels) |channel| output[frame * channels + channel] = 0;
            }
        }
        _ = self.rendered_frames.fetchAdd(frames, .release);
    }

    fn enqueue(self: *Sampler, source: Event, delay_seconds: f32) void {
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % queue_capacity;
        if (next == self.read_index.load(.acquire)) {
            _ = self.dropped_events.fetchAdd(1, .monotonic);
            return;
        }
        var event = source;
        event.due_frame = schedule.dueFrame(self.rendered_frames.load(.acquire), delay_seconds, self.sample_rate);
        event.report_late = delay_seconds > 0;
        event.sequence = self.write_sequence;
        self.write_sequence +%= 1;
        self.events[write] = event;
        self.write_index.store(next, .release);
    }

    fn consumeEvents(self: *Sampler, frame_count: usize) void {
        self.click_delay_count = 0;
        var read = self.read_index.load(.monotonic);
        const write = self.write_index.load(.acquire);
        while (read != write) {
            const event = self.events[read];
            if (!self.pending_events.push(event)) _ = self.dropped_events.fetchAdd(1, .monotonic);
            read = (read + 1) % queue_capacity;
        }
        self.read_index.store(read, .release);

        const block_start = self.rendered_frames.load(.monotonic);
        while (self.pending_events.peek()) |event| {
            const delay = schedule.blockOffset(event.due_frame, block_start, frame_count) orelse break;
            _ = self.pending_events.pop();
            if (event.report_late and event.due_frame < block_start) _ = self.late_events.fetchAdd(1, .monotonic);
            // sfizz's first integer is an intra-render-block sample delay. The
            // native scheduler now preserves score timing below the visual
            // frame boundary while source MIDI channels remain in the semantic
            // score/recording models.
            switch (event.kind) {
                0 => self.api.send_note_off(self.handle, @intCast(delay), event.pitch, event.velocity),
                1 => self.api.send_note_on(self.handle, @intCast(delay), event.pitch, @max(1, event.velocity)),
                // MIDI All Sound Off is delay-aware in sfizz, unlike the
                // immediate C helper, so final/repeat boundaries do not cut
                // earlier notes at the beginning of the render block.
                2 => self.api.send_cc(self.handle, @intCast(delay), 120, 0),
                3 => if (self.click_delay_count < self.click_delays.len) {
                    self.click_delays[self.click_delay_count] = delay;
                    self.click_accents[self.click_delay_count] = event.velocity >= 120;
                    self.click_delay_count += 1;
                },
                4 => {
                    self.api.send_cc(self.handle, @intCast(delay), event.controller, event.velocity);
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
        }
    }

    fn renderScheduledClicks(self: *Sampler, frame_count: usize, sample_rate: f32) void {
        @memset(self.click_stereo[0 .. frame_count * 2], 0);
        var cursor: usize = 0;
        for (self.click_delays[0..self.click_delay_count], self.click_accents[0..self.click_delay_count]) |raw_delay, accent| {
            const delay = @min(@as(usize, raw_delay), frame_count);
            if (delay > cursor) {
                self.click_synth.renderInterleaved(self.click_stereo[cursor * 2 .. delay * 2], delay - cursor, 2, sample_rate);
                cursor = delay;
            }
            self.click_synth.click(accent);
        }
        if (cursor < frame_count) self.click_synth.renderInterleaved(self.click_stereo[cursor * 2 .. frame_count * 2], frame_count - cursor, 2, sample_rate);
    }
};

fn openFirst(paths: []const []const u8) ?std.DynLib {
    for (paths) |path| return std.DynLib.open(path) catch continue;
    return null;
}
