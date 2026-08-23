const std = @import("std");
const model = @import("../model.zig");

pub const divisions: i64 = 480;
pub const max_export_notes = 4096;

pub const Error = error{OutputTooSmall};

const Builder = struct {
    output: []u8,
    len: usize = 0,

    fn append(self: *Builder, bytes: []const u8) Error!void {
        if (bytes.len > self.output.len - self.len) return error.OutputTooSmall;
        @memcpy(self.output[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn print(self: *Builder, comptime format: []const u8, args: anytype) Error!void {
        const rendered = std.fmt.bufPrint(self.output[self.len..], format, args) catch return error.OutputTooSmall;
        self.len += rendered.len;
    }

    fn escaped(self: *Builder, value: []const u8) Error!void {
        for (value) |byte| switch (byte) {
            '&' => try self.append("&amp;"),
            '<' => try self.append("&lt;"),
            '>' => try self.append("&gt;"),
            '\"' => try self.append("&quot;"),
            '\'' => try self.append("&apos;"),
            else => try self.append(&.{byte}),
        };
    }
};

const Segment = struct {
    note: model.Note,
    start_tick: i64,
    duration_tick: i64,
    tie_stop: bool,
    tie_start: bool,
    original_start: bool,
    original_end: bool,
};

pub fn write(
    output: []u8,
    meta: *const model.DocumentMeta,
    transport: *const model.Transport,
    notes: []const model.Note,
    lyrics: []const model.Lyric,
    harmonies: []const model.Harmony,
    pedals: []const model.PedalEvent,
    measures: []const model.Measure,
    playback: *const model.PlaybackBounds,
) Error!usize {
    var builder = Builder{ .output = output };
    try builder.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try builder.append("<score-partwise version=\"4.0\">\n  <work><work-title>");
    try builder.escaped(meta.titleSlice());
    try builder.append("</work-title></work>\n  <identification><creator type=\"composer\">");
    try builder.escaped(meta.creatorSlice());
    try builder.append("</creator><encoding><software>Score</software></encoding></identification>\n");

    const fallback_beats = @max(@as(u8, 1), meta.beats_per_measure);
    const fallback_beat_unit = @max(@as(u8, 1), meta.beat_unit);
    const fallback_measure_beats = @as(f32, @floatFromInt(fallback_beats)) * 4.0 / @as(f32, @floatFromInt(fallback_beat_unit));
    var max_end: f32 = fallback_measure_beats;
    for (notes) |note| max_end = @max(max_end, note.start_beat + @max(note.duration_beats, 1.0 / @as(f32, @floatFromInt(divisions))));
    for (lyrics) |lyric| max_end = @max(max_end, lyric.start_beat + 0.001);
    for (harmonies) |harmony| max_end = @max(max_end, harmony.start_beat + 0.001);
    for (pedals) |pedal| max_end = @max(max_end, pedal.start_beat + 0.001);
    var measure_count: usize = if (measures.len != 0) measures.len else @max(1, @as(usize, @intFromFloat(@ceil(max_end / fallback_measure_beats))));
    if (measures.len != 0) {
        const last = measures[measures.len - 1];
        const authored_end = last.start_beat + @max(0.0001, last.duration_beats);
        max_end = @max(max_end, authored_end);
        if (max_end > authored_end + 0.0001) measure_count += @as(usize, @intFromFloat(@ceil((max_end - authored_end) / fallback_measure_beats)));
    }

    const has_vocal_guide = for (notes) |note| {
        if ((note.flags & model.note_flag_vocal_guide) != 0) break true;
    } else false;
    try builder.append("  <part-list><score-part id=\"P1\"><part-name>Piano</part-name><score-instrument id=\"P1-I1\"><instrument-name>Acoustic Grand Piano</instrument-name></score-instrument><midi-instrument id=\"P1-I1\"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part>");
    if (has_vocal_guide) try builder.append("<score-part id=\"P2\"><part-name>Vocal guide (optional)</part-name><score-instrument id=\"P2-I1\"><instrument-name>Voice guide</instrument-name></score-instrument></score-part>");
    try builder.append("</part-list>\n");

    const part_count: usize = if (has_vocal_guide) 2 else 1;
    for (0..part_count) |part_index| {
        const vocal_part = has_vocal_guide and part_index == 1;
        try builder.print("  <part id=\"P{d}\">\n", .{part_index + 1});
        var segments: [max_export_notes]Segment = undefined;
        for (0..measure_count) |measure_index| {
            const imported_measure = measure_index < measures.len;
            const measure = if (imported_measure) measures[measure_index] else blk: {
                const authored_end = if (measures.len != 0)
                    measures[measures.len - 1].start_beat + @max(0.0001, measures[measures.len - 1].duration_beats)
                else
                    0;
                const extension_index = measure_index - measures.len;
                const number: u32 = if (measures.len != 0)
                    measures[measures.len - 1].number + @as(u32, @intCast(extension_index + 1))
                else
                    @intCast(measure_index + 1);
                break :blk model.Measure{
                    .start_beat = authored_end + @as(f32, @floatFromInt(extension_index)) * fallback_measure_beats,
                    .duration_beats = fallback_measure_beats,
                    .number = number,
                    .beats = fallback_beats,
                    .beat_unit = fallback_beat_unit,
                };
            };
            try builder.print("    <measure number=\"{d}\"", .{measure.number});
            if (measure.implicit != 0) try builder.append(" implicit=\"yes\"");
            try builder.append(">\n");
            const beats = @max(@as(u8, 1), measure.beats);
            const beat_unit = @max(@as(u8, 1), measure.beat_unit);
            if (measure_index == 0) {
                if (vocal_part) {
                    try builder.print("      <attributes><divisions>{d}</divisions><key><fifths>{d}</fifths></key><time><beats>{d}</beats><beat-type>{d}</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\n", .{ divisions, meta.key_fifths, beats, beat_unit });
                } else {
                    try builder.print("      <attributes><divisions>{d}</divisions><key><fifths>{d}</fifths></key><time><beats>{d}</beats><beat-type>{d}</beat-type></time><staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>\n", .{ divisions, meta.key_fifths, beats, beat_unit });
                }
            } else {
                const previous = if (measure_index - 1 < measures.len) measures[measure_index - 1] else model.Measure{ .beats = fallback_beats, .beat_unit = fallback_beat_unit };
                if (beats != @max(@as(u8, 1), previous.beats) or beat_unit != @max(@as(u8, 1), previous.beat_unit)) {
                    try builder.print("      <attributes><time><beats>{d}</beats><beat-type>{d}</beat-type></time></attributes>\n", .{ beats, beat_unit });
                }
            }

            const measure_ticks: i64 = @max(1, beatToTick(@max(0.0001, measure.duration_beats)));
            const measure_start = beatToTick(@max(0, measure.start_beat));
            const measure_end = measure_start + measure_ticks;
            if (!vocal_part) {
                const tempo_count = @min(@as(usize, playback.tempo_count), playback.tempos.len);
                const editable_quarter = model.quarterTempoFromPulse(@max(1, transport.tempo_bpm), meta.tempo_beat_unit);
                var emitted_tempo = false;
                for (playback.tempos[0..tempo_count]) |tempo| {
                    const tempo_tick = beatToTick(@max(0, tempo.start_beat));
                    if (tempo_tick < measure_start or tempo_tick >= measure_end) continue;
                    const scale = editable_quarter / @max(1, playback.tempo_base_bpm);
                    try writeTempo(&builder, tempo.bpm * scale, meta.tempo_beat_unit, tempo_tick - measure_start);
                    emitted_tempo = true;
                }
                if (measure_index == 0 and !emitted_tempo) try writeTempo(&builder, editable_quarter, meta.tempo_beat_unit, 0);
                for (harmonies) |harmony| {
                    const harmony_tick = beatToTick(@max(0, harmony.start_beat));
                    if (harmony_tick < measure_start or harmony_tick >= measure_end) continue;
                    try writeHarmony(&builder, harmony, harmony_tick - measure_start);
                }
                for (pedals) |pedal| {
                    const pedal_tick = beatToTick(@max(0, pedal.start_beat));
                    if (pedal_tick < measure_start or pedal_tick >= measure_end) continue;
                    try writePedal(&builder, pedal, pedal_tick - measure_start);
                }
            }
            if (vocal_part or !has_vocal_guide) {
                for (lyrics) |lyric| {
                    const lyric_tick = beatToTick(@max(0, lyric.start_beat));
                    if (lyric_tick < measure_start or lyric_tick >= measure_end) continue;
                    try builder.append(if (vocal_part) "      <direction placement=\"below\"><direction-type><words>" else "      <direction placement=\"above\"><direction-type><words>");
                    try builder.escaped(lyric.textSlice());
                    try builder.append("</words></direction-type>");
                    try builder.print("<offset>{d}</offset></direction>\n", .{lyric_tick - measure_start});
                }
            }

            var emitted_track = false;
            var emitted_any_note = false;
            var exported_voice: usize = 0;
            // The vocal guide is a real, independent MusicXML part. This keeps
            // it out of piano playback/assessment and prevents guide cues from
            // being merged into grand-staff voices on exchange round trips.
            const output_staff_count: usize = if (vocal_part) 1 else 2;
            for (0..output_staff_count) |output_staff_index| {
                for (0..256) |source_staff_index| {
                    const source_staff: u8 = @intCast(source_staff_index);
                    const output_staff = if (vocal_part) 1 else exportStaff(source_staff);
                    if (output_staff != output_staff_index + 1) continue;
                    var voices = [_]bool{false} ** 256;
                    for (notes) |note| {
                        if (note.staff != source_staff or noteIsVocal(note) != vocal_part) continue;
                        const note_start = beatToTick(@max(0, note.start_beat));
                        const note_end = note_start + @max(1, beatToTick(@max(note.duration_beats, 1.0 / @as(f32, @floatFromInt(divisions)))));
                        if (note_start < measure_end and note_end > measure_start) voices[note.voice] = true;
                    }
                    for (voices, 0..) |present, source_voice_index| {
                        if (!present) continue;
                        if (emitted_track) try builder.print("      <backup><duration>{d}</duration></backup>\n", .{measure_ticks});
                        emitted_track = true;
                        exported_voice += 1;
                        const count = collectSegments(&segments, notes, source_staff, @intCast(source_voice_index), measure_start, measure_end, vocal_part);
                        std.mem.sort(Segment, segments[0..count], {}, segmentLessThan);
                        try writeTrack(&builder, segments[0..count], output_staff_index + 1, exported_voice, measure_ticks);
                        emitted_any_note = emitted_any_note or count != 0;
                    }
                }
            }
            if (!emitted_any_note) {
                try builder.print("      <note><rest measure=\"yes\"/><duration>{d}</duration><voice>1</voice><staff>1</staff></note>\n", .{measure_ticks});
            }
            try builder.append("    </measure>\n");
        }
        try builder.append("  </part>\n");
    }
    try builder.append("</score-partwise>\n");
    return builder.len;
}

fn writeTempo(builder: *Builder, quarter_bpm: f32, requested_beat_unit: u8, offset_ticks: i64) Error!void {
    const beat_unit = if (tempoBeatUnitName(requested_beat_unit) != null) requested_beat_unit else 4;
    const unit_name = tempoBeatUnitName(beat_unit) orelse "quarter";
    const quarter = std.math.clamp(quarter_bpm, 1, 999);
    const pulse = std.math.clamp(model.pulseTempoFromQuarter(quarter, beat_unit), 1, 999);
    try builder.print("      <direction placement=\"above\"><direction-type><metronome><beat-unit>{s}</beat-unit><per-minute>{d:.3}</per-minute></metronome></direction-type>", .{ unit_name, pulse });
    if (offset_ticks != 0) try builder.print("<offset>{d}</offset>", .{offset_ticks});
    try builder.print("<sound tempo=\"{d:.3}\"/></direction>\n", .{quarter});
}

fn tempoBeatUnitName(beat_unit: u8) ?[]const u8 {
    return switch (beat_unit) {
        1 => "whole",
        2 => "half",
        4 => "quarter",
        8 => "eighth",
        16 => "16th",
        32 => "32nd",
        64 => "64th",
        128 => "128th",
        else => null,
    };
}

fn writePedal(builder: *Builder, pedal: model.PedalEvent, offset_tick: i64) Error!void {
    // MusicXML's pedal direction denotes the damper/sustain pedal. Preserve
    // other controller automation in the native document until a standard
    // exchange representation is available instead of mislabeling it.
    if (pedal.pedal != model.pedal_sustain) return;
    try builder.append("      <direction placement=\"below\"><direction-type><pedal type=\"");
    try builder.append(pedalActionName(pedal.action));
    try builder.append("\"");
    if ((pedal.flags & model.pedal_flag_line) != 0) try builder.append(" line=\"yes\"");
    if ((pedal.flags & model.pedal_flag_sign) != 0) try builder.append(" sign=\"yes\"");
    try builder.append("/></direction-type>");
    if (offset_tick != 0) try builder.print("<offset>{d}</offset>", .{offset_tick});
    // MusicXML's sound element carries continuous damper position as a
    // percentage. Keep the visible pedal line/sign and the performed CC64
    // value in the same exchange document so half-pedal guidance does not
    // collapse to a binary on/off instruction after a round trip.
    try builder.print("<sound damper-pedal=\"{d:.3}\"/>", .{@as(f32, @floatFromInt(pedal.value)) * 100.0 / 127.0});
    try builder.append("<staff>2</staff></direction>\n");
}

fn pedalActionName(action: u8) []const u8 {
    return switch (action) {
        model.pedal_action_start => "start",
        model.pedal_action_stop => "stop",
        model.pedal_action_change => "change",
        model.pedal_action_continue => "continue",
        model.pedal_action_resume => "resume",
        model.pedal_action_discontinue => "discontinue",
        else => "stop",
    };
}

fn writeHarmony(builder: *Builder, harmony: model.Harmony, offset_tick: i64) Error!void {
    try builder.append("      <harmony><root><root-step>");
    try builder.append(&.{harmony.root_step});
    try builder.append("</root-step>");
    if (harmony.root_alter != 0) try builder.print("<root-alter>{d}</root-alter>", .{harmony.root_alter});
    try builder.append("</root><kind");
    if (harmony.text_len != 0) {
        try builder.append(" text=\"");
        try builder.escaped(harmony.textSlice());
        try builder.append("\"");
    }
    try builder.append(">");
    try builder.escaped(if (harmony.kind_len != 0) harmony.kindSlice() else "major");
    try builder.append("</kind>");
    if (harmony.inversion >= 0) try builder.print("<inversion>{d}</inversion>", .{harmony.inversion});
    if (harmony.bass_step != 0) {
        try builder.append("<bass><bass-step>");
        try builder.append(&.{harmony.bass_step});
        try builder.append("</bass-step>");
        if (harmony.bass_alter != 0) try builder.print("<bass-alter>{d}</bass-alter>", .{harmony.bass_alter});
        try builder.append("</bass>");
    }
    if (offset_tick != 0) try builder.print("<offset>{d}</offset>", .{offset_tick});
    try builder.append("</harmony>\n");
}

fn beatToTick(beat: f32) i64 {
    return @intFromFloat(@round(beat * @as(f32, @floatFromInt(divisions))));
}

fn exportStaff(source: u8) usize {
    return if ((source & 1) == 0) 1 else 2;
}

fn noteIsVocal(note: model.Note) bool {
    return (note.flags & model.note_flag_vocal_guide) != 0;
}

fn collectSegments(
    destination: *[max_export_notes]Segment,
    notes: []const model.Note,
    source_staff: u8,
    voice: u8,
    measure_start: i64,
    measure_end: i64,
    vocal_part: bool,
) usize {
    var count: usize = 0;
    for (notes) |note| {
        if (note.staff != source_staff or note.voice != voice or noteIsVocal(note) != vocal_part) continue;
        const note_start = beatToTick(@max(0, note.start_beat));
        const note_end = note_start + @max(1, beatToTick(@max(note.duration_beats, 1.0 / @as(f32, @floatFromInt(divisions)))));
        if (note_start >= measure_end or note_end <= measure_start) continue;
        if (count == destination.len) break;
        const start = @max(note_start, measure_start);
        const end = @min(note_end, measure_end);
        destination[count] = .{
            .note = note,
            .start_tick = start - measure_start,
            .duration_tick = @max(1, end - start),
            .tie_stop = note_start < measure_start or (note_start >= measure_start and (note.flags & model.note_flag_tie_stop) != 0),
            .tie_start = note_end > measure_end or (note_end <= measure_end and (note.flags & model.note_flag_tie_start) != 0),
            .original_start = start == note_start,
            .original_end = end == note_end,
        };
        count += 1;
    }
    return count;
}

fn segmentLessThan(_: void, left: Segment, right: Segment) bool {
    if (left.start_tick != right.start_tick) return left.start_tick < right.start_tick;
    if (left.duration_tick != right.duration_tick) return left.duration_tick > right.duration_tick;
    return left.note.pitch < right.note.pitch;
}

fn writeTrack(builder: *Builder, segments: []const Segment, staff: usize, voice: usize, measure_ticks: i64) Error!void {
    var cursor: i64 = 0;
    var index: usize = 0;
    while (index < segments.len) {
        const group_start = segments[index].start_tick;
        if (group_start > cursor) try builder.print("      <forward><duration>{d}</duration></forward>\n", .{group_start - cursor});
        var group_end = index + 1;
        while (group_end < segments.len and segments[group_end].start_tick == group_start) : (group_end += 1) {}
        for (segments[index..group_end]) |segment| {
            const dynamic_code = if (segment.original_start) model.dynamic(segment.note.flags) else 0;
            if (dynamicName(dynamic_code)) |name| {
                try builder.print("      <direction placement=\"below\"><direction-type><dynamics><{s}/></dynamics></direction-type></direction>\n", .{name});
                break;
            }
        }
        for (segments[index..group_end], 0..) |segment, chord_index| try writeNote(builder, segment, staff, voice, chord_index != 0);
        cursor = @max(cursor, group_start + segments[index].duration_tick);
        index = group_end;
    }
    if (cursor < measure_ticks) try builder.print("      <forward><duration>{d}</duration></forward>\n", .{measure_ticks - cursor});
}

fn writeNote(builder: *Builder, segment: Segment, staff: usize, voice: usize, chord: bool) Error!void {
    const pitch_class = segment.note.pitch % 12;
    const steps = [_][]const u8{ "C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B" };
    const alters = [_]i8{ 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 };
    const has_spelling = segment.note.written_step >= 'A' and segment.note.written_step <= 'G' and segment.note.written_octave >= 0;
    try builder.append("      <note>");
    if (chord) try builder.append("<chord/>");
    if ((segment.note.flags & model.note_flag_vocal_guide) != 0) try builder.append("<cue/>");
    const alter = if (has_spelling) segment.note.written_alter else alters[pitch_class];
    const rest = (segment.note.flags & model.note_flag_rest) != 0;
    if (rest) {
        if (has_spelling) {
            try builder.print("<rest><display-step>{c}</display-step><display-octave>{d}</display-octave></rest>", .{ segment.note.written_step, segment.note.written_octave });
        } else if ((segment.note.flags & model.note_flag_measure_rest) != 0) {
            try builder.append("<rest measure=\"yes\"/>");
        } else {
            try builder.append("<rest/>");
        }
    } else {
        try builder.append("<pitch><step>");
        if (has_spelling) try builder.append(&.{segment.note.written_step}) else try builder.append(steps[pitch_class]);
        try builder.append("</step>");
        if (alter != 0) try builder.print("<alter>{d}</alter>", .{alter});
        const octave: i16 = if (has_spelling) segment.note.written_octave else @as(i16, segment.note.pitch / 12) - 1;
        try builder.print("<octave>{d}</octave></pitch>", .{octave});
    }
    try builder.print("<duration>{d}</duration><voice>{d}</voice><staff>{d}</staff>", .{ segment.duration_tick, voice, staff });
    const tuplet_actual = model.tupletActual(segment.note.flags);
    const tuplet_normal = model.tupletNormal(segment.note.flags);
    if (!rest and tuplet_actual > 1 and tuplet_normal > 0) try builder.print("<time-modification><actual-notes>{d}</actual-notes><normal-notes>{d}</normal-notes></time-modification>", .{ tuplet_actual, tuplet_normal });
    if (!rest and segment.tie_stop) try builder.append("<tie type=\"stop\"/>");
    if (!rest and segment.tie_start) try builder.append("<tie type=\"start\"/>");
    for (0..@min(segment.note.dots, 3)) |_| try builder.append("<dot/>");
    if (!rest and (segment.note.flags & model.note_flag_explicit_accidental) != 0) {
        try builder.append("<accidental>");
        try builder.append(switch (alter) {
            -2 => "flat-flat",
            -1 => "flat",
            0 => "natural",
            1 => "sharp",
            2 => "double-sharp",
            else => "natural",
        });
        try builder.append("</accidental>");
    }
    const beam_text: ?[]const u8 = if (rest)
        null
    else if ((segment.note.flags & model.note_flag_beam_begin) != 0)
        "begin"
    else if ((segment.note.flags & model.note_flag_beam_continue) != 0)
        "continue"
    else if ((segment.note.flags & model.note_flag_beam_end) != 0)
        "end"
    else
        null;
    if (beam_text) |value| try builder.print("<beam number=\"1\">{s}</beam>", .{value});
    const slur_start = segment.original_start and (segment.note.flags & model.note_flag_slur_start) != 0;
    const slur_stop = segment.original_end and (segment.note.flags & model.note_flag_slur_stop) != 0;
    const tuplet_start = segment.original_start and (segment.note.flags & model.note_flag_tuplet_start) != 0;
    const tuplet_stop = segment.original_end and (segment.note.flags & model.note_flag_tuplet_stop) != 0;
    const articulation_mask = model.note_flag_staccato | model.note_flag_accent | model.note_flag_tenuto | model.note_flag_marcato;
    const has_articulations = segment.original_start and (segment.note.flags & articulation_mask) != 0;
    const fermata = segment.original_start and (segment.note.flags & model.note_flag_fermata) != 0;
    const has_fingering = segment.original_start and segment.note.fingering >= 1 and segment.note.fingering <= 5;
    if (!rest and (segment.tie_stop or segment.tie_start or slur_start or slur_stop or tuplet_start or tuplet_stop or has_articulations or fermata or has_fingering)) {
        try builder.append("<notations>");
        if (segment.tie_stop) try builder.append("<tied type=\"stop\"/>");
        if (segment.tie_start) try builder.append("<tied type=\"start\"/>");
        if (slur_stop) try builder.append("<slur type=\"stop\"/>");
        if (slur_start) try builder.append(if ((segment.note.flags & model.note_flag_slur_above) != 0) "<slur type=\"start\" placement=\"above\"/>" else "<slur type=\"start\"/>");
        if (tuplet_stop) try builder.append("<tuplet type=\"stop\"/>");
        if (tuplet_start) try builder.append("<tuplet type=\"start\"/>");
        if (has_articulations) {
            try builder.append("<articulations>");
            if ((segment.note.flags & model.note_flag_staccato) != 0) try builder.append("<staccato/>");
            if ((segment.note.flags & model.note_flag_accent) != 0) try builder.append("<accent/>");
            if ((segment.note.flags & model.note_flag_tenuto) != 0) try builder.append("<tenuto/>");
            if ((segment.note.flags & model.note_flag_marcato) != 0) try builder.append("<strong-accent/>");
            try builder.append("</articulations>");
        }
        if (fermata) try builder.append("<fermata/>");
        if (has_fingering) try builder.print("<technical><fingering>{d}</fingering></technical>", .{segment.note.fingering});
        try builder.append("</notations>");
    }
    try builder.append("</note>\n");
}

fn dynamicName(dynamic_code: u8) ?[]const u8 {
    return switch (dynamic_code) {
        model.dynamic_ppp => "ppp",
        model.dynamic_pp => "pp",
        model.dynamic_p => "p",
        model.dynamic_mp => "mp",
        model.dynamic_mf => "mf",
        model.dynamic_f => "f",
        model.dynamic_ff => "ff",
        model.dynamic_fff => "fff",
        model.dynamic_sfz => "sfz",
        else => null,
    };
}

test "writes interoperable two-staff MusicXML" {
    var meta: model.DocumentMeta = .{};
    meta.setTitle("A & B");
    meta.setCreator("Composer <Test>");
    const transport: model.Transport = .{ .tempo_bpm = 96 };
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 0, .duration_beats = 4, .pitch = 48, .velocity = 72, .staff = 1, .voice = 1 },
    };
    var lyrics = [_]model.Lyric{.{ .start_beat = 1.5 }};
    lyrics[0].setText("sing & breathe");
    var harmonies = [_]model.Harmony{.{ .start_beat = 0, .root_step = 'B', .root_alter = -1, .bass_step = 'D', .bass_alter = -1 }};
    harmonies[0].setKind("minor-seventh");
    harmonies[0].setText("m7");
    var playback: model.PlaybackBounds = .{ .tempo_base_bpm = 96 };
    playback.tempos[0] = .{ .start_beat = 0, .bpm = 96 };
    playback.tempos[1] = .{ .start_beat = 2, .bpm = 84 };
    playback.tempo_count = 2;
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &lyrics, &harmonies, &.{}, &.{}, &playback);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<work-title>A &amp; B</work-title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<chord/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<staff>2</staff>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<words>sing &amp; breathe</words>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<root-step>B</root-step><root-alter>-1</root-alter>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<kind text=\"m7\">minor-seventh</kind>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<bass-step>D</bass-step><bass-alter>-1</bass-alter>") != null);
    const roundtrip = try @import("../import/musicxml.zig").parse(output[0..len]);
    try std.testing.expectEqual(@as(usize, 2), roundtrip.tempo_count);
    try std.testing.expectApproxEqAbs(@as(f32, 84), roundtrip.tempos[1].bpm, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), roundtrip.tempos[1].start_beat, 0.001);
}

test "round trips an eighth-note pulse with quarter-note playback tempo" {
    var meta: model.DocumentMeta = .{ .tempo_beat_unit = 8 };
    meta.setTitle("Pulse semantics");
    const transport: model.Transport = .{ .tempo_bpm = 147 };
    const notes = [_]model.Note{.{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 61, .velocity = 88, .staff = 0, .voice = 0 }};
    var playback: model.PlaybackBounds = .{ .tempo_base_bpm = 73.5, .tempo_beat_unit = 8 };
    playback.tempos[0] = .{ .start_beat = 0, .bpm = 73.5 };
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &.{}, &.{}, &.{}, &.{}, &playback);
    const xml = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, xml, "<beat-unit>eighth</beat-unit><per-minute>147.000</per-minute>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<sound tempo=\"73.500\"/>") != null);
    const imported = try @import("../import/musicxml.zig").parse(xml);
    try std.testing.expectApproxEqAbs(@as(f32, 147), imported.tempo_bpm, 0.001);
    try std.testing.expectEqual(@as(u8, 8), imported.tempo_beat_unit);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), imported.tempos[0].bpm, 0.001);
}

test "keeps optional vocal guide in a separate export part" {
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const transport: model.Transport = .{};
    const notes = [_]model.Note{
        // Part 0, staff 1: optional vocal-guide silence for the full bar.
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 4, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_vocal_guide | model.note_flag_rest | model.note_flag_measure_rest },
        // Part 1, staff 1: the piano upper staff occupies internal staff 8.
        .{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 88, .staff = 8, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 64, .velocity = 88, .staff = 8, .voice = 0 },
    };
    var lyrics = [_]model.Lyric{.{ .start_beat = 0 }};
    lyrics[0].setText("singer lane");
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &lyrics, &.{}, &.{}, &.{}, &.{});
    const xml = output[0..len];
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, xml, "<part id="));
    try std.testing.expect(std.mem.indexOf(u8, xml, "<part-name>Piano</part-name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<part-name>Vocal guide (optional)</part-name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<direction placement=\"below\"><direction-type><words>singer lane</words>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<backup><duration>1920</duration></backup>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<voice>1</voice>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<note><chord/><pitch>") == null);

    const imported = try @import("../import/musicxml.zig").parse(xml);
    try std.testing.expectEqual(@as(usize, 3), imported.note_count);
    try std.testing.expectEqual(@as(usize, 1), imported.lyric_count);
    var sounding: usize = 0;
    var vocal: usize = 0;
    for (imported.notes[0..imported.note_count]) |note| {
        if ((note.flags & model.note_flag_rest) == 0) sounding += 1;
        if ((note.flags & model.note_flag_vocal_guide) != 0) vocal += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sounding);
    try std.testing.expectEqual(@as(usize, 1), vocal);
}

test "exports preserved flat spelling engraving and semantic spanners" {
    var meta: model.DocumentMeta = .{ .beats_per_measure = 6, .beat_unit = 4, .key_fifths = -5 };
    meta.setTitle("Notation fidelity");
    const transport: model.Transport = .{};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 0.75, .pitch = 73, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'D', .written_alter = -1, .written_octave = 5, .dots = 1, .flags = model.withDynamic(model.withTupletRatio(model.note_flag_explicit_accidental | model.note_flag_tie_start | model.note_flag_beam_begin | model.note_flag_slur_start | model.note_flag_slur_above | model.note_flag_tuplet_start | model.note_flag_staccato | model.note_flag_accent, 3, 2), model.dynamic_mf), .fingering = 4 },
        .{ .stable_id = 2, .start_beat = 0.75, .duration_beats = 0.25, .pitch = 73, .velocity = 90, .staff = 0, .voice = 0, .written_step = 'D', .written_alter = -1, .written_octave = 5, .flags = model.withTupletRatio(model.note_flag_tie_stop | model.note_flag_beam_end | model.note_flag_slur_stop | model.note_flag_tuplet_stop | model.note_flag_fermata, 3, 2) },
    };
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &.{}, &.{}, &.{}, &.{}, &.{});
    const xml = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, xml, "<step>D</step><alter>-1</alter><octave>5</octave>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<dot/><accidental>flat</accidental>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<beam number=\"1\">begin</beam>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<tie type=\"start\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<dynamics><mf/></dynamics>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<actual-notes>3</actual-notes><normal-notes>2</normal-notes>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<slur type=\"start\" placement=\"above\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<staccato/><accent/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<fermata/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<technical><fingering>4</fingering></technical>") != null);
    const imported = try @import("../import/musicxml.zig").parse(xml);
    try std.testing.expectEqual(@as(i8, -1), imported.notes[0].written_alter);
    try std.testing.expectEqual(@as(u8, 1), imported.notes[0].dots);
    try std.testing.expectEqual(model.dynamic_mf, model.dynamic(imported.notes[0].flags));
    try std.testing.expectEqual(@as(u8, 4), imported.notes[0].fingering);
    try std.testing.expectEqual(@as(u8, 3), model.tupletActual(imported.notes[0].flags));
    try std.testing.expect((imported.notes[0].flags & model.note_flag_slur_start) != 0);
    try std.testing.expect((imported.notes[0].flags & model.note_flag_staccato) != 0);
    try std.testing.expect((imported.notes[1].flags & model.note_flag_fermata) != 0);
}

test "round trips explicit dotted and measure rests" {
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const transport: model.Transport = .{};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1.5, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .dots = 1, .flags = model.note_flag_rest },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 4, .pitch = 71, .velocity = 0, .staff = 0, .voice = 0, .flags = model.note_flag_rest | model.note_flag_measure_rest },
    };
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &.{}, &.{}, &.{}, &.{}, &.{});
    const xml = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, xml, "<rest/><duration>720</duration>") != null);
    const imported = try @import("../import/musicxml.zig").parse(xml);
    try std.testing.expectEqual(@as(usize, 2), imported.note_count);
    try std.testing.expect((imported.notes[0].flags & model.note_flag_rest) != 0);
    try std.testing.expectEqual(@as(u8, 1), imported.notes[0].dots);
    try std.testing.expect((imported.notes[1].flags & model.note_flag_measure_rest) != 0);
}

test "preserves authored measure boundaries and mid-score meter changes" {
    const meta: model.DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const transport: model.Transport = .{};
    const notes = [_]model.Note{
        .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 2, .start_beat = 4, .duration_beats = 1, .pitch = 62, .velocity = 90, .staff = 0, .voice = 0 },
        .{ .stable_id = 3, .start_beat = 6, .duration_beats = 1, .pitch = 64, .velocity = 90, .staff = 0, .voice = 0 },
        // Ending exactly on the authored boundary must not synthesize an extra measure.
        .{ .stable_id = 4, .start_beat = 9, .duration_beats = 1, .pitch = 67, .velocity = 90, .staff = 1, .voice = 1 },
    };
    const measures = [_]model.Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1, .beats = 4, .beat_unit = 4 },
        .{ .start_beat = 4, .duration_beats = 2, .number = 2, .beats = 2, .beat_unit = 4 },
        .{ .start_beat = 6, .duration_beats = 4, .number = 3, .beats = 4, .beat_unit = 4 },
    };
    var output: [32 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &.{}, &.{}, &.{}, &measures, &.{});
    const xml = output[0..len];
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, xml, "<measure number="));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, xml, "<beats>4</beats><beat-type>4</beat-type>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, xml, "<beats>2</beats><beat-type>4</beat-type>"));
    const imported = try @import("../import/musicxml.zig").parse(xml);
    try std.testing.expectEqual(@as(usize, 3), imported.measure_count);
    try std.testing.expectEqual(@as(usize, 4), imported.note_count);
    try std.testing.expectEqual(@as(f32, 0), imported.measures[0].start_beat);
    try std.testing.expectEqual(@as(f32, 4), imported.measures[1].start_beat);
    try std.testing.expectEqual(@as(f32, 6), imported.measures[2].start_beat);
    try std.testing.expectEqual(@as(f32, 2), imported.measures[1].duration_beats);
}
