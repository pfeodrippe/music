const std = @import("std");
const score = @import("score");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const build_options = @import("build_options");

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
    pitch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    confidence_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    timestamp_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

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
            std.log.err("hot reload module has no score_plugin_descriptor", .{});
            return;
        };
        app.applySystemPlugin(entry()) catch |err| {
            candidate.close();
            _ = native_c.unlink(staged.ptr);
            app.restoreBuiltinSystems();
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
};

const Renderer = struct {
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
        };
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

    fn draw(self: *Renderer, app: *const score.App, logical_size: [2]i32, scale: [2]f32, time: f32) void {
        if (!self.context.canRender()) return;
        const width: f32 = @floatFromInt(@max(logical_size[0], 1));
        const height: f32 = @floatFromInt(@max(logical_size[1], 1));
        const frame = Uniforms{ .viewport = .{ width, height }, .time = time, .pixel_ratio = scale[0] };
        const items = app.drawItems();
        self.context.queue.writeBuffer(self.uniforms, 0, Uniforms, (&[_]Uniforms{frame})[0..]);
        if (items.len != 0) self.context.queue.writeBuffer(self.instances, 0, score.render.DrawItem, items);

        const back_buffer = self.context.swapchain.getCurrentTextureView();
        defer back_buffer.release();
        const encoder = self.context.device.createCommandEncoder(null);
        defer encoder.release();
        const attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer,
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
        const commands = encoder.finish(null);
        defer commands.release();
        self.context.submit(&.{commands});
        _ = self.context.present();
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    try zglfw.init();
    defer zglfw.terminate();
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.cocoa_retina_framebuffer, true);
    zglfw.windowHint(.scale_framebuffer, true);

    const window = try zglfw.Window.create(1440, 900, "Score — notation and piano practice", null, null);
    defer window.destroy();
    window.setSizeLimits(720, 540, -1, -1);

    const initial_size = window.getSize();
    const initial_scale = window.getContentScale();
    const app = try score.App.create(allocator, @floatFromInt(initial_size[0]), @floatFromInt(initial_size[1]), initial_scale[0]);
    defer app.destroy(allocator);
    var synth: score.synth.Synth = .{};
    const audio_output = native_c.score_audio_output_start(audioRender, &synth);
    defer native_c.score_audio_output_stop(audio_output);
    const midi_service = native_c.score_midi_create();
    defer native_c.score_midi_destroy(midi_service);
    std.log.info("music devices: {d} MIDI inputs, {d} MIDI outputs, audio {d:.0} Hz", .{
        native_c.score_midi_source_count(midi_service),
        native_c.score_midi_destination_count(midi_service),
        native_c.score_audio_output_sample_rate(audio_output),
    });
    var microphone_monitor: MicrophoneMonitor = .{};
    var audio_input: ?*native_c.ScoreAudioInput = null;
    defer native_c.score_audio_input_stop(audio_input);
    var reloader: DevReloader = .{};
    defer reloader.deinit(app);
    window.setUserPointer(app);
    _ = window.setCursorPosCallback(cursorCallback);
    _ = window.setMouseButtonCallback(mouseButtonCallback);
    _ = window.setScrollCallback(scrollCallback);
    _ = window.setKeyCallback(keyCallback);
    _ = window.setDropCallback(dropCallback);

    loadAutosave(app, allocator);

    var renderer = try Renderer.init(allocator, window);
    defer renderer.deinit(allocator);

    var previous_time = zglfw.getTime();
    var next_autosave = previous_time + 2;
    while (!window.shouldClose()) {
        zglfw.pollEvents();
        const now = zglfw.getTime();
        reloader.poll(app, now);
        switch (app.takeHostRequest()) {
            .open_score => {
                const selected = native_c.score_open_score_panel();
                if (selected != null and selected[0] != 0) loadScorePath(app, allocator, selected) catch |err| {
                    app.setHostStatus(3);
                    std.log.err("import failed: {s}", .{@errorName(err)});
                };
            },
            .choose_microphone => {
                ensureMicrophone(&audio_input, &microphone_monitor);
                app.setHostStatus(if (audio_input != null or native_c.score_midi_source_count(midi_service) != 0) 4 else 5);
            },
            .export_score => {
                const selected = native_c.score_save_score_panel();
                if (selected != null and selected[0] != 0) saveScorePath(app, allocator, selected) catch |err| {
                    app.setHostStatus(3);
                    std.log.err("score export failed: {s}", .{@errorName(err)});
                };
            },
            .start_recording => {
                ensureMicrophone(&audio_input, &microphone_monitor);
                var audio_path_buffer: [4096]u8 = undefined;
                const audio_path = appDataPath(&audio_path_buffer, "latest-take.wav") catch null;
                if (audio_path == null or native_c.score_audio_input_begin_recording(audio_input, audio_path.?.ptr) == 0) std.log.warn("microphone recording unavailable; MIDI capture remains active", .{});
            },
            .stop_recording => {
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
        const logical_size = window.getSize();
        const scale = window.getContentScale();
        app.resize(@floatFromInt(logical_size[0]), @floatFromInt(logical_size[1]), scale[0]);
        app.tick(delta);
        const semantic_items = app.accessibilityItems();
        native_c.score_accessibility_update(@ptrCast(semantic_items.ptr), @intCast(semantic_items.len), accessibilityActivate, app);
        pumpMidiInput(app, &synth, midi_service);
        pumpMicrophone(app, &microphone_monitor);
        pumpPlayback(app, &synth, midi_service);
        renderer.draw(app, logical_size, scale, @floatCast(now));
        if (now >= next_autosave) {
            saveAutosave(app, allocator) catch |err| std.log.warn("autosave failed: {s}", .{@errorName(err)});
            next_autosave = now + 2;
        }
    }
    try saveAutosave(app, allocator);
}

fn ensureMicrophone(input: *?*native_c.ScoreAudioInput, monitor: *MicrophoneMonitor) void {
    if (input.* != null) return;
    input.* = native_c.score_audio_input_start(audioInput, monitor);
    if (input.* == null) std.log.warn("microphone permission or input device unavailable", .{}) else std.log.info("microphone practice active", .{});
}

fn audioInput(samples: [*c]const f32, frames: u32, sample_rate: f64, timestamp_ns: u64, context: ?*anyopaque) callconv(.c) void {
    const monitor: *MicrophoneMonitor = @ptrCast(@alignCast(context orelse return));
    const detected = score.pitch.detect(samples[0..frames], @floatCast(sample_rate)) orelse return;
    monitor.pitch.store(detected.midi_note, .monotonic);
    monitor.confidence_bits.store(@bitCast(detected.confidence), .monotonic);
    monitor.timestamp_ns.store(timestamp_ns, .monotonic);
    _ = monitor.sequence.fetchAdd(1, .release);
}

fn accessibilityActivate(id: u32, context: ?*anyopaque) callconv(.c) void {
    const app: *score.App = @ptrCast(@alignCast(context orelse return));
    app.accessibilityActivate(id);
}

fn pumpMicrophone(app: *score.App, monitor: *MicrophoneMonitor) void {
    const sequence = monitor.sequence.load(.acquire);
    if (sequence == monitor.consumed) return;
    monitor.consumed = sequence;
    app.microphonePitch(@intCast(monitor.pitch.load(.monotonic)), @bitCast(monitor.confidence_bits.load(.monotonic)));
}

fn audioRender(samples: [*c]f32, frames: u32, channels: u32, sample_rate: f64, context: ?*anyopaque) callconv(.c) void {
    const synth: *score.synth.Synth = @ptrCast(@alignCast(context orelse return));
    const len = @as(usize, frames) * channels;
    synth.renderInterleaved(samples[0..len], frames, channels, @floatCast(sample_rate));
}

fn pumpMidiInput(app: *score.App, synth: *score.synth.Synth, service: ?*native_c.ScoreMidiService) void {
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

fn pumpPlayback(app: *score.App, synth: *score.synth.Synth, service: ?*native_c.ScoreMidiService) void {
    var events: [128]score.playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    for (events[0..count]) |event| {
        if (event.on == 2) {
            synth.allNotesOff();
            continue;
        }
        if (event.on == 3) {
            synth.click(event.velocity >= 120);
            continue;
        }
        if (event.on != 0) {
            synth.noteOn(event.channel, event.pitch, event.velocity);
        } else {
            synth.noteOff(event.channel, event.pitch);
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
    app.pointer(pointerEvent(kind, position[0], position[1], @intCast(@intFromEnum(button)), 1, 0));
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

fn loadAutosave(app: *score.App, allocator: std.mem.Allocator) void {
    var path_buffer: [4096]u8 = undefined;
    const path = appDataPath(&path_buffer, "autosave.score") catch return;
    const bytes = readWholeFile(allocator, path.ptr) catch return;
    defer allocator.free(bytes);
    app.deserialize(bytes) catch |err| {
        std.log.warn("autosave recovery skipped: {s}", .{@errorName(err)});
        return;
    };
    std.log.info("recovered autosave", .{});
    app.setHostStatus(7);
}

fn saveAutosave(app: *const score.App, allocator: std.mem.Allocator) !void {
    const bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(bytes);
    const len = try app.serialize(bytes);
    var temporary_buffer: [4096]u8 = undefined;
    var destination_buffer: [4096]u8 = undefined;
    const temporary = try appDataPath(&temporary_buffer, "autosave.score.tmp");
    const destination = try appDataPath(&destination_buffer, "autosave.score");
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

fn appDataPath(buffer: *[4096]u8, basename: []const u8) ![:0]u8 {
    const root_pointer = native_c.score_application_support_path();
    if (root_pointer == null or root_pointer[0] == 0) return error.ApplicationSupportUnavailable;
    return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ std.mem.span(root_pointer), basename });
}

fn saveScorePath(app: *score.App, allocator: std.mem.Allocator, path: [*:0]const u8) !void {
    const bytes = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(bytes);
    const len = try app.exportMusicXml(bytes);
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
