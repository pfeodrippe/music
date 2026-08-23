const std = @import("std");
const model = @import("model.zig");
const ui = @import("ui.zig");
const render = @import("../render/packet.zig");
const platform = @import("../platform/api.zig");
const recording = @import("recording.zig");
const hot = @import("../hot_reload/abi.zig");
const builtin_systems = @import("../systems/plugin.zig");
const musicxml = @import("import/musicxml.zig");
const musicxml_export = @import("export/musicxml.zig");
const mxl_export = @import("export/mxl.zig");
const midi_export = @import("export/midi.zig");
const midi = @import("import/midi.zig");
const mxl = @import("import/mxl.zig");
const practice_assessment = @import("practice.zig");
const command = @import("command.zig");
const annotation = @import("annotation.zig");
const accessibility = @import("accessibility.zig");
const native_format = @import("persistence/native.zig");
const playback = @import("playback/timeline.zig");

const bundled_bach_minuet = @embedFile("../assets/scores/bach-minuet-in-g.mxl");
const bundled_beethoven_fur_elise = @embedFile("../assets/scores/beethoven-fur-elise.musicxml");

pub const c = @cImport({
    @cDefine("FLECS_CUSTOM_BUILD", "1");
    @cDefine("FLECS_SYSTEM", "1");
    @cDefine("FLECS_PIPELINE", "1");
    @cDefine("FLECS_TIMER", "1");
    @cInclude("flecs.h");
});

const ComponentIds = struct {
    note: c.ecs_entity_t,
    transport: c.ecs_entity_t,
    ui_state: c.ecs_entity_t,
    practice: c.ecs_entity_t,
    document_meta: c.ecs_entity_t,
    playback_bounds: c.ecs_entity_t,
};

const ScoreHitContext = struct {
    stage: ui.Rect,
    page: ui.ScorePage,
    x: f32,
    y: f32,
};

const RuntimeSystem = struct {
    stable_id: u64,
    callback: hot.SystemCallback,
    terms: [hot.max_query_terms]hot.QueryTerm,
    term_count: u32,
    component_sizes: [hot.max_query_terms]usize,
    entity: c.ecs_entity_t,
};

pub const App = struct {
    world: *c.ecs_world_t,
    ids: ComponentIds,
    session: c.ecs_entity_t,
    note_entities: [musicxml.max_import_notes]c.ecs_entity_t = undefined,
    note_count: usize = 0,
    lyrics: [musicxml.max_import_lyrics]model.Lyric = undefined,
    lyric_count: usize = 0,
    harmonies: [musicxml.max_import_harmonies]model.Harmony = undefined,
    harmony_count: usize = 0,
    pedals: [musicxml.max_import_pedals]model.PedalEvent = undefined,
    pedal_count: usize = 0,
    measures: [musicxml.max_import_measures]model.Measure = undefined,
    measure_count: usize = 0,
    packet: render.Packet = .{},
    take: recording.Take = .{},
    time_seconds: f32 = 0,
    next_note_id: u64 = 1000,
    journal: command.Journal = .{},
    annotations: annotation.Store = .{},
    accessibility: accessibility.Snapshot = .{},
    host_request: platform.HostRequest = .none,
    timeline: playback.Timeline = .{},
    playback_events: [256]playback.HostEvent = undefined,
    playback_event_count: usize = 0,
    previous_cursor: f32 = 0,
    was_playing: bool = false,
    take_replaying: bool = false,
    take_replay_elapsed_ns: u64 = 0,
    take_replay_index: usize = 0,
    systems: [32]?*RuntimeSystem = [_]?*RuntimeSystem{null} ** 32,
    system_count: usize = 0,
    draw_callback: ?hot.DrawCallback = null,
    dev_command_callback: ?hot.DevCommandCallback = null,
    plugin_generation: u32 = 0,
    notice_deadline_seconds: f32 = 0,
    last_observed_pitch: u8 = 255,
    last_observation_seconds: f32 = -10,
    audition_pitch: u8 = 255,
    page_scroll_accumulator: f32 = 0,
    last_page_scroll_seconds: f32 = -10,

    pub fn create(allocator: std.mem.Allocator, width: f32, height: f32, pixel_ratio: f32) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        const world = c.ecs_init() orelse return error.FlecsInitFailed;
        errdefer _ = c.ecs_fini(world);

        const ids = ComponentIds{
            .note = registerComponent(world, model.Note, "Score.Note"),
            .transport = registerComponent(world, model.Transport, "Score.Transport"),
            .ui_state = registerComponent(world, model.UiState, "Score.UiState"),
            .practice = registerComponent(world, model.PracticeState, "Score.PracticeState"),
            .document_meta = registerComponent(world, model.DocumentMeta, "Score.DocumentMeta"),
            .playback_bounds = registerComponent(world, model.PlaybackBounds, "Score.PlaybackBounds"),
        };
        if (ids.note == 0 or ids.transport == 0 or ids.ui_state == 0 or ids.practice == 0 or ids.document_meta == 0 or ids.playback_bounds == 0) return error.ComponentRegistrationFailed;

        const session = createEntity(world, "Score.Session");
        var transport: model.Transport = .{};
        var ui_state: model.UiState = .{ .viewport_width = width, .viewport_height = height, .pixel_ratio = pixel_ratio };
        var practice: model.PracticeState = .{};
        var playback_bounds: model.PlaybackBounds = .{};
        var meta: model.DocumentMeta = .{};
        meta.setTitle("Piano practice study");
        meta.setCreator("Score");
        c.ecs_set_id(world, session, ids.transport, @sizeOf(model.Transport), &transport);
        c.ecs_set_id(world, session, ids.ui_state, @sizeOf(model.UiState), &ui_state);
        c.ecs_set_id(world, session, ids.practice, @sizeOf(model.PracticeState), &practice);
        c.ecs_set_id(world, session, ids.document_meta, @sizeOf(model.DocumentMeta), &meta);
        c.ecs_set_id(world, session, ids.playback_bounds, @sizeOf(model.PlaybackBounds), &playback_bounds);

        self.* = App{ .world = world, .ids = ids, .session = session };
        try self.applySystemPlugin(builtin_systems.descriptor());
        self.seedOriginalStudy();
        self.rebuildTimeline();
        self.buildFrame();
        return self;
    }

    pub fn deinit(self: *App) void {
        for (self.systems[0..self.system_count]) |runtime_optional| {
            if (runtime_optional) |runtime| {
                c.ecs_delete(self.world, runtime.entity);
                std.heap.c_allocator.destroy(runtime);
            }
        }
        _ = c.ecs_fini(self.world);
        self.* = undefined;
    }

    pub fn destroy(self: *App, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    pub fn tick(self: *App, delta_seconds: f32) void {
        const clamped = std.math.clamp(delta_seconds, 0, 0.1);
        self.time_seconds += clamped;
        const before = self.transportSnapshot();
        _ = c.ecs_progress(self.world, clamped);
        const after = self.transportSnapshot();
        self.extractPlayback(before, after);
        self.advanceTakeReplay(clamped);
        if (after.playing != 0 and after.cursor_beat >= 0) {
            if (self.getMut(model.UiState, self.session, self.ids.ui_state)) |state| {
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                var window = if (state.score_view_mode == .continuous)
                    self.scoreContinuousForState(state, meta, state.view_start_beat)
                else
                    self.scorePageForState(state, meta, state.view_start_beat);
                var visible_end = window.endBeat();
                const layout = ui.Layout.calculateForState(state);
                const visible_pages: usize = switch (state.score_view_mode) {
                    .spread => ui.spreadVisiblePageCount(layout.stage, state.zoom),
                    .paged, .continuous => 1,
                };
                var visible_page = window;
                for (1..visible_pages) |_| {
                    const next = self.scorePageForState(state, meta, visible_page.endBeat());
                    if (next.page_index == visible_page.page_index) break;
                    visible_page = next;
                    visible_end = visible_page.endBeat();
                }
                if (after.cursor_beat < window.startBeat() or after.cursor_beat >= visible_end) {
                    window = if (state.score_view_mode == .continuous)
                        self.scoreContinuousForState(state, meta, after.cursor_beat)
                    else
                        self.scorePageForState(state, meta, after.cursor_beat);
                    if (state.score_view_mode == .spread) {
                        const spread_pages: u32 = @intCast(ui.spreadVisiblePageCount(layout.stage, state.zoom));
                        var retreat = window.page_index % spread_pages;
                        while (retreat > 0 and window.startBeat() > 0.0001) : (retreat -= 1) {
                            window = self.scorePageForState(state, meta, window.startBeat() - 0.001);
                        }
                    }
                    state.view_start_beat = window.startBeat();
                    c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
                }
            }
        }
        if (self.notice_deadline_seconds != 0 and self.time_seconds >= self.notice_deadline_seconds) {
            if (self.getMut(model.UiState, self.session, self.ids.ui_state)) |state| state.notice = 0;
            self.notice_deadline_seconds = 0;
        }
        self.buildFrame();
    }

    pub fn resize(self: *App, width: f32, height: f32, pixel_ratio: f32) void {
        const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
        state.viewport_width = @max(width, 320);
        state.viewport_height = @max(height, 320);
        state.pixel_ratio = @max(pixel_ratio, 1);
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        self.buildFrame();
    }

    pub fn pointer(self: *App, event: platform.PointerEvent) void {
        const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
        state.pointer_x = event.x;
        state.pointer_y = event.y;
        if (event.kind == .scroll) {
            const layout = ui.Layout.calculateForState(state);
            if (layout.stage.contains(event.x, event.y) and self.time_seconds - self.last_page_scroll_seconds >= 0.24) {
                const dominant_delta = if (@abs(event.scroll_y) >= @abs(event.scroll_x)) event.scroll_y else -event.scroll_x;
                if (self.page_scroll_accumulator != 0 and std.math.sign(self.page_scroll_accumulator) != std.math.sign(dominant_delta)) self.page_scroll_accumulator = 0;
                self.page_scroll_accumulator += dominant_delta;
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                if (self.page_scroll_accumulator <= -0.65) {
                    self.nextScorePage(state, meta);
                    self.page_scroll_accumulator = 0;
                    self.last_page_scroll_seconds = self.time_seconds;
                } else if (self.page_scroll_accumulator >= 0.65) {
                    self.previousScorePage(state, meta);
                    self.page_scroll_accumulator = 0;
                    self.last_page_scroll_seconds = self.time_seconds;
                }
            }
        } else if (event.kind == .down) {
            const layout = ui.Layout.calculateForState(state);
            const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
            if (state.library_open != 0) {
                if (layout.library_items[0].contains(event.x, event.y)) {
                    state.library_open = 0;
                    self.loadBundledScore(0) catch self.setHostStatus(3);
                } else if (layout.library_items[1].contains(event.x, event.y)) {
                    state.library_open = 0;
                    self.loadBundledScore(1) catch self.setHostStatus(3);
                } else if (layout.library_close.contains(event.x, event.y)) {
                    state.library_open = 0;
                }
                c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
                self.buildFrame();
                return;
            } else if (layout.library_trigger.contains(event.x, event.y)) {
                state.library_open = 1;
            } else if (layout.play.contains(event.x, event.y)) {
                self.toggleTransport(transport);
            } else if (layout.record.contains(event.x, event.y)) {
                transport.recording = if (transport.recording == 0) 1 else 0;
                if (transport.recording != 0) {
                    self.take.reset(@intFromFloat(self.time_seconds * std.time.ns_per_s));
                    const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
                    self.take.tempo_bpm = model.effectiveTempoAt(bounds, transport, @max(0, transport.cursor_beat));
                    (self.getMut(model.PracticeState, self.session, self.ids.practice) orelse return).* = .{};
                    self.last_observed_pitch = 255;
                    self.last_observation_seconds = -10;
                    self.host_request = .start_recording;
                } else {
                    self.take.stopped_ns = @intFromFloat(self.time_seconds * std.time.ns_per_s);
                    self.host_request = .stop_recording;
                }
            } else if (layout.import_score.contains(event.x, event.y)) {
                state.notice = 1;
                self.notice_deadline_seconds = self.time_seconds + 4;
                self.host_request = .open_score;
            } else if (layout.loop_toggle.contains(event.x, event.y)) {
                if (transport.loop_enabled == 0) {
                    const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                    const position = model.barBeatAt(self.measures[0..self.measure_count], transport.cursor_beat, meta);
                    transport.loop_start = position.measure_start;
                    transport.loop_end = @min(self.scoreEndBeat(), position.measure_start + position.measure_duration);
                    if (transport.loop_end <= transport.loop_start) transport.loop_end = transport.loop_start + position.measure_duration;
                    transport.loop_enabled = 1;
                } else {
                    transport.loop_enabled = 0;
                }
            } else if (layout.metronome_toggle.contains(event.x, event.y)) {
                transport.metronome_enabled = if (transport.metronome_enabled == 0) 1 else 0;
            } else if (layout.keyboard_toggle.contains(event.x, event.y)) {
                state.keyboard_visible = if (state.keyboard_visible == 0) 1 else 0;
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                state.view_start_beat = self.scorePageForState(state, meta, state.view_start_beat).startBeat();
            } else if (layout.vocal_guide_toggle.contains(event.x, event.y)) {
                state.vocal_guide_visible = if (state.vocal_guide_visible == 0) 1 else 0;
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                state.view_start_beat = self.scorePageForState(state, meta, state.view_start_beat).startBeat();
            } else if (layout.pedal_guide_toggle.contains(event.x, event.y)) {
                state.pedal_guide_visible = if (state.pedal_guide_visible == 0) 1 else 0;
            } else if (layout.tempo_value.contains(event.x, event.y)) {
                state.tempo_editing = 1;
                state.tempo_edit_value = @intFromFloat(@round(transport.tempo_bpm));
            } else if (layout.tempo_minus.contains(event.x, event.y)) {
                state.tempo_editing = 0;
                transport.tempo_bpm = @max(30, transport.tempo_bpm - 1);
            } else if (layout.tempo_plus.contains(event.x, event.y)) {
                state.tempo_editing = 0;
                transport.tempo_bpm = @min(240, transport.tempo_bpm + 1);
            } else if (layout.view_mode_toggle.contains(event.x, event.y)) {
                state.score_view_mode = switch (state.score_view_mode) {
                    .paged => .continuous,
                    .continuous => .spread,
                    .spread => .paged,
                };
                state.view_start_beat = self.scorePageForState(state, self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return, state.view_start_beat).startBeat();
            } else if (layout.zoom_minus.contains(event.x, event.y)) {
                state.zoom = @max(ui.min_score_zoom, state.zoom - 0.1);
            } else if (layout.zoom_plus.contains(event.x, event.y)) {
                state.zoom = @min(ui.max_score_zoom, state.zoom + 0.1);
            } else if (layout.focus_toggle.contains(event.x, event.y)) {
                state.focus_score = if (state.focus_score == 0) 1 else 0;
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                state.view_start_beat = self.scorePageForState(state, meta, state.view_start_beat).startBeat();
            } else if (layout.input_quick.contains(event.x, event.y)) {
                self.host_request = .choose_microphone;
            } else if (layout.export_score.contains(event.x, event.y)) {
                self.host_request = .export_score;
            } else if (layout.replay_take.contains(event.x, event.y)) {
                self.beginTakeReplay();
                self.host_request = .replay_take;
            } else if (layout.export_take.contains(event.x, event.y)) {
                self.host_request = .export_take;
            } else if (layout.page_previous.contains(event.x, event.y)) {
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                self.previousScorePage(state, meta);
            } else if (layout.page_next.contains(event.x, event.y)) {
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                self.nextScorePage(state, meta);
            } else if (layout.input_setup.contains(event.x, event.y)) {
                self.host_request = .choose_microphone;
            } else if (ui.pianoPitchAt(layout.keyboard_panel, event.x, event.y)) |pitch| {
                if (self.audition_pitch != 255) self.pushPlayback(.{ .pitch = self.audition_pitch, .velocity = 0, .channel = 0, .on = 0 });
                self.audition_pitch = pitch;
                self.pushPlayback(.{ .pitch = pitch, .velocity = 92, .channel = 0, .on = 1 });
            } else {
                if (layout.stage.contains(event.x, event.y)) switch (state.tool) {
                    .edit => self.insertNoteAt(event.x, event.y, layout.stage),
                    .read, .practice => self.selectNearestNote(event.x, event.y, layout.stage),
                    .annotate => {
                        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                        const hit = self.scoreHitContext(state, meta, layout.stage, event.x, event.y);
                        self.annotations.beginScore(self.annotationPointForHit(state, hit, event.pressure), hit.page.page_index);
                    },
                };
                for (layout.tool_buttons, 0..) |button, index| {
                    if (button.contains(event.x, event.y)) state.tool = @enumFromInt(index);
                }
            }
            c.ecs_modified_id(self.world, self.session, self.ids.transport);
        } else if (event.kind == .move and state.tool == .annotate and self.annotations.active != null) {
            const layout = ui.Layout.calculateForState(state);
            if (layout.stage.contains(event.x, event.y)) {
                const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
                const hit = self.scoreHitContext(state, meta, layout.stage, event.x, event.y);
                const active = self.annotations.active orelse return;
                if (annotation.pageIndex(self.annotations.strokes[active]) == hit.page.page_index) {
                    self.annotations.append(self.annotationPointForHit(state, hit, event.pressure));
                }
            }
        } else if (event.kind == .up or event.kind == .cancel) {
            if (self.audition_pitch != 255) {
                self.pushPlayback(.{ .pitch = self.audition_pitch, .velocity = 0, .channel = 0, .on = 0 });
                self.audition_pitch = 255;
            }
            if (self.annotations.active != null) self.annotations.end();
        }
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        self.buildFrame();
    }

    pub fn key(self: *App, event: platform.KeyEvent) void {
        if (event.pressed == 0 or event.repeat != 0) return;
        if (self.getMut(model.UiState, self.session, self.ids.ui_state)) |state| {
            if (state.tempo_editing != 0) {
                const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
                if (event.key >= 48 and event.key <= 57) {
                    const digit = event.key - 48;
                    state.tempo_edit_value = if (state.tempo_editing == 1) digit else @min(999, state.tempo_edit_value * 10 + digit);
                    state.tempo_editing = 2;
                } else if (event.key == 8 or event.key == 259) {
                    state.tempo_edit_value /= 10;
                    state.tempo_editing = 2;
                } else if (event.key == 13 or event.key == 257) {
                    if (state.tempo_edit_value >= 30 and state.tempo_edit_value <= 240) {
                        transport.tempo_bpm = @floatFromInt(state.tempo_edit_value);
                        state.tempo_editing = 0;
                        c.ecs_modified_id(self.world, self.session, self.ids.transport);
                    }
                } else if (event.key == 27 or event.key == 256) {
                    state.tempo_editing = 0;
                }
                c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
                self.buildFrame();
                return;
            }
        }
        if (event.key == 32) {
            const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
            self.toggleTransport(transport);
            c.ecs_modified_id(self.world, self.session, self.ids.transport);
        }
        if (event.key == 45 or event.key == 189) {
            const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
            transport.tempo_bpm = @max(30, transport.tempo_bpm - 1);
            c.ecs_modified_id(self.world, self.session, self.ids.transport);
        }
        if (event.key == 43 or event.key == 61 or event.key == 187) {
            const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
            transport.tempo_bpm = @min(240, transport.tempo_bpm + 1);
            c.ecs_modified_id(self.world, self.session, self.ids.transport);
        }
        if (event.key == 90 and event.modifiers != 0) self.undo();
        if (event.key == 89 and event.modifiers != 0) self.redo();
        if (event.key == 75 or event.key == 107) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.keyboard_visible = if (state.keyboard_visible == 0) 1 else 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 76 or event.key == 108) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.library_open = if (state.library_open == 0) 1 else 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 86 or event.key == 118) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.vocal_guide_visible = if (state.vocal_guide_visible == 0) 1 else 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 71 or event.key == 103) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.pedal_guide_visible = if (state.pedal_guide_visible == 0) 1 else 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 70 or event.key == 102) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.focus_score = if (state.focus_score == 0) 1 else 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 77 or event.key == 109) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.score_view_mode = switch (state.score_view_mode) {
                .paged => .continuous,
                .continuous => .spread,
                .spread => .paged,
            };
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 91) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.zoom = @max(ui.min_score_zoom, state.zoom - 0.1);
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 93) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.zoom = @min(ui.max_score_zoom, state.zoom + 0.1);
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        if (event.key == 27 or event.key == 256) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.library_open = 0;
            c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        }
        const state_for_navigation = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const page_forward = event.key == 34 or event.key == 267 or ((event.key == 39 or event.key == 262) and state_for_navigation.tool != .edit);
        const page_backward = event.key == 33 or event.key == 266 or ((event.key == 37 or event.key == 263) and state_for_navigation.tool != .edit);
        if (page_forward) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
            self.nextScorePage(state, meta);
        }
        if (page_backward) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
            self.previousScorePage(state, meta);
        }
        if (state_for_navigation.tool == .edit and event.key >= '0' and event.key <= '5') self.setSelectedFingering(@intCast(event.key - '0'));
        if (event.key == 8 or event.key == 46 or event.key == 261) self.deleteSelectedNote();
        if (event.key == 38 or event.key == 265) self.moveSelectedNote(1, 0);
        if (event.key == 40 or event.key == 264) self.moveSelectedNote(-1, 0);
        if ((event.key == 37 or event.key == 263) and state_for_navigation.tool == .edit) self.moveSelectedNote(0, -0.25);
        if ((event.key == 39 or event.key == 262) and state_for_navigation.tool == .edit) self.moveSelectedNote(0, 0.25);
        self.buildFrame();
    }

    pub fn drawItems(self: *const App) []const render.DrawItem {
        return self.packet.slice();
    }

    pub fn buildPrintablePage(self: *const App, packet: *render.Packet, width: f32, height: f32, requested_beat: f32) !ui.ScorePage {
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return error.MissingUiState;
        const transport = self.getConst(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        var notes: [musicxml.max_import_notes]model.Note = undefined;
        var len: usize = 0;
        for (self.note_entities[0..self.note_count]) |entity| {
            if (self.getConst(model.Note, entity, self.ids.note)) |note| {
                notes[len] = note.*;
                len += 1;
            }
        }
        return ui.drawPrintablePage(
            packet,
            width,
            height,
            requested_beat,
            state,
            transport,
            meta,
            notes[0..len],
            self.lyrics[0..self.lyric_count],
            self.harmonies[0..self.harmony_count],
            self.pedals[0..self.pedal_count],
            self.measures[0..self.measure_count],
            &self.annotations,
        );
    }

    pub fn printableEndBeat(self: *const App) f32 {
        return self.scoreEndBeat();
    }

    pub fn accessibilityItems(self: *const App) []const accessibility.Item {
        return self.accessibility.items[0..self.accessibility.len];
    }

    pub fn accessibilityActivate(self: *App, id: u32) void {
        if (id == accessibility.Id.document) return;
        for (self.accessibilityItems()) |item| {
            if (item.id != id) continue;
            const x = item.rect[0] + item.rect[2] * 0.5;
            const y = item.rect[1] + item.rect[3] * 0.5;
            self.pointer(.{ .kind = .down, .pointer_type = .mouse, .id = id, .buttons = 1, .x = x, .y = y, .pressure = 1, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
            self.pointer(.{ .kind = .up, .pointer_type = .mouse, .id = id, .buttons = 0, .x = x, .y = y, .pressure = 0, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
            return;
        }
    }

    pub fn takeHostRequest(self: *App) platform.HostRequest {
        const result = self.host_request;
        self.host_request = .none;
        return result;
    }

    pub fn setHostStatus(self: *App, status: u32) void {
        const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
        state.notice = status;
        self.notice_deadline_seconds = self.time_seconds + 4;
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        self.buildFrame();
    }

    pub fn drainPlaybackEvents(self: *App, output: []playback.HostEvent) usize {
        const count = @min(output.len, self.playback_event_count);
        @memcpy(output[0..count], self.playback_events[0..count]);
        if (count < self.playback_event_count) std.mem.copyForwards(playback.HostEvent, self.playback_events[0 .. self.playback_event_count - count], self.playback_events[count..self.playback_event_count]);
        self.playback_event_count -= count;
        return count;
    }

    pub fn importMusicXml(self: *App, source: []const u8) !void {
        const report = try musicxml.parse(source);
        try self.replaceNotes(report.notes[0..report.note_count]);
        self.resetDocumentExtras();
        @memcpy(self.lyrics[0..report.lyric_count], report.lyrics[0..report.lyric_count]);
        self.lyric_count = report.lyric_count;
        @memcpy(self.harmonies[0..report.harmony_count], report.harmonies[0..report.harmony_count]);
        self.harmony_count = report.harmony_count;
        @memcpy(self.pedals[0..report.pedal_count], report.pedals[0..report.pedal_count]);
        self.pedal_count = report.pedal_count;
        @memcpy(self.measures[0..report.measure_count], report.measures[0..report.measure_count]);
        self.measure_count = report.measure_count;
        self.rebuildTimeline();
        const meta = self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        meta.* = .{};
        meta.setTitle(if (report.title_len != 0) report.titleSlice() else "IMPORTED MUSICXML SCORE");
        meta.setCreator(report.creatorSlice());
        meta.source_kind = 1;
        meta.import_warnings = report.skipped_notes + report.approximations;
        meta.beats_per_measure = report.beats_per_measure;
        meta.beat_unit = report.beat_unit;
        meta.key_fifths = report.key_fifths;
        meta.tempo_beat_unit = report.tempo_beat_unit;
        const transport_state = self.getMut(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        transport_state.tempo_bpm = report.tempo_bpm;
        transport_state.cursor_beat = 0;
        transport_state.playing = 0;
        transport_state.recording = 0;
        transport_state.loop_enabled = 0;
        transport_state.loop_start = 0;
        transport_state.loop_end = self.scoreEndBeat();
        self.configureTempoMap(report.tempos[0..report.tempo_count], report.tempos[0].bpm, report.tempo_beat_unit);
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        self.buildFrame();
    }

    pub fn importMidi(self: *App, source: []const u8) !void {
        const report = try midi.parse(source);
        try self.replaceNotes(report.notes[0..report.note_count]);
        self.resetDocumentExtras();
        @memcpy(self.pedals[0..report.pedal_count], report.pedals[0..report.pedal_count]);
        self.pedal_count = report.pedal_count;
        self.rebuildTimeline();
        const meta = self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        meta.* = .{};
        meta.setTitle(if (report.title_len != 0) report.titleSlice() else "IMPORTED MIDI PERFORMANCE");
        meta.setCreator("QUANTIZATION REVIEW");
        meta.source_kind = 2;
        meta.beats_per_measure = report.beats_per_measure;
        meta.beat_unit = report.beat_unit;
        meta.key_fifths = report.key_fifths;
        meta.tempo_beat_unit = 4;
        const transport_state = self.getMut(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        transport_state.tempo_bpm = report.tempo_bpm;
        transport_state.cursor_beat = 0;
        transport_state.playing = 0;
        transport_state.recording = 0;
        transport_state.loop_enabled = 0;
        transport_state.loop_start = 0;
        transport_state.loop_end = self.scoreEndBeat();
        self.configureTempoMap(report.tempos[0..report.tempo_count], report.tempo_bpm, 4);
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        self.buildFrame();
    }

    pub fn loadBundledScore(self: *App, index: u32) !void {
        switch (index) {
            0 => try self.importMxl(bundled_bach_minuet),
            1 => try self.importMusicXml(bundled_beethoven_fur_elise),
            else => return error.UnknownBundledScore,
        }
        if (self.getMut(model.UiState, self.session, self.ids.ui_state)) |state| state.library_open = 0;
        self.setHostStatus(2);
    }

    pub fn importMxl(self: *App, source: []const u8) !void {
        const document = try mxl.extract(std.heap.c_allocator, source);
        defer std.heap.c_allocator.free(document);
        try self.importMusicXml(document);
    }

    fn resetDocumentExtras(self: *App) void {
        self.annotations = .{};
        self.take = .{};
        self.lyric_count = 0;
        self.harmony_count = 0;
        self.pedal_count = 0;
        self.measure_count = 0;
        self.configureTempoMap(&.{.{ .start_beat = 0, .bpm = 72 }}, 72, 4);
        (self.getMut(model.PracticeState, self.session, self.ids.practice) orelse return).* = .{};
        if (self.getMut(model.UiState, self.session, self.ids.ui_state)) |state| state.view_start_beat = 0;
    }

    pub fn midiInput(self: *App, time_ns: u64, status: u8, data1: u8, data2: u8) void {
        const transport_state = self.getConst(model.Transport, self.session, self.ids.transport) orelse return;
        if (transport_state.recording != 0) {
            self.take.pushMidi(.{
                .time_ns = time_ns,
                .sequence = @intCast(self.take.midi_len),
                .kind = status & 0xf0,
                .channel = status & 0x0f,
                .data1 = data1,
                .data2 = data2,
            });
        }
        const ui_state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
        ui_state.input_source = .midi;
        const message = status & 0xf0;
        if (message == 0x90 and data2 != 0) self.assessMidiNote(data1);
        if (message == 0xb0) switch (data1) {
            64 => {
                self.assessPedal(model.pedal_sustain, @intCast(ui_state.sustain_pedal), data2);
                ui_state.sustain_pedal = data2;
            },
            66 => {
                self.assessPedal(model.pedal_sostenuto, @intCast(ui_state.sostenuto_pedal), data2);
                ui_state.sostenuto_pedal = data2;
            },
            67 => {
                self.assessPedal(model.pedal_soft, @intCast(ui_state.soft_pedal), data2);
                ui_state.soft_pedal = data2;
            },
            else => {},
        };
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        self.buildFrame();
    }

    pub fn microphonePitch(self: *App, pitch: u8, confidence: f32) void {
        if (confidence < 0.72) return;
        if (pitch == self.last_observed_pitch and self.time_seconds - self.last_observation_seconds < 0.18) return;
        self.last_observed_pitch = pitch;
        self.last_observation_seconds = self.time_seconds;
        const ui_state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
        ui_state.input_source = .microphone;
        self.assessObservedPitch(pitch, confidence);
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
    }

    pub fn undo(self: *App) void {
        const edit = self.journal.undo() orelse {
            _ = self.annotations.undoLast();
            return;
        };
        switch (edit.kind) {
            .insert_note => self.deleteNoteByStableId(edit.after.stable_id, false),
            .delete_note => self.insertNote(edit.before, false),
            .replace_note => self.replaceNote(edit.after.stable_id, edit.before, false),
        }
        self.buildFrame();
    }

    pub fn redo(self: *App) void {
        const edit = self.journal.redo() orelse return;
        switch (edit.kind) {
            .insert_note => self.insertNote(edit.after, false),
            .delete_note => self.deleteNoteByStableId(edit.before.stable_id, false),
            .replace_note => self.replaceNote(edit.before.stable_id, edit.after, false),
        }
        self.buildFrame();
    }

    pub fn serialize(self: *const App, output: []u8) !usize {
        const snapshot = try std.heap.c_allocator.create(native_format.Snapshot);
        defer std.heap.c_allocator.destroy(snapshot);
        snapshot.* = .{};
        snapshot.meta = (self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta).*;
        snapshot.transport = self.transportSnapshot();
        snapshot.note_count = self.note_count;
        for (self.note_entities[0..self.note_count], 0..) |entity, index| snapshot.notes[index] = (self.getConst(model.Note, entity, self.ids.note) orelse return error.MissingNote).*;
        snapshot.lyric_count = self.lyric_count;
        @memcpy(snapshot.lyrics[0..self.lyric_count], self.lyrics[0..self.lyric_count]);
        snapshot.harmony_count = self.harmony_count;
        @memcpy(snapshot.harmonies[0..self.harmony_count], self.harmonies[0..self.harmony_count]);
        snapshot.pedal_count = self.pedal_count;
        @memcpy(snapshot.pedals[0..self.pedal_count], self.pedals[0..self.pedal_count]);
        snapshot.measure_count = self.measure_count;
        @memcpy(snapshot.measures[0..self.measure_count], self.measures[0..self.measure_count]);
        if (self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds)) |bounds| {
            snapshot.tempo_base_bpm = bounds.tempo_base_bpm;
            snapshot.tempo_count = @min(@as(usize, bounds.tempo_count), bounds.tempos.len);
            @memcpy(snapshot.tempos[0..snapshot.tempo_count], bounds.tempos[0..snapshot.tempo_count]);
        }
        snapshot.annotations = self.annotations;
        snapshot.take = self.take;
        return native_format.encode(snapshot, output);
    }

    /// Exports the editable notation as standards-based MusicXML for exchange
    /// with notation tools. Portable `.score` serialization remains separate
    /// because it additionally preserves practice takes and anchored ink.
    pub fn exportMusicXml(self: *const App, output: []u8) !usize {
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        const transport = self.getConst(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        var notes: [musicxml.max_import_notes]model.Note = undefined;
        var count: usize = 0;
        for (self.note_entities[0..self.note_count]) |entity| {
            notes[count] = (self.getConst(model.Note, entity, self.ids.note) orelse return error.MissingNote).*;
            count += 1;
        }
        const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
        return musicxml_export.write(output, meta, transport, notes[0..count], self.lyrics[0..self.lyric_count], self.harmonies[0..self.harmony_count], self.pedals[0..self.pedal_count], self.measures[0..self.measure_count], bounds);
    }

    /// Exports the same editable notation inside the standard compressed
    /// MusicXML (`.mxl`) container used by MuseScore and other notation tools.
    pub fn exportMxl(self: *const App, output: []u8) !usize {
        const xml = try std.heap.c_allocator.alloc(u8, output.len);
        defer std.heap.c_allocator.free(xml);
        const xml_len = try self.exportMusicXml(xml);
        return mxl_export.write(output, xml[0..xml_len]);
    }

    /// Exports a deterministic Type-1 Standard MIDI File with conductor,
    /// piano, optional vocal-guide, and three-pedal automation tracks.
    pub fn exportMidi(self: *const App, output: []u8) !usize {
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        const transport = self.getConst(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        var notes: [musicxml.max_import_notes]model.Note = undefined;
        var count: usize = 0;
        for (self.note_entities[0..self.note_count]) |entity| {
            notes[count] = (self.getConst(model.Note, entity, self.ids.note) orelse return error.MissingNote).*;
            count += 1;
        }
        const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
        return midi_export.write(output, meta, transport.tempo_bpm, bounds, notes[0..count], self.pedals[0..self.pedal_count]);
    }

    pub fn exportTakeMidi(self: *const App, output: []u8) !usize {
        if (self.take.midi_len == 0) return error.EmptyMidiTake;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        return midi_export.writeTake(output, meta, &self.take);
    }

    pub fn deserialize(self: *App, source: []const u8) !void {
        const snapshot = try std.heap.c_allocator.create(native_format.Snapshot);
        defer std.heap.c_allocator.destroy(snapshot);
        try native_format.decode(source, snapshot);
        try self.replaceNotes(snapshot.notes[0..snapshot.note_count]);
        self.lyric_count = snapshot.lyric_count;
        @memcpy(self.lyrics[0..self.lyric_count], snapshot.lyrics[0..snapshot.lyric_count]);
        self.harmony_count = snapshot.harmony_count;
        @memcpy(self.harmonies[0..self.harmony_count], snapshot.harmonies[0..snapshot.harmony_count]);
        self.pedal_count = snapshot.pedal_count;
        @memcpy(self.pedals[0..self.pedal_count], snapshot.pedals[0..snapshot.pedal_count]);
        self.measure_count = snapshot.measure_count;
        @memcpy(self.measures[0..self.measure_count], snapshot.measures[0..snapshot.measure_count]);
        self.rebuildTimeline();
        (self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta).* = snapshot.meta;
        self.configureTempoMap(snapshot.tempos[0..snapshot.tempo_count], snapshot.tempo_base_bpm, snapshot.meta.tempo_beat_unit);
        (self.getMut(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport).* = snapshot.transport;
        self.annotations = snapshot.annotations;
        self.take = snapshot.take;
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        self.buildFrame();
    }

    pub fn transportSnapshot(self: *const App) model.Transport {
        return (self.getConst(model.Transport, self.session, self.ids.transport) orelse unreachable).*;
    }

    /// Executes a local development command against the live Flecs session.
    /// The native debug socket is omitted from release builds; keeping parsing
    /// here makes the behavior directly unit-testable without a window.
    pub fn runDevCommand(self: *App, source: []const u8, response: []u8) usize {
        const input = std.mem.trim(u8, source, " \t\r\n");
        if (input.len == 0) return devResponse(response, "error empty command", .{});

        const transport_state = self.getMut(model.Transport, self.session, self.ids.transport) orelse return devResponse(response, "error missing transport", .{});
        const ui_state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return devResponse(response, "error missing ui", .{});
        const practice_state = self.getMut(model.PracticeState, self.session, self.ids.practice) orelse return devResponse(response, "error missing practice", .{});
        const meta = self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return devResponse(response, "error missing metadata", .{});
        const bounds = self.getMut(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return devResponse(response, "error missing playback bounds", .{});

        var result_len: usize = 0;
        if (std.mem.eql(u8, input, "help")) {
            result_len = devResponse(response, "ok commands: state | fingering state|chord|set NOTE_ID 1..5|clear | ink dot BEAT HEIGHT|undo | load FILE | export FILE | export-take FILE | capture FILE.bmp | window WIDTH HEIGHT | record start|stop | midi STATUS DATA1 DATA2 | sampler state | sampler detail studio|dry|RELEASE HAMMER PEDAL_NOISE RESONANCE | reload | shader reload|state | play | pause | toggle | seek BEAT | page next|previous | tempo BPM | view paged|continuous|spread | zoom 0.45..1.05 | focus on|off|toggle | keys on|off|toggle | voice on|off|toggle | pedal on|off|toggle | metronome on|off|toggle | loop on|off|toggle | tool read|edit|ink|practice | plugin COMMAND", .{});
        } else if (std.mem.eql(u8, input, "state")) {
            const position = model.barBeatAt(self.measures[0..self.measure_count], transport_state.cursor_beat, meta);
            result_len = devResponse(response, "ok generation={d} playing={d} cursor={d:.3} tempo={d:.2} pulse_unit={d} quarter={d:.2} end={d:.3} loop={d} loop_start={d:.3} loop_end={d:.3} page={d:.3} view={s} zoom={d:.2} focus={d} bar={d} beat={d} measures={d} keys={d} voice={d} pedalguide={d} notes={d} harmonies={d} pedals={d} ink={d} take={d} title={s}", .{
                self.plugin_generation,
                transport_state.playing,
                transport_state.cursor_beat,
                transport_state.tempo_bpm,
                bounds.tempo_beat_unit,
                model.effectiveTempoAt(bounds, transport_state, @max(0, transport_state.cursor_beat)),
                bounds.end_beat,
                transport_state.loop_enabled,
                transport_state.loop_start,
                transport_state.loop_end,
                ui_state.view_start_beat,
                @tagName(ui_state.score_view_mode),
                ui_state.zoom,
                ui_state.focus_score,
                position.bar,
                position.beat,
                self.measure_count,
                ui_state.keyboard_visible,
                ui_state.vocal_guide_visible,
                ui_state.pedal_guide_visible,
                self.note_count,
                self.harmony_count,
                self.pedal_count,
                self.annotations.stroke_count,
                self.take.midi_len,
                meta.titleSlice(),
            });
        } else if (std.mem.eql(u8, input, "fingering state") or std.mem.eql(u8, input, "fingering chord")) {
            var notes: [musicxml.max_import_notes]model.Note = undefined;
            for (self.note_entities[0..self.note_count], 0..) |entity, index| notes[index] = (self.getConst(model.Note, entity, self.ids.note) orelse return devResponse(response, "error missing note", .{})).*;
            if (std.mem.eql(u8, input, "fingering chord")) {
                result_len = chordFingeringResponse(response, ui.chordFingeringSnapshot(notes[0..self.note_count], @max(0, transport_state.cursor_beat)));
            } else {
                const guide = ui.fingeringSnapshot(notes[0..self.note_count], @max(0, transport_state.cursor_beat));
                result_len = devResponse(response, "ok left={d}:{d} next={d}:{d} right={d}:{d} next={d}:{d}", .{
                    guide.left_current_pitch,
                    guide.left_current_finger,
                    guide.left_next_pitch,
                    guide.left_next_finger,
                    guide.right_current_pitch,
                    guide.right_current_finger,
                    guide.right_next_pitch,
                    guide.right_next_finger,
                });
            }
        } else if (commandArgument(input, "fingering")) |argument| {
            var fields = std.mem.tokenizeAny(u8, argument, " \t");
            if (!std.mem.eql(u8, fields.next() orelse "", "set")) return devResponse(response, "error fingering expects state, chord, or set NOTE_ID 1..5|clear", .{});
            const stable_id_text = fields.next() orelse return devResponse(response, "error fingering set expects NOTE_ID 1..5|clear", .{});
            const finger_text = fields.next() orelse return devResponse(response, "error fingering set expects NOTE_ID 1..5|clear", .{});
            if (fields.next() != null) return devResponse(response, "error fingering set expects NOTE_ID 1..5|clear", .{});
            const stable_id = std.fmt.parseUnsigned(u64, stable_id_text, 10) catch return devResponse(response, "error invalid note id", .{});
            const finger: u8 = if (std.mem.eql(u8, finger_text, "clear")) 0 else std.fmt.parseUnsigned(u8, finger_text, 10) catch return devResponse(response, "error fingering expects 1..5 or clear", .{});
            if (finger > 5) return devResponse(response, "error fingering expects 1..5 or clear", .{});
            if (!self.setNoteFingering(stable_id, finger, true)) return devResponse(response, "error note id {d} not found", .{stable_id});
            result_len = devResponse(response, "ok note={d} fingering={d}", .{ stable_id, finger });
        } else if (commandArgument(input, "ink")) |argument| {
            if (std.mem.eql(u8, argument, "undo")) {
                result_len = devResponse(response, "ok ink_undone={d} strokes={d}", .{ @intFromBool(self.annotations.undoLast()), self.annotations.stroke_count });
            } else {
                var fields = std.mem.tokenizeAny(u8, argument, " \t");
                if (!std.mem.eql(u8, fields.next() orelse "", "dot")) return devResponse(response, "error ink expects dot BEAT HEIGHT or undo", .{});
                const beat_text = fields.next() orelse return devResponse(response, "error ink dot expects BEAT HEIGHT", .{});
                const height_text = fields.next() orelse return devResponse(response, "error ink dot expects BEAT HEIGHT", .{});
                if (fields.next() != null) return devResponse(response, "error ink dot expects BEAT HEIGHT", .{});
                const beat = std.fmt.parseFloat(f32, beat_text) catch return devResponse(response, "error invalid ink beat", .{});
                const height = std.fmt.parseFloat(f32, height_text) catch return devResponse(response, "error invalid ink height", .{});
                if (!std.math.isFinite(beat) or beat < 0 or beat > bounds.end_beat) return devResponse(response, "error ink beat outside score", .{});
                if (!std.math.isFinite(height) or height < 0 or height > 1) return devResponse(response, "error ink height expects 0..1", .{});
                const page = self.scorePageForState(ui_state, meta, beat);
                self.annotations.beginScore(.{ .u = beat, .v = height, .pressure = 0.7, .time_ms = self.time_seconds * 1000 }, page.page_index);
                self.annotations.end();
                result_len = devResponse(response, "ok ink beat={d:.3} height={d:.3} page={d} strokes={d}", .{ beat, height, page.page_index + 1, self.annotations.stroke_count });
            }
        } else if (commandArgument(input, "record")) |argument| {
            if (std.mem.eql(u8, argument, "start")) {
                transport_state.recording = 1;
                self.take.reset(@intFromFloat(self.time_seconds * std.time.ns_per_s));
                self.take.tempo_bpm = model.effectiveTempoAt(bounds, transport_state, @max(0, transport_state.cursor_beat));
                practice_state.* = .{};
                self.host_request = .start_recording;
                result_len = devResponse(response, "ok recording=1 tempo={d:.2}", .{self.take.tempo_bpm});
            } else if (std.mem.eql(u8, argument, "stop")) {
                transport_state.recording = 0;
                self.take.stopped_ns = @intFromFloat(self.time_seconds * std.time.ns_per_s);
                self.host_request = .stop_recording;
                result_len = devResponse(response, "ok recording=0 take={d}", .{self.take.midi_len});
            } else {
                return devResponse(response, "error record expects start or stop", .{});
            }
        } else if (commandArgument(input, "midi")) |argument| {
            var fields = std.mem.tokenizeAny(u8, argument, " \t");
            const status_text = fields.next() orelse return devResponse(response, "error midi expects STATUS DATA1 DATA2", .{});
            const data1_text = fields.next() orelse return devResponse(response, "error midi expects STATUS DATA1 DATA2", .{});
            const data2_text = fields.next() orelse return devResponse(response, "error midi expects STATUS DATA1 DATA2", .{});
            if (fields.next() != null) return devResponse(response, "error midi expects STATUS DATA1 DATA2", .{});
            const status = std.fmt.parseInt(u8, status_text, 0) catch return devResponse(response, "error invalid MIDI status", .{});
            const data1 = std.fmt.parseInt(u8, data1_text, 0) catch return devResponse(response, "error invalid MIDI data1", .{});
            const data2 = std.fmt.parseInt(u8, data2_text, 0) catch return devResponse(response, "error invalid MIDI data2", .{});
            if (status < 0x80 or status >= 0xf0 or data1 >= 128 or data2 >= 128) return devResponse(response, "error invalid MIDI channel message", .{});
            self.midiInput(@intFromFloat(self.time_seconds * std.time.ns_per_s), status, data1, data2);
            result_len = devResponse(response, "ok midi=0x{x} {d} {d} take={d}", .{ status, data1, data2, self.take.midi_len });
        } else if (std.mem.eql(u8, input, "play")) {
            if (transport_state.playing == 0) self.toggleTransport(transport_state);
            result_len = devResponse(response, "ok playing={d} cursor={d:.3}", .{ transport_state.playing, transport_state.cursor_beat });
        } else if (std.mem.eql(u8, input, "pause")) {
            transport_state.playing = 0;
            result_len = devResponse(response, "ok playing=0 cursor={d:.3}", .{transport_state.cursor_beat});
        } else if (std.mem.eql(u8, input, "toggle")) {
            self.toggleTransport(transport_state);
            result_len = devResponse(response, "ok playing={d} cursor={d:.3}", .{ transport_state.playing, transport_state.cursor_beat });
        } else if (commandArgument(input, "seek")) |argument| {
            const beat = std.fmt.parseFloat(f32, argument) catch return devResponse(response, "error seek expects a number", .{});
            transport_state.cursor_beat = std.math.clamp(beat, 0, bounds.end_beat);
            // A stale loop after a remote/dev seek can otherwise wrap the
            // cursor into an unrelated bar on the first playback frame. A
            // deliberate seek outside the active range means the user left
            // that loop; seeking within it preserves the loop.
            if (transport_state.loop_enabled != 0 and
                (transport_state.cursor_beat < transport_state.loop_start or transport_state.cursor_beat >= transport_state.loop_end))
            {
                transport_state.loop_enabled = 0;
            }
            ui_state.view_start_beat = self.scorePageForState(ui_state, meta, transport_state.cursor_beat).startBeat();
            result_len = devResponse(response, "ok cursor={d:.3} page={d:.3} loop={d}", .{ transport_state.cursor_beat, ui_state.view_start_beat, transport_state.loop_enabled });
        } else if (commandArgument(input, "page")) |argument| {
            if (std.mem.eql(u8, argument, "next")) {
                self.nextScorePage(ui_state, meta);
            } else if (std.mem.eql(u8, argument, "previous")) {
                self.previousScorePage(ui_state, meta);
            } else {
                return devResponse(response, "error page expects next or previous", .{});
            }
            const page = if (ui_state.score_view_mode == .continuous)
                self.scoreContinuousForState(ui_state, meta, ui_state.view_start_beat)
            else
                self.scorePageForState(ui_state, meta, ui_state.view_start_beat);
            result_len = devResponse(response, "ok page={d} start={d:.3} end={d:.3}", .{ page.page_index + 1, page.startBeat(), page.endBeat() });
        } else if (commandArgument(input, "tempo")) |argument| {
            const bpm = std.fmt.parseFloat(f32, argument) catch return devResponse(response, "error tempo expects a number", .{});
            transport_state.tempo_bpm = std.math.clamp(bpm, 30, 240);
            result_len = devResponse(response, "ok tempo={d:.2}", .{transport_state.tempo_bpm});
        } else if (commandArgument(input, "view")) |argument| {
            ui_state.score_view_mode = if (std.mem.eql(u8, argument, "paged"))
                .paged
            else if (std.mem.eql(u8, argument, "continuous"))
                .continuous
            else if (std.mem.eql(u8, argument, "spread"))
                .spread
            else
                return devResponse(response, "error view expects paged, continuous, or spread", .{});
            result_len = devResponse(response, "ok view={s}", .{@tagName(ui_state.score_view_mode)});
        } else if (commandArgument(input, "zoom")) |argument| {
            const zoom = std.fmt.parseFloat(f32, argument) catch return devResponse(response, "error zoom expects a number", .{});
            ui_state.zoom = std.math.clamp(zoom, ui.min_score_zoom, ui.max_score_zoom);
            result_len = devResponse(response, "ok zoom={d:.2}", .{ui_state.zoom});
        } else if (commandArgument(input, "focus")) |argument| {
            ui_state.focus_score = devToggle(argument, ui_state.focus_score) orelse return devResponse(response, "error focus expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok focus={d}", .{ui_state.focus_score});
        } else if (commandArgument(input, "keys")) |argument| {
            ui_state.keyboard_visible = devToggle(argument, ui_state.keyboard_visible) orelse return devResponse(response, "error keys expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok keys={d}", .{ui_state.keyboard_visible});
        } else if (commandArgument(input, "voice")) |argument| {
            ui_state.vocal_guide_visible = devToggle(argument, ui_state.vocal_guide_visible) orelse return devResponse(response, "error voice expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok voice={d}", .{ui_state.vocal_guide_visible});
        } else if (commandArgument(input, "pedal")) |argument| {
            ui_state.pedal_guide_visible = devToggle(argument, ui_state.pedal_guide_visible) orelse return devResponse(response, "error pedal expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok pedalguide={d}", .{ui_state.pedal_guide_visible});
        } else if (commandArgument(input, "metronome")) |argument| {
            transport_state.metronome_enabled = devToggle(argument, transport_state.metronome_enabled) orelse return devResponse(response, "error metronome expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok metronome={d}", .{transport_state.metronome_enabled});
        } else if (commandArgument(input, "loop")) |argument| {
            transport_state.loop_enabled = devToggle(argument, transport_state.loop_enabled) orelse return devResponse(response, "error loop expects on, off, or toggle", .{});
            result_len = devResponse(response, "ok loop={d}", .{transport_state.loop_enabled});
        } else if (commandArgument(input, "tool")) |argument| {
            ui_state.tool = if (std.mem.eql(u8, argument, "read"))
                .read
            else if (std.mem.eql(u8, argument, "edit"))
                .edit
            else if (std.mem.eql(u8, argument, "ink"))
                .annotate
            else if (std.mem.eql(u8, argument, "practice"))
                .practice
            else
                return devResponse(response, "error unknown tool", .{});
            result_len = devResponse(response, "ok tool={s}", .{argument});
        } else if (commandArgument(input, "plugin")) |argument| {
            const callback = self.dev_command_callback orelse return devResponse(response, "error hot plugin has no command hook", .{});
            var notes: [musicxml.max_import_notes]model.Note = undefined;
            for (self.note_entities[0..self.note_count], 0..) |entity, index| {
                notes[index] = (self.getConst(model.Note, entity, self.ids.note) orelse continue).*;
            }
            var context = hot.DevCommandContext{
                .command = argument.ptr,
                .command_len = @intCast(argument.len),
                .response = response.ptr,
                .response_capacity = @intCast(response.len),
                .response_len = 0,
                .transport = transport_state,
                .ui_state = ui_state,
                .practice = practice_state,
                .document_meta = meta,
                .playback_bounds = bounds,
                .notes = &notes,
                .note_count = @intCast(self.note_count),
            };
            callback(&context);
            for (self.note_entities[0..self.note_count], 0..) |entity, index| {
                if (self.getMut(model.Note, entity, self.ids.note)) |note| note.* = notes[index];
                c.ecs_modified_id(self.world, entity, self.ids.note);
            }
            self.rebuildTimeline();
            result_len = @min(response.len, context.response_len);
            if (result_len == 0) result_len = devResponse(response, "ok plugin command completed", .{});
        } else {
            result_len = devResponse(response, "error unknown command; run help", .{});
        }

        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        c.ecs_modified_id(self.world, self.session, self.ids.practice);
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.playback_bounds);
        self.buildFrame();
        return result_len;
    }

    /// Installs or replaces a development module at a frame boundary. Flecs
    /// component storage remains untouched. Query changes recreate only the
    /// affected system entity; callback-only changes are pointer swaps.
    pub fn applySystemPlugin(self: *App, plugin: *const hot.PluginDescriptor) !void {
        if (!hot.compatible(plugin)) return error.IncompatiblePlugin;
        if (plugin.glyph_atlas_hash != builtin_systems.descriptor().glyph_atlas_hash) return error.GlyphAtlasMismatch;
        for (plugin.systems[0..plugin.system_count]) |descriptor| {
            if (descriptor.term_count > hot.max_query_terms) return error.InvalidQuery;
            if (self.findRuntime(descriptor.stable_id)) |slot| {
                const current = self.systems[slot].?;
                if (sameQuery(current, &descriptor)) {
                    current.callback = descriptor.callback;
                } else {
                    c.ecs_delete(self.world, current.entity);
                    std.heap.c_allocator.destroy(current);
                    self.systems[slot] = try self.createRuntime(&descriptor);
                }
            } else {
                if (self.system_count == self.systems.len) return error.TooManySystems;
                self.systems[self.system_count] = try self.createRuntime(&descriptor);
                self.system_count += 1;
            }
        }
        if (plugin.draw) |draw_callback| self.draw_callback = draw_callback;
        self.dev_command_callback = plugin.dev_command;
        self.plugin_generation = plugin.generation;
    }

    pub fn restoreBuiltinSystems(self: *App) void {
        self.applySystemPlugin(builtin_systems.descriptor()) catch unreachable;
    }

    fn seedOriginalStudy(self: *App) void {
        const pitches = [_]u8{
            60, 64, 67, 69, 67, 64, 62, 60,
            62, 65, 69, 72, 69, 65, 64, 62,
            60, 62, 64, 67, 65, 64, 62, 59,
            60, 64, 67, 72, 71, 69, 67, 60,
        };
        for (pitches, 0..) |pitch, index| {
            const entity = createEntity(self.world, null);
            var note = model.Note{
                .stable_id = self.next_note_id,
                .start_beat = @floatFromInt(index),
                .duration_beats = 0.82,
                .pitch = pitch,
                .velocity = 88,
                .staff = 0,
                .voice = 0,
            };
            c.ecs_set_id(self.world, entity, self.ids.note, @sizeOf(model.Note), &note);
            self.note_entities[self.note_count] = entity;
            self.note_count += 1;
            self.next_note_id += 1;
            if (index % 2 == 0) {
                const bass_entity = createEntity(self.world, null);
                const bass_pattern = [_]u8{ 48, 45, 50, 43 };
                var bass = model.Note{
                    .stable_id = self.next_note_id,
                    .start_beat = @floatFromInt(index),
                    .duration_beats = 1.72,
                    .pitch = bass_pattern[(index / 2) % bass_pattern.len],
                    .velocity = 72,
                    .staff = 1,
                    .voice = 1,
                };
                c.ecs_set_id(self.world, bass_entity, self.ids.note, @sizeOf(model.Note), &bass);
                self.note_entities[self.note_count] = bass_entity;
                self.note_count += 1;
                self.next_note_id += 1;
            }
        }
    }

    fn replaceNotes(self: *App, notes: []const model.Note) !void {
        if (notes.len > self.note_entities.len) return error.TooManyNotes;
        for (self.note_entities[0..self.note_count]) |entity| c.ecs_delete(self.world, entity);
        self.note_count = 0;
        for (notes) |source_note| {
            const entity = createEntity(self.world, null);
            var note = source_note;
            c.ecs_set_id(self.world, entity, self.ids.note, @sizeOf(model.Note), &note);
            self.note_entities[self.note_count] = entity;
            self.note_count += 1;
        }
        self.journal = .{};
        self.next_note_id = 1;
        for (notes) |note| self.next_note_id = @max(self.next_note_id, note.stable_id + 1);
        self.rebuildTimeline();
    }

    fn vocalStaffVisible(self: *const App, state: *const model.UiState) bool {
        if (state.vocal_guide_visible == 0) return false;
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if ((note.flags & model.note_flag_vocal_guide) != 0) return true;
        }
        return false;
    }

    fn scoreSystemsForState(self: *const App, state: *const model.UiState) usize {
        const layout = ui.Layout.calculateForState(state);
        const stage = if (state.score_view_mode == .spread) layout.stage else ui.zoomedScoreStage(layout.stage, state.zoom);
        return ui.scoreSystemsPerPage(stage.height, self.vocalStaffVisible(state));
    }

    fn scorePageForState(self: *const App, state: *const model.UiState, meta: *const model.DocumentMeta, beat: f32) ui.ScorePage {
        return ui.scorePageForBeatLimited(self.measures[0..self.measure_count], beat, meta, state.zoom, self.scoreSystemsForState(state));
    }

    fn scoreContinuousForState(self: *const App, state: *const model.UiState, meta: *const model.DocumentMeta, beat: f32) ui.ScorePage {
        return ui.scoreContinuousForBeatLimited(self.measures[0..self.measure_count], beat, meta, state.zoom, self.scoreSystemsForState(state));
    }

    fn scoreHitContext(self: *const App, state: *const model.UiState, meta: *const model.DocumentMeta, stage: ui.Rect, x: f32, y: f32) ScoreHitContext {
        var pane = stage;
        var page = if (state.score_view_mode == .continuous)
            self.scoreContinuousForState(state, meta, state.view_start_beat)
        else
            self.scorePageForState(state, meta, state.view_start_beat);
        const zoom = std.math.clamp(state.zoom, ui.min_score_zoom, ui.max_score_zoom);
        if (state.score_view_mode == .spread and stage.width >= 760) {
            const visible_pages = ui.spreadVisiblePageCount(stage, zoom);
            var selected_offset: usize = 0;
            for (0..visible_pages) |page_offset| {
                const candidate = ui.spreadPageStage(stage, zoom, page_offset);
                if (candidate.contains(x, y)) {
                    pane = candidate;
                    selected_offset = page_offset;
                    break;
                }
            }
            for (0..selected_offset) |_| {
                const next = self.scorePageForState(state, meta, page.endBeat());
                if (next.page_index == page.page_index) break;
                page = next;
            }
        } else if (state.score_view_mode == .paged) {
            pane = ui.zoomedScoreStage(stage, zoom);
            const center_x = stage.x + stage.width * 0.5;
            return .{
                .stage = pane,
                .page = page,
                .x = center_x + (x - center_x) / zoom,
                .y = stage.y + (y - stage.y) / zoom,
            };
        }
        if (state.score_view_mode == .continuous) {
            pane = ui.zoomedScoreStage(stage, zoom);
            const center_x = pane.x + pane.width * 0.5;
            return .{
                .stage = pane,
                .page = page,
                .x = center_x + (x - center_x) / zoom,
                .y = pane.y + (y - pane.y) / zoom,
            };
        }
        const center_x = pane.x + pane.width * 0.5;
        const center_y = pane.y + pane.height * 0.5;
        return .{
            .stage = pane,
            .page = page,
            .x = center_x + (x - center_x) / zoom,
            .y = center_y + (y - center_y) / zoom,
        };
    }

    fn annotationPointForHit(self: *const App, state: *const model.UiState, hit: ScoreHitContext, pressure: f32) annotation.Point {
        const vocal_visible = self.vocalStaffVisible(state);
        const geometry = ui.ScoreGeometry.calculateForSystems(hit.stage, vocal_visible, hit.page.system_count);
        const system = ui.scoreSystemAtY(geometry, hit.page, vocal_visible, hit.y);
        const top = if (vocal_visible) geometry.vocal_y[system] else geometry.treble_y[system];
        const bottom = geometry.bass_y[system] + 49;
        const score_system = hit.page.systems[system];
        const beat = std.math.clamp(
            ui.scoreBeatAtX(geometry, hit.page, self.measures[0..self.measure_count], system, hit.x),
            score_system.start_beat,
            @max(score_system.start_beat, score_system.end_beat - 0.001),
        );
        return .{
            .u = beat,
            .v = std.math.clamp((hit.y - top) / @max(1, bottom - top), -1, 2),
            .pressure = if (pressure > 0) pressure else 0.5,
            .time_ms = self.time_seconds * 1000,
        };
    }

    fn insertNoteAt(self: *App, x: f32, y: f32, stage: ui.Rect) void {
        if (self.note_count == self.note_entities.len) return;
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const vocal_visible = self.vocalStaffVisible(state);
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
        const measures = self.measures[0..self.measure_count];
        const hit = self.scoreHitContext(state, meta, stage, x, y);
        const geometry = ui.ScoreGeometry.calculateForSystems(hit.stage, vocal_visible, hit.page.system_count);
        const page = hit.page;
        const system_index = ui.scoreSystemAtY(geometry, page, vocal_visible, hit.y);
        const treble_distance = @abs(hit.y - (geometry.treble_y[system_index] + 24));
        const bass_distance = @abs(hit.y - (geometry.bass_y[system_index] + 24));
        const staff: u8 = if (bass_distance < treble_distance) 1 else 0;
        const absolute_beat = ui.scoreBeatAtX(geometry, page, measures, system_index, hit.x);
        const quantized = @round(absolute_beat * 4) / 4;
        var pitch: u8 = 21;
        var pitch_distance: f32 = std.math.floatMax(f32);
        for (21..109) |candidate_value| {
            const candidate: u8 = @intCast(candidate_value);
            const candidate_note = model.Note{ .stable_id = 0, .start_beat = quantized, .duration_beats = 0.5, .pitch = candidate, .velocity = 88, .staff = staff, .voice = 0 };
            const position = ui.scoreNotePosition(candidate_note, geometry, page, measures) orelse continue;
            const distance = @abs(position.y - hit.y);
            if (distance < pitch_distance) {
                pitch_distance = distance;
                pitch = candidate;
            }
        }
        const note = model.Note{ .stable_id = self.next_note_id, .start_beat = quantized, .duration_beats = 0.5, .pitch = pitch, .velocity = 88, .staff = staff, .voice = 0, .selected = 1 };
        self.next_note_id += 1;
        self.insertNote(note, true);
    }

    fn insertNote(self: *App, note: model.Note, record_history: bool) void {
        if (self.note_count == self.note_entities.len) return;
        for (self.note_entities[0..self.note_count]) |existing| {
            if (self.getMut(model.Note, existing, self.ids.note)) |value| value.selected = 0;
        }
        const entity = createEntity(self.world, null);
        var stored = note;
        c.ecs_set_id(self.world, entity, self.ids.note, @sizeOf(model.Note), &stored);
        self.note_entities[self.note_count] = entity;
        self.note_count += 1;
        if (record_history) self.journal.push(.{ .kind = .insert_note, .before = note, .after = note });
        self.rebuildTimeline();
    }

    fn deleteNoteByStableId(self: *App, stable_id: u64, record_history: bool) void {
        for (self.note_entities[0..self.note_count], 0..) |entity, index| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if (note.stable_id != stable_id) continue;
            const copy = note.*;
            c.ecs_delete(self.world, entity);
            if (index + 1 < self.note_count) std.mem.copyForwards(c.ecs_entity_t, self.note_entities[index .. self.note_count - 1], self.note_entities[index + 1 .. self.note_count]);
            self.note_count -= 1;
            if (record_history) self.journal.push(.{ .kind = .delete_note, .before = copy, .after = copy });
            self.rebuildTimeline();
            return;
        }
    }

    fn replaceNote(self: *App, stable_id: u64, replacement: model.Note, record_history: bool) void {
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getMut(model.Note, entity, self.ids.note) orelse continue;
            if (note.stable_id != stable_id) continue;
            const before = note.*;
            note.* = replacement;
            c.ecs_modified_id(self.world, entity, self.ids.note);
            if (record_history) self.journal.push(.{ .kind = .replace_note, .before = before, .after = replacement });
            self.rebuildTimeline();
            return;
        }
    }

    fn deleteSelectedNote(self: *App) void {
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if (note.selected != 0) {
                self.deleteNoteByStableId(note.stable_id, true);
                return;
            }
        }
    }

    fn moveSelectedNote(self: *App, pitch_delta: i8, beat_delta: f32) void {
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if (note.selected == 0) continue;
            var replacement = note.*;
            replacement.pitch = @intCast(std.math.clamp(@as(i16, replacement.pitch) + pitch_delta, 0, 127));
            replacement.start_beat = @max(0, replacement.start_beat + beat_delta);
            self.replaceNote(replacement.stable_id, replacement, true);
            return;
        }
    }

    fn setNoteFingering(self: *App, stable_id: u64, finger: u8, record_history: bool) bool {
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if (note.stable_id != stable_id) continue;
            if (note.fingering == finger) return true;
            var replacement = note.*;
            replacement.fingering = finger;
            self.replaceNote(stable_id, replacement, record_history);
            return true;
        }
        return false;
    }

    fn setSelectedFingering(self: *App, finger: u8) void {
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if (note.selected == 0) continue;
            _ = self.setNoteFingering(note.stable_id, finger, true);
            return;
        }
    }

    fn selectNearestNote(self: *App, x: f32, y: f32, stage: ui.Rect) void {
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
        const measures = self.measures[0..self.measure_count];
        const hit = self.scoreHitContext(state, meta, stage, x, y);
        const geometry = ui.ScoreGeometry.calculateForSystems(hit.stage, self.vocalStaffVisible(state), hit.page.system_count);
        const page = hit.page;
        var best_entity: c.ecs_entity_t = 0;
        var best_distance_squared: f32 = std.math.floatMax(f32);
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getMut(model.Note, entity, self.ids.note) orelse continue;
            note.selected = 0;
            if ((note.flags & model.note_flag_vocal_guide) != 0 and state.vocal_guide_visible == 0) continue;
            const position = ui.scoreNotePosition(note.*, geometry, page, measures) orelse continue;
            const dx = position.x - hit.x;
            const dy = position.y - hit.y;
            const distance_squared = dx * dx + dy * dy;
            if (distance_squared < best_distance_squared) {
                best_distance_squared = distance_squared;
                best_entity = entity;
            }
        }
        if (best_entity != 0 and best_distance_squared < 42 * 42) {
            if (self.getMut(model.Note, best_entity, self.ids.note)) |note| {
                note.selected = 1;
                if (self.getMut(model.Transport, self.session, self.ids.transport)) |transport| {
                    if (transport.playing == 0) transport.cursor_beat = note.start_beat;
                }
            }
        }
    }

    fn scoreEndBeat(self: *const App) f32 {
        var result: f32 = 4;
        for (self.note_entities[0..self.note_count]) |entity| {
            if (self.getConst(model.Note, entity, self.ids.note)) |note| result = @max(result, note.start_beat + note.duration_beats);
        }
        for (self.pedals[0..self.pedal_count]) |event| result = @max(result, event.start_beat);
        return result;
    }

    fn nextScorePage(self: *const App, state: *model.UiState, meta: *const model.DocumentMeta) void {
        if (state.score_view_mode == .continuous) {
            const window = self.scoreContinuousForState(state, meta, state.view_start_beat);
            if (window.system_count > 1) {
                state.view_start_beat = window.systems[1].start_beat;
            } else if (window.endBeat() < self.scoreEndBeat() - 0.0001) {
                state.view_start_beat = window.endBeat();
            }
            return;
        }
        var page = self.scorePageForState(state, meta, state.view_start_beat);
        state.view_start_beat = page.startBeat();
        const advances: usize = if (state.score_view_mode == .spread) 2 else 1;
        for (0..advances) |_| {
            if (page.endBeat() >= self.scoreEndBeat() - 0.0001) break;
            state.view_start_beat = page.endBeat();
            page = self.scorePageForState(state, meta, state.view_start_beat);
        }
    }

    fn previousScorePage(self: *const App, state: *model.UiState, meta: *const model.DocumentMeta) void {
        if (state.score_view_mode == .continuous) {
            const window = self.scoreContinuousForState(state, meta, state.view_start_beat);
            if (window.startBeat() > 0.0001) state.view_start_beat = self.scoreContinuousForState(state, meta, window.startBeat() - 0.001).startBeat();
            return;
        }
        var page = self.scorePageForState(state, meta, state.view_start_beat);
        state.view_start_beat = page.startBeat();
        const retreats: usize = if (state.score_view_mode == .spread) 2 else 1;
        for (0..retreats) |_| {
            if (page.startBeat() <= 0.0001) break;
            state.view_start_beat = self.scorePageForState(state, meta, page.startBeat() - 0.001).startBeat();
            page = self.scorePageForState(state, meta, state.view_start_beat);
        }
    }

    fn toggleTransport(self: *App, transport: *model.Transport) void {
        if (transport.playing != 0) {
            transport.playing = 0;
            return;
        }
        const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
        if (transport.cursor_beat >= bounds.end_beat - 0.001) transport.cursor_beat = 0;
        if (transport.cursor_beat <= 0.001 and transport.count_in_bars != 0) {
            const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
            transport.cursor_beat = -@as(f32, @floatFromInt(transport.count_in_bars)) * meta.measureBeats();
        }
        transport.playing = 1;
    }

    fn assessMidiNote(self: *App, played_pitch: u8) void {
        self.assessObservedPitch(played_pitch, 1);
    }

    fn assessObservedPitch(self: *App, played_pitch: u8, confidence: f32) void {
        const transport_state = self.getConst(model.Transport, self.session, self.ids.transport) orelse return;
        if (transport_state.cursor_beat < 0) return;
        var nearest: ?model.Note = null;
        var nearest_distance: f32 = 1000;
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getConst(model.Note, entity, self.ids.note) orelse continue;
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
            const distance = @abs(note.start_beat - transport_state.cursor_beat);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = note.*;
            }
        }
        const expected = nearest orelse return;
        const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
        const milliseconds_per_beat = 60_000.0 / model.effectiveTempoAt(bounds, transport_state, transport_state.cursor_beat);
        const result = practice_assessment.assess(expected.pitch, expected.start_beat * milliseconds_per_beat, played_pitch, transport_state.cursor_beat * milliseconds_per_beat, confidence);
        const state = self.getMut(model.PracticeState, self.session, self.ids.practice) orelse return;
        state.total_notes += 1;
        switch (result.rating) {
            .perfect, .correct => state.correct_notes += 1,
            .early => state.early_notes += 1,
            .late => state.late_notes += 1,
            .wrong_pitch => state.pitch_errors += 1,
        }
        state.confidence = confidence;
        state.average_timing_ms = if (state.total_notes == 1) @abs(result.timing_delta_ms) else (state.average_timing_ms * @as(f32, @floatFromInt(state.total_notes - 1)) + @abs(result.timing_delta_ms)) / @as(f32, @floatFromInt(state.total_notes));
        c.ecs_modified_id(self.world, self.session, self.ids.practice);
    }

    fn assessPedal(self: *App, pedal: u8, previous_value: u8, value: u8) void {
        const was_down = previous_value >= 64;
        const is_down = value >= 64;
        if (was_down == is_down) return;
        const transport_state = self.getConst(model.Transport, self.session, self.ids.transport) orelse return;
        if (transport_state.cursor_beat < 0) return;
        var nearest: ?model.PedalEvent = null;
        var nearest_distance = std.math.inf(f32);
        for (self.pedals[0..self.pedal_count]) |event| {
            if (event.pedal != pedal or (event.value >= 64) != is_down) continue;
            const distance = @abs(event.start_beat - transport_state.cursor_beat);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = event;
            }
        }
        const expected = nearest orelse return;
        const bounds = self.getConst(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
        const milliseconds_per_beat = 60_000.0 / model.effectiveTempoAt(bounds, transport_state, transport_state.cursor_beat);
        const delta_ms = (transport_state.cursor_beat - expected.start_beat) * milliseconds_per_beat;
        const practice_state = self.getMut(model.PracticeState, self.session, self.ids.practice) orelse return;
        practice_state.pedal_changes += 1;
        practice_state.last_pedal_timing_ms = delta_ms;
        if (@abs(delta_ms) > 160) practice_state.pedal_errors += 1;
        c.ecs_modified_id(self.world, self.session, self.ids.practice);
    }

    fn buildFrame(self: *App) void {
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const transport = self.getConst(model.Transport, self.session, self.ids.transport) orelse return;
        const practice = self.getConst(model.PracticeState, self.session, self.ids.practice) orelse return;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
        var notes: [musicxml.max_import_notes]model.Note = undefined;
        var len: usize = 0;
        for (self.note_entities[0..self.note_count]) |entity| {
            if (self.getConst(model.Note, entity, self.ids.note)) |note| {
                notes[len] = note.*;
                len += 1;
            }
        }
        if (self.draw_callback) |draw_callback| {
            var context = hot.FrameContext{
                .packet = &self.packet,
                .ui_state = state,
                .transport = transport,
                .practice = practice,
                .document_meta = meta,
                .notes = notes[0..].ptr,
                .note_count = @intCast(len),
                .lyrics = self.lyrics[0..].ptr,
                .lyric_count = @intCast(self.lyric_count),
                .harmonies = self.harmonies[0..].ptr,
                .harmony_count = @intCast(self.harmony_count),
                .pedals = self.pedals[0..].ptr,
                .pedal_count = @intCast(self.pedal_count),
                .measures = self.measures[0..].ptr,
                .measure_count = @intCast(self.measure_count),
                .annotations = &self.annotations,
                .time_seconds = self.time_seconds,
            };
            draw_callback(&context);
        } else {
            ui.draw(&self.packet, state, transport, practice, meta, notes[0..len], self.lyrics[0..self.lyric_count], self.harmonies[0..self.harmony_count], self.pedals[0..self.pedal_count], self.measures[0..self.measure_count], &self.annotations, self.time_seconds);
        }
        self.accessibility.build(state, transport, meta);
    }

    fn rebuildTimeline(self: *App) void {
        var notes: [musicxml.max_import_notes]model.Note = undefined;
        var len: usize = 0;
        for (self.note_entities[0..self.note_count]) |entity| {
            if (self.getConst(model.Note, entity, self.ids.note)) |note| {
                notes[len] = note.*;
                len += 1;
            }
        }
        self.timeline = playback.Timeline.build(notes[0..len]) catch .{};
        const bounds = self.getMut(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
        bounds.end_beat = self.scoreEndBeat();
        c.ecs_modified_id(self.world, self.session, self.ids.playback_bounds);
    }

    fn configureTempoMap(self: *App, tempos: []const model.TempoEvent, base_bpm: f32, tempo_beat_unit: u8) void {
        const bounds = self.getMut(model.PlaybackBounds, self.session, self.ids.playback_bounds) orelse return;
        bounds.tempo_base_bpm = if (std.math.isFinite(base_bpm) and base_bpm > 0) base_bpm else 72;
        bounds.tempo_beat_unit = @max(@as(u8, 1), tempo_beat_unit);
        bounds.tempo_count = @intCast(@min(tempos.len, bounds.tempos.len));
        if (bounds.tempo_count == 0) {
            bounds.tempo_count = 1;
            bounds.tempos[0] = .{ .start_beat = 0, .bpm = bounds.tempo_base_bpm };
        } else {
            @memcpy(bounds.tempos[0..bounds.tempo_count], tempos[0..bounds.tempo_count]);
        }
        c.ecs_modified_id(self.world, self.session, self.ids.playback_bounds);
    }

    fn extractPlayback(self: *App, before: model.Transport, after: model.Transport) void {
        if (after.playing == 0) {
            // A transport system may have stopped exactly at the document end.
            // Emit the final slice before the all-notes-off event so a note
            // beginning in the last host frame is not silently skipped.
            if (before.playing != 0 and after.cursor_beat > before.cursor_beat) {
                self.emitRange(before.cursor_beat, after.cursor_beat);
                self.emitMetronomeRange(before.cursor_beat, after.cursor_beat, before);
            }
            if (self.was_playing) {
                self.pushPedalReset();
                self.pushPlayback(.{ .pitch = 0, .velocity = 0, .channel = 0, .on = 2 });
            }
            self.was_playing = false;
            self.previous_cursor = after.cursor_beat;
            return;
        }
        var start = before.cursor_beat;
        if (!self.was_playing) {
            self.syncScorePedals(@max(0, start));
            start -= 0.0001;
        }
        if (after.cursor_beat < start) {
            self.pushPlayback(.{ .pitch = 0, .velocity = 0, .channel = 0, .on = 2 });
            self.emitRange(start, before.loop_end);
            self.emitMetronomeRange(start, before.loop_end - 0.0001, after);
            start = before.loop_start - 0.0001;
            self.syncScorePedals(@max(0, before.loop_start));
        }
        self.emitRange(start, after.cursor_beat);
        self.emitMetronomeRange(start, after.cursor_beat, after);
        self.was_playing = true;
        self.previous_cursor = after.cursor_beat;
    }

    fn emitRange(self: *App, start: f32, end: f32) void {
        for (self.timeline.events[0..self.timeline.len]) |event| {
            if (event.beat > start and event.beat <= end) self.pushPlayback(.{ .pitch = event.pitch, .velocity = event.velocity, .channel = event.channel, .on = event.on });
        }
        for (self.pedals[0..self.pedal_count]) |event| {
            if (event.start_beat <= start or event.start_beat > end) continue;
            const controller = pedalController(event.pedal);
            // A MusicXML pedal "change" means lift and immediately depress,
            // not merely resend the same non-zero CC value. The latter leaves
            // every previously released note held forever in samplers that
            // correctly ignore redundant controller values.
            if (event.action == model.pedal_action_change and event.value != 0) {
                self.pushPlayback(.{ .pitch = controller, .velocity = 0, .channel = 0, .on = 4 });
            }
            self.pushPlayback(.{ .pitch = controller, .velocity = event.value, .channel = 0, .on = 4 });
        }
    }

    fn syncScorePedals(self: *App, beat: f32) void {
        for (0..3) |pedal| self.pushPlayback(.{ .pitch = pedalController(@intCast(pedal)), .velocity = self.scorePedalValueAt(@intCast(pedal), beat), .channel = 0, .on = 4 });
    }

    fn pushPedalReset(self: *App) void {
        for (0..3) |pedal| self.pushPlayback(.{ .pitch = pedalController(@intCast(pedal)), .velocity = 0, .channel = 0, .on = 4 });
    }

    fn scorePedalValueAt(self: *const App, pedal: u8, beat: f32) u8 {
        var value: u8 = 0;
        for (self.pedals[0..self.pedal_count]) |event| {
            if (event.start_beat > beat + 0.0001) break;
            if (event.pedal == pedal) value = event.value;
        }
        return value;
    }

    fn emitMetronomeRange(self: *App, start: f32, end: f32, transport: model.Transport) void {
        if (transport.metronome_enabled == 0 or end < start) return;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
        if (self.measure_count == 0) {
            self.emitFixedMetronomeRange(start, end, 0, meta.beats_per_measure, meta.beat_unit);
            return;
        }
        for (self.measures[0..self.measure_count]) |measure| {
            const measure_end = measure.start_beat + @max(0.0001, measure.duration_beats);
            if (measure_end <= start + 0.00001 or measure.start_beat > end + 0.00001) continue;
            const beat_length = measure.beatLength();
            var beat_index: u32 = 0;
            while (measure.start_beat + @as(f32, @floatFromInt(beat_index)) * beat_length < measure_end - 0.00001) : (beat_index += 1) {
                const click = measure.start_beat + @as(f32, @floatFromInt(beat_index)) * beat_length;
                if (click > start + 0.00001 and click <= end + 0.00001) self.pushPlayback(.{ .pitch = 0, .velocity = if (beat_index == 0) 127 else 86, .channel = 0, .on = 3 });
            }
        }
        const last = self.measures[self.measure_count - 1];
        const authored_end = last.start_beat + @max(0.0001, last.duration_beats);
        if (end > authored_end + 0.00001) self.emitFixedMetronomeRange(@max(start, authored_end - 0.0001), end, authored_end, meta.beats_per_measure, meta.beat_unit);
    }

    fn emitFixedMetronomeRange(self: *App, start: f32, end: f32, origin: f32, beats: u8, beat_unit: u8) void {
        const beat_length = 4.0 / @as(f32, @floatFromInt(@max(1, beat_unit)));
        const beats_per_measure: i64 = @max(1, beats);
        var beat_index: i64 = @as(i64, @intFromFloat(@floor((start - origin) / beat_length))) + 1;
        while (origin + @as(f32, @floatFromInt(beat_index)) * beat_length <= end + 0.00001) : (beat_index += 1) {
            const accent = @mod(beat_index, beats_per_measure) == 0;
            self.pushPlayback(.{ .pitch = 0, .velocity = if (accent) 127 else 86, .channel = 0, .on = 3 });
        }
    }

    fn pushPlayback(self: *App, event: playback.HostEvent) void {
        if (self.playback_event_count == self.playback_events.len) return;
        self.playback_events[self.playback_event_count] = event;
        self.playback_event_count += 1;
    }

    fn beginTakeReplay(self: *App) void {
        self.take_replaying = self.take.midi_len != 0;
        self.take_replay_elapsed_ns = 0;
        self.take_replay_index = 0;
    }

    fn advanceTakeReplay(self: *App, delta_seconds: f32) void {
        if (!self.take_replaying or self.take.midi_len == 0) return;
        self.take_replay_elapsed_ns += @intFromFloat(delta_seconds * std.time.ns_per_s);
        const base = self.take.midi[0].time_ns;
        while (self.take_replay_index < self.take.midi_len) {
            const event = self.take.midi[self.take_replay_index];
            if (event.time_ns -| base > self.take_replay_elapsed_ns) break;
            switch (event.kind) {
                0x90 => self.pushPlayback(.{ .pitch = event.data1, .velocity = event.data2, .channel = event.channel, .on = if (event.data2 == 0) 0 else 1 }),
                0x80 => self.pushPlayback(.{ .pitch = event.data1, .velocity = event.data2, .channel = event.channel, .on = 0 }),
                0xb0 => self.pushPlayback(.{ .pitch = event.data1, .velocity = event.data2, .channel = event.channel, .on = 4 }),
                else => {}, // Preserve unsupported messages in export; do not misplay them as notes.
            }
            self.take_replay_index += 1;
        }
        if (self.take_replay_index == self.take.midi_len) self.take_replaying = false;
    }

    fn findRuntime(self: *const App, stable_id: u64) ?usize {
        for (self.systems[0..self.system_count], 0..) |runtime, index| {
            if (runtime != null and runtime.?.stable_id == stable_id) return index;
        }
        return null;
    }

    fn createRuntime(self: *App, descriptor: *const hot.SystemDescriptor) !*RuntimeSystem {
        const runtime = try std.heap.c_allocator.create(RuntimeSystem);
        errdefer std.heap.c_allocator.destroy(runtime);
        runtime.* = .{
            .stable_id = descriptor.stable_id,
            .callback = descriptor.callback,
            .terms = descriptor.terms,
            .term_count = descriptor.term_count,
            .component_sizes = [_]usize{0} ** hot.max_query_terms,
            .entity = 0,
        };

        var system: c.ecs_system_desc_t = std.mem.zeroes(c.ecs_system_desc_t);
        system.entity = createEntity(self.world, descriptor.name);
        system.phase = c.EcsOnUpdate;
        system.callback = dispatchReloadableSystem;
        system.ctx = runtime;
        for (descriptor.terms[0..descriptor.term_count], 0..) |term, index| {
            const component = self.componentFor(term.component);
            if (component.id == 0) return error.UnknownComponent;
            system.query.terms[index].id = component.id;
            system.query.terms[index].inout = switch (term.access) {
                .read => c.EcsIn,
                .write => c.EcsOut,
                .read_write => c.EcsInOut,
                .none => c.EcsInOutDefault,
            };
            if (term.optional != 0) system.query.terms[index].oper = c.EcsOptional;
            runtime.component_sizes[index] = component.size;
        }
        runtime.entity = c.ecs_system_init(self.world, &system);
        if (runtime.entity == 0) return error.SystemRegistrationFailed;
        return runtime;
    }

    fn componentFor(self: *const App, component_key: hot.ComponentKey) struct { id: c.ecs_entity_t, size: usize } {
        return switch (component_key) {
            .transport => .{ .id = self.ids.transport, .size = @sizeOf(model.Transport) },
            .ui_state => .{ .id = self.ids.ui_state, .size = @sizeOf(model.UiState) },
            .practice_state => .{ .id = self.ids.practice, .size = @sizeOf(model.PracticeState) },
            .note => .{ .id = self.ids.note, .size = @sizeOf(model.Note) },
            .document_meta => .{ .id = self.ids.document_meta, .size = @sizeOf(model.DocumentMeta) },
            .playback_bounds => .{ .id = self.ids.playback_bounds, .size = @sizeOf(model.PlaybackBounds) },
            else => .{ .id = 0, .size = 0 },
        };
    }

    fn getConst(self: *const App, comptime T: type, entity: c.ecs_entity_t, id: c.ecs_entity_t) ?*const T {
        const raw = c.ecs_get_id(self.world, entity, id) orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    fn getMut(self: *App, comptime T: type, entity: c.ecs_entity_t, id: c.ecs_entity_t) ?*T {
        const raw = c.ecs_get_mut_id(self.world, entity, id) orelse return null;
        return @ptrCast(@alignCast(raw));
    }
};

fn commandArgument(input: []const u8, command_name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, input, command_name)) return null;
    if (input.len == command_name.len) return "";
    if (input[command_name.len] != ' ') return null;
    return std.mem.trim(u8, input[command_name.len + 1 ..], " \t\r\n");
}

fn pedalController(pedal: u8) u8 {
    return switch (pedal) {
        model.pedal_sostenuto => 66,
        model.pedal_soft => 67,
        else => 64,
    };
}

fn devToggle(argument: []const u8, current: u32) ?u32 {
    if (std.mem.eql(u8, argument, "on")) return 1;
    if (std.mem.eql(u8, argument, "off")) return 0;
    if (std.mem.eql(u8, argument, "toggle")) return if (current == 0) 1 else 0;
    return null;
}

fn devResponse(output: []u8, comptime format: []const u8, arguments: anytype) usize {
    const value = std.fmt.bufPrint(output, format, arguments) catch return 0;
    return value.len;
}

fn appendDevResponse(output: []u8, len: *usize, comptime format: []const u8, arguments: anytype) bool {
    const value = std.fmt.bufPrint(output[len.*..], format, arguments) catch return false;
    len.* += value.len;
    return true;
}

fn chordFingeringResponse(output: []u8, guide: ui.ChordFingeringSnapshot) usize {
    var len: usize = 0;
    if (!appendDevResponse(output, &len, "ok", .{})) return 0;
    const labels = [_][]const u8{ "left", "left-next", "right", "right-next" };
    const chords = [_]ui.ChordFingering{ guide.left_current, guide.left_next, guide.right_current, guide.right_next };
    for (labels, chords) |label, chord| {
        if (!appendDevResponse(output, &len, " {s}[{d}]", .{ label, chord.len })) return len;
        if (chord.overflow != 0 and !appendDevResponse(output, &len, "+{d}", .{chord.overflow})) return len;
        if (!appendDevResponse(output, &len, "=", .{})) return len;
        for (chord.pitches[0..chord.len], chord.fingers[0..chord.len], 0..) |pitch, finger, index| {
            if (index != 0 and !appendDevResponse(output, &len, ",", .{})) return len;
            if (!appendDevResponse(output, &len, "{d}:{d}", .{ pitch, finger })) return len;
        }
    }
    return len;
}

fn createEntity(world: *c.ecs_world_t, name: ?[*:0]const u8) c.ecs_entity_t {
    var descriptor: c.ecs_entity_desc_t = std.mem.zeroes(c.ecs_entity_desc_t);
    descriptor.name = name;
    return c.ecs_entity_init(world, &descriptor);
}

fn registerComponent(world: *c.ecs_world_t, comptime T: type, name: [*:0]const u8) c.ecs_entity_t {
    const entity = createEntity(world, name);
    var descriptor: c.ecs_component_desc_t = std.mem.zeroes(c.ecs_component_desc_t);
    descriptor.entity = entity;
    descriptor.type.size = @intCast(@sizeOf(T));
    descriptor.type.alignment = @intCast(@alignOf(T));
    return c.ecs_component_init(world, &descriptor);
}

fn dispatchReloadableSystem(iter: ?*c.ecs_iter_t) callconv(.c) void {
    const it = iter orelse return;
    const runtime: *RuntimeSystem = @ptrCast(@alignCast(it.ctx orelse return));
    var context = hot.SystemContext{
        .delta_seconds = it.delta_time,
        .entity_count = @intCast(it.count),
        .columns = [_]?*anyopaque{null} ** hot.max_query_terms,
    };
    for (0..runtime.term_count) |index| {
        context.columns[index] = c.ecs_field_w_size(it, runtime.component_sizes[index], @intCast(index));
    }
    runtime.callback(&context);
}

fn sameQuery(runtime: *const RuntimeSystem, descriptor: *const hot.SystemDescriptor) bool {
    if (runtime.term_count != descriptor.term_count) return false;
    for (0..runtime.term_count) |index| {
        const left = runtime.terms[index];
        const right = descriptor.terms[index];
        if (left.component != right.component or left.access != right.access or left.optional != right.optional or left.source != right.source) return false;
    }
    return true;
}

test "Flecs world advances playback and produces a GPU packet" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    for (0..300) |_| app.tick(1.0 / 60.0);
    try std.testing.expect(app.transportSnapshot().cursor_beat > 0);
    try std.testing.expect(app.drawItems().len > 300);
}

test "hot-reloadable transport stops at score end and replay starts over" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const bounds = app.getConst(model.PlaybackBounds, app.session, app.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
    const expected_end = bounds.end_beat;
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.count_in_bars = 0;
    transport.cursor_beat = expected_end - 0.01;
    transport.playing = 1;
    app.was_playing = true;

    app.tick(0.1);
    const stopped = app.transportSnapshot();
    try std.testing.expectEqual(@as(u32, 0), stopped.playing);
    try std.testing.expectApproxEqAbs(expected_end, stopped.cursor_beat, 0.0001);
    var events: [256]playback.HostEvent = undefined;
    const event_count = app.drainPlaybackEvents(&events);
    try std.testing.expect(event_count != 0);
    try std.testing.expectEqual(@as(u8, 2), events[event_count - 1].on);

    app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    const restarted = app.transportSnapshot();
    try std.testing.expectEqual(@as(u32, 1), restarted.playing);
    try std.testing.expectEqual(@as(f32, 0), restarted.cursor_beat);
}

test "accessible GPU pedal button toggles score and keyboard guidance" {
    const app = try App.create(std.heap.c_allocator, 1440, 900, 2);
    defer app.destroy(std.heap.c_allocator);
    const before_items = app.drawItems().len;
    app.accessibilityActivate(accessibility.Id.pedal_guide);
    const state = app.getConst(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    try std.testing.expectEqual(@as(u32, 0), state.pedal_guide_visible);
    try std.testing.expect(app.drawItems().len < before_items);
    app.key(.{ .key = 'G', .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(@as(u32, 1), state.pedal_guide_visible);
}

test "development commands control live Flecs state and invoke hot Zig code" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    var response: [512]u8 = undefined;

    var len = app.runDevCommand("tempo 91.5", &response);
    try std.testing.expect(std.mem.startsWith(u8, response[0..len], "ok tempo=91.50"));
    try std.testing.expectApproxEqAbs(@as(f32, 91.5), app.transportSnapshot().tempo_bpm, 0.001);

    len = app.runDevCommand("keys off", &response);
    try std.testing.expectEqualStrings("ok keys=0", response[0..len]);
    const ui_state = app.getConst(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    try std.testing.expectEqual(@as(u32, 0), ui_state.keyboard_visible);

    len = app.runDevCommand("pedal off", &response);
    try std.testing.expectEqualStrings("ok pedalguide=0", response[0..len]);
    try std.testing.expectEqual(@as(u32, 0), ui_state.pedal_guide_visible);

    const first_before = (app.getConst(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote).pitch;
    len = app.runDevCommand("plugin transpose 1", &response);
    try std.testing.expect(std.mem.startsWith(u8, response[0..len], "ok transposed="));
    const first_after = (app.getConst(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote).pitch;
    try std.testing.expectEqual(first_before + 1, first_after);

    len = app.runDevCommand("state", &response);
    try std.testing.expect(std.mem.indexOf(u8, response[0..len], "generation=13") != null);
    try std.testing.expect(std.mem.indexOf(u8, response[0..len], "keys=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response[0..len], "pedalguide=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response[0..len], "ink=0") != null);
}

test "development ink command creates removable score-space QA marks" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    var response: [256]u8 = undefined;

    var len = app.runDevCommand("ink dot 10 0.5", &response);
    try std.testing.expect(std.mem.startsWith(u8, response[0..len], "ok ink beat=10.000 height=0.500"));
    try std.testing.expectEqual(@as(usize, 1), app.annotations.stroke_count);
    try std.testing.expect(annotation.isScoreSpace(app.annotations.strokes[0]));
    try std.testing.expectApproxEqAbs(@as(f32, 10), app.annotations.points[0].u, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), app.annotations.points[0].v, 0.001);

    len = app.runDevCommand("ink undo", &response);
    try std.testing.expectEqualStrings("ok ink_undone=1 strokes=0", response[0..len]);
    try std.testing.expectEqual(@as(usize, 0), app.annotations.stroke_count);
    len = app.runDevCommand("ink dot 10 1.5", &response);
    try std.testing.expectEqualStrings("error ink height expects 0..1", response[0..len]);
}

test "development fingering state reports phrase-aware hands and ignores vocal guide" {
    const fixture =
        \\<score-partwise version="4.0"><work><work-title>Fingering Study</work-title></work>
        \\<part-list>
        \\<score-part id="P1"><part-name>Piano</part-name></score-part>
        \\<score-part id="P2"><part-name>Voice</part-name></score-part>
        \\</part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>5</beats><beat-type>4</beat-type></time><staves>2</staves></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<backup><duration>5</duration></backup>
        \\<note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><pitch><step>D</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><pitch><step>E</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><pitch><step>F</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><pitch><step>G</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\</measure></part>
        \\<part id="P2"><measure number="1"><attributes><divisions>1</divisions><time><beats>5</beats><beat-type>4</beat-type></time></attributes>
        \\<note><pitch><step>A</step><octave>5</octave></pitch><duration>1</duration></note>
        \\<note><pitch><step>B</step><octave>5</octave></pitch><duration>1</duration></note>
        \\<note><pitch><step>C</step><octave>6</octave></pitch><duration>1</duration></note>
        \\<note><pitch><step>D</step><octave>6</octave></pitch><duration>1</duration></note>
        \\<note><pitch><step>E</step><octave>6</octave></pitch><duration>1</duration></note>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);

    var response: [256]u8 = undefined;
    const len = app.runDevCommand("fingering state", &response);
    try std.testing.expectEqualStrings("ok left=48:5 next=50:4 right=60:1 next=62:2", response[0..len]);
}

test "authored fingering is editable through native keys and development commands" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);

    var response: [256]u8 = undefined;
    var len = app.runDevCommand("fingering set 1 5", &response);
    try std.testing.expectEqualStrings("ok note=1 fingering=5", response[0..len]);
    try std.testing.expectEqual(@as(u8, 5), (app.getConst(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote).fingering);
    len = app.runDevCommand("fingering state", &response);
    try std.testing.expect(std.mem.indexOf(u8, response[0..len], "right=60:5") != null);

    const ui_state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    ui_state.tool = .edit;
    const note = app.getMut(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote;
    note.selected = 1;
    app.key(.{ .key = '3', .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(@as(u8, 3), (app.getConst(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote).fingering);
    app.undo();
    try std.testing.expectEqual(@as(u8, 5), (app.getConst(model.Note, app.note_entities[0], app.ids.note) orelse return error.MissingNote).fingering);
    len = app.runDevCommand("fingering set 1 clear", &response);
    try std.testing.expectEqualStrings("ok note=1 fingering=0", response[0..len]);
}

test "development fingering chord reports every simultaneous piano tone" {
    const fixture =
        \\<score-partwise version="4.0"><work><work-title>Chord Fingering Study</work-title></work>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>2</beats><beat-type>4</beat-type></time><staves>2</staves></attributes>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><chord/><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><chord/><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><chord/><pitch><step>F</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<note><chord/><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><staff>1</staff></note>
        \\<backup><duration>2</duration></backup>
        \\<note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><chord/><pitch><step>E</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><pitch><step>D</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><chord/><pitch><step>F</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\<note><chord/><pitch><step>A</step><octave>3</octave></pitch><duration>1</duration><staff>2</staff></note>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);

    var response: [512]u8 = undefined;
    const len = app.runDevCommand("fingering chord", &response);
    try std.testing.expectEqualStrings(
        "ok left[3]=48:5,52:3,55:1 left-next[3]=50:5,53:3,57:1 right[3]=60:1,64:3,67:5 right-next[3]=62:1,65:3,69:5",
        response[0..len],
    );
}

test "MusicXML harmony survives app import GPU state and export re-import" {
    const fixture =
        \\<score-partwise version="4.0"><work><work-title>Harmony Study</work-title></work>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1">
        \\<attributes><divisions>4</divisions><key><fifths>-5</fifths></key><time><beats>6</beats><beat-type>4</beat-type></time></attributes>
        \\<harmony><root><root-step>B</root-step><root-alter>-1</root-alter></root><kind text="m7">minor-seventh</kind><bass><bass-step>D</bass-step><bass-alter>-1</bass-alter></bass></harmony>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>24</duration><staff>1</staff></note>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);
    try std.testing.expectEqual(@as(usize, 1), app.harmony_count);
    try std.testing.expectEqualStrings("m7", app.harmonies[0].textSlice());
    const draw_items_with_harmony = app.drawItems().len;
    app.harmony_count = 0;
    app.tick(0);
    const draw_items_without_harmony = app.drawItems().len;
    try std.testing.expect(draw_items_with_harmony > draw_items_without_harmony);
    app.harmony_count = 1;
    app.tick(0);

    var exported: [64 * 1024]u8 = undefined;
    const exported_len = try app.exportMusicXml(&exported);
    try std.testing.expect(std.mem.indexOf(u8, exported[0..exported_len], "<kind text=\"m7\">minor-seventh</kind>") != null);
    const imported_again = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer imported_again.destroy(std.heap.c_allocator);
    try imported_again.importMusicXml(exported[0..exported_len]);
    try std.testing.expectEqual(@as(usize, 1), imported_again.harmony_count);
    try std.testing.expectEqual(@as(i8, -1), imported_again.harmonies[0].bass_alter);
}

test "MusicXML sustain pedal survives app import practice and export re-import" {
    const fixture =
        \\<score-partwise version="4.0"><work><work-title>Pedal Study</work-title></work>
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1">
        \\<attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<direction placement="below"><direction-type><pedal type="start" line="yes"/></direction-type><staff>2</staff></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><staff>1</staff></note>
        \\<direction placement="below"><direction-type><pedal type="stop" line="yes"/></direction-type><staff>2</staff></direction>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);
    try std.testing.expectEqual(@as(usize, 2), app.pedal_count);
    app.emitRange(-0.001, 0.001);
    var playback_batch: [8]playback.HostEvent = undefined;
    const playback_count = app.drainPlaybackEvents(&playback_batch);
    var emitted_sustain = false;
    for (playback_batch[0..playback_count]) |event| emitted_sustain = emitted_sustain or (event.on == 4 and event.pitch == 64 and event.velocity == 127);
    try std.testing.expect(emitted_sustain);
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.cursor_beat = app.pedals[0].start_beat;
    app.midiInput(1, 0xb0, 64, 127);
    const practice = app.getConst(model.PracticeState, app.session, app.ids.practice) orelse return error.MissingPracticeState;
    try std.testing.expectEqual(@as(u32, 1), practice.pedal_changes);
    try std.testing.expectEqual(@as(u32, 0), practice.pedal_errors);
    transport.cursor_beat = app.pedals[1].start_beat + 1;
    app.midiInput(2, 0xb0, 64, 0);
    const late_practice = app.getConst(model.PracticeState, app.session, app.ids.practice) orelse return error.MissingPracticeState;
    try std.testing.expectEqual(@as(u32, 2), late_practice.pedal_changes);
    try std.testing.expectEqual(@as(u32, 1), late_practice.pedal_errors);

    var exported: [64 * 1024]u8 = undefined;
    const exported_len = try app.exportMusicXml(&exported);
    try std.testing.expect(std.mem.indexOf(u8, exported[0..exported_len], "<pedal type=\"start\" line=\"yes\"/>") != null);
    const imported_again = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer imported_again.destroy(std.heap.c_allocator);
    try imported_again.importMusicXml(exported[0..exported_len]);
    try std.testing.expectEqual(@as(usize, 2), imported_again.pedal_count);
    try std.testing.expectEqual(model.pedal_action_stop, imported_again.pedals[1].action);
}

test "MusicXML pedal change emits an ordered CC64 lift and redepress" {
    const fixture =
        \\<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list><part id="P1"><measure number="1">
        \\<attributes><divisions>4</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        \\<direction placement="below"><direction-type><pedal type="start" line="yes"/></direction-type><sound damper-pedal="56.693"/><staff>2</staff></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><staff>1</staff></note>
        \\<direction placement="below"><direction-type><pedal type="change" line="yes"/></direction-type><sound damper-pedal="56.693"/><staff>2</staff></direction>
        \\</measure></part></score-partwise>
    ;
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMusicXml(fixture);
    try std.testing.expectEqual(@as(usize, 2), app.pedal_count);
    app.emitRange(0.9, 1.1);
    var events: [4]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    var controller_values: [2]u8 = undefined;
    var controller_count: usize = 0;
    for (events[0..count]) |event| {
        if (event.on != 4 or event.pitch != 64) continue;
        controller_values[controller_count] = event.velocity;
        controller_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), controller_count);
    try std.testing.expectEqual(@as(u8, 0), controller_values[0]);
    try std.testing.expectEqual(@as(u8, 72), controller_values[1]);
}

test "Standard MIDI pedal automation reaches playback and document bounds" {
    const fixture = [_]u8{
        'M',  'T',  'h',  'd',  0,    0,  0, 6,    0,    0,    0,  1,   1,    0xe0,
        'M',  'T',  'r',  'k',  0,    0,  0, 22,   0x00, 0xb0, 64, 127, 0x00, 0x90,
        60,   100,  0x83, 0x60, 0x80, 60, 0, 0x8f, 0x00, 0xb0, 64, 0,   0x00, 0xff,
        0x2f, 0x00,
    };
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.importMidi(&fixture);
    try std.testing.expectEqual(@as(usize, 2), app.pedal_count);
    try std.testing.expectEqual(model.pedal_action_start, app.pedals[0].action);
    try std.testing.expectEqual(model.pedal_action_stop, app.pedals[1].action);
    const bounds = app.getConst(model.PlaybackBounds, app.session, app.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
    try std.testing.expectApproxEqAbs(@as(f32, 5), bounds.end_beat, 0.001);

    app.emitRange(-0.001, 0.001);
    app.emitRange(4.9, 5.0);
    var events: [16]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    var saw_down = false;
    var saw_up = false;
    for (events[0..count]) |event| {
        if (event.on != 4 or event.pitch != 64) continue;
        saw_down = saw_down or event.velocity == 127;
        saw_up = saw_up or event.velocity == 0;
    }
    try std.testing.expect(saw_down and saw_up);
}

test "app Standard MIDI export re-imports notes metadata and pedal tail" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const source =
        \\<?xml version="1.0"?><score-partwise version="4.0">
        \\<work><work-title>MIDI Exchange</work-title></work><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>-2</fifths></key><time><beats>3</beats><beat-type>4</beat-type></time><staves>2</staves></attributes>
        \\<direction><sound tempo="96"/></direction><direction><direction-type><pedal type="start" line="yes"/></direction-type></direction>
        \\<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><staff>1</staff></note>
        \\<direction><offset>2</offset><direction-type><pedal type="stop" line="yes"/></direction-type></direction>
        \\</measure></part></score-partwise>
    ;
    try app.importMusicXml(source);
    const expected_end = app.scoreEndBeat();
    var encoded: [8192]u8 = undefined;
    const encoded_len = try app.exportMidi(&encoded);
    const imported = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer imported.destroy(std.heap.c_allocator);
    try imported.importMidi(encoded[0..encoded_len]);
    const meta = imported.getConst(model.DocumentMeta, imported.session, imported.ids.document_meta) orelse return error.MissingDocumentMeta;
    const transport = imported.getConst(model.Transport, imported.session, imported.ids.transport) orelse return error.MissingTransport;
    try std.testing.expectEqualStrings("MIDI Exchange", meta.titleSlice());
    try std.testing.expectEqual(@as(u8, 3), meta.beats_per_measure);
    try std.testing.expectEqual(@as(u8, 4), meta.beat_unit);
    try std.testing.expectEqual(@as(i8, -2), meta.key_fifths);
    try std.testing.expectApproxEqAbs(@as(f32, 96), transport.tempo_bpm, 0.01);
    try std.testing.expectEqual(@as(usize, 2), imported.pedal_count);
    try std.testing.expectApproxEqAbs(expected_end, imported.scoreEndBeat(), 0.001);
}

test "captured take exports human MIDI timing through the accessible GPU action" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.take.tempo_bpm = 100;
    app.take.pushMidi(.{ .time_ns = 2_000_000_000, .sequence = 0, .kind = 0x90, .channel = 3, .data1 = 65, .data2 = 88 });
    app.take.pushMidi(.{ .time_ns = 2_300_000_000, .sequence = 1, .kind = 0x80, .channel = 3, .data1 = 65, .data2 = 0 });
    var output: [4096]u8 = undefined;
    const length = try app.exportTakeMidi(&output);
    const report = try midi.parse(output[0..length]);
    try std.testing.expectEqual(@as(usize, 1), report.note_count);
    try std.testing.expectEqual(@as(u8, 3), report.notes[0].voice);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), report.notes[0].duration_beats, 0.001);

    var found_accessible_export = false;
    for (app.accessibilityItems()) |item| found_accessible_export = found_accessible_export or item.id == accessibility.Id.export_take;
    try std.testing.expect(found_accessible_export);
    app.accessibilityActivate(accessibility.Id.export_take);
    try std.testing.expectEqual(platform.HostRequest.export_take, app.takeHostRequest());
}

test "recorded take replay sends pedal controllers instead of false note-offs" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.take.pushMidi(.{ .time_ns = 1_000, .sequence = 0, .kind = 0xb0, .channel = 0, .data1 = 64, .data2 = 100 });
    app.take.pushMidi(.{ .time_ns = 2_000, .sequence = 1, .kind = 0x90, .channel = 0, .data1 = 60, .data2 = 90 });
    app.beginTakeReplay();
    app.advanceTakeReplay(1);
    var events: [8]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u8, 4), events[0].on);
    try std.testing.expectEqual(@as(u8, 64), events[0].pitch);
    try std.testing.expectEqual(@as(u8, 100), events[0].velocity);
    try std.testing.expectEqual(@as(u8, 1), events[1].on);
}

test "count-in produces accented metronome host events before notation" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    app.tick(1.0 / 60.0);
    var events: [16]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    try std.testing.expect(count >= 1);
    var found_accent = false;
    for (events[0..count]) |event| found_accent = found_accent or (event.on == 3 and event.velocity == 127);
    try std.testing.expect(found_accent);
    try std.testing.expect(app.transportSnapshot().cursor_beat < 0);
}

test "multiple Flecs system queries share the hot-reload plugin ABI" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try std.testing.expectEqual(@as(usize, 2), app.system_count);
    const practice = app.getMut(model.PracticeState, app.session, app.ids.practice) orelse return error.MissingPracticeState;
    practice.confidence = 1;
    app.tick(0.1);
    try std.testing.expect(practice.confidence < 1);
}

test "hot reload rejects glyph metadata for a different host atlas" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    var mismatched = builtin_systems.descriptor().*;
    mismatched.glyph_atlas_hash ^= 1;
    try std.testing.expectError(error.GlyphAtlasMismatch, app.applySystemPlugin(&mismatched));
}

test "bundled public-domain score library imports offline" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    try app.loadBundledScore(0);
    try std.testing.expect(app.note_count > 20);
    try app.loadBundledScore(1);
    try std.testing.expect(app.note_count > 100);
    try std.testing.expect(app.pedal_count > 20);
    const meta = app.getConst(model.DocumentMeta, app.session, app.ids.document_meta) orelse return error.MissingDocumentMeta;
    try std.testing.expect(std.mem.indexOf(u8, meta.titleSlice(), "Elise") != null);
}

test "importing a score resets document-scoped transport state" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.cursor_beat = 9;
    transport.playing = 1;
    transport.recording = 1;
    transport.loop_enabled = 1;
    transport.loop_start = 8;
    try app.importMusicXml(bundled_beethoven_fur_elise);
    const imported = app.transportSnapshot();
    try std.testing.expectEqual(@as(f32, 0), imported.cursor_beat);
    try std.testing.expectEqual(@as(u32, 0), imported.playing);
    try std.testing.expectEqual(@as(u32, 0), imported.recording);
    try std.testing.expectEqual(@as(u32, 0), imported.loop_enabled);
    try std.testing.expectEqual(@as(f32, 0), imported.loop_start);
    try std.testing.expect(imported.loop_end > 4);
}

test "loop button isolates the current meter-aware measure" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.measures[0] = .{ .start_beat = 0, .duration_beats = 4, .number = 1, .beats = 4, .beat_unit = 4 };
    app.measures[1] = .{ .start_beat = 4, .duration_beats = 2, .number = 2, .beats = 2, .beat_unit = 4 };
    app.measures[2] = .{ .start_beat = 6, .duration_beats = 4, .number = 3, .beats = 4, .beat_unit = 4 };
    app.measure_count = 3;
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.cursor_beat = 5.25;
    const button = ui.Layout.calculate(1280, 800, true).loop_toggle;
    app.pointer(.{
        .kind = .down,
        .pointer_type = .mouse,
        .id = 1,
        .buttons = 1,
        .x = button.x + button.width * 0.5,
        .y = button.y + button.height * 0.5,
        .pressure = 1,
        .tilt_x = 0,
        .tilt_y = 0,
        .scroll_x = 0,
        .scroll_y = 0,
    });
    try std.testing.expectEqual(@as(u32, 1), transport.loop_enabled);
    try std.testing.expectEqual(@as(f32, 4), transport.loop_start);
    try std.testing.expectEqual(@as(f32, 6), transport.loop_end);
}

test "development seek outside an active loop leaves the stale loop" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.loop_enabled = 1;
    transport.loop_start = 8;
    transport.loop_end = 12;
    var response: [256]u8 = undefined;

    _ = app.runDevCommand("seek 10", &response);
    try std.testing.expectEqual(@as(u32, 1), transport.loop_enabled);

    const response_len = app.runDevCommand("seek 20", &response);
    try std.testing.expectEqual(@as(u32, 0), transport.loop_enabled);
    try std.testing.expect(std.mem.indexOf(u8, response[0..response_len], "loop=0") != null);
}

test "metronome accents every authored variable-meter barline" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.measures[0] = .{ .start_beat = 0, .duration_beats = 4, .number = 1, .beats = 4, .beat_unit = 4 };
    app.measures[1] = .{ .start_beat = 4, .duration_beats = 2, .number = 2, .beats = 2, .beat_unit = 4 };
    app.measure_count = 2;
    app.emitMetronomeRange(3.9, 4.1, .{ .metronome_enabled = 1 });
    var events: [4]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 3), events[0].on);
    try std.testing.expectEqual(@as(u8, 127), events[0].velocity);
}

test "page navigation preserves the Flecs document and moves the GPU score window" {
    const app = try App.create(std.heap.c_allocator, 1024, 768, 2);
    defer app.destroy(std.heap.c_allocator);
    try std.testing.expect(app.scoreEndBeat() > 31);
    const initial_state = app.getConst(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    const meta = app.getConst(model.DocumentMeta, app.session, app.ids.document_meta) orelse return error.MissingDocumentMeta;
    const expected_start = app.scorePageForState(initial_state, meta, initial_state.view_start_beat).endBeat();
    app.key(.{ .key = 34, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    const state = app.getConst(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    try std.testing.expectEqual(expected_start, state.view_start_beat);
    try std.testing.expect(state.view_start_beat > 0);
    try std.testing.expect(app.drawItems().len > 100);
}

test "paged score responds to visible controls wheel gestures and reading arrows" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    const layout = ui.Layout.calculate(state.viewport_width, state.viewport_height, state.keyboard_visible != 0);

    app.pointer(.{ .kind = .down, .pointer_type = .mouse, .id = 1, .buttons = 1, .x = layout.page_next.x + 8, .y = layout.page_next.y + 8, .pressure = 1, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    try std.testing.expect(state.view_start_beat > 0);
    const second_page = state.view_start_beat;

    app.pointer(.{ .kind = .down, .pointer_type = .mouse, .id = 1, .buttons = 1, .x = layout.page_previous.x + 8, .y = layout.page_previous.y + 8, .pressure = 1, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    try std.testing.expectEqual(@as(f32, 0), state.view_start_beat);

    app.pointer(.{ .kind = .scroll, .pointer_type = .mouse, .id = 1, .buttons = 0, .x = layout.stage.x + layout.stage.width * 0.5, .y = layout.stage.y + layout.stage.height * 0.5, .pressure = 0, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = -1 });
    try std.testing.expectEqual(second_page, state.view_start_beat);
    app.tick(0.1);
    app.tick(0.1);
    app.tick(0.1);
    app.pointer(.{ .kind = .scroll, .pointer_type = .mouse, .id = 1, .buttons = 0, .x = layout.stage.x + layout.stage.width * 0.5, .y = layout.stage.y + layout.stage.height * 0.5, .pressure = 0, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 1 });
    try std.testing.expectEqual(@as(f32, 0), state.view_start_beat);

    app.key(.{ .key = 262, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(second_page, state.view_start_beat);
    state.tool = .edit;
    app.key(.{ .key = 262, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(second_page, state.view_start_beat);
}

test "score viewport modes navigate at page system and spread granularity" {
    const app = try App.create(std.heap.c_allocator, 1440, 900, 2);
    defer app.destroy(std.heap.c_allocator);
    const state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    var response: [256]u8 = undefined;

    _ = app.runDevCommand("view continuous", &response);
    _ = app.runDevCommand("page next", &response);
    const continuous_start = state.view_start_beat;
    try std.testing.expectEqual(model.ScoreViewMode.continuous, state.score_view_mode);
    try std.testing.expect(continuous_start > 0);

    state.view_start_beat = 0;
    _ = app.runDevCommand("view paged", &response);
    _ = app.runDevCommand("page next", &response);
    const paged_start = state.view_start_beat;
    try std.testing.expect(paged_start > continuous_start);

    state.view_start_beat = 0;
    _ = app.runDevCommand("view spread", &response);
    _ = app.runDevCommand("page next", &response);
    try std.testing.expect(state.view_start_beat >= paged_start);

    _ = app.runDevCommand("zoom 0.75", &response);
    _ = app.runDevCommand("focus on", &response);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), state.zoom, 0.001);
    try std.testing.expectEqual(@as(u32, 1), state.focus_score);
    const focused = ui.Layout.calculateForState(state);
    try std.testing.expectEqual(@as(f32, 0), focused.top.height);
    try std.testing.expectEqual(@as(f32, 0), focused.keyboard_panel.height);
    try std.testing.expect(focused.stage.height > 800);
}

test "spread annotations attach to the clicked page in score coordinates" {
    const app = try App.create(std.heap.c_allocator, 1440, 900, 2);
    defer app.destroy(std.heap.c_allocator);
    const state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    state.tool = .annotate;
    state.keyboard_visible = 0;
    state.score_view_mode = .spread;
    state.zoom = 0.75;
    const layout = ui.Layout.calculateForState(state);
    const gap: f32 = 12;
    const pane_width = (layout.stage.width - gap) * 0.5;
    const pane = ui.Rect{ .x = layout.stage.x + pane_width + gap, .y = layout.stage.y, .width = pane_width, .height = layout.stage.height };
    const target_x = pane.x + pane.width * 0.25;
    const target_y = pane.y + pane.height * 0.4;
    const screen_x = pane.x + pane.width * 0.5 + (target_x - (pane.x + pane.width * 0.5)) * state.zoom;
    const screen_y = pane.y + pane.height * 0.5 + (target_y - (pane.y + pane.height * 0.5)) * state.zoom;
    const meta = app.getConst(model.DocumentMeta, app.session, app.ids.document_meta) orelse return error.MissingDocumentMeta;
    const hit = app.scoreHitContext(state, meta, layout.stage, screen_x, screen_y);
    const expected = app.annotationPointForHit(state, hit, 0.5);
    app.pointer(.{ .kind = .down, .pointer_type = .pen, .id = 9, .buttons = 1, .x = screen_x, .y = screen_y, .pressure = 0.5, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    app.pointer(.{ .kind = .up, .pointer_type = .pen, .id = 9, .buttons = 0, .x = screen_x, .y = screen_y, .pressure = 0, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    try std.testing.expectEqual(@as(usize, 1), app.annotations.stroke_count);
    try std.testing.expect(annotation.isScoreSpace(app.annotations.strokes[0]));
    try std.testing.expectEqual(hit.page.page_index, annotation.pageIndex(app.annotations.strokes[0]));
    try std.testing.expectApproxEqAbs(expected.u, app.annotations.points[0].u, 0.001);
    try std.testing.expectApproxEqAbs(expected.v, app.annotations.points[0].v, 0.001);
}

test "clicking the GPU tempo readout edits and validates BPM" {
    const app = try App.create(std.heap.c_allocator, 1440, 900, 2);
    defer app.destroy(std.heap.c_allocator);
    const state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    const layout = ui.Layout.calculate(state.viewport_width, state.viewport_height, state.keyboard_visible != 0);
    const click = platform.PointerEvent{
        .kind = .down,
        .pointer_type = .mouse,
        .id = 1,
        .buttons = 1,
        .x = layout.tempo_value.x + layout.tempo_value.width * 0.5,
        .y = layout.tempo_value.y + layout.tempo_value.height * 0.5,
        .pressure = 1,
        .tilt_x = 0,
        .tilt_y = 0,
        .scroll_x = 0,
        .scroll_y = 0,
    };
    app.pointer(click);
    try std.testing.expectEqual(@as(u32, 1), state.tempo_editing);
    for ([_]u32{ '1', '4', '7', 257 }) |key_code| app.key(.{ .key = key_code, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(@as(u32, 0), state.tempo_editing);
    try std.testing.expectApproxEqAbs(@as(f32, 147), app.transportSnapshot().tempo_bpm, 0.001);

    app.pointer(click);
    for ([_]u32{ '2', '9', 257 }) |key_code| app.key(.{ .key = key_code, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(@as(u32, 2), state.tempo_editing);
    try std.testing.expectApproxEqAbs(@as(f32, 147), app.transportSnapshot().tempo_bpm, 0.001);
    app.key(.{ .key = 256, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    try std.testing.expectEqual(@as(u32, 0), state.tempo_editing);
}

test "MusicXML eighth pulse drives quarter-note transport time" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const source =
        \\<score-partwise version="4.0">
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<direction><direction-type><metronome><beat-unit>eighth</beat-unit><per-minute>147</per-minute></metronome></direction-type><sound tempo="73.5"/></direction>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>16</duration></note>
        \\</measure></part></score-partwise>
    ;
    try app.importMusicXml(source);
    const meta = app.getConst(model.DocumentMeta, app.session, app.ids.document_meta) orelse return error.MissingDocumentMeta;
    const bounds = app.getConst(model.PlaybackBounds, app.session, app.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    try std.testing.expectEqual(@as(u8, 8), meta.tempo_beat_unit);
    try std.testing.expectEqual(@as(u32, 8), bounds.tempo_beat_unit);
    try std.testing.expectApproxEqAbs(@as(f32, 147), transport.tempo_bpm, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), model.effectiveTempoAt(bounds, transport, 0), 0.001);
    transport.playing = 1;
    app.tick(0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1225), app.transportSnapshot().cursor_beat, 0.0001);
}

test "MusicXML quarter 147 never halves transport playback" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const source =
        \\<score-partwise version="4.0">
        \\<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        \\<part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
        \\<direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>147</per-minute></metronome></direction-type><sound tempo="147"/></direction>
        \\<note><pitch><step>D</step><alter>-1</alter><octave>4</octave></pitch><duration>16</duration></note>
        \\</measure></part></score-partwise>
    ;
    try app.importMusicXml(source);
    const meta = app.getConst(model.DocumentMeta, app.session, app.ids.document_meta) orelse return error.MissingDocumentMeta;
    const bounds = app.getConst(model.PlaybackBounds, app.session, app.ids.playback_bounds) orelse return error.MissingPlaybackBounds;
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    try std.testing.expectEqual(@as(u8, 4), meta.tempo_beat_unit);
    try std.testing.expectEqual(@as(u32, 4), bounds.tempo_beat_unit);
    try std.testing.expectApproxEqAbs(@as(f32, 147), transport.tempo_bpm, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 147), model.effectiveTempoAt(bounds, transport, 0), 0.001);
    transport.playing = 1;
    app.tick(0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.245), app.transportSnapshot().cursor_beat, 0.0001);
}

test "variable-meter page navigation and annotation anchors use authored systems" {
    const app = try App.create(std.heap.c_allocator, 1024, 768, 2);
    defer app.destroy(std.heap.c_allocator);
    app.measures[0] = .{ .start_beat = 0, .duration_beats = 4, .number = 1, .beats = 4, .beat_unit = 4 };
    app.measures[1] = .{ .start_beat = 4, .duration_beats = 4, .number = 2, .beats = 4, .beat_unit = 4 };
    app.measures[2] = .{ .start_beat = 8, .duration_beats = 2, .number = 3, .beats = 2, .beat_unit = 4 };
    app.measures[3] = .{ .start_beat = 10, .duration_beats = 4, .number = 4, .beats = 4, .beat_unit = 4 };
    app.measures[4] = .{ .start_beat = 14, .duration_beats = 3, .number = 5, .beats = 3, .beat_unit = 4 };
    app.measures[5] = .{ .start_beat = 17, .duration_beats = 5, .number = 6, .beats = 5, .beat_unit = 4 };
    app.measures[6] = .{ .start_beat = 22, .duration_beats = 2, .number = 7, .beats = 2, .beat_unit = 4 };
    app.measure_count = 7;

    var response: [256]u8 = undefined;
    var response_len = app.runDevCommand("page next", &response);
    try std.testing.expectEqualStrings("ok page=2 start=8.000 end=17.000", response[0..response_len]);
    const state = app.getMut(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    try std.testing.expectEqual(@as(f32, 8), state.view_start_beat);
    state.tool = .annotate;
    state.keyboard_visible = 0;
    const stage = ui.Layout.calculate(state.viewport_width, state.viewport_height, false).stage;
    app.pointer(.{ .kind = .down, .pointer_type = .pen, .id = 7, .buttons = 1, .x = stage.x + stage.width * 0.5, .y = stage.y + stage.height * 0.5, .pressure = 0.7, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    app.pointer(.{ .kind = .up, .pointer_type = .pen, .id = 7, .buttons = 0, .x = stage.x + stage.width * 0.5, .y = stage.y + stage.height * 0.5, .pressure = 0, .tilt_x = 0, .tilt_y = 0, .scroll_x = 0, .scroll_y = 0 });
    try std.testing.expectEqual(@as(usize, 1), app.annotations.stroke_count);
    // Hiding the keyboard gives the page enough height for all three authored
    // systems, so the ink correctly reflows onto page index zero.
    try std.testing.expect(annotation.isScoreSpace(app.annotations.strokes[0]));
    try std.testing.expectEqual(@as(u32, 0), annotation.pageIndex(app.annotations.strokes[0]));

    response_len = app.runDevCommand("page previous", &response);
    try std.testing.expectEqualStrings("ok page=1 start=0.000 end=24.000", response[0..response_len]);
    try std.testing.expectEqual(@as(f32, 0), state.view_start_beat);

    response_len = app.runDevCommand("page sideways", &response);
    try std.testing.expectEqualStrings("error page expects next or previous", response[0..response_len]);
}

test "GPU top bar exposes MusicXML export action" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const expected = ui.Layout.calculate(1280, 800, true).export_score;
    var found = false;
    for (app.drawItems()) |item| {
        if (@abs(item.rect[0] - expected.x) < 0.1 and @abs(item.rect[1] - expected.y) < 0.1 and @abs(item.rect[2] - expected.width) < 0.1) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "edited Flecs score round-trips through industry MusicXML" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const output = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(output);
    const length = try app.exportMusicXml(output);
    const report = try musicxml.parse(output[0..length]);
    try std.testing.expectEqual(app.note_count, report.note_count);
    try std.testing.expectEqualStrings("Piano practice study", report.titleSlice());
    try std.testing.expectEqual(@as(f32, 72), report.tempo_bpm);
}
