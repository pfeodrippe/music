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
    pedal_guide_toggle: Rect,
    tempo_minus: Rect,
    tempo_plus: Rect,
    tempo_value: Rect,
    import_score: Rect,
    export_score: Rect,
    input_quick: Rect,
    input_setup: Rect,
    replay_take: Rect,
    export_take: Rect,
    page_previous: Rect,
    page_next: Rect,
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
            .tempo_value = .{ .x = width - 148, .y = transport.y + 14, .width = 132, .height = 49 },
            .import_score = .{ .x = import_x, .y = 15, .width = import_width, .height = 40 },
            .export_score = .{ .x = export_x, .y = 15, .width = export_width, .height = 40 },
            .input_quick = .{ .x = export_x - input_width - button_gap, .y = 15, .width = input_width, .height = 40 },
            .input_setup = if (coach_width > 0) .{ .x = width - coach_width + 20, .y = top_height + 76, .width = coach_width - 40, .height = 44 } else .{ .x = 0, .y = 0, .width = 0, .height = 0 },
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
    vocal_y: [2]f32,
    treble_y: [2]f32,
    bass_y: [2]f32,

    pub fn calculate(stage: Rect) ScoreGeometry {
        return calculateWithVocal(stage, false);
    }

    pub fn calculateWithVocal(stage: Rect, vocal_visible: bool) ScoreGeometry {
        const margin: f32 = if (stage.width < 700) 20 else 46;
        const page_width = @max(280, stage.width - margin * 2);
        const page_height = @max(280, stage.height - 34);
        const page_x = stage.x + (stage.width - page_width) * 0.5;
        const page_y = stage.y + 18;
        const page_padding: f32 = if (page_width < 500) 24 else 48;
        const staff_x = page_x + page_padding;
        const staff_width = page_width - page_padding * 2;
        // Reserve enough room for clef, a complete seven-accidental key
        // signature, and meter. This stays fixed across imports so pointer
        // hit-testing and GPU engraving use the same music origin.
        const notation_lead: f32 = if (page_width < 500) 110 else 126;
        const music_x = staff_x + notation_lead;
        const music_width = staff_width - notation_lead;
        const first_treble = page_y + @as(f32, if (page_height < 360) 96 else 112);
        const system_gap = std.math.clamp(page_height - 340, 126, 200);
        const compact_vocal = page_height < 480;
        const first_vocal = page_y + @as(f32, if (compact_vocal) 76 else 84);
        const vocal_to_treble: f32 = if (compact_vocal) 68 else 82;
        const treble_to_bass: f32 = if (compact_vocal) 56 else 62;
        const vocal_group_height = vocal_to_treble + treble_to_bass + 48;
        const vocal_system_gap = @min(
            @as(f32, if (compact_vocal) 210 else 230),
            @max(vocal_group_height + 4, page_height - (first_vocal - page_y) - vocal_group_height - @as(f32, if (compact_vocal) 24 else 32)),
        );
        const resolved_treble = if (vocal_visible) first_vocal + vocal_to_treble else first_treble;
        const resolved_bass = if (vocal_visible) resolved_treble + treble_to_bass else first_treble + 68;
        const resolved_gap = if (vocal_visible) vocal_system_gap else system_gap;
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
            .vocal_y = if (vocal_visible) .{ first_vocal, first_vocal + vocal_system_gap } else .{ first_treble, first_treble + system_gap },
            .treble_y = .{ resolved_treble, resolved_treble + resolved_gap },
            .bass_y = .{ resolved_bass, resolved_bass + resolved_gap },
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

pub const ScorePage = struct {
    systems: [2]ScoreSystem,
    system_count: usize = 2,
    page_index: u32 = 0,

    pub fn startBeat(self: ScorePage) f32 {
        return self.systems[0].start_beat;
    }

    pub fn endBeat(self: ScorePage) f32 {
        return self.systems[@max(1, self.system_count) - 1].end_beat;
    }
};

pub const ScoreBeatPosition = struct { x: f32, system: usize };

fn nextScoreSystem(measures: []const model.Measure, first_measure: usize) ScoreSystem {
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
        if (measure_end > first_measure and candidate_end - start > 9.0001) break;
        end = @max(end, candidate_end);
        measure_end += 1;
    }
    return .{ .start_beat = start, .end_beat = end, .first_measure = first_measure, .measure_end = measure_end };
}

pub fn scorePageForBeat(measures: []const model.Measure, requested_beat: f32, meta: *const model.DocumentMeta) ScorePage {
    if (measures.len == 0) {
        const page_start = meta.pageStart(requested_beat);
        const system_beats = meta.systemBeats();
        return .{ .systems = .{
            .{ .start_beat = page_start, .end_beat = page_start + system_beats },
            .{ .start_beat = page_start + system_beats, .end_beat = page_start + system_beats * 2 },
        }, .page_index = @intFromFloat(@floor(page_start / meta.pageBeats())) };
    }

    const target = @max(measures[0].start_beat, requested_beat);
    var first_measure: usize = 0;
    var page_index: u32 = 0;
    while (true) : (page_index += 1) {
        const first = nextScoreSystem(measures, first_measure);
        const second = nextScoreSystem(measures, first.measure_end);
        const page = ScorePage{
            .systems = .{ first, second },
            .system_count = if (second.measure_end > second.first_measure) 2 else 1,
            .page_index = page_index,
        };
        if (target < page.endBeat() - 0.0001 or second.measure_end >= measures.len) return page;
        first_measure = second.measure_end;
    }
}

pub fn scorePageCount(measures: []const model.Measure, meta: *const model.DocumentMeta) u32 {
    if (measures.len == 0) return 1;
    var page_count: u32 = 0;
    var first_measure: usize = 0;
    while (first_measure < measures.len) {
        const first = nextScoreSystem(measures, first_measure);
        const second = nextScoreSystem(measures, first.measure_end);
        first_measure = second.measure_end;
        page_count += 1;
    }
    _ = meta;
    return @max(1, page_count);
}

fn measureBoundaryX(geometry: ScoreGeometry, system: ScoreSystem, beat: f32) f32 {
    return geometry.music_x + std.math.clamp((beat - system.start_beat) / system.duration(), 0, 1) * geometry.music_width;
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
            const padding = @min(14, (right - left) * 0.12);
            const local = std.math.clamp((absolute_beat - measure.start_beat) / @max(0.0001, measure.duration_beats), 0, 1);
            return .{ .x = left + padding + local * @max(1, right - left - padding * 2), .system = system_index };
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
        const padding = @min(14, (right - left) * 0.12);
        const usable = @max(1, right - left - padding * 2);
        const local = std.math.clamp((x - left - padding) / usable, 0, 1);
        return std.math.clamp(measure.start_beat + local * measure_duration, measure.start_beat, measure_end - 0.0001);
    }
    return system.end_beat - 0.0001;
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
    return ((a.flags ^ b.flags) & model.note_flag_vocal_guide) == 0;
}

fn chordStemUp(notes: []const model.Note, note: model.Note, staff_y: f32) bool {
    var y_sum: f32 = 0;
    var count: u32 = 0;
    for (notes) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const bass = (candidate.staff & 1) != 0 or (candidate.staff == 0 and candidate.pitch < 58);
        const base_diatonic: i32 = if (bass) 18 else 30;
        y_sum += staff_y + 48 - @as(f32, @floatFromInt(noteDiatonic(candidate) - base_diatonic)) * 6;
        count += 1;
    }
    return count == 0 or y_sum / @as(f32, @floatFromInt(count)) >= staff_y + 24;
}

fn chordNoteOffset(notes: []const model.Note, note: model.Note, stem_up: bool) f32 {
    const diatonic = noteDiatonic(note);
    for (notes) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const delta = noteDiatonic(candidate) - diatonic;
        if (stem_up and delta == -1) return 10;
        if (!stem_up and delta == 1) return -10;
    }
    return 0;
}

fn isChordStemAnchor(notes: []const model.Note, note: model.Note, stem_up: bool) bool {
    const diatonic = noteDiatonic(note);
    for (notes) |candidate| {
        if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.start_beat != note.start_beat or candidate.staff != note.staff or candidate.voice != note.voice) continue;
        const candidate_diatonic = noteDiatonic(candidate);
        if (stem_up and candidate_diatonic > diatonic) return false;
        if (!stem_up and candidate_diatonic < diatonic) return false;
    }
    return true;
}

fn chordHasBeam(notes: []const model.Note, note: model.Note) bool {
    for (notes) |candidate| {
        if (sameNotationLayer(candidate, note) and candidate.start_beat == note.start_beat and candidate.staff == note.staff and candidate.voice == note.voice and (candidate.flags & model.note_flag_beam_mask) != 0) return true;
    }
    return false;
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
    for (notes[0..note_index]) |earlier| {
        if ((earlier.flags & model.note_flag_rest) != 0) continue;
        if (!sameNotationLayer(earlier, note) or earlier.staff != note.staff or earlier.start_beat < measure_start or earlier.start_beat >= note.start_beat) continue;
        const earlier_spelling = noteSpelling(earlier);
        if (earlier_spelling.step == spelling.step and earlier_spelling.octave == spelling.octave) expected = earlier_spelling.alter;
    }
    if ((note.flags & model.note_flag_explicit_accidental) != 0) return true;
    if (spelling.alter == expected) return false;
    // One accidental applies to every matching unison in the chord.
    for (notes[0..note_index]) |earlier| {
        if ((earlier.flags & model.note_flag_rest) != 0) continue;
        if (!sameNotationLayer(earlier, note) or earlier.staff != note.staff or earlier.start_beat != note.start_beat) continue;
        const earlier_spelling = noteSpelling(earlier);
        if (earlier_spelling.step == spelling.step and earlier_spelling.octave == spelling.octave and earlier_spelling.alter == spelling.alter) return false;
    }
    return true;
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

test "score pages preserve authored variable-meter systems and positions" {
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 136, .beats = 4, .beat_unit = 4 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 137, .beats = 4, .beat_unit = 4 },
        .{ .start_beat = 8, .duration_beats = 2, .number = 138, .beats = 2, .beat_unit = 4 },
        .{ .start_beat = 10, .duration_beats = 4, .number = 139, .beats = 4, .beat_unit = 4 },
    };
    const meta: model.DocumentMeta = .{};
    const page = scorePageForBeat(&measures, 8, &meta);
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
    try std.testing.expectApproxEqAbs(geometry.music_x + geometry.music_width / 3, measureBoundaryX(geometry, page.systems[1], 10), 0.01);

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
    const page = scorePageForBeat(&measures, 16, &.{});
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
    try std.testing.expectEqual(@as(u32, 3), scorePageCount(&measures, &.{}));
    const layout = Layout.calculate(1280, 800, true);
    try std.testing.expect(layout.page_previous.width >= 34);
    try std.testing.expect(layout.page_next.x > layout.page_previous.x);
    try std.testing.expect(layout.stage.contains(layout.page_previous.x + 1, layout.page_previous.y + 1));
    try std.testing.expect(layout.stage.contains(layout.page_next.x + 1, layout.page_next.y + 1));
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
    pedals: []const model.PedalEvent,
    measures: []const model.Measure,
    annotations: *const annotation.Store,
    time_seconds: f32,
) void {
    packet.reset();
    const layout = Layout.calculate(state.viewport_width, state.viewport_height, state.keyboard_visible != 0);

    packet.rect(0, 0, state.viewport_width, state.viewport_height, palette.background);
    drawTopBar(packet, layout, state, meta);
    if (layout.tools.width > 0 or layout.tools.height > 0) drawTools(packet, layout, state.tool);
    drawScore(packet, layout.stage, state, transport, meta, notes, lyrics, harmonies, pedals, measures, time_seconds);
    drawAnnotations(packet, layout.stage, state, meta, measures, annotations);
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
            else => "SCORE IS READY",
        };
        packet.text(x + 18, 101, message, 1.75, if (state.notice == 3 or state.notice == 5 or state.notice == 9) palette.rose else palette.text);
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

pub fn hasVocalGuide(notes: []const model.Note) bool {
    for (notes) |note| {
        if ((note.flags & model.note_flag_vocal_guide) != 0) return true;
    }
    return false;
}

/// Pure, hot-swappable screen composition: persistent Metal resources remain
/// in the native host while this function rebuilds the frame packet.
fn drawScore(packet: *render.Packet, stage: Rect, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta, notes: []const model.Note, lyrics: []const model.Lyric, harmonies: []const model.Harmony, pedals: []const model.PedalEvent, measures: []const model.Measure, time_seconds: f32) void {
    packet.rect(stage.x, stage.y, stage.width, stage.height, .{ 0.045, 0.052, 0.064, 1 });
    const vocal_visible = state.vocal_guide_visible != 0 and hasVocalGuide(notes);
    var geometry = ScoreGeometry.calculateWithVocal(stage, vocal_visible);
    const page = scorePageForBeat(measures, state.view_start_beat, meta);
    geometry.beat_width = geometry.music_width / page.systems[0].duration();
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
    const page_number = page.page_index + 1;
    const page_count = scorePageCount(measures, meta);
    packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - 88, geometry.page_y + 38, std.fmt.bufPrint(&page_buffer, "PAGE {d} / {d}", .{ page_number, page_count }) catch "PAGE", 0.95, .{ 0.35, 0.36, 0.36, 1 });
    if (geometry.page_width >= 620) packet.text(geometry.page_x + geometry.page_width - geometry.page_padding - 124, geometry.page_y + 57, "SCROLL  /  LEFT-RIGHT", 0.62, .{ 0.46, 0.47, 0.48, 1 });

    for (0..page.system_count) |system| {
        const score_system = page.systems[system];
        if (vocal_visible) {
            for (0..5) |line| packet.rect(geometry.staff_x, geometry.vocal_y[system] + @as(f32, @floatFromInt(line)) * 12, geometry.staff_width, 0.85, palette.ink);
            packet.text(geometry.staff_x - 40, geometry.vocal_y[system] + 20, "VOICE", 0.58, .{ 0.40, 0.27, 0.31, 1 });
        }
        const staves = [_]f32{ geometry.treble_y[system], geometry.bass_y[system] };
        for (staves) |staff_y| for (0..5) |line| packet.rect(geometry.staff_x, staff_y + @as(f32, @floatFromInt(line)) * 12, geometry.staff_width, 0.85, palette.ink);
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
            const measure_end = measure.start_beat + @max(0.0001, measure.duration_beats);
            const bx = measureBoundaryX(geometry, score_system, measure_end);
            if (vocal_visible) packet.rect(bx, geometry.vocal_y[system], if (measure_index + 1 == score_system.measure_end) 1.5 else 0.9, 49, palette.ink);
            packet.rect(bx, geometry.treble_y[system], if (measure_index + 1 == score_system.measure_end) 1.5 else 0.9, geometry.bass_y[system] - geometry.treble_y[system] + 49, palette.ink);
            if (measure_index == score_system.first_measure) continue;
            const previous = measures[measure_index - 1];
            if (measure.beats != previous.beats or measure.beat_unit != previous.beat_unit) {
                const change_x = measureBoundaryX(geometry, score_system, measure.start_beat) + 8;
                if (vocal_visible) drawSingleTimeSignature(packet, change_x, geometry.vocal_y[system], measure.beats, measure.beat_unit, music_em, palette.ink);
                drawTimeSignature(packet, change_x, geometry.treble_y[system], geometry.bass_y[system], measure.beats, measure.beat_unit, music_em, palette.ink);
            }
        }
    }

    drawPageNavigation(packet, Layout.calculate(state.viewport_width, state.viewport_height, state.keyboard_visible != 0), state, page_number, page_count);

    for (harmonies) |harmony| {
        const position = scoreBeatPosition(geometry, page, measures, harmony.start_beat) orelse continue;
        var x = position.x;
        const y = if (vocal_visible) geometry.vocal_y[position.system] - 27 else geometry.treble_y[position.system] - 31;
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

    if (state.pedal_guide_visible != 0) drawPedalNotation(packet, pedals, notes, geometry, page, measures, transport);

    for (notes, 0..) |note, note_index| {
        const vocal_guide = (note.flags & model.note_flag_vocal_guide) != 0;
        if (vocal_guide and state.vocal_guide_visible == 0) continue;
        const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        const staff_y = staffYForPosition(geometry, position);
        const active = transport.playing != 0 and transport.cursor_beat >= note.start_beat and transport.cursor_beat < note.start_beat + note.duration_beats;
        const color: Color = if (vocal_guide) (if (active) palette.rose else .{ 0.53, 0.33, 0.40, 1 }) else if (note.selected != 0) palette.rose else if (active) palette.cyan else palette.ink;
        const stem_up = chordStemUp(notes, note, staff_y);
        const note_x = position.x + if ((note.flags & model.note_flag_rest) != 0) @as(f32, 0) else chordNoteOffset(notes, note, stem_up);
        if (active or note.selected != 0) packet.glow(note_x - 14, position.y - 12, 29, 25, 13, if (active) .{ 0.18, 0.78, 0.76, 0.32 } else .{ 0.80, 0.20, 0.34, 0.24 }, time_seconds);
        if ((note.flags & model.note_flag_rest) != 0) {
            packet.musicGlyph(restGlyph(note.duration_beats), note_x - 7, position.y, 48, color);
            if (note.dots != 0) {
                for (0..@min(note.dots, 3)) |dot| packet.musicGlyph(0xe1e7, note_x + 10 + @as(f32, @floatFromInt(dot)) * 6, position.y - 6, 48, color);
            }
            continue;
        }
        if (position.y < staff_y - 3 or position.y > staff_y + 51) packet.rect(@min(position.x, note_x) - 12, position.y - 0.7, 24 + @abs(note_x - position.x), 1.4, palette.ink);
        const music_em: f32 = 48;
        if (shouldDrawAccidentalInMeasures(notes, note_index, meta, measures)) {
            packet.musicGlyph(accidentalGlyph(noteSpelling(note).alter), position.x - 23, position.y, music_em, color);
        }
        const notehead: u21 = if (note.duration_beats >= 4) 0xe0a2 else if (note.duration_beats >= 2) 0xe0a3 else 0xe0a4;
        const origin_offset: f32 = if (note.duration_beats >= 4) 10.1 else 7.1;
        packet.musicGlyph(notehead, note_x - origin_offset, position.y, music_em, color);
        if (note.duration_beats < 4 and !chordHasBeam(notes, note) and isChordStemAnchor(notes, note, stem_up)) {
            const stem_x = if (stem_up) note_x + 6.2 else note_x - 6.2;
            const stem_end = if (stem_up) position.y - 32 else position.y + 32;
            packet.rect(stem_x, @min(position.y, stem_end), 1.25, @abs(stem_end - position.y), color);
            if (note.duration_beats <= 0.5) packet.musicGlyph(if (stem_up) 0xe240 else 0xe241, stem_x, stem_end, music_em, color);
        }
        if (note.dots != 0) {
            const on_line = @abs(@round((position.y - staff_y) / 12) * 12 - (position.y - staff_y)) < 1.5;
            const dot_y = position.y - (if (on_line) @as(f32, 6) else 0);
            for (0..@min(note.dots, 3)) |dot| packet.musicGlyph(0xe1e7, note_x + 9 + @as(f32, @floatFromInt(dot)) * 6, dot_y, music_em, color);
        }
        drawArticulations(packet, note, note_x, position.y, stem_up, color);
        if (model.dynamic(note.flags) != 0) drawDynamic(packet, model.dynamic(note.flags), note_x - 3, if (position.bass) staff_y + 65 else staff_y + 62, color);
    }

    drawBeams(packet, notes, geometry, page, measures, state, transport);
    drawTies(packet, notes, geometry, page, measures, state, transport);
    drawSlurs(packet, notes, geometry, page, measures, state, transport);
    drawTuplets(packet, notes, geometry, page, measures, state, transport);

    if (vocal_visible) {
        for (lyrics) |lyric| {
            const position = scoreBeatPosition(geometry, page, measures, lyric.start_beat) orelse continue;
            const x = position.x;
            const y = geometry.vocal_y[position.system] + 55;
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

fn drawPageNavigation(packet: *render.Packet, layout: Layout, state: *const model.UiState, page_number: u32, page_count: u32) void {
    const previous_enabled = page_number > 1;
    const next_enabled = page_number < page_count;
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

fn drawDynamic(packet: *render.Packet, dynamic_code: u8, x: f32, y: f32, color: Color) void {
    const glyphs: []const u21 = switch (dynamic_code) {
        model.dynamic_ppp => &.{ 0xe520, 0xe520, 0xe520 },
        model.dynamic_pp => &.{ 0xe520, 0xe520 },
        model.dynamic_p => &.{0xe520},
        model.dynamic_mp => &.{ 0xe521, 0xe520 },
        model.dynamic_mf => &.{ 0xe521, 0xe522 },
        model.dynamic_f => &.{0xe522},
        model.dynamic_ff => &.{ 0xe522, 0xe522 },
        model.dynamic_fff => &.{ 0xe522, 0xe522, 0xe522 },
        model.dynamic_sfz => &.{ 0xe524, 0xe522, 0xe525 },
        else => return,
    };
    var cursor = x;
    for (glyphs) |glyph| {
        packet.musicGlyph(glyph, cursor, y, 36, color);
        cursor += switch (glyph) {
            0xe521 => 15,
            0xe522 => 9,
            else => 11,
        };
    }
}

const BeamAnchor = struct {
    start_beat: f32,
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
    color: Color,
};

fn drawBeams(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    var anchors: [512]BeamAnchor = undefined;
    var anchor_count: usize = 0;
    for (notes) |note| {
        if ((note.flags & model.note_flag_rest) != 0) continue;
        if ((note.flags & model.note_flag_beam_mask) == 0) continue;
        if ((note.flags & model.note_flag_vocal_guide) != 0 and state.vocal_guide_visible == 0) continue;
        const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        var existing: ?usize = null;
        for (anchors[0..anchor_count], 0..) |anchor, index| {
            if (anchor.start_beat == note.start_beat and anchor.staff == note.staff and anchor.voice == note.voice and anchor.vocal == position.vocal) {
                existing = index;
                break;
            }
        }
        if (existing) |index| {
            anchors[index].min_y = @min(anchors[index].min_y, position.y);
            anchors[index].max_y = @max(anchors[index].max_y, position.y);
            anchors[index].duration = @min(anchors[index].duration, note.duration_beats);
            anchors[index].flags |= note.flags;
        } else if (anchor_count < anchors.len) {
            anchors[anchor_count] = .{
                .start_beat = note.start_beat,
                .x = position.x,
                .min_y = position.y,
                .max_y = position.y,
                .duration = note.duration_beats,
                .staff = note.staff,
                .voice = note.voice,
                .system = position.system,
                .bass = position.bass,
                .vocal = position.vocal,
                .flags = note.flags,
                .color = noteInkColor(note, state, transport),
            };
            anchor_count += 1;
        }
    }

    for (anchors[0..anchor_count], 0..) |first_anchor, first_index| {
        if ((first_anchor.flags & model.note_flag_beam_begin) == 0) continue;
        var group: [64]usize = undefined;
        var group_count: usize = 1;
        group[0] = first_index;
        var current_index = first_index;
        while (group_count < group.len and (anchors[current_index].flags & model.note_flag_beam_end) == 0) {
            var next_index: ?usize = null;
            var next_beat = std.math.inf(f32);
            for (anchors[0..anchor_count], 0..) |candidate, candidate_index| {
                if (candidate.staff != first_anchor.staff or candidate.voice != first_anchor.voice or candidate.system != first_anchor.system or candidate.vocal != first_anchor.vocal) continue;
                if (candidate.start_beat <= anchors[current_index].start_beat or candidate.start_beat >= next_beat) continue;
                if ((candidate.flags & (model.note_flag_beam_continue | model.note_flag_beam_end)) == 0) continue;
                next_beat = candidate.start_beat;
                next_index = candidate_index;
            }
            current_index = next_index orelse break;
            group[group_count] = current_index;
            group_count += 1;
        }
        if (group_count < 2) continue;

        const staff_y = if (first_anchor.vocal) geometry.vocal_y[first_anchor.system] else if (first_anchor.bass) geometry.bass_y[first_anchor.system] else geometry.treble_y[first_anchor.system];
        var center_sum: f32 = 0;
        var group_min_y = std.math.inf(f32);
        var group_max_y = -std.math.inf(f32);
        for (group[0..group_count]) |index| {
            center_sum += (anchors[index].min_y + anchors[index].max_y) * 0.5;
            group_min_y = @min(group_min_y, anchors[index].min_y);
            group_max_y = @max(group_max_y, anchors[index].max_y);
        }
        const stem_up = center_sum / @as(f32, @floatFromInt(group_count)) >= staff_y + 24;
        const first = anchors[group[0]];
        const last = anchors[group[group_count - 1]];
        const first_center = (first.min_y + first.max_y) * 0.5;
        const last_center = (last.min_y + last.max_y) * 0.5;
        const baseline_start = if (stem_up) group_min_y - 29 else group_max_y + 29;
        const slope = std.math.clamp((last_center - first_center) * 0.22, -6, 6);
        const span = @max(last.x - first.x, 0.001);

        var beam_points: [64][2]f32 = undefined;
        for (group[0..group_count], 0..) |index, point_index| {
            const anchor = anchors[index];
            const x = anchor.x + (if (stem_up) @as(f32, 6.2) else -6.2);
            const t = std.math.clamp((anchor.x - first.x) / span, 0, 1);
            const beam_y = baseline_start + slope * t;
            const attach_y = if (stem_up) anchor.max_y else anchor.min_y;
            packet.line(x, attach_y, x, beam_y, 1.35, anchor.color);
            beam_points[point_index] = .{ x, beam_y };
        }
        for (0..group_count - 1) |point_index| {
            const left = beam_points[point_index];
            const right = beam_points[point_index + 1];
            packet.line(left[0], left[1], right[0], right[1], 4.2, first.color);
            const left_anchor = anchors[group[point_index]];
            const right_anchor = anchors[group[point_index + 1]];
            if (left_anchor.duration <= 0.25 and right_anchor.duration <= 0.25) {
                const offset: f32 = if (stem_up) 6 else -6;
                packet.line(left[0], left[1] + offset, right[0], right[1] + offset, 3.5, first.color);
            }
        }
    }
}

fn drawTies(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    for (notes) |note| {
        if ((note.flags & model.note_flag_rest) != 0) continue;
        if ((note.flags & model.note_flag_tie_start) == 0) continue;
        const start_position = scoreNotePosition(note, geometry, page, measures) orelse continue;
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
        const end_position = scoreNotePosition(tied, geometry, page, measures) orelse continue;
        if (end_position.system != start_position.system) continue;
        const staff_y = staffYForPosition(geometry, start_position);
        const arc_below = start_position.y < staff_y + 24;
        const y_sign: f32 = if (arc_below) 1 else -1;
        const x1 = start_position.x + 7;
        const x2 = end_position.x - 7;
        if (x2 <= x1 + 2) continue;
        const base_y = start_position.y + y_sign * 7;
        const color = noteInkColor(note, state, transport);
        var previous_x = x1;
        var previous_y = base_y;
        for (1..9) |segment| {
            const t = @as(f32, @floatFromInt(segment)) / 8.0;
            const x = x1 + (x2 - x1) * t;
            const y = base_y + y_sign * 8 * (4 * t * (1 - t));
            packet.line(previous_x, previous_y, x, y, 1.35, color);
            previous_x = x;
            previous_y = y;
        }
    }
}

fn drawSlurs(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    for (notes) |note| {
        if ((note.flags & (model.note_flag_rest | model.note_flag_slur_start)) != model.note_flag_slur_start) continue;
        const start_position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        var target: ?model.Note = null;
        var nearest_beat = std.math.inf(f32);
        for (notes) |candidate| {
            if ((candidate.flags & model.note_flag_rest) != 0 or (candidate.flags & model.note_flag_slur_stop) == 0) continue;
            if (!sameNotationLayer(candidate, note) or candidate.staff != note.staff or candidate.voice != note.voice or candidate.start_beat <= note.start_beat or candidate.start_beat >= nearest_beat) continue;
            nearest_beat = candidate.start_beat;
            target = candidate;
        }
        const ending = target orelse continue;
        const end_position = scoreNotePosition(ending, geometry, page, measures) orelse continue;
        if (end_position.system != start_position.system) continue;
        const staff_y = staffYForPosition(geometry, start_position);
        const above = (note.flags & model.note_flag_slur_above) != 0 or start_position.y >= staff_y + 24;
        const sign: f32 = if (above) -1 else 1;
        const x1 = start_position.x + 4;
        const x2 = end_position.x + 4;
        if (x2 <= x1 + 8) continue;
        const height = std.math.clamp((x2 - x1) * 0.11, 13, 30);
        const color = noteInkColor(note, state, transport);
        var previous_x = x1;
        var previous_y = start_position.y + sign * 10;
        for (1..13) |segment| {
            const t = @as(f32, @floatFromInt(segment)) / 12.0;
            const x = x1 + (x2 - x1) * t;
            const endpoint_y = start_position.y + (end_position.y - start_position.y) * t;
            const y = endpoint_y + sign * (10 + height * (4 * t * (1 - t)));
            packet.line(previous_x, previous_y, x, y, 1.45, color);
            previous_x = x;
            previous_y = y;
        }
    }
}

fn drawTuplets(packet: *render.Packet, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, state: *const model.UiState, transport: *const model.Transport) void {
    for (notes) |note| {
        const actual = model.tupletActual(note.flags);
        if (actual < 2 or (note.flags & model.note_flag_rest) != 0) continue;
        var has_previous = false;
        for (notes) |candidate| {
            if (!sameNotationLayer(candidate, note) or candidate.staff != note.staff or candidate.voice != note.voice or candidate.start_beat >= note.start_beat) continue;
            if (model.tupletActual(candidate.flags) == actual and note.start_beat - candidate.start_beat <= @max(candidate.duration_beats * 1.1, 0.34)) has_previous = true;
        }
        if ((note.flags & model.note_flag_tuplet_start) == 0 and has_previous) continue;
        const start_position = scoreNotePosition(note, geometry, page, measures) orelse continue;
        var ending = note;
        var distinct: u8 = 1;
        var last_beat = note.start_beat;
        var explicit_stop = (note.flags & model.note_flag_tuplet_stop) != 0;
        while (!explicit_stop and distinct < actual) {
            var next_note: ?model.Note = null;
            var next_beat = std.math.inf(f32);
            for (notes) |candidate| {
                if ((candidate.flags & model.note_flag_rest) != 0 or !sameNotationLayer(candidate, note) or candidate.staff != note.staff or candidate.voice != note.voice) continue;
                if (model.tupletActual(candidate.flags) != actual or candidate.start_beat <= last_beat or candidate.start_beat >= next_beat) continue;
                next_note = candidate;
                next_beat = candidate.start_beat;
            }
            ending = next_note orelse break;
            last_beat = ending.start_beat;
            explicit_stop = (ending.flags & model.note_flag_tuplet_stop) != 0;
            distinct += 1;
        }
        if (distinct < 2) continue;
        const end_position = scoreNotePosition(ending, geometry, page, measures) orelse continue;
        if (end_position.system != start_position.system) continue;
        const staff_y = staffYForPosition(geometry, start_position);
        const y = @min(staff_y - 17, @min(start_position.y, end_position.y) - 23);
        const x1 = start_position.x - 3;
        const x2 = end_position.x + 7;
        const color = noteInkColor(note, state, transport);
        if ((note.flags & model.note_flag_beam_mask) == 0) {
            const middle = (x1 + x2) * 0.5;
            packet.line(x1, y, middle - 8, y, 1.1, color);
            packet.line(middle + 8, y, x2, y, 1.1, color);
            packet.line(x1, y, x1, y + 5, 1.1, color);
            packet.line(x2, y, x2, y + 5, 1.1, color);
        }
        if (actual <= 9) packet.musicGlyph(0xe080 + @as(u21, actual), (x1 + x2) * 0.5 - 5, y + 4, 28, color);
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
        if ((note.flags & (model.note_flag_vocal_guide | model.note_flag_rest)) != 0) continue;
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

fn drawPedalNotation(packet: *render.Packet, events: []const model.PedalEvent, notes: []const model.Note, geometry: ScoreGeometry, page: ScorePage, measures: []const model.Measure, transport: *const model.Transport) void {
    for (0..page.system_count) |system| {
        const system_start = page.systems[system].start_beat;
        const system_end = page.systems[system].end_beat;
        const next_treble = if (system == 0) geometry.treble_y[1] else geometry.page_y + geometry.page_height;
        // Pedal is a separate expression lane, not text painted on top of the
        // lowest bass stem. Estimate the rendered bass ink (including beams,
        // flags, articulation space, and dynamics), then place the lane below
        // it while keeping a safety gap before the next system.
        var lowest_bass_ink = geometry.bass_y[system] + 52;
        for (notes) |note| {
            const position = scoreNotePosition(note, geometry, page, measures) orelse continue;
            if (position.system != system or !position.bass) continue;
            var extent = position.y + if ((note.flags & model.note_flag_rest) != 0) @as(f32, 16) else 42;
            if (model.dynamic(note.flags) != 0) extent = @max(extent, geometry.bass_y[system] + 84);
            const below_articulation_mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato | model.note_flag_fermata;
            if ((note.flags & below_articulation_mask) != 0 and chordStemUp(notes, note, geometry.bass_y[system])) extent += 18;
            lowest_bass_ink = @max(lowest_bass_ink, extent);
        }
        const y = @min(@max(geometry.bass_y[system] + 76, lowest_bass_ink + 16), next_treble - 18);
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

fn drawPedalStatus(packet: *render.Packet, panel: Rect, state: *const model.UiState, transport: *const model.Transport, pedals: []const model.PedalEvent) void {
    if (panel.width < 880) return;
    const labels = [_][]const u8{ "SOFT", "SOST", "SUST" };
    const values = [_]u32{ state.soft_pedal, state.sostenuto_pedal, state.sustain_pedal };
    const kinds = [_]u8{ model.pedal_soft, model.pedal_sostenuto, model.pedal_sustain };
    const start_x = panel.x + panel.width - 352;
    if (panel.width >= 800) {
        packet.text(start_x - 128, panel.y + 18, "LIVE / SCORE", 0.68, palette.muted);
        if (nextPedalEvent(pedals, model.pedal_sustain, @max(0, transport.cursor_beat))) |next| {
            var instruction_buffer: [64]u8 = undefined;
            const action: []const u8 = switch (next.action) {
                model.pedal_action_stop, model.pedal_action_discontinue => "UP",
                model.pedal_action_change => "CHANGE",
                else => "DOWN",
            };
            const instruction = std.fmt.bufPrint(&instruction_buffer, "NEXT SUST {s}  {d:.1} BEATS", .{ action, next.start_beat - @max(0, transport.cursor_beat) }) catch "NEXT PEDAL CHANGE";
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
    packet.rect(panel.x, panel.y, panel.width, panel.height, .{ 0.055, 0.064, 0.078, 1 });
    packet.rect(panel.x, panel.y, panel.width, 1, palette.border);
    packet.text(panel.x + 24, panel.y + 14, "Guided piano", 1.55, palette.text);
    if (panel.width >= 560) packet.text(panel.x + 142, panel.y + 17, "Follow the glow / 1 thumb / 5 little finger", 1.0, palette.muted);
    if (state.pedal_guide_visible != 0) drawPedalStatus(packet, panel, state, transport, pedals);
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

fn drawAnnotations(packet: *render.Packet, stage: Rect, state: *const model.UiState, meta: *const model.DocumentMeta, measures: []const model.Measure, annotations: *const annotation.Store) void {
    const page_index = scorePageForBeat(measures, state.view_start_beat, meta).page_index;
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
        if (practice.pedal_errors != 0) "PEDAL CHANGE MISSED OR LATE" else "REPLAY AUDIO + MIDI"
    else if (practice.pedal_errors != 0)
        "CHECK THE PEDAL GUIDE TIMING"
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
        packet.text(28, layout.transport.y + 44, std.fmt.bufPrint(&beat_buffer, "{d} BEATS", .{beats_left}) catch "READY", 1.6, palette.text);
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
    packet.text(layout.transport.width - 134, layout.transport.y + 24, if (state.tempo_editing != 0) "TYPE BPM" else "TEMPO", 1.15, if (state.tempo_editing != 0 and !tempo_valid) palette.rose else palette.muted);
    if (state.tempo_editing != 0) {
        packet.text(layout.transport.width - 134, layout.transport.y + 45, std.fmt.bufPrint(&tempo_buffer, "{d}| BPM", .{state.tempo_edit_value}) catch "BPM", 1.55, if (tempo_valid) palette.cyan else palette.rose);
    } else {
        packet.text(layout.transport.width - 134, layout.transport.y + 45, std.fmt.bufPrint(&tempo_buffer, "{d:.0} BPM", .{transport.tempo_bpm}) catch "BPM", 1.55, if (tempo_hovered) palette.cyan else palette.text);
    }
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
    drawScore(&packet, .{ .x = 0, .y = 0, .width = 900, .height = 620 }, &state, &transport, &meta, &notes, &.{}, &.{}, &.{}, &measures, 0);
    var analytic_lines: usize = 0;
    for (packet.slice()) |item| if (@as(u32, @intFromFloat(item.params[0] + 0.5)) == @intFromEnum(render.Kind.line)) {
        analytic_lines += 1;
    };
    try std.testing.expect(analytic_lines >= 21); // beam, tie, and twelve-segment slur
    try std.testing.expect(packet.len >= 65); // articulation, fermata, tuplet, and mf glyphs are present
    try std.testing.expect(!packet.clipped);
}

test "vocal guide occupies an independent labeled staff" {
    const geometry = ScoreGeometry.calculateWithVocal(.{ .x = 0, .y = 0, .width = 900, .height = 620 }, true);
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 4, .number = 2 },
    };
    const page = scorePageForBeat(&measures, 0, &.{});
    const piano = model.Note{ .stable_id = 1, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 88, .staff = 0, .voice = 0 };
    const vocal = model.Note{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_vocal_guide };
    const piano_position = scoreNotePosition(piano, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    const vocal_position = scoreNotePosition(vocal, geometry, page, &measures) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!piano_position.vocal);
    try std.testing.expect(vocal_position.vocal);
    try std.testing.expect(vocal_position.y < piano_position.y - 40);
    try std.testing.expect(!hasVocalGuide(&.{piano}));
    try std.testing.expect(hasVocalGuide(&.{ piano, vocal }));
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
    const page = scorePageForBeat(&measures, 0, &.{});
    drawPedalNotation(&packet, &opening_events, &.{}, geometry, page, &measures, &transport);
    var line_count: usize = 0;
    for (packet.slice()) |item| if (@as(u32, @intFromFloat(item.params[0] + 0.5)) == @intFromEnum(render.Kind.line)) {
        line_count += 1;
        try std.testing.expect(item.rect[2] >= item.rect[0]);
    };
    try std.testing.expect(line_count >= 3);
    try std.testing.expect(!packet.clipped);
}
