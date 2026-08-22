const std = @import("std");
const model = @import("model.zig");
const ui = @import("ui.zig");
const render = @import("../render/packet.zig");
const platform = @import("../platform/api.zig");
const recording = @import("recording.zig");
const hot = @import("../hot_reload/abi.zig");
const builtin_systems = @import("../systems/plugin.zig");
const musicxml = @import("import/musicxml.zig");
const midi = @import("import/midi.zig");
const mxl = @import("import/mxl.zig");
const practice_assessment = @import("practice.zig");
const command = @import("command.zig");
const annotation = @import("annotation.zig");
const accessibility = @import("accessibility.zig");
const native_format = @import("persistence/native.zig");
const playback = @import("playback/timeline.zig");

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
    notice_deadline_seconds: f32 = 0,
    last_observed_pitch: u8 = 255,
    last_observation_seconds: f32 = -10,

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
        };
        if (ids.note == 0 or ids.transport == 0 or ids.ui_state == 0 or ids.practice == 0 or ids.document_meta == 0) return error.ComponentRegistrationFailed;

        const session = createEntity(world, "Score.Session");
        var transport: model.Transport = .{};
        var ui_state: model.UiState = .{ .viewport_width = width, .viewport_height = height, .pixel_ratio = pixel_ratio };
        var practice: model.PracticeState = .{};
        var meta: model.DocumentMeta = .{};
        meta.setTitle("ORIGINAL NOTATION STUDY");
        meta.setCreator("SCORE FIXTURE");
        c.ecs_set_id(world, session, ids.transport, @sizeOf(model.Transport), &transport);
        c.ecs_set_id(world, session, ids.ui_state, @sizeOf(model.UiState), &ui_state);
        c.ecs_set_id(world, session, ids.practice, @sizeOf(model.PracticeState), &practice);
        c.ecs_set_id(world, session, ids.document_meta, @sizeOf(model.DocumentMeta), &meta);

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
                if (after.cursor_beat < state.view_start_beat or after.cursor_beat >= state.view_start_beat + 16) {
                    state.view_start_beat = @floor(after.cursor_beat / 16) * 16;
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
            const end = self.scoreEndBeat();
            state.view_start_beat = std.math.clamp(state.view_start_beat + event.scroll_y * 0.04, 0, @max(0, end - 1));
        } else if (event.kind == .down) {
            const layout = ui.Layout.calculate(state.viewport_width, state.viewport_height);
            const transport = self.getMut(model.Transport, self.session, self.ids.transport) orelse return;
            if (layout.play.contains(event.x, event.y)) {
                self.toggleTransport(transport);
            } else if (layout.record.contains(event.x, event.y)) {
                transport.recording = if (transport.recording == 0) 1 else 0;
                if (transport.recording != 0) {
                    self.take.reset(@intFromFloat(self.time_seconds * std.time.ns_per_s));
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
                    const measure_beats: f32 = @floatFromInt(@max(1, meta.beats_per_measure));
                    transport.loop_start = @floor(@max(0, transport.cursor_beat) / measure_beats) * measure_beats;
                    transport.loop_end = @min(self.scoreEndBeat(), transport.loop_start + measure_beats);
                    if (transport.loop_end <= transport.loop_start) transport.loop_end = transport.loop_start + measure_beats;
                    transport.loop_enabled = 1;
                } else {
                    transport.loop_enabled = 0;
                }
            } else if (layout.metronome_toggle.contains(event.x, event.y)) {
                transport.metronome_enabled = if (transport.metronome_enabled == 0) 1 else 0;
            } else if (layout.tempo_minus.contains(event.x, event.y)) {
                transport.tempo_bpm = @max(30, transport.tempo_bpm - 1);
            } else if (layout.tempo_plus.contains(event.x, event.y)) {
                transport.tempo_bpm = @min(240, transport.tempo_bpm + 1);
            } else if (layout.input_quick.contains(event.x, event.y)) {
                self.host_request = .choose_microphone;
            } else if (layout.export_score.contains(event.x, event.y)) {
                self.host_request = .export_score;
            } else if (layout.replay_take.contains(event.x, event.y)) {
                self.beginTakeReplay();
                self.host_request = .replay_take;
            } else if (layout.input_setup.contains(event.x, event.y)) {
                self.host_request = .choose_microphone;
            } else {
                if (layout.stage.contains(event.x, event.y)) switch (state.tool) {
                    .edit => self.insertNoteAt(event.x, event.y, layout.stage),
                    .read, .practice => self.selectNearestNote(event.x, event.y, layout.stage),
                    .annotate => self.annotations.begin(annotationPoint(event, layout.stage, self.time_seconds), @intFromFloat(@floor(state.view_start_beat / 16))),
                };
                for (layout.tool_buttons, 0..) |button, index| {
                    if (button.contains(event.x, event.y)) state.tool = @enumFromInt(index);
                }
            }
            c.ecs_modified_id(self.world, self.session, self.ids.transport);
        } else if (event.kind == .move and state.tool == .annotate and self.annotations.active != null) {
            const layout = ui.Layout.calculate(state.viewport_width, state.viewport_height);
            if (layout.stage.contains(event.x, event.y)) self.annotations.append(annotationPoint(event, layout.stage, self.time_seconds));
        } else if ((event.kind == .up or event.kind == .cancel) and self.annotations.active != null) self.annotations.end();
        c.ecs_modified_id(self.world, self.session, self.ids.ui_state);
        self.buildFrame();
    }

    pub fn key(self: *App, event: platform.KeyEvent) void {
        if (event.pressed == 0 or event.repeat != 0) return;
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
        if (event.key == 34 or event.key == 267) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.view_start_beat = @min(@floor(state.view_start_beat / 16) * 16 + 16, @max(0, self.scoreEndBeat() - 1));
        }
        if (event.key == 33 or event.key == 266) {
            const state = self.getMut(model.UiState, self.session, self.ids.ui_state) orelse return;
            state.view_start_beat = @max(0, @floor(state.view_start_beat / 16) * 16 - 16);
        }
        if (event.key == 8 or event.key == 46 or event.key == 261) self.deleteSelectedNote();
        if (event.key == 38 or event.key == 265) self.moveSelectedNote(1, 0);
        if (event.key == 40 or event.key == 264) self.moveSelectedNote(-1, 0);
        if (event.key == 37 or event.key == 263) self.moveSelectedNote(0, -0.25);
        if (event.key == 39 or event.key == 262) self.moveSelectedNote(0, 0.25);
        self.buildFrame();
    }

    pub fn drawItems(self: *const App) []const render.DrawItem {
        return self.packet.slice();
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
        const meta = self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        meta.* = .{};
        meta.setTitle(if (report.title_len != 0) report.titleSlice() else "IMPORTED MUSICXML SCORE");
        meta.setCreator(report.creatorSlice());
        meta.source_kind = 1;
        meta.import_warnings = report.skipped_notes + report.approximations;
        meta.beats_per_measure = report.beats_per_measure;
        meta.beat_unit = report.beat_unit;
        meta.key_fifths = report.key_fifths;
        const transport_state = self.getMut(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        transport_state.tempo_bpm = report.tempo_bpm;
        transport_state.cursor_beat = 0;
        transport_state.loop_end = self.scoreEndBeat();
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        self.buildFrame();
    }

    pub fn importMidi(self: *App, source: []const u8) !void {
        const report = try midi.parse(source);
        try self.replaceNotes(report.notes[0..report.note_count]);
        self.resetDocumentExtras();
        const meta = self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta;
        meta.* = .{};
        meta.setTitle(if (report.title_len != 0) report.titleSlice() else "IMPORTED MIDI PERFORMANCE");
        meta.setCreator("QUANTIZATION REVIEW");
        meta.source_kind = 2;
        const transport_state = self.getMut(model.Transport, self.session, self.ids.transport) orelse return error.MissingTransport;
        transport_state.tempo_bpm = report.tempo_bpm;
        transport_state.cursor_beat = 0;
        transport_state.loop_end = self.scoreEndBeat();
        c.ecs_modified_id(self.world, self.session, self.ids.document_meta);
        c.ecs_modified_id(self.world, self.session, self.ids.transport);
        self.buildFrame();
    }

    pub fn importMxl(self: *App, source: []const u8) !void {
        const document = try mxl.extract(std.heap.c_allocator, source);
        defer std.heap.c_allocator.free(document);
        try self.importMusicXml(document);
    }

    fn resetDocumentExtras(self: *App) void {
        self.annotations = .{};
        self.take = .{};
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
        if ((status & 0xf0) == 0x90 and data2 != 0) self.assessMidiNote(data1);
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
        snapshot.annotations = self.annotations;
        snapshot.take = self.take;
        return native_format.encode(snapshot, output);
    }

    pub fn deserialize(self: *App, source: []const u8) !void {
        const snapshot = try std.heap.c_allocator.create(native_format.Snapshot);
        defer std.heap.c_allocator.destroy(snapshot);
        try native_format.decode(source, snapshot);
        try self.replaceNotes(snapshot.notes[0..snapshot.note_count]);
        (self.getMut(model.DocumentMeta, self.session, self.ids.document_meta) orelse return error.MissingDocumentMeta).* = snapshot.meta;
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

    /// Installs or replaces a development module at a frame boundary. Flecs
    /// component storage remains untouched. Query changes recreate only the
    /// affected system entity; callback-only changes are pointer swaps.
    pub fn applySystemPlugin(self: *App, plugin: *const hot.PluginDescriptor) !void {
        if (!hot.compatible(plugin)) return error.IncompatiblePlugin;
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

    fn insertNoteAt(self: *App, x: f32, y: f32, stage: ui.Rect) void {
        if (self.note_count == self.note_entities.len) return;
        const geometry = ui.ScoreGeometry.calculate(stage);
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const system_index: u8 = if (y < (geometry.treble_y[0] + geometry.bass_y[0] + 48 + geometry.treble_y[1]) / 3) 0 else 1;
        const treble_distance = @abs(y - (geometry.treble_y[system_index] + 24));
        const bass_distance = @abs(y - (geometry.bass_y[system_index] + 24));
        const staff: u8 = if (bass_distance < treble_distance) 1 else 0;
        const beat_in_system = std.math.clamp((x - geometry.music_x) / geometry.beat_width, 0, 7.75);
        const quantized = @round(beat_in_system * 4) / 4 + @as(f32, @floatFromInt(system_index)) * 8;
        var pitch: u8 = 21;
        var pitch_distance: f32 = std.math.floatMax(f32);
        for (21..109) |candidate_value| {
            const candidate: u8 = @intCast(candidate_value);
            const candidate_note = model.Note{ .stable_id = 0, .start_beat = state.view_start_beat + quantized, .duration_beats = 0.5, .pitch = candidate, .velocity = 88, .staff = staff, .voice = 0 };
            const position = ui.notePosition(candidate_note, geometry, state.view_start_beat) orelse continue;
            const distance = @abs(position.y - y);
            if (distance < pitch_distance) {
                pitch_distance = distance;
                pitch = candidate;
            }
        }
        const note = model.Note{ .stable_id = self.next_note_id, .start_beat = state.view_start_beat + quantized, .duration_beats = 0.5, .pitch = pitch, .velocity = 88, .staff = staff, .voice = 0, .selected = 1 };
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

    fn selectNearestNote(self: *App, x: f32, y: f32, stage: ui.Rect) void {
        const state = self.getConst(model.UiState, self.session, self.ids.ui_state) orelse return;
        const geometry = ui.ScoreGeometry.calculate(stage);
        var best_entity: c.ecs_entity_t = 0;
        var best_distance_squared: f32 = std.math.floatMax(f32);
        for (self.note_entities[0..self.note_count]) |entity| {
            const note = self.getMut(model.Note, entity, self.ids.note) orelse continue;
            note.selected = 0;
            const position = ui.notePosition(note.*, geometry, state.view_start_beat) orelse continue;
            const dx = position.x - x;
            const dy = position.y - y;
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
        return result;
    }

    fn toggleTransport(self: *App, transport: *model.Transport) void {
        if (transport.playing != 0) {
            transport.playing = 0;
            return;
        }
        if (transport.cursor_beat <= 0.001 and transport.count_in_bars != 0) {
            const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
            transport.cursor_beat = -@as(f32, @floatFromInt(transport.count_in_bars * @max(1, meta.beats_per_measure)));
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
            const distance = @abs(note.start_beat - transport_state.cursor_beat);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = note.*;
            }
        }
        const expected = nearest orelse return;
        const milliseconds_per_beat = 60_000.0 / transport_state.tempo_bpm;
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
        ui.draw(&self.packet, state, transport, practice, meta, notes[0..len], &self.annotations, self.time_seconds);
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
    }

    fn extractPlayback(self: *App, before: model.Transport, after: model.Transport) void {
        if (after.playing == 0) {
            if (self.was_playing) self.pushPlayback(.{ .pitch = 0, .velocity = 0, .channel = 0, .on = 2 });
            self.was_playing = false;
            self.previous_cursor = after.cursor_beat;
            return;
        }
        var start = before.cursor_beat;
        if (!self.was_playing) start -= 0.0001;
        if (after.cursor_beat < start) {
            self.pushPlayback(.{ .pitch = 0, .velocity = 0, .channel = 0, .on = 2 });
            self.emitRange(start, before.loop_end);
            self.emitMetronomeRange(start, before.loop_end - 0.0001, after);
            start = before.loop_start - 0.0001;
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
    }

    fn emitMetronomeRange(self: *App, start: f32, end: f32, transport: model.Transport) void {
        if (transport.metronome_enabled == 0 or end < start) return;
        const meta = self.getConst(model.DocumentMeta, self.session, self.ids.document_meta) orelse return;
        const beats_per_measure: i64 = @max(1, meta.beats_per_measure);
        var beat_index: i64 = @as(i64, @intFromFloat(@floor(start))) + 1;
        while (@as(f32, @floatFromInt(beat_index)) <= end + 0.00001) : (beat_index += 1) {
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
            const on: u8 = if (event.kind == 0x90 and event.data2 != 0) 1 else 0;
            self.pushPlayback(.{ .pitch = event.data1, .velocity = event.data2, .channel = event.channel, .on = on });
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

fn createEntity(world: *c.ecs_world_t, name: ?[*:0]const u8) c.ecs_entity_t {
    var descriptor: c.ecs_entity_desc_t = std.mem.zeroes(c.ecs_entity_desc_t);
    descriptor.name = name;
    return c.ecs_entity_init(world, &descriptor);
}

fn annotationPoint(event: platform.PointerEvent, stage: ui.Rect, time_seconds: f32) annotation.Point {
    return .{
        .u = std.math.clamp((event.x - stage.x) / stage.width, 0, 1),
        .v = std.math.clamp((event.y - stage.y) / stage.height, 0, 1),
        .pressure = if (event.pressure > 0) event.pressure else 0.5,
        .time_ms = time_seconds * 1000,
    };
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

test "count-in produces accented metronome host events before notation" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    app.key(.{ .key = 32, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    app.tick(1.0 / 60.0);
    var events: [16]playback.HostEvent = undefined;
    const count = app.drainPlaybackEvents(&events);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(@as(u8, 3), events[0].on);
    try std.testing.expectEqual(@as(u8, 127), events[0].velocity);
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

test "loop button isolates the current meter-aware measure" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const transport = app.getMut(model.Transport, app.session, app.ids.transport) orelse return error.MissingTransport;
    transport.cursor_beat = 5.25;
    const button = ui.Layout.calculate(1280, 800).loop_toggle;
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
    try std.testing.expectEqual(@as(f32, 8), transport.loop_end);
}

test "page navigation preserves the Flecs document and moves the GPU score window" {
    const app = try App.create(std.heap.c_allocator, 1024, 768, 2);
    defer app.destroy(std.heap.c_allocator);
    try std.testing.expect(app.scoreEndBeat() > 31);
    app.key(.{ .key = 34, .scancode = 0, .modifiers = 0, .pressed = 1, .repeat = 0 });
    const state = app.getConst(model.UiState, app.session, app.ids.ui_state) orelse return error.MissingUiState;
    try std.testing.expectEqual(@as(f32, 16), @floor(state.view_start_beat / 16) * 16);
    try std.testing.expect(app.drawItems().len > 400);
}

test "GPU top bar exposes portable save action" {
    const app = try App.create(std.heap.c_allocator, 1280, 800, 2);
    defer app.destroy(std.heap.c_allocator);
    const expected = ui.Layout.calculate(1280, 800).export_score;
    var found = false;
    for (app.drawItems()) |item| {
        if (@abs(item.rect[0] - expected.x) < 0.1 and @abs(item.rect[1] - expected.y) < 0.1 and @abs(item.rect[2] - expected.width) < 0.1) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
