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
    keyboard_panel: Rect,
    coach: ?Rect,
    transport: Rect,
    play: Rect,
    record: Rect,
    loop_toggle: Rect,
    metronome_toggle: Rect,
    keyboard_toggle: Rect,
    vocal_guide_toggle: Rect,
    tempo_minus: Rect,
    tempo_plus: Rect,
    import_score: Rect,
    export_score: Rect,
    input_quick: Rect,
    input_setup: Rect,
    replay_take: Rect,
    library_trigger: Rect,
    library_modal: Rect,
    library_close: Rect,
    library_items: [2]Rect,
    tool_buttons: [4]Rect,

    pub fn calculate(width: f32, height: f32, keyboard_visible: bool) Layout {
        const top_height: f32 = 70;
        const transport_height: f32 = 76;
        const compact_tools_height: f32 = if (width < 760) 54 else 0;
        const tool_width: f32 = if (width < 760) 0 else 78;
        const coach_width: f32 = if (width >= 1120) 300 else 0;
        const stage_x = tool_width;
        const stage_width = width - tool_width - coach_width;
        const content_height = height - top_height - transport_height - compact_tools_height;
        const desired_keyboard_height: f32 = if (height < 650) 128 else if (width < 760) 150 else 180;
        const keyboard_height: f32 = if (keyboard_visible) @min(desired_keyboard_height, @max(112, content_height * 0.34)) else 0;
        const stage_height = content_height - keyboard_height;
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
        const library_modal_width = @min(620, stage_width - 40);
        const library_modal_x = stage_x + (stage_width - library_modal_width) * 0.5;
        const library_modal_y = top_height + 46;
        const library_modal = Rect{ .x = library_modal_x, .y = library_modal_y, .width = library_modal_width, .height = @min(360, content_height - 70) };
        return .{
            .top = .{ .x = 0, .y = 0, .width = width, .height = top_height },
            .tools = if (tool_width != 0) .{ .x = 0, .y = top_height, .width = tool_width, .height = content_height } else .{ .x = 0, .y = top_height + content_height, .width = width, .height = compact_tools_height },
            .stage = .{ .x = stage_x, .y = top_height, .width = stage_width, .height = stage_height },
            .keyboard_panel = .{ .x = stage_x, .y = top_height + stage_height, .width = stage_width, .height = keyboard_height },
            .coach = if (coach_width > 0) .{ .x = width - coach_width, .y = top_height, .width = coach_width, .height = content_height } else null,
            .transport = transport,
            .play = play,
            .record = record,
            .loop_toggle = if (width >= 760) .{ .x = play.x + 66, .y = play.y + 4, .width = 52, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .metronome_toggle = if (width >= 800) .{ .x = play.x + 124, .y = play.y + 4, .width = 64, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .keyboard_toggle = if (width >= 1000)
                .{ .x = play.x + 194, .y = play.y + 4, .width = 58, .height = 40 }
            else if (width >= 640)
                .{ .x = play.x - 132, .y = play.y + 4, .width = 58, .height = 40 }
            else
                .{ .x = play.x + 64, .y = play.y + 4, .width = 58, .height = 40 },
            .vocal_guide_toggle = if (width >= 1180) .{ .x = play.x + 258, .y = play.y + 4, .width = 64, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_minus = if (width >= 640) .{ .x = width - 235, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_plus = if (width >= 640) .{ .x = width - 199, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .import_score = .{ .x = import_x, .y = 15, .width = import_width, .height = 40 },
            .export_score = .{ .x = export_x, .y = 15, .width = export_width, .height = 40 },
            .input_quick = .{ .x = export_x - input_width - button_gap, .y = 15, .width = input_width, .height = 40 },
            .input_setup = if (coach_width > 0) .{ .x = width - coach_width + 20, .y = top_height + 76, .width = coach_width - 40, .height = 44 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .replay_take = if (coach_width > 0) .{ .x = width - coach_width + 32, .y = top_height + 230, .width = coach_width - 64, .height = 28 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .library_trigger = if (coach_width > 0)
                .{ .x = width - coach_width + 20, .y = top_height + content_height - 174, .width = coach_width - 40, .height = 144 }
            else if (width >= 760)
                .{ .x = export_x - input_width - button_gap - 100, .y = 15, .width = 90, .height = 40 }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .library_modal = library_modal,
            .library_close = .{ .x = library_modal.x + library_modal.width - 52, .y = library_modal.y + 18, .width = 34, .height = 34 },
            .library_items = .{
                .{ .x = library_modal.x + 28, .y = library_modal.y + 92, .width = library_modal.width - 56, .height = 82 },
                .{ .x = library_modal.x + 28, .y = library_modal.y + 190, .width = library_modal.width - 56, .height = 82 },
            },
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
    staff_x: f32,
    staff_width: f32,
    music_x: f32,
    music_width: f32,
    beat_width: f32,
    treble_y: [2]f32,
    bass_y: [2]f32,

    pub fn calculate(stage: Rect) ScoreGeometry {
        const margin: f32 = if (stage.width < 700) 20 else 46;
        const page_width = @max(280, stage.width - margin * 2);
        const page_height = @max(280, stage.height - 34);
        const page_x = stage.x + (stage.width - page_width) * 0.5;
        const page_y = stage.y + 18;
        const page_padding: f32 = if (page_width < 500) 24 else 48;
        const staff_x = page_x + page_padding;
        const staff_width = page_width - page_padding * 2;
        const notation_lead: f32 = if (page_width < 500) 64 else 82;
        const music_x = staff_x + notation_lead;
        const music_width = staff_width - notation_lead;
        const first_treble = page_y + @as(f32, if (page_height < 360) 96 else 112);
        const system_gap = std.math.clamp(page_height - 340, 126, 200);
        return .{
            .page_x = page_x,
            .page_y = page_y,
            .page_width = page_width,
            .page_height = page_height,
            .page_padding = page_padding,
            .staff_x = staff_x,
            .staff_width = staff_width,
            .music_x = music_x,
            .music_width = music_width,
            .beat_width = music_width / 8,
            .treble_y = .{ first_treble, first_treble + system_gap },
            .bass_y = .{ first_treble + 68, first_treble + system_gap + 68 },
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
    lyrics: []const model.Lyric,
    annotations: *const annotation.Store,
    time_seconds: f32,
) void {
    packet.reset();
    const layout = Layout.calculate(state.viewport_width, state.viewport_height, state.keyboard_visible != 0);

    packet.rect(0, 0, state.viewport_width, state.viewport_height, palette.background);
    drawTopBar(packet, layout, state, meta);
    if (layout.tools.width > 0 or layout.tools.height > 0) drawTools(packet, layout, state.tool);
    drawScore(packet, layout.stage, state, transport, meta, notes, lyrics, time_seconds);
    drawAnnotations(packet, layout.stage, state, annotations);
    if (layout.keyboard_panel.height > 0) drawKeyboard(packet, layout.keyboard_panel, state, transport, notes);
    if (layout.coach) |coach| drawCoach(packet, coach, state, practice);
    drawTransport(packet, layout, state, transport, meta, time_seconds);
    if (state.library_open != 0) drawLibrary(packet, layout, state);

    if (state.notice != 0) {
        const width: f32 = @min(460, state.viewport_width - 40);
        const x = (state.viewport_width - width) * 0.5;
        packet.rounded(x, 84, width, 54, 14, palette.panel_raised);
        const message: []const u8 = switch (state.notice) {
            1 => "CHOOSE A SCORE FILE",
            2 => "SCORE IMPORTED + SAVED LOCALLY",
            3 => "IMPORT FAILED OR UNSUPPORTED",
            4 => "MUSIC INPUT READY",
            5 => "INPUT PERMISSION NOT GRANTED",
            6 => "TAKE SAVED ON THIS DEVICE",
            7 => "RECOVERED YOUR LAST SESSION",
            8 => "MUSICXML SCORE EXPORTED",
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
    if (layout.library_trigger.width > 0 and layout.library_trigger.y < layout.top.height) {
        const library_hovered = layout.library_trigger.contains(state.pointer_x, state.pointer_y);
        packet.rounded(layout.library_trigger.x, layout.library_trigger.y, layout.library_trigger.width, layout.library_trigger.height, 12, if (library_hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.library_trigger.x + 11, layout.library_trigger.y + 15, "LIBRARY", 1.05, if (library_hovered) palette.cyan else palette.text);
    }
    const export_hovered = layout.export_score.contains(state.pointer_x, state.pointer_y);
    packet.rounded(layout.export_score.x, layout.export_score.y, layout.export_score.width, layout.export_score.height, 12, if (export_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.export_score.x + 13, layout.export_score.y + 15, if (layout.export_score.width < 90) "SAVE" else "EXPORT", if (layout.export_score.width < 90) 1.25 else 1.35, if (export_hovered) palette.cyan else palette.text);
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

fn drawScore(packet: *render.Packet, stage: Rect, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, notes: []const model.Note, lyrics: []const model.Lyric, time_seconds: f32) void {
    packet.rect(stage.x, stage.y, stage.width, stage.height, .{ 0.045, 0.052, 0.064, 1 });
    const geometry = ScoreGeometry.calculate(stage);
    packet.glow(geometry.page_x - 10, geometry.page_y + 8, geometry.page_width + 20, geometry.page_height + 10, 18, .{ 0, 0, 0, 0.34 }, 0);
    packet.rounded(geometry.page_x, geometry.page_y, geometry.page_width, geometry.page_height, 5, palette.paper);
    packet.text(geometry.page_x + geometry.page_padding - 6, geometry.page_y + 36, meta.titleSlice(), if (geometry.page_width < 500) 1.55 else 2.45, palette.ink);
    const source_label: []const u8 = switch (meta.source_kind) {
        1 => "IMPORTED MUSICXML - REVIEW WARNINGS",
        2 => "IMPORTED MIDI - QUANTIZATION REVIEW",
        else => "BUILT-IN PRACTICE SCORE",
    };
    packet.text(geometry.page_x + geometry.page_padding - 5, geometry.page_y + 64, if (geometry.page_width < 500) "SCORE PRACTICE" else source_label, if (geometry.page_width < 500) 0.9 else 1.2, .{ 0.30, 0.31, 0.31, 1 });
    var page_buffer: [24]u8 = undefined;
    const page_number: u32 = @intFromFloat(@floor(state.view_start_beat / 16) + 1);
    packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - 62, geometry.page_y + 38, std.fmt.bufPrint(&page_buffer, "PAGE {d}", .{page_number}) catch "PAGE", 0.95, .{ 0.35, 0.36, 0.36, 1 });

    for (0..2) |system| {
        const staves = [_]f32{ geometry.treble_y[system], geometry.bass_y[system] };
        for (staves) |staff_y| for (0..5) |line| packet.rect(geometry.staff_x, staff_y + @as(f32, @floatFromInt(line)) * 12, geometry.staff_width, 0.85, palette.ink);
        const music_em: f32 = 48;
        packet.musicGlyph(0xe050, geometry.staff_x + 5, geometry.treble_y[system] + 36, music_em, palette.ink);
        packet.musicGlyph(0xe062, geometry.staff_x + 5, geometry.bass_y[system] + 12, music_em, palette.ink);
        var beats_buffer: [4]u8 = undefined;
        var unit_buffer: [4]u8 = undefined;
        const beats = std.fmt.bufPrint(&beats_buffer, "{d}", .{meta.beats_per_measure}) catch "4";
        const unit = std.fmt.bufPrint(&unit_buffer, "{d}", .{meta.beat_unit}) catch "4";
        const time_x = geometry.staff_x + @as(f32, if (geometry.page_width < 500) 35 else 45);
        if (beats.len != 0 and beats[0] >= '0' and beats[0] <= '9') packet.musicGlyph(0xe080 + @as(u21, beats[0] - '0'), time_x, geometry.treble_y[system] + 12, music_em, palette.ink);
        if (unit.len != 0 and unit[0] >= '0' and unit[0] <= '9') packet.musicGlyph(0xe080 + @as(u21, unit[0] - '0'), time_x, geometry.treble_y[system] + 36, music_em, palette.ink);
        packet.rect(geometry.staff_x, geometry.treble_y[system], 1.5, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
        const measure_beats: f32 = @floatFromInt(@max(1, meta.beats_per_measure));
        var bar_beat: f32 = measure_beats;
        while (bar_beat <= 8.001) : (bar_beat += measure_beats) {
            const bx = geometry.music_x + @min(8, bar_beat) * geometry.beat_width;
            packet.rect(bx, geometry.treble_y[system], if (bar_beat + measure_beats > 8) 1.5 else 0.9, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
            if (bar_beat >= 8) break;
        }
    }

    for (notes) |note| {
        const vocal_guide = (note.flags & model.note_flag_vocal_guide) != 0;
        if (vocal_guide and state.vocal_guide_visible == 0) continue;
        const position = notePosition(note, geometry, state.view_start_beat) orelse continue;
        const staff_y = if (position.bass) geometry.bass_y[position.system] else geometry.treble_y[position.system];
        const active = transport.playing != 0 and transport.cursor_beat >= note.start_beat and transport.cursor_beat < note.start_beat + note.duration_beats;
        const color: Color = if (vocal_guide) (if (active) palette.rose else .{ 0.53, 0.33, 0.40, 1 }) else if (note.selected != 0) palette.rose else if (active) palette.cyan else palette.ink;
        if (active or note.selected != 0) packet.glow(position.x - 14, position.y - 12, 29, 25, 13, if (active) .{ 0.18, 0.78, 0.76, 0.32 } else .{ 0.80, 0.20, 0.34, 0.24 }, time_seconds);
        if (position.y < staff_y - 3 or position.y > staff_y + 51) packet.rect(position.x - 12, position.y - 0.7, 24, 1.4, palette.ink);
        const music_em: f32 = 48;
        const notehead: u21 = if (note.duration_beats >= 4) 0xe0a2 else if (note.duration_beats >= 2) 0xe0a3 else 0xe0a4;
        const origin_offset: f32 = if (note.duration_beats >= 4) 10.1 else 7.1;
        packet.musicGlyph(notehead, position.x - origin_offset, position.y, music_em, color);
        if (note.duration_beats < 4) {
            const stem_up = position.y >= staff_y + 24;
            const stem_x = if (stem_up) position.x + 6.2 else position.x - 6.2;
            const stem_end = if (stem_up) position.y - 32 else position.y + 32;
            packet.rect(stem_x, @min(position.y, stem_end), 1.25, @abs(stem_end - position.y), color);
            if (note.duration_beats <= 0.5) packet.musicGlyph(if (stem_up) 0xe240 else 0xe241, stem_x, stem_end, music_em, color);
        }
    }

    const lyric_page_start = @floor(state.view_start_beat / 16) * 16;
    for (lyrics) |lyric| {
        const relative = lyric.start_beat - lyric_page_start;
        if (relative < 0 or relative >= 16) continue;
        const system: usize = if (relative < 8) 0 else 1;
        const beat = if (system == 0) relative else relative - 8;
        const x = geometry.music_x + beat * geometry.beat_width;
        const y = geometry.treble_y[system] + 54;
        const active = transport.playing != 0 and @abs(transport.cursor_beat - lyric.start_beat) < 0.34;
        packet.text(x - 3, y, lyric.textSlice(), if (geometry.page_width < 500) 0.65 else 0.82, if (active) palette.cyan_dim else .{ 0.20, 0.21, 0.22, 1 });
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

const piano_low: u8 = 36; // C2
const piano_high: u8 = 96; // C7
const piano_white_count: f32 = 36;

fn isBlackKey(pitch: u8) bool {
    return switch (pitch % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

fn whiteIndexBefore(pitch: u8) u8 {
    var result: u8 = 0;
    var candidate: u8 = piano_low;
    while (candidate < pitch and candidate <= piano_high) : (candidate += 1) {
        if (!isBlackKey(candidate)) result += 1;
    }
    return result;
}

fn pianoKeysRect(panel: Rect) Rect {
    const side: f32 = if (panel.width < 620) 12 else 24;
    return .{ .x = panel.x + side, .y = panel.y + 51, .width = panel.width - side * 2, .height = @max(52, panel.height - 62) };
}

fn pianoKeyCenter(panel: Rect, pitch: u8) f32 {
    const keys = pianoKeysRect(panel);
    const white_width = keys.width / piano_white_count;
    const before: f32 = @floatFromInt(whiteIndexBefore(pitch));
    return if (isBlackKey(pitch)) keys.x + before * white_width else keys.x + (before + 0.5) * white_width;
}

pub fn pianoPitchAt(panel: Rect, x: f32, y: f32) ?u8 {
    if (panel.height <= 0) return null;
    const keys = pianoKeysRect(panel);
    if (!keys.contains(x, y)) return null;
    const white_width = keys.width / piano_white_count;
    const black_width = white_width * 0.62;
    var pitch: u8 = piano_low;
    while (pitch <= piano_high) : (pitch += 1) {
        if (!isBlackKey(pitch)) continue;
        const key = Rect{ .x = pianoKeyCenter(panel, pitch) - black_width * 0.5, .y = keys.y, .width = black_width, .height = keys.height * 0.62 };
        if (key.contains(x, y)) return pitch;
    }
    pitch = piano_low;
    while (pitch <= piano_high) : (pitch += 1) {
        if (isBlackKey(pitch)) continue;
        const before: f32 = @floatFromInt(whiteIndexBefore(pitch));
        const key = Rect{ .x = keys.x + before * white_width, .y = keys.y, .width = white_width, .height = keys.height };
        if (key.contains(x, y)) return pitch;
    }
    return null;
}

const HandTargets = struct {
    active: ?u8 = null,
    next: ?u8 = null,
    next_beat: f32 = std.math.floatMax(f32),
};

fn findHandTargets(notes: []const model.Note, cursor: f32, left: bool) HandTargets {
    var result: HandTargets = .{};
    var active_start: f32 = -std.math.floatMax(f32);
    for (notes) |note| {
        if ((note.flags & model.note_flag_vocal_guide) != 0) continue;
        const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
        if (note_left != left or note.pitch < piano_low or note.pitch > piano_high) continue;
        if (note.start_beat <= cursor + 0.025 and note.start_beat + note.duration_beats > cursor and note.start_beat > active_start) {
            result.active = note.pitch;
            active_start = note.start_beat;
        }
        if (note.start_beat > cursor + 0.04 and note.start_beat < result.next_beat) {
            result.next = note.pitch;
            result.next_beat = note.start_beat;
        }
    }
    if (result.active == null and result.next == null) {
        for (notes) |note| {
            if ((note.flags & model.note_flag_vocal_guide) != 0) continue;
            const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
            if (note_left != left or note.pitch < piano_low or note.pitch > piano_high) continue;
            if (note.start_beat >= cursor and note.start_beat < result.next_beat) {
                result.next = note.pitch;
                result.next_beat = note.start_beat;
            }
        }
    }
    return result;
}

fn fingerPair(targets: HandTargets, left: bool) [2]u8 {
    const current = targets.active orelse targets.next orelse return .{ 3, 3 };
    const next = targets.next orelse return .{ 3, 3 };
    const interval = std.math.clamp(pitchToDiatonic(next) - pitchToDiatonic(current), -4, 4);
    if (interval >= 0) {
        const step: u8 = @intCast(interval);
        return if (left) .{ 5, 5 - step } else .{ 1, 1 + step };
    }
    const step: u8 = @intCast(-interval);
    return if (left) .{ 1, 1 + step } else .{ 5, 5 - step };
}

fn keyColor(pitch: u8, left: HandTargets, right: HandTargets, hovered: ?u8, black: bool) Color {
    if (left.active == pitch) return if (black) .{ 0.76, 0.43, 0.14, 1 } else .{ 0.98, 0.75, 0.39, 1 };
    if (right.active == pitch) return if (black) .{ 0.11, 0.62, 0.61, 1 } else .{ 0.45, 0.92, 0.88, 1 };
    if (left.next == pitch) return if (black) .{ 0.36, 0.25, 0.15, 1 } else .{ 0.36, 0.30, 0.23, 1 };
    if (right.next == pitch) return if (black) .{ 0.12, 0.32, 0.34, 1 } else .{ 0.20, 0.38, 0.39, 1 };
    if (hovered == pitch) return if (black) palette.rose else .{ 0.96, 0.76, 0.80, 1 };
    return if (black) .{ 0.055, 0.063, 0.077, 1 } else .{ 0.88, 0.88, 0.85, 1 };
}

fn drawFingeringGuide(packet: *render.Packet, panel: Rect, targets: HandTargets, left: bool) void {
    const current = targets.active orelse targets.next orelse return;
    const fingers = fingerPair(targets, left);
    const accent = if (left) palette.amber else palette.cyan;
    const keys = pianoKeysRect(panel);
    const current_x = pianoKeyCenter(panel, current);
    const current_y = keys.y + keys.height * (if (isBlackKey(current)) @as(f32, 0.40) else 0.68);
    packet.ellipse(current_x - 9, current_y - 9, 18, 18, .{ accent[0], accent[1], accent[2], 0.96 });
    var finger_buffer: [2]u8 = undefined;
    packet.text(current_x - 3, current_y - 5, std.fmt.bufPrint(&finger_buffer, "{d}", .{fingers[0]}) catch "3", 0.88, palette.background);
    if (targets.next) |next| {
        if (next != current) {
            const next_x = pianoKeyCenter(panel, next);
            const next_y = keys.y + keys.height * (if (isBlackKey(next)) @as(f32, 0.25) else 0.52);
            packet.ellipse(next_x - 7, next_y - 7, 14, 14, .{ accent[0], accent[1], accent[2], 0.42 });
            packet.text(next_x - 3, next_y - 5, std.fmt.bufPrint(&finger_buffer, "{d}", .{fingers[1]}) catch "3", 0.82, palette.text);
        }
    }
}

fn drawPedalStatus(packet: *render.Packet, panel: Rect, state: *const model.UiState) void {
    if (panel.width < 880) return;
    const labels = [_][]const u8{ "SOFT", "SOST", "SUST" };
    const values = [_]u32{ state.soft_pedal, state.sostenuto_pedal, state.sustain_pedal };
    const start_x = panel.x + panel.width - 352;
    for (labels, values, 0..) |label, value, index| {
        const x = start_x + @as(f32, @floatFromInt(index)) * 58;
        const amount = @as(f32, @floatFromInt(@min(value, 127))) / 127.0;
        packet.rounded(x, panel.y + 10, 52, 28, 8, palette.panel_raised);
        if (amount > 0.001) packet.rounded(x + 2, panel.y + 30 - amount * 18, 48, amount * 6 + 6, 6, .{ palette.cyan[0], palette.cyan[1], palette.cyan[2], 0.42 + amount * 0.48 });
        packet.text(x + 7, panel.y + 18, label, 0.72, if (amount >= 0.5) palette.text else palette.muted);
    }
}

fn drawKeyboard(packet: *render.Packet, panel: Rect, state: *const model.UiState, transport: *const model.Transport, notes: []const model.Note) void {
    packet.rect(panel.x, panel.y, panel.width, panel.height, .{ 0.055, 0.064, 0.078, 1 });
    packet.rect(panel.x, panel.y, panel.width, 1, palette.border);
    packet.text(panel.x + 24, panel.y + 14, "Guided piano", 1.55, palette.text);
    if (panel.width >= 560) packet.text(panel.x + 142, panel.y + 17, "Follow the glow / 1 thumb / 5 little finger", 1.0, palette.muted);
    drawPedalStatus(packet, panel, state);
    packet.ellipse(panel.x + panel.width - 146, panel.y + 18, 8, 8, palette.amber);
    packet.text(panel.x + panel.width - 133, panel.y + 14, "Left", 1.05, palette.muted);
    packet.ellipse(panel.x + panel.width - 78, panel.y + 18, 8, 8, palette.cyan);
    packet.text(panel.x + panel.width - 65, panel.y + 14, "Right", 1.05, palette.muted);

    const cursor = @max(0, transport.cursor_beat);
    const left = findHandTargets(notes, cursor, true);
    const right = findHandTargets(notes, cursor, false);
    const hovered = pianoPitchAt(panel, state.pointer_x, state.pointer_y);
    const keys = pianoKeysRect(panel);
    const white_width = keys.width / piano_white_count;
    var pitch: u8 = piano_low;
    while (pitch <= piano_high) : (pitch += 1) {
        if (isBlackKey(pitch)) continue;
        const before: f32 = @floatFromInt(whiteIndexBefore(pitch));
        const x = keys.x + before * white_width;
        packet.rounded(x, keys.y, white_width + 0.25, keys.height, 2.5, .{ 0.13, 0.14, 0.16, 1 });
        packet.rounded(x + 0.7, keys.y + 0.8, @max(1, white_width - 1.15), keys.height - 1.6, 2, keyColor(pitch, left, right, hovered, false));
        if (pitch % 12 == 0 and panel.width >= 700) {
            var octave_buffer: [4]u8 = undefined;
            packet.text(x + 2, keys.y + keys.height - 16, std.fmt.bufPrint(&octave_buffer, "C{d}", .{pitch / 12 - 1}) catch "C", 0.75, .{ 0.20, 0.21, 0.23, 0.75 });
        }
    }
    pitch = piano_low;
    const black_width = white_width * 0.62;
    while (pitch <= piano_high) : (pitch += 1) {
        if (!isBlackKey(pitch)) continue;
        const x = pianoKeyCenter(panel, pitch) - black_width * 0.5;
        packet.rounded(x, keys.y, black_width, keys.height * 0.62, 2.5, keyColor(pitch, left, right, hovered, true));
    }
    drawFingeringGuide(packet, panel, left, true);
    drawFingeringGuide(packet, panel, right, false);
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
    packet.text(coach.x + 36, card_y + 24, "SCORE LIBRARY", 1.8, palette.text);
    packet.text(coach.x + 36, card_y + 50, "BACH / BEETHOVEN / MORE", 1.05, palette.muted);
    packet.text(coach.x + 36, card_y + 82, "PUBLIC-DOMAIN STARTERS", 1.15, palette.cyan);
    packet.text(coach.x + 36, card_y + 101, "MUSICXML / MXL / MIDI", 1.15, palette.cyan);
    packet.text(coach.x + 36, card_y + 124, "YOUR FILES STAY PRIVATE", 1.0, palette.muted);
}

fn drawLibrary(packet: *render.Packet, layout: Layout, state: *const model.UiState) void {
    const content_height = layout.stage.height + layout.keyboard_panel.height;
    packet.rect(layout.stage.x, layout.stage.y, layout.stage.width, content_height, .{ 0.01, 0.014, 0.022, 0.82 });
    const modal = layout.library_modal;
    packet.glow(modal.x - 14, modal.y - 10, modal.width + 28, modal.height + 24, 26, .{ 0, 0, 0, 0.55 }, 0);
    packet.rounded(modal.x, modal.y, modal.width, modal.height, 20, palette.panel);
    packet.text(modal.x + 30, modal.y + 26, "Score library", 2.2, palette.text);
    packet.text(modal.x + 30, modal.y + 56, "Curated offline starters with explicit public-domain or CC0 metadata", 1.0, palette.muted);
    packet.rounded(layout.library_close.x, layout.library_close.y, layout.library_close.width, layout.library_close.height, 11, palette.panel_raised);
    packet.text(layout.library_close.x + 11, layout.library_close.y + 9, "X", 1.25, palette.muted);

    const titles = [_][]const u8{ "Minuet in G major", "Fur Elise" };
    const creators = [_][]const u8{ "J. S. Bach / BWV Anh. 114", "L. van Beethoven / WoO 59" };
    const badges = [_][]const u8{ "PUBLIC DOMAIN", "OPENSCORE CC0" };
    for (layout.library_items, 0..) |item, index| {
        const hovered = item.contains(state.pointer_x, state.pointer_y);
        packet.rounded(item.x, item.y, item.width, item.height, 14, if (hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(item.x + 22, item.y + 16, titles[index], 1.55, palette.text);
        packet.text(item.x + 22, item.y + 43, creators[index], 1.05, palette.muted);
        const badge_width = render.Packet.textWidth(badges[index], 0.9) + 18;
        packet.rounded(item.x + item.width - badge_width - 18, item.y + 26, badge_width, 25, 8, if (index == 0) .{ 0.28, 0.25, 0.16, 1 } else palette.cyan_dim);
        packet.text(item.x + item.width - badge_width - 9, item.y + 33, badges[index], 0.9, if (index == 0) palette.amber else palette.cyan);
    }
    packet.text(modal.x + 30, modal.y + modal.height - 40, "Choose a starter, or use Import Score for your own MusicXML, MXL, MIDI, or .score file.", 0.95, palette.muted);
}

fn drawTransport(packet: *render.Packet, layout: Layout, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, time_seconds: f32) void {
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
    packet.rounded(layout.keyboard_toggle.x, layout.keyboard_toggle.y, layout.keyboard_toggle.width, layout.keyboard_toggle.height, 12, if (layout.keyboard_panel.height > 0) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.keyboard_toggle.x + 9, layout.keyboard_toggle.y + 15, "KEYS", 0.95, if (layout.keyboard_panel.height > 0) palette.cyan else palette.muted);
    if (layout.vocal_guide_toggle.width > 0) {
        packet.rounded(layout.vocal_guide_toggle.x, layout.vocal_guide_toggle.y, layout.vocal_guide_toggle.width, layout.vocal_guide_toggle.height, 12, if (state.vocal_guide_visible != 0) .{ 0.30, 0.15, 0.21, 1 } else palette.panel_raised);
        packet.text(layout.vocal_guide_toggle.x + 8, layout.vocal_guide_toggle.y + 15, "VOICE", 0.86, if (state.vocal_guide_visible != 0) palette.rose else palette.muted);
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
