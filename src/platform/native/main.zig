const std = @import("std");
const score = @import("score");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const build_options = @import("build_options");
const sfizz_sampler = @import("sfizz_sampler.zig");
const SfizzSampler = sfizz_sampler.Sampler;
const dev_control = @import("dev_control.zig");

extern fn glfwGetMonitorWorkarea(monitor: *zglfw.Monitor, xpos: ?*c_int, ypos: ?*c_int, width: ?*c_int, height: ?*c_int) void;

const native_c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("open_panel.h");
    @cInclude("music_devices.h");
});

const shader_source = @embedFile("score_ui.wgsl");

const Uniforms = extern struct {
    viewport: [2]f32,
    time: f32,
    pixel_ratio: f32,
};

const MicrophoneMonitor = struct {
    sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    consumed: u32 = 0,
    pitch_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pitches: [score.pitch.max_polyphonic_pitches]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** score.pitch.max_polyphonic_pitches,
    confidence_bits: [score.pitch.max_polyphonic_pitches]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** score.pitch.max_polyphonic_pitches,
    timestamp_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// AudioQueue serializes callbacks, so the attack tracker is owned
    /// exclusively by its real-time producer and needs no atomics internally.
    attack_tracker: score.pitch.AttackTracker = .{},
    analysis_windows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    analysis_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    analysis_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    published_attacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn averageAnalysisMilliseconds(self: *const MicrophoneMonitor) f64 {
        const windows = self.analysis_windows.load(.acquire);
        if (windows == 0) return 0;
        return @as(f64, @floatFromInt(self.analysis_total_ns.load(.acquire))) / @as(f64, @floatFromInt(windows)) / std.time.ns_per_ms;
    }
};

const InputSelection = struct {
    /// `maxInt(u32)` means every current CoreMIDI source is connected.
    midi_source: u32 = std.math.maxInt(u32),
    microphone: bool = false,
    /// Index in the filtered CoreAudio input-device list. `maxInt(u32)` asks
    /// the platform facade to resolve the current system default.
    audio_device: u32 = std.math.maxInt(u32),
};

/// CoreAudio can spend seconds resolving a sleeping wireless input. Keep that
/// work off the render/event thread while preserving a single callback owner
/// for the microphone analyzer. Stopping the old queue is quick and happens
/// before the worker starts; the worker falls back to the previous device if
/// the requested queue cannot be created.
const AudioInputSwitch = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_bits: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    requested_device: u32 = std.math.maxInt(u32),
    previous_device: u32 = std.math.maxInt(u32),
    input_count: u32 = 0,
    requested_name: [128]u8 = [_]u8{0} ** 128,
    requested_name_len: usize = 0,
    select_route: bool = false,
    monitor: ?*MicrophoneMonitor = null,

    fn begin(self: *AudioInputSwitch, input: *?*native_c.ScoreAudioInput, monitor: *MicrophoneMonitor, requested_device: u32, select_route: bool) bool {
        if (self.thread != null) return false;
        if (input.*) |active_input| {
            if (native_c.score_audio_input_is_recording(active_input) != 0) return false;
            self.previous_device = native_c.score_audio_input_selected_device(active_input);
        } else {
            self.previous_device = std.math.maxInt(u32);
        }
        native_c.score_audio_input_stop(input.*);
        input.* = null;
        resetMicrophoneMonitor(monitor);
        self.requested_device = requested_device;
        self.input_count = native_c.score_audio_input_device_count();
        self.requested_name_len = native_c.score_audio_input_device_name(requested_device, &self.requested_name, self.requested_name.len);
        self.select_route = select_route;
        self.monitor = monitor;
        self.result_bits.store(0, .release);
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, audioInputSwitchWorker, .{self}) catch return false;
        return true;
    }

    fn poll(self: *AudioInputSwitch, input: *?*native_c.ScoreAudioInput) bool {
        if (self.thread == null or !self.done.load(.acquire)) return false;
        self.thread.?.join();
        self.thread = null;
        const bits = self.result_bits.swap(0, .acq_rel);
        input.* = if (bits == 0) null else @ptrFromInt(bits);
        self.monitor = null;
        return true;
    }

    fn deinit(self: *AudioInputSwitch) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const bits = self.result_bits.swap(0, .acq_rel);
        if (bits != 0) native_c.score_audio_input_stop(@ptrFromInt(bits));
    }

    fn active(self: *const AudioInputSwitch) bool {
        return self.thread != null;
    }

    fn pendingLabel(self: *const AudioInputSwitch, output: []u8) []const u8 {
        const name = if (self.requested_name_len == 0)
            "DEFAULT AUDIO INPUT"
        else
            self.requested_name[0..@min(self.requested_name_len, self.requested_name.len)];
        return std.fmt.bufPrint(output, "AUDIO / {s}", .{name}) catch "AUDIO INPUT";
    }
};

fn audioInputSwitchWorker(state: *AudioInputSwitch) void {
    const monitor = state.monitor orelse {
        state.done.store(true, .release);
        return;
    };
    var result = native_c.score_audio_input_start_device(audioInput, monitor, state.requested_device);
    if (result == null and state.previous_device < native_c.score_audio_input_device_count()) {
        result = native_c.score_audio_input_start_device(audioInput, monitor, state.previous_device);
    }
    state.result_bits.store(if (result) |input| @intFromPtr(input) else 0, .release);
    state.done.store(true, .release);
}

const PerformanceMonitor = struct {
    frame_count: u64 = 0,
    frame_seconds_total: f64 = 0,
    frame_seconds_max: f64 = 0,
    work_seconds_total: f64 = 0,
    work_seconds_max: f64 = 0,
    present_seconds_total: f64 = 0,
    present_seconds_max: f64 = 0,
    acquire_wait_seconds_total: f64 = 0,
    acquire_wait_seconds_max: f64 = 0,
    missed_120hz: u64 = 0,
    missed_60hz: u64 = 0,
    maximum_draw_items: usize = 0,

    fn record(self: *PerformanceMonitor, frame_seconds: f64, work_seconds: f64, acquire_wait_seconds: f64, present_seconds: f64, draw_items: usize) void {
        if (!(frame_seconds > 0) or !std.math.isFinite(frame_seconds)) return;
        const safe_work = if (work_seconds > 0 and std.math.isFinite(work_seconds)) work_seconds else 0;
        const safe_acquire_wait = if (acquire_wait_seconds > 0 and std.math.isFinite(acquire_wait_seconds)) acquire_wait_seconds else 0;
        const safe_present = if (present_seconds > 0 and std.math.isFinite(present_seconds)) present_seconds else 0;
        self.frame_count += 1;
        self.frame_seconds_total += frame_seconds;
        self.frame_seconds_max = @max(self.frame_seconds_max, frame_seconds);
        self.work_seconds_total += safe_work;
        self.work_seconds_max = @max(self.work_seconds_max, safe_work);
        self.acquire_wait_seconds_total += safe_acquire_wait;
        self.acquire_wait_seconds_max = @max(self.acquire_wait_seconds_max, safe_acquire_wait);
        self.present_seconds_total += safe_present;
        self.present_seconds_max = @max(self.present_seconds_max, safe_present);
        // Half a millisecond prevents a nominal 8.333 ms vsync interval from
        // being counted as a miss solely because of timer quantization.
        if (frame_seconds > 1.0 / 120.0 + 0.0005) self.missed_120hz += 1;
        if (frame_seconds > 1.0 / 60.0 + 0.0005) self.missed_60hz += 1;
        self.maximum_draw_items = @max(self.maximum_draw_items, draw_items);
    }

    fn reset(self: *PerformanceMonitor) void {
        self.* = .{};
    }

    fn averageFrameMilliseconds(self: *const PerformanceMonitor) f64 {
        return if (self.frame_count == 0) 0 else self.frame_seconds_total * 1000 / @as(f64, @floatFromInt(self.frame_count));
    }

    fn averageWorkMilliseconds(self: *const PerformanceMonitor) f64 {
        return if (self.frame_count == 0) 0 else self.work_seconds_total * 1000 / @as(f64, @floatFromInt(self.frame_count));
    }

    fn averagePresentMilliseconds(self: *const PerformanceMonitor) f64 {
        return if (self.frame_count == 0) 0 else self.present_seconds_total * 1000 / @as(f64, @floatFromInt(self.frame_count));
    }

    fn averageAcquireWaitMilliseconds(self: *const PerformanceMonitor) f64 {
        return if (self.frame_count == 0) 0 else self.acquire_wait_seconds_total * 1000 / @as(f64, @floatFromInt(self.frame_count));
    }
};

const CaptureMapState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(wgpu.BufferMapAsyncStatus.unknown)),
};

const PipelineCreateState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(wgpu.CreatePipelineAsyncStatus.unknown)),
    pipeline: ?wgpu.RenderPipeline = null,
    message_len: usize = 0,
    message: [2048]u8 = [_]u8{0} ** 2048,
};

const ErrorScopeState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err_type: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(wgpu.ErrorType.unknown)),
    message_len: usize = 0,
    message: [2048]u8 = [_]u8{0} ** 2048,
};

fn captureMapped(status: wgpu.BufferMapAsyncStatus, context: ?*anyopaque) callconv(.c) void {
    const state: *CaptureMapState = @ptrCast(@alignCast(context orelse return));
    state.status.store(@intFromEnum(status), .monotonic);
    state.done.store(true, .release);
}

fn pipelineCreated(status: wgpu.CreatePipelineAsyncStatus, pipeline: wgpu.RenderPipeline, message: ?[*:0]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *PipelineCreateState = @ptrCast(@alignCast(context orelse return));
    state.status.store(@intFromEnum(status), .monotonic);
    if (status == .success) state.pipeline = pipeline;
    if (message) |value| {
        const source = std.mem.span(value);
        state.message_len = @min(source.len, state.message.len);
        @memcpy(state.message[0..state.message_len], source[0..state.message_len]);
    }
    state.done.store(true, .release);
}

fn errorScopeCompleted(err_type: wgpu.ErrorType, message: ?[*:0]const u8, context: ?*anyopaque) callconv(.c) void {
    const state: *ErrorScopeState = @ptrCast(@alignCast(context orelse return));
    state.err_type.store(@intFromEnum(err_type), .monotonic);
    if (message) |value| {
        const source = std.mem.span(value);
        state.message_len = @min(source.len, state.message.len);
        @memcpy(state.message[0..state.message_len], source[0..state.message_len]);
    }
    state.done.store(true, .release);
}

const DevReloader = if (build_options.hot_reload) struct {
    const plugin_path: [:0]const u8 = "zig-out/lib/libscore-systems.dylib";
    const Entry = *const fn () callconv(.c) *const score.hot_reload.PluginDescriptor;

    library: ?std.DynLib = null,
    staged_path: [512:0]u8 = undefined,
    staged_path_len: usize = 0,
    modified_ns: i128 = -1,
    next_poll: f64 = 0,

    fn poll(self: *@This(), app: *score.App, now: f64) void {
        if (now < self.next_poll) return;
        self.next_poll = now + 0.2;
        const source_path = pluginPath();
        const stamp = modificationTime(source_path) orelse return;
        if (stamp == self.modified_ns) return;

        // Point every callback back into the monolith before unloading code.
        app.restoreBuiltinSystems();
        if (self.library) |*old| old.close();
        self.library = null;
        self.removeStaged();

        var path_buffer: [512:0]u8 = undefined;
        const source_slice = std.mem.span(source_path);
        const directory = if (std.mem.lastIndexOfScalar(u8, source_slice, '/')) |slash| source_slice[0..slash] else ".";
        const staged = std.fmt.bufPrintZ(&path_buffer, "{s}/.score-systems-hot-{d}.dylib", .{ directory, stamp }) catch {
            std.log.err("hot reload path is too long", .{});
            return;
        };
        stagePlugin(source_path, staged) catch |err| {
            std.log.warn("hot reload staging deferred: {s}", .{@errorName(err)});
            return;
        };
        var candidate = std.DynLib.open(staged) catch |err| {
            _ = native_c.unlink(staged.ptr);
            std.log.warn("hot reload deferred: {s}", .{@errorName(err)});
            return;
        };
        const entry = candidate.lookup(Entry, "score_plugin_descriptor") orelse {
            candidate.close();
            _ = native_c.unlink(staged.ptr);
            self.modified_ns = stamp;
            std.log.err("hot reload module has no score_plugin_descriptor", .{});
            return;
        };
        app.applySystemPlugin(entry()) catch |err| {
            candidate.close();
            _ = native_c.unlink(staged.ptr);
            app.restoreBuiltinSystems();
            self.modified_ns = stamp;
            std.log.err("hot reload rejected: {s}", .{@errorName(err)});
            return;
        };
        self.library = candidate;
        std.mem.copyForwards(u8, self.staged_path[0..staged.len], staged);
        self.staged_path[staged.len] = 0;
        self.staged_path_len = staged.len;
        self.modified_ns = stamp;
        std.log.info("systems and GPU screen composition hot-reloaded; Flecs world preserved", .{});
    }

    fn deinit(self: *@This(), app: *score.App) void {
        app.restoreBuiltinSystems();
        if (self.library) |*library| library.close();
        self.library = null;
        self.removeStaged();
    }

    fn force(self: *@This()) void {
        self.modified_ns = -1;
        self.next_poll = 0;
    }

    fn removeStaged(self: *@This()) void {
        if (self.staged_path_len == 0) return;
        _ = native_c.unlink(self.staged_path[0..self.staged_path_len :0].ptr);
        self.staged_path_len = 0;
    }

    /// Darwin can retain a dlopen image for a path after dlclose. Loading a
    /// uniquely named, fully written copy guarantees that a changed module is
    /// fresh code rather than dyld's cached image.
    fn stagePlugin(source_path: [*:0]const u8, destination_path: [:0]const u8) !void {
        const source = native_c.fopen(source_path, "rb") orelse return error.StageOpenSourceFailed;
        defer _ = native_c.fclose(source);
        const destination = native_c.fopen(destination_path.ptr, "wb") orelse return error.StageOpenDestinationFailed;
        var complete = false;
        defer {
            if (!complete) _ = native_c.unlink(destination_path.ptr);
        }
        defer _ = native_c.fclose(destination);

        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const read_count = native_c.fread(&buffer, 1, buffer.len, source);
            if (read_count == 0) break;
            if (native_c.fwrite(&buffer, 1, read_count, destination) != read_count) return error.StageWriteFailed;
        }
        if (native_c.ferror(source) != 0) return error.StageReadFailed;
        if (native_c.fflush(destination) != 0) return error.StageFlushFailed;
        complete = true;
    }

    fn pluginPath() [*:0]const u8 {
        const configured = native_c.getenv("SCORE_HOT_RELOAD_PLUGIN");
        if (configured != null and configured[0] != 0) return configured;
        return plugin_path.ptr;
    }

    fn modificationTime(path: [*:0]const u8) ?i128 {
        var info: native_c.struct_stat = undefined;
        if (native_c.stat(path, &info) != 0) return null;
        return @as(i128, info.st_mtimespec.tv_sec) * std.time.ns_per_s + info.st_mtimespec.tv_nsec;
    }
} else struct {
    fn poll(_: *@This(), _: *score.App, _: f64) void {}
    fn deinit(_: *@This(), _: *score.App) void {}
    fn force(_: *@This()) void {}
};

const Renderer = struct {
    const DrawTiming = struct {
        work_seconds: f64 = 0,
        acquire_wait_seconds: f64 = 0,
        present_seconds: f64 = 0,
    };

    context: *zgpu.GraphicsContext,
    pipeline: wgpu.RenderPipeline,
    bind_group_layout: wgpu.BindGroupLayout,
    pipeline_layout: wgpu.PipelineLayout,
    bind_group: wgpu.BindGroup,
    uniforms: wgpu.Buffer,
    instances: wgpu.Buffer,
    atlas_texture: wgpu.Texture,
    atlas_view: wgpu.TextureView,
    atlas_sampler: wgpu.Sampler,
    shader_generation: u32,
    shader_error_len: usize,
    shader_error: [2048]u8,

    fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !Renderer {
        const context = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{ .present_mode = .fifo },
        );
        errdefer context.destroy(allocator);

        const uniforms = context.device.createBuffer(.{
            .label = "score frame uniforms",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(Uniforms),
        });
        errdefer uniforms.release();

        const instances = context.device.createBuffer(.{
            .label = "score ui instances",
            .usage = .{ .storage = true, .copy_dst = true },
            .size = score.render.max_draw_items * @sizeOf(score.render.DrawItem),
        });
        errdefer instances.release();

        const atlas_texture = context.device.createTexture(.{
            .label = "score Inter and Bravura glyph atlas",
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{ .width = score.glyph_atlas.width, .height = score.glyph_atlas.height },
            .format = .rgba8_unorm,
        });
        errdefer atlas_texture.release();
        const atlas_view = atlas_texture.createView(.{});
        errdefer atlas_view.release();
        const atlas_sampler = context.device.createSampler(.{
            .label = "score glyph atlas sampler",
            .mag_filter = .linear,
            .min_filter = .linear,
        });
        errdefer atlas_sampler.release();
        context.queue.writeTexture(
            .{ .texture = atlas_texture },
            .{ .offset = 0, .bytes_per_row = score.glyph_atlas.width * 4, .rows_per_image = score.glyph_atlas.height },
            .{ .width = score.glyph_atlas.width, .height = score.glyph_atlas.height },
            u8,
            score.glyph_atlas.pixels,
        );

        const layout_entries = [_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true, .fragment = true },
                .buffer = .{ .binding_type = .uniform, .min_binding_size = @sizeOf(Uniforms) },
            },
            .{
                .binding = 1,
                .visibility = .{ .vertex = true, .fragment = true },
                .buffer = .{ .binding_type = .read_only_storage, .min_binding_size = @sizeOf(score.render.DrawItem) },
            },
            .{
                .binding = 2,
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d },
            },
            .{
                .binding = 3,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .filtering },
            },
        };
        const bind_group_layout = context.device.createBindGroupLayout(.{
            .label = "score ui bind group layout",
            .entry_count = layout_entries.len,
            .entries = &layout_entries,
        });
        errdefer bind_group_layout.release();

        const layouts = [_]wgpu.BindGroupLayout{bind_group_layout};
        const pipeline_layout = context.device.createPipelineLayout(.{
            .label = "score ui pipeline layout",
            .bind_group_layout_count = layouts.len,
            .bind_group_layouts = &layouts,
        });
        errdefer pipeline_layout.release();

        const shader = zgpu.createWgslShaderModule(context.device, shader_source, "score ui shader");
        defer shader.release();

        const blend = wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &blend,
        }};
        const fragment = wgpu.FragmentState{
            .module = shader,
            .entry_point = "fs_main",
            .target_count = targets.len,
            .targets = &targets,
        };
        const pipeline = context.device.createRenderPipeline(.{
            .label = "score procedural ui pipeline",
            .layout = pipeline_layout,
            .vertex = .{ .module = shader, .entry_point = "vs_main" },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .fragment = &fragment,
        });
        errdefer pipeline.release();

        const entries = [_]wgpu.BindGroupEntry{
            .{ .binding = 0, .buffer = uniforms, .size = @sizeOf(Uniforms) },
            .{ .binding = 1, .buffer = instances, .size = score.render.max_draw_items * @sizeOf(score.render.DrawItem) },
            .{ .binding = 2, .size = 0, .texture_view = atlas_view },
            .{ .binding = 3, .size = 0, .sampler = atlas_sampler },
        };
        const bind_group = context.device.createBindGroup(.{
            .label = "score ui bind group",
            .layout = bind_group_layout,
            .entry_count = entries.len,
            .entries = &entries,
        });
        errdefer bind_group.release();

        return .{
            .context = context,
            .pipeline = pipeline,
            .bind_group_layout = bind_group_layout,
            .pipeline_layout = pipeline_layout,
            .bind_group = bind_group,
            .uniforms = uniforms,
            .instances = instances,
            .atlas_texture = atlas_texture,
            .atlas_view = atlas_view,
            .atlas_sampler = atlas_sampler,
            .shader_generation = 0,
            .shader_error_len = 0,
            .shader_error = [_]u8{0} ** 2048,
        };
    }

    /// Build a replacement pipeline asynchronously so Dawn can return complete
    /// WGSL and interface validation diagnostics. The active pipeline is not
    /// released until the candidate succeeds, which makes failed edits
    /// non-destructive during native development.
    fn reloadShaderSource(self: *Renderer, source: [*:0]const u8) !void {
        // zgpu deliberately terminates Debug processes on uncaptured WebGPU
        // errors. Keep candidate validation inside a scope so an invalid edit
        // becomes a recoverable developer diagnostic instead.
        self.context.device.pushErrorScope(.validation);
        const shader = zgpu.createWgslShaderModule(self.context.device, source, "score hot WGSL shader");
        defer shader.release();

        const blend = wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &blend,
        }};
        const fragment = wgpu.FragmentState{
            .module = shader,
            .entry_point = "fs_main",
            .target_count = targets.len,
            .targets = &targets,
        };
        const descriptor = wgpu.RenderPipelineDescriptor{
            .label = "score hot procedural ui pipeline",
            .layout = self.pipeline_layout,
            .vertex = .{ .module = shader, .entry_point = "vs_main" },
            .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
            .fragment = &fragment,
        };
        var state: PipelineCreateState = .{};
        self.context.device.createRenderPipelineAsync(descriptor, pipelineCreated, &state);
        const deadline = zglfw.getTime() + 5;
        while (!state.done.load(.acquire) and zglfw.getTime() < deadline) self.context.device.tick();

        var validation: ErrorScopeState = .{};
        // This pinned zgpu revision declares a bool even though Dawn's C ABI
        // returns void; the callback is the authoritative completion signal.
        _ = self.context.device.popErrorScope(errorScopeCompleted, &validation);
        const validation_deadline = zglfw.getTime() + 5;
        while (!validation.done.load(.acquire) and zglfw.getTime() < validation_deadline) self.context.device.tick();
        if (!validation.done.load(.acquire)) {
            self.setShaderError("shader validation diagnostics timed out");
            return error.ShaderValidationTimedOut;
        }
        if (validation.err_type.load(.monotonic) != @intFromEnum(wgpu.ErrorType.no_error)) {
            if (state.pipeline) |candidate| candidate.release();
            self.setShaderError(if (validation.message_len == 0) "Dawn rejected the shader" else validation.message[0..validation.message_len]);
            return error.ShaderPipelineRejected;
        }
        if (!state.done.load(.acquire)) {
            self.setShaderError("pipeline validation timed out");
            return error.ShaderValidationTimedOut;
        }
        if (state.status.load(.monotonic) != @intFromEnum(wgpu.CreatePipelineAsyncStatus.success)) {
            self.setShaderError(if (state.message_len == 0) "Dawn rejected the shader pipeline" else state.message[0..state.message_len]);
            return error.ShaderPipelineRejected;
        }
        const candidate = state.pipeline orelse {
            self.setShaderError("Dawn returned no pipeline after successful validation");
            return error.ShaderPipelineMissing;
        };
        const previous = self.pipeline;
        self.pipeline = candidate;
        previous.release();
        self.shader_generation +%= 1;
        self.shader_error_len = 0;
    }

    fn setShaderError(self: *Renderer, message: []const u8) void {
        self.shader_error_len = @min(message.len, self.shader_error.len);
        @memcpy(self.shader_error[0..self.shader_error_len], message[0..self.shader_error_len]);
    }

    fn shaderError(self: *const Renderer) []const u8 {
        return self.shader_error[0..self.shader_error_len];
    }

    fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.bind_group.release();
        self.atlas_sampler.release();
        self.atlas_view.release();
        self.atlas_texture.release();
        self.pipeline.release();
        self.pipeline_layout.release();
        self.bind_group_layout.release();
        self.instances.release();
        self.uniforms.release();
        self.context.destroy(allocator);
        self.* = undefined;
    }

    fn draw(self: *Renderer, app: *const score.App, logical_size: [2]i32, scale: [2]f32, time: f32) DrawTiming {
        if (!self.context.canRender()) return .{};
        const started = zglfw.getTime();
        const width: f32 = @floatFromInt(@max(logical_size[0], 1));
        const height: f32 = @floatFromInt(@max(logical_size[1], 1));
        const frame = Uniforms{ .viewport = .{ width, height }, .time = time, .pixel_ratio = scale[0] };
        const items = app.drawItems();
        self.context.queue.writeBuffer(self.uniforms, 0, Uniforms, (&[_]Uniforms{frame})[0..]);
        if (items.len != 0) self.context.queue.writeBuffer(self.instances, 0, score.render.DrawItem, items);

        const before_acquire = zglfw.getTime();
        const back_buffer = self.context.swapchain.getCurrentTextureView();
        const acquired = zglfw.getTime();
        defer back_buffer.release();
        const encoder = self.context.device.createCommandEncoder(null);
        defer encoder.release();
        self.encodePass(encoder, back_buffer, items);
        const commands = encoder.finish(null);
        defer commands.release();
        self.context.submit(&.{commands});
        const submitted = zglfw.getTime();
        _ = self.context.present();
        const completed = zglfw.getTime();
        return .{
            // CAMetalLayer::nextDrawable intentionally waits for display
            // pacing. Keep that wait out of CPU/GPU command construction so
            // the work metric remains useful at both 60 Hz and 120 Hz.
            .work_seconds = before_acquire - started + submitted - acquired,
            .acquire_wait_seconds = acquired - before_acquire,
            .present_seconds = completed - submitted,
        };
    }

    fn encodePass(self: *Renderer, encoder: wgpu.CommandEncoder, target: wgpu.TextureView, items: []const score.render.DrawItem) void {
        const attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = target,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.035, .g = 0.043, .b = 0.055, .a = 1 },
        }};
        const pass = encoder.beginRenderPass(.{
            .label = "score frame",
            .color_attachment_count = attachments.len,
            .color_attachments = &attachments,
        });
        pass.setPipeline(self.pipeline);
        pass.setBindGroup(0, self.bind_group, null);
        pass.draw(6, @intCast(items.len), 0, 0);
        pass.end();
        pass.release();
    }

    /// Debug-only visual QA path. The same WebGPU/Metal pipeline is rendered
    /// into a copyable BGRA texture, read back, and written as a top-down BMP;
    /// the Debug command rejects extensions that would mislabel this encoding.
    /// This is a capture of the real GPU result, never a software renderer.
    fn captureBmp(self: *Renderer, app: *const score.App, logical_size: [2]i32, scale: [2]f32, time: f32, path: [*:0]const u8) !void {
        if (!build_options.hot_reload) return error.DebugCaptureUnavailable;
        if (!self.context.canRender()) return error.SurfaceUnavailable;
        const physical_width = self.context.swapchain_descriptor.width;
        const physical_height = self.context.swapchain_descriptor.height;
        if (physical_width == 0 or physical_height == 0) return error.SurfaceUnavailable;
        const row_bytes = physical_width * 4;
        const padded_row_bytes = std.mem.alignForward(u32, row_bytes, 256);
        const mapped_size: usize = @as(usize, padded_row_bytes) * physical_height;

        const frame = Uniforms{
            .viewport = .{ @floatFromInt(@max(logical_size[0], 1)), @floatFromInt(@max(logical_size[1], 1)) },
            .time = time,
            .pixel_ratio = scale[0],
        };
        const items = app.drawItems();
        self.context.queue.writeBuffer(self.uniforms, 0, Uniforms, (&[_]Uniforms{frame})[0..]);
        if (items.len != 0) self.context.queue.writeBuffer(self.instances, 0, score.render.DrawItem, items);

        const texture = self.context.device.createTexture(.{
            .label = "score debug GPU capture",
            .usage = .{ .render_attachment = true, .copy_src = true },
            .size = .{ .width = physical_width, .height = physical_height },
            .format = zgpu.GraphicsContext.swapchain_format,
        });
        defer texture.release();
        const view = texture.createView(.{});
        defer view.release();
        const readback = self.context.device.createBuffer(.{
            .label = "score debug GPU readback",
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = mapped_size,
        });
        defer readback.release();

        const encoder = self.context.device.createCommandEncoder(null);
        defer encoder.release();
        self.encodePass(encoder, view, items);
        encoder.copyTextureToBuffer(
            .{ .texture = texture },
            .{ .layout = .{ .bytes_per_row = padded_row_bytes, .rows_per_image = physical_height }, .buffer = readback },
            .{ .width = physical_width, .height = physical_height },
        );
        const commands = encoder.finish(null);
        defer commands.release();
        self.context.submit(&.{commands});

        var state: CaptureMapState = .{};
        readback.mapAsync(.{ .read = true }, 0, mapped_size, captureMapped, &state);
        const deadline = zglfw.getTime() + 5;
        while (!state.done.load(.acquire) and zglfw.getTime() < deadline) self.context.device.tick();
        if (!state.done.load(.acquire)) return error.GpuReadbackTimedOut;
        if (state.status.load(.monotonic) != @intFromEnum(wgpu.BufferMapAsyncStatus.success)) return error.GpuReadbackFailed;
        const bytes = readback.getConstMappedRange(u8, 0, mapped_size) orelse return error.GpuReadbackFailed;
        defer readback.unmap();
        try writeTopDownBmp(path, physical_width, physical_height, padded_row_bytes, bytes);
    }

    fn appendPdfPage(self: *Renderer, pdf: *anyopaque, items: []const score.render.DrawItem, width: u32, height: u32) !void {
        if (!self.context.canRender()) return error.SurfaceUnavailable;
        const row_bytes = width * 4;
        const padded_row_bytes = std.mem.alignForward(u32, row_bytes, 256);
        const mapped_size: usize = @as(usize, padded_row_bytes) * height;
        const frame = Uniforms{
            .viewport = .{ @floatFromInt(width), @floatFromInt(height) },
            .time = 0,
            .pixel_ratio = 1,
        };
        self.context.queue.writeBuffer(self.uniforms, 0, Uniforms, (&[_]Uniforms{frame})[0..]);
        if (items.len != 0) self.context.queue.writeBuffer(self.instances, 0, score.render.DrawItem, items);

        const texture = self.context.device.createTexture(.{
            .label = "score printable GPU page",
            .usage = .{ .render_attachment = true, .copy_src = true },
            .size = .{ .width = width, .height = height },
            .format = zgpu.GraphicsContext.swapchain_format,
        });
        defer texture.release();
        const view = texture.createView(.{});
        defer view.release();
        const readback = self.context.device.createBuffer(.{
            .label = "score printable GPU readback",
            .usage = .{ .copy_dst = true, .map_read = true },
            .size = mapped_size,
        });
        defer readback.release();
        const encoder = self.context.device.createCommandEncoder(null);
        defer encoder.release();
        self.encodePass(encoder, view, items);
        encoder.copyTextureToBuffer(
            .{ .texture = texture },
            .{ .layout = .{ .bytes_per_row = padded_row_bytes, .rows_per_image = height }, .buffer = readback },
            .{ .width = width, .height = height },
        );
        const commands = encoder.finish(null);
        defer commands.release();
        self.context.submit(&.{commands});

        var state: CaptureMapState = .{};
        readback.mapAsync(.{ .read = true }, 0, mapped_size, captureMapped, &state);
        const deadline = zglfw.getTime() + 5;
        while (!state.done.load(.acquire) and zglfw.getTime() < deadline) self.context.device.tick();
        if (!state.done.load(.acquire)) return error.GpuReadbackTimedOut;
        if (state.status.load(.monotonic) != @intFromEnum(wgpu.BufferMapAsyncStatus.success)) return error.GpuReadbackFailed;
        const bytes = readback.getConstMappedRange(u8, 0, mapped_size) orelse return error.GpuReadbackFailed;
        defer readback.unmap();
        try appendPdfBgra(pdf, width, height, padded_row_bytes, bytes);
    }
};

const DevShaderReloader = if (build_options.hot_reload) struct {
    const default_path: [:0]const u8 = "src/render/shaders/ui.wgsl";
    const source_capacity = 256 * 1024;

    modified_ns: i128 = -1,
    next_poll: f64 = 0,
    source: [source_capacity:0]u8 = [_:0]u8{0} ** source_capacity,

    fn poll(self: *@This(), app: *score.App, renderer: *Renderer, now: f64) void {
        if (now < self.next_poll) return;
        self.next_poll = now + 0.2;
        const path = shaderPath();
        const stamp = modificationTime(path) orelse return;
        if (stamp == self.modified_ns) return;
        self.modified_ns = stamp;
        const source = self.readSource(path) catch |err| {
            renderer.setShaderError(@errorName(err));
            app.setHostStatus(9);
            std.log.err("WGSL hot reload kept last-good pipeline: {s}", .{@errorName(err)});
            return;
        };
        renderer.reloadShaderSource(source.ptr) catch |err| {
            app.setHostStatus(9);
            std.log.err("WGSL hot reload kept last-good pipeline: {s}: {s}", .{ @errorName(err), renderer.shaderError() });
            return;
        };
        app.setHostStatus(10);
        std.log.info("WGSL pipeline hot-reloaded; generation={d}; Flecs world preserved", .{renderer.shader_generation});
    }

    fn force(self: *@This()) void {
        self.modified_ns = -1;
        self.next_poll = 0;
    }

    fn readSource(self: *@This(), path: [*:0]const u8) ![:0]const u8 {
        const file = native_c.fopen(path, "rb") orelse return error.ShaderOpenFailed;
        defer _ = native_c.fclose(file);
        const count = native_c.fread(&self.source, 1, self.source.len - 1, file);
        if (native_c.ferror(file) != 0) return error.ShaderReadFailed;
        if (count == self.source.len - 1 and native_c.fgetc(file) != native_c.EOF) return error.ShaderTooLarge;
        self.source[count] = 0;
        return self.source[0..count :0];
    }

    fn shaderPath() [*:0]const u8 {
        const configured = native_c.getenv("SCORE_HOT_RELOAD_SHADER");
        if (configured != null and configured[0] != 0) return configured;
        return default_path.ptr;
    }

    fn modificationTime(path: [*:0]const u8) ?i128 {
        var info: native_c.struct_stat = undefined;
        if (native_c.stat(path, &info) != 0) return null;
        return @as(i128, info.st_mtimespec.tv_sec) * std.time.ns_per_s + info.st_mtimespec.tv_nsec;
    }
} else struct {
    fn poll(_: *@This(), _: *score.App, _: *Renderer, _: f64) void {}
    fn force(_: *@This()) void {}
};

fn writeTopDownBmp(path: [*:0]const u8, width: u32, height: u32, stride: u32, pixels: []const u8) !void {
    const file = native_c.fopen(path, "wb") orelse return error.CaptureOpenFailed;
    defer _ = native_c.fclose(file);
    var header = [_]u8{0} ** 54;
    header[0] = 'B';
    header[1] = 'M';
    putLe32(header[2..6], 54 + width * height * 4);
    putLe32(header[10..14], 54);
    putLe32(header[14..18], 40);
    putLe32(header[18..22], width);
    putLe32(header[22..26], @bitCast(-@as(i32, @intCast(height))));
    header[26] = 1;
    header[28] = 32;
    putLe32(header[34..38], width * height * 4);
    if (native_c.fwrite(&header, 1, header.len, file) != header.len) return error.CaptureWriteFailed;
    const row_bytes: usize = @as(usize, width) * 4;
    for (0..height) |row| {
        const start: usize = @as(usize, row) * stride;
        if (native_c.fwrite(pixels[start .. start + row_bytes].ptr, 1, row_bytes, file) != row_bytes) return error.CaptureWriteFailed;
    }
    if (native_c.fflush(file) != 0) return error.CaptureWriteFailed;
}

fn putLe32(destination: []u8, value: u32) void {
    for (0..4) |index| destination[index] = @truncate(value >> @intCast(index * 8));
}

const pdf_width_pixels: u32 = 1240;
const pdf_height_pixels: u32 = 1754;
const pdf_width_points: f64 = 595;
const pdf_height_points: f64 = 842;

fn appendPdfBgra(pdf: *anyopaque, width: u32, height: u32, stride: u32, bytes: []const u8) !void {
    if (native_c.score_pdf_append_bgra(pdf, bytes.ptr, width, height, stride) == 0) return error.PdfPageWriteFailed;
}

/// Build and validate the replacement before touching the live callback. Once
/// it is ready, CoreAudio is stopped, rebound, and restarted around the new
/// sampler. Every error path keeps the old sampler and attempts to restore its
/// output, so an invalid user-selected SFZ never leaves a dangling audio-thread
/// context or destroys the currently playable instrument.
fn replaceInstrument(
    allocator: std.mem.Allocator,
    library_paths: []const []const u8,
    selected_path: []const u8,
    active_path: *[:0]u8,
    active_sampler: **SfizzSampler,
    active_output: *?*native_c.ScoreAudioOutput,
) !void {
    const replacement_path = try allocator.dupeZ(u8, selected_path);
    errdefer allocator.free(replacement_path);
    const replacement = try SfizzSampler.create(allocator, library_paths, replacement_path);
    errdefer replacement.destroy();
    replacement.applyPianoDetailProfile(.studio);

    const output_device = native_c.score_audio_output_selected_device(active_output.*);
    const target_sample_rate: f32 = @floatCast(native_c.score_audio_output_device_nominal_sample_rate(output_device));
    native_c.score_audio_output_stop(active_output.*);
    if (target_sample_rate > 0) replacement.setSampleRate(target_sample_rate);
    active_output.* = native_c.score_audio_output_start_device(audioRender, replacement, output_device);
    if (active_output.* == null) {
        if (target_sample_rate > 0) active_sampler.*.setSampleRate(target_sample_rate);
        active_output.* = native_c.score_audio_output_start_device(audioRender, active_sampler.*, output_device);
        return error.AudioOutputUnavailable;
    }

    active_sampler.*.destroy();
    allocator.free(active_path.*);
    active_sampler.* = replacement;
    active_path.* = replacement_path;
    persistInstrumentPath(active_path.*);
}

fn selectAudioOutput(sampler: *SfizzSampler, output: *?*native_c.ScoreAudioOutput, requested_device: u32) bool {
    if (requested_device >= native_c.score_audio_output_device_count()) return false;
    const previous_device = native_c.score_audio_output_selected_device(output.*);
    if (output.* != null and previous_device == requested_device) return true;
    const previous_sample_rate: f32 = @floatCast(native_c.score_audio_output_sample_rate(output.*));
    const target_sample_rate: f32 = @floatCast(native_c.score_audio_output_device_nominal_sample_rate(requested_device));
    native_c.score_audio_output_stop(output.*);
    if (target_sample_rate > 0) sampler.setSampleRate(target_sample_rate);
    output.* = native_c.score_audio_output_start_device(audioRender, sampler, requested_device);
    if (output.* == null and previous_device < native_c.score_audio_output_device_count()) {
        if (previous_sample_rate > 0) sampler.setSampleRate(previous_sample_rate);
        output.* = native_c.score_audio_output_start_device(audioRender, sampler, previous_device);
    }
    return output.* != null and native_c.score_audio_output_selected_device(output.*) == requested_device;
}

fn instrumentDisplayName(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "AccurateSalamanderGrandPiano") != null or std.mem.indexOf(u8, path, "Accurate-SalamanderGrandPiano") != null) return "ACCURATE SALAMANDER GRAND";
    if (std.mem.indexOf(u8, path, "Salamander Grand Piano") != null) return "SALAMANDER GRAND PIANO";
    const basename = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return basename;
    return basename[0..dot];
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    var initial_score_path: ?[:0]const u8 = null;
    const accurate_salamander_path: [:0]const u8 = "local-content/instruments/AccurateSalamanderGrandPianoV6.2beta2/sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz";
    const salamander_v3_path: [:0]const u8 = "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    var configured_instrument_path: ?[:0]const u8 = null;
    if (native_c.getenv("SCORE_INSTRUMENT")) |configured| if (configured[0] != 0) {
        configured_instrument_path = std.mem.span(configured);
    };
    var expects_instrument_path = false;
    var start_playing = false;
    while (arguments.next()) |argument| {
        if (expects_instrument_path) {
            configured_instrument_path = argument;
            expects_instrument_path = false;
        } else if (std.mem.eql(u8, argument, "--sfz")) {
            expects_instrument_path = true;
        } else if (std.mem.eql(u8, argument, "--play")) {
            start_playing = true;
        } else if (initial_score_path == null) {
            initial_score_path = argument;
        } else {
            return error.TooManyArguments;
        }
    }
    if (expects_instrument_path) return error.MissingInstrumentPath;

    var persisted_instrument_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
    const discovered_instrument_path = loadPersistedInstrumentPath(&persisted_instrument_buffer) orelse
        if (readableFile(accurate_salamander_path.ptr)) accurate_salamander_path else salamander_v3_path;
    var instrument_path = configured_instrument_path orelse discovered_instrument_path;
    const canonical_instrument_path = std.Io.Dir.cwd().realPathFileAlloc(init.io, instrument_path, allocator) catch null;
    defer if (canonical_instrument_path) |path| allocator.free(path);
    if (canonical_instrument_path) |path| instrument_path = path;

    // Claim the native process before creating AppKit/GLFW, Metal, audio, MIDI,
    // or sampler state. A kernel-held lock remains authoritative even if an old
    // render thread stops polling its development socket or fills the socket
    // backlog. A duplicate Debug launch asks the owner to come to the front and
    // then exits without creating a window.
    var instance_lock = dev_control.InstanceLock.init() catch |err| switch (err) {
        error.InstanceRunning => {
            if (build_options.hot_reload) _ = dev_control.notifyExisting("activate");
            std.log.info("another Score host owns the native session; duplicate launch ignored", .{});
            return;
        },
        else => return err,
    };
    defer instance_lock.deinit();

    var dev_server: ?dev_control.Server = null;
    if (build_options.hot_reload) {
        dev_server = dev_control.Server.init() catch |err| switch (err) {
            error.SocketInUse => {
                std.log.info("another Debug Score host owns the development session; duplicate launch ignored", .{});
                return;
            },
            else => blk: {
                std.log.warn("development control unavailable: {s}", .{@errorName(err)});
                break :blk null;
            },
        };
        if (dev_server) |*server| std.log.info("development control listening at {s}", .{server.pathSlice()});
    }
    defer if (dev_server) |*server| server.deinit();

    try zglfw.init();
    defer zglfw.terminate();
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.cocoa_retina_framebuffer, true);
    zglfw.windowHint(.scale_framebuffer, true);

    const primary_work_area = if (zglfw.Monitor.getPrimary()) |monitor| monitorWorkArea(monitor) else nativeWorkArea();
    const initial_window_size = clampWindowSize(.{ 1440, 900 }, conservativeContentMaximum(primary_work_area));
    const window = try zglfw.Window.create(initial_window_size[0], initial_window_size[1], "Score — notation and piano practice", null, null);
    defer window.destroy();
    _ = fitWindowToDisplay(window, null);

    const initial_size = window.getSize();
    const initial_scale = window.getContentScale();
    const app = try score.App.create(allocator, @floatFromInt(initial_size[0]), @floatFromInt(initial_size[1]), initial_scale[0]);
    defer app.destroy(allocator);
    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir_len = try std.process.executableDirPath(init.io, &executable_path_buffer);
    var bundle_library_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_library = try std.fmt.bufPrint(&bundle_library_buffer, "{s}/../Frameworks/libsfizz.dylib", .{executable_path_buffer[0..executable_dir_len]});
    const sampler_library_paths = [_][]const u8{
        "zig-out/lib/libsfizz.dylib",
        bundle_library,
    };
    var active_instrument_path = try allocator.dupeZ(u8, instrument_path);
    defer allocator.free(active_instrument_path);
    var sampler = try SfizzSampler.create(allocator, &sampler_library_paths, active_instrument_path);
    persistInstrumentPath(active_instrument_path);
    // The reference Salamander/Accurate-Salamander profiles document these
    // controls as sampled release, hammer noise, pedal mechanics, and damper
    // resonance. Other SFZ instruments safely ignore unbound controllers.
    sampler.applyPianoDetailProfile(.studio);
    var audio_output = native_c.score_audio_output_start(audioRender, sampler);
    defer {
        native_c.score_audio_output_stop(audio_output);
        sampler.destroy();
    }
    app.setSamplerStatus(if (audio_output != null) 1 else 2, instrumentDisplayName(active_instrument_path), sampler.region_count, sampler.preloaded_sample_count);
    const midi_service = native_c.score_midi_create();
    defer native_c.score_midi_destroy(midi_service);
    std.log.info("music devices: {d} MIDI inputs, {d} MIDI outputs, audio {d:.0} Hz; SFZ {d} regions / {d} preloaded samples; instrument {s}", .{
        native_c.score_midi_source_count(midi_service),
        native_c.score_midi_destination_count(midi_service),
        native_c.score_audio_output_sample_rate(audio_output),
        sampler.region_count,
        sampler.preloaded_sample_count,
        active_instrument_path,
    });
    std.log.info("CoreAudio output: device={d:.0} Hz buffer={d} frames device_latency={d} safety={d} callback={d} estimated={d:.2} ms", .{
        native_c.score_audio_output_device_sample_rate(audio_output),
        native_c.score_audio_output_device_buffer_frames(audio_output),
        native_c.score_audio_output_device_latency_frames(audio_output),
        native_c.score_audio_output_safety_offset_frames(audio_output),
        native_c.score_audio_output_callback_frames(audio_output),
        native_c.score_audio_output_estimated_latency_seconds(audio_output) * 1000.0,
    });
    var microphone_monitor: MicrophoneMonitor = .{};
    var audio_input: ?*native_c.ScoreAudioInput = null;
    var audio_input_switch: AudioInputSwitch = .{};
    var input_selection: InputSelection = .{};
    var pending_audio_recording = false;
    var take_audio_path_buffer: [4096]u8 = undefined;
    defer {
        audio_input_switch.deinit();
        native_c.score_audio_input_stop(audio_input);
    }
    var reloader: DevReloader = .{};
    defer reloader.deinit(app);
    // If the socket could not be created for an environmental reason other
    // than a live owner, keep the app usable but protect the authoritative
    // recovery journal. A known duplicate has already exited before creating
    // a native window.
    const autosave_writer = !build_options.hot_reload or dev_server != null;
    if (!autosave_writer) std.log.warn("development host is read-only for autosave recovery", .{});
    window.setUserPointer(app);
    _ = window.setCursorPosCallback(cursorCallback);
    _ = window.setMouseButtonCallback(mouseButtonCallback);
    _ = window.setScrollCallback(scrollCallback);
    _ = window.setKeyCallback(keyCallback);
    _ = window.setDropCallback(dropCallback);

    if (initial_score_path) |path| {
        loadScorePath(app, allocator, path.ptr) catch |err| {
            std.log.err("initial score import failed for {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    } else {
        const recovered = loadAutosave(app, allocator);
        var source_path_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (loadPersistedScoreSource(&source_path_buffer)) |source| {
            const current_crc = scoreSourceCrc(allocator, source.path.ptr) catch null;
            if (!recovered or (current_crc != null and current_crc.? != source.crc)) {
                loadScorePath(app, allocator, source.path.ptr) catch |err| {
                    std.log.warn("newer score source could not replace autosave: {s}", .{@errorName(err)});
                };
            }
        }
    }
    updateInputStatus(app, midi_service, audio_input, input_selection);
    if (start_playing) app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });

    var renderer = try Renderer.init(allocator, window);
    defer renderer.deinit(allocator);
    var shader_reloader: DevShaderReloader = .{};

    var previous_time = zglfw.getTime();
    var next_autosave = previous_time + 2;
    var performance: PerformanceMonitor = .{};
    while (!window.shouldClose()) {
        zglfw.pollEvents();
        // GLFW sizes the client area, while macOS constrains the decorated
        // outer frame. Re-evaluate after monitor moves and display changes so
        // a window cannot remain wider or taller than its current work area.
        _ = fitWindowToDisplay(window, null);
        const now = zglfw.getTime();
        const logical_size = window.getSize();
        const scale = window.getContentScale();
        if (audio_input_switch.poll(&audio_input)) {
            if (audio_input) |active| {
                const selected_device = native_c.score_audio_input_selected_device(active);
                if (audio_input_switch.select_route) input_selection = .{ .microphone = true, .audio_device = selected_device };
                std.log.info("audio input switch completed: device {d}", .{selected_device});
            } else if (audio_input_switch.select_route) {
                input_selection = .{};
                std.log.warn("audio input switch failed and no previous input could be restored", .{});
            }
            updateInputStatus(app, midi_service, audio_input, input_selection);
            if (pending_audio_recording) {
                pending_audio_recording = false;
                const audio_path = appDataPath(&take_audio_path_buffer, "latest-take.wav") catch null;
                if (audio_path == null or native_c.score_audio_input_begin_recording(audio_input, audio_path.?.ptr) == 0) {
                    std.log.warn("audio input became unavailable before recording; MIDI capture remains active", .{});
                }
            }
        }
        reloader.poll(app, now);
        shader_reloader.poll(app, &renderer, now);
        if (dev_server) |*server| pumpDevControl(server, app, &sampler, &audio_output, &active_instrument_path, allocator, &sampler_library_paths, midi_service, &audio_input, &audio_input_switch, &microphone_monitor, &input_selection, &reloader, &shader_reloader, &renderer, &performance, window, logical_size, scale, @floatCast(now));
        switch (app.takeHostRequest()) {
            .open_score => {
                const selected = native_c.score_open_score_panel();
                if (selected != null and selected[0] != 0) loadScorePath(app, allocator, selected) catch |err| {
                    app.setHostStatus(3);
                    std.log.err("import failed: {s}", .{@errorName(err)});
                };
            },
            .choose_midi => cycleInput(app, midi_service, &audio_input, &audio_input_switch, &microphone_monitor, &input_selection),
            .choose_microphone => selectMicrophoneInput(app, midi_service, &audio_input, &audio_input_switch, &microphone_monitor, &input_selection),
            .open_instrument => {
                const selected = native_c.score_open_instrument_panel();
                if (selected != null and selected[0] != 0) {
                    replaceInstrument(allocator, &sampler_library_paths, std.mem.span(selected), &active_instrument_path, &sampler, &audio_output) catch |err| {
                        app.setSamplerStatus(if (audio_output != null) 1 else 2, instrumentDisplayName(active_instrument_path), sampler.region_count, sampler.preloaded_sample_count);
                        app.setHostStatus(14);
                        std.log.err("instrument swap failed; previous sampler kept: {s}", .{@errorName(err)});
                        continue;
                    };
                    app.setSamplerStatus(1, instrumentDisplayName(active_instrument_path), sampler.region_count, sampler.preloaded_sample_count);
                    app.setHostStatus(13);
                    std.log.info("instrument loaded: {d} regions / {d} preloaded samples; {s}", .{ sampler.region_count, sampler.preloaded_sample_count, active_instrument_path });
                }
            },
            .export_score => {
                const selected = native_c.score_save_score_panel();
                if (selected != null and selected[0] != 0) exportScorePath(app, &renderer, allocator, selected) catch |err| {
                    app.setHostStatus(3);
                    std.log.err("score export failed: {s}", .{@errorName(err)});
                };
            },
            .export_take => {
                const selected = native_c.score_save_take_panel();
                if (selected != null and selected[0] != 0) saveTakePath(app, allocator, selected) catch |err| {
                    app.setHostStatus(3);
                    std.log.err("MIDI take export failed: {s}", .{@errorName(err)});
                };
            },
            .start_recording => {
                const requested_device = if (input_selection.microphone) input_selection.audio_device else std.math.maxInt(u32);
                const ready_or_scheduled = ensureMicrophone(&audio_input, &audio_input_switch, &microphone_monitor, requested_device, false);
                if (audio_input_switch.active()) {
                    pending_audio_recording = ready_or_scheduled;
                } else {
                    const audio_path = appDataPath(&take_audio_path_buffer, "latest-take.wav") catch null;
                    if (!ready_or_scheduled or audio_path == null or native_c.score_audio_input_begin_recording(audio_input, audio_path.?.ptr) == 0) {
                        std.log.warn("microphone recording unavailable; MIDI capture remains active", .{});
                    }
                }
            },
            .stop_recording => {
                pending_audio_recording = false;
                native_c.score_audio_input_end_recording(audio_input);
                app.setHostStatus(6);
            },
            .replay_take => {
                var audio_path_buffer: [4096]u8 = undefined;
                if (appDataPath(&audio_path_buffer, "latest-take.wav")) |audio_path| native_c.score_replay_audio_file(audio_path.ptr) else |_| {}
            },
            else => {},
        }
        const delta: f32 = @floatCast(now - previous_time);
        previous_time = now;
        app.resize(@floatFromInt(logical_size[0]), @floatFromInt(logical_size[1]), scale[0]);
        app.tick(delta);
        const semantic_items = app.accessibilityItems();
        native_c.score_accessibility_update(@ptrCast(semantic_items.ptr), @intCast(semantic_items.len), accessibilityActivate, app);
        pumpMidiInput(app, sampler, midi_service);
        if (input_selection.microphone) pumpMicrophone(app, &microphone_monitor);
        pumpPlayback(app, sampler, midi_service);
        const draw_item_count = app.drawItems().len;
        const before_draw = zglfw.getTime();
        const draw_timing = renderer.draw(app, logical_size, scale, @floatCast(now));
        const work_seconds = before_draw - now + draw_timing.work_seconds;
        performance.record(delta, work_seconds, draw_timing.acquire_wait_seconds, draw_timing.present_seconds, draw_item_count);
        if (autosave_writer and now >= next_autosave) {
            saveAutosave(app, allocator) catch |err| std.log.warn("autosave failed: {s}", .{@errorName(err)});
            next_autosave = now + 2;
        }
    }
    try saveAutosave(app, allocator);
}

fn readableFile(path: [*:0]const u8) bool {
    const file = native_c.fopen(path, "rb") orelse return false;
    _ = native_c.fclose(file);
    return true;
}

fn loadPersistedInstrumentPath(output: *[std.fs.max_path_bytes:0]u8) ?[:0]const u8 {
    var configuration_path_buffer: [4096]u8 = undefined;
    const configuration_path = appDataPath(&configuration_path_buffer, "instrument-path.txt") catch return null;
    const file = native_c.fopen(configuration_path.ptr, "rb") orelse return null;
    defer _ = native_c.fclose(file);
    const count = native_c.fread(output, 1, output.len - 1, file);
    if (count == 0 or native_c.ferror(file) != 0) return null;
    const trimmed = std.mem.trimEnd(u8, output[0..count], " \t\r\n");
    if (trimmed.len == 0 or trimmed.len >= output.len) return null;
    output[trimmed.len] = 0;
    const path = output[0..trimmed.len :0];
    return if (readableFile(path.ptr)) path else null;
}

fn persistInstrumentPath(path: [:0]const u8) void {
    // Relative Debug paths are intentionally not persisted: Finder-launched
    // bundles do not share the development shell's working directory.
    if (!std.fs.path.isAbsolute(path)) return;
    var configuration_path_buffer: [4096]u8 = undefined;
    const configuration_path = appDataPath(&configuration_path_buffer, "instrument-path.txt") catch return;
    const file = native_c.fopen(configuration_path.ptr, "wb") orelse return;
    defer _ = native_c.fclose(file);
    if (native_c.fwrite(path.ptr, 1, path.len, file) != path.len) return;
    _ = native_c.fwrite("\n", 1, 1, file);
    _ = native_c.fflush(file);
    _ = native_c.fsync(native_c.fileno(file));
}

fn pumpDevControl(
    server: *dev_control.Server,
    app: *score.App,
    sampler: **SfizzSampler,
    audio_output: *?*native_c.ScoreAudioOutput,
    instrument_path: *[:0]u8,
    allocator: std.mem.Allocator,
    sampler_library_paths: []const []const u8,
    midi_service: ?*native_c.ScoreMidiService,
    audio_input: *?*native_c.ScoreAudioInput,
    audio_input_switch: *AudioInputSwitch,
    microphone_monitor: *MicrophoneMonitor,
    input_selection: *InputSelection,
    reloader: *DevReloader,
    shader_reloader: *DevShaderReloader,
    renderer: *Renderer,
    performance: *PerformanceMonitor,
    window: *zglfw.Window,
    logical_size: [2]i32,
    scale: [2]f32,
    time: f32,
) void {
    var command_buffer: [dev_control.max_command_bytes]u8 = undefined;
    const client = server.poll(&command_buffer) orelse return;
    const command = std.mem.trim(u8, command_buffer[0..client.command_len], " \t\r\n");
    var response: [dev_control.max_response_bytes]u8 = undefined;
    var response_len: usize = 0;
    if (std.mem.eql(u8, command, "reload")) {
        reloader.force();
        shader_reloader.force();
        response_len = hostDevResponse(&response, "ok systems and shader hot reload scheduled", .{});
    } else if (std.mem.eql(u8, command, "shader reload")) {
        shader_reloader.force();
        response_len = hostDevResponse(&response, "ok shader hot reload scheduled", .{});
    } else if (std.mem.eql(u8, command, "shader state")) {
        const message = renderer.shaderError();
        response_len = if (message.len == 0)
            hostDevResponse(&response, "ok shader_generation={d} last_good=1 error=none", .{renderer.shader_generation})
        else
            hostDevResponse(&response, "ok shader_generation={d} last_good=1 error={s}", .{ renderer.shader_generation, message });
    } else if (std.mem.eql(u8, command, "perf reset")) {
        performance.reset();
        response_len = hostDevResponse(&response, "ok performance counters reset", .{});
    } else if (std.mem.eql(u8, command, "perf state")) {
        response_len = hostDevResponse(&response, "ok frames={d} avg_frame_ms={d:.3} max_frame_ms={d:.3} avg_work_ms={d:.3} max_work_ms={d:.3} avg_acquire_wait_ms={d:.3} max_acquire_wait_ms={d:.3} avg_present_ms={d:.3} max_present_ms={d:.3} missed_120hz={d} missed_60hz={d} max_draw_items={d}", .{
            performance.frame_count,
            performance.averageFrameMilliseconds(),
            performance.frame_seconds_max * 1000,
            performance.averageWorkMilliseconds(),
            performance.work_seconds_max * 1000,
            performance.averageAcquireWaitMilliseconds(),
            performance.acquire_wait_seconds_max * 1000,
            performance.averagePresentMilliseconds(),
            performance.present_seconds_max * 1000,
            performance.missed_120hz,
            performance.missed_60hz,
            performance.maximum_draw_items,
        });
    } else if (std.mem.eql(u8, command, "activate")) {
        window.requestAttention();
        window.focus();
        const message = "ok activated";
        @memcpy(response[0..message.len], message);
        response_len = message.len;
    } else if (std.mem.eql(u8, command, "window state")) {
        const geometry = currentWindowGeometry(window);
        response_len = hostDevResponse(&response, "ok content={d}x{d} outer={d}x{d} position={d},{d} workarea={d},{d},{d}x{d}", .{
            geometry.content[0],
            geometry.content[1],
            geometry.outer[0],
            geometry.outer[1],
            geometry.position[0],
            geometry.position[1],
            geometry.work_area.x,
            geometry.work_area.y,
            geometry.work_area.width,
            geometry.work_area.height,
        });
    } else if (std.mem.startsWith(u8, command, "window ")) {
        if (parseWindowSize(std.mem.trim(u8, command[7..], " \t\r\n"))) |size| {
            const safe_size = fitWindowToDisplay(window, size);
            response_len = if (safe_size[0] == size[0] and safe_size[1] == size[1])
                hostDevResponse(&response, "ok window={d}x{d}", .{ safe_size[0], safe_size[1] })
            else
                hostDevResponse(&response, "ok window={d}x{d} requested={d}x{d} clamped=screen-safe", .{ safe_size[0], safe_size[1], size[0], size[1] });
        } else {
            response_len = hostDevResponse(&response, "error usage: window WIDTH HEIGHT (720..3840 x 540..2160)", .{});
        }
    } else if (std.mem.eql(u8, command, "sampler state")) {
        const detail = sampler.*.pianoDetailProfile();
        response_len = hostDevResponse(&response, "ok regions={d} preloaded={d} dropped={d} late={d} overloaded={d} limited_frames={d} invalid_output={d} release={d} hammer={d} pedal_noise={d} resonance={d} instrument={s}", .{
            sampler.*.region_count,
            sampler.*.preloaded_sample_count,
            sampler.*.droppedEventCount(),
            sampler.*.lateEventCount(),
            sampler.*.overloadedSampleCount(),
            sampler.*.limitedFrameCount(),
            sampler.*.invalidOutputSampleCount(),
            detail.sampled_release,
            detail.hammer_noise,
            detail.pedal_noise,
            detail.pedal_resonance,
            instrument_path.*,
        });
    } else if (std.mem.startsWith(u8, command, "sampler load ")) {
        const path = std.mem.trim(u8, command[13..], " \t\r\n");
        if (path.len == 0) {
            response_len = hostDevResponse(&response, "error usage: sampler load PATH.sfz", .{});
        } else {
            replaceInstrument(allocator, sampler_library_paths, path, instrument_path, sampler, audio_output) catch |err| {
                app.setSamplerStatus(if (audio_output.* != null) 1 else 2, instrumentDisplayName(instrument_path.*), sampler.*.region_count, sampler.*.preloaded_sample_count);
                response_len = hostDevResponse(&response, "error instrument swap failed; previous kept: {s}", .{@errorName(err)});
            };
            if (response_len == 0) {
                app.setSamplerStatus(1, instrumentDisplayName(instrument_path.*), sampler.*.region_count, sampler.*.preloaded_sample_count);
                response_len = hostDevResponse(&response, "ok loaded instrument regions={d} preloaded={d} path={s}", .{ sampler.*.region_count, sampler.*.preloaded_sample_count, instrument_path.* });
            }
        }
    } else if (std.mem.eql(u8, command, "audio state")) {
        var output_name_buffer: [128]u8 = undefined;
        const output_index = native_c.score_audio_output_selected_device(audio_output.*);
        const output_name_len = native_c.score_audio_output_device_name(output_index, &output_name_buffer, output_name_buffer.len);
        const output_name = if (output_name_len == 0) "DEFAULT OUTPUT" else output_name_buffer[0..@min(output_name_len, output_name_buffer.len)];
        response_len = hostDevResponse(&response, "ok output_index={d} outputs={d} output={s} render_hz={d:.0} device_hz={d:.0} unit_device_hz={d:.0} unit_device_channels={d} buffer_frames={d} callback_frames={d} max_callback_frames={d} callback_buffers={d} callback_channels={d} nonzero_samples={d} callback_peak={d:.6} muted={d} volume={d:.3} input_muted={d} input_volume={d:.3} device_latency_frames={d} safety_frames={d} unit_latency_ms={d:.3} estimated_output_ms={d:.3}", .{
            output_index,
            native_c.score_audio_output_device_count(),
            output_name,
            native_c.score_audio_output_sample_rate(audio_output.*),
            native_c.score_audio_output_device_sample_rate(audio_output.*),
            native_c.score_audio_output_unit_device_sample_rate(audio_output.*),
            native_c.score_audio_output_unit_device_channels(audio_output.*),
            native_c.score_audio_output_device_buffer_frames(audio_output.*),
            native_c.score_audio_output_callback_frames(audio_output.*),
            native_c.score_audio_output_max_callback_frames(audio_output.*),
            native_c.score_audio_output_callback_buffers(audio_output.*),
            native_c.score_audio_output_callback_channels(audio_output.*),
            native_c.score_audio_output_nonzero_samples(audio_output.*),
            native_c.score_audio_output_callback_peak(audio_output.*),
            native_c.score_audio_output_device_muted(audio_output.*),
            native_c.score_audio_output_device_volume(audio_output.*),
            native_c.score_audio_output_device_input_muted(audio_output.*),
            native_c.score_audio_output_device_input_volume(audio_output.*),
            native_c.score_audio_output_device_latency_frames(audio_output.*),
            native_c.score_audio_output_safety_offset_frames(audio_output.*),
            native_c.score_audio_output_unit_latency_seconds(audio_output.*) * 1000.0,
            native_c.score_audio_output_estimated_latency_seconds(audio_output.*) * 1000.0,
        });
    } else if (std.mem.startsWith(u8, command, "audio output ")) {
        const argument = std.mem.trim(u8, command[13..], " \t\r\n");
        const index = std.fmt.parseInt(u32, argument, 10) catch std.math.maxInt(u32);
        if (!selectAudioOutput(sampler.*, audio_output, index)) {
            response_len = hostDevResponse(&response, "error usage: audio output INDEX (available outputs={d})", .{native_c.score_audio_output_device_count()});
        } else {
            var output_name_buffer: [128]u8 = undefined;
            const output_name_len = native_c.score_audio_output_device_name(index, &output_name_buffer, output_name_buffer.len);
            const output_name = if (output_name_len == 0) "UNNAMED OUTPUT" else output_name_buffer[0..@min(output_name_len, output_name_buffer.len)];
            response_len = hostDevResponse(&response, "ok output_index={d} output={s} estimated_output_ms={d:.3}", .{ index, output_name, native_c.score_audio_output_estimated_latency_seconds(audio_output.*) * 1000.0 });
        }
    } else if (std.mem.startsWith(u8, command, "audio mute ")) {
        const argument = std.mem.trim(u8, command["audio mute ".len..], " \t\r\n");
        const muted: c_int = if (std.mem.eql(u8, argument, "on")) 1 else if (std.mem.eql(u8, argument, "off")) 0 else -1;
        if (muted < 0 or native_c.score_audio_output_set_muted(audio_output.*, muted) == 0) {
            response_len = hostDevResponse(&response, "error usage: audio mute on|off (selected output may not expose a mute control)", .{});
        } else {
            response_len = hostDevResponse(&response, "ok muted={d} volume={d:.3}", .{ native_c.score_audio_output_device_muted(audio_output.*), native_c.score_audio_output_device_volume(audio_output.*) });
        }
    } else if (std.mem.eql(u8, command, "input state")) {
        response_len = inputStateResponse(&response, midi_service, audio_input.*, audio_input_switch, microphone_monitor, input_selection.*);
    } else if (std.mem.eql(u8, command, "input next")) {
        cycleInput(app, midi_service, audio_input, audio_input_switch, microphone_monitor, input_selection);
        response_len = inputStateResponse(&response, midi_service, audio_input.*, audio_input_switch, microphone_monitor, input_selection.*);
    } else if (std.mem.eql(u8, command, "input microphone")) {
        selectMicrophoneInput(app, midi_service, audio_input, audio_input_switch, microphone_monitor, input_selection);
        response_len = inputStateResponse(&response, midi_service, audio_input.*, audio_input_switch, microphone_monitor, input_selection.*);
    } else if (std.mem.startsWith(u8, command, "input audio ")) {
        const argument = std.mem.trim(u8, command[12..], " \t\r\n");
        const index = std.fmt.parseInt(u32, argument, 10) catch std.math.maxInt(u32);
        if (!selectAudioInput(app, midi_service, audio_input, audio_input_switch, microphone_monitor, input_selection, index)) {
            response_len = hostDevResponse(&response, "error usage: input audio INDEX (available inputs={d}; cannot switch while recording)", .{native_c.score_audio_input_device_count()});
        } else {
            response_len = inputStateResponse(&response, midi_service, audio_input.*, audio_input_switch, microphone_monitor, input_selection.*);
        }
    } else if (std.mem.startsWith(u8, command, "input midi ")) {
        const argument = std.mem.trim(u8, command[11..], " \t\r\n");
        const index = if (std.mem.eql(u8, argument, "all"))
            std.math.maxInt(u32)
        else
            std.fmt.parseInt(u32, argument, 10) catch std.math.maxInt(u32) - 1;
        if (!selectMidiInput(app, midi_service, audio_input_switch, input_selection, index)) {
            response_len = hostDevResponse(&response, "error usage: input midi all|INDEX (available sources={d}; wait for any audio switch)", .{native_c.score_midi_source_count(midi_service)});
        } else {
            response_len = inputStateResponse(&response, midi_service, audio_input.*, audio_input_switch, microphone_monitor, input_selection.*);
        }
    } else if (std.mem.startsWith(u8, command, "sampler detail ")) {
        const argument = std.mem.trim(u8, command[15..], " \t\r\n");
        if (parseSamplerDetail(argument)) |profile| {
            sampler.*.applyPianoDetailProfile(profile);
            response_len = hostDevResponse(&response, "ok sampler detail queued release={d} hammer={d} pedal_noise={d} resonance={d}", .{
                profile.sampled_release,
                profile.hammer_noise,
                profile.pedal_noise,
                profile.pedal_resonance,
            });
        } else {
            response_len = hostDevResponse(&response, "error usage: sampler detail studio|dry|RELEASE HAMMER PEDAL_NOISE RESONANCE (0..127)", .{});
        }
    } else if (std.mem.startsWith(u8, command, "midi ")) {
        response_len = app.runDevCommand(command, &response);
        if (std.mem.startsWith(u8, response[0..response_len], "ok ")) dispatchDevMidi(sampler.*, command[5..]);
    } else if (std.mem.startsWith(u8, command, "load ")) {
        const path = std.mem.trim(u8, command[5..], " \t\r\n");
        var path_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (path.len >= path_buffer.len) {
            response_len = hostDevResponse(&response, "error score path is too long", .{});
        } else {
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            loadScorePath(app, std.heap.c_allocator, path_buffer[0..path.len :0].ptr) catch |err| {
                response_len = hostDevResponse(&response, "error load failed: {s}", .{@errorName(err)});
            };
            if (response_len == 0) saveAutosave(app, std.heap.c_allocator) catch |err| {
                response_len = hostDevResponse(&response, "error loaded but autosave failed: {s}", .{@errorName(err)});
            };
            if (response_len == 0) response_len = hostDevResponse(&response, "ok loaded {s}", .{path});
        }
    } else if (std.mem.startsWith(u8, command, "export-take ")) {
        const path = std.mem.trim(u8, command[12..], " \t\r\n");
        var path_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (path.len >= path_buffer.len) {
            response_len = hostDevResponse(&response, "error take export path is too long", .{});
        } else {
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            saveTakePath(app, std.heap.c_allocator, path_buffer[0..path.len :0].ptr) catch |err| {
                response_len = hostDevResponse(&response, "error take export failed: {s}", .{@errorName(err)});
            };
            if (response_len == 0) response_len = hostDevResponse(&response, "ok exported MIDI take {s}", .{path});
        }
    } else if (std.mem.startsWith(u8, command, "export ")) {
        const path = std.mem.trim(u8, command[7..], " \t\r\n");
        var path_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (path.len >= path_buffer.len) {
            response_len = hostDevResponse(&response, "error export path is too long", .{});
        } else {
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            exportScorePath(app, renderer, std.heap.c_allocator, path_buffer[0..path.len :0].ptr) catch |err| {
                response_len = hostDevResponse(&response, "error export failed: {s}", .{@errorName(err)});
            };
            if (response_len == 0) response_len = hostDevResponse(&response, "ok exported {s}", .{path});
        }
    } else if (build_options.hot_reload and std.mem.startsWith(u8, command, "capture ")) {
        const path = std.mem.trim(u8, command[8..], " \t\r\n");
        var path_buffer: [std.fs.max_path_bytes:0]u8 = [_:0]u8{0} ** std.fs.max_path_bytes;
        if (!std.mem.endsWith(u8, path, ".bmp")) {
            response_len = hostDevResponse(&response, "error native GPU capture must use a .bmp path", .{});
        } else if (path.len >= path_buffer.len) {
            response_len = hostDevResponse(&response, "error capture path is too long", .{});
        } else {
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            renderer.captureBmp(app, logical_size, scale, time, path_buffer[0..path.len :0].ptr) catch |err| {
                response_len = hostDevResponse(&response, "error GPU capture failed: {s}", .{@errorName(err)});
            };
            if (response_len == 0) response_len = hostDevResponse(&response, "ok captured native GPU frame {s}", .{path});
        }
    } else {
        response_len = app.runDevCommand(command, &response);
    }
    client.respond(response[0..response_len]);
}

fn dispatchDevMidi(sampler: *SfizzSampler, argument: []const u8) void {
    var fields = std.mem.tokenizeAny(u8, argument, " \t");
    const status = std.fmt.parseInt(u8, fields.next() orelse return, 0) catch return;
    const data1 = std.fmt.parseInt(u8, fields.next() orelse return, 0) catch return;
    const data2 = std.fmt.parseInt(u8, fields.next() orelse return, 0) catch return;
    const message = status & 0xf0;
    const channel = status & 0x0f;
    if (message == 0x90 and data2 != 0) {
        sampler.noteOn(channel, data1, data2);
    } else if (message == 0x80 or (message == 0x90 and data2 == 0)) {
        sampler.noteOff(channel, data1);
    } else if (message == 0xb0) {
        sampler.controlChange(channel, data1, data2);
    }
}

fn parseSamplerDetail(argument: []const u8) ?sfizz_sampler.PianoDetailProfile {
    if (std.mem.eql(u8, argument, "studio")) return .studio;
    if (std.mem.eql(u8, argument, "dry")) return .dry;
    var fields = std.mem.tokenizeAny(u8, argument, " \t");
    const sampled_release = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    const hammer_noise = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    const pedal_noise = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    const pedal_resonance = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null or sampled_release > 127 or hammer_noise > 127 or pedal_noise > 127 or pedal_resonance > 127) return null;
    return .{
        .sampled_release = sampled_release,
        .hammer_noise = hammer_noise,
        .pedal_noise = pedal_noise,
        .pedal_resonance = pedal_resonance,
    };
}

fn parseWindowSize(argument: []const u8) ?[2]i32 {
    var fields = std.mem.tokenizeAny(u8, argument, " \t");
    const width = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const height = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null or width < 720 or width > 3840 or height < 540 or height > 2160) return null;
    return .{ width, height };
}

const WorkArea = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const WindowGeometry = struct {
    content: [2]i32,
    outer: [2]i32,
    position: [2]i32,
    work_area: WorkArea,
};

const window_grab_margin: i32 = 12;

fn monitorWorkArea(monitor: *zglfw.Monitor) WorkArea {
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    glfwGetMonitorWorkarea(monitor, &x, &y, &width, &height);
    return .{ .x = x, .y = y, .width = @max(width, 1), .height = @max(height, 1) };
}

fn nativeWorkArea() WorkArea {
    var area = WorkArea{ .x = 0, .y = 0, .width = 1440, .height = 900 };
    if (native_c.score_current_work_area(&area.x, &area.y, &area.width, &area.height) == 0) return area;
    area.width = @max(area.width, 1);
    area.height = @max(area.height, 1);
    return area;
}

fn conservativeContentMaximum(area: WorkArea) [2]i32 {
    // Before GLFW creates the native window its exact decoration size is not
    // available. This initial allowance is replaced with measured frame
    // geometry immediately after creation.
    return .{
        @max(320, area.width - 2 * window_grab_margin - 16),
        @max(320, area.height - 2 * window_grab_margin - 64),
    };
}

fn contentMaximum(area: WorkArea, frame: [4]i32) [2]i32 {
    return .{
        @max(320, area.width - frame[0] - frame[2] - 2 * window_grab_margin),
        @max(320, area.height - frame[1] - frame[3] - 2 * window_grab_margin),
    };
}

fn rectangleIntersectionArea(left: i32, top: i32, width: i32, height: i32, area: WorkArea) i64 {
    const overlap_width = @max(0, @min(left + width, area.x + area.width) - @max(left, area.x));
    const overlap_height = @max(0, @min(top + height, area.y + area.height) - @max(top, area.y));
    return @as(i64, overlap_width) * @as(i64, overlap_height);
}

fn workAreaForWindow(window: *zglfw.Window) WorkArea {
    const position = window.getPos();
    const content = window.getSize();
    const frame = window.getFrameSize();
    const outer_left = position[0] - frame[0];
    const outer_top = position[1] - frame[1];
    const outer_width = content[0] + frame[0] + frame[2];
    const outer_height = content[1] + frame[1] + frame[3];

    const monitors = zglfw.Monitor.getAll();
    var best_area = if (zglfw.Monitor.getPrimary()) |monitor|
        monitorWorkArea(monitor)
    else if (monitors.len != 0)
        monitorWorkArea(monitors[0])
    else
        nativeWorkArea();
    var best_overlap = rectangleIntersectionArea(outer_left, outer_top, outer_width, outer_height, best_area);
    for (monitors) |monitor| {
        const area = monitorWorkArea(monitor);
        const overlap = rectangleIntersectionArea(outer_left, outer_top, outer_width, outer_height, area);
        if (overlap > best_overlap) {
            best_area = area;
            best_overlap = overlap;
        }
    }
    return best_area;
}

fn currentWindowGeometry(window: *zglfw.Window) WindowGeometry {
    const content = window.getSize();
    const position = window.getPos();
    const frame = window.getFrameSize();
    return .{
        .content = content,
        .outer = .{ content[0] + frame[0] + frame[2], content[1] + frame[1] + frame[3] },
        .position = position,
        .work_area = workAreaForWindow(window),
    };
}

fn fitWindowToDisplay(window: *zglfw.Window, requested: ?[2]i32) [2]i32 {
    const area = workAreaForWindow(window);
    const frame = window.getFrameSize();
    const maximum = contentMaximum(area, frame);
    const minimum = [2]i32{ @min(720, maximum[0]), @min(540, maximum[1]) };
    window.setSizeLimits(minimum[0], minimum[1], maximum[0], maximum[1]);

    const current = window.getSize();
    const target = clampWindowSize(requested orelse current, maximum);
    const resized = target[0] != current[0] or target[1] != current[1];
    if (resized) window.setSize(target[0], target[1]);

    // Reposition only when this function has resized the window or when a
    // dev command explicitly requested a geometry. Ordinary window dragging
    // must remain free so users can move the app between displays.
    if (resized or requested != null) {
        const position = window.getPos();
        const outer_left = position[0] - frame[0];
        const outer_top = position[1] - frame[1];
        const outer_width = target[0] + frame[0] + frame[2];
        const outer_height = target[1] + frame[1] + frame[3];
        const safe_left = std.math.clamp(outer_left, area.x + window_grab_margin, area.x + area.width - outer_width - window_grab_margin);
        const safe_top = std.math.clamp(outer_top, area.y + window_grab_margin, area.y + area.height - outer_height - window_grab_margin);
        if (safe_left != outer_left or safe_top != outer_top) {
            window.setPos(safe_left + frame[0], safe_top + frame[1]);
        }
    }
    return target;
}

fn clampWindowSize(requested: [2]i32, maximum: [2]i32) [2]i32 {
    return .{
        std.math.clamp(requested[0], @min(720, maximum[0]), maximum[0]),
        std.math.clamp(requested[1], @min(540, maximum[1]), maximum[1]),
    };
}

test "native window requests remain inside the screen-safe work area" {
    try std.testing.expectEqual([2]i32{ 1400, 900 }, clampWindowSize(.{ 1400, 900 }, .{ 1696, 1000 }));
    try std.testing.expectEqual([2]i32{ 1696, 1000 }, clampWindowSize(.{ 1920, 1200 }, .{ 1696, 1000 }));
    try std.testing.expectEqual([2]i32{ 1702, 975 }, contentMaximum(.{ .x = 0, .y = 25, .width = 1728, .height = 1025 }, .{ 1, 25, 1, 1 }));
    try std.testing.expectEqual(@as(i64, 50 * 60), rectangleIntersectionArea(50, 40, 100, 100, .{ .x = 100, .y = 80, .width = 200, .height = 200 }));
}

test "native performance monitor separates cadence from frame work" {
    var monitor: PerformanceMonitor = .{};
    monitor.record(1.0 / 120.0, 0.002, 0.006, 0.0005, 900);
    monitor.record(0.020, 0.004, 0.005, 0.001, 1_200);
    try std.testing.expectEqual(@as(u64, 2), monitor.frame_count);
    try std.testing.expectEqual(@as(u64, 1), monitor.missed_120hz);
    try std.testing.expectEqual(@as(u64, 1), monitor.missed_60hz);
    try std.testing.expectEqual(@as(usize, 1_200), monitor.maximum_draw_items);
    try std.testing.expectApproxEqAbs(@as(f64, 3), monitor.averageWorkMilliseconds(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), monitor.averageAcquireWaitMilliseconds(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), monitor.averagePresentMilliseconds(), 0.0001);
    monitor.reset();
    try std.testing.expectEqual(@as(u64, 0), monitor.frame_count);
}

fn hostDevResponse(output: []u8, comptime format: []const u8, arguments: anytype) usize {
    const value = std.fmt.bufPrint(output, format, arguments) catch return 0;
    return value.len;
}

fn resetMicrophoneMonitor(monitor: *MicrophoneMonitor) void {
    monitor.sequence.store(0, .release);
    monitor.consumed = 0;
    monitor.pitch_count.store(0, .release);
    for (&monitor.pitches) |*pitch| pitch.store(0, .monotonic);
    for (&monitor.confidence_bits) |*confidence| confidence.store(0, .monotonic);
    monitor.timestamp_ns.store(0, .monotonic);
    monitor.attack_tracker = .{};
    monitor.analysis_windows.store(0, .monotonic);
    monitor.analysis_total_ns.store(0, .monotonic);
    monitor.analysis_max_ns.store(0, .monotonic);
    monitor.published_attacks.store(0, .monotonic);
}

fn ensureMicrophone(input: *?*native_c.ScoreAudioInput, input_switch: *AudioInputSwitch, monitor: *MicrophoneMonitor, requested_device: u32, select_route: bool) bool {
    const resolved_device = if (requested_device == std.math.maxInt(u32)) native_c.score_audio_default_input_index() else requested_device;
    if (resolved_device >= native_c.score_audio_input_device_count()) return false;
    if (input.*) |active| {
        if (native_c.score_audio_input_selected_device(active) == resolved_device) return true;
        if (native_c.score_audio_input_is_recording(active) != 0) return false;
    }

    if (input_switch.active()) return false;
    return input_switch.begin(input, monitor, resolved_device, select_route);
}

fn selectedInputLabel(output: []u8, midi_service: ?*native_c.ScoreMidiService, selection: InputSelection) []const u8 {
    if (selection.microphone) {
        var device_name: [128]u8 = [_]u8{0} ** 128;
        const index = if (selection.audio_device == std.math.maxInt(u32)) native_c.score_audio_default_input_index() else selection.audio_device;
        const name_len = native_c.score_audio_input_device_name(index, &device_name, device_name.len);
        const name = if (name_len != 0) device_name[0..@min(name_len, device_name.len)] else "DEFAULT AUDIO INPUT";
        return std.fmt.bufPrint(output, "AUDIO / {s}", .{name}) catch "AUDIO INPUT";
    }
    const count = native_c.score_midi_source_count(midi_service);
    if (count == 0) return std.fmt.bufPrint(output, "SET UP INPUT", .{}) catch "INPUT";
    if (selection.midi_source == std.math.maxInt(u32)) return std.fmt.bufPrint(output, "MIDI / ALL {d} INPUTS", .{count}) catch "ALL MIDI INPUTS";
    var source_name: [128]u8 = [_]u8{0} ** 128;
    const name_len = native_c.score_midi_source_name(midi_service, selection.midi_source, &source_name, source_name.len);
    const name = if (name_len != 0) source_name[0..@min(name_len, source_name.len)] else "UNNAMED INPUT";
    return std.fmt.bufPrint(output, "MIDI / {s}", .{name}) catch "MIDI INPUT";
}

fn updateInputStatus(app: *score.App, midi_service: ?*native_c.ScoreMidiService, audio_input: ?*native_c.ScoreAudioInput, selection: InputSelection) void {
    var label_buffer: [160]u8 = undefined;
    const label = selectedInputLabel(&label_buffer, midi_service, selection);
    if (selection.microphone) {
        app.setInputStatus(if (audio_input != null) .microphone else .none, if (audio_input != null) label else "AUDIO INPUT UNAVAILABLE", native_c.score_audio_input_device_count());
    } else {
        const count = native_c.score_midi_source_count(midi_service);
        app.setInputStatus(if (count != 0) .midi else .none, label, count);
    }
}

fn updatePendingOrReadyInputStatus(app: *score.App, midi_service: ?*native_c.ScoreMidiService, audio_input: ?*native_c.ScoreAudioInput, input_switch: *const AudioInputSwitch, selection: InputSelection) void {
    if (!input_switch.active()) {
        updateInputStatus(app, midi_service, audio_input, selection);
        return;
    }
    var label_buffer: [160]u8 = undefined;
    const label = input_switch.pendingLabel(&label_buffer);
    app.setInputStatus(.none, label, input_switch.input_count);
}

fn selectMidiInput(app: *score.App, midi_service: ?*native_c.ScoreMidiService, input_switch: *const AudioInputSwitch, selection: *InputSelection, index: u32) bool {
    const count = native_c.score_midi_source_count(midi_service);
    if (input_switch.active() or midi_service == null or count == 0 or (index != std.math.maxInt(u32) and index >= count)) return false;
    if (native_c.score_midi_select_source(midi_service, index) == 0) return false;
    selection.* = .{ .midi_source = index, .microphone = false };
    updateInputStatus(app, midi_service, null, selection.*);
    app.setHostStatus(4);
    return true;
}

fn selectMicrophoneInput(app: *score.App, midi_service: ?*native_c.ScoreMidiService, input: *?*native_c.ScoreAudioInput, input_switch: *AudioInputSwitch, monitor: *MicrophoneMonitor, selection: *InputSelection) void {
    const default_device = native_c.score_audio_default_input_index();
    if (default_device >= native_c.score_audio_input_device_count() or !ensureMicrophone(input, input_switch, monitor, default_device, true)) {
        updateInputStatus(app, midi_service, input.*, selection.*);
        app.setHostStatus(5);
        return;
    }
    selection.* = .{ .microphone = true, .audio_device = default_device };
    updatePendingOrReadyInputStatus(app, midi_service, input.*, input_switch, selection.*);
    app.setHostStatus(4);
}

fn selectAudioInput(app: *score.App, midi_service: ?*native_c.ScoreMidiService, input: *?*native_c.ScoreAudioInput, input_switch: *AudioInputSwitch, monitor: *MicrophoneMonitor, selection: *InputSelection, index: u32) bool {
    if (index >= native_c.score_audio_input_device_count() or !ensureMicrophone(input, input_switch, monitor, index, true)) return false;
    selection.* = .{ .microphone = true, .audio_device = index };
    updatePendingOrReadyInputStatus(app, midi_service, input.*, input_switch, selection.*);
    app.setHostStatus(4);
    return true;
}

fn cycleInput(app: *score.App, midi_service: ?*native_c.ScoreMidiService, input: *?*native_c.ScoreAudioInput, input_switch: *AudioInputSwitch, monitor: *MicrophoneMonitor, selection: *InputSelection) void {
    if (input_switch.active()) return;
    const count = native_c.score_midi_source_count(midi_service);
    const audio_count = native_c.score_audio_input_device_count();
    if (selection.microphone) {
        if (selection.audio_device + 1 < audio_count and selectAudioInput(app, midi_service, input, input_switch, monitor, selection, selection.audio_device + 1)) return;
        if (count != 0 and selectMidiInput(app, midi_service, input_switch, selection, std.math.maxInt(u32))) return;
        if (audio_count != 0) _ = selectAudioInput(app, midi_service, input, input_switch, monitor, selection, 0);
        return;
    }
    if (count == 0) {
        if (audio_count != 0) _ = selectAudioInput(app, midi_service, input, input_switch, monitor, selection, 0);
    } else if (selection.midi_source == std.math.maxInt(u32)) {
        _ = selectMidiInput(app, midi_service, input_switch, selection, 0);
    } else if (selection.midi_source + 1 < count) {
        _ = selectMidiInput(app, midi_service, input_switch, selection, selection.midi_source + 1);
    } else if (audio_count != 0) {
        _ = selectAudioInput(app, midi_service, input, input_switch, monitor, selection, 0);
    } else {
        _ = selectMidiInput(app, midi_service, input_switch, selection, std.math.maxInt(u32));
    }
}

fn inputStateResponse(output: []u8, midi_service: ?*native_c.ScoreMidiService, input: ?*native_c.ScoreAudioInput, input_switch: *const AudioInputSwitch, monitor: *const MicrophoneMonitor, selection: InputSelection) usize {
    var label_buffer: [160]u8 = undefined;
    const label = if (input_switch.active()) input_switch.pendingLabel(&label_buffer) else selectedInputLabel(&label_buffer, midi_service, selection);
    const audio_input_count = if (input_switch.active()) input_switch.input_count else native_c.score_audio_input_device_count();
    var pitch_buffer: [96]u8 = undefined;
    const last_pitches = microphonePitchSummary(&pitch_buffer, monitor);
    const selected = if (selection.microphone) "audio" else if (selection.midi_source == std.math.maxInt(u32)) "all" else "indexed";
    return hostDevResponse(output, "ok mode={s} selected={s} midi_index={d} midi_sources={d} midi_destinations={d} audio_index={d} audio_inputs={d} switching={d} audio_started={d} recording={d} input_hz={d:.0} device_hz={d:.0} buffer_frames={d} callback_frames={d} max_callback_frames={d} latency_frames={d} safety_frames={d} estimated_input_ms={d:.3} analysis_windows={d} avg_analysis_ms={d:.3} max_analysis_ms={d:.3} attacks={d} last_pitches={s} label={s}", .{
        if (selection.microphone) "microphone" else "midi",
        selected,
        selection.midi_source,
        native_c.score_midi_source_count(midi_service),
        native_c.score_midi_destination_count(midi_service),
        if (selection.microphone) selection.audio_device else std.math.maxInt(u32),
        audio_input_count,
        @intFromBool(input_switch.active()),
        @intFromBool(input != null),
        native_c.score_audio_input_is_recording(input),
        native_c.score_audio_input_sample_rate(input),
        native_c.score_audio_input_device_sample_rate(input),
        native_c.score_audio_input_device_buffer_frames(input),
        native_c.score_audio_input_callback_frames(input),
        native_c.score_audio_input_max_callback_frames(input),
        native_c.score_audio_input_device_latency_frames(input),
        native_c.score_audio_input_safety_offset_frames(input),
        native_c.score_audio_input_estimated_latency_seconds(input) * 1000.0,
        monitor.analysis_windows.load(.acquire),
        monitor.averageAnalysisMilliseconds(),
        @as(f64, @floatFromInt(monitor.analysis_max_ns.load(.acquire))) / std.time.ns_per_ms,
        monitor.published_attacks.load(.acquire),
        last_pitches,
        label,
    });
}

fn microphonePitchSummary(output: []u8, monitor: *const MicrophoneMonitor) []const u8 {
    const count = @min(score.pitch.max_polyphonic_pitches, monitor.pitch_count.load(.acquire));
    if (count == 0) return "none";
    var len: usize = 0;
    for (0..count) |index| {
        const pitch = monitor.pitches[index].load(.monotonic);
        const written = if (index == 0)
            std.fmt.bufPrint(output[len..], "{d}", .{pitch}) catch break
        else
            std.fmt.bufPrint(output[len..], ",{d}", .{pitch}) catch break;
        len += written.len;
    }
    return if (len == 0) "none" else output[0..len];
}

fn audioInput(samples: [*c]const f32, frames: u32, sample_rate: f64, timestamp_ns: u64, context: ?*anyopaque) callconv(.c) void {
    const monitor: *MicrophoneMonitor = @ptrCast(@alignCast(context orelse return));
    const analysis_start_ns = native_c.score_host_time_now_ns();
    const detected = score.pitch.detectPolyphonic(samples[0..frames], @floatCast(sample_rate));
    const analysis_ns = native_c.score_host_time_now_ns() - analysis_start_ns;
    _ = monitor.analysis_windows.fetchAdd(1, .monotonic);
    _ = monitor.analysis_total_ns.fetchAdd(analysis_ns, .monotonic);
    var maximum = monitor.analysis_max_ns.load(.monotonic);
    while (analysis_ns > maximum) {
        if (monitor.analysis_max_ns.cmpxchgWeak(maximum, analysis_ns, .release, .monotonic)) |observed| {
            maximum = observed;
        } else break;
    }
    var new_attacks: [score.pitch.max_polyphonic_pitches]score.pitch.Detection = undefined;
    const new_attack_count = monitor.attack_tracker.update(detected, &new_attacks);
    if (new_attack_count == 0) return;
    _ = monitor.published_attacks.fetchAdd(new_attack_count, .monotonic);

    // Odd sequence values mean the producer is publishing. The main thread
    // accepts only a stable even value, giving this small atomic payload
    // seqlock semantics without blocking the real-time callback.
    _ = monitor.sequence.fetchAdd(1, .acq_rel);
    for (new_attacks[0..new_attack_count], 0..) |candidate, index| {
        monitor.pitches[index].store(candidate.midi_note, .monotonic);
        monitor.confidence_bits[index].store(@bitCast(candidate.confidence), .monotonic);
    }
    monitor.pitch_count.store(@intCast(new_attack_count), .monotonic);
    const observation_ns = timestamp_ns + @as(u64, @intFromFloat(@as(f64, @floatFromInt(frames)) * 0.5 / sample_rate * std.time.ns_per_s));
    monitor.timestamp_ns.store(observation_ns, .monotonic);
    _ = monitor.sequence.fetchAdd(1, .release);
}

fn accessibilityActivate(id: u32, context: ?*anyopaque) callconv(.c) void {
    const app: *score.App = @ptrCast(@alignCast(context orelse return));
    app.accessibilityActivate(id);
}

fn pumpMicrophone(app: *score.App, monitor: *MicrophoneMonitor) void {
    const before = monitor.sequence.load(.acquire);
    if (before == monitor.consumed or (before & 1) != 0) return;
    const count = @min(score.pitch.max_polyphonic_pitches, monitor.pitch_count.load(.monotonic));
    var pitches: [score.pitch.max_polyphonic_pitches]u8 = undefined;
    var confidences: [score.pitch.max_polyphonic_pitches]f32 = undefined;
    for (0..count) |index| {
        pitches[index] = @intCast(monitor.pitches[index].load(.monotonic));
        confidences[index] = @bitCast(monitor.confidence_bits[index].load(.monotonic));
    }
    const timestamp_ns = monitor.timestamp_ns.load(.monotonic);
    const after = monitor.sequence.load(.acquire);
    if (before != after or (after & 1) != 0) return;
    monitor.consumed = after;
    const now_ns = native_c.score_host_time_now_ns();
    const age_seconds: f32 = if (timestamp_ns != 0 and now_ns > timestamp_ns)
        @floatCast(@as(f64, @floatFromInt(now_ns - timestamp_ns)) / std.time.ns_per_s)
    else
        0;
    for (pitches[0..count], confidences[0..count]) |pitch, confidence| app.microphonePitchDelayed(pitch, confidence, age_seconds);
}

fn audioRender(samples: [*c]f32, frames: u32, channels: u32, sample_rate: f64, context: ?*anyopaque) callconv(.c) void {
    const synth: *SfizzSampler = @ptrCast(@alignCast(context orelse return));
    const len = @as(usize, frames) * channels;
    synth.renderInterleaved(samples[0..len], frames, channels, @floatCast(sample_rate));
}

fn pumpMidiInput(app: *score.App, synth: *SfizzSampler, service: ?*native_c.ScoreMidiService) void {
    var events: [128]native_c.ScoreMidiEvent = undefined;
    const count = native_c.score_midi_poll(service, &events, events.len);
    for (events[0..count]) |event| {
        app.midiInput(event.time_ns, event.status, event.data1, event.data2);
        const message = event.status & 0xf0;
        if (message == 0x90 and event.data2 != 0) {
            synth.noteOn(event.status & 0x0f, event.data1, event.data2);
        } else if (message == 0x80 or (message == 0x90 and event.data2 == 0)) {
            synth.noteOff(event.status & 0x0f, event.data1);
        } else if (message == 0xb0) {
            synth.controlChange(event.status & 0x0f, event.data1, event.data2);
        }
    }
}

fn pumpPlayback(app: *score.App, synth: *SfizzSampler, service: ?*native_c.ScoreMidiService) void {
    var events: [128]score.playback.ScheduledHostEvent = undefined;
    const count = app.drainScheduledPlaybackEvents(&events);
    for (events[0..count]) |scheduled| {
        const event = scheduled.event;
        if (event.on == 2) {
            synth.allNotesOffDelayed(scheduled.delay_seconds);
            continue;
        }
        if (event.on == 3) {
            synth.clickDelayed(event.velocity >= 120, scheduled.delay_seconds);
            continue;
        }
        if (event.on == 4) {
            synth.controlChangeDelayed(event.channel, event.pitch, event.velocity, scheduled.delay_seconds);
            continue;
        }
        if (event.on != 0) {
            synth.noteOnDelayed(event.channel, event.pitch, event.velocity, scheduled.delay_seconds);
        } else {
            synth.noteOffDelayed(event.channel, event.pitch, scheduled.delay_seconds);
        }
    }
    _ = service;
}

fn cursorCallback(window: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
    const app = window.getUserPointer(score.App) orelse return;
    app.pointer(pointerEvent(.move, x, y, 0, 0, 0));
}

fn mouseButtonCallback(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    _ = mods;
    const app = window.getUserPointer(score.App) orelse return;
    const position = window.getCursorPos();
    const kind: score.platform.PointerKind = if (action == .press) .down else .up;
    // Match browser PointerEvent.buttons instead of forwarding GLFW's
    // zero-based enum (where the primary button is 0 and looked unpressed).
    const button_mask: u32 = @as(u32, 1) << @intCast(@intFromEnum(button));
    app.pointer(pointerEvent(kind, position[0], position[1], button_mask, 1, 0));
}

fn scrollCallback(window: *zglfw.Window, x_offset: f64, y_offset: f64) callconv(.c) void {
    const app = window.getUserPointer(score.App) orelse return;
    const position = window.getCursorPos();
    app.pointer(pointerEvent(.scroll, position[0], position[1], 0, x_offset, y_offset));
}

fn keyCallback(window: *zglfw.Window, key: zglfw.Key, scancode: c_int, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    const app = window.getUserPointer(score.App) orelse return;
    app.key(.{
        .key = @bitCast(@intFromEnum(key)),
        .scancode = @bitCast(scancode),
        .modifiers = @bitCast(mods),
        .pressed = if (action == .release) 0 else 1,
        .repeat = if (action == .repeat) 1 else 0,
    });
}

fn dropCallback(window: *zglfw.Window, path_count: i32, paths: [*][*:0]const u8) callconv(.c) void {
    const app = window.getUserPointer(score.App) orelse return;
    if (path_count <= 0) return;
    loadScorePath(app, std.heap.c_allocator, paths[0]) catch |err| std.log.err("dropped score import failed: {s}", .{@errorName(err)});
}

fn loadScorePath(app: *score.App, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const bytes = try readWholeFile(allocator, path);
    defer allocator.free(bytes);
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
        try app.importMxl(bytes);
    } else if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], score.native_format.magic)) {
        try app.deserialize(bytes);
    } else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "MThd")) {
        try app.importMidi(bytes);
    } else {
        try app.importMusicXml(bytes);
    }
    std.log.info("imported score: {s}", .{path});
    const saved = blk: {
        saveAutosave(app, allocator) catch |err| {
            std.log.warn("imported score could not be checkpointed immediately: {s}", .{@errorName(err)});
            break :blk false;
        };
        break :blk true;
    };
    if (saved) persistScoreSource(std.mem.span(path), std.hash.crc.Crc32.hash(bytes)) catch |err| {
        std.log.warn("score source tracking unavailable: {s}", .{@errorName(err)});
    };
    app.setHostStatus(2);
}

fn readWholeFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const file = native_c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = native_c.fclose(file);
    if (native_c.fseek(file, 0, native_c.SEEK_END) != 0) return error.SeekFailed;
    const length = native_c.ftell(file);
    if (length < 0 or length > 64 * 1024 * 1024) return error.FileTooLarge;
    if (native_c.fseek(file, 0, native_c.SEEK_SET) != 0) return error.SeekFailed;
    const bytes = try allocator.alloc(u8, @intCast(length));
    errdefer allocator.free(bytes);
    if (bytes.len != 0 and native_c.fread(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.ReadFailed;
    return bytes;
}

fn loadAutosave(app: *score.App, allocator: std.mem.Allocator) bool {
    var path_buffer: [4096]u8 = undefined;
    const path = appDataPath(&path_buffer, autosaveBasename()) catch return false;
    const bytes = readWholeFile(allocator, path.ptr) catch return false;
    defer allocator.free(bytes);
    app.deserialize(bytes) catch |err| {
        std.log.warn("autosave recovery skipped: {s}", .{@errorName(err)});
        return false;
    };
    std.log.info("recovered autosave", .{});
    app.setHostStatus(7);
    return true;
}

fn saveAutosave(app: *const score.App, allocator: std.mem.Allocator) !void {
    const bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(bytes);
    const len = try app.serialize(bytes);
    var temporary_name_buffer: [64]u8 = undefined;
    const temporary_name = try std.fmt.bufPrint(&temporary_name_buffer, "{s}.{d}.tmp", .{ autosaveBasename(), native_c.getpid() });
    var temporary_buffer: [4096]u8 = undefined;
    var destination_buffer: [4096]u8 = undefined;
    const temporary = try appDataPath(&temporary_buffer, temporary_name);
    const destination = try appDataPath(&destination_buffer, autosaveBasename());
    errdefer _ = native_c.unlink(temporary.ptr);
    const file = native_c.fopen(temporary.ptr, "wb") orelse return error.OpenFailed;
    if (native_c.fwrite(bytes.ptr, 1, len, file) != len) {
        _ = native_c.fclose(file);
        return error.WriteFailed;
    }
    if (native_c.fflush(file) != 0) {
        _ = native_c.fclose(file);
        return error.FlushFailed;
    }
    _ = native_c.fsync(native_c.fileno(file));
    if (native_c.fclose(file) != 0) return error.CloseFailed;
    if (native_c.rename(temporary.ptr, destination.ptr) != 0) return error.RenameFailed;
}

fn autosaveBasename() []const u8 {
    // Development builds may coexist with older release/native windows while the
    // hot-reload watcher restarts this process. Keep their recovery journals
    // independent so those windows cannot overwrite the score under test.
    return if (build_options.hot_reload) "autosave-dev.score" else "autosave.score";
}

const ScoreSource = struct {
    path: [:0]const u8,
    crc: u32,
};

fn scoreSourceBasename() []const u8 {
    return if (build_options.hot_reload) "score-source-dev.txt" else "score-source.txt";
}

fn loadPersistedScoreSource(output: *[std.fs.max_path_bytes:0]u8) ?ScoreSource {
    var configuration_path_buffer: [4096]u8 = undefined;
    const configuration_path = appDataPath(&configuration_path_buffer, scoreSourceBasename()) catch return null;
    const file = native_c.fopen(configuration_path.ptr, "rb") orelse return null;
    defer _ = native_c.fclose(file);
    var record: [std.fs.max_path_bytes + 64]u8 = undefined;
    const count = native_c.fread(&record, 1, record.len, file);
    if (count == 0 or count == record.len or native_c.ferror(file) != 0) return null;
    var lines = std.mem.splitScalar(u8, record[0..count], '\n');
    if (!std.mem.eql(u8, lines.next() orelse return null, "SCORE-SOURCE-1")) return null;
    const crc = std.fmt.parseUnsigned(u32, lines.next() orelse return null, 16) catch return null;
    const raw_path = std.mem.trim(u8, lines.next() orelse return null, " \t\r");
    if (raw_path.len == 0 or raw_path.len >= output.len or !std.fs.path.isAbsolute(raw_path)) return null;
    @memcpy(output[0..raw_path.len], raw_path);
    output[raw_path.len] = 0;
    const path = output[0..raw_path.len :0];
    return if (readableFile(path.ptr)) .{ .path = path, .crc = crc } else null;
}

fn persistScoreSource(path: []const u8, crc: u32) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\n') != null) return;
    var record_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const record = try std.fmt.bufPrint(&record_buffer, "SCORE-SOURCE-1\n{x:0>8}\n{s}\n", .{ crc, path });
    var configuration_path_buffer: [4096]u8 = undefined;
    const configuration_path = try appDataPath(&configuration_path_buffer, scoreSourceBasename());
    const file = native_c.fopen(configuration_path.ptr, "wb") orelse return error.OpenFailed;
    defer _ = native_c.fclose(file);
    if (native_c.fwrite(record.ptr, 1, record.len, file) != record.len) return error.WriteFailed;
    if (native_c.fflush(file) != 0) return error.FlushFailed;
    _ = native_c.fsync(native_c.fileno(file));
}

fn scoreSourceCrc(allocator: std.mem.Allocator, path: [*:0]const u8) !u32 {
    const bytes = try readWholeFile(allocator, path);
    defer allocator.free(bytes);
    return std.hash.crc.Crc32.hash(bytes);
}

fn appDataPath(buffer: *[4096]u8, basename: []const u8) ![:0]u8 {
    const root_pointer = native_c.score_application_support_path();
    if (root_pointer == null or root_pointer[0] == 0) return error.ApplicationSupportUnavailable;
    return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ std.mem.span(root_pointer), basename });
}

fn exportScorePath(app: *score.App, renderer: *Renderer, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const extension = std.fs.path.extension(std.mem.span(path));
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return savePdfPath(app, renderer, allocator, path);
    return saveScorePath(app, allocator, path);
}

fn savePdfPath(app: *score.App, renderer: *Renderer, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const pdf = native_c.score_pdf_begin(path, pdf_width_points, pdf_height_points) orelse return error.PdfContextFailed;
    defer native_c.score_pdf_end(pdf);
    const packet = try allocator.create(score.render.Packet);
    defer allocator.destroy(packet);
    var beat: f32 = 0;
    var page_guard: usize = 0;
    const end_beat = app.printableEndBeat();
    while (page_guard < 2048) : (page_guard += 1) {
        const page = try app.buildPrintablePage(packet, @floatFromInt(pdf_width_pixels), @floatFromInt(pdf_height_pixels), beat);
        try renderer.appendPdfPage(pdf, packet.slice(), pdf_width_pixels, pdf_height_pixels);
        const next_beat = page.endBeat();
        if (next_beat >= end_beat - 0.0001) break;
        if (next_beat <= beat + 0.0001) return error.PdfPaginationStalled;
        beat = next_beat;
    } else return error.PdfPageLimitExceeded;
    app.setHostStatus(8);
}

fn saveScorePath(app: *score.App, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const bytes = try allocator.alloc(u8, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    const extension = std.fs.path.extension(std.mem.span(path));
    const len = if (std.ascii.eqlIgnoreCase(extension, ".mid") or std.ascii.eqlIgnoreCase(extension, ".midi"))
        try app.exportMidi(bytes)
    else if (std.ascii.eqlIgnoreCase(extension, ".score"))
        try app.serialize(bytes)
    else if (std.ascii.eqlIgnoreCase(extension, ".mxl"))
        try app.exportMxl(bytes)
    else
        try app.exportMusicXml(bytes);
    const file = native_c.fopen(path, "wb") orelse return error.OpenFailed;
    if (native_c.fwrite(bytes.ptr, 1, len, file) != len) {
        _ = native_c.fclose(file);
        return error.WriteFailed;
    }
    if (native_c.fflush(file) != 0) {
        _ = native_c.fclose(file);
        return error.FlushFailed;
    }
    _ = native_c.fsync(native_c.fileno(file));
    if (native_c.fclose(file) != 0) return error.CloseFailed;
    app.setHostStatus(8);
}

fn saveTakePath(app: *score.App, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(bytes);
    const len = try app.exportTakeMidi(bytes);
    const file = native_c.fopen(path, "wb") orelse return error.OpenFailed;
    if (native_c.fwrite(bytes.ptr, 1, len, file) != len) {
        _ = native_c.fclose(file);
        return error.WriteFailed;
    }
    if (native_c.fflush(file) != 0) {
        _ = native_c.fclose(file);
        return error.FlushFailed;
    }
    _ = native_c.fsync(native_c.fileno(file));
    if (native_c.fclose(file) != 0) return error.CloseFailed;
    app.setHostStatus(11);
}

fn pointerEvent(kind: score.platform.PointerKind, x: f64, y: f64, buttons: u32, scroll_x: f64, scroll_y: f64) score.platform.PointerEvent {
    return .{
        .kind = kind,
        .pointer_type = .mouse,
        .id = 0,
        .buttons = buttons,
        .x = @floatCast(x),
        .y = @floatCast(y),
        .pressure = if (buttons == 0) 0 else 1,
        .tilt_x = 0,
        .tilt_y = 0,
        .scroll_x = @floatCast(scroll_x),
        .scroll_y = @floatCast(scroll_y),
    };
}
