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
};

pub fn write(
    output: []u8,
    meta: *const model.DocumentMeta,
    transport: *const model.Transport,
    notes: []const model.Note,
    lyrics: []const model.Lyric,
) Error!usize {
    var builder = Builder{ .output = output };
    try builder.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try builder.append("<score-partwise version=\"4.0\">\n  <work><work-title>");
    try builder.escaped(meta.titleSlice());
    try builder.append("</work-title></work>\n  <identification><creator type=\"composer\">");
    try builder.escaped(meta.creatorSlice());
    try builder.append("</creator><encoding><software>Score</software></encoding></identification>\n");
    try builder.append("  <part-list><score-part id=\"P1\"><part-name>Piano</part-name><score-instrument id=\"P1-I1\"><instrument-name>Acoustic Grand Piano</instrument-name></score-instrument><midi-instrument id=\"P1-I1\"><midi-channel>1</midi-channel><midi-program>1</midi-program></midi-instrument></score-part></part-list>\n  <part id=\"P1\">\n");

    const beats = @max(@as(u8, 1), meta.beats_per_measure);
    const beat_unit = @max(@as(u8, 1), meta.beat_unit);
    const measure_beats = @as(f32, @floatFromInt(beats)) * 4.0 / @as(f32, @floatFromInt(beat_unit));
    const measure_ticks: i64 = @max(1, beatToTick(measure_beats));
    var max_end: f32 = measure_beats;
    for (notes) |note| max_end = @max(max_end, note.start_beat + @max(note.duration_beats, 1.0 / @as(f32, @floatFromInt(divisions))));
    for (lyrics) |lyric| max_end = @max(max_end, lyric.start_beat + 0.001);
    const measure_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(max_end / measure_beats))));

    var segments: [max_export_notes]Segment = undefined;
    for (0..measure_count) |measure_index| {
        try builder.print("    <measure number=\"{d}\">\n", .{measure_index + 1});
        if (measure_index == 0) {
            try builder.print("      <attributes><divisions>{d}</divisions><key><fifths>{d}</fifths></key><time><beats>{d}</beats><beat-type>{d}</beat-type></time><staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef></attributes>\n", .{ divisions, meta.key_fifths, beats, beat_unit });
            try builder.print("      <direction placement=\"above\"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>{d}</per-minute></metronome></direction-type><sound tempo=\"{d}\"/></direction>\n", .{ @as(u32, @intFromFloat(@round(@max(1, transport.tempo_bpm)))), @as(u32, @intFromFloat(@round(@max(1, transport.tempo_bpm)))) });
        }

        const measure_start = @as(i64, @intCast(measure_index)) * measure_ticks;
        const measure_end = measure_start + measure_ticks;
        for (lyrics) |lyric| {
            const lyric_tick = beatToTick(@max(0, lyric.start_beat));
            if (lyric_tick < measure_start or lyric_tick >= measure_end) continue;
            try builder.append("      <direction placement=\"above\"><direction-type><words>");
            try builder.escaped(lyric.textSlice());
            try builder.append("</words></direction-type>");
            try builder.print("<offset>{d}</offset></direction>\n", .{lyric_tick - measure_start});
        }
        var emitted_track = false;
        var emitted_any_note = false;
        for (0..2) |staff_index| {
            var voices = [_]bool{false} ** 256;
            for (notes) |note| {
                if (exportStaff(note.staff) != staff_index + 1) continue;
                const note_start = beatToTick(@max(0, note.start_beat));
                const note_end = note_start + @max(1, beatToTick(@max(note.duration_beats, 1.0 / @as(f32, @floatFromInt(divisions)))));
                if (note_start < measure_end and note_end > measure_start) voices[note.voice] = true;
            }
            for (voices, 0..) |present, voice| {
                if (!present) continue;
                if (emitted_track) try builder.print("      <backup><duration>{d}</duration></backup>\n", .{measure_ticks});
                emitted_track = true;
                const count = collectSegments(&segments, notes, staff_index + 1, @intCast(voice), measure_start, measure_end);
                std.mem.sort(Segment, segments[0..count], {}, segmentLessThan);
                try writeTrack(&builder, segments[0..count], staff_index + 1, voice + 1, measure_ticks);
                emitted_any_note = emitted_any_note or count != 0;
            }
        }
        if (!emitted_any_note) {
            try builder.print("      <note><rest measure=\"yes\"/><duration>{d}</duration><voice>1</voice><staff>1</staff></note>\n", .{measure_ticks});
        }
        try builder.append("    </measure>\n");
    }
    try builder.append("  </part>\n</score-partwise>\n");
    return builder.len;
}

fn beatToTick(beat: f32) i64 {
    return @intFromFloat(@round(beat * @as(f32, @floatFromInt(divisions))));
}

fn exportStaff(source: u8) usize {
    return if ((source & 1) == 0) 1 else 2;
}

fn collectSegments(
    destination: *[max_export_notes]Segment,
    notes: []const model.Note,
    staff: usize,
    voice: u8,
    measure_start: i64,
    measure_end: i64,
) usize {
    var count: usize = 0;
    for (notes) |note| {
        if (exportStaff(note.staff) != staff or note.voice != voice) continue;
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
            .tie_stop = note_start < measure_start,
            .tie_start = note_end > measure_end,
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
    try builder.append("      <note>");
    if (chord) try builder.append("<chord/>");
    if ((segment.note.flags & model.note_flag_vocal_guide) != 0) try builder.append("<cue/>");
    try builder.append("<pitch><step>");
    try builder.append(steps[pitch_class]);
    try builder.append("</step>");
    if (alters[pitch_class] != 0) try builder.print("<alter>{d}</alter>", .{alters[pitch_class]});
    try builder.print("<octave>{d}</octave></pitch><duration>{d}</duration><voice>{d}</voice><staff>{d}</staff>", .{ segment.note.pitch / 12 - 1, segment.duration_tick, voice, staff });
    if (segment.tie_stop) try builder.append("<tie type=\"stop\"/>");
    if (segment.tie_start) try builder.append("<tie type=\"start\"/>");
    if (segment.tie_stop or segment.tie_start) {
        try builder.append("<notations>");
        if (segment.tie_stop) try builder.append("<tied type=\"stop\"/>");
        if (segment.tie_start) try builder.append("<tied type=\"start\"/>");
        try builder.append("</notations>");
    }
    try builder.append("</note>\n");
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
    var output: [16 * 1024]u8 = undefined;
    const len = try write(&output, &meta, &transport, &notes, &lyrics);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<work-title>A &amp; B</work-title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<chord/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<staff>2</staff>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "<words>sing &amp; breathe</words>") != null);
}
