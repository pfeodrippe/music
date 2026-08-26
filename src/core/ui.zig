const model = @import("model.zig");
const fingering = @import("fingering.zig");
const render = @import("../render/packet.zig");
const glyph_atlas = @import("../render/glyph_atlas.zig");
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

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.width and self.x + self.width > other.x and self.y < other.y + other.height and self.y + self.height > other.y;
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
    pedal_guide_toggle: Rect,
    tempo_minus: Rect,
    tempo_plus: Rect,
    tempo_value: Rect,
    view_mode_toggle: Rect,
    focus_toggle: Rect,
    part_selector: Rect,
    zoom_minus: Rect,
    zoom_plus: Rect,
    import_score: Rect,
    export_score: Rect,
    input_quick: Rect,
    input_setup: Rect,
    instrument_setup: Rect,
    replay_take: Rect,
    export_take: Rect,
    page_previous: Rect,
    page_next: Rect,
    library_trigger: Rect,
    library_modal: Rect,
    library_close: Rect,
    library_items: [4]Rect,
    tool_buttons: [4]Rect,
    app_view_toggle: Rect,

    pub fn calculate(width: f32, height: f32, keyboard_visible: bool) Layout {
        return calculateWithFocus(width, height, keyboard_visible, false);
    }

    pub fn calculateForState(state: *const model.UiState) Layout {
        return calculateWithFocus(state.viewport_width, state.viewport_height, state.keyboard_visible != 0, state.focus_score != 0);
    }

    fn calculateWithFocus(width: f32, height: f32, keyboard_visible: bool, focus_score: bool) Layout {
        const constrained = !focus_score and width < 760 and height < 650;
        const top_height: f32 = if (focus_score) 0 else if (constrained) 56 else 70;
        const transport_height: f32 = if (focus_score or constrained) 58 else 76;
        const compact_tools_height: f32 = if (!focus_score and width < 760) (if (constrained) 44 else 54) else 0;
        const tool_width: f32 = if (!focus_score and width >= 760) 78 else 0;
        const coach_width: f32 = if (!focus_score and width >= 1120) 300 else 0;
        const stage_x = tool_width;
        const stage_width = width - tool_width - coach_width;
        const content_height = height - top_height - transport_height - compact_tools_height;
        // At the supported 720x540 minimum the score needs one complete vocal
        // and grand-staff system, including the coaching/lyric lane. A tall
        // keyboard stole the exact 20 px that lane needs and let its text run
        // into upward piano beams. Keep a playable compact keyboard while
        // giving engraving first claim on the scarce vertical space.
        const desired_keyboard_height: f32 = if (constrained) 60 else if (width < 760) 150 else 180;
        const keyboard_floor: f32 = if (constrained) 56 else 112;
        const keyboard_height: f32 = if (keyboard_visible and !focus_score) @min(desired_keyboard_height, @max(keyboard_floor, content_height * 0.30)) else 0;
        const stage_height = content_height - keyboard_height;
        const transport = Rect{ .x = 0, .y = height - transport_height, .width = width, .height = transport_height };
        const play_size: f32 = 48;
        const play = Rect{ .x = width * 0.5 - play_size * 0.5, .y = transport.y + (transport_height - play_size) * 0.5, .width = play_size, .height = play_size };
        const record = Rect{ .x = play.x - 62, .y = play.y + 4, .width = 40, .height = 40 };
        var tool_buttons: [4]Rect = undefined;
        for (0..4) |index| tool_buttons[index] = if (tool_width != 0)
            .{ .x = 14, .y = top_height + 20 + @as(f32, @floatFromInt(index)) * 58, .width = 50, .height = 48 }
        else
            .{ .x = @as(f32, @floatFromInt(index)) * width / 4 + 5, .y = top_height + content_height + 5, .width = width / 4 - 10, .height = @max(0, compact_tools_height - 10) };
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
        const library_modal = Rect{ .x = library_modal_x, .y = library_modal_y, .width = library_modal_width, .height = @min(430, content_height - 70) };
        const library_item_height = @min(70, @max(48, (library_modal.height - 148 - 36) / 4));
        const library_item_gap: f32 = 12;
        const page_button_width: f32 = if (stage_width < 640) 34 else 40;
        const page_button_height: f32 = if (stage_height < 520) 52 else 68;
        const page_button_y = top_height + (stage_height - page_button_height) * 0.5;
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
            .pedal_guide_toggle = if (width >= 1320) .{ .x = play.x + 328, .y = play.y + 4, .width = 64, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_minus = if (width >= 640) .{ .x = width - 235, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_plus = if (width >= 640) .{ .x = width - 199, .y = play.y + 8, .width = 30, .height = 32 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .tempo_value = .{ .x = width - 148, .y = transport.y + (transport_height - 49) * 0.5, .width = 132, .height = 49 },
            .view_mode_toggle = if (width >= 820) .{ .x = 158, .y = transport.y + (transport_height - 34) * 0.5, .width = 98, .height = 34 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .zoom_minus = if (width >= 940) .{ .x = 264, .y = transport.y + (transport_height - 34) * 0.5, .width = 34, .height = 34 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .zoom_plus = if (width >= 940) .{ .x = 304, .y = transport.y + (transport_height - 34) * 0.5, .width = 34, .height = 34 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .focus_toggle = if (width >= 1040) .{ .x = 346, .y = transport.y + (transport_height - 34) * 0.5, .width = 86, .height = 34 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .part_selector = if (!focus_score and width >= 900) .{ .x = 278, .y = 15, .width = 116, .height = 40 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .import_score = .{ .x = import_x, .y = 15, .width = import_width, .height = 40 },
            .export_score = .{ .x = export_x, .y = 15, .width = export_width, .height = 40 },
            .input_quick = .{ .x = export_x - input_width - button_gap, .y = 15, .width = input_width, .height = 40 },
            .input_setup = if (coach_width > 0) .{ .x = width - coach_width + 20, .y = top_height + 76, .width = coach_width - 40, .height = 44 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .instrument_setup = if (coach_width > 0 and content_height >= 520)
                .{ .x = width - coach_width + 20, .y = top_height + 286, .width = coach_width - 40, .height = 78 }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .replay_take = if (coach_width > 0) .{ .x = width - coach_width + 32, .y = top_height + 236, .width = (coach_width - 72) * 0.5, .height = 26 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .export_take = if (coach_width > 0) .{ .x = width - coach_width + 40 + (coach_width - 72) * 0.5, .y = top_height + 236, .width = (coach_width - 72) * 0.5, .height = 26 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .page_previous = .{ .x = stage_x + 5, .y = page_button_y, .width = page_button_width, .height = page_button_height },
            .page_next = .{ .x = stage_x + stage_width - page_button_width - 5, .y = page_button_y, .width = page_button_width, .height = page_button_height },
            .library_trigger = if (coach_width > 0)
                .{ .x = width - coach_width + 20, .y = top_height + content_height - 174, .width = coach_width - 40, .height = 144 }
            else if (width >= 760)
                .{ .x = export_x - input_width - button_gap - 100, .y = 15, .width = 90, .height = 40 }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .library_modal = library_modal,
            .library_close = .{ .x = library_modal.x + library_modal.width - 52, .y = library_modal.y + 18, .width = 34, .height = 34 },
            .library_items = .{
                .{ .x = library_modal.x + 28, .y = library_modal.y + 92, .width = library_modal.width - 56, .height = library_item_height },
                .{ .x = library_modal.x + 28, .y = library_modal.y + 92 + library_item_height + library_item_gap, .width = library_modal.width - 56, .height = library_item_height },
                .{ .x = library_modal.x + 28, .y = library_modal.y + 92 + (library_item_height + library_item_gap) * 2, .width = library_modal.width - 56, .height = library_item_height },
                .{ .x = library_modal.x + 28, .y = library_modal.y + 92 + (library_item_height + library_item_gap) * 3, .width = library_modal.width - 56, .height = library_item_height },
            },
            .tool_buttons = tool_buttons,
            .app_view_toggle = if (!focus_score and width >= 700)
                .{ .x = width * 0.5 - 70, .y = 15, .width = 140, .height = 40 }
            else
                .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    }
};

pub const ControllerLayout = struct {
    header: Rect,
    score_view: Rect,
    protocol: Rect,
    edit: Rect,
    setup: Rect,
    banks: [4]Rect,
    octave_down: Rect,
    octave_up: Rect,
    pads: [16]Rect,
    transport: [8]Rect,

    pub fn calculate(width: f32, height: f32) ControllerLayout {
        const header_height: f32 = 72;
        const margin: f32 = if (width < 700) 12 else 24;
        const gap: f32 = if (width < 700) 7 else 12;
        const controls_y: f32 = header_height + 16;
        const controls_height: f32 = 44;
        const grid_top = controls_y + controls_height + 22;
        const available_width = width - margin * 2 - gap * 5;
        const available_height = height - grid_top - margin - gap * 3;
        const unit = @max(@as(f32, 38), @min(@as(f32, 158), @min(available_width / 6, available_height / 4)));
        const total_width = unit * 6 + gap * 5;
        const total_height = unit * 4 + gap * 3;
        const grid_x = (width - total_width) * 0.5;
        const grid_y = grid_top + @max(@as(f32, 0), (height - grid_top - margin - total_height) * 0.5);
        var pads: [16]Rect = undefined;
        var transport: [8]Rect = undefined;
        for (0..4) |visual_row| {
            for (0..4) |column| {
                const pad_index = (3 - visual_row) * 4 + column;
                pads[pad_index] = .{
                    .x = grid_x + @as(f32, @floatFromInt(column)) * (unit + gap),
                    .y = grid_y + @as(f32, @floatFromInt(visual_row)) * (unit + gap),
                    .width = unit,
                    .height = unit,
                };
            }
            for (0..2) |column| {
                const index = visual_row * 2 + column;
                transport[index] = .{
                    .x = grid_x + @as(f32, @floatFromInt(column + 4)) * (unit + gap),
                    .y = grid_y + @as(f32, @floatFromInt(visual_row)) * (unit + gap),
                    .width = unit,
                    .height = unit,
                };
            }
        }
        const compact = width < 760;
        const bank_width: f32 = if (compact) 60 else 82;
        const bank_start = width * 0.5 - (bank_width * 4 + gap * 3) * 0.5;
        const header_button_width: f32 = if (compact) 72 else 92;
        const protocol_x = width - margin - header_button_width;
        return .{
            .header = .{ .x = 0, .y = 0, .width = width, .height = header_height },
            .score_view = .{ .x = margin, .y = 15, .width = if (compact) 92 else 118, .height = 42 },
            .protocol = .{ .x = protocol_x, .y = 15, .width = header_button_width, .height = 42 },
            .edit = .{ .x = protocol_x - gap - header_button_width, .y = 15, .width = header_button_width, .height = 42 },
            .setup = .{ .x = width - margin - (if (compact) @as(f32, 72) else 92), .y = controls_y, .width = if (compact) 72 else 92, .height = controls_height },
            .banks = .{
                .{ .x = bank_start, .y = controls_y, .width = bank_width, .height = controls_height },
                .{ .x = bank_start + bank_width + gap, .y = controls_y, .width = bank_width, .height = controls_height },
                .{ .x = bank_start + (bank_width + gap) * 2, .y = controls_y, .width = bank_width, .height = controls_height },
                .{ .x = bank_start + (bank_width + gap) * 3, .y = controls_y, .width = bank_width, .height = controls_height },
            },
            .octave_down = .{ .x = margin, .y = controls_y, .width = if (compact) 48 else 58, .height = controls_height },
            .octave_up = .{ .x = margin + (if (compact) @as(f32, 54) else 66), .y = controls_y, .width = if (compact) 48 else 58, .height = controls_height },
            .pads = pads,
            .transport = transport,
        };
    }
};

pub const min_score_zoom: f32 = 0.45;
pub const max_score_zoom: f32 = 1.05;

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
    vocal_y: [max_score_systems]f32,
    lyric_y: [max_score_systems]f32,
    treble_y: [max_score_systems]f32,
    bass_y: [max_score_systems]f32,

    pub fn calculate(stage: Rect) ScoreGeometry {
        return calculateForSystems(stage, false, 2);
    }

    pub fn calculateWithVocal(stage: Rect, vocal_visible: bool) ScoreGeometry {
        return calculateForSystems(stage, vocal_visible, 2);
    }

    pub fn calculateForSystems(stage: Rect, vocal_visible: bool, requested_systems: usize) ScoreGeometry {
        const system_count = std.math.clamp(requested_systems, 1, max_score_systems);
        const margin: f32 = if (stage.width < 700) 20 else 46;
        const page_width = @max(280, stage.width - margin * 2);
        // The paper must remain inside the stage. A previous 280 px minimum
        // painted the score underneath the keyboard in a constrained window.
        const page_height = @max(220, stage.height - 20);
        const page_x = stage.x + (stage.width - page_width) * 0.5;
        const page_y = stage.y + 10;
        const page_padding: f32 = if (page_width < 500) 24 else 48;
        const staff_x = page_x + page_padding;
        const staff_width = page_width - page_padding * 2;
        // Reserve enough room for clef, a complete seven-accidental key
        // signature, and meter. This stays fixed across imports so pointer
        // hit-testing and GPU engraving use the same music origin.
        const notation_lead: f32 = if (page_width < 500) 110 else 126;
        const music_x = staff_x + notation_lead;
        const music_width = staff_width - notation_lead;
        const ultra_compact = page_height < 340;
        // The Bravura treble clef reaches roughly 34 px above the top staff
        // line.  Keep that real ink bound below the 60 px source-label lane;
        // using the staff line itself as the bound made compact first pages
        // look as though the title, source, clef, key and meter were one blob.
        const first_treble = page_y + @as(f32, if (ultra_compact) 76 else if (page_height < 440) 116 else 124);
        // Dynamics need a real lane between the two staves. The former 56/68
        // px separation was narrower than the 26 px Bravura dynamic ink once
        // the two five-line staves were accounted for, so `mf` visibly crossed
        // the bass staff. Keep a reduced but still useful compact separation.
        const treble_to_bass: f32 = if (ultra_compact) 64 else 82;
        const piano_group_extent: f32 = treble_to_bass + 49;
        const piano_minimum_gap: f32 = treble_to_bass + 82;
        const compact_vocal = page_height < 680;
        // The first singer staff starts below the complete page heading. SMuFL
        // treble clefs extend well above the top staff line, so anchoring this
        // at the old 84 px offset let the clef collide with the source label.
        const first_vocal = page_y + @as(f32, if (ultra_compact) 76 else if (page_height < 440) 116 else 124);
        // Lyrics own the lane immediately below the vocal staff. Keep enough
        // clearance for descenders, note stems/dynamics, and the next piano
        // staff instead of allowing text to collide with either notation row.
        // Keep coaching words/lyrics in a true lane between the vocal and
        // piano staves. The previous 20 px clearance put text directly in the
        // reach of an upward piano beam, especially on printed pages.
        const vocal_to_treble: f32 = if (ultra_compact) 110 else if (compact_vocal) 110 else 118;
        const vocal_group_extent = vocal_to_treble + treble_to_bass + 49;
        const vocal_minimum_gap = vocal_to_treble + treble_to_bass + 96;
        const resolved_treble = if (vocal_visible) first_vocal + vocal_to_treble else first_treble;
        const resolved_bass = resolved_treble + treble_to_bass;
        const first_top = if (vocal_visible) first_vocal else first_treble;
        const group_extent = if (vocal_visible) vocal_group_extent else piano_group_extent;
        const bottom_margin: f32 = if (vocal_visible) (if (compact_vocal) 24 else 32) else 28;
        const minimum_gap = if (vocal_visible) vocal_minimum_gap else piano_minimum_gap;
        const resolved_gap = if (system_count > 1)
            @max(minimum_gap, (page_height - (first_top - page_y) - group_extent - bottom_margin) / @as(f32, @floatFromInt(system_count - 1)))
        else
            minimum_gap;
        var vocal_y = [_]f32{0} ** max_score_systems;
        var lyric_y = [_]f32{0} ** max_score_systems;
        var treble_y = [_]f32{0} ** max_score_systems;
        var bass_y = [_]f32{0} ** max_score_systems;
        for (0..max_score_systems) |system| {
            const offset = @as(f32, @floatFromInt(system)) * resolved_gap;
            vocal_y[system] = (if (vocal_visible) first_vocal else first_treble) + offset;
            lyric_y[system] = (if (vocal_visible) first_vocal + 68 else first_treble + 82) + offset;
            treble_y[system] = resolved_treble + offset;
            bass_y[system] = resolved_bass + offset;
        }
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
            .vocal_y = vocal_y,
            // The lyric baseline is a distinct engraving lane: 34 px below
            // the lowest staff line and still above the piano grand staff.
            .lyric_y = lyric_y,
            .treble_y = treble_y,
            .bass_y = bass_y,
        };
    }
};

pub const NotePosition = struct { x: f32, y: f32, system: usize, bass: bool, vocal: bool };

pub const ScoreSystem = struct {
    start_beat: f32 = 0,
    end_beat: f32 = 0,
    first_measure: usize = 0,
    measure_end: usize = 0,

    pub fn duration(self: ScoreSystem) f32 {
        return @max(0.0001, self.end_beat - self.start_beat);
    }
};

pub const max_score_systems: usize = 6;

pub const ScorePage = struct {
    systems: [max_score_systems]ScoreSystem = [_]ScoreSystem{.{}} ** max_score_systems,
    system_count: usize = 2,
    page_index: u32 = 0,

    pub fn startBeat(self: ScorePage) f32 {
        return self.systems[0].start_beat;
    }

    pub fn endBeat(self: ScorePage) f32 {
        return self.systems[@max(1, self.system_count) - 1].end_beat;
    }
};

/// Virtual engraving area for semantic zoom.  It grows inversely with zoom,
/// then the resulting notation is transformed back into the one physical
/// paper sheet.  More complete systems therefore merge onto that same sheet
/// as the user zooms out.
pub fn zoomedScoreStage(stage: Rect, zoom: f32) Rect {
    const resolved_zoom = std.math.clamp(zoom, min_score_zoom, max_score_zoom);
    const width = stage.width / resolved_zoom;
    const height = stage.height / resolved_zoom;
    return .{
        .x = stage.x + (stage.width - width) * 0.5,
        .y = stage.y,
        .width = width,
        .height = height,
    };
}

pub const ScoreBeatPosition = struct { x: f32, system: usize };

fn scoreSystemBeatCapacity(zoom: f32) f32 {
    // Zooming out must reveal more authored measures, not merely shrink the
    // same sparse page. Keep the density bounded so note spacing remains
    // readable and zooming in still has a useful optical effect.
    return std.math.clamp(9.0 / std.math.clamp(zoom, min_score_zoom, max_score_zoom), 8.0, 20.0);
}

fn nextScoreSystem(measures: []const model.Measure, first_measure: usize, beat_capacity: f32) ScoreSystem {
    if (first_measure >= measures.len) {
        const end = if (measures.len == 0) @as(f32, 0) else measures[measures.len - 1].start_beat + measures[measures.len - 1].duration_beats;
        return .{ .start_beat = end, .end_beat = end, .first_measure = measures.len, .measure_end = measures.len };
    }
    const start = measures[first_measure].start_beat;
    var measure_end = first_measure;
    var end = start;
    while (measure_end < measures.len) {
        const measure = measures[measure_end];
        const candidate_end = measure.start_beat + @max(0.0001, measure.duration_beats);
        if (measure_end > first_measure and candidate_end - start > beat_capacity + 0.0001) break;
        end = @max(end, candidate_end);
        measure_end += 1;
    }
    return .{ .start_beat = start, .end_beat = end, .first_measure = first_measure, .measure_end = measure_end };
}

/// Select the number of complete systems that physically fit in a score pane.
/// Vocal-guide pages need substantially more vertical space because the vocal
/// staff and lyric lane are independent from the piano grand staff.
pub fn scoreSystemsPerPage(stage_height: f32, vocal_visible: bool) usize {
    const page_height = @max(220, stage_height - 20);
    // Preserve the established one/two-system breakpoints (680 vocal, 430
    // piano). Beyond that breakpoint, use the actual engraved group extent so
    // tall pages do not waste enough white space to hold another full system.
    const two_system_breakpoint: f32 = if (vocal_visible) 680 else 430;
    const single_system_height: f32 = if (vocal_visible) 373 else 255;
    const additional_system_height: f32 = if (vocal_visible) 296 else 164;
    if (page_height < two_system_breakpoint) return 1;
    const extra = @as(usize, @intFromFloat(@floor((page_height - single_system_height) / additional_system_height)));
    return std.math.clamp(1 + extra, 1, max_score_systems);
}

/// Continuous mode draws one look-ahead system beyond the fully visible set
/// so a fractional pan never uncovers an empty strip at the bottom edge.
pub fn continuousBufferedSystemCount(visible_systems: usize) usize {
    return @min(max_score_systems, std.math.clamp(visible_systems, 1, max_score_systems) + 1);
}

/// Source-space distance between adjacent systems. Rendering and hit-testing
/// both use this value before the final semantic-zoom transform.
pub fn scoreSystemStride(stage: Rect, vocal_visible: bool, visible_systems: usize) f32 {
    const geometry = ScoreGeometry.calculateForSystems(stage, vocal_visible, visible_systems);
    return @max(1, geometry.treble_y[1] - geometry.treble_y[0]);
}

pub fn scorePageForBeat(measures: []const model.Measure, requested_beat: f32, meta: *const model.DocumentMeta, zoom: f32) ScorePage {
    return scorePageForBeatLimited(measures, requested_beat, meta, zoom, 2);
}

pub fn scorePageForBeatLimited(measures: []const model.Measure, requested_beat: f32, meta: *const model.DocumentMeta, zoom: f32, requested_systems: usize) ScorePage {
    const systems_per_page = std.math.clamp(requested_systems, 1, max_score_systems);
    if (measures.len == 0) {
        const system_beats = meta.systemBeats();
        const page_beats = system_beats * @as(f32, @floatFromInt(systems_per_page));
        const page_start = @floor(@max(0, requested_beat) / page_beats) * page_beats;
        var page: ScorePage = .{ .system_count = systems_per_page, .page_index = @intFromFloat(@floor(page_start / page_beats)) };
        for (0..systems_per_page) |system| {
            const start = page_start + @as(f32, @floatFromInt(system)) * system_beats;
            page.systems[system] = .{ .start_beat = start, .end_beat = start + system_beats };
        }
        return page;
    }

    const target = @max(measures[0].start_beat, requested_beat);
    const beat_capacity = scoreSystemBeatCapacity(zoom);
    var first_measure: usize = 0;
    var page_index: u32 = 0;
    while (true) : (page_index += 1) {
        var page: ScorePage = .{ .system_count = 0, .page_index = page_index };
        var measure_cursor = first_measure;
        while (page.system_count < systems_per_page and measure_cursor < measures.len) {
            const system = nextScoreSystem(measures, measure_cursor, beat_capacity);
            page.systems[page.system_count] = system;
            page.system_count += 1;
            measure_cursor = system.measure_end;
        }
        const page_measure_end = page.systems[page.system_count - 1].measure_end;
        const page_end = page.endBeat();
        for (page.system_count..max_score_systems) |system| page.systems[system] = .{
            .start_beat = page_end,
            .end_beat = page_end,
            .first_measure = page_measure_end,
            .measure_end = page_measure_end,
        };
        if (target < page.endBeat() - 0.0001 or page_measure_end >= measures.len) return page;
        first_measure = page_measure_end;
    }
}

pub fn scoreContinuousForBeat(measures: []const model.Measure, requested_beat: f32, meta: *const model.DocumentMeta, zoom: f32) ScorePage {
    return scoreContinuousForBeatLimited(measures, requested_beat, meta, zoom, 2);
}

pub fn scoreContinuousForBeatLimited(measures: []const model.Measure, requested_beat: f32, meta: *const model.DocumentMeta, zoom: f32, requested_systems: usize) ScorePage {
    const systems_per_page = std.math.clamp(requested_systems, 1, max_score_systems);
    if (measures.len == 0) {
        const system_beats = meta.systemBeats();
        const first_start = @floor(@max(0, requested_beat) / system_beats) * system_beats;
        var page: ScorePage = .{
            .system_count = systems_per_page,
            .page_index = @intFromFloat(@floor(first_start / system_beats)),
        };
        for (0..systems_per_page) |system| {
            const start = first_start + @as(f32, @floatFromInt(system)) * system_beats;
            page.systems[system] = .{ .start_beat = start, .end_beat = start + system_beats };
        }
        return page;
    }
    const target = @max(measures[0].start_beat, requested_beat);
    const beat_capacity = scoreSystemBeatCapacity(zoom);
    var first_measure: usize = 0;
    var system_index: u32 = 0;
    while (first_measure < measures.len) : (system_index += 1) {
        const first = nextScoreSystem(measures, first_measure, beat_capacity);
        if (target < first.end_beat - 0.0001 or first.measure_end >= measures.len) {
            var page: ScorePage = .{ .system_count = 0, .page_index = system_index };
            var measure_cursor = first_measure;
            while (page.system_count < systems_per_page and measure_cursor < measures.len) {
                const system = nextScoreSystem(measures, measure_cursor, beat_capacity);
                page.systems[page.system_count] = system;
                page.system_count += 1;
                measure_cursor = system.measure_end;
            }
            const page_measure_end = page.systems[page.system_count - 1].measure_end;
            const page_end = page.endBeat();
            for (page.system_count..max_score_systems) |system| page.systems[system] = .{
                .start_beat = page_end,
                .end_beat = page_end,
                .first_measure = page_measure_end,
                .measure_end = page_measure_end,
            };
            return page;
        }
        first_measure = first.measure_end;
    }
    return scorePageForBeatLimited(measures, requested_beat, meta, zoom, systems_per_page);
}

pub fn scoreSystemCount(measures: []const model.Measure, zoom: f32) u32 {
    if (measures.len == 0) return 1;
    const beat_capacity = scoreSystemBeatCapacity(zoom);
    var count: u32 = 0;
    var first_measure: usize = 0;
    while (first_measure < measures.len) : (count += 1) first_measure = nextScoreSystem(measures, first_measure, beat_capacity).measure_end;
    return @max(1, count);
}

pub fn scorePageCount(measures: []const model.Measure, meta: *const model.DocumentMeta, zoom: f32) u32 {
    return scorePageCountLimited(measures, meta, zoom, 2);
}

pub fn scorePageCountLimited(measures: []const model.Measure, meta: *const model.DocumentMeta, zoom: f32, requested_systems: usize) u32 {
    if (measures.len == 0) return 1;
    const systems_per_page = std.math.clamp(requested_systems, 1, max_score_systems);
    const beat_capacity = scoreSystemBeatCapacity(zoom);
    var page_count: u32 = 0;
    var first_measure: usize = 0;
    while (first_measure < measures.len) {
        var systems: usize = 0;
        while (systems < systems_per_page and first_measure < measures.len) : (systems += 1) {
            first_measure = nextScoreSystem(measures, first_measure, beat_capacity).measure_end;
        }
        page_count += 1;
    }
    _ = meta;
    return @max(1, page_count);
}

fn measureBoundaryX(geometry: ScoreGeometry, system: ScoreSystem, beat: f32) f32 {
    return geometry.music_x + std.math.clamp((beat - system.start_beat) / system.duration(), 0, 1) * geometry.music_width;
}

const MeasureContentInsets = struct {
    left: f32,
    right: f32,
};

/// Keep authored content clear of a mid-system meter change. The opening
/// meter lives in the fixed notation lead, but later meters are engraved just
/// inside their measure and therefore need horizontal space before beat one.
/// Hit-testing uses the same insets below so pointer edits remain reversible.
fn measureContentInsets(system: ScoreSystem, measures: []const model.Measure, measure_index: usize, left: f32, right: f32) MeasureContentInsets {
    const width = @max(1, right - left);
    const regular = @min(14, width * 0.12);
    const meter_changed = measure_index > system.first_measure and measure_index < measures.len and
        (measures[measure_index].beats != measures[measure_index - 1].beats or measures[measure_index].beat_unit != measures[measure_index - 1].beat_unit);
    // A 48 px SMuFL time signature centered eight pixels after the barline
    // occupies roughly the first 27 px. Forty pixels, capped for narrow bars,
    // leaves an optical gap before the first notehead/rest.
    const meter_clearance: f32 = if (meter_changed) @min(40, width * 0.24) else 0;
    return .{
        .left = @min(width * 0.44, @max(regular, meter_clearance)),
        .right = regular,
    };
}

pub fn scoreBeatPosition(geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, absolute_beat: f32) ?ScoreBeatPosition {
    var system_index: usize = 0;
    while (system_index < page.system_count) : (system_index += 1) {
        const system = page.systems[system_index];
        if (absolute_beat < system.start_beat - 0.0001 or absolute_beat >= system.end_beat - 0.0001) continue;
        var measure_index = system.first_measure;
        while (measure_index < system.measure_end) : (measure_index += 1) {
            const measure = measures[measure_index];
            const measure_end = measure.start_beat + @max(0.0001, measure.duration_beats);
            if (absolute_beat >= measure_end - 0.0001 and measure_index + 1 < system.measure_end) continue;
            const left = measureBoundaryX(geometry, system, measure.start_beat);
            const right = measureBoundaryX(geometry, system, measure_end);
            const insets = measureContentInsets(system, measures, measure_index, left, right);
            const local = std.math.clamp((absolute_beat - measure.start_beat) / @max(0.0001, measure.duration_beats), 0, 1);
            return .{ .x = left + insets.left + local * @max(1, right - left - insets.left - insets.right), .system = system_index };
        }
        return .{ .x = measureBoundaryX(geometry, system, absolute_beat), .system = system_index };
    }
    return null;
}

pub fn scoreNotePosition(note: model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure) ?NotePosition {
    var absolute_beat = note.start_beat;
    if ((note.flags & model.note_flag_measure_rest) != 0) absolute_beat += note.duration_beats * 0.5;
    const beat_position = scoreBeatPosition(geometry, page, measures, absolute_beat) orelse return null;
    const rest = (note.flags & model.note_flag_rest) != 0;
    const vocal = (note.flags & model.note_flag_vocal_guide) != 0;
    const bass = !vocal and ((note.staff & 1) != 0 or (!rest and note.staff == 0 and note.pitch < 58));
    const staff_y = if (vocal) geometry.vocal_y[beat_position.system] else if (bass) geometry.bass_y[beat_position.system] else geometry.treble_y[beat_position.system];
    const base_diatonic: i32 = if (bass) 18 else 30;
    const diatonic = noteDiatonic(note);
    return .{
        .x = beat_position.x,
        .y = if (rest) staff_y + 24 else staff_y + 48 - @as(f32, @floatFromInt(diatonic - base_diatonic)) * 6,
        .system = beat_position.system,
        .bass = bass,
        .vocal = vocal,
    };
}

pub fn scoreBeatAtX(geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, system_index: usize, x: f32) f32 {
    const system = page.systems[@min(system_index, @max(1, page.system_count) - 1)];
    const relative_x = std.math.clamp(x - geometry.music_x, 0, @max(0, geometry.music_width - 0.001));
    if (system.first_measure >= system.measure_end or system.measure_end > measures.len) {
        return system.start_beat + relative_x / @max(1, geometry.music_width) * system.duration();
    }

    const raw_beat = system.start_beat + relative_x / @max(1, geometry.music_width) * system.duration();
    var measure_index = system.first_measure;
    while (measure_index < system.measure_end) : (measure_index += 1) {
        const measure = measures[measure_index];
        const measure_duration = @max(0.0001, measure.duration_beats);
        const measure_end = measure.start_beat + measure_duration;
        if (raw_beat >= measure_end - 0.0001 and measure_index + 1 < system.measure_end) continue;
        const left = measureBoundaryX(geometry, system, measure.start_beat);
        const right = measureBoundaryX(geometry, system, measure_end);
        const insets = measureContentInsets(system, measures, measure_index, left, right);
        const usable = @max(1, right - left - insets.left - insets.right);
        const local = std.math.clamp((x - left - insets.left) / usable, 0, 1);
        return std.math.clamp(measure.start_beat + local * measure_duration, measure.start_beat, measure_end - 0.0001);
    }
    return system.end_beat - 0.0001;
}

/// Resolve a pointer to the closest visible system. The boundary is the
/// optical midpoint between adjacent systems, so editing and score-space ink
/// remain stable when a tall window fits three or more systems.
pub fn scoreSystemAtY(geometry: ScoreGeometry, page: ScorePage, vocal_visible: bool, y: f32) usize {
    const count = std.math.clamp(page.system_count, 1, max_score_systems);
    for (0..count) |system| {
        if (system + 1 == count) return system;
        const bottom = geometry.bass_y[system] + 49;
        const next_top = if (vocal_visible) geometry.vocal_y[system + 1] else geometry.treble_y[system + 1];
        if (y < (bottom + next_top) * 0.5) return system;
    }
    return count - 1;
}

fn measurePadding(geometry: ScoreGeometry, measure_beats: f32) f32 {
    return @min(14, measure_beats * geometry.beat_width * 0.12);
}

pub fn beatX(geometry: ScoreGeometry, beat_in_system: f32, measure_beats: f32, system_beats: f32) f32 {
    const beat = std.math.clamp(beat_in_system, 0, @max(0, system_beats - 0.0001));
    const measure_index = @floor(beat / measure_beats);
    const local_beat = beat - measure_index * measure_beats;
    const measure_x = geometry.music_x + measure_index * measure_beats * geometry.beat_width;
    const measure_width = measure_beats * geometry.beat_width;
    const padding = measurePadding(geometry, measure_beats);
    return measure_x + padding + local_beat / measure_beats * @max(1, measure_width - padding * 2);
}

pub fn beatAtX(geometry: ScoreGeometry, x: f32, measure_beats: f32, system_beats: f32) f32 {
    const measure_width = measure_beats * geometry.beat_width;
    const relative_x = std.math.clamp(x - geometry.music_x, 0, @max(0, geometry.music_width - 0.001));
    const measure_index = @floor(relative_x / measure_width);
    const local_x = relative_x - measure_index * measure_width;
    const padding = measurePadding(geometry, measure_beats);
    const usable = @max(1, measure_width - padding * 2);
    const local_beat = std.math.clamp((local_x - padding) / usable, 0, 1) * measure_beats;
    return std.math.clamp(measure_index * measure_beats + local_beat, 0, @max(0, system_beats - 0.0001));
}

pub fn notePosition(note: model.Note, geometry: ScoreGeometry, page_start_beat: f32, measure_beats: f32, system_beats: f32) ?NotePosition {
    const relative = note.start_beat - page_start_beat;
    if (relative < 0 or relative >= system_beats * 2) return null;
    const system: usize = if (relative < system_beats) 0 else 1;
    var beat = if (system == 0) relative else relative - system_beats;
    if ((note.flags & model.note_flag_measure_rest) != 0) beat += note.duration_beats * 0.5;
    const rest = (note.flags & model.note_flag_rest) != 0;
    const vocal = (note.flags & model.note_flag_vocal_guide) != 0;
    const bass = !vocal and ((note.staff & 1) != 0 or (!rest and note.staff == 0 and note.pitch < 58));
    const staff_y = if (vocal) geometry.vocal_y[system] else if (bass) geometry.bass_y[system] else geometry.treble_y[system];
    const base_diatonic: i32 = if (bass) 18 else 30; // bass G2 / treble E4 bottom lines
    const diatonic = noteDiatonic(note);
    return .{
        .x = beatX(geometry, beat, measure_beats, system_beats),
        .y = if (rest) staff_y + 24 else staff_y + 48 - @as(f32, @floatFromInt(diatonic - base_diatonic)) * 6,
        .system = system,
        .bass = bass,
        .vocal = vocal,
    };
}

fn staffYForPosition(geometry: ScoreGeometry, position: NotePosition) f32 {
    return if (position.vocal) geometry.vocal_y[position.system] else if (position.bass) geometry.bass_y[position.system] else geometry.treble_y[position.system];
}

fn sameNotationLayer(a: model.Note, b: model.Note) bool {
    // A grace sequence and its principal note intentionally share a metric
    // onset, staff and voice. Keep them in separate engraving layers so the
    // principal is not mistaken for another notehead in a grace chord.
    return ((a.flags ^ b.flags) & (model.note_flag_vocal_guide | model.note_flag_grace)) == 0;
}

fn sameOnsetVoiceLayer(a: model.Note, b: model.Note) bool {
    return sameNotationLayer(a, b) and a.staff == b.staff and @abs(a.start_beat - b.start_beat) < 0.0001;
}

const NoteRange = struct { start: usize, end: usize };

/// Frame note snapshots are ordered by beat before engraving. Restrict chord
/// and concurrent-voice queries to one onset instead of rescanning an entire
/// large score for every visible note.
fn noteOnsetRange(notes: []const model.Note, start_beat: f32) NoteRange {
    const tolerance: f32 = 0.0001;
    var low: usize = 0;
    var high: usize = notes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (notes[middle].start_beat < start_beat - tolerance) low = middle + 1 else high = middle;
    }
    const start = low;
    high = notes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (notes[middle].start_beat < start_beat + tolerance) low = middle + 1 else high = middle;
    }
    return .{ .start = start, .end = low };
}

fn noteOnsetSlice(notes: []const model.Note, start_beat: f32) []const model.Note {
    const range = noteOnsetRange(notes, start_beat);
    return notes[range.start..range.end];
}

fn hasConcurrentVoice(notes: []const model.Note, note: model.Note) bool {
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if (candidate.voice != note.voice and sameOnsetVoiceLayer(candidate, note)) return true;
    }
    return false;
}

fn hasConcurrentPitchedVoice(notes: []const model.Note, note: model.Note) bool {
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or candidate.voice == note.voice) continue;
        if (sameOnsetVoiceLayer(candidate, note)) return true;
    }
    return false;
}

fn chordStemUp(notes: []const model.Note, note: model.Note, staff_y: f32) bool {
    // Conventional polyphonic engraving keeps the upper/first voice stems up
    // and the lower/second voice stems down. Without this override, two voices
    // centered on the same staff chose the same stem direction and became
    // indistinguishable even when their noteheads were later displaced.
    if (hasConcurrentPitchedVoice(notes, note)) return (note.voice & 1) == 0;
    var y_sum: f32 = 0;
    var count: u32 = 0;
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const bass = (candidate.staff & 1) != 0 or (candidate.staff == 0 and candidate.pitch < 58);
        const base_diatonic: i32 = if (bass) 18 else 30;
        y_sum += staff_y + 48 - @as(f32, @floatFromInt(noteDiatonic(candidate) - base_diatonic)) * 6;
        count += 1;
    }
    return count == 0 or y_sum / @as(f32, @floatFromInt(count)) >= staff_y + 24;
}

fn chordNoteOffset(notes: []const model.Note, note: model.Note, stem_up: bool) f32 {
    if ((note.flags & model.note_flag_grace) != 0) return 0;
    const diatonic = noteDiatonic(note);
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const delta = noteDiatonic(candidate) - diatonic;
        if (stem_up and delta == -1) return 10;
        if (!stem_up and delta == 1) return -10;
    }
    return 0;
}

fn voicesNeedHorizontalSeparation(notes: []const model.Note, note: model.Note) bool {
    if ((note.flags & model.note_flag_rest) != 0) return false;
    var own_notes: [32]model.Note = undefined;
    var own_count: usize = 0;
    const onset_notes = noteOnsetSlice(notes, note.start_beat);
    for (onset_notes) |own| {
        if ((own.flags & model.note_flag_rest) != 0 or own.voice != note.voice or !sameOnsetVoiceLayer(own, note)) continue;
        if (own_count < own_notes.len) {
            own_notes[own_count] = own;
            own_count += 1;
        }
    }
    for (onset_notes) |other| {
        if ((other.flags & model.note_flag_rest) != 0 or other.voice == note.voice or !sameOnsetVoiceLayer(other, note)) continue;
        for (own_notes[0..own_count]) |own| {
            const distance = @abs(noteDiatonic(own) - noteDiatonic(other));
            if (distance > 1) continue;
            // Exact unisons with the same graphical duration can share one
            // notehead and carry stems on both sides. Seconds, differently
            // spelled unisons, and mixed-duration unisons need separate heads.
            if (distance == 0 and own.pitch == other.pitch and own.duration_beats == other.duration_beats and own.dots == other.dots) continue;
            return true;
        }
    }
    return false;
}

fn voiceHorizontalOffset(notes: []const model.Note, note: model.Note) f32 {
    if (!voicesNeedHorizontalSeparation(notes, note)) return 0;
    const lane = @min(@as(f32, @floatFromInt(note.voice / 2)), 2);
    const distance = 7 + lane * 6;
    return if ((note.voice & 1) == 0) distance else -distance;
}

fn noteRenderX(notes: []const model.Note, note: model.Note, position: NotePosition) f32 {
    if ((note.flags & model.note_flag_rest) != 0) return position.x;
    const base_diatonic: i32 = if (position.bass) 18 else 30;
    const relative_y = 48 - @as(f32, @floatFromInt(noteDiatonic(note) - base_diatonic)) * 6;
    const stem_up = chordStemUp(notes, note, position.y - relative_y);
    var x = position.x + chordNoteOffset(notes, note, stem_up) + voiceHorizontalOffset(notes, note);
    if ((note.flags & model.note_flag_grace) != 0) {
        var sequence_count: usize = 0;
        var sequence_rank: usize = 0;
        for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
            if ((candidate.flags & model.note_flag_grace) == 0 or !sameNotationLayer(candidate, note) or candidate.staff != note.staff or candidate.voice != note.voice or @abs(candidate.start_beat - note.start_beat) >= 0.0001) continue;
            sequence_count += 1;
            if (candidate.stable_id < note.stable_id) sequence_rank += 1;
        }
        // Source order reads left-to-right, with the final grace closest to
        // the principal attack. Clamp pathological imports so a large grace
        // run cannot invade the clef/key-signature lane.
        const remaining = @min(sequence_count -| sequence_rank -| 1, 4);
        x -= 11 + @as(f32, @floatFromInt(remaining)) * 10;
    }
    return x;
}

fn restRenderY(notes: []const model.Note, note: model.Note, position: NotePosition) f32 {
    if ((note.flags & model.note_flag_rest) == 0) return position.y;
    if (!hasConcurrentVoice(notes, note)) return position.y;
    const lane = @min(@as(f32, @floatFromInt(note.voice / 2)), 2);
    // The Bravura quarter-rest ink is about 43 px tall at our 48 px em, so
    // the two primary voice lanes need 48 px center separation to leave real
    // optical air rather than forming one long, ambiguous composite symbol.
    const distance = 24 + lane * 10;
    return position.y + if ((note.voice & 1) == 0) -distance else distance;
}

fn noteRenderPosition(notes: []const model.Note, note: model.Note, position: NotePosition) NotePosition {
    var resolved = position;
    resolved.x = noteRenderX(notes, note, position);
    resolved.y = restRenderY(notes, note, position);
    return resolved;
}

fn isChordStemAnchor(notes: []const model.Note, note: model.Note, stem_up: bool) bool {
    if ((note.flags & model.note_flag_grace) != 0) return true;
    const diatonic = noteDiatonic(note);
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const candidate_diatonic = noteDiatonic(candidate);
        if (stem_up and candidate_diatonic > diatonic) return false;
        if (!stem_up and candidate_diatonic < diatonic) return false;
    }
    return true;
}

fn chordHasBeam(notes: []const model.Note, note: model.Note) bool {
    // Grace attacks share the principal note's metric onset, but each has its
    // own stable-id beam anchor. Their authored beam flag still suppresses the
    // standalone flag/stem in the note pass; drawBeams emits the cue-size
    // connected group after all noteheads are placed.
    if ((note.flags & model.note_flag_grace) != 0) return (note.flags & model.note_flag_beam_mask) != 0;
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if (sameNotationLayer(candidate, note) and candidate.start_beat == note.start_beat and candidate.staff == note.staff and candidate.voice == note.voice and (candidate.flags & model.note_flag_beam_mask) != 0) return true;
    }
    return false;
}

fn chordSingleTremoloMarks(notes: []const model.Note, note: model.Note) u8 {
    var marks = model.singleTremoloMarks(note);
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        marks = @max(marks, model.singleTremoloMarks(candidate));
    }
    return marks;
}

fn drawSingleNoteTremolo(packet: *render.Packet, marks: u8, stem_x: f32, note_y: f32, stem_up: bool, scale: f32, color: Color) void {
    for (0..@min(marks, 8)) |index| {
        const distance = (10 + @as(f32, @floatFromInt(index)) * 4.4) * scale;
        const y = note_y + (if (stem_up) -distance else distance);
        packet.line(stem_x - 6.5 * scale, y + 3 * scale, stem_x + 6.5 * scale, y - 3 * scale, 2.2 * scale, color);
    }
}

const Spelling = struct { step: u8, alter: i8, octave: i8 };

fn noteSpelling(note: model.Note) Spelling {
    if (note.written_step >= 'A' and note.written_step <= 'G' and note.written_octave >= 0) {
        return .{ .step = note.written_step, .alter = note.written_alter, .octave = note.written_octave };
    }
    const steps = [_]u8{ 'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B' };
    const alters = [_]i8{ 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 };
    return .{ .step = steps[note.pitch % 12], .alter = alters[note.pitch % 12], .octave = @intCast(note.pitch / 12 -| 1) };
}

fn stepIndex(step: u8) i32 {
    return switch (step) {
        'C' => 0,
        'D' => 1,
        'E' => 2,
        'F' => 3,
        'G' => 4,
        'A' => 5,
        'B' => 6,
        else => 0,
    };
}

fn noteDiatonic(note: model.Note) i32 {
    const spelling = noteSpelling(note);
    return @as(i32, spelling.octave) * 7 + stepIndex(spelling.step);
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

fn keyAlterForStep(step: u8, fifths: i8) i8 {
    const sharps = "FCGDAEB";
    const flats = "BEADGCF";
    if (fifths > 0) {
        const count: usize = @intCast(@min(fifths, 7));
        if (std.mem.indexOfScalar(u8, sharps[0..count], step) != null) return 1;
    } else if (fifths < 0) {
        const count: usize = @intCast(@min(-fifths, 7));
        if (std.mem.indexOfScalar(u8, flats[0..count], step) != null) return -1;
    }
    return 0;
}

fn shouldDrawAccidental(notes: []const model.Note, note_index: usize, meta: *const model.DocumentMeta) bool {
    return shouldDrawAccidentalInMeasures(notes, note_index, meta, &.{});
}

fn shouldDrawAccidentalInMeasures(notes: []const model.Note, note_index: usize, meta: *const model.DocumentMeta, measures: []const model.Measure) bool {
    const note = notes[note_index];
    const spelling = noteSpelling(note);
    const measure_beats = meta.measureBeats();
    const measure_start = if (model.measureIndexAt(measures, note.start_beat)) |index| measures[index].start_beat else @floor(note.start_beat / measure_beats) * measure_beats;
    var expected = keyAlterForStep(spelling.step, meta.key_fifths);
    var measure_note_start: usize = 0;
    var measure_note_end = note_index;
    while (measure_note_start < measure_note_end) {
        const middle = measure_note_start + (measure_note_end - measure_note_start) / 2;
        if (notes[middle].start_beat < measure_start) measure_note_start = middle + 1 else measure_note_end = middle;
    }
    for (notes[measure_note_start..note_index]) |earlier| {
        if ((earlier.flags & model.note_flag_rest) != 0) continue;
        if (!sameNotationLayer(earlier, note) or earlier.staff != note.staff or earlier.start_beat < measure_start or earlier.start_beat >= note.start_beat) continue;
        const earlier_spelling = noteSpelling(earlier);
        if (earlier_spelling.step == spelling.step and earlier_spelling.octave == spelling.octave) expected = earlier_spelling.alter;
    }
    // One accidental applies to every matching unison in the chord.
    const onset = noteOnsetRange(notes, note.start_beat);
    for (notes[onset.start..@min(note_index, onset.end)], onset.start..) |earlier, earlier_index| {
        if ((earlier.flags & model.note_flag_rest) != 0) continue;
        if (!sameNotationLayer(earlier, note) or earlier.staff != note.staff or earlier.start_beat != note.start_beat) continue;
        const earlier_spelling = noteSpelling(earlier);
        if (earlier_spelling.step == spelling.step and earlier_spelling.octave == spelling.octave and earlier_spelling.alter == spelling.alter and shouldDrawAccidentalInMeasures(notes, earlier_index, meta, measures)) return false;
    }
    if ((note.flags & model.note_flag_explicit_accidental) != 0) return true;
    if (spelling.alter == expected) return false;
    return true;
}

fn accidentalColumn(notes: []const model.Note, note_index: usize, meta: *const model.DocumentMeta, measures: []const model.Measure) u8 {
    const note = notes[note_index];
    var placed: [32]struct { diatonic: i32, column: u8 } = undefined;
    var placed_count: usize = 0;
    const onset = noteOnsetRange(notes, note.start_beat);
    for (notes[onset.start .. note_index + 1], onset.start..) |candidate, candidate_index| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameOnsetVoiceLayer(candidate, note)) continue;
        if (!shouldDrawAccidentalInMeasures(notes, candidate_index, meta, measures)) continue;
        var occupied = [_]bool{false} ** 8;
        const candidate_diatonic = noteDiatonic(candidate);
        for (placed[0..placed_count]) |earlier| {
            if (@abs(earlier.diatonic - candidate_diatonic) <= 4) occupied[earlier.column] = true;
        }
        var column: u8 = 0;
        while (column + 1 < occupied.len and occupied[column]) column += 1;
        if (candidate_index == note_index) return column;
        if (placed_count < placed.len) {
            placed[placed_count] = .{ .diatonic = candidate_diatonic, .column = column };
            placed_count += 1;
        }
    }
    return 0;
}

fn accidentalRenderX(notes: []const model.Note, note_index: usize, note_x: f32, position: NotePosition, meta: *const model.DocumentMeta, measures: []const model.Measure) f32 {
    const column = accidentalColumn(notes, note_index, meta, measures);
    return @min(position.x, note_x) - 23 - @as(f32, @floatFromInt(column)) * 14;
}

fn accidentalGlyph(alter: i8) u21 {
    return switch (alter) {
        -2 => 0xe264,
        -1 => 0xe260,
        0 => 0xe261,
        1 => 0xe262,
        2 => 0xe263,
        else => 0xe261,
    };
}

fn drawKeySignature(packet: *render.Packet, start_x: f32, staff_y: f32, bass: bool, fifths: i8, music_em: f32, color: Color) f32 {
    const clamped = std.math.clamp(fifths, -7, 7);
    const count: usize = @intCast(if (clamped < 0) -clamped else clamped);
    if (count == 0) return start_x;

    // Standard circle-of-fifths order. The MIDI values are used only to share
    // the exact diatonic staff-position calculation used by notes; the
    // accidental glyph supplies the alteration itself.
    const treble_flats = [_]u8{ 71, 76, 69, 74, 67, 72, 65 }; // B E A D G C F
    const bass_flats = [_]u8{ 47, 52, 45, 50, 43, 48, 41 };
    const treble_sharps = [_]u8{ 77, 72, 79, 74, 69, 76, 71 }; // F C G D A E B
    const bass_sharps = [_]u8{ 53, 48, 55, 50, 45, 52, 47 };
    const pitches: *const [7]u8 = if (clamped < 0)
        (if (bass) &bass_flats else &treble_flats)
    else
        (if (bass) &bass_sharps else &treble_sharps);
    const base_diatonic: i32 = if (bass) 18 else 30;
    const glyph: u21 = if (clamped < 0) 0xe260 else 0xe262;
    const spacing: f32 = 7.6;
    for (pitches[0..count], 0..) |pitch, index| {
        const y = staff_y + 48 - @as(f32, @floatFromInt(pitchToDiatonic(pitch) - base_diatonic)) * 6;
        packet.musicGlyph(glyph, start_x + @as(f32, @floatFromInt(index)) * spacing, y, music_em, color);
    }
    return start_x + @as(f32, @floatFromInt(count)) * spacing;
}

fn drawTimeSignatureNumber(packet: *render.Packet, value: u8, center_x: f32, baseline_y: f32, music_em: f32, color: Color) void {
    var buffer: [4]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
    const digit_spacing: f32 = 10;
    const start_x = center_x - @as(f32, @floatFromInt(digits.len - 1)) * digit_spacing * 0.5;
    for (digits, 0..) |digit, index| {
        if (digit < '0' or digit > '9') continue;
        packet.musicGlyph(0xe080 + @as(u21, digit - '0'), start_x + @as(f32, @floatFromInt(index)) * digit_spacing, baseline_y, music_em, color);
    }
}

fn drawTimeSignature(packet: *render.Packet, center_x: f32, treble_y: f32, bass_y: f32, beats: u8, beat_unit: u8, music_em: f32, color: Color) void {
    drawTimeSignatureNumber(packet, @max(1, beats), center_x, treble_y + 12, music_em, color);
    drawTimeSignatureNumber(packet, @max(1, beat_unit), center_x, treble_y + 36, music_em, color);
    drawTimeSignatureNumber(packet, @max(1, beats), center_x, bass_y + 12, music_em, color);
    drawTimeSignatureNumber(packet, @max(1, beat_unit), center_x, bass_y + 36, music_em, color);
}

fn drawGrandStaffBrace(packet: *render.Packet, staff_x: f32, treble_y: f32, bass_y: f32, color: Color) void {
    const glyph = glyph_atlas.findMusic(0xe000) orelse return;
    const height_ems = glyph.plane[3] - glyph.plane[1];
    if (height_ems <= 0) return;

    const top = treble_y;
    const bottom = bass_y + 48;
    const em_size = (bottom - top) / height_ems;
    const baseline_y = top - glyph.plane[1] * em_size;
    // Keep a small optical gap between the brace and the analytic staff
    // connector. Deriving the origin from the right plane bound keeps this
    // exact when the Bravura atlas is regenerated.
    const origin_x = staff_x - 4 - glyph.plane[2] * em_size;
    packet.musicGlyph(0xe000, origin_x, baseline_y, em_size, color);
}

fn drawSingleTimeSignature(packet: *render.Packet, center_x: f32, staff_y: f32, beats: u8, beat_unit: u8, music_em: f32, color: Color) void {
    drawTimeSignatureNumber(packet, @max(1, beats), center_x, staff_y + 12, music_em, color);
    drawTimeSignatureNumber(packet, @max(1, beat_unit), center_x, staff_y + 36, music_em, color);
}

test "five-flat concert key signature emits five positioned GPU glyphs per staff" {
    var packet: render.Packet = undefined;
    packet.reset();
    const treble_end = drawKeySignature(&packet, 32, 100, false, -5, 48, palette.ink);
    const bass_end = drawKeySignature(&packet, 32, 168, true, -5, 48, palette.ink);
    try std.testing.expectEqual(@as(usize, 10), packet.len);
    try std.testing.expectApproxEqAbs(@as(f32, 70), treble_end, 0.001);
    try std.testing.expectApproxEqAbs(treble_end, bass_end, 0.001);
    try std.testing.expect(!packet.clipped);
}

test "SMuFL grand-staff brace spans both piano staves without touching the connector" {
    var packet: render.Packet = undefined;
    packet.reset();
    drawGrandStaffBrace(&packet, 100, 20, 88, palette.ink);
    try std.testing.expectEqual(@as(usize, 1), packet.len);
    const item = packet.slice()[0];
    try std.testing.expectEqual(@as(u32, @intFromEnum(render.Kind.glyph)), @as(u32, @intFromFloat(item.params[0] + 0.5)));
    try std.testing.expectApproxEqAbs(@as(f32, 20), item.rect[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 116), item.rect[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 96), item.rect[0] + item.rect[2], 0.001);
    try std.testing.expect(!packet.clipped);
}

test "score pages preserve authored variable-meter systems and positions" {
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 136, .beats = 4, .beat_unit = 4 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 137, .beats = 4, .beat_unit = 4 },
        .{ .start_beat = 8, .duration_beats = 2, .number = 138, .beats = 2, .beat_unit = 4 },
        .{ .start_beat = 10, .duration_beats = 4, .number = 139, .beats = 4, .beat_unit = 4 },
    };
    const meta: model.DocumentMeta = .{};
    const page = scorePageForBeat(&measures, 8, &meta, 1);
    try std.testing.expectEqual(@as(usize, 0), page.systems[0].first_measure);
    try std.testing.expectEqual(@as(usize, 2), page.systems[0].measure_end);
    try std.testing.expectEqual(@as(usize, 2), page.systems[1].first_measure);
    try std.testing.expectEqual(@as(usize, 4), page.systems[1].measure_end);
    try std.testing.expectEqual(@as(f32, 8), page.systems[1].start_beat);
    try std.testing.expectEqual(@as(f32, 14), page.systems[1].end_beat);

    const geometry = ScoreGeometry.calculate(.{ .x = 0, .y = 0, .width = 900, .height = 620 });
    const short_bar = scoreBeatPosition(geometry, page, &measures, 8) orelse return error.TestUnexpectedResult;
    const return_to_common = scoreBeatPosition(geometry, page, &measures, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), short_bar.system);
    try std.testing.expectEqual(@as(usize, 1), return_to_common.system);
    try std.testing.expect(short_bar.x < return_to_common.x);
    const return_barline_x = measureBoundaryX(geometry, page.systems[1], 10);
    try std.testing.expectApproxEqAbs(geometry.music_x + geometry.music_width / 3, return_barline_x, 0.01);
    // The mid-system 4/4 glyph is centered at barline + 8. Beat-one content
    // must begin beyond its right edge instead of colliding with the meter.
    try std.testing.expect(return_to_common.x >= return_barline_x + 39.9);
    try std.testing.expectApproxEqAbs(@as(f32, 10), scoreBeatAtX(geometry, page, &measures, 1, return_to_common.x), 0.001);

    const inside_short_bar = scoreBeatPosition(geometry, page, &measures, 9) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(
        @as(f32, 9),
        scoreBeatAtX(geometry, page, &measures, inside_short_bar.system, inside_short_bar.x),
        0.001,
    );
}

test "short final score page contains no phantom empty system" {
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
        .{ .start_beat = 8, .duration_beats = 4, .number = 3 },
        .{ .start_beat = 12, .duration_beats = 4, .number = 4 },
        .{ .start_beat = 16, .duration_beats = 4, .number = 5 },
    };
    const page = scorePageForBeat(&measures, 16, &.{}, 1);
    try std.testing.expectEqual(@as(u32, 1), page.page_index);
    try std.testing.expectEqual(@as(usize, 1), page.system_count);
    try std.testing.expectEqual(@as(f32, 16), page.startBeat());
    try std.testing.expectEqual(@as(f32, 20), page.endBeat());
    try std.testing.expectEqual(@as(usize, 5), page.systems[1].first_measure);
    try std.testing.expectEqual(page.systems[1].first_measure, page.systems[1].measure_end);
}

test "paged score reports a finite page count and exposes edge controls" {
    var measures: [9]model.Measure = undefined;
    for (&measures, 0..) |*measure, index| {
        measure.* = .{
            .start_beat = @as(f32, @floatFromInt(index)) * 4,
            .duration_beats = 4,
            .number = @intCast(index + 1),
            .beats = 4,
            .beat_unit = 4,
        };
    }
    try std.testing.expectEqual(@as(u32, 3), scorePageCount(&measures, &.{}, 1));
    const layout = Layout.calculate(1280, 800, true);
    try std.testing.expect(layout.page_previous.width >= 34);
    try std.testing.expect(layout.page_next.x > layout.page_previous.x);
    try std.testing.expect(layout.stage.contains(layout.page_previous.x + 1, layout.page_previous.y + 1));
    try std.testing.expect(layout.stage.contains(layout.page_next.x + 1, layout.page_next.y + 1));
    try std.testing.expect(layout.instrument_setup.width > 0);
    try std.testing.expect(layout.instrument_setup.y >= layout.replay_take.y + layout.replay_take.height);
    try std.testing.expect(layout.instrument_setup.y + layout.instrument_setup.height <= layout.library_trigger.y);
}

test "constrained vocal score paginates one complete system without crossing the keyboard" {
    var measures: [6]model.Measure = undefined;
    for (&measures, 0..) |*measure, index| {
        measure.* = .{
            .start_beat = @as(f32, @floatFromInt(index)) * 4,
            .duration_beats = 4,
            .number = @intCast(index + 1),
            .beats = 4,
            .beat_unit = 4,
        };
    }
    const layout = Layout.calculate(720, 540, true);
    const systems_per_page = scoreSystemsPerPage(layout.stage.height, true);
    try std.testing.expectEqual(@as(usize, 1), systems_per_page);
    const page = scorePageForBeatLimited(&measures, 0, &.{}, 1, systems_per_page);
    try std.testing.expectEqual(@as(usize, 1), page.system_count);
    try std.testing.expectEqual(@as(f32, 8), page.endBeat());
    try std.testing.expectEqual(@as(u32, 3), scorePageCountLimited(&measures, &.{}, 1, systems_per_page));

    const geometry = ScoreGeometry.calculateWithVocal(layout.stage, true);
    try std.testing.expect(geometry.page_y + geometry.page_height <= layout.stage.y + layout.stage.height + 0.001);
    try std.testing.expect(geometry.bass_y[0] + 49 <= geometry.page_y + geometry.page_height + 0.001);
    // Coaching text must clear the full upward-beam ink bound, not merely the
    // treble staff line. This is the compact-window collision regression.
    try std.testing.expect(geometry.lyric_y[0] + 12 <= geometry.treble_y[0] - 29);
    try std.testing.expect(layout.keyboard_panel.y >= layout.stage.y + layout.stage.height);
    try std.testing.expect(layout.tools.y >= layout.keyboard_panel.y + layout.keyboard_panel.height);
}

test "roomy vocal pages retain two systems with collision-safe vertical spacing" {
    const stage = Rect{ .x = 0, .y = 0, .width = 1200, .height = 760 };
    try std.testing.expectEqual(@as(usize, 2), scoreSystemsPerPage(stage.height, true));
    const geometry = ScoreGeometry.calculateWithVocal(stage, true);
    // Reserve the complete 29 px upward-beam reach below coaching text.
    try std.testing.expect(geometry.lyric_y[0] + 12 <= geometry.treble_y[0] - 29);
    try std.testing.expect(geometry.vocal_y[1] >= geometry.bass_y[0] + 96);
    try std.testing.expect(geometry.bass_y[1] + 49 <= geometry.page_y + geometry.page_height + 0.001);
}

test "printable staff rules cannot disappear between raster sample centers" {
    var packet: render.Packet = .{};
    packet.rect(40, 120.42, 900, 0.85, palette.ink);
    packet.rect(40, 140, 60, 0.85, palette.ink);
    stabilizePrintableRules(&packet);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), packet.items[0].rect[3], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 120.22), packet.items[0].rect[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), packet.items[1].rect[3], 0.001);
}

test "page heading owns a real clef-ink clearance lane" {
    const stage = Rect{ .x = 0, .y = 0, .width = 1200, .height = 760 };
    const vocal_geometry = ScoreGeometry.calculateForSystems(stage, true, 2);
    const piano_geometry = ScoreGeometry.calculateForSystems(stage, false, 2);
    const source_label_ink_bottom = vocal_geometry.page_y + 78;
    try std.testing.expect(vocal_geometry.vocal_y[0] - 34 >= source_label_ink_bottom + 10);
    try std.testing.expect(piano_geometry.treble_y[0] - 34 >= source_label_ink_bottom + 10);
}

test "paged zoom merges more systems onto one sheet" {
    const stage = Rect{ .x = 80, .y = 64, .width = 1800, .height = 1000 };
    const normal = zoomedScoreStage(stage, 1);
    const overview = zoomedScoreStage(stage, 0.65);
    const deep_overview = zoomedScoreStage(stage, min_score_zoom);
    try std.testing.expectEqual(stage.height, normal.height);
    try std.testing.expect(overview.height > normal.height);
    try std.testing.expect(deep_overview.height > overview.height);
    try std.testing.expect(scoreSystemsPerPage(overview.height, true) > scoreSystemsPerPage(normal.height, true));
    try std.testing.expect(scoreSystemsPerPage(deep_overview.height, true) > scoreSystemsPerPage(overview.height, true));
}

test "tall score pages paginate and hit-test six complete systems" {
    var measures: [48]model.Measure = undefined;
    for (&measures, 0..) |*measure, index| {
        measure.* = .{
            .start_beat = @as(f32, @floatFromInt(index)) * 4,
            .duration_beats = 4,
            .number = @intCast(index + 1),
            .beats = 4,
            .beat_unit = 4,
        };
    }
    const stage = Rect{ .x = 0, .y = 0, .width = 1400, .height = 1100 };
    const systems_per_page = scoreSystemsPerPage(stage.height, false);
    try std.testing.expectEqual(@as(usize, 6), systems_per_page);
    const page = scorePageForBeatLimited(&measures, 0, &.{}, 1, systems_per_page);
    try std.testing.expectEqual(@as(usize, 6), page.system_count);
    try std.testing.expectEqual(@as(f32, 48), page.endBeat());
    try std.testing.expectEqual(@as(u32, 4), scorePageCountLimited(&measures, &.{}, 1, systems_per_page));

    const geometry = ScoreGeometry.calculateForSystems(stage, false, page.system_count);
    for (0..page.system_count) |system| {
        const center_y = (geometry.treble_y[system] + geometry.bass_y[system] + 49) * 0.5;
        try std.testing.expectEqual(system, scoreSystemAtY(geometry, page, false, center_y));
        if (system > 0) try std.testing.expect(geometry.treble_y[system] >= geometry.bass_y[system - 1] + 82);
    }
    try std.testing.expect(geometry.bass_y[page.system_count - 1] + 49 <= geometry.page_y + geometry.page_height + 0.001);
}

test "tall vocal pages add systems without crossing lyric or page lanes" {
    const stage = Rect{ .x = 0, .y = 0, .width = 1400, .height = 1500 };
    const systems = scoreSystemsPerPage(stage.height, true);
    try std.testing.expectEqual(@as(usize, 4), systems);
    const geometry = ScoreGeometry.calculateForSystems(stage, true, systems);
    for (0..systems) |system| {
        try std.testing.expect(geometry.lyric_y[system] + 16 <= geometry.treble_y[system]);
        if (system > 0) try std.testing.expect(geometry.vocal_y[system] >= geometry.bass_y[system - 1] + 96);
    }
    try std.testing.expect(geometry.bass_y[systems - 1] + 49 <= geometry.page_y + geometry.page_height + 0.001);
}

test "zooming out reflows more complete measures onto each score page" {
    var measures: [12]model.Measure = undefined;
    for (&measures, 0..) |*measure, index| {
        measure.* = .{
            .start_beat = @as(f32, @floatFromInt(index)) * 4,
            .duration_beats = 4,
            .number = @intCast(index + 1),
            .beats = 4,
            .beat_unit = 4,
        };
    }
    const normal = scorePageForBeat(&measures, 0, &.{}, 1);
    const overview = scorePageForBeat(&measures, 0, &.{}, 0.65);
    try std.testing.expectEqual(@as(usize, 2), normal.systems[0].measure_end);
    try std.testing.expectEqual(@as(usize, 3), overview.systems[0].measure_end);
    try std.testing.expect(scorePageCount(&measures, &.{}, 0.65) < scorePageCount(&measures, &.{}, 1));
    try std.testing.expectEqual(@as(f32, 0), overview.startBeat());
}

test "continuous pan buffers a look-ahead system and translates analytic GPU items" {
    try std.testing.expectEqual(@as(usize, 2), continuousBufferedSystemCount(1));
    try std.testing.expectEqual(@as(usize, 4), continuousBufferedSystemCount(3));
    try std.testing.expectEqual(max_score_systems, continuousBufferedSystemCount(max_score_systems));
    const stage = Rect{ .x = 20, .y = 40, .width = 900, .height = 620 };
    try std.testing.expect(scoreSystemStride(stage, false, 2) > 100);
    try std.testing.expect(scoreSystemStride(stage, true, 2) > 100);

    var packet: render.Packet = undefined;
    packet.reset();
    packet.rect(10, 20, 30, 40, palette.ink);
    packet.line(10, 25, 80, 35, 2, palette.ink);
    translateScoreItemsY(&packet, 0, -12);
    try std.testing.expectApproxEqAbs(@as(f32, 8), packet.items[0].rect[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 13), packet.items[1].rect[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 23), packet.items[1].rect[3], 0.001);
}

test "time signatures engrave both staves and multi-digit meters" {
    var packet: render.Packet = undefined;
    packet.reset();
    drawTimeSignature(&packet, 100, 80, 148, 12, 8, 48, palette.ink);
    try std.testing.expectEqual(@as(usize, 6), packet.len);
    try std.testing.expect(!packet.clipped);
}

pub fn draw(
    packet: *render.Packet,
    state: *const model.UiState,
    transport: *const model.Transport,
    practice: *const model.PracticeState,
    meta: *const model.DocumentMeta,
    notes: []const model.Note,
    lyrics: []const model.Lyric,
    harmonies: []const model.Harmony,
    hairpins: []const model.Hairpin,
    pedals: []const model.PedalEvent,
    measures: []const model.Measure,
    annotations: *const annotation.Store,
    time_seconds: f32,
) void {
    packet.reset();
    if (state.app_view == .controller) {
        drawController(packet, state, time_seconds);
        return;
    }
    const layout = Layout.calculateForState(state);

    packet.rect(0, 0, state.viewport_width, state.viewport_height, palette.background);
    drawScore(packet, layout.stage, state, transport, meta, notes, lyrics, harmonies, hairpins, pedals, measures, annotations, time_seconds);
    // Score content may be translated while freely panning continuous mode.
    // Repaint fixed chrome afterward so off-viewport notation is clipped by
    // the panels on every GPU backend without introducing a software path.
    if (layout.top.height > 0) drawTopBar(packet, layout, state, meta);
    if (layout.tools.width > 0 or layout.tools.height > 0) drawTools(packet, layout, state.tool);
    if (layout.keyboard_panel.height > 0) drawKeyboard(packet, layout.keyboard_panel, state, transport, notes, pedals);
    if (layout.coach) |coach| drawCoach(packet, coach, state, practice);
    drawTransport(packet, layout, state, transport, meta, measures, time_seconds);
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
            8 => "SCORE FILE EXPORTED",
            9 => "SHADER ERROR - LAST GOOD PIPELINE KEPT",
            10 => "GPU SHADER HOT RELOADED",
            11 => "MIDI TAKE EXPORTED",
            12 => "CHOOSE AN SFZ INSTRUMENT",
            13 => "INSTRUMENT LOADED + AUDIO READY",
            14 => "INSTRUMENT LOAD FAILED - PREVIOUS KEPT",
            15 => "LOADING SAMPLED GRAND PIANO...",
            16 => "AUDIO COULD NOT START",
            17 => "CLICK PLAY AGAIN TO ENABLE SOUND",
            else => "SCORE IS READY",
        };
        packet.text(x + 18, 101, message, 1.75, if (state.notice == 3 or state.notice == 5 or state.notice == 9 or state.notice == 14 or state.notice == 16) palette.rose else palette.text);
    }
}

fn drawController(packet: *render.Packet, state: *const model.UiState, time_seconds: f32) void {
    const layout = ControllerLayout.calculate(state.viewport_width, state.viewport_height);
    packet.rect(0, 0, state.viewport_width, state.viewport_height, palette.background);
    packet.rect(0, 0, state.viewport_width, layout.header.height, palette.panel);
    packet.rect(0, layout.header.height - 1, state.viewport_width, 1, palette.border);

    const score_hovered = layout.score_view.contains(state.pointer_x, state.pointer_y);
    packet.rounded(layout.score_view.x, layout.score_view.y, layout.score_view.width, layout.score_view.height, 12, if (score_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.score_view.x + 16, layout.score_view.y + 16, "SCORE", 1.35, if (score_hovered) palette.cyan else palette.text);
    if (state.viewport_width >= 620) {
        packet.text(layout.score_view.x + layout.score_view.width + 22, 19, "PERFORMANCE CONTROLLER", 2.15, palette.text);
        packet.text(layout.score_view.x + layout.score_view.width + 24, 45, if (state.controller_editing != 0) "CUSTOM PAD EDITOR / TAP A PAD, THEN SET ITS MESSAGE" else "MULTITOUCH / PENCIL PRESSURE / OSC / MIDI", 0.72, if (state.controller_editing != 0) palette.amber else palette.muted);
    }

    const protocol_hovered = layout.protocol.contains(state.pointer_x, state.pointer_y);
    const protocol_color = if (state.controller_protocol == .osc) palette.cyan else palette.amber;
    packet.rounded(layout.protocol.x, layout.protocol.y, layout.protocol.width, layout.protocol.height, 12, if (protocol_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.protocol.x + 15, layout.protocol.y + 15, if (state.controller_protocol == .osc) "OSC" else "MIDI", 1.45, if (protocol_hovered) palette.text else protocol_color);

    const edit_hovered = layout.edit.contains(state.pointer_x, state.pointer_y);
    const editing = state.controller_editing != 0;
    packet.rounded(layout.edit.x, layout.edit.y, layout.edit.width, layout.edit.height, 12, if (editing) mixColor(palette.panel, palette.amber, 0.24) else if (edit_hovered) palette.panel_raised else palette.panel);
    packet.text(layout.edit.x + 15, layout.edit.y + 15, if (editing) "DONE" else "EDIT", 1.18, if (editing or edit_hovered) palette.amber else palette.text);

    for (layout.banks, 0..) |button, index| {
        const selected = index == @intFromEnum(state.controller_bank);
        const hovered = button.contains(state.pointer_x, state.pointer_y);
        packet.rounded(button.x, button.y, button.width, button.height, 11, if (selected) palette.cyan_dim else if (hovered) palette.panel_raised else palette.panel);
        const labels = [_][]const u8{ "PADS", "CLIPS", "ACTIONS", "USER" };
        const label = labels[index];
        const scale = std.math.clamp((button.width - 14) / @max(1, render.Packet.textWidth(label, 1)), 0.64, 1.05);
        packet.text(button.x + (button.width - render.Packet.textWidth(label, scale)) * 0.5, button.y + 16, label, scale, if (selected) palette.cyan else if (hovered) palette.text else palette.muted);
    }

    drawControllerSmallButton(packet, layout.octave_down, state, "OCT -", palette.amber);
    drawControllerSmallButton(packet, layout.octave_up, state, "OCT +", palette.amber);
    const setup_hovered = layout.setup.contains(state.pointer_x, state.pointer_y);
    packet.rounded(layout.setup.x, layout.setup.y, layout.setup.width, layout.setup.height, 11, if (setup_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.setup.x + 12, layout.setup.y + 16, "SETUP", if (layout.setup.width < 80) 0.9 else 1.05, if (setup_hovered) palette.cyan else palette.text);

    if (state.viewport_width >= 900) {
        var status_buffer: [96]u8 = undefined;
        const status = if (state.controller_editing != 0)
            "BITWIG: MAPPING PANEL > PARAMETER > DONE > PRESS PAD"
        else if (state.controller_protocol == .midi)
            "COREMIDI / NETWORK MIDI"
        else if (state.controller_target_len == 0)
            "OSC TARGET NOT CONFIGURED"
        else
            std.fmt.bufPrint(&status_buffer, "OSC  {s}", .{state.controllerTarget()}) catch "OSC TARGET";
        packet.text(layout.banks[0].x, layout.banks[0].y - 12, status, 0.66, if (state.controller_status == 2) palette.rose else if (state.controller_status == 1) palette.green else palette.muted);
    }

    for (layout.pads, 0..) |pad, index| {
        const mask = @as(u32, 1) << @intCast(index);
        const pressed = (state.controller_pressed_pads & mask) != 0 or (state.controller_bank == .user and (state.controller_toggled_pads & mask) != 0);
        const selected_for_edit = editing and state.controller_bank == .user and index == @min(state.controller_selected_pad, 15);
        const hovered = pad.contains(state.pointer_x, state.pointer_y);
        const row: usize = if (state.controller_bank == .user) @intCast(@min(state.controller_assignments[index].color, 3)) else index / 4;
        const accent = switch (row) {
            0 => palette.cyan,
            1 => palette.green,
            2 => palette.amber,
            else => palette.rose,
        };
        const base = switch (row) {
            0 => Color{ 0.08, 0.25, 0.27, 1 },
            1 => Color{ 0.13, 0.25, 0.19, 1 },
            2 => Color{ 0.27, 0.20, 0.10, 1 },
            else => Color{ 0.28, 0.12, 0.17, 1 },
        };
        if (pressed or selected_for_edit) packet.glow(pad.x - 7, pad.y - 7, pad.width + 14, pad.height + 14, if (pressed) 18 else 10, if (selected_for_edit) palette.amber else accent, time_seconds);
        packet.rounded(pad.x, pad.y, pad.width, pad.height, @min(18, pad.width * 0.14), if (pressed) accent else if (hovered) mixColor(base, accent, 0.25) else base);
        drawControllerPadLabel(packet, pad, state, index, if (pressed) palette.background else palette.text);
    }

    const transport_labels = [_][]const u8{ "STOP", "PLAY", "RECORD", "LOOP", "CLICK", "UNDO", "REDO", "SAVE" };
    for (layout.transport, 0..) |button, index| {
        if (editing and state.controller_bank == .user) {
            drawControllerEditCell(packet, button, state, index);
            continue;
        }
        const pressed = (state.controller_pressed_transport & (@as(u32, 1) << @intCast(index))) != 0;
        const hovered = button.contains(state.pointer_x, state.pointer_y);
        const accent = switch (index) {
            0 => palette.rose,
            1 => palette.green,
            2 => palette.rose,
            3, 4 => palette.amber,
            else => palette.cyan,
        };
        if (pressed) packet.glow(button.x - 7, button.y - 7, button.width + 14, button.height + 14, 18, accent, time_seconds);
        packet.rounded(button.x, button.y, button.width, button.height, @min(18, button.width * 0.14), if (pressed) accent else if (hovered) mixColor(palette.panel_raised, accent, 0.24) else palette.panel_raised);
        const label = transport_labels[index];
        const scale = std.math.clamp((button.width - 22) / @max(1, render.Packet.textWidth(label, 1)), 0.72, 1.2);
        packet.text(button.x + (button.width - render.Packet.textWidth(label, scale)) * 0.5, button.y + button.height * 0.48, label, scale, if (pressed) palette.background else accent);
    }
}

fn drawControllerSmallButton(packet: *render.Packet, button: Rect, state: *const model.UiState, label: []const u8, accent: Color) void {
    const hovered = button.contains(state.pointer_x, state.pointer_y);
    packet.rounded(button.x, button.y, button.width, button.height, 11, if (hovered) mixColor(palette.panel_raised, accent, 0.22) else palette.panel_raised);
    packet.text(button.x + 10, button.y + 16, label, if (button.width < 54) 0.72 else 0.85, if (hovered) accent else palette.text);
}

fn drawControllerEditCell(packet: *render.Packet, button: Rect, state: *const model.UiState, index: usize) void {
    const selected: usize = @intCast(@min(state.controller_selected_pad, 15));
    const assignment = state.controller_assignments[selected];
    const hovered = button.contains(state.pointer_x, state.pointer_y);
    var secondary_buffer: [24]u8 = undefined;
    const primary = switch (index) {
        0, 1 => "TYPE",
        2, 3 => switch (assignment.kind) {
            .note, .drum => "NOTE",
            .cc => "CC",
            .clip => "SCENE",
            .action => "ACTION",
        },
        4, 5 => if (assignment.kind == .clip) "TRACK" else "CHANNEL",
        6 => "BEHAVIOR",
        else => "COLOR",
    };
    const secondary: []const u8 = switch (index) {
        0 => "PREVIOUS",
        1 => "NEXT",
        2 => "-",
        3 => "+",
        4 => "-",
        5 => "+",
        6 => if (assignment.behavior == .momentary) "MOMENTARY" else "TOGGLE",
        else => std.fmt.bufPrint(&secondary_buffer, "SWATCH {d}", .{@as(u16, @min(assignment.color, 3)) + 1}) catch "SWATCH",
    };
    const accent = switch (index) {
        0, 1 => palette.cyan,
        2, 3 => palette.green,
        4, 5 => palette.amber,
        6 => palette.rose,
        else => palette.cyan,
    };
    packet.rounded(button.x, button.y, button.width, button.height, @min(18, button.width * 0.14), if (hovered) mixColor(palette.panel_raised, accent, 0.25) else palette.panel_raised);
    const primary_scale = std.math.clamp((button.width - 18) / @max(1, render.Packet.textWidth(primary, 1)), 0.54, 0.82);
    packet.text(button.x + (button.width - render.Packet.textWidth(primary, primary_scale)) * 0.5, button.y + button.height * 0.36, primary, primary_scale, palette.muted);
    const secondary_scale = std.math.clamp((button.width - 18) / @max(1, render.Packet.textWidth(secondary, 1)), 0.52, 1.12);
    packet.text(button.x + (button.width - render.Packet.textWidth(secondary, secondary_scale)) * 0.5, button.y + button.height * 0.61, secondary, secondary_scale, accent);
}

fn drawControllerPadLabel(packet: *render.Packet, pad: Rect, state: *const model.UiState, index: usize, color: Color) void {
    var primary_buffer: [32]u8 = undefined;
    var secondary_buffer: [32]u8 = undefined;
    const primary: []const u8 = switch (state.controller_bank) {
        .pads => blk: {
            const midi_note: u8 = @intCast(std.math.clamp(state.controller_octave * 12 + 12 + @as(i32, @intCast(index)), 0, 127));
            break :blk noteLabel(&primary_buffer, midi_note);
        },
        .clips => std.fmt.bufPrint(&primary_buffer, "TRACK {d}", .{index % 4 + 1}) catch "TRACK",
        .actions => std.fmt.bufPrint(&primary_buffer, "ACTION {d}", .{index + 1}) catch "ACTION",
        .user => switch (state.controller_assignments[index].kind) {
            .note => noteLabel(&primary_buffer, state.controller_assignments[index].value),
            .drum => std.fmt.bufPrint(&primary_buffer, "DRUM {d}", .{state.controller_assignments[index].value}) catch "DRUM",
            .cc => std.fmt.bufPrint(&primary_buffer, "CC {d}", .{state.controller_assignments[index].value}) catch "CC",
            .clip => std.fmt.bufPrint(&primary_buffer, "CLIP {d}", .{@as(u16, state.controller_assignments[index].value) + 1}) catch "CLIP",
            .action => std.fmt.bufPrint(&primary_buffer, "ACTION {d}", .{@as(u16, state.controller_assignments[index].value) + 1}) catch "ACTION",
        },
    };
    const secondary: []const u8 = switch (state.controller_bank) {
        .pads => blk: {
            const midi_note: u8 = @intCast(std.math.clamp(state.controller_octave * 12 + 12 + @as(i32, @intCast(index)), 0, 127));
            break :blk std.fmt.bufPrint(&secondary_buffer, "NOTE {d}", .{midi_note}) catch "NOTE";
        },
        .clips => std.fmt.bufPrint(&secondary_buffer, "SCENE {d}", .{index / 4 + 1}) catch "SCENE",
        .actions => "BITWIG / MAP",
        .user => blk: {
            const assignment = state.controller_assignments[index];
            break :blk switch (assignment.kind) {
                .clip => std.fmt.bufPrint(&secondary_buffer, "TRACK {d}", .{@as(u16, assignment.channel) + 1}) catch "TRACK",
                else => std.fmt.bufPrint(&secondary_buffer, "CH {d} / {s}", .{ @as(u16, assignment.channel) + 1, if (assignment.behavior == .momentary) "MOM" else "TOGGLE" }) catch "USER",
            };
        },
    };
    const primary_scale = std.math.clamp((pad.width - 20) / @max(1, render.Packet.textWidth(primary, 1)), 0.78, 1.35);
    packet.text(pad.x + (pad.width - render.Packet.textWidth(primary, primary_scale)) * 0.5, pad.y + pad.height * 0.42, primary, primary_scale, color);
    const secondary_scale = std.math.clamp((pad.width - 22) / @max(1, render.Packet.textWidth(secondary, 1)), 0.54, 0.74);
    packet.text(pad.x + (pad.width - render.Packet.textWidth(secondary, secondary_scale)) * 0.5, pad.y + pad.height * 0.66, secondary, secondary_scale, color);
}

fn noteLabel(buffer: []u8, midi_note: u8) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const octave = @divTrunc(@as(i16, midi_note), 12) - 1;
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ names[midi_note % 12], octave }) catch "NOTE";
}

fn mixColor(left: Color, right: Color, amount: f32) Color {
    const t = std.math.clamp(amount, 0, 1);
    return .{
        left[0] + (right[0] - left[0]) * t,
        left[1] + (right[1] - left[1]) * t,
        left[2] + (right[2] - left[2]) * t,
        left[3] + (right[3] - left[3]) * t,
    };
}

fn drawTopBar(packet: *render.Packet, layout: Layout, state: *const model.UiState, meta: *const model.DocumentMeta) void {
    packet.rect(layout.top.x, layout.top.y, layout.top.width, layout.top.height, palette.panel);
    packet.rect(0, layout.top.height - 1, layout.top.width, 1, palette.border);
    packet.glow(18, 17, 36, 36, 12, palette.cyan_dim, 0.15);
    packet.text(28, 27, "S", 2.3, palette.cyan);
    if (layout.top.width >= 600) {
        packet.text(70, 22, "SCORE", 3.0, palette.text);
        if (layout.top.height >= 65) packet.text(70, 47, meta.titleSlice(), 1.25, palette.muted);
    }
    if (layout.app_view_toggle.width > 0) {
        const controller_hovered = layout.app_view_toggle.contains(state.pointer_x, state.pointer_y);
        packet.rounded(layout.app_view_toggle.x, layout.app_view_toggle.y, layout.app_view_toggle.width, layout.app_view_toggle.height, 12, if (controller_hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.app_view_toggle.x + 15, layout.app_view_toggle.y + 15, "CONTROLLER", 1.08, if (controller_hovered) palette.cyan else palette.text);
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
    if (layout.part_selector.width > 0 and @popCount(state.instrument_part_mask) > 1) {
        const part_hovered = layout.part_selector.contains(state.pointer_x, state.pointer_y);
        packet.rounded(layout.part_selector.x, layout.part_selector.y, layout.part_selector.width, layout.part_selector.height, 12, if (part_hovered) palette.cyan_dim else palette.panel_raised);
        const source_label = if (state.selected_part_label_len != 0) state.selectedPartLabel() else "PART";
        const name_scale = std.math.clamp((layout.part_selector.width - 22) / @max(1, render.Packet.textWidth(source_label, 1)), 0.58, 0.82);
        packet.text(layout.part_selector.x + 11, layout.part_selector.y + 9, source_label, name_scale, if (part_hovered) palette.cyan else palette.text);
        var ordinal_buffer: [24]u8 = undefined;
        const ordinal = std.fmt.bufPrint(&ordinal_buffer, "PART {d} OF {d}", .{ model.instrumentPartOrdinal(state.instrument_part_mask, state.selected_part), @popCount(state.instrument_part_mask) }) catch "PART";
        packet.text(layout.part_selector.x + 11, layout.part_selector.y + 26, ordinal, 0.55, palette.muted);
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

pub fn hasVocalGuide(notes: []const model.Note) bool {
    for (notes) |note| {
        if ((note.flags & model.note_flag_vocal_guide) != 0) return true;
    }
    return false;
}

/// Pure, hot-swappable screen composition: persistent Metal resources remain
/// in the native host while this function rebuilds the frame packet.
fn drawScore(packet: *render.Packet, stage: Rect, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, notes: []const model.Note, lyrics: []const model.Lyric, harmonies: []const model.Harmony, hairpins: []const model.Hairpin, pedals: []const model.PedalEvent, measures: []const model.Measure, annotations: *const annotation.Store, time_seconds: f32) void {
    packet.rect(stage.x, stage.y, stage.width, stage.height, .{ 0.045, 0.052, 0.064, 1 });
    const zoom = std.math.clamp(state.zoom, min_score_zoom, max_score_zoom);
    const vocal_visible = state.vocal_guide_visible != 0 and hasVocalGuide(notes);
    const reflow_stage = zoomedScoreStage(stage, zoom);
    const systems_per_page = scoreSystemsPerPage(reflow_stage.height, vocal_visible);
    const page_count = scorePageCountLimited(measures, meta, zoom, systems_per_page);
    if (state.score_view_mode == .paged) {
        const page = scorePageForBeatLimited(measures, state.view_start_beat, meta, zoom, systems_per_page);
        const start = packet.len;
        drawScorePage(packet, reflow_stage, state, transport, meta, notes, lyrics, harmonies, hairpins, pedals, measures, time_seconds, page, page_count, page.system_count);
        drawAnnotationsPage(packet, reflow_stage, page, vocal_visible, measures, annotations);
        transformScoreItemsTopAnchored(packet, start, stage, zoom);
        drawPageNavigation(packet, Layout.calculateForState(state), state, page.page_index + 1, page.page_index + 1, page_count);
        return;
    }

    const buffered_systems = continuousBufferedSystemCount(systems_per_page);
    const page = scoreContinuousForBeatLimited(measures, state.view_start_beat, meta, zoom, buffered_systems);
    const displayed_count = scoreSystemCount(measures, zoom);
    // The continuous paper is the viewport surface, not a transformed page.
    // Keep it edge-to-edge while its notation layer responds to zoom.
    packet.rect(stage.x, stage.y, stage.width, stage.height, palette.paper);
    const start = packet.len;
    drawScorePage(packet, reflow_stage, state, transport, meta, notes, lyrics, harmonies, hairpins, pedals, measures, time_seconds, page, displayed_count, systems_per_page);
    drawAnnotationsPageWithLayout(packet, reflow_stage, page, vocal_visible, measures, annotations, systems_per_page);
    const pan_fraction = if (page.system_count > systems_per_page) std.math.clamp(state.continuous_pan_fraction, 0, 0.9999) else 0;
    translateScoreItemsY(packet, start, -pan_fraction * scoreSystemStride(reflow_stage, vocal_visible, systems_per_page));
    transformScoreItemsTopAnchored(packet, start, stage, zoom);
    drawPageNavigation(packet, Layout.calculateForState(state), state, page.page_index + 1, page.page_index + 1, displayed_count);
}

/// Build one clean, complete authored sheet for print/PDF export.  This uses
/// the exact GPU engraving path used on screen, but excludes all application
/// chrome, navigation controls and playback highlights.
pub fn drawPrintablePage(
    packet: *render.Packet,
    width: f32,
    height: f32,
    requested_beat: f32,
    source_state: *const model.UiState,
    source_transport: *const model.Transport,
    meta: *const model.DocumentMeta,
    notes: []const model.Note,
    lyrics: []const model.Lyric,
    harmonies: []const model.Harmony,
    hairpins: []const model.Hairpin,
    pedals: []const model.PedalEvent,
    measures: []const model.Measure,
    annotations: *const annotation.Store,
) ScorePage {
    packet.reset();
    var state = source_state.*;
    state.viewport_width = width;
    state.viewport_height = height;
    state.zoom = 1;
    state.score_view_mode = .paged;
    state.tool = .read;
    state.pedal_edit_selected = 0;
    state.pointer_x = -10_000;
    state.pointer_y = -10_000;
    var transport = source_transport.*;
    transport.playing = 0;
    transport.cursor_beat = -10_000;
    const vocal_visible = state.vocal_guide_visible != 0 and hasVocalGuide(notes);
    // Expanding the source stage by the normal screen margins makes the
    // resulting paper exactly fill the PDF page while retaining its internal
    // 48 px notation padding.
    const stage = Rect{ .x = -46, .y = -10, .width = width + 92, .height = height + 20 };
    const systems_per_page = scoreSystemsPerPage(stage.height, vocal_visible);
    const page = scorePageForBeatLimited(measures, requested_beat, meta, 1, systems_per_page);
    const page_count = scorePageCountLimited(measures, meta, 1, systems_per_page);
    // Keep the same top-down system spacing on the final partial PDF page as
    // on every full page. Only authored systems are drawn; the layout count
    // merely prevents a short final page from stretching them to both edges.
    drawScorePage(packet, stage, &state, &transport, meta, notes, lyrics, harmonies, hairpins, pedals, measures, 0, page, page_count, systems_per_page);
    drawAnnotationsPage(packet, stage, page, vocal_visible, measures, annotations);
    stabilizePrintableRules(packet);
    return page;
}

/// A screen point covers multiple physical pixels on a Retina swapchain, but
/// the offscreen PDF texture uses one logical point per pixel. Staff rules
/// thinner than one pixel can therefore fall entirely between sample centers
/// on some systems. Preserve their optical center and promote only long,
/// horizontal hairlines to a raster-stable printable thickness.
fn stabilizePrintableRules(packet: *render.Packet) void {
    for (packet.items[0..packet.len]) |*item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .rect or item.rect[2] < 100 or item.rect[3] <= 0 or item.rect[3] > 1) continue;
        const printable_thickness: f32 = 1.25;
        item.rect[1] -= (printable_thickness - item.rect[3]) * 0.5;
        item.rect[3] = printable_thickness;
    }
}

fn transformScoreItemsTopAnchored(packet: *render.Packet, start: usize, stage: Rect, scale: f32) void {
    if (@abs(scale - 1) < 0.0001) return;
    const center_x = stage.x + stage.width * 0.5;
    const top_y = stage.y;
    for (packet.items[start..packet.len]) |*item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line) {
            item.rect[0] = center_x + (item.rect[0] - center_x) * scale;
            item.rect[1] = top_y + (item.rect[1] - top_y) * scale;
            item.rect[2] = center_x + (item.rect[2] - center_x) * scale;
            item.rect[3] = top_y + (item.rect[3] - top_y) * scale;
            item.params[1] *= scale;
        } else {
            item.rect[0] = center_x + (item.rect[0] - center_x) * scale;
            item.rect[1] = top_y + (item.rect[1] - top_y) * scale;
            item.rect[2] *= scale;
            item.rect[3] *= scale;
            if (kind == .rounded_rect) item.params[1] *= scale;
        }
    }
}

fn translateScoreItemsY(packet: *render.Packet, start: usize, delta_y: f32) void {
    if (@abs(delta_y) < 0.0001) return;
    for (packet.items[start..packet.len]) |*item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        item.rect[1] += delta_y;
        if (kind == .line) item.rect[3] += delta_y;
    }
}

fn transformScoreItems(packet: *render.Packet, start: usize, stage: Rect, scale: f32) void {
    if (@abs(scale - 1) < 0.0001) return;
    const center_x = stage.x + stage.width * 0.5;
    const center_y = stage.y + stage.height * 0.5;
    for (packet.items[start..packet.len]) |*item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line) {
            item.rect[0] = center_x + (item.rect[0] - center_x) * scale;
            item.rect[1] = center_y + (item.rect[1] - center_y) * scale;
            item.rect[2] = center_x + (item.rect[2] - center_x) * scale;
            item.rect[3] = center_y + (item.rect[3] - center_y) * scale;
            item.params[1] *= scale;
        } else {
            item.rect[0] = center_x + (item.rect[0] - center_x) * scale;
            item.rect[1] = center_y + (item.rect[1] - center_y) * scale;
            item.rect[2] *= scale;
            item.rect[3] *= scale;
            if (kind == .rounded_rect) item.params[1] *= scale;
        }
    }
}

fn drawScorePage(packet: *render.Packet, stage: Rect, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, notes: []const model.Note, lyrics: []const model.Lyric, harmonies: []const model.Harmony, hairpins: []const model.Hairpin, pedals: []const model.PedalEvent, measures: []const model.Measure, time_seconds: f32, page: ScorePage, page_count: u32, layout_system_count: usize) void {
    const vocal_visible = state.vocal_guide_visible != 0 and hasVocalGuide(notes);
    var geometry = ScoreGeometry.calculateForSystems(stage, vocal_visible, @max(@as(usize, 1), layout_system_count));
    const compact_header = geometry.page_height < 340;
    const continuous = state.score_view_mode == .continuous;
    geometry.beat_width = geometry.music_width / page.systems[0].duration();
    if (!continuous) {
        packet.glow(geometry.page_x - 10, geometry.page_y + 8, geometry.page_width + 20, geometry.page_height + 10, 18, .{ 0, 0, 0, 0.34 }, 0);
        packet.rounded(geometry.page_x, geometry.page_y, geometry.page_width, geometry.page_height, 5, palette.paper);
    }
    const show_header = !continuous or page.page_index == 0;
    if (show_header) packet.text(geometry.page_x + geometry.page_padding - 6, geometry.page_y + if (compact_header) @as(f32, 30) else 36, meta.titleSlice(), if (compact_header or geometry.page_width < 500) 1.55 else 2.45, palette.ink);
    const source_label: []const u8 = switch (meta.source_kind) {
        1 => "IMPORTED MUSICXML - REVIEW WARNINGS",
        2 => "IMPORTED MIDI - QUANTIZATION REVIEW",
        else => "BUILT-IN PRACTICE SCORE",
    };
    if (show_header and !compact_header) packet.text(geometry.page_x + geometry.page_padding - 5, geometry.page_y + 60, if (geometry.page_width < 500) "SCORE PRACTICE" else source_label, if (geometry.page_width < 500) 0.9 else 1.2, .{ 0.30, 0.31, 0.31, 1 });
    // A single instrumental part used to hide its source name completely: the
    // top-bar part selector only exists for multi-part scores. Keep the active
    // MusicXML part visible on the paper as well, so a playable reduction such
    // as "Piano reduction (harp + ensemble)" cannot masquerade as an unrelated
    // sparse piano part. This is semantic score metadata, not a Holocene-only
    // UI string, and it is retained by screen and PDF rendering alike.
    if (show_header and !compact_header and geometry.page_width >= 500 and state.selected_part_label_len != 0) {
        const part_label = state.selectedPartLabel();
        const available_width = @max(@as(f32, 120), geometry.page_width - geometry.page_padding * 2 - 220);
        const part_scale = std.math.clamp(available_width / @max(1, render.Packet.textWidth(part_label, 1)), 0.82, 1.08);
        packet.text(geometry.page_x + geometry.page_padding - 5, geometry.page_y + 76, part_label, part_scale, .{ 0.28, 0.29, 0.29, 1 });
    }
    if (show_header and !compact_header and state.tool == .edit and geometry.page_width >= 700) {
        packet.text(geometry.page_x + geometry.page_padding - 5, geometry.page_y + 89, "PEDALS: CLICK A LANE TO ADD / DRAG A POINT / DELETE TO REMOVE / CC64, 66, 67", 0.62, .{ 0.45, 0.36, 0.24, 1 });
    }
    var page_buffer: [40]u8 = undefined;
    const page_number = page.page_index + 1;
    const visible_system_count = @min(page.system_count, @max(@as(usize, 1), layout_system_count));
    const page_label = if (continuous)
        std.fmt.bufPrint(&page_buffer, "SYSTEMS {d}-{d} / {d}", .{ page_number, page_number + @as(u32, @intCast(visible_system_count)) - 1, page_count }) catch "SYSTEMS"
    else
        std.fmt.bufPrint(&page_buffer, "PAGE {d} / {d}", .{ page_number, page_count }) catch "PAGE";
    packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - (if (continuous) @as(f32, 128) else 88), geometry.page_y + 38, page_label, if (continuous) 0.72 else 0.95, .{ 0.35, 0.36, 0.36, 1 });
    if (geometry.page_width >= 620) packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - 124, geometry.page_y + 57, if (continuous) "SCROLL VERTICALLY" else "SCROLL  /  LEFT-RIGHT", 0.62, .{ 0.46, 0.47, 0.48, 1 });

    for (0..page.system_count) |system| {
        const score_system = page.systems[system];
        if (vocal_visible) {
            for (0..5) |line| packet.rect(geometry.staff_x, geometry.vocal_y[system] + @as(f32, @floatFromInt(line)) * 12, geometry.staff_width, 0.85, palette.ink);
            packet.text(geometry.staff_x - 40, geometry.vocal_y[system] + 20, "VOICE", 0.58, .{ 0.40, 0.27, 0.31, 1 });
        }
        const staves = [_]f32{ geometry.treble_y[system], geometry.bass_y[system] };
        for (staves) |staff_y| for (0..5) |line| packet.rect(geometry.staff_x, staff_y + @as(f32, @floatFromInt(line)) * 12, geometry.staff_width, 0.85, palette.ink);
        drawGrandStaffBrace(packet, geometry.staff_x, geometry.treble_y[system], geometry.bass_y[system], palette.ink);
        const music_em: f32 = 48;
        if (vocal_visible) packet.musicGlyph(0xe050, geometry.staff_x + 5, geometry.vocal_y[system] + 36, music_em, palette.ink);
        packet.musicGlyph(0xe050, geometry.staff_x + 5, geometry.treble_y[system] + 36, music_em, palette.ink);
        packet.musicGlyph(0xe062, geometry.staff_x + 5, geometry.bass_y[system] + 12, music_em, palette.ink);
        const key_x = geometry.staff_x + 32;
        if (vocal_visible) _ = drawKeySignature(packet, key_x, geometry.vocal_y[system], false, meta.key_fifths, music_em, palette.ink);
        const treble_key_end = drawKeySignature(packet, key_x, geometry.treble_y[system], false, meta.key_fifths, music_em, palette.ink);
        _ = drawKeySignature(packet, key_x, geometry.bass_y[system], true, meta.key_fifths, music_em, palette.ink);
        const time_x = if (meta.key_fifths == 0) geometry.staff_x + 45 else treble_key_end + 8;
        const opening_measure = if (score_system.first_measure < measures.len) measures[score_system.first_measure] else model.Measure{ .beats = meta.beats_per_measure, .beat_unit = meta.beat_unit };
        if (vocal_visible) drawSingleTimeSignature(packet, time_x, geometry.vocal_y[system], opening_measure.beats, opening_measure.beat_unit, music_em, palette.ink);
        drawTimeSignature(packet, time_x, geometry.treble_y[system], geometry.bass_y[system], opening_measure.beats, opening_measure.beat_unit, music_em, palette.ink);
        if (vocal_visible) packet.rect(geometry.staff_x, geometry.vocal_y[system], 1.5, 49, palette.ink);
        packet.rect(geometry.staff_x, geometry.treble_y[system], 1.5, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
        var measure_index = score_system.first_measure;
        while (measure_index < score_system.measure_end) : (measure_index += 1) {
            const measure = measures[measure_index];
            const measure_start_x = measureBoundaryX(geometry, score_system, measure.start_beat);
            if (measure.hasForwardRepeat()) {
                if (vocal_visible) drawRepeatBarline(packet, measure_start_x, geometry.vocal_y[system], geometry.vocal_y[system], true);
                drawRepeatBarline(packet, measure_start_x, geometry.treble_y[system], geometry.bass_y[system], true);
            }
            const measure_end = measure.start_beat + @max(0.0001, measure.duration_beats);
            const bx = measureBoundaryX(geometry, score_system, measure_end);
            if (vocal_visible) packet.rect(bx, geometry.vocal_y[system], if (measure_index + 1 == score_system.measure_end) 1.5 else 0.9, 49, palette.ink);
            packet.rect(bx, geometry.treble_y[system], if (measure_index + 1 == score_system.measure_end) 1.5 else 0.9, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
            if (measure.hasBackwardRepeat()) {
                if (vocal_visible) drawRepeatBarline(packet, bx, geometry.vocal_y[system], geometry.vocal_y[system], false);
                drawRepeatBarline(packet, bx, geometry.treble_y[system], geometry.bass_y[system], false);
            }
            if (measure_index == score_system.first_measure) continue;
            const previous = measures[measure_index - 1];
            if (measure.beats != previous.beats or measure.beat_unit != previous.beat_unit) {
                const change_x = measureBoundaryX(geometry, score_system, measure.start_beat) + 8;
                if (vocal_visible) drawSingleTimeSignature(packet, change_x, geometry.vocal_y[system], measure.beats, measure.beat_unit, music_em, palette.ink);
                drawTimeSignature(packet, change_x, geometry.treble_y[system], geometry.bass_y[system], measure.beats, measure.beat_unit, music_em, palette.ink);
            }
        }
        drawVoltaEndingsForSystem(packet, geometry, score_system, system, measures, vocal_visible);
    }

    for (harmonies) |harmony| {
        const position = scoreBeatPosition(geometry, page, measures, harmony.start_beat) orelse continue;
        var x = position.x;
        // With an independent vocal staff, the page header owns the space
        // above it. Chord symbols live in the clear lane below that staff and
        // above its lyrics, instead of colliding with title/import text.
        const y = if (vocal_visible) geometry.vocal_y[position.system] + 58 else geometry.treble_y[position.system] - 25;
        x = drawHarmonyPitch(packet, x, y, harmony.root_step, harmony.root_alter, palette.ink);
        if (harmony.text_len != 0) {
            packet.text(x, y, harmony.textSlice(), 0.95, palette.ink);
            x += render.Packet.textWidth(harmony.textSlice(), 0.95);
        }
        if (harmony.bass_step != 0) {
            packet.text(x + 1, y, "/", 0.95, palette.ink);
            x += render.Packet.textWidth("/", 0.95) + 1;
            _ = drawHarmonyPitch(packet, x, y, harmony.bass_step, harmony.bass_alter, palette.ink);
        }
    }

    drawHairpins(packet, hairpins, geometry, page, measures, state);
    if (state.pedal_guide_visible != 0) drawPedalNotation(packet, pedals, notes, geometry, page, measures, transport, state);

    for (notes, 0..) |note, note_index| {
        const vocal_guide = (note.flags & model.note_flag_vocal_guide) != 0;
        if (vocal_guide and state.vocal_guide_visible == 0) continue;
        const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        const staff_y = staffYForPosition(geometry, position);
        const active = transport.playing != 0 and transport.cursor_beat >= note.start_beat and transport.cursor_beat < note.start_beat + note.duration_beats;
        const color: Color = if (vocal_guide) (if (active) palette.rose else .{ 0.53, 0.33, 0.40, 1 }) else if (note.selected != 0) palette.rose else if (active) palette.cyan else palette.ink;
        const stem_up = chordStemUp(notes, note, staff_y);
        const resolved = noteRenderPosition(notes, note, position);
        const note_x = resolved.x;
        const note_y = resolved.y;
        if (active or note.selected != 0) packet.glow(note_x - 14, note_y - 12, 29, 25, 13, if (active) .{ 0.18, 0.78, 0.76, 0.32 } else .{ 0.80, 0.20, 0.34, 0.24 }, time_seconds);
        if ((note.flags & model.note_flag_rest) != 0) {
            packet.musicGlyph(restGlyph(note.duration_beats), note_x - 7, note_y, 48, color);
            if (note.dots != 0) {
                for (0..@min(note.dots, 3)) |dot| packet.musicGlyph(0xe1e7, note_x + 10 + @as(f32, @floatFromInt(dot)) * 6, note_y - 6, 48, color);
            }
            continue;
        }
        if (note_y < staff_y - 3 or note_y > staff_y + 51) packet.rect(@min(position.x, note_x) - 12, note_y - 0.7, 24 + @abs(note_x - position.x), 1.4, palette.ink);
        const grace = (note.flags & model.note_flag_grace) != 0;
        const music_em: f32 = if (grace) 34 else 48;
        const glyph_scale: f32 = music_em / 48;
        if (shouldDrawAccidentalInMeasures(notes, note_index, meta, measures)) {
            packet.musicGlyph(accidentalGlyph(noteSpelling(note).alter), accidentalRenderX(notes, note_index, note_x, position, meta, measures), note_y, music_em, color);
        }
        const notehead: u21 = if (note.duration_beats >= 4) 0xe0a2 else if (note.duration_beats >= 2) 0xe0a3 else 0xe0a4;
        const origin_offset: f32 = (if (note.duration_beats >= 4) @as(f32, 10.1) else 7.1) * glyph_scale;
        packet.musicGlyph(notehead, note_x - origin_offset, note_y, music_em, color);
        const stem_offset = 6.2 * glyph_scale;
        const stem_x = if (stem_up) note_x + stem_offset else note_x - stem_offset;
        const tremolo_marks = chordSingleTremoloMarks(notes, note);
        const stem_anchor = isChordStemAnchor(notes, note, stem_up);
        if (note.duration_beats < 4 and !chordHasBeam(notes, note) and stem_anchor) {
            const tremolo_clearance = 14 + @as(f32, @floatFromInt(tremolo_marks)) * 4.4;
            const stem_length: f32 = @max(if (grace) @as(f32, 23) else 32, tremolo_clearance * glyph_scale);
            const stem_end = if (stem_up) note_y - stem_length else note_y + stem_length;
            packet.rect(stem_x, @min(note_y, stem_end), if (grace) 1.0 else 1.25, @abs(stem_end - note_y), color);
            if (note.duration_beats <= 0.5) packet.musicGlyph(if (stem_up) 0xe240 else 0xe241, stem_x, stem_end, music_em, color);
        }
        // The acciaccatura slash belongs to the grace stem whether that stem
        // carries a standalone flag or joins a connected cue-size beam.
        if (grace and (note.notations & model.note_notation_grace_slash) != 0) {
            const slash_y = if (stem_up) note_y - 12 else note_y + 12;
            packet.line(stem_x - 7, slash_y + 4, stem_x + 8, slash_y - 4, 1.35, color);
        }
        if (tremolo_marks != 0 and stem_anchor) drawSingleNoteTremolo(packet, tremolo_marks, stem_x, note_y, stem_up, glyph_scale, color);
        if (note.dots != 0) {
            const on_line = @abs(@round((note_y - staff_y) / 12) * 12 - (note_y - staff_y)) < 1.5;
            const dot_y = note_y - (if (on_line) @as(f32, 6) else 0);
            for (0..@min(note.dots, 3)) |dot| packet.musicGlyph(0xe1e7, note_x + 9 * glyph_scale + @as(f32, @floatFromInt(dot)) * 6 * glyph_scale, dot_y, music_em, color);
        }
        drawArticulations(packet, note, note_x, note_y, stem_up, color);
        drawOrnamentsAndArpeggiation(packet, notes, note_index, note, position, note_x, staff_y, meta, measures, color);
        if (model.dynamic(note.flags) != 0) {
            if (dynamicPlacement(notes, note_index, note_x - 3, geometry, page, measures)) |placement| {
                drawDynamic(packet, model.dynamic(note.flags), placement.x, placement.y, color);
            }
        }
    }

    drawBeams(packet, notes, geometry, page, measures, state, transport);
    drawTies(packet, notes, geometry, page, measures, state, transport);
    drawSlurs(packet, notes, geometry, page, measures, state, transport);
    drawTuplets(packet, notes, geometry, page, measures, state, transport);

    if (vocal_visible) {
        for (lyrics) |lyric| {
            const position = scoreBeatPosition(geometry, page, measures, lyric.start_beat) orelse continue;
            const x = position.x;
            const y = geometry.lyric_y[position.system];
            const active = transport.playing != 0 and @abs(transport.cursor_beat - lyric.start_beat) < 0.34;
            packet.text(x - 3, y, lyric.textSlice(), if (geometry.page_width < 500) 0.65 else 0.82, if (active) palette.cyan_dim else .{ 0.20, 0.21, 0.22, 1 });
        }
    }

    if (scoreBeatPosition(geometry, page, measures, transport.cursor_beat)) |cursor| {
        const cursor_x = cursor.x;
        const cursor_top = (if (vocal_visible) geometry.vocal_y[cursor.system] else geometry.treble_y[cursor.system]) - 11;
        const cursor_height = geometry.bass_y[cursor.system] - cursor_top + 60;
        packet.glow(cursor_x - 5, cursor_top, 11, cursor_height, 6, .{ 0.35, 0.91, 0.88, 0.22 }, time_seconds);
        packet.rect(cursor_x, cursor_top, 2, cursor_height, palette.cyan);
    }
}

fn drawRepeatBarline(packet: *render.Packet, x: f32, upper_staff_y: f32, lower_staff_y: f32, forward: bool) void {
    const top = upper_staff_y;
    const height = lower_staff_y - upper_staff_y + 49;
    const thick_x = if (forward) x + 3 else x - 6;
    packet.rect(thick_x, top, 3.2, height, palette.ink);
    // Repeat dots sit in the two middle spaces of each participating staff.
    var staff_y = upper_staff_y;
    while (staff_y <= lower_staff_y + 0.001) : (staff_y += @max(@as(f32, 1), lower_staff_y - upper_staff_y)) {
        const dot_x = if (forward) x + 9 else x - 11;
        packet.ellipse(dot_x - 2.2, staff_y + 18 - 2.2, 4.4, 4.4, palette.ink);
        packet.ellipse(dot_x - 2.2, staff_y + 30 - 2.2, 4.4, 4.4, palette.ink);
        if (upper_staff_y == lower_staff_y) break;
    }
}

fn drawVoltaEndingsForSystem(packet: *render.Packet, geometry: ScoreGeometry, system: ScoreSystem, system_index: usize, measures: []const model.Measure, vocal_visible: bool) void {
    var index = system.first_measure;
    while (index < system.measure_end and index < measures.len) {
        const first = measures[index];
        if (first.ending_mask == 0) {
            index += 1;
            continue;
        }
        const mask = first.ending_mask;
        var end_index = index + 1;
        while (end_index < system.measure_end and end_index < measures.len and measures[end_index].ending_mask == mask) : (end_index += 1) {}
        const last = measures[end_index - 1];
        const x0 = measureBoundaryX(geometry, system, first.start_beat);
        const x1 = measureBoundaryX(geometry, system, last.start_beat + @max(0.0001, last.duration_beats));
        const staff_y = if (vocal_visible) geometry.vocal_y[system_index] else geometry.treble_y[system_index];
        const y = staff_y - 22;
        packet.rect(x0, y, @max(1, x1 - x0), 1.25, palette.ink);
        if (first.endingStarts()) packet.rect(x0, y, 1.25, 13, palette.ink);
        if ((last.ending_flags & model.measure_ending_stop) != 0) packet.rect(x1 - 1.25, y, 1.25, 13, palette.ink);
        if (first.endingStarts()) {
            var label: [64]u8 = undefined;
            var length: usize = 0;
            for (0..16) |pass_index| {
                if ((mask & (@as(u16, 1) << @intCast(pass_index))) == 0) continue;
                const written = if (length == 0)
                    std.fmt.bufPrint(label[length..], "{d}.", .{pass_index + 1}) catch break
                else
                    std.fmt.bufPrint(label[length..], ", {d}.", .{pass_index + 1}) catch break;
                length += written.len;
            }
            if (length != 0) packet.text(x0 + 6, y - 18, label[0..length], 0.82, palette.ink);
        }
        index = end_index;
    }
}

fn drawPageNavigation(packet: *render.Packet, layout: Layout, state: *const model.UiState, first_page_number: u32, last_page_number: u32, page_count: u32) void {
    const previous_enabled = first_page_number > 1;
    const next_enabled = last_page_number < page_count;
    const previous_hovered = previous_enabled and layout.page_previous.contains(state.pointer_x, state.pointer_y);
    const next_hovered = next_enabled and layout.page_next.contains(state.pointer_x, state.pointer_y);
    const disabled: Color = .{ 0.22, 0.24, 0.27, 0.42 };

    packet.rounded(layout.page_previous.x, layout.page_previous.y, layout.page_previous.width, layout.page_previous.height, 14, if (!previous_enabled) disabled else if (previous_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.page_previous.x + 11, layout.page_previous.y + layout.page_previous.height * 0.5 - 8, "<", 1.45, if (previous_enabled) (if (previous_hovered) palette.cyan else palette.text) else palette.muted);
    packet.rounded(layout.page_next.x, layout.page_next.y, layout.page_next.width, layout.page_next.height, 14, if (!next_enabled) disabled else if (next_hovered) palette.cyan_dim else palette.panel_raised);
    packet.text(layout.page_next.x + 12, layout.page_next.y + layout.page_next.height * 0.5 - 8, ">", 1.45, if (next_enabled) (if (next_hovered) palette.cyan else palette.text) else palette.muted);
}

fn noteInkColor(note: model.Note, state: *const model.UiState, transport: *const model.Transport) Color {
    const active = transport.playing != 0 and transport.cursor_beat >= note.start_beat and transport.cursor_beat < note.start_beat + note.duration_beats;
    if ((note.flags & model.note_flag_vocal_guide) != 0) return if (active) palette.rose else .{ 0.53, 0.33, 0.40, 1 };
    _ = state;
    return if (note.selected != 0) palette.rose else if (active) palette.cyan else palette.ink;
}

fn restGlyph(duration_beats: f32) u21 {
    if (duration_beats >= 4) return 0xe4e3;
    if (duration_beats >= 2) return 0xe4e4;
    if (duration_beats >= 1) return 0xe4e5;
    if (duration_beats >= 0.5) return 0xe4e6;
    if (duration_beats >= 0.25) return 0xe4e7;
    return 0xe4e8;
}

fn drawArticulations(packet: *render.Packet, note: model.Note, x: f32, y: f32, stem_up: bool, color: Color) void {
    const mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato | model.note_flag_fermata;
    if ((note.flags & mask) == 0) return;
    const below = stem_up;
    const sign: f32 = if (below) 1 else -1;
    var offset: f32 = 16;
    const glyphs = [_]struct { flag: u32, above: u21, below: u21 }{
        .{ .flag = model.note_flag_staccato, .above = 0xe4a2, .below = 0xe4a3 },
        .{ .flag = model.note_flag_tenuto, .above = 0xe4a4, .below = 0xe4a5 },
        .{ .flag = model.note_flag_accent, .above = 0xe4a0, .below = 0xe4a1 },
        .{ .flag = model.note_flag_marcato, .above = 0xe4ac, .below = 0xe4ad },
        .{ .flag = model.note_flag_fermata, .above = 0xe4c0, .below = 0xe4c1 },
    };
    for (glyphs) |entry| {
        if ((note.flags & entry.flag) == 0) continue;
        packet.musicGlyph(if (below) entry.below else entry.above, x, y + sign * offset, 34, color);
        offset += if (entry.flag == model.note_flag_fermata) 15 else 9;
    }
}

const VerticalInkBounds = struct { top: f32, bottom: f32 };

fn chordVerticalInkBounds(notes: []const model.Note, note: model.Note, staff_y: f32) VerticalInkBounds {
    var bounds = VerticalInkBounds{ .top = staff_y + 24, .bottom = staff_y + 24 };
    var found = false;
    for (noteOnsetSlice(notes, note.start_beat)) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or candidate.staff != note.staff or candidate.voice != note.voice or !sameNotationLayer(candidate, note) or @abs(candidate.start_beat - note.start_beat) >= 0.0001) continue;
        const bass = (candidate.staff & 1) != 0 or (candidate.staff == 0 and candidate.pitch < 58);
        const base_diatonic: i32 = if (bass) 18 else 30;
        const y = staff_y + 48 - @as(f32, @floatFromInt(noteDiatonic(candidate) - base_diatonic)) * 6;
        var top = y - 11;
        var bottom = y + 11;
        const stem_up = chordStemUp(notes, candidate, staff_y);
        if (candidate.duration_beats < 4) {
            const stem_length: f32 = if ((candidate.flags & model.note_flag_grace) != 0) 23 else if ((candidate.flags & model.note_flag_beam_mask) != 0) 38 else 32;
            if (stem_up) top = @min(top, y - stem_length) else bottom = @max(bottom, y + stem_length);
        }
        const articulation_mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato | model.note_flag_fermata;
        if ((candidate.flags & articulation_mask) != 0) {
            if (stem_up) bottom += 28 else top -= 28;
        }
        if (!found) {
            bounds = .{ .top = top, .bottom = bottom };
            found = true;
        } else {
            bounds.top = @min(bounds.top, top);
            bounds.bottom = @max(bounds.bottom, bottom);
        }
    }
    return bounds;
}

fn isFirstMatchingNotation(notes: []const model.Note, note_index: usize, note: model.Note, mask: u32) bool {
    const value = note.notations & mask;
    if (value == 0) return false;
    const onset = noteOnsetRange(notes, note.start_beat);
    for (notes[onset.start..@min(note_index, onset.end)]) |earlier| {
        if (earlier.staff != note.staff or earlier.voice != note.voice or !sameNotationLayer(earlier, note) or @abs(earlier.start_beat - note.start_beat) >= 0.0001) continue;
        if ((earlier.notations & mask) == value) return false;
    }
    return true;
}

fn chordAccidentalColumns(notes: []const model.Note, note: model.Note, meta: *const model.DocumentMeta, measures: []const model.Measure) u8 {
    var columns: u8 = 0;
    const onset = noteOnsetRange(notes, note.start_beat);
    for (notes[onset.start..onset.end], onset.start..) |candidate, candidate_index| {
        if ((candidate.flags & model.note_flag_rest) != 0 or candidate.staff != note.staff or candidate.voice != note.voice or !sameNotationLayer(candidate, note) or @abs(candidate.start_beat - note.start_beat) >= 0.0001) continue;
        if (!shouldDrawAccidentalInMeasures(notes, candidate_index, meta, measures)) continue;
        columns = @max(columns, accidentalColumn(notes, candidate_index, meta, measures) + 1);
    }
    return columns;
}

fn drawOrnamentsAndArpeggiation(packet: *render.Packet, notes: []const model.Note, note_index: usize, note: model.Note, position: NotePosition, note_x: f32, staff_y: f32, meta: *const model.DocumentMeta, measures: []const model.Measure, color: Color) void {
    const bounds = chordVerticalInkBounds(notes, note, staff_y);
    const ornaments = note.notations & model.note_notation_ornament_mask;
    if (ornaments != 0 and isFirstMatchingNotation(notes, note_index, note, model.note_notation_ornament_mask | model.note_notation_ornament_below)) {
        const below = (note.notations & model.note_notation_ornament_below) != 0;
        const baseline_y = if (below) bounds.bottom + 18 else bounds.top - 12;
        const glyphs = [_]struct { bit: u32, glyph: u21 }{
            .{ .bit = model.note_notation_trill, .glyph = 0xe566 },
            .{ .bit = model.note_notation_turn, .glyph = 0xe567 },
            .{ .bit = model.note_notation_inverted_turn, .glyph = 0xe568 },
            .{ .bit = model.note_notation_mordent, .glyph = 0xe56d },
            .{ .bit = model.note_notation_inverted_mordent, .glyph = 0xe56c },
        };
        var count: usize = 0;
        for (glyphs) |entry| if ((ornaments & entry.bit) != 0) {
            count += 1;
        };
        var x = note_x - @as(f32, @floatFromInt(count -| 1)) * 11;
        for (glyphs) |entry| {
            if ((ornaments & entry.bit) == 0) continue;
            packet.musicGlyph(entry.glyph, x, baseline_y, 34, color);
            x += 22;
        }
    }

    if ((note.notations & model.note_notation_arpeggiate_mask) != 0 and isFirstMatchingNotation(notes, note_index, note, model.note_notation_arpeggiate_mask)) {
        const glyph: u21 = if ((note.notations & model.note_notation_arpeggiate_up) != 0)
            0xe634
        else if ((note.notations & model.note_notation_arpeggiate_down) != 0)
            0xe635
        else
            0xe63c;
        const glyph_height: f32 = if (glyph == 0xe63c) 1.484 else 1.65;
        const glyph_top: f32 = if (glyph == 0xe63c) -1.43 else -1.58;
        const em_size = std.math.clamp((bounds.bottom - bounds.top + 16) / glyph_height, 24, 52);
        const baseline_y = bounds.top - 8 - glyph_top * em_size;
        const accidental_columns = chordAccidentalColumns(notes, note, meta, measures);
        const x = @min(position.x, note_x) - 36 - @as(f32, @floatFromInt(accidental_columns)) * 14;
        packet.musicGlyph(glyph, x, baseline_y, em_size, color);
    }
}

const DynamicPlacement = struct { x: f32, y: f32 };

fn dynamicGlyphs(dynamic_code: u8) ?[]const u21 {
    return switch (dynamic_code) {
        model.dynamic_ppp => &.{ 0xe520, 0xe520, 0xe520 },
        model.dynamic_pp => &.{ 0xe520, 0xe520 },
        model.dynamic_p => &.{0xe520},
        model.dynamic_mp => &.{ 0xe521, 0xe520 },
        model.dynamic_mf => &.{ 0xe521, 0xe522 },
        model.dynamic_f => &.{0xe522},
        model.dynamic_ff => &.{ 0xe522, 0xe522 },
        model.dynamic_fff => &.{ 0xe522, 0xe522, 0xe522 },
        model.dynamic_sfz => &.{ 0xe524, 0xe522, 0xe525 },
        else => null,
    };
}

fn dynamicGlyphAdvance(glyph: u21) f32 {
    return switch (glyph) {
        0xe521 => 15,
        0xe522 => 9,
        else => 11,
    };
}

fn dynamicWidth(dynamic_code: u8) f32 {
    const glyphs = dynamicGlyphs(dynamic_code) orelse return 0;
    var width: f32 = 0;
    for (glyphs) |glyph| width += dynamicGlyphAdvance(glyph);
    return width;
}

fn dynamicInkBounds(dynamic_code: u8, x: f32, baseline_y: f32) Rect {
    // Bravura's tallest supported dynamic (`f`) spans approximately
    // -18.3...+8.2 px at the 36 px em used below. Add optical side bearings so
    // collision checks also protect adjacent accidentals and stems.
    return .{ .x = x - 8, .y = baseline_y - 20, .width = dynamicWidth(dynamic_code) + 16, .height = 30 };
}

fn noteCollisionBounds(notes: []const model.Note, note: model.Note, position: NotePosition, geometry: ScoreGeometry) Rect {
    const staff_y = staffYForPosition(geometry, position);
    const resolved = noteRenderPosition(notes, note, position);
    if ((note.flags & model.note_flag_rest) != 0) return .{ .x = resolved.x - 15, .y = resolved.y - 18, .width = 30, .height = 36 };
    const stem_up = chordStemUp(notes, note, staff_y);
    const note_x = resolved.x;
    const grace = (note.flags & model.note_flag_grace) != 0;
    const half_head: f32 = if (grace) 8 else 11;
    const tremolo_clearance = 14 + @as(f32, @floatFromInt(chordSingleTremoloMarks(notes, note))) * 4.4;
    const ordinary_stem_length: f32 = if (grace) 23 else if ((note.flags & model.note_flag_beam_mask) != 0) 38 else 32;
    const tremolo_scale: f32 = if (grace) 34.0 / 48.0 else 1;
    const stem_length: f32 = @max(ordinary_stem_length, tremolo_clearance * tremolo_scale);
    var minimum_y = resolved.y - half_head;
    var maximum_y = resolved.y + half_head;
    if (note.duration_beats < 4) {
        if (stem_up) {
            minimum_y = @min(minimum_y, resolved.y - stem_length);
        } else {
            maximum_y = @max(maximum_y, resolved.y + stem_length);
        }
    }
    const articulation_mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato | model.note_flag_fermata;
    if ((note.flags & articulation_mask) != 0) {
        if (stem_up) maximum_y += 25 else minimum_y -= 25;
    }
    if ((note.notations & model.note_notation_ornament_mask) != 0) {
        if ((note.notations & model.note_notation_ornament_below) != 0) maximum_y += 34 else minimum_y -= 34;
    }
    return .{ .x = @min(position.x, note_x) - 27, .y = minimum_y, .width = 54 + @abs(note_x - position.x), .height = maximum_y - minimum_y };
}

fn dynamicPlacement(notes: []const model.Note, note_index: usize, initial_x: f32, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure) ?DynamicPlacement {
    const note = notes[note_index];
    const dynamic_code = model.dynamic(note.flags);
    if (dynamic_code == 0) return null;
    const position = scoreNotePosition(note, geometry, page, measures) orelse return null;

    // Coalesce identical dynamics authored on multiple chord/voice notes at
    // one onset. Different simultaneous markings stay visible and move into
    // adjacent horizontal slots rather than drawing on top of each other.
    var rank: usize = 0;
    for (notes, 0..) |candidate, candidate_index| {
        if (candidate_index == note_index or model.dynamic(candidate.flags) == 0 or @abs(candidate.start_beat - note.start_beat) > 0.0001) continue;
        const candidate_position = scoreNotePosition(candidate, geometry, page, measures) orelse continue;
        if (candidate_position.system != position.system or candidate_position.vocal != position.vocal or candidate_position.bass != position.bass) continue;
        if (model.dynamic(candidate.flags) == dynamic_code) {
            if (candidate.stable_id < note.stable_id) return null;
        } else if (candidate.stable_id < note.stable_id) {
            rank += 1;
        }
    }
    const x = initial_x + @as(f32, @floatFromInt(rank)) * (dynamicWidth(dynamic_code) + 8);
    const treble_y = geometry.treble_y[position.system];
    const bass_y = geometry.bass_y[position.system];
    const staff_y = staffYForPosition(geometry, position);
    const candidates: [4]f32 = if (position.vocal)
        .{ staff_y - 16, staff_y - 34, staff_y + 88, staff_y + 102 }
    else if (position.bass)
        .{ bass_y + 72, treble_y + 70, treble_y - 16, bass_y + 94 }
    else
        .{ treble_y + 70, treble_y - 16, bass_y + 72, bass_y + 94 };
    const next_top = if (position.system + 1 < page.system_count)
        (if (geometry.vocal_y[position.system + 1] < geometry.treble_y[position.system + 1]) geometry.vocal_y[position.system + 1] else geometry.treble_y[position.system + 1]) - 8
    else
        geometry.page_y + geometry.page_height - 8;
    for (candidates) |baseline_y| {
        const bounds = dynamicInkBounds(dynamic_code, x, baseline_y);
        if (bounds.y < geometry.page_y + 70 or bounds.y + bounds.height > next_top) continue;
        var collision = false;
        for (notes) |candidate| {
            const candidate_position = scoreNotePosition(candidate, geometry, page, measures) orelse continue;
            if (candidate_position.system != position.system or candidate_position.vocal != position.vocal) continue;
            if (bounds.intersects(noteCollisionBounds(notes, candidate, candidate_position, geometry))) {
                collision = true;
                break;
            }
        }
        if (!collision) return .{ .x = x, .y = baseline_y };
    }
    // Preserve the authored expression even in an exceptionally dense system;
    // the first lane is the deterministic least-surprising fallback.
    return .{ .x = x, .y = candidates[0] };
}

fn drawDynamic(packet: *render.Packet, dynamic_code: u8, x: f32, y: f32, color: Color) void {
    const glyphs = dynamicGlyphs(dynamic_code) orelse return;
    var cursor = x;
    for (glyphs) |glyph| {
        packet.musicGlyph(glyph, cursor, y, 36, color);
        cursor += dynamicGlyphAdvance(glyph);
    }
}

fn beamLevelCount(duration_beats: f32) usize {
    if (duration_beats <= 0.0626) return 4;
    if (duration_beats <= 0.1251) return 3;
    if (duration_beats <= 0.2501) return 2;
    return 1;
}

fn beamThickness(level: usize) f32 {
    return switch (level) {
        0 => 4.2,
        1 => 3.5,
        2 => 3.2,
        else => 3.0,
    };
}

fn beamFlagGlyph(levels: usize, stem_up: bool) u21 {
    const upward = [_]u21{ 0xe240, 0xe242, 0xe244, 0xe246 };
    const downward = [_]u21{ 0xe241, 0xe243, 0xe245, 0xe247 };
    const index = @min(@max(levels, 1), upward.len) - 1;
    return if (stem_up) upward[index] else downward[index];
}

const BeamAnchor = struct {
    start_beat: f32,
    stable_id: u64,
    x: f32,
    min_y: f32,
    max_y: f32,
    duration: f32,
    staff: u8,
    voice: u8,
    system: usize,
    bass: bool,
    vocal: bool,
    flags: u32,
    grace: bool,
    color: Color,
    forced_voice_stem: bool,
};

fn drawBeams(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    var anchors: [512]BeamAnchor = undefined;
    var anchor_count: usize = 0;
    for (notes) |note| {
        if ((note.flags & model.note_flag_rest) != 0) continue;
        if ((note.flags & model.note_flag_beam_mask) == 0) continue;
        if ((note.flags & model.note_flag_vocal_guide) != 0 and state.vocal_guide_visible == 0) continue;
        const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        const resolved = noteRenderPosition(notes, note, position);
        const staff_y = staffYForPosition(geometry, position);
        const stem_up = chordStemUp(notes, note, staff_y);
        const grace = (note.flags & model.note_flag_grace) != 0;
        var existing: ?usize = null;
        for (anchors[0..anchor_count], 0..) |anchor, index| {
            const same_attack = if (grace) anchor.grace and anchor.stable_id == note.stable_id else !anchor.grace and anchor.start_beat == note.start_beat;
            if (same_attack and anchor.staff == note.staff and anchor.voice == note.voice and anchor.vocal == position.vocal) {
                existing = index;
                break;
            }
        }
        if (existing) |index| {
            anchors[index].min_y = @min(anchors[index].min_y, resolved.y);
            anchors[index].max_y = @max(anchors[index].max_y, resolved.y);
            if (isChordStemAnchor(notes, note, stem_up)) anchors[index].x = resolved.x;
            anchors[index].duration = @min(anchors[index].duration, note.duration_beats);
            anchors[index].flags |= note.flags;
            anchors[index].forced_voice_stem = anchors[index].forced_voice_stem or hasConcurrentPitchedVoice(notes, note);
        } else if (anchor_count < anchors.len) {
            anchors[anchor_count] = .{
                .start_beat = note.start_beat,
                .stable_id = note.stable_id,
                .x = resolved.x,
                .min_y = resolved.y,
                .max_y = resolved.y,
                .duration = note.duration_beats,
                .staff = note.staff,
                .voice = note.voice,
                .system = position.system,
                .bass = position.bass,
                .vocal = position.vocal,
                .flags = note.flags,
                .grace = grace,
                .color = noteInkColor(note, state, transport),
                .forced_voice_stem = hasConcurrentPitchedVoice(notes, note),
            };
            anchor_count += 1;
        }
    }

    for (anchors[0..anchor_count], 0..) |first_anchor, first_index| {
        var previous_index: ?usize = null;
        var previous_x = -std.math.inf(f32);
        for (anchors[0..anchor_count], 0..) |candidate, candidate_index| {
            if (candidate.staff != first_anchor.staff or candidate.voice != first_anchor.voice or candidate.system != first_anchor.system or candidate.vocal != first_anchor.vocal or candidate.grace != first_anchor.grace) continue;
            if (candidate.x >= first_anchor.x - 0.001 or candidate.x <= previous_x) continue;
            previous_x = candidate.x;
            previous_index = candidate_index;
        }
        if (previous_index) |index| if ((anchors[index].flags & model.note_flag_beam_end) == 0) continue;
        if ((first_anchor.flags & model.note_flag_beam_mask) == 0) continue;
        var group: [64]usize = undefined;
        var group_count: usize = 1;
        group[0] = first_index;
        var current_index = first_index;
        while (group_count < group.len and (anchors[current_index].flags & model.note_flag_beam_end) == 0) {
            var next_index: ?usize = null;
            var next_x = std.math.inf(f32);
            for (anchors[0..anchor_count], 0..) |candidate, candidate_index| {
                if (candidate.staff != first_anchor.staff or candidate.voice != first_anchor.voice or candidate.system != first_anchor.system or candidate.vocal != first_anchor.vocal or candidate.grace != first_anchor.grace) continue;
                if (candidate.x <= anchors[current_index].x + 0.001 or candidate.x >= next_x) continue;
                if ((candidate.flags & (model.note_flag_beam_continue | model.note_flag_beam_end)) == 0) continue;
                next_x = candidate.x;
                next_index = candidate_index;
            }
            current_index = next_index orelse break;
            group[group_count] = current_index;
            group_count += 1;
        }
        const staff_y = if (first_anchor.vocal) geometry.vocal_y[first_anchor.system] else if (first_anchor.bass) geometry.bass_y[first_anchor.system] else geometry.treble_y[first_anchor.system];
        const cue_scale: f32 = if (first_anchor.grace) 0.72 else 1;
        if (group_count < 2) {
            const stem_up = if (first_anchor.forced_voice_stem) (first_anchor.voice & 1) == 0 else (first_anchor.min_y + first_anchor.max_y) * 0.5 >= staff_y + 24;
            const x = first_anchor.x + (if (stem_up) @as(f32, 6.2) else -6.2) * cue_scale;
            const attach_y = if (stem_up) first_anchor.max_y else first_anchor.min_y;
            const stem_end = if (stem_up) first_anchor.min_y - 29 * cue_scale else first_anchor.max_y + 29 * cue_scale;
            packet.line(x, attach_y, x, stem_end, 1.35 * cue_scale, first_anchor.color);
            packet.musicGlyph(beamFlagGlyph(beamLevelCount(first_anchor.duration), stem_up), x, stem_end, 48 * cue_scale, first_anchor.color);
            continue;
        }

        var center_sum: f32 = 0;
        var group_min_y = std.math.inf(f32);
        var group_max_y = -std.math.inf(f32);
        var forced_voice_stem = false;
        for (group[0..group_count]) |index| {
            center_sum += (anchors[index].min_y + anchors[index].max_y) * 0.5;
            group_min_y = @min(group_min_y, anchors[index].min_y);
            group_max_y = @max(group_max_y, anchors[index].max_y);
            forced_voice_stem = forced_voice_stem or anchors[index].forced_voice_stem;
        }
        const stem_up = if (forced_voice_stem) (first_anchor.voice & 1) == 0 else center_sum / @as(f32, @floatFromInt(group_count)) >= staff_y + 24;
        const first = anchors[group[0]];
        const last = anchors[group[group_count - 1]];
        const first_center = (first.min_y + first.max_y) * 0.5;
        const last_center = (last.min_y + last.max_y) * 0.5;
        const baseline_start = if (stem_up) group_min_y - 29 * cue_scale else group_max_y + 29 * cue_scale;
        const slope = std.math.clamp((last_center - first_center) * 0.22, -6 * cue_scale, 6 * cue_scale);
        const span = @max(last.x - first.x, 0.001);

        var beam_points: [64][2]f32 = undefined;
        for (group[0..group_count], 0..) |index, point_index| {
            const anchor = anchors[index];
            const x = anchor.x + (if (stem_up) @as(f32, 6.2) else -6.2) * cue_scale;
            const t = std.math.clamp((anchor.x - first.x) / span, 0, 1);
            const beam_y = baseline_start + slope * t;
            const attach_y = if (stem_up) anchor.max_y else anchor.min_y;
            packet.line(x, attach_y, x, beam_y, 1.35 * cue_scale, anchor.color);
            beam_points[point_index] = .{ x, beam_y };
        }
        const level_sign: f32 = if (stem_up) 1 else -1;
        for (0..group_count - 1) |point_index| {
            const left = beam_points[point_index];
            const right = beam_points[point_index + 1];
            const left_anchor = anchors[group[point_index]];
            const right_anchor = anchors[group[point_index + 1]];
            const shared_levels = @min(beamLevelCount(left_anchor.duration), beamLevelCount(right_anchor.duration));
            for (0..shared_levels) |level| {
                const offset = level_sign * 6 * cue_scale * @as(f32, @floatFromInt(level));
                packet.line(left[0], left[1] + offset, right[0], right[1] + offset, beamThickness(level) * cue_scale, first.color);
            }
        }

        // A shorter value beside longer neighbors needs a partial beam for
        // every unshared level. Draw each isolated beamlet once and point it
        // inward: starts point right, ends point left, and interior values
        // choose the nearer half of the group deterministically.
        for (group[0..group_count], 0..) |anchor_index, point_index| {
            const anchor = anchors[anchor_index];
            const levels = beamLevelCount(anchor.duration);
            for (1..levels) |level| {
                const left_connected = point_index > 0 and beamLevelCount(anchors[group[point_index - 1]].duration) > level;
                const right_connected = point_index + 1 < group_count and beamLevelCount(anchors[group[point_index + 1]].duration) > level;
                if (left_connected or right_connected) continue;
                const point = beam_points[point_index];
                const point_right = point_index == 0 or ((anchor.flags & model.note_flag_beam_begin) != 0) or (point_index + 1 < group_count and (anchor.flags & model.note_flag_beam_end) == 0 and point_index * 2 < group_count);
                const neighbor_index = if (point_right) point_index + 1 else point_index - 1;
                const neighbor = beam_points[neighbor_index];
                const available = @abs(neighbor[0] - point[0]);
                const hook = @min(@as(f32, 12) * cue_scale, available * 0.38);
                const direction: f32 = if (point_right) 1 else -1;
                const x2 = point[0] + direction * hook;
                const t = hook / @max(0.001, available);
                const y2 = point[1] + (neighbor[1] - point[1]) * t;
                const offset = level_sign * 6 * cue_scale * @as(f32, @floatFromInt(level));
                packet.line(point[0], point[1] + offset, x2, y2 + offset, beamThickness(level) * cue_scale, anchor.color);
            }
        }
    }
}

fn drawTies(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    for (notes) |note| {
        if ((note.flags & model.note_flag_rest) != 0) continue;
        if ((note.flags & model.note_flag_tie_start) == 0) continue;
        const raw_start_position = scoreNotePosition(note, geometry, page, measures);
        const start_position: ?NotePosition = if (raw_start_position) |position| noteRenderPosition(notes, note, position) else null;
        const wanted_beat = note.start_beat + note.duration_beats;
        var target: ?model.Note = null;
        for (notes) |candidate| {
            if ((candidate.flags & model.note_flag_rest) != 0) continue;
            if (sameNotationLayer(candidate, note) and candidate.pitch == note.pitch and candidate.staff == note.staff and candidate.voice == note.voice and @abs(candidate.start_beat - wanted_beat) < 0.03) {
                target = candidate;
                break;
            }
        }
        const tied = target orelse continue;
        const raw_end_position = scoreNotePosition(tied, geometry, page, measures);
        const end_position: ?NotePosition = if (raw_end_position) |position| noteRenderPosition(notes, tied, position) else null;
        if (start_position == null and end_position == null) continue;
        const reference = start_position orelse end_position.?;
        const staff_y = staffYForPosition(geometry, reference);
        const arc_below = reference.y < staff_y + 24;
        const y_sign: f32 = if (arc_below) 1 else -1;
        const color = noteInkColor(note, state, transport);
        if (start_position != null and end_position != null and start_position.?.system == end_position.?.system) {
            const start = start_position.?;
            const ending = end_position.?;
            drawNotationArc(packet, start.x + 7, start.y + y_sign * 7, ending.x - 7, ending.y + y_sign * 7, y_sign, 8, 1.35, color);
            continue;
        }
        drawCrossSystemArc(packet, geometry, note, start_position, end_position, y_sign, 7, 8, 1.35, color);
    }
}

fn findSlurTarget(notes: []const model.Note, start: model.Note, number_bit: u8) ?model.Note {
    var target: ?model.Note = null;
    var nearest_beat = std.math.inf(f32);
    for (notes) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or (model.slurStopMask(candidate) & number_bit) == 0) continue;
        if (!sameNotationLayer(candidate, start) or candidate.staff != start.staff or candidate.voice != start.voice or candidate.start_beat <= start.start_beat or candidate.start_beat >= nearest_beat) continue;
        nearest_beat = candidate.start_beat;
        target = candidate;
    }
    return target;
}

fn slurAbove(notes: []const model.Note, note: model.Note, position: NotePosition, geometry: ScoreGeometry) bool {
    if ((note.flags & model.note_flag_slur_above) != 0) return true;
    const staff_y = staffYForPosition(geometry, position);
    // With no explicit MusicXML placement, put the phrase on the notehead
    // side, opposite the chord stem/beam. Choosing from pitch alone placed
    // an auto slur between noteheads and an up-stem beam, cutting every stem.
    const stem_up = chordStemUp(notes, note, staff_y);
    return !stem_up;
}

const SlurSpan = struct {
    start: model.Note,
    ending: model.Note,
    number_index: usize,
};

fn collectVisibleSlurSpans(notes: []const model.Note, page: ScorePage, spans: *[512]SlurSpan) usize {
    if (page.system_count == 0) return 0;
    const page_start = page.systems[0].start_beat;
    const page_end = page.systems[page.system_count - 1].end_beat;
    var count: usize = 0;
    for (notes) |start| {
        if ((start.flags & model.note_flag_rest) != 0) continue;
        const start_mask = model.slurStartMask(start);
        if (start_mask == 0) continue;
        for (0..8) |number_index| {
            const number_bit = @as(u8, 1) << @intCast(number_index);
            if ((start_mask & number_bit) == 0) continue;
            const ending = findSlurTarget(notes, start, number_bit) orelse continue;
            if (ending.start_beat < page_start - 0.0001 or start.start_beat >= page_end + 0.0001) continue;
            if (count == spans.len) return count;
            spans[count] = .{ .start = start, .ending = ending, .number_index = number_index };
            count += 1;
        }
    }
    return count;
}

fn slurOpticalLane(notes: []const model.Note, spans: []const SlurSpan, span_index: usize, above: bool, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure) usize {
    const span = spans[span_index];
    const start = span.start;
    const ending = span.ending;
    var lane: usize = 0;
    for (spans, 0..) |other, other_index| {
        if (other_index == span_index) continue;
        const other_start = other.start;
        if ((other_start.flags & model.note_flag_rest) != 0 or !sameNotationLayer(other_start, start) or other_start.staff != start.staff or other_start.voice != start.voice) continue;
        const other_end = other.ending;
        const other_above = if (scoreNotePosition(other_start, geometry, page, measures)) |raw_position|
            slurAbove(notes, other_start, noteRenderPosition(notes, other_start, raw_position), geometry)
        else
            (other_start.flags & model.note_flag_slur_above) != 0;
        if (other_above != above) continue;

        const same_start = @abs(other_start.start_beat - start.start_beat) < 0.0001;
        const same_end = @abs(other_end.start_beat - ending.start_beat) < 0.0001;
        if (same_start and same_end) {
            // Coincident independently numbered phrases still need two
            // visible strokes. Lower identifiers occupy the outer lane so
            // the result is deterministic without giving the number any
            // geometric meaning.
            if (other.number_index > span.number_index) lane += 1;
            continue;
        }

        // A phrase containing another complete phrase is the outer arc. It
        // must sit farther from the staff, while the contained phrase remains
        // close to its noteheads.
        const contains = other_start.start_beat >= start.start_beat - 0.0001 and other_end.start_beat <= ending.start_beat + 0.0001 and (!same_start or !same_end);
        if (contains) {
            lane += 1;
            continue;
        }

        // Interleaved spans cannot share the same optical path. Give the
        // later-starting/later-ending phrase the next lane; this keeps the two
        // endpoint hooks distinct rather than crossing at mid-span.
        const crosses_from_left = other_start.start_beat < start.start_beat - 0.0001 and other_end.start_beat > start.start_beat + 0.0001 and other_end.start_beat < ending.start_beat - 0.0001;
        if (crosses_from_left) lane += 1;
    }
    return @min(lane, 5);
}

fn slurCollisionHeight(notes: []const model.Note, start: model.Note, ending: model.Note, start_position: NotePosition, end_position: NotePosition, above: bool, endpoint_clearance: f32, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, base_height: f32) f32 {
    const x1 = start_position.x + 4;
    const x2 = end_position.x + 4;
    const width = x2 - x1;
    if (width <= 2 or start_position.system != end_position.system) return base_height;

    const sign: f32 = if (above) -1 else 1;
    const y1 = start_position.y + sign * endpoint_clearance;
    const y2 = end_position.y + sign * endpoint_clearance;
    var height = base_height;

    // Solve the quadratic arc at every intermediate onset against the full
    // chord/stem/articulation bounds. This keeps a phrase endpoint close to
    // its notehead while lifting only the belly far enough to clear the music
    // inside the span. A fixed-height arc crossed rising arpeggios and beams.
    for (notes) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, start)) continue;
        if (candidate.start_beat <= start.start_beat + 0.0001 or candidate.start_beat >= ending.start_beat - 0.0001) continue;
        const raw_position = scoreNotePosition(candidate, geometry, page, measures) orelse continue;
        const position = noteRenderPosition(notes, candidate, raw_position);
        if (position.system != start_position.system or position.vocal != start_position.vocal or position.bass != start_position.bass) continue;
        const x = position.x;
        if (x <= x1 + 1 or x >= x2 - 1) continue;
        const t = (x - x1) / width;
        const weight = 4 * t * (1 - t);
        if (weight < 0.04) continue;
        const linear_y = y1 + (y2 - y1) * t;
        const staff_y = staffYForPosition(geometry, position);
        const bounds = chordVerticalInkBounds(notes, candidate, staff_y);
        const required = if (above)
            (linear_y - (bounds.top - 7)) / weight
        else
            ((bounds.bottom + 7) - linear_y) / weight;
        height = @max(height, required);
    }
    return std.math.clamp(height, base_height, 144);
}

fn drawSlurs(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    var spans: [512]SlurSpan = undefined;
    const span_count = collectVisibleSlurSpans(notes, page, &spans);
    for (spans[0..span_count], 0..) |span, span_index| {
        const note = span.start;
        const ending = span.ending;
        const raw_start_position = scoreNotePosition(note, geometry, page, measures);
        const start_position: ?NotePosition = if (raw_start_position) |position| noteRenderPosition(notes, note, position) else null;
        const raw_end_position = scoreNotePosition(ending, geometry, page, measures);
        const end_position: ?NotePosition = if (raw_end_position) |position| noteRenderPosition(notes, ending, position) else null;
        if (start_position == null and end_position == null) continue;
        const reference = start_position orelse end_position.?;
        const above = slurAbove(notes, note, reference, geometry);
        const sign: f32 = if (above) -1 else 1;
        // MusicXML numbers identify pairs, not vertical lanes. Derive the
        // lane from span nesting/overlap so an outer number-1 phrase does
        // not cross an inner number-2 phrase (or vice versa).
        const lane = @as(f32, @floatFromInt(slurOpticalLane(notes, spans[0..span_count], span_index, above, geometry, page, measures)));
        // A lane step must exceed one staff-space pitch difference; the
        // old three-pixel step could still make a lower outer endpoint
        // cross a higher inner endpoint at a responsive system edge.
        const clearance = (if (above) @as(f32, 10) else 3) + lane * 12;
        const color = noteInkColor(note, state, transport);
        if (start_position != null and end_position != null and start_position.?.system == end_position.?.system) {
            const start = start_position.?;
            const end = end_position.?;
            const x1 = start.x + 4;
            const x2 = end.x + 4;
            const base_height = (if (above)
                std.math.clamp((x2 - x1) * 0.11, 13, 30)
            else
                std.math.clamp((x2 - x1) * 0.015, 3, 5)) + lane * 8;
            const height = slurCollisionHeight(notes, note, ending, start, end, above, clearance, geometry, page, measures, base_height);
            drawNotationArc(packet, x1, start.y + sign * clearance, x2, end.y + sign * clearance, sign, height, 1.45, color);
            continue;
        }
        drawCrossSystemArc(packet, geometry, note, start_position, end_position, sign, clearance, 18 + lane * 8, 1.45, color);
    }
}

fn drawNotationArc(packet: *render.Packet, x1: f32, y1: f32, x2: f32, y2: f32, sign: f32, height: f32, thickness: f32, color: Color) void {
    if (x2 <= x1 + 2) return;
    // Short continuation hooks must flatten with their horizontal span. A
    // fixed 18 px slur height on a note immediately after a system break
    // looked like a vertical loop instead of the tail of a phrase mark.
    const arc_height = @min(height, @max(@as(f32, 2.5), (x2 - x1) * 0.45));
    var previous_x = x1;
    var previous_y = y1;
    for (1..13) |segment| {
        const t = @as(f32, @floatFromInt(segment)) / 12.0;
        const x = x1 + (x2 - x1) * t;
        const endpoint_y = y1 + (y2 - y1) * t;
        const y = endpoint_y + sign * arc_height * (4 * t * (1 - t));
        packet.line(previous_x, previous_y, x, y, thickness, color);
        previous_x = x;
        previous_y = y;
    }
}

fn notationLayerY(geometry: ScoreGeometry, note: model.Note, system: usize) f32 {
    if ((note.flags & model.note_flag_vocal_guide) != 0) return geometry.vocal_y[system];
    if ((note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58)) return geometry.bass_y[system];
    return geometry.treble_y[system];
}

fn crossSystemArcBaseline(geometry: ScoreGeometry, note: model.Note, system: usize, sign: f32) f32 {
    const staff_y = notationLayerY(geometry, note, system);
    return staff_y + if (sign < 0) @as(f32, -12) else 60;
}

fn drawCrossSystemArc(packet: *render.Packet, geometry: ScoreGeometry, note: model.Note, start_position: ?NotePosition, end_position: ?NotePosition, sign: f32, endpoint_clearance: f32, height: f32, thickness: f32, color: Color) void {
    const left = geometry.music_x + 3;
    const right = geometry.music_x + geometry.music_width - 3;
    const first_system = if (start_position) |start| start.system else 0;
    const last_system = if (end_position) |ending| ending.system else max_score_systems - 1;

    if (start_position) |start| {
        // A broken tie/slur leaves the system on the same optical baseline as
        // its note endpoint. Bending it toward a generic staff lane produced
        // a conspicuous diagonal arc on wide systems.
        const endpoint_y = start.y + sign * endpoint_clearance;
        drawNotationArc(packet, start.x + 4, endpoint_y, right, endpoint_y, sign, height, thickness, color);
    }

    if (start_position != null and end_position != null and last_system > first_system + 1) {
        for (first_system + 1..last_system) |system| {
            const baseline = crossSystemArcBaseline(geometry, note, system, sign);
            drawNotationArc(packet, left, baseline, right, baseline, sign, height, thickness, color);
        }
    }

    if (end_position) |ending| {
        // Likewise, enter the continuation system level with the destination
        // note. This keeps even a note near the left margin from growing a
        // steep hook that can be mistaken for an articulation.
        const endpoint_y = ending.y + sign * endpoint_clearance;
        drawNotationArc(packet, left, endpoint_y, ending.x + 4, endpoint_y, sign, height, thickness, color);
    }
}

const TupletGroup = struct {
    members: [15]model.Note = undefined,
    count: usize = 0,
    fully_beamed: bool = true,

    fn append(self: *TupletGroup, note: model.Note) void {
        if (self.count == self.members.len) return;
        self.members[self.count] = note;
        self.count += 1;
        if ((note.flags & model.note_flag_rest) != 0 or (note.flags & model.note_flag_beam_mask) == 0) self.fully_beamed = false;
    }

    fn slice(self: *const TupletGroup) []const model.Note {
        return self.members[0..self.count];
    }

    fn endBeat(self: *const TupletGroup) f32 {
        if (self.count == 0) return 0;
        const ending = self.members[self.count - 1];
        return ending.start_beat + ending.duration_beats;
    }
};

fn collectTupletGroup(notes: []const model.Note, first: model.Note, actual: u8) TupletGroup {
    var group: TupletGroup = .{};
    group.append(first);
    var last_beat = first.start_beat;
    var explicit_stop = (first.flags & model.note_flag_tuplet_stop) != 0;
    while (!explicit_stop and group.count < @min(@as(usize, actual), group.members.len)) {
        var next_note: ?model.Note = null;
        var next_beat = std.math.inf(f32);
        for (notes) |candidate| {
            if (!sameNotationLayer(candidate, first) or candidate.staff != first.staff or candidate.voice != first.voice) continue;
            if (model.tupletActual(candidate.flags) != actual or candidate.start_beat <= last_beat + 0.0001 or candidate.start_beat >= next_beat) continue;
            next_note = candidate;
            next_beat = candidate.start_beat;
        }
        const next = next_note orelse break;
        group.append(next);
        last_beat = next.start_beat;
        explicit_stop = (next.flags & model.note_flag_tuplet_stop) != 0;
    }
    return group;
}

fn drawTuplets(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    for (notes) |note| {
        const actual = model.tupletActual(note.flags);
        if (actual < 2) continue;
        var has_previous = false;
        for (notes) |candidate| {
            if (!sameNotationLayer(candidate, note) or candidate.staff != note.staff or candidate.voice != note.voice or candidate.start_beat >= note.start_beat) continue;
            if (model.tupletActual(candidate.flags) == actual and note.start_beat - candidate.start_beat <= @max(candidate.duration_beats * 1.1, 0.34)) has_previous = true;
        }
        if ((note.flags & model.note_flag_tuplet_start) == 0 and has_previous) continue;
        const group = collectTupletGroup(notes, note, actual);
        if (group.count < 2) continue;

        var polyphonic = false;
        for (group.slice()) |member| polyphonic = polyphonic or hasConcurrentVoice(notes, member);
        const above = if (polyphonic)
            (note.voice & 1) == 0
        else blk: {
            for (group.slice()) |member| {
                if ((member.flags & model.note_flag_rest) != 0) continue;
                const position = scoreNotePosition(member, geometry, page, measures) orelse continue;
                break :blk chordStemUp(notes, member, staffYForPosition(geometry, position));
            }
            break :blk (note.voice & 1) == 0;
        };
        const color = noteInkColor(note, state, transport);
        for (0..page.system_count) |system| {
            var first_position: ?NotePosition = null;
            var last_position: ?NotePosition = null;
            var minimum_y = std.math.inf(f32);
            var maximum_y = -std.math.inf(f32);
            for (group.slice()) |member| {
                const raw_position = scoreNotePosition(member, geometry, page, measures) orelse continue;
                if (raw_position.system != system) continue;
                const position = noteRenderPosition(notes, member, raw_position);
                if (first_position == null or position.x < first_position.?.x) first_position = position;
                if (last_position == null or position.x > last_position.?.x) last_position = position;
                minimum_y = @min(minimum_y, position.y);
                maximum_y = @max(maximum_y, position.y);
            }
            if (first_position == null or last_position == null) continue;
            const score_system = page.systems[system];
            const continues_left = note.start_beat < score_system.start_beat - 0.0001;
            const continues_right = group.endBeat() > score_system.end_beat + 0.0001;
            var x1 = if (continues_left) geometry.music_x + 3 else first_position.?.x - 3;
            var x2 = if (continues_right) geometry.music_x + geometry.music_width - 3 else last_position.?.x + 7;
            if (x2 < x1 + 24) {
                const middle = (x1 + x2) * 0.5;
                x1 = middle - 12;
                x2 = middle + 12;
            }
            const staff_y = staffYForPosition(geometry, first_position.?);
            const ink_clearance: f32 = if (group.fully_beamed) 40 else 25;
            const y = if (above)
                @min(staff_y - 17, minimum_y - ink_clearance)
            else
                @max(staff_y + 65, maximum_y + ink_clearance);
            const middle = (x1 + x2) * 0.5;
            const bracket = !group.fully_beamed or continues_left or continues_right;
            if (bracket) {
                packet.line(x1, y, middle - 9, y, 1.1, color);
                packet.line(middle + 9, y, x2, y, 1.1, color);
                const tick: f32 = if (above) 5 else -5;
                packet.line(x1, y, x1, y + tick, 1.1, color);
                packet.line(x2, y, x2, y + tick, 1.1, color);
            }
            if (actual <= 9) packet.musicGlyph(0xe080 + @as(u21, actual), middle - 5, y, 28, color);
        }
    }
}

fn drawHarmonyPitch(packet: *render.Packet, start_x: f32, y: f32, step: u8, alter: i8, color: Color) f32 {
    const letter = [_]u8{step};
    packet.text(start_x, y, &letter, 1.0, color);
    var x = start_x + render.Packet.textWidth(&letter, 1.0);
    const glyph: u21 = if (alter < 0) 0xe260 else 0xe262;
    const count: usize = @intCast(@min(@abs(@as(i16, alter)), 2));
    for (0..count) |_| {
        packet.musicGlyph(glyph, x - 1, y + 8, 20, color);
        x += 5.5;
    }
    return x;
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
    const header: f32 = if (panel.height < 110) 30 else 51;
    return .{ .x = panel.x + side, .y = panel.y + header, .width = panel.width - side * 2, .height = @max(28, panel.height - header - 4) };
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
    active_beat: f32 = -std.math.floatMax(f32),
    next: ?u8 = null,
    next_beat: f32 = std.math.floatMax(f32),
};

fn findHandTargets(notes: []const model.Note, cursor: f32, left: bool) HandTargets {
    var result: HandTargets = .{};
    var active_start: f32 = -std.math.floatMax(f32);
    for (notes) |note| {
        if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
        const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
        if (note_left != left or note.pitch < piano_low or note.pitch > piano_high) continue;
        if (note.start_beat <= cursor + 0.025 and note.start_beat + note.duration_beats > cursor and note.start_beat > active_start) {
            result.active = note.pitch;
            result.active_beat = note.start_beat;
            active_start = note.start_beat;
        }
        if (note.start_beat > cursor + 0.04 and note.start_beat < result.next_beat) {
            result.next = note.pitch;
            result.next_beat = note.start_beat;
        }
    }
    if (result.active == null and result.next == null) {
        for (notes) |note| {
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
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

fn intervalFingerPair(targets: HandTargets, left: bool) [2]u8 {
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

const HandPhrase = struct {
    attacks: [fingering.max_phrase_attacks]fingering.Attack = undefined,
    len: usize = 0,

    fn insert(self: *HandPhrase, attack: fingering.Attack) void {
        var index: usize = 0;
        while (index < self.len and self.attacks[index].beat < attack.beat - 0.001) : (index += 1) {}
        // Phrase motion needs one anchor per attack; simultaneous chord tones
        // are expanded into distinct fingers after this melodic optimization.
        // Keep the first score-ordered note here to match findHandTargets.
        if (index < self.len and @abs(self.attacks[index].beat - attack.beat) <= 0.001) return;
        if (self.len >= self.attacks.len) return;
        var move = self.len;
        while (move > index) : (move -= 1) self.attacks[move] = self.attacks[move - 1];
        self.attacks[index] = attack;
        self.len += 1;
    }
};

fn handPhrase(notes: []const model.Note, cursor: f32, left: bool, targets: HandTargets) HandPhrase {
    var result: HandPhrase = .{};
    const active_start = if (targets.active != null) targets.active_beat else cursor;
    const window_start = @min(cursor - 8, active_start - 0.01);
    const window_end = cursor + 16;
    for (notes) |note| {
        if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
        const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
        if (note_left != left or note.pitch < piano_low or note.pitch > piano_high) continue;
        if (note.start_beat < window_start or note.start_beat > window_end) continue;
        result.insert(.{ .beat = note.start_beat, .pitch = note.pitch });
    }
    return result;
}

fn authoredFingerAt(notes: []const model.Note, beat: f32, pitch: u8, left: bool) ?u8 {
    for (notes) |note| {
        if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
        const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
        if (note_left != left or note.pitch != pitch or @abs(note.start_beat - beat) > 0.001) continue;
        if (note.fingering >= 1 and note.fingering <= 5) return note.fingering;
    }
    return null;
}

fn phraseFingerPair(notes: []const model.Note, cursor: f32, targets: HandTargets, left: bool) [2]u8 {
    const fallback = intervalFingerPair(targets, left);
    const current_pitch = targets.active orelse targets.next orelse return fallback;
    const current_beat = if (targets.active != null) targets.active_beat else targets.next_beat;
    const phrase = handPhrase(notes, cursor, left, targets);
    if (phrase.len == 0) return fallback;
    var fingers: [fingering.max_phrase_attacks]u8 = undefined;
    fingering.optimize(phrase.attacks[0..phrase.len], left, fingers[0..phrase.len]);

    var result = fallback;
    for (phrase.attacks[0..phrase.len], fingers[0..phrase.len]) |attack, finger| {
        if (@abs(attack.beat - current_beat) <= 0.001 and attack.pitch == current_pitch) result[0] = finger;
        if (targets.next) |next_pitch| {
            if (@abs(attack.beat - targets.next_beat) <= 0.001 and attack.pitch == next_pitch) result[1] = finger;
        }
    }
    if (authoredFingerAt(notes, current_beat, current_pitch, left)) |finger| result[0] = finger;
    if (targets.next) |next_pitch| {
        if (authoredFingerAt(notes, targets.next_beat, next_pitch, left)) |finger| result[1] = finger;
    }
    if (targets.active == null) result[0] = result[1];
    return result;
}

pub const ChordFingering = struct {
    pitches: [fingering.max_chord_tones]u8 = [_]u8{255} ** fingering.max_chord_tones,
    fingers: [fingering.max_chord_tones]u8 = [_]u8{0} ** fingering.max_chord_tones,
    len: u8 = 0,
    overflow: u8 = 0,

    fn contains(self: ChordFingering, pitch: u8) bool {
        for (self.pitches[0..self.len]) |candidate| if (candidate == pitch) return true;
        return false;
    }

    fn insertPitch(self: *ChordFingering, pitch: u8) void {
        var index: usize = 0;
        while (index < self.len and self.pitches[index] < pitch) : (index += 1) {}
        if (index < self.len and self.pitches[index] == pitch) return;
        if (self.len >= fingering.max_chord_tones) {
            self.overflow +|= 1;
            return;
        }
        var move: usize = self.len;
        while (move > index) : (move -= 1) self.pitches[move] = self.pitches[move - 1];
        self.pitches[index] = pitch;
        self.len += 1;
    }
};

fn chordAt(notes: []const model.Note, beat: f32, left: bool, anchor_pitch: u8, anchor_finger: u8) ChordFingering {
    var result: ChordFingering = .{};
    for (notes) |note| {
        if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
        const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
        if (note_left != left or note.pitch < piano_low or note.pitch > piano_high) continue;
        if (@abs(note.start_beat - beat) > 0.001) continue;
        result.insertPitch(note.pitch);
    }
    if (result.len != 0) {
        fingering.optimizeChord(result.pitches[0..result.len], left, anchor_pitch, anchor_finger, result.fingers[0..result.len]);
        for (notes) |note| {
            if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
            const note_left = (note.staff & 1) != 0 or (note.staff == 0 and note.pitch < 58);
            if (note_left != left or @abs(note.start_beat - beat) > 0.001 or note.fingering < 1 or note.fingering > 5) continue;
            for (result.pitches[0..result.len], 0..) |pitch, index| {
                if (pitch == note.pitch) result.fingers[index] = note.fingering;
            }
        }
    }
    return result;
}

pub const ChordFingeringSnapshot = struct {
    left_current: ChordFingering = .{},
    left_next: ChordFingering = .{},
    right_current: ChordFingering = .{},
    right_next: ChordFingering = .{},
};

pub fn chordFingeringSnapshot(notes: []const model.Note, cursor: f32) ChordFingeringSnapshot {
    const left = findHandTargets(notes, cursor, true);
    const right = findHandTargets(notes, cursor, false);
    const left_fingers = phraseFingerPair(notes, cursor, left, true);
    const right_fingers = phraseFingerPair(notes, cursor, right, false);
    var result: ChordFingeringSnapshot = .{};
    if (left.active) |pitch| {
        result.left_current = chordAt(notes, left.active_beat, true, pitch, left_fingers[0]);
        if (left.next) |next| result.left_next = chordAt(notes, left.next_beat, true, next, left_fingers[1]);
    } else if (left.next) |pitch| {
        result.left_current = chordAt(notes, left.next_beat, true, pitch, left_fingers[0]);
    }
    if (right.active) |pitch| {
        result.right_current = chordAt(notes, right.active_beat, false, pitch, right_fingers[0]);
        if (right.next) |next| result.right_next = chordAt(notes, right.next_beat, false, next, right_fingers[1]);
    } else if (right.next) |pitch| {
        result.right_current = chordAt(notes, right.next_beat, false, pitch, right_fingers[0]);
    }
    return result;
}

pub const FingeringSnapshot = struct {
    left_current_pitch: u8 = 255,
    left_current_finger: u8 = 0,
    left_next_pitch: u8 = 255,
    left_next_finger: u8 = 0,
    right_current_pitch: u8 = 255,
    right_current_finger: u8 = 0,
    right_next_pitch: u8 = 255,
    right_next_finger: u8 = 0,
};

pub fn fingeringSnapshot(notes: []const model.Note, cursor: f32) FingeringSnapshot {
    const left = findHandTargets(notes, cursor, true);
    const right = findHandTargets(notes, cursor, false);
    const left_fingers = phraseFingerPair(notes, cursor, left, true);
    const right_fingers = phraseFingerPair(notes, cursor, right, false);
    return .{
        .left_current_pitch = left.active orelse left.next orelse 255,
        .left_current_finger = if (left.active != null or left.next != null) left_fingers[0] else 0,
        .left_next_pitch = left.next orelse 255,
        .left_next_finger = if (left.next != null) left_fingers[1] else 0,
        .right_current_pitch = right.active orelse right.next orelse 255,
        .right_current_finger = if (right.active != null or right.next != null) right_fingers[0] else 0,
        .right_next_pitch = right.next orelse 255,
        .right_next_finger = if (right.next != null) right_fingers[1] else 0,
    };
}

fn expectedPedalValue(events: []const model.PedalEvent, pedal: u8, cursor_beat: f32) u8 {
    var value: u8 = 0;
    for (events) |event| {
        if (event.start_beat > cursor_beat + 0.0001) break;
        if (event.pedal == pedal) value = event.value;
    }
    return value;
}

fn nextPedalEvent(events: []const model.PedalEvent, pedal: u8, cursor_beat: f32) ?model.PedalEvent {
    for (events) |event| {
        if (event.pedal == pedal and event.start_beat > cursor_beat + 0.01) return event;
    }
    return null;
}

fn nextPedalEventAny(events: []const model.PedalEvent, cursor_beat: f32) ?model.PedalEvent {
    var result: ?model.PedalEvent = null;
    for (events) |event| {
        if (event.start_beat <= cursor_beat + 0.01) continue;
        if (result == null or event.start_beat < result.?.start_beat) result = event;
    }
    return result;
}

fn pedalShortLabel(pedal: u8) []const u8 {
    return switch (pedal) {
        model.pedal_soft => "SOFT",
        model.pedal_sostenuto => "SOST",
        else => "SUST",
    };
}

fn pedalGapNeedsReview(events: []const model.PedalEvent, pedal: u8, cursor_beat: f32, max_gap_beats: f32) bool {
    if (expectedPedalValue(events, pedal, cursor_beat) == 0) return false;
    const next = nextPedalEvent(events, pedal, cursor_beat) orelse return true;
    return next.start_beat - cursor_beat > max_gap_beats + 0.0001;
}

fn pedalCurveRequired(events: []const model.PedalEvent, pedal: u8, system_start: f32, system_end: f32) bool {
    if (pedal != model.pedal_sustain and expectedPedalValue(events, pedal, system_start - 0.001) != 0) return true;
    for (events) |event| {
        if (event.pedal != pedal or event.start_beat < system_start or event.start_beat >= system_end) continue;
        // Soft and sostenuto always need their own semantic lane. Damper uses
        // the familiar Ped. line unless an authored value is genuinely
        // continuous, in which case the pressure curve is shown as well.
        if (pedal != model.pedal_sustain or (event.value != 0 and event.value != 127)) return true;
    }
    return false;
}

fn pedalCurveColor(pedal: u8) Color {
    return switch (pedal) {
        model.pedal_soft => palette.amber,
        model.pedal_sostenuto => palette.rose,
        else => palette.cyan,
    };
}

fn pedalCurveLabel(pedal: u8) []const u8 {
    return switch (pedal) {
        model.pedal_soft => "UC",
        model.pedal_sostenuto => "SOST",
        else => "SUST",
    };
}

fn pedalCurveY(baseline: f32, value: u8) f32 {
    return baseline - @as(f32, @floatFromInt(value)) / 127.0 * 8.0;
}

const PedalCurveSystemLayout = struct {
    notation_y: f32,
    kinds: [3]u8 = undefined,
    baselines: [3]f32 = undefined,
    count: usize = 0,
};

pub const PedalCurveHit = struct {
    system: usize,
    pedal: u8,
    beat: f32,
    value: u8,
    baseline: f32,
    event_index: ?usize = null,
};

fn pedalCurveSystemLayout(events: []const model.PedalEvent, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, system: usize, editing: bool) PedalCurveSystemLayout {
    const score_system = page.systems[system];
    const next_system_top = if (system + 1 < page.system_count) geometry.vocal_y[system + 1] else geometry.page_y + geometry.page_height;
    var lowest_bass_ink = geometry.bass_y[system] + 52;
    for (notes) |note| {
        const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        if (position.system != system or !position.bass) continue;
        var extent = position.y + if ((note.flags & model.note_flag_rest) != 0) @as(f32, 16) else 42;
        if (model.dynamic(note.flags) != 0) extent = @max(extent, geometry.bass_y[system] + 84);
        const below_articulation_mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato | model.note_flag_fermata;
        if ((note.flags & below_articulation_mask) != 0 and chordStemUp(notes, note, geometry.bass_y[system])) extent += 18;
        if ((note.notations & model.note_notation_ornament_mask) != 0 and (note.notations & model.note_notation_ornament_below) != 0) extent += 34;
        lowest_bass_ink = @max(lowest_bass_ink, extent);
    }
    const notation_y = @min(@max(geometry.bass_y[system] + 76, lowest_bass_ink + 16), next_system_top - 18);
    var result = PedalCurveSystemLayout{ .notation_y = notation_y };
    for ([_]u8{ model.pedal_soft, model.pedal_sostenuto, model.pedal_sustain }) |pedal| {
        if (!editing and !pedalCurveRequired(events, pedal, score_system.start_beat, score_system.end_beat)) continue;
        result.kinds[result.count] = pedal;
        result.count += 1;
    }
    if (result.count == 0) return result;
    const curve_bottom = notation_y - 18;
    const curve_top = lowest_bass_ink + 12;
    const spacing = if (result.count > 1)
        std.math.clamp((curve_bottom - curve_top) / @as(f32, @floatFromInt(result.count - 1)), 7, 13)
    else
        0;
    for (result.kinds[0..result.count], 0..) |_, index| {
        const reverse_index = result.count - index - 1;
        result.baselines[index] = curve_bottom - spacing * @as(f32, @floatFromInt(reverse_index));
    }
    return result;
}

fn pedalCurveBaseline(layout: PedalCurveSystemLayout, pedal: u8) ?f32 {
    for (layout.kinds[0..layout.count], 0..) |kind, index| if (kind == pedal) return layout.baselines[index];
    return null;
}

pub fn pedalCurveEditPosition(events: []const model.PedalEvent, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, system: usize, pedal: u8, x: f32, y: f32, editing: bool) ?PedalCurveHit {
    if (system >= page.system_count or x < geometry.music_x - 12 or x > geometry.music_x + geometry.music_width + 12) return null;
    const layout = pedalCurveSystemLayout(events, notes, geometry, page, measures, system, editing);
    const baseline = pedalCurveBaseline(layout, pedal) orelse return null;
    const raw_value = std.math.clamp((baseline - y) / 8.0, 0, 1) * 127.0;
    return .{
        .system = system,
        .pedal = pedal,
        .beat = scoreBeatAtX(geometry, page, measures, system, x),
        .value = @intFromFloat(@round(raw_value)),
        .baseline = baseline,
    };
}

/// Resolve an edit-mode pointer against the exact pressure-lane geometry used
/// by the renderer. A click near an existing control point selects it;
/// otherwise it produces a new semantic point on the nearest lane.
pub fn pedalCurveHitAt(events: []const model.PedalEvent, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, x: f32, y: f32, editing: bool) ?PedalCurveHit {
    if (x < geometry.music_x - 12 or x > geometry.music_x + geometry.music_width + 12) return null;

    // Resolve authored points before resolving a lane. Compact multi-system
    // pages can place two eight-pixel pressure bands close together; choosing
    // a lane first made a perfectly visible high point belong to its neighbor.
    // The rendered point is the unambiguous object the user is grabbing.
    var existing: ?PedalCurveHit = null;
    var point_distance_squared: f32 = 11 * 11;
    for (0..page.system_count) |system| {
        const layout = pedalCurveSystemLayout(events, notes, geometry, page, measures, system, editing);
        const score_system = page.systems[system];
        for (layout.kinds[0..layout.count], 0..) |pedal, lane_index| {
            const baseline = layout.baselines[lane_index];
            for (events, 0..) |event, index| {
                if (event.pedal != pedal or event.start_beat < score_system.start_beat or event.start_beat >= score_system.end_beat) continue;
                const point = scoreBeatPosition(geometry, page, measures, event.start_beat) orelse continue;
                if (point.system != system) continue;
                const point_y = pedalCurveY(baseline, event.value);
                const dx = point.x - x;
                const dy = point_y - y;
                const distance_squared = dx * dx + dy * dy;
                if (distance_squared >= point_distance_squared) continue;
                point_distance_squared = distance_squared;
                existing = .{
                    .system = system,
                    .pedal = pedal,
                    .beat = event.start_beat,
                    .value = event.value,
                    .baseline = baseline,
                    .event_index = index,
                };
            }
        }
    }
    if (existing) |hit| return hit;

    var best: ?PedalCurveHit = null;
    var best_lane_distance: f32 = std.math.floatMax(f32);
    for (0..page.system_count) |system| {
        const layout = pedalCurveSystemLayout(events, notes, geometry, page, measures, system, editing);
        for (layout.kinds[0..layout.count], 0..) |pedal, lane_index| {
            const baseline = layout.baselines[lane_index];
            // An empty lane is selected from its zero-pressure baseline. This
            // makes clicking the visible guide deterministic even when the
            // neighboring pressure envelopes nearly touch.
            const distance = @abs(y - baseline);
            if (distance >= best_lane_distance) continue;
            best_lane_distance = distance;
            best = pedalCurveEditPosition(events, notes, geometry, page, measures, system, pedal, x, y, editing);
        }
    }
    if (best_lane_distance > 8.5) return null;
    return best;
}

fn drawPedalCurveLane(packet: *render.Packet, events: []const model.PedalEvent, pedal: u8, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, system_index: usize, baseline: f32, transport: *const model.Transport, state: *const model.UiState) void {
    const system = page.systems[system_index];
    const color = pedalCurveColor(pedal);
    packet.text(geometry.music_x - if (pedal == model.pedal_sostenuto) @as(f32, 32) else 22, baseline - 11, pedalCurveLabel(pedal), 0.52, color);

    // A compact per-measure pressure/change heatmap makes long or over-busy
    // pedal plans visible before playback without covering either staff.
    var measure_index = system.first_measure;
    while (measure_index < system.measure_end and measure_index < measures.len) : (measure_index += 1) {
        const measure = measures[measure_index];
        const measure_end = measure.start_beat + @max(0.0001, measure.duration_beats);
        var peak = expectedPedalValue(events, pedal, measure.start_beat - 0.001);
        var changes: u8 = 0;
        for (events) |event| {
            if (event.pedal != pedal or event.start_beat < measure.start_beat or event.start_beat >= measure_end) continue;
            peak = @max(peak, event.value);
            changes +|= 1;
        }
        if (peak == 0 and changes == 0) continue;
        const left = measureBoundaryX(geometry, system, measure.start_beat);
        const right = measureBoundaryX(geometry, system, measure_end);
        const pressure = @as(f32, @floatFromInt(peak)) / 127.0;
        const activity = @min(@as(f32, @floatFromInt(changes)) / 4.0, 1.0);
        packet.rect(left + 1, baseline - 9, @max(1, right - left - 2), 10, .{ color[0], color[1], color[2], 0.035 + pressure * 0.075 + activity * 0.055 });
    }

    const previous_value = expectedPedalValue(events, pedal, system.start_beat - 0.001);
    var previous_x = geometry.music_x;
    var previous_y = pedalCurveY(baseline, previous_value);
    for (events) |event| {
        if (event.pedal != pedal or event.start_beat < system.start_beat or event.start_beat >= system.end_beat) continue;
        const x = (scoreBeatPosition(geometry, page, measures, event.start_beat) orelse continue).x;
        const next_y = pedalCurveY(baseline, event.value);
        packet.line(previous_x, previous_y, x, previous_y, 1.05, .{ color[0], color[1], color[2], 0.72 });
        if (@abs(next_y - previous_y) > 0.01) packet.line(x, previous_y, x, next_y, 1.05, .{ color[0], color[1], color[2], 0.82 });
        const selected = state.pedal_edit_selected != 0 and state.pedal_edit_kind == pedal and @abs(state.pedal_edit_beat - event.start_beat) < 0.001;
        const active = @abs(transport.cursor_beat - event.start_beat) < 0.22;
        if (selected) packet.ellipse(x - 5.2, next_y - 5.2, 10.4, 10.4, .{ color[0], color[1], color[2], 0.28 });
        packet.ellipse(x - if (selected) @as(f32, 3.2) else 2.3, next_y - if (selected) @as(f32, 3.2) else 2.3, if (selected) 6.4 else 4.6, if (selected) 6.4 else 4.6, if (active) palette.cyan else color);
        previous_x = x;
        previous_y = next_y;
    }
    packet.line(previous_x, previous_y, geometry.music_x + geometry.music_width, previous_y, 1.05, .{ color[0], color[1], color[2], 0.72 });
}

const max_hairpin_optical_lanes: usize = 6;
const hairpin_lane_group_count: usize = 256 * 4;
// MusicXML wedges can open to a 9 px half-height. This keeps concurrent
// wedges distinct even when both use their maximum authored spread.
const hairpin_lane_spacing: f32 = 22;

fn hairpinLaneGroup(hairpin: model.Hairpin) usize {
    const vocal: usize = if ((hairpin.flags & model.hairpin_flag_vocal) != 0) 2 else 0;
    const above: usize = if ((hairpin.flags & model.hairpin_flag_above) != 0) 1 else 0;
    return @as(usize, hairpin.staff) * 4 + vocal + above;
}

/// Assign overlapping wedges on the same staff/side to deterministic optical
/// lanes. MusicXML numbers pair starts and stops; they are not placement hints.
/// Imported hairpins are start-beat sorted, so interval partitioning gives the
/// minimum lane count without per-frame allocation or quadratic collision
/// scans. A lane becomes reusable exactly when its previous wedge ends.
fn resolveHairpinOpticalLanes(hairpins: []const model.Hairpin, state: *const model.UiState, lanes: []u8) void {
    @memset(lanes, 0);
    var lane_ends: [hairpin_lane_group_count][max_hairpin_optical_lanes]f32 = undefined;
    for (&lane_ends) |*group| @memset(group, -std.math.inf(f32));

    for (hairpins[0..@min(hairpins.len, lanes.len)], 0..) |hairpin, index| {
        if (!model.hairpinVisibleInPart(hairpin, state.selected_part, state.vocal_guide_visible != 0)) continue;
        if (hairpin.kind != model.hairpin_crescendo and hairpin.kind != model.hairpin_diminuendo) continue;
        const start = @min(hairpin.start_beat, hairpin.end_beat);
        const ending = @max(hairpin.start_beat, hairpin.end_beat);
        const group = &lane_ends[hairpinLaneGroup(hairpin)];
        var lane: usize = 0;
        while (lane + 1 < group.len and group[lane] > start + 0.0001) : (lane += 1) {}
        lanes[index] = @intCast(lane);
        group[lane] = @max(group[lane], ending);
    }
}

fn hairpinLaneY(hairpin: model.Hairpin, geometry: ScoreGeometry, system: usize, optical_lane: u8) f32 {
    const above = (hairpin.flags & model.hairpin_flag_above) != 0;
    const lane_offset = @as(f32, @floatFromInt(optical_lane)) * hairpin_lane_spacing;
    if ((hairpin.flags & model.hairpin_flag_vocal) != 0) {
        return if (above) geometry.vocal_y[system] - 17 - lane_offset else geometry.lyric_y[system] - 18 + lane_offset;
    }
    const bass = (hairpin.staff % model.staff_slots_per_part & 1) != 0;
    if (bass) return if (above) geometry.bass_y[system] - 17 - lane_offset else geometry.bass_y[system] + 66 + lane_offset;
    return if (above) geometry.treble_y[system] - 17 - lane_offset else geometry.treble_y[system] + 65 + lane_offset;
}

fn drawStyledHairpinLine(packet: *render.Packet, x1: f32, y1: f32, x2: f32, y2: f32, flags: u8) void {
    const dashed = (flags & model.hairpin_flag_dashed) != 0;
    const dotted = (flags & model.hairpin_flag_dotted) != 0;
    if (!dashed and !dotted) {
        packet.line(x1, y1, x2, y2, 1.2, palette.ink);
        return;
    }
    const dx = x2 - x1;
    const dy = y2 - y1;
    const distance = @sqrt(dx * dx + dy * dy);
    if (distance < 0.01) return;
    const nominal_step: f32 = if (dotted) 5 else 10;
    const count: usize = @max(1, @min(@as(usize, 96), @as(usize, @intFromFloat(@ceil(distance / nominal_step)))));
    const inv = 1.0 / @as(f32, @floatFromInt(count));
    for (0..count) |index| {
        const start_t = @as(f32, @floatFromInt(index)) * inv;
        if (dotted) {
            const x = x1 + dx * start_t;
            const y = y1 + dy * start_t;
            packet.ellipse(x - 1.1, y - 1.1, 2.2, 2.2, palette.ink);
        } else {
            const end_t = @min(1, start_t + inv * 0.58);
            packet.line(x1 + dx * start_t, y1 + dy * start_t, x1 + dx * end_t, y1 + dy * end_t, 1.2, palette.ink);
        }
    }
}

/// Engrave semantic MusicXML wedges without flattening them into per-system
/// graphics. A wedge that crosses a responsive line/page boundary retains its
/// global opening at both sides of every continuation segment.
fn drawHairpins(packet: *render.Packet, hairpins: []const model.Hairpin, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState) void {
    var optical_lanes: [1024]u8 = undefined;
    resolveHairpinOpticalLanes(hairpins, state, optical_lanes[0..@min(hairpins.len, optical_lanes.len)]);
    for (hairpins, 0..) |hairpin, hairpin_index| {
        if (!model.hairpinVisibleInPart(hairpin, state.selected_part, state.vocal_guide_visible != 0)) continue;
        if (hairpin.kind != model.hairpin_crescendo and hairpin.kind != model.hairpin_diminuendo) continue;
        const authored_start = @min(hairpin.start_beat, hairpin.end_beat);
        const authored_end = @max(hairpin.start_beat, hairpin.end_beat);
        const duration = @max(0.0001, authored_end - authored_start);
        const spread = std.math.clamp(hairpin.spread * 0.8, 7, 18) * 0.5;
        for (page.systems[0..page.system_count], 0..) |system, system_index| {
            const segment_start = @max(authored_start, system.start_beat);
            const segment_end = @min(authored_end, system.end_beat);
            if (segment_end <= segment_start + 0.0001) continue;
            const x1 = if (segment_start <= system.start_beat + 0.0001)
                geometry.music_x
            else
                (scoreBeatPosition(geometry, page, measures, segment_start) orelse continue).x;
            const x2 = if (segment_end >= system.end_beat - 0.0001)
                geometry.music_x + geometry.music_width
            else
                (scoreBeatPosition(geometry, page, measures, segment_end) orelse continue).x;
            const progress_start = std.math.clamp((segment_start - authored_start) / duration, 0, 1);
            const progress_end = std.math.clamp((segment_end - authored_start) / duration, 0, 1);
            const opening_start = if (hairpin.kind == model.hairpin_crescendo) spread * progress_start else spread * (1 - progress_start);
            const opening_end = if (hairpin.kind == model.hairpin_crescendo) spread * progress_end else spread * (1 - progress_end);
            const optical_lane = if (hairpin_index < optical_lanes.len) optical_lanes[hairpin_index] else 0;
            const lane_y = hairpinLaneY(hairpin, geometry, system_index, optical_lane);
            drawStyledHairpinLine(packet, x1, lane_y - opening_start, x2, lane_y - opening_end, hairpin.flags);
            drawStyledHairpinLine(packet, x1, lane_y + opening_start, x2, lane_y + opening_end, hairpin.flags);

            if ((hairpin.flags & model.hairpin_flag_niente) != 0) {
                const closed_at_start = hairpin.kind == model.hairpin_crescendo and @abs(segment_start - authored_start) < 0.0001;
                const closed_at_end = hairpin.kind == model.hairpin_diminuendo and @abs(segment_end - authored_end) < 0.0001;
                if (closed_at_start or closed_at_end) {
                    const x = if (closed_at_start) x1 else x2;
                    packet.ellipse(x - 4, lane_y - 4, 8, 8, palette.ink);
                    packet.ellipse(x - 2.4, lane_y - 2.4, 4.8, 4.8, palette.paper);
                }
            }
        }
    }
}

fn drawPedalNotation(packet: *render.Packet, events: []const model.PedalEvent, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, transport: *const model.Transport, state: *const model.UiState) void {
    for (0..page.system_count) |system| {
        const system_start = page.systems[system].start_beat;
        const system_end = page.systems[system].end_beat;
        const curve_layout = pedalCurveSystemLayout(events, notes, geometry, page, measures, system, state.tool == .edit);
        const y = curve_layout.notation_y;
        for (curve_layout.kinds[0..curve_layout.count], 0..) |pedal, index| drawPedalCurveLane(packet, events, pedal, geometry, page, measures, system, curve_layout.baselines[index], transport, state);
        // Sample just before the system boundary. Clamping the first system to
        // beat zero incorrectly treats a pedal-down exactly at the opening as
        // pre-existing state and draws a stray line before its `Ped.` mark.
        var down = expectedPedalValue(events, model.pedal_sustain, system_start - 0.001) >= 64;
        var line_start = geometry.music_x;
        var line_enabled = down;
        for (events) |event| {
            if (event.pedal != model.pedal_sustain or event.start_beat < system_start or event.start_beat >= system_end) continue;
            const x = (scoreBeatPosition(geometry, page, measures, event.start_beat) orelse continue).x;
            const active = @abs(transport.cursor_beat - event.start_beat) < 0.22;
            const color = if (active) palette.cyan else palette.ink;
            const event_line = (event.flags & model.pedal_flag_line) != 0;
            switch (event.action) {
                model.pedal_action_start, model.pedal_action_resume => {
                    if (down and line_enabled) packet.line(line_start, y, x - 3, y, 1.05, palette.ink);
                    packet.text(x - 2, y - 13, "Ped.", 0.72, color);
                    line_start = x + 24;
                    down = true;
                    line_enabled = event_line;
                    if (line_enabled) packet.line(line_start, y, line_start, y - 5, 1.05, color);
                },
                model.pedal_action_stop, model.pedal_action_discontinue => {
                    if (down and line_enabled) {
                        packet.line(line_start, y, x, y, 1.05, palette.ink);
                        packet.line(x, y, x, y - 6, 1.05, color);
                    } else {
                        packet.text(x - 2, y - 13, "*", 0.9, color);
                    }
                    down = false;
                    line_enabled = false;
                },
                model.pedal_action_change => {
                    if (down and line_enabled) {
                        packet.line(line_start, y, x - 4, y, 1.05, palette.ink);
                        packet.line(x - 4, y, x, y + 5, 1.05, color);
                        packet.line(x, y + 5, x + 4, y, 1.05, color);
                        line_start = x + 4;
                    } else {
                        packet.text(x - 2, y - 13, "Ped.", 0.72, color);
                        line_start = x + 24;
                    }
                    down = true;
                    line_enabled = event_line or line_enabled;
                },
                model.pedal_action_continue => {
                    down = true;
                    line_enabled = event_line or line_enabled;
                    line_start = x;
                },
                else => {},
            }
        }
        if (down and line_enabled) packet.line(line_start, y, geometry.music_x + geometry.music_width, y, 1.05, palette.ink);
    }
}

fn keyColor(pitch: u8, guide: ChordFingeringSnapshot, hovered: ?u8, black: bool) Color {
    if (guide.left_current.contains(pitch)) return if (black) .{ 0.76, 0.43, 0.14, 1 } else .{ 0.98, 0.75, 0.39, 1 };
    if (guide.right_current.contains(pitch)) return if (black) .{ 0.11, 0.62, 0.61, 1 } else .{ 0.45, 0.92, 0.88, 1 };
    if (guide.left_next.contains(pitch)) return if (black) .{ 0.36, 0.25, 0.15, 1 } else .{ 0.36, 0.30, 0.23, 1 };
    if (guide.right_next.contains(pitch)) return if (black) .{ 0.12, 0.32, 0.34, 1 } else .{ 0.20, 0.38, 0.39, 1 };
    if (hovered == pitch) return if (black) palette.rose else .{ 0.96, 0.76, 0.80, 1 };
    return if (black) .{ 0.055, 0.063, 0.077, 1 } else .{ 0.88, 0.88, 0.85, 1 };
}

fn drawFingeringGuide(packet: *render.Packet, panel: Rect, current: ChordFingering, next: ChordFingering, left: bool) void {
    if (current.len == 0) return;
    const accent = if (left) palette.amber else palette.cyan;
    const keys = pianoKeysRect(panel);
    var finger_buffer: [2]u8 = undefined;
    for (current.pitches[0..current.len], current.fingers[0..current.len]) |pitch, finger| {
        const x = pianoKeyCenter(panel, pitch);
        const y = keys.y + keys.height * (if (isBlackKey(pitch)) @as(f32, 0.40) else 0.68);
        packet.ellipse(x - 9, y - 9, 18, 18, .{ accent[0], accent[1], accent[2], 0.96 });
        packet.text(x - 3, y - 5, std.fmt.bufPrint(&finger_buffer, "{d}", .{finger}) catch "3", 0.88, palette.background);
    }
    for (next.pitches[0..next.len], next.fingers[0..next.len]) |pitch, finger| {
        if (current.contains(pitch)) continue;
        const x = pianoKeyCenter(panel, pitch);
        const y = keys.y + keys.height * (if (isBlackKey(pitch)) @as(f32, 0.25) else 0.52);
        packet.ellipse(x - 7, y - 7, 14, 14, .{ accent[0], accent[1], accent[2], 0.42 });
        packet.text(x - 3, y - 5, std.fmt.bufPrint(&finger_buffer, "{d}", .{finger}) catch "3", 0.82, palette.text);
    }
    if (current.overflow != 0 or next.overflow != 0) {
        packet.text(keys.x + if (left) @as(f32, 0) else keys.width - 132, panel.y + 35, "REDISTRIBUTE >5", 0.68, palette.rose);
    }
}

fn drawPedalStatus(packet: *render.Packet, panel: Rect, state: *const model.UiState, transport: *const model.Transport, pedals: []const model.PedalEvent) void {
    if (panel.width < 880) return;
    const labels = [_][]const u8{ "SOFT", "SOST", "SUST" };
    const values = [_]u32{ state.soft_pedal, state.sostenuto_pedal, state.sustain_pedal };
    const kinds = [_]u8{ model.pedal_soft, model.pedal_sostenuto, model.pedal_sustain };
    const start_x = panel.x + panel.width - 352;
    if (panel.width >= 800) {
        packet.text(start_x - 128, panel.y + 18, "LIVE / SCORE", 0.68, palette.muted);
        const cursor = @max(0, transport.cursor_beat);
        var review_kind: ?u8 = null;
        for ([_]u8{ model.pedal_soft, model.pedal_sostenuto, model.pedal_sustain }) |kind| {
            if (pedalGapNeedsReview(pedals, kind, cursor, 16)) {
                review_kind = kind;
                break;
            }
        }
        if (review_kind) |kind| {
            var review_buffer: [48]u8 = undefined;
            const review = std.fmt.bufPrint(&review_buffer, "{s} PLAN REVIEW / LONG HOLD", .{pedalShortLabel(kind)}) catch "PEDAL PLAN REVIEW";
            packet.text(start_x - 330, panel.y + 18, review, 0.72, palette.rose);
        } else if (nextPedalEventAny(pedals, cursor)) |next| {
            var instruction_buffer: [64]u8 = undefined;
            const action: []const u8 = switch (next.action) {
                model.pedal_action_stop, model.pedal_action_discontinue => "UP",
                model.pedal_action_change => "CHANGE",
                else => "DOWN",
            };
            const instruction = std.fmt.bufPrint(&instruction_buffer, "NEXT {s} {s}  {d:.1} BEATS", .{ pedalShortLabel(next.pedal), action, next.start_beat - cursor }) catch "NEXT PEDAL CHANGE";
            packet.text(start_x - 330, panel.y + 18, instruction, 0.72, palette.amber);
        }
    }
    for (labels, values, kinds, 0..) |label, value, kind, index| {
        const x = start_x + @as(f32, @floatFromInt(index)) * 58;
        const amount = @as(f32, @floatFromInt(@min(value, 127))) / 127.0;
        const expected = @as(f32, @floatFromInt(expectedPedalValue(pedals, kind, @max(0, transport.cursor_beat)))) / 127.0;
        const mismatch = @abs(amount - expected) > 0.38;
        packet.rounded(x, panel.y + 10, 52, 28, 8, palette.panel_raised);
        if (amount > 0.001) packet.rounded(x + 2, panel.y + 30 - amount * 18, 48, amount * 6 + 6, 6, .{ palette.cyan[0], palette.cyan[1], palette.cyan[2], 0.42 + amount * 0.48 });
        if (expected > 0.001) packet.rect(x + 3, panel.y + 29 - expected * 18, 46, 1.5, if (mismatch) palette.rose else palette.amber);
        packet.text(x + 7, panel.y + 18, label, 0.72, if (mismatch) palette.rose else if (amount >= 0.5) palette.text else palette.muted);
    }
}

fn drawKeyboard(packet: *render.Packet, panel: Rect, state: *const model.UiState, transport: *const model.Transport, notes: []const model.Note, pedals: []const model.PedalEvent) void {
    const compact = panel.height < 110;
    packet.rect(panel.x, panel.y, panel.width, panel.height, .{ 0.055, 0.064, 0.078, 1 });
    packet.rect(panel.x, panel.y, panel.width, 1, palette.border);
    packet.text(panel.x + 24, panel.y + if (compact) @as(f32, 9) else 14, "Guided piano", if (compact) 1.05 else 1.55, palette.text);
    if (!compact and showKeyboardInstruction(panel.width, state.pedal_guide_visible != 0)) packet.text(panel.x + 142, panel.y + 17, "Follow the glow / 1 thumb / 5 little finger", 1.0, palette.muted);
    if (state.pedal_guide_visible != 0) drawPedalStatus(packet, panel, state, transport, pedals);
    packet.ellipse(panel.x + panel.width - 146, panel.y + if (compact) @as(f32, 12) else 18, 8, 8, palette.amber);
    packet.text(panel.x + panel.width - 133, panel.y + if (compact) @as(f32, 8) else 14, "Left", if (compact) 0.82 else 1.05, palette.muted);
    packet.ellipse(panel.x + panel.width - 78, panel.y + if (compact) @as(f32, 12) else 18, 8, 8, palette.cyan);
    packet.text(panel.x + panel.width - 65, panel.y + if (compact) @as(f32, 8) else 14, "Right", if (compact) 0.82 else 1.05, palette.muted);

    const cursor = @max(0, transport.cursor_beat);
    const guide = chordFingeringSnapshot(notes, cursor);
    const hovered = pianoPitchAt(panel, state.pointer_x, state.pointer_y);
    const keys = pianoKeysRect(panel);
    const white_width = keys.width / piano_white_count;
    var pitch: u8 = piano_low;
    while (pitch <= piano_high) : (pitch += 1) {
        if (isBlackKey(pitch)) continue;
        const before: f32 = @floatFromInt(whiteIndexBefore(pitch));
        const x = keys.x + before * white_width;
        packet.rounded(x, keys.y, white_width + 0.25, keys.height, 2.5, .{ 0.13, 0.14, 0.16, 1 });
        packet.rounded(x + 0.7, keys.y + 0.8, @max(1, white_width - 1.15), keys.height - 1.6, 2, keyColor(pitch, guide, hovered, false));
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
        packet.rounded(x, keys.y, black_width, keys.height * 0.62, 2.5, keyColor(pitch, guide, hovered, true));
    }
    drawFingeringGuide(packet, panel, guide.left_current, guide.left_next, true);
    drawFingeringGuide(packet, panel, guide.right_current, guide.right_next, false);
}

fn showKeyboardInstruction(panel_width: f32, pedal_guide_visible: bool) bool {
    // The pedal countdown starts 682 px from the right edge. At tablet/browser
    // widths its variable text otherwise occupies the same lane as the static
    // fingering hint. Preserve the useful hint when pedals are hidden, and
    // reserve the whole status lane when the three-pedal guide is active.
    return panel_width >= (if (pedal_guide_visible) @as(f32, 1120) else 560);
}

test "guided-piano hint yields its lane to pedal status at browser widths" {
    try std.testing.expect(!showKeyboardInstruction(904, true));
    try std.testing.expect(showKeyboardInstruction(904, false));
    try std.testing.expect(showKeyboardInstruction(1280, true));
}

fn drawAnnotationsPage(packet: *render.Packet, stage: Rect, page: ScorePage, vocal_visible: bool, measures: []const model.Measure, annotations: *const annotation.Store) void {
    drawAnnotationsPageWithLayout(packet, stage, page, vocal_visible, measures, annotations, page.system_count);
}

fn drawAnnotationsPageWithLayout(packet: *render.Packet, stage: Rect, page: ScorePage, vocal_visible: bool, measures: []const model.Measure, annotations: *const annotation.Store, layout_system_count: usize) void {
    const geometry = ScoreGeometry.calculateForSystems(stage, vocal_visible, @max(@as(usize, 1), layout_system_count));
    for (annotations.strokes[0..annotations.stroke_count]) |stroke| {
        if (!annotation.isScoreSpace(stroke) and annotation.pageIndex(stroke) != page.page_index) continue;
        const start: usize = @intCast(stroke.first_point);
        const end = start + stroke.point_count;
        for (annotations.points[start..end]) |point| {
            const pressure_width = stroke.width * (0.6 + point.pressure * 0.8);
            var x = stage.x + point.u * stage.width;
            var y = stage.y + point.v * stage.height;
            if (annotation.isScoreSpace(stroke)) {
                const beat_position = scoreBeatPosition(geometry, page, measures, point.u) orelse continue;
                const top = if (vocal_visible) geometry.vocal_y[beat_position.system] else geometry.treble_y[beat_position.system];
                const bottom = geometry.bass_y[beat_position.system] + 49;
                x = beat_position.x;
                y = top + point.v * (bottom - top);
            }
            packet.ellipse(
                x - pressure_width * 0.5,
                y - pressure_width * 0.5,
                pressure_width,
                pressure_width,
                stroke.rgba,
            );
        }
    }
}

test "score ink follows its page through zoom transforms" {
    var annotations: annotation.Store = .{};
    annotations.begin(.{ .u = 0.25, .v = 0.4, .pressure = 0.5, .time_ms = 0 }, 3);
    annotations.end();
    var packet: render.Packet = undefined;
    packet.reset();
    const stage = Rect{ .x = 100, .y = 50, .width = 800, .height = 600 };
    var page: ScorePage = .{ .page_index = 3 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 8 };
    page.systems[1] = .{ .start_beat = 8, .end_beat = 16 };
    drawAnnotationsPage(&packet, stage, page, false, &.{}, &annotations);
    try std.testing.expectEqual(@as(usize, 1), packet.len);
    transformScoreItems(&packet, 0, stage, 0.75);
    const item = packet.slice()[0];
    try std.testing.expectApproxEqAbs(@as(f32, 348.5), item.rect[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 303.5), item.rect[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), item.rect[2], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), item.rect[3], 0.01);
}

test "score-space ink follows its beat when responsive pagination reflows systems" {
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
        .{ .start_beat = 8, .duration_beats = 4, .number = 3 },
        .{ .start_beat = 12, .duration_beats = 4, .number = 4 },
    };
    var annotations: annotation.Store = .{};
    annotations.beginScore(.{ .u = 10, .v = 0.5, .pressure = 0.5, .time_ms = 0 }, 0);
    annotations.end();

    const roomy_stage = Rect{ .x = 0, .y = 0, .width = 900, .height = 760 };
    const roomy_page = scorePageForBeatLimited(&measures, 10, &.{}, 1, 2);
    var roomy_packet: render.Packet = undefined;
    roomy_packet.reset();
    drawAnnotationsPage(&roomy_packet, roomy_stage, roomy_page, true, &measures, &annotations);
    try std.testing.expectEqual(@as(usize, 1), roomy_packet.len);
    const roomy_geometry = ScoreGeometry.calculateWithVocal(roomy_stage, true);
    const roomy_position = scoreBeatPosition(roomy_geometry, roomy_page, &measures, 10) orelse return error.TestUnexpectedResult;
    const roomy_center_y = roomy_packet.slice()[0].rect[1] + roomy_packet.slice()[0].rect[3] * 0.5;
    try std.testing.expectEqual(@as(usize, 1), roomy_position.system);
    try std.testing.expectApproxEqAbs((roomy_geometry.vocal_y[1] + roomy_geometry.bass_y[1] + 49) * 0.5, roomy_center_y, 0.01);

    const narrow_stage = Rect{ .x = 0, .y = 0, .width = 720, .height = 302 };
    const narrow_page = scorePageForBeatLimited(&measures, 10, &.{}, 1, 1);
    var narrow_packet: render.Packet = undefined;
    narrow_packet.reset();
    drawAnnotationsPage(&narrow_packet, narrow_stage, narrow_page, true, &measures, &annotations);
    try std.testing.expectEqual(@as(usize, 1), narrow_packet.len);
    const narrow_geometry = ScoreGeometry.calculateWithVocal(narrow_stage, true);
    const narrow_position = scoreBeatPosition(narrow_geometry, narrow_page, &measures, 10) orelse return error.TestUnexpectedResult;
    const narrow_center_y = narrow_packet.slice()[0].rect[1] + narrow_packet.slice()[0].rect[3] * 0.5;
    try std.testing.expectEqual(@as(usize, 0), narrow_position.system);
    try std.testing.expectApproxEqAbs((narrow_geometry.vocal_y[0] + narrow_geometry.bass_y[0] + 49) * 0.5, narrow_center_y, 0.01);
}

fn drawCoach(packet: *render.Packet, coach: Rect, state: *const model.UiState, practice: *const model.PracticeState) void {
    packet.rect(coach.x, coach.y, coach.width, coach.height, palette.panel);
    packet.rect(coach.x, coach.y, 1, coach.height, palette.border);
    packet.text(coach.x + 24, coach.y + 24, "PRACTICE COACH", 2.0, palette.text);
    packet.text(coach.x + 24, coach.y + 57, "LISTEN WITH", 1.2, palette.muted);
    const source = if (state.input_label_len != 0) state.inputLabel() else switch (state.input_source) {
        .none => "SET UP INPUT",
        .midi => "MIDI INPUT",
        .microphone => "MICROPHONE",
    };
    packet.rounded(coach.x + 20, coach.y + 76, coach.width - 40, 44, 12, palette.panel_raised);
    const source_scale = std.math.clamp((coach.width - 72) / @max(1, render.Packet.textWidth(source, 1)), 0.72, 1.34);
    packet.text(coach.x + 35, coach.y + 88, source, source_scale, if (state.input_source == .none) palette.amber else palette.green);
    if (state.input_source != .none) packet.text(coach.x + 35, coach.y + 106, "CLICK TO CHANGE INPUT", 0.62, palette.muted);

    packet.rounded(coach.x + 20, coach.y + 144, coach.width - 40, 126, 15, .{ 0.085, 0.098, 0.118, 1 });
    packet.text(coach.x + 36, coach.y + 164, "TAKE SUMMARY", 1.35, palette.muted);
    var summary_buffer: [48]u8 = undefined;
    const summary = if (practice.total_notes != 0)
        std.fmt.bufPrint(&summary_buffer, "{d}/{d} NOTES CORRECT", .{ practice.correct_notes, practice.total_notes }) catch "TAKE CAPTURED"
    else if (practice.expected_pedal_changes != 0)
        std.fmt.bufPrint(&summary_buffer, "{d}/{d} PEDAL CHANGES", .{ practice.expected_pedal_changes - practice.missed_pedal_changes, practice.expected_pedal_changes }) catch "PEDAL PASS"
    else
        "PLAY TO GET FEEDBACK";
    packet.text(coach.x + 36, coach.y + 198, summary, 1.5, palette.text);
    const recommendation: []const u8 = if (practice.total_notes == 0)
        if (practice.pedal_errors != 0) "PEDAL CHANGE MISSED OR LATE" else "REPLAY AUDIO + MIDI"
    else if (practice.pedal_errors != 0)
        "CHECK THE PEDAL GUIDE TIMING"
    else if (practice.extra_notes != 0)
        "EXTRA KEYS - RELEASE BETWEEN CHORDS"
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
    packet.text(coach.x + 36, coach.y + 218, recommendation, 0.86, if (practice.total_notes == 0) palette.cyan else palette.amber);
    const replay = Rect{ .x = coach.x + 32, .y = coach.y + 236, .width = (coach.width - 72) * 0.5, .height = 26 };
    const export_take = Rect{ .x = coach.x + 40 + (coach.width - 72) * 0.5, .y = coach.y + 236, .width = (coach.width - 72) * 0.5, .height = 26 };
    packet.rounded(replay.x, replay.y, replay.width, replay.height, 8, if (replay.contains(state.pointer_x, state.pointer_y)) palette.cyan_dim else palette.panel_raised);
    packet.rounded(export_take.x, export_take.y, export_take.width, export_take.height, 8, if (export_take.contains(state.pointer_x, state.pointer_y)) palette.cyan_dim else palette.panel_raised);
    packet.text(replay.x + 13, replay.y + 8, "REPLAY", 0.82, palette.cyan);
    packet.text(export_take.x + 12, export_take.y + 8, "EXPORT MIDI", 0.72, palette.cyan);

    if (state.sampler_status != 0 and coach.height >= 520) {
        const instrument = Rect{ .x = coach.x + 20, .y = coach.y + 286, .width = coach.width - 40, .height = 78 };
        const hovered = instrument.contains(state.pointer_x, state.pointer_y);
        packet.rounded(instrument.x, instrument.y, instrument.width, instrument.height, 13, if (hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(instrument.x + 16, instrument.y + 12, "INSTRUMENT", 0.86, palette.muted);
        const label = if (state.sampler_label_len != 0) state.samplerLabel() else "SFZ SAMPLER";
        const label_scale = std.math.clamp((instrument.width - 32) / @max(1, render.Packet.textWidth(label, 1)), 0.72, 1.08);
        packet.text(instrument.x + 16, instrument.y + 29, label, label_scale, if (state.sampler_status == 1) palette.text else palette.rose);
        var diagnostic_buffer: [48]u8 = undefined;
        const diagnostic = if (state.sampler_status == 1)
            std.fmt.bufPrint(&diagnostic_buffer, "{d} ZONES / {d} SAMPLES  -  LOAD SFZ", .{ state.sampler_region_count, state.sampler_sample_count }) catch "READY  -  LOAD SFZ"
        else
            "SAMPLER UNAVAILABLE  -  LOAD SFZ";
        packet.text(instrument.x + 16, instrument.y + 55, diagnostic, 0.64, if (hovered) palette.cyan else palette.muted);
    }

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

    const titles = [_][]const u8{ "Minuet in G major", "Fur Elise", "Flowing 6/4 Piano Lab", "Holocene" };
    const creators = [_][]const u8{ "J. S. Bach / BWV Anh. 114", "L. van Beethoven / WoO 59", "Original progressive tutorial", "Bon Iver / authorized local study" };
    const badges = [_][]const u8{ "PUBLIC DOMAIN", "OPENSCORE CC0", "BUILT-IN LESSON", "PRIVATE STUDY" };
    for (layout.library_items, 0..) |item, index| {
        const hovered = item.contains(state.pointer_x, state.pointer_y);
        packet.rounded(item.x, item.y, item.width, item.height, 14, if (hovered) palette.cyan_dim else palette.panel_raised);
        packet.text(item.x + 22, item.y + 13, titles[index], 1.48, palette.text);
        packet.text(item.x + 22, item.y + 39, creators[index], 1.0, palette.muted);
        const badge_width = render.Packet.textWidth(badges[index], 0.9) + 18;
        const badge_color: [4]f32 = if (index == 0) .{ 0.28, 0.25, 0.16, 1 } else if (index == 2) .{ 0.20, 0.16, 0.29, 1 } else palette.cyan_dim;
        const badge_text_color = if (index == 0) palette.amber else if (index == 2) palette.rose else palette.cyan;
        packet.rounded(item.x + item.width - badge_width - 18, item.y + (item.height - 25) * 0.5, badge_width, 25, 8, badge_color);
        packet.text(item.x + item.width - badge_width - 9, item.y + (item.height - 25) * 0.5 + 7, badges[index], 0.9, badge_text_color);
    }
    packet.text(modal.x + 30, modal.y + modal.height - 40, "Choose a starter, or use Import Score for your own MusicXML, MXL, MIDI, or .score file.", 0.95, palette.muted);
}

fn drawTransport(packet: *render.Packet, layout: Layout, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, measures: []const model.Measure, time_seconds: f32) void {
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
    if (layout.pedal_guide_toggle.width > 0) {
        packet.rounded(layout.pedal_guide_toggle.x, layout.pedal_guide_toggle.y, layout.pedal_guide_toggle.width, layout.pedal_guide_toggle.height, 12, if (state.pedal_guide_visible != 0) .{ 0.30, 0.23, 0.13, 1 } else palette.panel_raised);
        packet.text(layout.pedal_guide_toggle.x + 7, layout.pedal_guide_toggle.y + 15, "PEDAL", 0.78, if (state.pedal_guide_visible != 0) palette.amber else palette.muted);
    }
    if (layout.view_mode_toggle.width > 0) {
        const label: []const u8 = switch (state.score_view_mode) {
            .paged => "PAGE",
            .continuous => "CONTINUOUS",
        };
        packet.rounded(layout.view_mode_toggle.x, layout.view_mode_toggle.y, layout.view_mode_toggle.width, layout.view_mode_toggle.height, 10, palette.panel_raised);
        packet.text(layout.view_mode_toggle.x + 10, layout.view_mode_toggle.y + 11, label, if (state.score_view_mode == .continuous) 0.70 else 0.88, palette.cyan);
    }
    if (layout.zoom_minus.width > 0) {
        packet.rounded(layout.zoom_minus.x, layout.zoom_minus.y, layout.zoom_minus.width, layout.zoom_minus.height, 10, palette.panel_raised);
        packet.rounded(layout.zoom_plus.x, layout.zoom_plus.y, layout.zoom_plus.width, layout.zoom_plus.height, 10, palette.panel_raised);
        packet.text(layout.zoom_minus.x + 10, layout.zoom_minus.y + 8, "-", 1.25, palette.text);
        packet.text(layout.zoom_plus.x + 9, layout.zoom_plus.y + 8, "+", 1.25, palette.text);
    }
    if (layout.focus_toggle.width > 0) {
        packet.rounded(layout.focus_toggle.x, layout.focus_toggle.y, layout.focus_toggle.width, layout.focus_toggle.height, 10, if (state.focus_score != 0) palette.cyan_dim else palette.panel_raised);
        packet.text(layout.focus_toggle.x + 10, layout.focus_toggle.y + 10, if (state.focus_score != 0) "EXIT FOCUS" else "FOCUS", if (state.focus_score != 0) 0.70 else 0.88, if (state.focus_score != 0) palette.cyan else palette.text);
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
    if (transport.cursor_beat < 0) {
        const beats_left: u32 = @intFromFloat(@ceil(-transport.cursor_beat));
        packet.text(28, layout.transport.y + 23, "COUNT IN", 1.3, palette.amber);
        packet.text(28, layout.transport.y + 44, countInBeatsLabel(&beat_buffer, beats_left), 1.6, palette.text);
    } else {
        const position = model.barBeatAt(measures, transport.cursor_beat, meta);
        packet.text(28, layout.transport.y + 23, std.fmt.bufPrint(&bar_buffer, "BAR {d}", .{position.bar}) catch "BAR", 1.3, palette.muted);
        packet.text(28, layout.transport.y + 44, std.fmt.bufPrint(&beat_buffer, "BEAT {d}", .{position.beat}) catch "BEAT", 1.6, palette.text);
    }
    const tempo_hovered = layout.tempo_value.contains(state.pointer_x, state.pointer_y);
    const tempo_valid = state.tempo_edit_value >= 30 and state.tempo_edit_value <= 240;
    if (state.tempo_editing != 0 or tempo_hovered) {
        packet.rounded(layout.tempo_value.x, layout.tempo_value.y, layout.tempo_value.width, layout.tempo_value.height, 10, if (state.tempo_editing != 0) palette.cyan_dim else palette.panel_raised);
    }
    packet.text(layout.transport.width - 134, layout.transport.y + 24, if (state.tempo_editing != 0) "TYPE PULSE" else "TEMPO", 1.15, if (state.tempo_editing != 0 and !tempo_valid) palette.rose else palette.muted);
    if (state.tempo_editing != 0) {
        packet.text(layout.transport.width - 134, layout.transport.y + 45, std.fmt.bufPrint(&tempo_buffer, "1/{d} = {d}|", .{ meta.tempo_beat_unit, state.tempo_edit_value }) catch "BPM", 1.35, if (tempo_valid) palette.cyan else palette.rose);
    } else {
        packet.text(layout.transport.width - 134, layout.transport.y + 45, std.fmt.bufPrint(&tempo_buffer, "1/{d} = {d:.0} BPM", .{ meta.tempo_beat_unit, transport.tempo_bpm }) catch "BPM", 1.25, if (tempo_hovered) palette.cyan else palette.text);
    }
}

fn countInBeatsLabel(buffer: []u8, beats_left: u32) []const u8 {
    return if (beats_left == 1)
        std.fmt.bufPrint(buffer, "1 BEAT LEFT", .{}) catch "READY"
    else
        std.fmt.bufPrint(buffer, "{d} BEATS LEFT", .{beats_left}) catch "READY";
}

test "count-in label makes remaining beats explicit" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1 BEAT LEFT", countInBeatsLabel(&buffer, 1));
    try std.testing.expectEqualStrings("6 BEATS LEFT", countInBeatsLabel(&buffer, 6));
}

test "controller editor safely formats every persisted color value" {
    var packet: render.Packet = undefined;
    packet.reset();
    var state: model.UiState = .{
        .viewport_width = 1192,
        .viewport_height = 768,
        .app_view = .controller,
        .controller_bank = .user,
        .controller_editing = 1,
    };
    // Preference blobs are validated on load, but the renderer must remain
    // total even if a hot-reloaded/debug state contains a wider byte value.
    // This specifically guards the SWATCH label overflow that used to abort
    // the native Debug app when Edit was clicked.
    state.controller_assignments[0].color = std.math.maxInt(u8);
    drawController(&packet, &state, 0);
    try std.testing.expect(packet.len > 0);
    try std.testing.expect(!packet.clipped);
}

test "engraving honors D-flat spelling and emits analytic beams and ties" {
    const geometry = ScoreGeometry.calculate(.{ .x = 0, .y = 0, .width = 900, .height = 620 });
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 73, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'D', .written_alter = -1, .written_octave = 5, .dots = 1, .flags = model.withDynamic(model.withTupletRatio(model.note_flag_beam_begin | model.note_flag_tie_start | model.note_flag_slur_start | model.note_flag_slur_above | model.note_flag_tuplet_start | model.note_flag_staccato | model.note_flag_accent, 3, 2), model.dynamic_mf) },
        .{ .stable_id = 2, .start_beat = 0.5, .duration_beats = 0.5, .pitch = 73, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'D', .written_alter = -1, .written_octave = 5, .flags = model.withTupletRatio(model.note_flag_beam_end | model.note_flag_tie_stop, 3, 2) },
        .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 74, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'D', .written_alter = 0, .written_octave = 5, .flags = model.withTupletRatio(model.note_flag_slur_stop | model.note_flag_tuplet_stop | model.note_flag_fermata, 3, 2) },
    };
    var meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4, .key_fifths = -5 };
    meta.setTitle("Engraving");
    try std.testing.expect(!shouldDrawAccidental(&notes, 0, &meta));
    try std.testing.expect(shouldDrawAccidental(&notes, 2, &meta));
    const position = notePosition(notes[0], geometry, 0, meta.measureBeats(), meta.systemBeats()) orelse return error.TestUnexpectedResult;
    // D-flat uses the D staff position, not the enharmonic C-sharp position.
    try std.testing.expectEqual(@as(i32, 36), noteDiatonic(notes[0]));
    try std.testing.expect(position.y < geometry.treble_y[0] + 48);

    var packet: render.Packet = undefined;
    packet.reset();
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 700 };
    const transport: model.Transport = .{};
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const annotations: annotation.Store = .{};
    drawScore(&packet, .{ .x = 0, .y = 0, .width = 900, .height = 620 }, &state, &transport, &meta, &notes, &.{}, &.{}, &.{}, &.{}, &measures, &annotations, 0);
    var analytic_lines: usize = 0;
    for (packet.slice()) |item| if (@as(u32, @intFromFloat(item.params[0] + 0.5)) == @intFromEnum(render.Kind.line)) {
        analytic_lines += 1;
    };
    try std.testing.expect(analytic_lines >= 21); // beam, tie, and twelve-segment slur
    try std.testing.expect(packet.len >= 65); // articulation, fermata, tuplet, and mf glyphs are present
    try std.testing.expect(!packet.clipped);
}

test "GPU engraving emits common ornaments and one collision-clear arpeggiation per chord" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'C', .written_octave = 5, .notations = model.note_notation_trill | model.note_notation_turn | model.note_notation_arpeggiate | model.note_notation_arpeggiate_up },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'E', .written_octave = 5 },
    };
    const meta: model.DocumentMeta = .{};
    const position: NotePosition = .{ .x = 120, .y = 76, .system = 0, .bass = false, .vocal = false };
    var packet: render.Packet = undefined;
    packet.reset();
    drawOrnamentsAndArpeggiation(&packet, &notes, 0, notes[0], position, 120, 100, &meta, &.{}, palette.ink);
    try std.testing.expectEqual(@as(usize, 3), packet.len);
    try std.testing.expect(packet.items[2].rect[0] < 100);
    try std.testing.expect(!packet.clipped);
}

test "GPU engraving draws forward and backward repeat dots on both piano staves" {
    var packet: render.Packet = .{};
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 620, .keyboard_visible = 0 };
    const transport: model.Transport = .{};
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 4, .pitch = 60, .velocity = 84, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 4, .pitch = 62, .velocity = 84, .staff = 0, .voice = 0 },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1, .repeat = model.measure_repeat_forward },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2, .repeat = model.measure_repeat_backward },
    };
    const annotations: annotation.Store = .{};
    drawScore(&packet, .{ .x = 0, .y = 0, .width = 900, .height = 620 }, &state, &transport, &meta, &notes, &.{}, &.{}, &.{}, &.{}, &measures, &annotations, 0);
    var repeat_dots: usize = 0;
    for (packet.slice()) |item| {
        if (@as(render.Kind, @enumFromInt(@as(u32, @intFromFloat(item.params[0])))) == .ellipse and
            item.rect[2] > 4.3 and item.rect[2] < 4.5 and item.rect[3] > 4.3 and item.rect[3] < 4.5)
        {
            repeat_dots += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8), repeat_dots);
}

test "dynamic expressions use clear lanes and coalesce duplicate voice marks" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 79, .velocity = 84, .staff = 0, .voice = 0, .flags = model.withDynamic(0, model.dynamic_mf) },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 79, .velocity = 84, .staff = 0, .voice = 1, .flags = model.withDynamic(0, model.dynamic_mf) },
    };
    const note_position = scoreNotePosition(notes[0], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const placement = dynamicPlacement(&notes, 0, note_position.x - 3, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(geometry.treble_y[0] + 70, placement.y, 0.01);
    const bounds = dynamicInkBounds(model.dynamic_mf, placement.x, placement.y);
    try std.testing.expect(bounds.y >= geometry.treble_y[0] + 49);
    try std.testing.expect(bounds.y + bounds.height <= geometry.bass_y[0]);
    try std.testing.expect(dynamicPlacement(&notes, 1, note_position.x - 3, geometry, page, &measures) == null);
}

test "engraving onset lookup isolates one chord in a large ordered snapshot" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 1, .pitch = 62, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 4, .duration_beats = 1, .pitch = 65, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 4, .start_beat = 8, .duration_beats = 1, .pitch = 67, .velocity = 80, .staff = 0, .voice = 0 },
    };
    const range = noteOnsetRange(&notes, 4);
    try std.testing.expectEqual(@as(usize, 1), range.start);
    try std.testing.expectEqual(@as(usize, 3), range.end);
    try std.testing.expectEqual(@as(usize, 2), noteOnsetSlice(&notes, 4).len);
}

test "dynamic expressions escape a conflicting cross-staff stem" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 79, .velocity = 84, .staff = 0, .voice = 0, .flags = model.withDynamic(0, model.dynamic_f) },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 71, .velocity = 84, .staff = 1, .voice = 0 },
    };
    const note_position = scoreNotePosition(notes[0], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const placement = dynamicPlacement(&notes, 0, note_position.x - 3, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    try std.testing.expect(@abs(placement.y - (geometry.treble_y[0] + 70)) > 0.01);
    const bounds = dynamicInkBounds(model.dynamic_f, placement.x, placement.y);
    for (notes) |note| {
        const position = scoreNotePosition(note, geometry, page, &measures) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!bounds.intersects(noteCollisionBounds(&notes, note, position, geometry)));
    }
}

test "simultaneous voices use opposing stems and separated mixed-duration noteheads" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'C', .written_octave = 5 },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 2, .pitch = 72, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'C', .written_octave = 5 },
        .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 74, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'D', .written_octave = 5 },
        .{ .stable_id = 4, .start_beat = 1, .duration_beats = 1, .pitch = 74, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'D', .written_octave = 5 },
    };
    const position = NotePosition{ .x = 100, .y = 100, .system = 0, .bass = false, .vocal = false };
    try std.testing.expect(chordStemUp(&notes, notes[0], 100));
    try std.testing.expect(!chordStemUp(&notes, notes[1], 100));
    try std.testing.expectApproxEqAbs(@as(f32, 14), noteRenderX(&notes, notes[0], position) - noteRenderX(&notes, notes[1], position), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), noteRenderX(&notes, notes[2], position), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), noteRenderX(&notes, notes[3], position), 0.001);

    var packet: render.Packet = .{};
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 700, .vocal_guide_visible = 0 };
    const transport: model.Transport = .{};
    const meta: model.DocumentMeta = .{};
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const annotations: annotation.Store = .{};
    drawScore(&packet, .{ .x = 0, .y = 0, .width = 900, .height = 620 }, &state, &transport, &meta, &notes, &.{}, &.{}, &.{}, &.{}, &measures, &annotations, 0);
    const filled = glyph_atlas.findMusic(0xe0a4) orelse return error.TestUnexpectedResult;
    const half = glyph_atlas.findMusic(0xe0a3) orelse return error.TestUnexpectedResult;
    var filled_x: ?f32 = null;
    var half_x: ?f32 = null;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .glyph) continue;
        if (std.meta.eql(item.uv, filled.uv) and filled_x == null) filled_x = item.rect[0] - filled.plane[0] * 48 + 7.1;
        if (std.meta.eql(item.uv, half.uv) and half_x == null) half_x = item.rect[0] - half.plane[0] * 48 + 7.1;
    }
    try std.testing.expect(filled_x != null and half_x != null);
    try std.testing.expectApproxEqAbs(@as(f32, 14), filled_x.? - half_x.?, 0.01);
    try std.testing.expect(!packet.clipped);
}

test "grace sequence engraves before and independently from principal attack" {
    const notes = [_]model.Note{
        .{ .stable_id = 10, .start_beat = 2, .duration_beats = 0.125, .pitch = 72, .velocity = 72, .staff = 0, .voice = 0, .flags = model.note_flag_grace | model.note_flag_beam_begin, .notations = model.note_notation_grace_slash },
        .{ .stable_id = 11, .start_beat = 2, .duration_beats = 0.125, .pitch = 74, .velocity = 76, .staff = 0, .voice = 0, .flags = model.note_flag_grace | model.note_flag_beam_end },
        .{ .stable_id = 12, .start_beat = 2, .duration_beats = 1, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0 },
    };
    const base = NotePosition{ .x = 220, .y = 160, .system = 0, .bass = false, .vocal = false };
    const first = noteRenderPosition(&notes, notes[0], base);
    const second = noteRenderPosition(&notes, notes[1], base);
    const principal = noteRenderPosition(&notes, notes[2], base);
    try std.testing.expect(first.x < second.x);
    try std.testing.expect(second.x < principal.x);
    try std.testing.expect(!sameNotationLayer(notes[0], notes[2]));
    try std.testing.expect(isChordStemAnchor(&notes, notes[0], true));
    try std.testing.expect(chordHasBeam(&notes, notes[0]));

    var packet: render.Packet = .{};
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 620, .keyboard_visible = 0, .vocal_guide_visible = 0 };
    const transport: model.Transport = .{};
    const meta: model.DocumentMeta = .{};
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const annotations: annotation.Store = .{};
    drawScore(&packet, .{ .x = 0, .y = 0, .width = 900, .height = 620 }, &state, &transport, &meta, &notes, &.{}, &.{}, &.{}, &.{}, &measures, &annotations, 0);
    var slash_lines: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line and @abs(item.rect[2] - item.rect[0]) > 10 and @abs(item.rect[3] - item.rect[1]) > 4) slash_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), slash_lines);

    var beam_packet: render.Packet = .{};
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    drawBeams(&beam_packet, &notes, geometry, page, &measures, &state, &transport);
    var grace_beams: usize = 0;
    var grace_stems: usize = 0;
    for (beam_packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .line) continue;
        if (@abs(item.rect[2] - item.rect[0]) > 8 and item.params[1] > 2) grace_beams += 1;
        if (@abs(item.rect[2] - item.rect[0]) < 0.01 and item.params[1] < 2) grace_stems += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), grace_beams);
    try std.testing.expectEqual(@as(usize, 2), grace_stems);
    try std.testing.expect(!beam_packet.clipped);
}

test "single-note tremolo engraves the authored number of analytic stem strokes" {
    var packet: render.Packet = .{};
    drawSingleNoteTremolo(&packet, 3, 120, 160, true, 1, palette.ink);
    try std.testing.expectEqual(@as(usize, 3), packet.len);
    for (packet.slice(), 0..) |item, index| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        try std.testing.expectEqual(render.Kind.line, kind);
        try std.testing.expectApproxEqAbs(@as(f32, 13), item.rect[2] - item.rect[0], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 2.2), item.params[1], 0.001);
        if (index != 0) try std.testing.expect(item.rect[1] < packet.items[index - 1].rect[1]);
    }

    const chord = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .notations = model.withSingleTremolo(0, 2) },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 80, .staff = 0, .voice = 0 },
    };
    try std.testing.expectEqual(@as(u8, 2), chordSingleTremoloMarks(&chord, chord[1]));
}

test "polyphonic rests and accidental columns remain distinct" {
    const rests = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_rest },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 71, .velocity = 0, .staff = 0, .voice = 1, .flags = model.note_flag_rest },
    };
    const rest_position = NotePosition{ .x = 100, .y = 124, .system = 0, .bass = false, .vocal = false };
    const upper_rest_y = restRenderY(&rests, rests[0], rest_position);
    const lower_rest_y = restRenderY(&rests, rests[1], rest_position);
    try std.testing.expectApproxEqAbs(@as(f32, 48), lower_rest_y - upper_rest_y, 0.001);
    const quarter_rest = glyph_atlas.findMusic(restGlyph(1)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(upper_rest_y + quarter_rest.plane[3] * 48 < lower_rest_y + quarter_rest.plane[1] * 48);

    const accidentals = [_]model.Note{
        .{ .stable_id = 3, .start_beat = 0, .duration_beats = 1, .pitch = 66, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'F', .written_alter = 1, .written_octave = 4 },
        .{ .stable_id = 4, .start_beat = 0, .duration_beats = 1, .pitch = 68, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'G', .written_alter = 1, .written_octave = 4 },
        .{ .stable_id = 5, .start_beat = 0, .duration_beats = 1, .pitch = 70, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'A', .written_alter = 1, .written_octave = 4 },
    };
    const meta: model.DocumentMeta = .{ .key_fifths = 0 };
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    try std.testing.expectEqual(@as(u8, 0), accidentalColumn(&accidentals, 0, &meta, &measures));
    try std.testing.expectEqual(@as(u8, 1), accidentalColumn(&accidentals, 1, &meta, &measures));
    try std.testing.expectEqual(@as(u8, 2), accidentalColumn(&accidentals, 2, &meta, &measures));

    const shared_unison = [_]model.Note{
        .{ .stable_id = 6, .start_beat = 0, .duration_beats = 1, .pitch = 66, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'F', .written_alter = 1, .written_octave = 4, .flags = model.note_flag_explicit_accidental },
        .{ .stable_id = 7, .start_beat = 0, .duration_beats = 1, .pitch = 66, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'F', .written_alter = 1, .written_octave = 4, .flags = model.note_flag_explicit_accidental },
    };
    try std.testing.expect(shouldDrawAccidentalInMeasures(&shared_unison, 0, &meta, &measures));
    try std.testing.expect(!shouldDrawAccidentalInMeasures(&shared_unison, 1, &meta, &measures));
}

test "tuplets include rests and use opposite voice lanes" {
    const ratio_start = model.withTupletRatio(model.note_flag_tuplet_start, 3, 2);
    const ratio_middle = model.withTupletRatio(0, 3, 2);
    const ratio_stop = model.withTupletRatio(model.note_flag_tuplet_stop, 3, 2);
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1.0 / 3.0, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'C', .written_octave = 5, .flags = ratio_start },
        .{ .stable_id = 2, .start_beat = 1.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .flags = ratio_middle | model.note_flag_rest },
        .{ .stable_id = 3, .start_beat = 2.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0, .written_step = 'E', .written_octave = 5, .flags = ratio_stop },
        .{ .stable_id = 4, .start_beat = 0, .duration_beats = 1.0 / 3.0, .pitch = 71, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'B', .written_octave = 4, .flags = ratio_start },
        .{ .stable_id = 5, .start_beat = 1.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 69, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'A', .written_octave = 4, .flags = ratio_middle },
        .{ .stable_id = 6, .start_beat = 2.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 67, .velocity = 84, .staff = 0, .voice = 1, .written_step = 'G', .written_octave = 4, .flags = ratio_stop },
    };
    const group = collectTupletGroup(&notes, notes[0], 3);
    try std.testing.expectEqual(@as(usize, 3), group.count);
    try std.testing.expect((group.members[1].flags & model.note_flag_rest) != 0);
    try std.testing.expect(!group.fully_beamed);

    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    var packet: render.Packet = .{};
    drawTuplets(&packet, &notes, geometry, page, &measures, &.{}, &.{});
    const digit = glyph_atlas.findMusic(0xe083) orelse return error.TestUnexpectedResult;
    var upper_digits: usize = 0;
    var lower_digits: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .glyph or !std.meta.eql(item.uv, digit.uv)) continue;
        const baseline = item.rect[1] - digit.plane[1] * 28;
        if (baseline < geometry.treble_y[0]) upper_digits += 1;
        if (baseline > geometry.treble_y[0] + 48) lower_digits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), upper_digits);
    try std.testing.expectEqual(@as(usize, 1), lower_digits);
    try std.testing.expect(!packet.clipped);
}

test "tuplet brackets continue across responsive systems" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 11.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .flags = model.withTupletRatio(model.note_flag_tuplet_start, 3, 2) },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 1.0 / 3.0, .pitch = 74, .velocity = 84, .staff = 0, .voice = 0, .flags = model.withTupletRatio(0, 3, 2) },
        .{ .stable_id = 3, .start_beat = 13.0 / 3.0, .duration_beats = 1.0 / 3.0, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0, .flags = model.withTupletRatio(model.note_flag_tuplet_stop, 3, 2) },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    var page: ScorePage = .{ .system_count = 2 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    page.systems[1] = .{ .start_beat = 4, .end_beat = 8, .first_measure = 1, .measure_end = 2 };
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 760 }, false, 2);
    var packet: render.Packet = .{};
    drawTuplets(&packet, &notes, geometry, page, &measures, &.{}, &.{});
    const digit = glyph_atlas.findMusic(0xe083) orelse return error.TestUnexpectedResult;
    var digit_count: usize = 0;
    var line_count: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .glyph and std.meta.eql(item.uv, digit.uv)) digit_count += 1;
        if (kind == .line) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), digit_count);
    try std.testing.expectEqual(@as(usize, 8), line_count);
    try std.testing.expect(!packet.clipped);
}

test "mixed beam groups render secondary and tertiary inward hooks" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_begin },
        .{ .stable_id = 2, .start_beat = 0.5, .duration_beats = 0.25, .pitch = 74, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_continue },
        .{ .stable_id = 3, .start_beat = 0.75, .duration_beats = 0.5, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_end },
        .{ .stable_id = 4, .start_beat = 2, .duration_beats = 0.125, .pitch = 76, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_begin },
        .{ .stable_id = 5, .start_beat = 2.125, .duration_beats = 0.25, .pitch = 74, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_continue },
        .{ .stable_id = 6, .start_beat = 2.375, .duration_beats = 0.125, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_end },
    };
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    var packet: render.Packet = .{};
    drawBeams(&packet, &notes, geometry, page, &measures, &.{}, &.{});
    var beam_segments: usize = 0;
    var hooks: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .line or item.params[1] < 3) continue;
        beam_segments += 1;
        if (@abs(item.rect[2] - item.rect[0]) <= 12.01) hooks += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), beam_segments);
    try std.testing.expectEqual(@as(usize, 3), hooks);
    try std.testing.expect(!packet.clipped);
}

test "responsive system breaks preserve readable flagged stems for authored beams" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 3.5, .duration_beats = 0.5, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_begin },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 0.5, .pitch = 74, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_end },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    var page: ScorePage = .{ .system_count = 2 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    page.systems[1] = .{ .start_beat = 4, .end_beat = 8, .first_measure = 1, .measure_end = 2 };
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 760 }, false, 2);
    var packet: render.Packet = .{};
    drawBeams(&packet, &notes, geometry, page, &measures, &.{}, &.{});
    const flag_up = glyph_atlas.findMusic(0xe240) orelse return error.TestUnexpectedResult;
    const flag_down = glyph_atlas.findMusic(0xe241) orelse return error.TestUnexpectedResult;
    var stems: usize = 0;
    var flags: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line) stems += 1;
        if (kind == .glyph and (std.meta.eql(item.uv, flag_up.uv) or std.meta.eql(item.uv, flag_down.uv))) flags += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), stems);
    try std.testing.expectEqual(@as(usize, 2), flags);
    try std.testing.expect(!packet.clipped);
}

test "ties and slurs continue across systems and page turns" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 760 }, false, 2);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 3.5, .duration_beats = 0.5, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_tie_start | model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_tie_stop | model.note_flag_slur_stop },
    };
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 760 };
    const transport: model.Transport = .{};

    var two_system_page: ScorePage = .{ .system_count = 2 };
    two_system_page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    two_system_page.systems[1] = .{ .start_beat = 4, .end_beat = 8, .first_measure = 1, .measure_end = 2 };
    var packet: render.Packet = undefined;
    packet.reset();
    drawTies(&packet, &notes, geometry, two_system_page, &measures, &state, &transport);
    drawSlurs(&packet, &notes, geometry, two_system_page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 48), packet.len);

    var outgoing_page: ScorePage = .{ .system_count = 1 };
    outgoing_page.systems[0] = two_system_page.systems[0];
    packet.reset();
    drawTies(&packet, &notes, geometry, outgoing_page, &measures, &state, &transport);
    drawSlurs(&packet, &notes, geometry, outgoing_page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 24), packet.len);

    var incoming_page: ScorePage = .{ .system_count = 1, .page_index = 1 };
    incoming_page.systems[0] = two_system_page.systems[1];
    packet.reset();
    drawTies(&packet, &notes, geometry, incoming_page, &measures, &state, &transport);
    drawSlurs(&packet, &notes, geometry, incoming_page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 24), packet.len);
}

test "numbered nested slurs pair with their own stops and use semantic lanes" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_start_mask = model.slurNumberBit(1), .flags = model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_start_mask = model.slurNumberBit(2), .flags = model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 3, .start_beat = 2, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_stop_mask = model.slurNumberBit(2), .flags = model.note_flag_slur_stop },
        .{ .stable_id = 4, .start_beat = 3, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_stop_mask = model.slurNumberBit(1), .flags = model.note_flag_slur_stop },
    };
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 620 };
    const transport: model.Transport = .{};
    var nested_spans: [512]SlurSpan = undefined;
    const nested_count = collectVisibleSlurSpans(&notes, page, &nested_spans);
    try std.testing.expectEqual(@as(usize, 2), nested_count);
    try std.testing.expectEqual(@as(usize, 1), slurOpticalLane(&notes, nested_spans[0..nested_count], 0, true, geometry, page, &measures));
    try std.testing.expectEqual(@as(usize, 0), slurOpticalLane(&notes, nested_spans[0..nested_count], 1, true, geometry, page, &measures));
    var packet: render.Packet = undefined;
    packet.reset();
    drawSlurs(&packet, &notes, geometry, page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 24), packet.len);
    const outer_end = scoreNotePosition(notes[3], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const inner_end = scoreNotePosition(notes[2], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(outer_end.x + 4, packet.items[11].rect[2], 0.01);
    try std.testing.expectApproxEqAbs(inner_end.x + 4, packet.items[23].rect[2], 0.01);
    try std.testing.expect(packet.items[0].rect[1] < packet.items[12].rect[1] - 2);

    const crossing = [_]model.Note{
        .{ .stable_id = 11, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_start_mask = model.slurNumberBit(1), .flags = model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 12, .start_beat = 1, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_start_mask = model.slurNumberBit(2), .flags = model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 13, .start_beat = 2, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_stop_mask = model.slurNumberBit(1), .flags = model.note_flag_slur_stop },
        .{ .stable_id = 14, .start_beat = 3, .duration_beats = 1, .pitch = 67, .velocity = 84, .staff = 0, .voice = 0, .slur_stop_mask = model.slurNumberBit(2), .flags = model.note_flag_slur_stop },
    };
    var crossing_spans: [512]SlurSpan = undefined;
    const crossing_count = collectVisibleSlurSpans(&crossing, page, &crossing_spans);
    try std.testing.expectEqual(@as(usize, 2), crossing_count);
    try std.testing.expectEqual(@as(usize, 0), slurOpticalLane(&crossing, crossing_spans[0..crossing_count], 0, true, geometry, page, &measures));
    try std.testing.expectEqual(@as(usize, 1), slurOpticalLane(&crossing, crossing_spans[0..crossing_count], 1, true, geometry, page, &measures));
}

test "phrase slurs clear intermediate chord and stem ink" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 60, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_start | model.note_flag_slur_above },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 0.5, .pitch = 84, .velocity = 84, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 2, .duration_beats = 0.5, .pitch = 60, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_stop },
    };
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 620 };
    const transport: model.Transport = .{};
    var packet: render.Packet = undefined;
    packet.reset();
    drawSlurs(&packet, &notes, geometry, page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 12), packet.len);

    const middle_raw = scoreNotePosition(notes[1], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const middle = noteRenderPosition(&notes, notes[1], middle_raw);
    const bounds = chordVerticalInkBounds(&notes, notes[1], staffYForPosition(geometry, middle));
    // Segment six ends at t=0.5, the exact intermediate onset in this fixture.
    try std.testing.expect(packet.items[5].rect[3] <= bounds.top - 6.5);
}

test "automatic slur placement stays opposite the stem and beam" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 900 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 61, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_start | model.note_flag_beam_begin },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 0.5, .pitch = 85, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_start | model.note_flag_beam_begin },
    };
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const low_raw = scoreNotePosition(notes[0], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const high_raw = scoreNotePosition(notes[1], geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const low = noteRenderPosition(&notes, notes[0], low_raw);
    const high = noteRenderPosition(&notes, notes[1], high_raw);
    try std.testing.expect(!slurAbove(&notes, notes[0], low, geometry));
    try std.testing.expect(slurAbove(&notes, notes[1], high, geometry));
}

test "automatic below slur remains in the grand-staff clearance" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, false, 1);
    const measures = [_]model.Measure{.{ .start_beat = 0, .duration_beats = 4, .number = 1 }};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.5, .pitch = 61, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_start | model.note_flag_beam_begin },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 0.5, .pitch = 72, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_beam_continue },
        .{ .stable_id = 3, .start_beat = 2, .duration_beats = 0.5, .pitch = 68, .velocity = 84, .staff = 0, .voice = 0, .flags = model.note_flag_slur_stop | model.note_flag_beam_end },
    };
    var page: ScorePage = .{ .system_count = 1 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    const state: model.UiState = .{ .viewport_width = 900, .viewport_height = 620 };
    const transport: model.Transport = .{};
    var packet: render.Packet = undefined;
    packet.reset();
    drawSlurs(&packet, &notes, geometry, page, &measures, &state, &transport);
    try std.testing.expectEqual(@as(usize, 12), packet.len);
    var bottom: f32 = -std.math.inf(f32);
    for (packet.slice()) |item| bottom = @max(bottom, @max(item.rect[1], item.rect[3]));
    try std.testing.expect(bottom <= geometry.bass_y[0] - 6);
}

test "vocal guide occupies an independent labeled staff" {
    const geometry = ScoreGeometry.calculateWithVocal(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, true);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeat(&measures, 0, &.{}, 1);
    const piano = model.Note{ .stable_id = 1, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 88, .staff = 0, .voice = 0 };
    const vocal = model.Note{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_vocal_guide };
    const piano_position = scoreNotePosition(piano, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const vocal_position = scoreNotePosition(vocal, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!piano_position.vocal);
    try std.testing.expect(vocal_position.vocal);
    try std.testing.expect(vocal_position.y < piano_position.y - 40);
    // Lyrics have a stable lane below the complete vocal staff and above the
    // full reach of an upward piano beam.
    try std.testing.expect(geometry.lyric_y[0] >= geometry.vocal_y[0] + 68);
    try std.testing.expect(geometry.lyric_y[0] + 12 <= geometry.treble_y[0] - 29);
    try std.testing.expect(geometry.vocal_y[0] >= geometry.page_y + 88);
    try std.testing.expect(!hasVocalGuide(&.{piano}));
    try std.testing.expect(hasVocalGuide(&.{ piano, vocal }));
}

test "hairpins retain their optical opening across responsive systems" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 760 }, false, 2);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    var page: ScorePage = .{ .system_count = 2 };
    page.systems[0] = .{ .start_beat = 0, .end_beat = 4, .first_measure = 0, .measure_end = 1 };
    page.systems[1] = .{ .start_beat = 4, .end_beat = 8, .first_measure = 1, .measure_end = 2 };
    const hairpins = [_]model.Hairpin{.{
        .start_beat = 1,
        .end_beat = 7,
        .spread = 16,
        .staff = 0,
        .kind = model.hairpin_crescendo,
        .number = 1,
        .flags = model.hairpin_flag_niente,
    }};
    var packet: render.Packet = .{};
    drawHairpins(&packet, &hairpins, geometry, page, &measures, &.{});
    var line_starts: [4]f32 = undefined;
    var line_count: usize = 0;
    var ellipse_count: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line) {
            try std.testing.expect(line_count < line_starts.len);
            line_starts[line_count] = item.rect[1];
            line_count += 1;
        } else if (kind == .ellipse) {
            ellipse_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), line_count);
    try std.testing.expectApproxEqAbs(line_starts[0], line_starts[1], 0.001);
    try std.testing.expect(@abs(line_starts[2] - line_starts[3]) > 3);
    try std.testing.expectEqual(@as(usize, 2), ellipse_count);
    try std.testing.expect(!packet.clipped);
}

test "overlapping hairpins use independent optical lanes per staff and side" {
    const hairpins = [_]model.Hairpin{
        .{ .start_beat = 0, .end_beat = 4, .staff = 0, .kind = model.hairpin_crescendo, .number = 1 },
        .{ .start_beat = 1, .end_beat = 3, .staff = 0, .kind = model.hairpin_diminuendo, .number = 2 },
        .{ .start_beat = 4, .end_beat = 6, .staff = 0, .kind = model.hairpin_crescendo, .number = 3 },
        .{ .start_beat = 1, .end_beat = 3, .staff = 0, .kind = model.hairpin_crescendo, .number = 4, .flags = model.hairpin_flag_above },
        .{ .start_beat = 1, .end_beat = 3, .staff = 1, .kind = model.hairpin_crescendo, .number = 5 },
        .{ .start_beat = 1, .end_beat = 3, .staff = 0, .kind = model.hairpin_crescendo, .number = 6, .flags = model.hairpin_flag_vocal },
    };
    const state: model.UiState = .{ .vocal_guide_visible = 1 };
    var lanes: [hairpins.len]u8 = undefined;
    resolveHairpinOpticalLanes(&hairpins, &state, &lanes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0, 0, 0 }, &lanes);

    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 900, .height = 760 }, true, 1);
    try std.testing.expectApproxEqAbs(hairpin_lane_spacing, hairpinLaneY(hairpins[1], geometry, 0, 1) - hairpinLaneY(hairpins[1], geometry, 0, 0), 0.001);
    try std.testing.expectApproxEqAbs(-hairpin_lane_spacing, hairpinLaneY(hairpins[3], geometry, 0, 1) - hairpinLaneY(hairpins[3], geometry, 0, 0), 0.001);
}

test "score pedal guide tracks expected controller state and emits analytic marks" {
    const events = [_]model.PedalEvent{
        .{ .start_beat = 1, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start, .flags = model.pedal_flag_line },
        .{ .start_beat = 3, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop, .flags = model.pedal_flag_line },
    };
    try std.testing.expectEqual(@as(u8, 0), expectedPedalValue(&events, model.pedal_sustain, 0.5));
    try std.testing.expectEqual(@as(u8, 127), expectedPedalValue(&events, model.pedal_sustain, 2));
    try std.testing.expectEqual(@as(u8, 0), expectedPedalValue(&events, model.pedal_sustain, 4));
    try std.testing.expectEqual(model.pedal_action_stop, (nextPedalEvent(&events, model.pedal_sustain, 2) orelse return error.TestUnexpectedResult).action);
    const all_pedals = [_]model.PedalEvent{
        .{ .start_beat = 2, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start },
        .{ .start_beat = 1, .pedal = model.pedal_soft, .value = 127, .action = model.pedal_action_start },
        .{ .start_beat = 3, .pedal = model.pedal_sostenuto, .value = 127, .action = model.pedal_action_start },
    };
    const earliest = nextPedalEventAny(&all_pedals, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(model.pedal_soft, earliest.pedal);
    try std.testing.expectEqualStrings("SOFT", pedalShortLabel(earliest.pedal));
    try std.testing.expect(!pedalGapNeedsReview(&events, model.pedal_sustain, 2, 16));
    const long_hold = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 72, .action = model.pedal_action_start },
        .{ .start_beat = 32, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop },
    };
    try std.testing.expect(pedalGapNeedsReview(&long_hold, model.pedal_sustain, 1, 16));
    try std.testing.expect(!pedalGapNeedsReview(&long_hold, model.pedal_sustain, 33, 16));
    var packet: render.Packet = undefined;
    packet.reset();
    const geometry = ScoreGeometry.calculate(.{ .x = 0, .y = 0, .width = 900, .height = 620 });
    const transport: model.Transport = .{ .cursor_beat = 1 };
    const opening_events = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start, .flags = model.pedal_flag_line },
        .{ .start_beat = 3, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop, .flags = model.pedal_flag_line },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeat(&measures, 0, &.{}, 1);
    drawPedalNotation(&packet, &opening_events, &.{}, geometry, page, &measures, &transport, &.{});
    var line_count: usize = 0;
    for (packet.slice()) |item| if (@as(u32, @intFromFloat(item.params[0] + 0.5)) == @intFromEnum(render.Kind.line)) {
        line_count += 1;
        try std.testing.expect(item.rect[2] >= item.rect[0]);
    };
    try std.testing.expect(line_count >= 3);
    try std.testing.expect(!packet.clipped);
}

test "three-pedal notation draws continuous pressure curves and measure heatmaps" {
    var packet: render.Packet = .{};
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 1100, .height = 720 }, false, 1);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeatLimited(&measures, 0, &.{}, 1, 1);
    const events = [_]model.PedalEvent{
        .{ .start_beat = 0.25, .pedal = model.pedal_sustain, .value = 72, .action = model.pedal_action_start, .flags = model.pedal_flag_line },
        .{ .start_beat = 2, .pedal = model.pedal_sustain, .value = 32, .action = model.pedal_action_change, .flags = model.pedal_flag_line },
        .{ .start_beat = 3.75, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop, .flags = model.pedal_flag_line },
        .{ .start_beat = 0.5, .pedal = model.pedal_soft, .value = 64, .action = model.pedal_action_start },
        .{ .start_beat = 1.5, .pedal = model.pedal_soft, .value = 100, .action = model.pedal_action_change },
        .{ .start_beat = 3.5, .pedal = model.pedal_soft, .value = 0, .action = model.pedal_action_stop },
        .{ .start_beat = 1, .pedal = model.pedal_sostenuto, .value = 127, .action = model.pedal_action_start, .flags = model.pedal_flag_line },
        .{ .start_beat = 3, .pedal = model.pedal_sostenuto, .value = 0, .action = model.pedal_action_stop, .flags = model.pedal_flag_line },
    };
    try std.testing.expect(pedalCurveRequired(&events, model.pedal_soft, 0, 8));
    try std.testing.expect(pedalCurveRequired(&events, model.pedal_sostenuto, 0, 8));
    try std.testing.expect(pedalCurveRequired(&events, model.pedal_sustain, 0, 8));
    const binary_sustain = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 127, .action = model.pedal_action_start },
        .{ .start_beat = 2, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop },
    };
    try std.testing.expect(!pedalCurveRequired(&binary_sustain, model.pedal_sustain, 0, 4));

    drawPedalNotation(&packet, &events, &.{}, geometry, page, &measures, &.{ .cursor_beat = 2 }, &.{});
    var heatmaps: usize = 0;
    var curves: usize = 0;
    var points: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        switch (kind) {
            .rect => if (item.color[3] < 0.2 and item.rect[3] >= 9) {
                heatmaps += 1;
            },
            .line => curves += 1,
            .ellipse => if (item.rect[2] < 6) {
                points += 1;
            },
            else => {},
        }
    }
    try std.testing.expect(heatmaps >= 3);
    try std.testing.expect(curves >= 18);
    try std.testing.expectEqual(events.len, points);
    try std.testing.expect(!packet.clipped);
}

test "edit pedal lanes hit existing points and empty continuous ranges" {
    const geometry = ScoreGeometry.calculateForSystems(.{ .x = 0, .y = 0, .width = 1100, .height = 720 }, false, 1);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeatLimited(&measures, 0, &.{}, 1, 1);
    const events = [_]model.PedalEvent{
        .{ .start_beat = 2, .pedal = model.pedal_soft, .value = 64, .action = model.pedal_action_start },
    };

    const soft_layout = pedalCurveEditPosition(&events, &.{}, geometry, page, &measures, 0, model.pedal_soft, geometry.music_x, 0, true) orelse return error.TestUnexpectedResult;
    const soft_x = (scoreBeatPosition(geometry, page, &measures, 2) orelse return error.TestUnexpectedResult).x;
    const soft_y = pedalCurveY(soft_layout.baseline, 64);
    const existing = pedalCurveHitAt(&events, &.{}, geometry, page, &measures, soft_x, soft_y, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(model.pedal_soft, existing.pedal);
    try std.testing.expectEqual(@as(?usize, 0), existing.event_index);
    try std.testing.expectEqual(@as(u8, 64), existing.value);

    const sost_layout = pedalCurveEditPosition(&events, &.{}, geometry, page, &measures, 0, model.pedal_sostenuto, geometry.music_x, 0, true) orelse return error.TestUnexpectedResult;
    const sost_x = (scoreBeatPosition(geometry, page, &measures, 3) orelse return error.TestUnexpectedResult).x;
    // Empty ranges begin on their labeled zero-pressure guide. Once created,
    // the point itself is the unambiguous target and can be dragged through
    // the full 0...127 envelope even on a compact multi-system page.
    const empty = pedalCurveHitAt(&events, &.{}, geometry, page, &measures, sost_x, sost_layout.baseline, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(model.pedal_sostenuto, empty.pedal);
    try std.testing.expectEqual(@as(?usize, null), empty.event_index);
    try std.testing.expectApproxEqAbs(@as(f32, 3), empty.beat, 0.01);
    try std.testing.expectEqual(@as(u8, 0), empty.value);
    try std.testing.expect(pedalCurveEditPosition(&events, &.{}, geometry, page, &measures, 0, model.pedal_sustain, geometry.music_x, 0, true) != null);

    var packet: render.Packet = .{};
    const edit_state = model.UiState{ .tool = .edit };
    drawPedalNotation(&packet, &events, &.{}, geometry, page, &measures, &.{}, &edit_state);
    var horizontal_guides: usize = 0;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind == .line and @abs(item.rect[1] - item.rect[3]) < 0.01 and item.rect[2] - item.rect[0] > geometry.music_width * 0.9) horizontal_guides += 1;
    }
    // The authored soft point splits its lane into two segments; the two empty
    // lanes remain full-width editor guides.
    try std.testing.expect(horizontal_guides >= 2);
}

test "pedal notation stays clear of the next vocal coaching staff" {
    var packet: render.Packet = .{};
    const stage = Rect{ .x = 0, .y = 0, .width = 1200, .height = 760 };
    const geometry = ScoreGeometry.calculateForSystems(stage, true, 2);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeatLimited(&measures, 0, &.{}, 1, 2);
    const events = [_]model.PedalEvent{
        .{ .start_beat = 0, .pedal = model.pedal_sustain, .value = 96, .action = model.pedal_action_start, .flags = model.pedal_flag_line },
        .{ .start_beat = 3, .pedal = model.pedal_sustain, .value = 0, .action = model.pedal_action_stop, .flags = model.pedal_flag_line },
    };
    drawPedalNotation(&packet, &events, &.{}, geometry, page, &measures, &.{}, &.{});
    var saw_line = false;
    for (packet.slice()) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .line) continue;
        saw_line = true;
        try std.testing.expect(@max(item.rect[1], item.rect[3]) <= geometry.vocal_y[1] - 17.9);
    }
    try std.testing.expect(saw_line);
}

test "virtual piano fingering uses the surrounding phrase and excludes vocal cues" {
    const right_notes = [_]model.Note{
        .{ .stable_id = 90, .start_beat = 0, .duration_beats = 1, .pitch = 84, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_vocal_guide },
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 62, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 2, .duration_beats = 1, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 4, .start_beat = 3, .duration_beats = 1, .pitch = 65, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 5, .start_beat = 4, .duration_beats = 1, .pitch = 67, .velocity = 90, .staff = 0, .voice = 0 },
    };
    const right_targets = findHandTargets(&right_notes, 0, false);
    try std.testing.expectEqual(@as(?u8, 60), right_targets.active);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &phraseFingerPair(&right_notes, 0, right_targets, false));
    try std.testing.expectEqual(@as(usize, 5), handPhrase(&right_notes, 0, false, right_targets).len);

    const left_notes = [_]model.Note{
        .{ .stable_id = 6, .start_beat = 0, .duration_beats = 1, .pitch = 48, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 7, .start_beat = 1, .duration_beats = 1, .pitch = 50, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 8, .start_beat = 2, .duration_beats = 1, .pitch = 52, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 9, .start_beat = 3, .duration_beats = 1, .pitch = 53, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 10, .start_beat = 4, .duration_beats = 1, .pitch = 55, .velocity = 90, .staff = 1, .voice = 0 },
    };
    const left_targets = findHandTargets(&left_notes, 0, true);
    try std.testing.expectEqualSlices(u8, &.{ 5, 4 }, &phraseFingerPair(&left_notes, 0, left_targets, true));
}

test "authored MusicXML fingering overrides phrase and chord suggestions" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 90, .staff = 0, .voice = 0, .fingering = 2 },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0, .fingering = 4 },
        .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 62, .velocity = 90, .staff = 0, .voice = 0, .fingering = 3 },
    };
    const guide = fingeringSnapshot(&notes, 0);
    try std.testing.expectEqual(@as(u8, 2), guide.right_current_finger);
    try std.testing.expectEqual(@as(u8, 3), guide.right_next_finger);
    const chords = chordFingeringSnapshot(&notes, 0);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, chords.right_current.fingers[0..2]);
}

test "virtual piano assigns every tone of simultaneous hand chords" {
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 48, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 52, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 0, .duration_beats = 1, .pitch = 55, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 4, .start_beat = 1, .duration_beats = 1, .pitch = 50, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 5, .start_beat = 1, .duration_beats = 1, .pitch = 53, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 6, .start_beat = 1, .duration_beats = 1, .pitch = 57, .velocity = 90, .staff = 1, .voice = 0 },
        .{ .stable_id = 7, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 8, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 9, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 10, .start_beat = 1, .duration_beats = 1, .pitch = 62, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 11, .start_beat = 1, .duration_beats = 1, .pitch = 65, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 12, .start_beat = 1, .duration_beats = 1, .pitch = 69, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 99, .start_beat = 0, .duration_beats = 1, .pitch = 84, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_vocal_guide },
    };
    const guide = chordFingeringSnapshot(&notes, 0);
    try std.testing.expectEqual(@as(u8, 3), guide.left_current.len);
    try std.testing.expectEqualSlices(u8, &.{ 48, 52, 55 }, guide.left_current.pitches[0..guide.left_current.len]);
    try std.testing.expectEqualSlices(u8, &.{ 5, 3, 1 }, guide.left_current.fingers[0..guide.left_current.len]);
    try std.testing.expectEqual(@as(u8, 3), guide.right_current.len);
    try std.testing.expectEqualSlices(u8, &.{ 60, 64, 67 }, guide.right_current.pitches[0..guide.right_current.len]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 5 }, guide.right_current.fingers[0..guide.right_current.len]);
    try std.testing.expectEqual(@as(u8, 3), guide.left_next.len);
    try std.testing.expectEqual(@as(u8, 3), guide.right_next.len);
}

test "unplayable six-tone single-hand chord is explicit" {
    var notes: [6]model.Note = undefined;
    for (&notes, 0..) |*note, index| note.* = .{
        .stable_id = index + 1,
        .start_beat = 0,
        .duration_beats = 1,
        .pitch = @intCast(60 + index),
        .velocity = 90,
        .staff = 0,
        .voice = 0,
    };
    const chord = chordAt(&notes, 0, false, 60, 1);
    try std.testing.expectEqual(@as(u8, 5), chord.len);
    try std.testing.expectEqual(@as(u8, 1), chord.overflow);
}

test "alternate endings engrave a numbered GPU bracket" {
    var packet: render.Packet = .{};
    const stage: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 700 };
    const geometry = ScoreGeometry.calculateForSystems(stage, false, 1);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1, .ending_mask = 1, .ending_flags = model.measure_ending_start },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2, .ending_mask = 1, .ending_flags = model.measure_ending_stop },
    };
    const system: ScoreSystem = .{ .start_beat = 0, .end_beat = 8, .first_measure = 0, .measure_end = 2 };
    drawVoltaEndingsForSystem(&packet, geometry, system, 0, &measures, false);
    try std.testing.expect(packet.len >= 4);
    var found_horizontal = false;
    var found_left_hook = false;
    var found_right_hook = false;
    for (packet.items[0..packet.len]) |item| {
        const kind: render.Kind = @enumFromInt(@as(u32, @intFromFloat(item.params[0] + 0.5)));
        if (kind != .rect) continue;
        found_horizontal = found_horizontal or item.rect[2] > geometry.music_width * 0.9 and item.rect[3] < 2;
        found_left_hook = found_left_hook or @abs(item.rect[0] - geometry.music_x) < 0.01 and item.rect[3] > 10;
        found_right_hook = found_right_hook or @abs(item.rect[0] + item.rect[2] - (geometry.music_x + geometry.music_width)) < 0.01 and item.rect[3] > 10;
    }
    try std.testing.expect(found_horizontal);
    try std.testing.expect(found_left_hook);
    try std.testing.expect(found_right_hook);
}
