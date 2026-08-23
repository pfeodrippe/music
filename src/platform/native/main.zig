const std = @import("std");
const score = @import("score");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const build_options = @import("build_options");
const sfizz_sampler = @import("sfizz_sampler.zig");
const SfizzSampler = sfizz_sampler.Sampler;
const dev_control = @import("dev_control.zig");

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
        self.encodePass(encoder, back_buffer, items);
        const commands = encoder.finish(null);
        defer commands.release();
        self.context.submit(&.{commands});
        _ = self.context.present();
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var arguments = std.process.Args.Iterator.init(init.minimal.args);
    _ = arguments.next();
    var initial_score_path: ?[:0]const u8 = null;
    const accurate_salamander_path: [:0]const u8 = "local-content/instruments/AccurateSalamanderGrandPianoV6.2beta2/sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz";
    const salamander_v3_path: [:0]const u8 = "local-content/instruments/SalamanderGrandPiano/Salamander Grand Piano V3.sfz";
    var instrument_path: [:0]const u8 = if (readableFile(accurate_salamander_path.ptr)) accurate_salamander_path else salamander_v3_path;
    if (native_c.getenv("SCORE_INSTRUMENT")) |configured| if (configured[0] != 0) {
        instrument_path = std.mem.span(configured);
    };
    var expects_instrument_path = false;
    var start_playing = false;
    while (arguments.next()) |argument| {
        if (expects_instrument_path) {
            instrument_path = argument;
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
    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_dir_len = try std.process.executableDirPath(init.io, &executable_path_buffer);
    var bundle_library_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bundle_library = try std.fmt.bufPrint(&bundle_library_buffer, "{s}/../Frameworks/libsfizz.dylib", .{executable_path_buffer[0..executable_dir_len]});
    const sampler_library_paths = [_][]const u8{
        "zig-out/lib/libsfizz.dylib",
        bundle_library,
    };
    const sampler = try SfizzSampler.create(allocator, &sampler_library_paths, instrument_path);
    defer sampler.destroy();
    // The reference Salamander/Accurate-Salamander profiles document these
    // controls as sampled release, hammer noise, pedal mechanics, and damper
    // resonance. Other SFZ instruments safely ignore unbound controllers.
    sampler.applyPianoDetailProfile(.studio);
    const audio_output = native_c.score_audio_output_start(audioRender, sampler);
    defer native_c.score_audio_output_stop(audio_output);
    const midi_service = native_c.score_midi_create();
    defer native_c.score_midi_destroy(midi_service);
    std.log.info("music devices: {d} MIDI inputs, {d} MIDI outputs, audio {d:.0} Hz; SFZ {d} regions / {d} preloaded samples; instrument {s}", .{
        native_c.score_midi_source_count(midi_service),
        native_c.score_midi_destination_count(midi_service),
        native_c.score_audio_output_sample_rate(audio_output),
        sampler.region_count,
        sampler.preloaded_sample_count,
        instrument_path,
    });
    var microphone_monitor: MicrophoneMonitor = .{};
    var audio_input: ?*native_c.ScoreAudioInput = null;
    defer native_c.score_audio_input_stop(audio_input);
    var reloader: DevReloader = .{};
    defer reloader.deinit(app);
    var dev_server: ?dev_control.Server = null;
    if (build_options.hot_reload) {
        dev_server = dev_control.Server.init() catch |err| blk: {
            std.log.warn("development control unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (dev_server) |*server| std.log.info("development control listening at {s}", .{server.pathSlice()});
    }
    // A Debug host which does not own the single live control socket is an
    // older/duplicate window. It may remain useful for visual comparison, but
    // it must never overwrite the authoritative development recovery journal.
    // This prevents a stale score from reappearing after a watcher restart.
    const autosave_writer = !build_options.hot_reload or dev_server != null;
    if (!autosave_writer) std.log.warn("duplicate development host is read-only for autosave recovery", .{});
    defer if (dev_server) |*server| server.deinit();
    window.setUserPointer(app);
    _ = window.setCursorPosCallback(cursorCallback);
    _ = window.setMouseButtonCallback(mouseButtonCallback);
    _ = window.setScrollCallback(scrollCallback);
    _ = window.setKeyCallback(keyCallback);
    _ = window.setDropCallback(dropCallback);

    loadAutosave(app, allocator);
    if (initial_score_path) |path| {
        loadScorePath(app, allocator, path.ptr) catch |err| {
            std.log.err("initial score import failed for {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
    }
    if (start_playing) app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });

    var renderer = try Renderer.init(allocator, window);
    defer renderer.deinit(allocator);
    var shader_reloader: DevShaderReloader = .{};

    var previous_time = zglfw.getTime();
    var next_autosave = previous_time + 2;
    while (!window.shouldClose()) {
        zglfw.pollEvents();
        const now = zglfw.getTime();
        const logical_size = window.getSize();
        const scale = window.getContentScale();
        reloader.poll(app, now);
        shader_reloader.poll(app, &renderer, now);
        if (dev_server) |*server| pumpDevControl(server, app, sampler, instrument_path, &reloader, &shader_reloader, &renderer, window, logical_size, scale, @floatCast(now));
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
        app.resize(@floatFromInt(logical_size[0]), @floatFromInt(logical_size[1]), scale[0]);
        app.tick(delta);
        const semantic_items = app.accessibilityItems();
        native_c.score_accessibility_update(@ptrCast(semantic_items.ptr), @intCast(semantic_items.len), accessibilityActivate, app);
        pumpMidiInput(app, sampler, midi_service);
        pumpMicrophone(app, &microphone_monitor);
        pumpPlayback(app, sampler, midi_service);
        renderer.draw(app, logical_size, scale, @floatCast(now));
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

fn pumpDevControl(server: *dev_control.Server, app: *score.App, sampler: *SfizzSampler, instrument_path: []const u8, reloader: *DevReloader, shader_reloader: *DevShaderReloader, renderer: *Renderer, window: *zglfw.Window, logical_size: [2]i32, scale: [2]f32, time: f32) void {
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
    } else if (std.mem.startsWith(u8, command, "window ")) {
        if (parseWindowSize(std.mem.trim(u8, command[7..], " \t\r\n"))) |size| {
            window.setSize(size[0], size[1]);
            response_len = hostDevResponse(&response, "ok window={d}x{d}", .{ size[0], size[1] });
        } else {
            response_len = hostDevResponse(&response, "error usage: window WIDTH HEIGHT (720..3840 x 540..2160)", .{});
        }
    } else if (std.mem.eql(u8, command, "sampler state")) {
        const detail = sampler.pianoDetailProfile();
        response_len = hostDevResponse(&response, "ok regions={d} preloaded={d} dropped={d} overloaded={d} release={d} hammer={d} pedal_noise={d} resonance={d} instrument={s}", .{
            sampler.region_count,
            sampler.preloaded_sample_count,
            sampler.droppedEventCount(),
            sampler.overloadedSampleCount(),
            detail.sampled_release,
            detail.hammer_noise,
            detail.pedal_noise,
            detail.pedal_resonance,
            instrument_path,
        });
    } else if (std.mem.startsWith(u8, command, "sampler detail ")) {
        const argument = std.mem.trim(u8, command[15..], " \t\r\n");
        if (parseSamplerDetail(argument)) |profile| {
            sampler.applyPianoDetailProfile(profile);
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
        if (std.mem.startsWith(u8, response[0..response_len], "ok ")) dispatchDevMidi(sampler, command[5..]);
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

fn hostDevResponse(output: []u8, comptime format: []const u8, arguments: anytype) usize {
    const value = std.fmt.bufPrint(output, format, arguments) catch return 0;
    return value.len;
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
        if (event.on == 4) {
            synth.controlChange(event.channel, event.pitch, event.velocity);
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
    const path = appDataPath(&path_buffer, autosaveBasename()) catch return;
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
