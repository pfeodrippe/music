const model = @import("model.zig");
const render = @import("../render/packet.zig");
const annotation = @import("annotation.zig");
const std = @import("std");

const Color = render.Color;

const palette = struct {
    const background: Color = .{ 0.035, 0.043, 0.055, 1 };
    const panel: Color = .{ 0.074, 0.086, 0.106, 1 };
    const panel_raised: Color = .{ 0.102, 0.118, 0.142, 1 };
    const border: Color = .{ 0.17, 0.19, 0.23, 1 };
    const text: Color = .{ 0.91, 0.92, 0.90, 1 };
    const muted: Color = .{ 0.49, 0.53, 0.58, 1 };
    const cyan: Color = .{ 0.35, 0.91, 0.88, 1 };
    const cyan_dim: Color = .{ 0.12, 0.30, 0.31, 1 };
    const rose: Color = .{ 0.96, 0.39, 0.52, 1 };
    const amber: Color = .{ 0.97, 0.70, 0.32, 1 };
    const green: Color = .{ 0.42, 0.88, 0.57, 1 };
    const paper: Color = .{ 0.94, 0.925, 0.875, 1 };
    const ink: Color = .{ 0.095, 0.105, 0.115, 1 };
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
};

pub const Layout = struct {
    top: Rect,
    tools: Rect,
    stage: Rect,
    coach: ?Rect,
    transport: Rect,
    play: Rect,
    record: Rect,
    loop_toggle: Rect,
    metronome_toggle: Rect,
    tempo_minus: Rect,
    tempo_plus: Rect,
    import_score: Rect,
    export_score: Rect,
    input_quick: Rect,
    input_setup: Rect,
    replay_take: Rect,
    tool_buttons: [4]Rect,

    pub fn calculate(width: f32, height: f32) Layout {
        const top_height: f32 = 70;
        const transport_height: f32 = 76;
        const compact_tools_height: f32 = if (width < 760) 54 else 0;
        const tool_width: f32 = if (width < 760) 0 else 78;
        const coach_width: f32 = if (width >= 1120) 300 else 0;
        const stage_x = tool_width;
        const stage_width = width - tool_width - coach_width;
        const stage_height = height - top_height - transport_height - compact_tools_height;
        const transport = Rect{ .x = 0, .y = height - transport_height, .width = width, .height = transport_height };
        const play_size: f32 = 48;
        const play = Rect{ .x = width * 0.5 - play_size * 0.5, .y = transport.y + 14, .width = play_size, .height = play_size };
        const record = Rect{ .x = play.x - 62, .y = play.y + 4, .width = 40, .height = 40 };
        var tool_buttons: [4]Rect = undefined;
        for (0..4) |index| tool_buttons[index] = if (tool_width != 0)
            .{ .x = 14, .y = top_height + 20 + @as(f32, @floatFromInt(index)) * 58, .width = 50, .height = 48 }
        else
            .{ .x = @as(f32, @floatFromInt(index)) * width / 4 + 5, .y = top_height + stage_height + 5, .width = width / 4 - 10, .height = 44 };
        const compact_button_width: f32 = if (width < 420) 78 else 94;
        const import_width: f32 = if (width < 600) compact_button_width else 154;
        const export_width: f32 = if (width < 600) compact_button_width else 94;
        const input_width: f32 = if (coach_width == 0) (if (width < 600) compact_button_width else 108) else 0;
        const button_gap: f32 = if (width < 420) 7 else 10;
        const right_margin: f32 = if (width < 420) 10 else 20;
        const import_x = width - import_width - right_margin;
        const export_x = import_x - export_width - button_gap;
        return .{
            .top = .{ .x = 0, .y = 0, .width = width, .height = top_height },
            .tools = if (tool_width != 0) .{ .x = 0, .y = top_height, .width = tool_width, .height = stage_height } else .{ .x = 0, .y = top_height + stage_height, .width = width, .height = compact_tools_height },
            .stage = .{ .x = stage_x, .y = top_height, .width = stage_width, .height = stage_height },
            .coach = if (coach_width > 0) .{ .x = width - coach_width, .y = top_height, .width = coach_width, .height = stage_height } else null,
            .transport = transport,
            .play = play,
            .record = record,
            .loop_toggle = if (width >= 760) .{ .x = play.x + 66, .y = play.y + 4, .width = 52, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .metronome_toggle = if (width >= 800) .{ .x = play.x + 124, .y = play.y + 4, .width = 64, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_minus = if (width >= 640) .{ .x = width - 235, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_plus = if (width >= 640) .{ .x = width - 199, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .import_score = .{ .x = import_x, .y = 15, .width = import_width, .height = 40 },
            .export_score = .{ .x = export_x, .y = 15, .width = export_width, .height = 40 },
            .input_quick = .{ .x = export_x - input_width - button_gap, .y = 15, .width = input_width, .height = 40 },
            .input_setup = if (coach_width > 0) .{ .x = width - coach_width + 20, .y = top_height + 76, .width = coach_width - 40, .height = 44 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .replay_take = if (coach_width > 0) .{ .x = width - coach_width + 32, .y = top_height + 230, .width = coach_width - 64, .height = 28 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tool_buttons = tool_buttons,
        };
    }
};

pub const ScoreGeometry = struct {
    page_x: f32,
    page_y: f32,
    page_width: f32,
    page_height: f32,
    page_padding: f32,
    music_x: f32,
    music_width: f32,
    beat_width: f32,
    treble_y: [2]f32,
    bass_y: [2]f32,

    pub fn calculate(stage: Rect) ScoreGeometry {
        const margin: f32 = if (stage.width < 700) 20 else 46;
        const page_width = @max(280, stage.width - margin * 2);
        const page_height = @max(530, stage.height - 34);
        const page_x = stage.x + (stage.width - page_width) * 0.5;
        const page_y = stage.y + 18;
        const page_padding: f32 = if (page_width < 500) 24 else 48;
        const content_width = page_width - page_padding * 2;
        const clef_width: f32 = if (page_width < 500) 45 else 54;
        const music_x = page_x + page_padding + clef_width;
        const music_width = content_width - clef_width;
        return .{
            .page_x = page_x,
            .page_y = page_y,
            .page_width = page_width,
            .page_height = page_height,
            .page_padding = page_padding,
            .music_x = music_x,
            .music_width = music_width,
            .beat_width = music_width / 8,
            .treble_y = .{ page_y + 126, page_y + 326 },
            .bass_y = .{ page_y + 194, page_y + 394 },
        };
    }
};

pub const NotePosition = struct { x: f32, y: f32, system: usize, bass: bool };

pub fn notePosition(note: model.Note, geometry: ScoreGeometry, view_start_beat: f32) ?NotePosition {
    const relative = note.start_beat - @floor(view_start_beat / 16) * 16;
    if (relative < 0 or relative >= 16) return null;
    const system: usize = if (relative < 8) 0 else 1;
    const beat = if (system == 0) relative else relative - 8;
    const bass = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
    const staff_y = if (bass) geometry.bass_y[system] else geometry.treble_y[system];
    const base_diatonic: i32 = if (bass) 18 else 30; // bass G2 / treble E4 bottom lines
    const diatonic = pitchToDiatonic(note.pitch);
    return .{
        .x = geometry.music_x + beat * geometry.beat_width,
        .y = staff_y + 48 - @as(f32, @floatFromInt(diatonic - base_diatonic)) * 6,
        .system = system,
        .bass = bass,
    };
}

fn pitchToDiatonic(pitch: u8) i32 {
    const pitch_class = pitch % 12;
    const step: i32 = switch (pitch_class) {
        0, 1 => 0,
        2, 3 => 1,
        4 => 2,
        5, 6 => 3,
        7, 8 => 4,
        9, 10 => 5,
        else => 6,
    };
    return (@as(i32, pitch / 12) - 1) * 7 + step;
}

pub fn draw(
    packet: *render.Packet,
    state: *const model.UiState,
    transport: *const model.Transport,
    practice: *const model.PracticeState,
    meta: *const model.DocumentMeta,
    notes: []const model.Note,
    annotations: *const annotation.Store,
    time_seconds: f32,
) void {
    packet.reset();
    const layout = Layout.calculate(state.viewport_width, state.viewport_height);

    packet.rect(0, 0, state.viewport_width, state.viewport_height, palette.background);
    drawTopBar(packet, layout, state, meta);
    if (layout.tools.width > 0 or layout.tools.height > 0) drawTools(packet, layout, state.tool);
    drawScore(packet, layout.stage, state, transport, meta, notes, time_seconds);
    drawAnnotations(packet, layout.stage, state, annotations);
    if (layout.coach) |coach| drawCoach(packet, coach, state, practice);
    drawTransport(packet, layout, transport, meta, time_seconds);

    if (state.notice != 0) {
        const width: f32 = @min(460, state.viewport_width - 40);
        const x = (state.viewport_width - width) * 0.5;
        packet.rounded(x, 84, width, 54, 14, palette.panel_raised);
        const message: []const u8 = switch (state.notice) {
            1 => "CHOOSE A LICENSED SCORE FILE",
            2 => "SCORE IMPORTED + SAVED LOCALLY",
            3 => "IMPORT FAILED OR UNSUPPORTED",
            4 => "MUSIC INPUT READY",
            5 => "INPUT PERMISSION NOT GRANTED",
            6 => "TAKE SAVED ON THIS DEVICE",
            7 => "RECOVERED YOUR LAST SESSION",
            8 => "PORTABLE SCORE EXPORTED",
            else => "SCORE IS READY",
        };
        packet.text(x + 18, 101, message, 1.75, if (state.notice == 3 or state.notice == 5) palette.rose else palette.text);
    }
}

fn drawTopBar(packet: *render.Packet, layout: Layout, state: *const model.UiState, meta: *const model.DocumentMeta) void {
    packet.rect(layout.top.x, layout.top.y, layout.top.width, layout.top.height, palette.panel);
    packet.rect(0, layout.top.height - 1, layout.top.width, 1, palette.border);
    packet.glow(18, 17, 36, 36, 12, palette.cyan_dim, 0.15);
    packet.text(28, 27, "S", 2.3, palette.cyan);
    if (layout.top.width >= 600) {
        packet.text(70, 22, "SCORE", 3.0, palette.text);
        packet.text(70, 47, meta.titleSlice(), 1.25, palette.muted);
    }
    if (layout.input_quick.width > 0) {
        const input_hovered = layout.input_quick.contains(state.pointer_x, state.pointer_y);
        packet.rounded(layout.input_quick.x, layout.input_quick.y, layout.input_quick.width, layout.input_quick.height, 12, if (input_hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.input_quick.x + 13, layout.input_quick.y + 15, "INPUT", 1.5, if (input_hovered) palette.cyan else palette.text);
    }
    const export_hovered = layout.export_score.contains(state.pointer_x, state.pointer_y);
    packet.rounded(layout.export_score.x, layout.export_score.y, layout.export_score.width, layout.export_score.height, 12, if (export_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.export_score.x + 13, layout.export_score.y + 15, "SAVE", if (layout.export_score.width < 90) 1.25 else 1.5, if (export_hovered) palette.cyan else palette.text);
    const hovered = layout.import_score.contains(state.pointer_x, state.pointer_y);
    packet.rounded(layout.import_score.x, layout.import_score.y, layout.import_score.width, layout.import_score.height, 12, if (hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.import_score.x + 13, layout.import_score.y + 15, if (layout.import_score.width < 120) "IMPORT" else "IMPORT SCORE", if (layout.import_score.width < 90) 1.2 else if (layout.import_score.width < 120) 1.45 else 1.65, if (hovered) palette.cyan else palette.text);
}

fn drawTools(packet: *render.Packet, layout: Layout, active: model.Tool) void {
    packet.rect(layout.tools.x, layout.tools.y, layout.tools.width, layout.tools.height, palette.panel);
    if (layout.tools.height < 70) packet.rect(layout.tools.x, layout.tools.y, layout.tools.width, 1, palette.border) else packet.rect(layout.tools.width - 1, layout.tools.y, 1, layout.tools.height, palette.border);
    const labels = [_][]const u8{ "READ", "EDIT", "INK", "PLAY" };
    for (layout.tool_buttons, 0..) |button, index| {
        const selected = index == @intFromEnum(active);
        if (selected) packet.rounded(button.x, button.y, button.width, button.height, 13, palette.cyan_dim);
        packet.text(button.x + 7, button.y + 17, labels[index], if (layout.tools.height < 70) 1.05 else 1.25, if (selected) palette.cyan else palette.muted);
    }
}

fn drawScore(packet: *render.Packet, stage: Rect, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, notes: []const model.Note, time_seconds: f32) void {
    packet.rect(stage.x, stage.y, stage.width, stage.height, .{ 0.045, 0.052, 0.064, 1 });
    const geometry = ScoreGeometry.calculate(stage);
    packet.glow(geometry.page_x - 10, geometry.page_y + 8, geometry.page_width + 20, geometry.page_height + 10, 18, .{ 0, 0, 0, 0.34 }, 0);
    packet.rounded(geometry.page_x, geometry.page_y, geometry.page_width, geometry.page_height, 5, palette.paper);
    packet.text(geometry.page_x + geometry.page_padding - 6, geometry.page_y + 36, meta.titleSlice(), if (geometry.page_width < 500) 1.55 else 2.45, palette.ink);
    const source_label: []const u8 = switch (meta.source_kind) {
        1 => "IMPORTED MUSICXML - REVIEW WARNINGS",
        2 => "IMPORTED MIDI - QUANTIZATION REVIEW",
        else => "PRACTICE FIXTURE - NOT HOLOCENE",
    };
    packet.text(geometry.page_x + geometry.page_padding - 5, geometry.page_y + 64, if (geometry.page_width < 500) "SCORE PRACTICE" else source_label, if (geometry.page_width < 500) 0.9 else 1.2, .{ 0.30, 0.31, 0.31, 1 });
    var page_buffer: [24]u8 = undefined;
    const page_number: u32 = @intFromFloat(@floor(state.view_start_beat / 16) + 1);
    packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - 62, geometry.page_y + 38, std.fmt.bufPrint(&page_buffer, "PAGE {d}", .{page_number}) catch "PAGE", 0.95, .{ 0.35, 0.36, 0.36, 1 });

    for (0..2) |system| {
        const staves = [_]f32{ geometry.treble_y[system], geometry.bass_y[system] };
        for (staves) |staff_y| for (0..5) |line| packet.rect(geometry.music_x, staff_y + @as(f32, @floatFromInt(line)) * 12, geometry.music_width, 1.25, palette.ink);
        packet.trebleClef(geometry.music_x - 48, geometry.treble_y[system] - 17, 31, 80, palette.ink);
        packet.bassClef(geometry.music_x - 45, geometry.bass_y[system] + 2, 33, 44, palette.ink);
        var beats_buffer: [4]u8 = undefined;
        var unit_buffer: [4]u8 = undefined;
        packet.text(geometry.music_x - 16, geometry.treble_y[system] + 7, std.fmt.bufPrint(&beats_buffer, "{d}", .{meta.beats_per_measure}) catch "4", 1.2, palette.ink);
        packet.text(geometry.music_x - 16, geometry.treble_y[system] + 29, std.fmt.bufPrint(&unit_buffer, "{d}", .{meta.beat_unit}) catch "4", 1.2, palette.ink);
        packet.rect(geometry.music_x - 5, geometry.treble_y[system], 2.2, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
        const measure_beats: f32 = @floatFromInt(@max(1, meta.beats_per_measure));
        var bar_beat: f32 = 0;
        while (bar_beat <= 8.001) : (bar_beat += measure_beats) {
            const bx = geometry.music_x + @min(8, bar_beat) * geometry.beat_width;
            packet.rect(bx, geometry.treble_y[system], if (bar_beat + measure_beats > 8) 2.2 else 1.25, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
            if (bar_beat >= 8) break;
        }
    }

    for (notes) |note| {
        const position = notePosition(note, geometry, state.view_start_beat) orelse continue;
        const staff_y = if (position.bass) geometry.bass_y[position.system] else geometry.treble_y[position.system];
        const active = transport.playing != 0 and transport.cursor_beat >= note.start_beat and transport.cursor_beat < note.start_beat + note.duration_beats;
        const color = if (note.selected != 0) palette.rose else if (active) palette.cyan else palette.ink;
        if (active or note.selected != 0) packet.glow(position.x - 14, position.y - 12, 29, 25, 13, if (active) .{ 0.18, 0.78, 0.76, 0.32 } else .{ 0.80, 0.20, 0.34, 0.24 }, time_seconds);
        if (position.y < staff_y - 3 or position.y > staff_y + 51) packet.rect(position.x - 12, position.y - 0.7, 24, 1.4, palette.ink);
        packet.ellipse(position.x - 8, position.y - 5, 16, 10, color);
        if (note.duration_beats >= 2) packet.ellipse(position.x - 4.5, position.y - 2.5, 9, 5, palette.paper);
        if (note.duration_beats < 4) {
            const stem_up = position.y >= staff_y + 24;
            packet.rect(if (stem_up) position.x + 6 else position.x - 8, if (stem_up) position.y - 31 else position.y, 1.7, 34, color);
            if (note.duration_beats <= 0.5) packet.rect(if (stem_up) position.x + 7 else position.x - 14, if (stem_up) position.y - 31 else position.y + 31, 8, 2, color);
        }
    }

    const page_start = @floor(state.view_start_beat / 16) * 16;
    const cursor_relative = transport.cursor_beat - page_start;
    if (cursor_relative >= 0 and cursor_relative < 16) {
        const cursor_system: usize = if (cursor_relative < 8) 0 else 1;
        const cursor_beat = if (cursor_system == 0) cursor_relative else cursor_relative - 8;
        const cursor_x = geometry.music_x + cursor_beat * geometry.beat_width;
        const cursor_top = geometry.treble_y[cursor_system] - 11;
        const cursor_height = geometry.bass_y[cursor_system] - geometry.treble_y[cursor_system] + 71;
        packet.glow(cursor_x - 5, cursor_top, 11, cursor_height, 6, .{ 0.35, 0.91, 0.88, 0.22 }, time_seconds);
        packet.rect(cursor_x, cursor_top, 2, cursor_height, palette.cyan);
    }
}

fn drawAnnotations(packet: *render.Packet, stage: Rect, state: *const model.UiState, annotations: *const annotation.Store) void {
    const page_index: u32 = @intFromFloat(@floor(state.view_start_beat / 16));
    for (annotations.strokes[0..annotations.stroke_count]) |stroke| {
        if (stroke.page_index != page_index) continue;
        const start: usize = @intCast(stroke.first_point);
        const end = start + stroke.point_count;
        for (annotations.points[start..end]) |point| {
            const pressure_width = stroke.width * (0.6 + point.pressure * 0.8);
            packet.ellipse(
                stage.x + point.u * stage.width - pressure_width * 0.5,
                stage.y + point.v * stage.height - pressure_width * 0.5,
                pressure_width,
                pressure_width,
                stroke.rgba,
            );
        }
    }
}

fn drawCoach(packet: *render.Packet, coach: Rect, state: *const model.UiState, practice: *const model.PracticeState) void {
    packet.rect(coach.x, coach.y, coach.width, coach.height, palette.panel);
    packet.rect(coach.x, coach.y, 1, coach.height, palette.border);
    packet.text(coach.x + 24, coach.y + 24, "PRACTICE COACH", 2.0, palette.text);
    packet.text(coach.x + 24, coach.y + 57, "LISTEN WITH", 1.2, palette.muted);
    const source = switch (state.input_source) {
        .none => "SET UP INPUT",
        .midi => "MIDI READY",
        .microphone => "MIC READY",
    };
    packet.rounded(coach.x + 20, coach.y + 76, coach.width - 40, 44, 12, palette.panel_raised);
    packet.text(coach.x + 35, coach.y + 92, source, 1.5, if (state.input_source == .none) palette.amber else palette.green);

    packet.rounded(coach.x + 20, coach.y + 144, coach.width - 40, 126, 15, .{ 0.085, 0.098, 0.118, 1 });
    packet.text(coach.x + 36, coach.y + 164, "TAKE SUMMARY", 1.35, palette.muted);
    var summary_buffer: [48]u8 = undefined;
    const summary = if (practice.total_notes == 0) "PLAY TO GET FEEDBACK" else std.fmt.bufPrint(&summary_buffer, "{d}/{d} NOTES CORRECT", .{ practice.correct_notes, practice.total_notes }) catch "TAKE CAPTURED";
    packet.text(coach.x + 36, coach.y + 198, summary, 1.5, palette.text);
    const recommendation: []const u8 = if (practice.total_notes == 0)
        "REPLAY AUDIO + MIDI"
    else if (practice.pitch_errors * 3 > practice.total_notes)
        "SLOW DOWN - CHECK PITCHES"
    else if (practice.early_notes > practice.late_notes + 1)
        "RELAX - NOTES ARE EARLY"
    else if (practice.late_notes > practice.early_notes + 1)
        "PREPARE EACH ATTACK EARLIER"
    else if (practice.average_timing_ms > 90)
        "LOOP THIS PASS AT 80 PERCENT"
    else
        "EVEN TIMING - REPEAT TO LOCK IN";
    packet.text(coach.x + 36, coach.y + 230, recommendation, 1.0, if (practice.total_notes == 0) palette.cyan else palette.amber);

    const card_y = coach.y + coach.height - 174;
    packet.rounded(coach.x + 20, card_y, coach.width - 40, 144, 16, palette.cyan_dim);
    packet.text(coach.x + 36, card_y + 24, "HOLOCENE", 1.8, palette.text);
    packet.text(coach.x + 36, card_y + 50, "BON IVER", 1.2, palette.muted);
    packet.text(coach.x + 36, card_y + 82, "IMPORT YOUR LICENSED", 1.25, palette.cyan);
    packet.text(coach.x + 36, card_y + 101, "MUSICXML MIDI OR PDF", 1.25, palette.cyan);
    packet.text(coach.x + 36, card_y + 124, "STAYS ON THIS DEVICE", 1.0, palette.muted);
}

fn drawTransport(packet: *render.Packet, layout: Layout, transport: *const model.Transport, meta: *const model.DocumentMeta, time_seconds: f32) void {
    packet.rect(layout.transport.x, layout.transport.y, layout.transport.width, layout.transport.height, palette.panel);
    packet.rect(0, layout.transport.y, layout.transport.width, 1, palette.border);
    if (transport.playing != 0) packet.glow(layout.play.x - 7, layout.play.y - 7, layout.play.width + 14, layout.play.height + 14, 25, .{ 0.2, 0.84, 0.81, 0.25 }, time_seconds);
    packet.rounded(layout.play.x, layout.play.y, layout.play.width, layout.play.height, 24, palette.cyan);
    if (transport.playing == 0) {
        packet.rect(layout.play.x + 19, layout.play.y + 14, 5, 20, palette.background);
        packet.rect(layout.play.x + 24, layout.play.y + 17, 5, 14, palette.background);
        packet.rect(layout.play.x + 29, layout.play.y + 20, 5, 8, palette.background);
    } else {
        packet.rect(layout.play.x + 17, layout.play.y + 14, 5, 20, palette.background);
        packet.rect(layout.play.x + 27, layout.play.y + 14, 5, 20, palette.background);
    }
    packet.rounded(layout.record.x, layout.record.y, layout.record.width, layout.record.height, 20, palette.panel_raised);
    packet.ellipse(layout.record.x + 13, layout.record.y + 13, 14, 14, if (transport.recording != 0) palette.rose else palette.muted);
    if (layout.loop_toggle.width > 0) {
        packet.rounded(layout.loop_toggle.x, layout.loop_toggle.y, layout.loop_toggle.width, layout.loop_toggle.height, 12, if (transport.loop_enabled != 0) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.loop_toggle.x + 8, layout.loop_toggle.y + 15, "LOOP", 1.0, if (transport.loop_enabled != 0) palette.cyan else palette.muted);
    }
    if (layout.metronome_toggle.width > 0) {
        packet.rounded(layout.metronome_toggle.x, layout.metronome_toggle.y, layout.metronome_toggle.width, layout.metronome_toggle.height, 12, if (transport.metronome_enabled != 0) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.metronome_toggle.x + 8, layout.metronome_toggle.y + 15, "CLICK", 0.9, if (transport.metronome_enabled != 0) palette.cyan else palette.muted);
    }
    if (layout.tempo_minus.width > 0) {
        packet.rounded(layout.tempo_minus.x, layout.tempo_minus.y, layout.tempo_minus.width, layout.tempo_minus.height, 10, palette.panel_raised);
        packet.text(layout.tempo_minus.x + 10, layout.tempo_minus.y + 11, "-", 1.4, palette.text);
        packet.rounded(layout.tempo_plus.x, layout.tempo_plus.y, layout.tempo_plus.width, layout.tempo_plus.height, 10, palette.panel_raised);
        packet.text(layout.tempo_plus.x + 9, layout.tempo_plus.y + 11, "+", 1.4, palette.text);
    }
    var bar_buffer: [24]u8 = undefined;
    var beat_buffer: [24]u8 = undefined;
    var tempo_buffer: [24]u8 = undefined;
    const beats_per_measure: f32 = @floatFromInt(@max(1, meta.beats_per_measure));
    if (transport.cursor_beat < 0) {
        const beats_left: u32 = @intFromFloat(@ceil(-transport.cursor_beat));
        packet.text(28, layout.transport.y + 23, "COUNT IN", 1.3, palette.amber);
        packet.text(28, layout.transport.y + 44, std.fmt.bufPrint(&beat_buffer, "{d} BEATS", .{beats_left}) catch "READY", 1.6, palette.text);
    } else {
        const bar = @as(u32, @intFromFloat(transport.cursor_beat / beats_per_measure)) + 1;
        const beat = @as(u32, @intFromFloat(@mod(transport.cursor_beat, beats_per_measure))) + 1;
        packet.text(28, layout.transport.y + 23, std.fmt.bufPrint(&bar_buffer, "BAR {d}", .{bar}) catch "BAR", 1.3, palette.muted);
        packet.text(28, layout.transport.y + 44, std.fmt.bufPrint(&beat_buffer, "BEAT {d}", .{beat}) catch "BEAT", 1.6, palette.text);
    }
    packet.text(layout.transport.width - 134, layout.transport.y + 24, "TEMPO", 1.15, palette.muted);
    packet.text(layout.transport.width - 134, layout.transport.y + 45, std.fmt.bufPrint(&tempo_buffer, "{d:.0} BPM", .{transport.tempo_bpm}) catch "BPM", 1.55, palette.text);
}
