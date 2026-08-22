const std = @import("std");

pub const note_flag_vocal_guide: u32 = 1 << 0;
pub const note_flag_tie_start: u32 = 1 << 1;
pub const note_flag_tie_stop: u32 = 1 << 2;
pub const note_flag_beam_begin: u32 = 1 << 3;
pub const note_flag_beam_continue: u32 = 1 << 4;
pub const note_flag_beam_end: u32 = 1 << 5;
pub const note_flag_explicit_accidental: u32 = 1 << 6;
pub const note_flag_grace: u32 = 1 << 7;
/// Rhythmic rest event. Rests share compact score-event storage with notes so
/// staff, voice, onset, duration, dots, and stable edit identity are retained.
pub const note_flag_rest: u32 = 1 << 8;
pub const note_flag_measure_rest: u32 = 1 << 9;
pub const note_flag_staccato: u32 = 1 << 10;
pub const note_flag_accent: u32 = 1 << 11;
pub const note_flag_tenuto: u32 = 1 << 12;
pub const note_flag_marcato: u32 = 1 << 13;
pub const note_flag_fermata: u32 = 1 << 14;
pub const note_flag_slur_start: u32 = 1 << 15;
pub const note_flag_slur_stop: u32 = 1 << 16;
pub const note_flag_slur_above: u32 = 1 << 17;
pub const note_flag_tuplet_start: u32 = 1 << 18;
pub const note_flag_tuplet_stop: u32 = 1 << 19;
pub const note_flag_beam_mask: u32 = note_flag_beam_begin | note_flag_beam_continue | note_flag_beam_end;
const note_tuplet_actual_shift: u5 = 20;
const note_tuplet_normal_shift: u5 = 24;
const note_tuplet_field_mask: u32 = 0x0f;
const note_dynamic_shift: u5 = 28;
pub const dynamic_ppp: u8 = 1;
pub const dynamic_pp: u8 = 2;
pub const dynamic_p: u8 = 3;
pub const dynamic_mp: u8 = 4;
pub const dynamic_mf: u8 = 5;
pub const dynamic_f: u8 = 6;
pub const dynamic_ff: u8 = 7;
pub const dynamic_fff: u8 = 8;
pub const dynamic_sfz: u8 = 9;

pub fn withTupletRatio(flags: u32, actual: u8, normal: u8) u32 {
    return flags | (@as(u32, @min(actual, 15)) << note_tuplet_actual_shift) | (@as(u32, @min(normal, 15)) << note_tuplet_normal_shift);
}

pub fn tupletActual(flags: u32) u8 {
    return @intCast((flags >> note_tuplet_actual_shift) & note_tuplet_field_mask);
}

pub fn tupletNormal(flags: u32) u8 {
    return @intCast((flags >> note_tuplet_normal_shift) & note_tuplet_field_mask);
}

pub fn withDynamic(flags: u32, dynamic_code: u8) u32 {
    return flags | (@as(u32, @min(dynamic_code, 15)) << note_dynamic_shift);
}

pub fn dynamic(flags: u32) u8 {
    return @intCast(flags >> note_dynamic_shift);
}

pub const Tool = enum(u32) {
    read,
    edit,
    annotate,
    practice,
};

pub const InputSource = enum(u32) {
    none,
    midi,
    microphone,
};

pub const Note = extern struct {
    stable_id: u64,
    start_beat: f32,
    duration_beats: f32,
    pitch: u8,
    velocity: u8,
    staff: u8,
    voice: u8,
    /// Original MusicXML pitch spelling. A zero step means generated/MIDI
    /// content whose spelling should be derived from pitch and key.
    written_step: u8 = 0,
    written_alter: i8 = 0,
    written_octave: i8 = -1,
    dots: u8 = 0,
    selected: u32 = 0,
    flags: u32 = 0,
};

pub const Lyric = extern struct {
    start_beat: f32 = 0,
    text_len: u32 = 0,
    text: [80]u8 = [_]u8{0} ** 80,

    pub fn setText(self: *Lyric, value: []const u8) void {
        self.text_len = @intCast(@min(value.len, self.text.len));
        @memcpy(self.text[0..self.text_len], value[0..self.text_len]);
    }

    pub fn textSlice(self: *const Lyric) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Harmony = extern struct {
    start_beat: f32 = 0,
    root_step: u8 = 'C',
    root_alter: i8 = 0,
    bass_step: u8 = 0,
    bass_alter: i8 = 0,
    inversion: i8 = -1,
    kind_len: u8 = 0,
    text_len: u8 = 0,
    reserved: u8 = 0,
    kind: [32]u8 = [_]u8{0} ** 32,
    text: [24]u8 = [_]u8{0} ** 24,

    pub fn setKind(self: *Harmony, value: []const u8) void {
        self.kind_len = @intCast(@min(value.len, self.kind.len));
        @memcpy(self.kind[0..self.kind_len], value[0..self.kind_len]);
    }

    pub fn setText(self: *Harmony, value: []const u8) void {
        self.text_len = @intCast(@min(value.len, self.text.len));
        @memcpy(self.text[0..self.text_len], value[0..self.text_len]);
    }

    pub fn kindSlice(self: *const Harmony) []const u8 {
        return self.kind[0..self.kind_len];
    }

    pub fn textSlice(self: *const Harmony) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const pedal_sustain: u8 = 0;
pub const pedal_sostenuto: u8 = 1;
pub const pedal_soft: u8 = 2;

pub const pedal_action_start: u8 = 1;
pub const pedal_action_stop: u8 = 2;
pub const pedal_action_change: u8 = 3;
pub const pedal_action_continue: u8 = 4;
pub const pedal_action_resume: u8 = 5;
pub const pedal_action_discontinue: u8 = 6;

pub const pedal_flag_line: u8 = 1 << 0;
pub const pedal_flag_sign: u8 = 1 << 1;

/// A score-authored pedal transition. `value` is MIDI-compatible so the same
/// event can drive notation guidance, practice comparison, and sampler CCs.
/// MusicXML currently standardizes the sustain pedal direction; the pedal
/// discriminator keeps the core ready for imported/edited sostenuto and soft
/// automation without baking platform controller details into the document.
pub const PedalEvent = extern struct {
    start_beat: f32 = 0,
    pedal: u8 = pedal_sustain,
    value: u8 = 0,
    action: u8 = pedal_action_stop,
    flags: u8 = 0,
};

/// One imported notation measure in quarter-note engine time.  The complete
/// map is document data: it preserves pickups, irregular bars, source measure
/// numbers, and every mid-score meter change independently from the notes that
/// happen to have been recognized inside the measure.
pub const Measure = extern struct {
    start_beat: f32 = 0,
    duration_beats: f32 = 4,
    number: u32 = 1,
    beats: u8 = 4,
    beat_unit: u8 = 4,
    implicit: u8 = 0,
    reserved: u8 = 0,

    pub fn beatLength(self: Measure) f32 {
        return 4.0 / @as(f32, @floatFromInt(@max(1, self.beat_unit)));
    }

    pub fn nominalBeats(self: Measure) f32 {
        return @as(f32, @floatFromInt(@max(1, self.beats))) * self.beatLength();
    }
};

/// Finds the authored measure containing `beat`. Exact boundaries belong to
/// the following measure, which keeps bar/beat display and click accents
/// stable when the transport lands precisely on a barline.
pub fn measureIndexAt(measures: []const Measure, beat: f32) ?usize {
    var index = measures.len;
    while (index != 0) {
        index -= 1;
        const measure = measures[index];
        if (beat + 0.0001 < measure.start_beat) continue;
        if (beat + 0.0001 < measure.start_beat + @max(0.0001, measure.duration_beats)) return index;
        return null;
    }
    return null;
}

pub const Transport = extern struct {
    cursor_beat: f32 = 0,
    tempo_bpm: f32 = 72,
    loop_start: f32 = 0,
    loop_end: f32 = 8,
    playing: u32 = 0,
    recording: u32 = 0,
    loop_enabled: u32 = 0,
    count_in_bars: u32 = 1,
    metronome_enabled: u32 = 1,
};

/// Derived document timing consumed by transport systems. Keeping this in the
/// Flecs world lets a hot-reloaded transport callback stop at the real score
/// boundary without reaching back into host-owned note storage.
pub const PlaybackBounds = extern struct {
    end_beat: f32 = 4,
};

pub const UiState = extern struct {
    viewport_width: f32 = 1280,
    viewport_height: f32 = 800,
    pixel_ratio: f32 = 1,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    view_start_beat: f32 = 0,
    zoom: f32 = 1,
    tool: Tool = .read,
    input_source: InputSource = .none,
    notice: u32 = 0,
    sidebar_open: u32 = 1,
    keyboard_visible: u32 = 1,
    library_open: u32 = 0,
    sustain_pedal: u32 = 0,
    sostenuto_pedal: u32 = 0,
    soft_pedal: u32 = 0,
    vocal_guide_visible: u32 = 1,
    pedal_guide_visible: u32 = 1,
    /// Transient native GPU text-entry state. This is intentionally UI-only;
    /// the committed value remains `Transport.tempo_bpm` and exports normally.
    tempo_editing: u32 = 0,
    tempo_edit_value: u32 = 0,
};

pub const PracticeState = extern struct {
    total_notes: u32 = 0,
    correct_notes: u32 = 0,
    early_notes: u32 = 0,
    late_notes: u32 = 0,
    pitch_errors: u32 = 0,
    confidence: f32 = 0,
    average_timing_ms: f32 = 0,
    pedal_changes: u32 = 0,
    pedal_errors: u32 = 0,
    last_pedal_timing_ms: f32 = 0,
};

pub const DocumentMeta = extern struct {
    title: [96]u8 = [_]u8{0} ** 96,
    creator: [96]u8 = [_]u8{0} ** 96,
    title_len: u32 = 0,
    creator_len: u32 = 0,
    source_kind: u32 = 0,
    import_warnings: u32 = 0,
    beats_per_measure: u8 = 4,
    beat_unit: u8 = 4,
    key_fifths: i8 = 0,
    reserved: u8 = 0,

    pub fn setTitle(self: *DocumentMeta, value: []const u8) void {
        self.title_len = @intCast(@min(value.len, self.title.len));
        @memcpy(self.title[0..self.title_len], value[0..self.title_len]);
    }

    pub fn setCreator(self: *DocumentMeta, value: []const u8) void {
        self.creator_len = @intCast(@min(value.len, self.creator.len));
        @memcpy(self.creator[0..self.creator_len], value[0..self.creator_len]);
    }

    pub fn titleSlice(self: *const DocumentMeta) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn creatorSlice(self: *const DocumentMeta) []const u8 {
        return self.creator[0..self.creator_len];
    }

    /// Duration of one notated beat in the engine's quarter-note units.
    pub fn beatLength(self: *const DocumentMeta) f32 {
        return 4.0 / @as(f32, @floatFromInt(@max(1, self.beat_unit)));
    }

    /// Duration of a complete measure in the engine's quarter-note units.
    pub fn measureBeats(self: *const DocumentMeta) f32 {
        return @as(f32, @floatFromInt(@max(1, self.beats_per_measure))) * self.beatLength();
    }

    /// Keep each system measure-complete while targeting at most nine
    /// quarter-note units of readable music. This prevents fractional bars at
    /// system endings in meters such as 3/8 and 6/8.
    pub fn systemBeats(self: *const DocumentMeta) f32 {
        const measure = self.measureBeats();
        const measures: u32 = @max(1, @as(u32, @intFromFloat(@floor(9.0 / measure))));
        return measure * @as(f32, @floatFromInt(measures));
    }

    pub fn pageBeats(self: *const DocumentMeta) f32 {
        return self.systemBeats() * 2;
    }

    pub fn pageStart(self: *const DocumentMeta, view_start_beat: f32) f32 {
        const span = self.pageBeats();
        return @floor(@max(0, view_start_beat) / span) * span;
    }
};

pub const BarBeat = struct {
    bar: u32,
    beat: u32,
    measure_start: f32,
    measure_duration: f32,
    beat_length: f32,
};

/// Converts transport time to authored bar/beat labels. Documents without an
/// imported map retain the generated-score fixed-meter behavior.
pub fn barBeatAt(measures: []const Measure, cursor_beat: f32, meta: *const DocumentMeta) BarBeat {
    const cursor = @max(0, cursor_beat);
    if (measureIndexAt(measures, cursor)) |index| {
        const measure = measures[index];
        const beat_length = measure.beatLength();
        return .{
            .bar = measure.number,
            .beat = @as(u32, @intFromFloat(@floor(@max(0, cursor - measure.start_beat) / beat_length))) + 1,
            .measure_start = measure.start_beat,
            .measure_duration = measure.duration_beats,
            .beat_length = beat_length,
        };
    }
    const measure_beats = meta.measureBeats();
    const beat_length = meta.beatLength();
    var origin: f32 = 0;
    var first_bar: u32 = 1;
    if (measures.len != 0) {
        const last = measures[measures.len - 1];
        origin = last.start_beat + @max(0.0001, last.duration_beats);
        first_bar = last.number + 1;
    }
    const relative = @max(0, cursor - origin);
    const extension: u32 = @intFromFloat(@floor(relative / measure_beats));
    const measure_start = origin + @as(f32, @floatFromInt(extension)) * measure_beats;
    return .{
        .bar = first_bar + extension,
        .beat = @as(u32, @intFromFloat(@floor((cursor - measure_start) / beat_length))) + 1,
        .measure_start = measure_start,
        .measure_duration = measure_beats,
        .beat_length = beat_length,
    };
}

test "portable score components have deterministic layouts" {
    try std.testing.expect(@sizeOf(Note) <= 32);
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Lyric));
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(Harmony));
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Transport));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(PlaybackBounds));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(UiState));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Measure));
}

test "measure lookup assigns exact barlines to the following measure" {
    const measures = [_]Measure{
        .{ .start_beat = 0, .duration_beats = 4, .number = 1 },
        .{ .start_beat = 4, .duration_beats = 2, .number = 2, .beats = 2 },
        .{ .start_beat = 6, .duration_beats = 4, .number = 3 },
    };
    try std.testing.expectEqual(@as(?usize, 0), measureIndexAt(&measures, 3.999));
    try std.testing.expectEqual(@as(?usize, 1), measureIndexAt(&measures, 4));
    try std.testing.expectEqual(@as(?usize, 2), measureIndexAt(&measures, 6));
    try std.testing.expectEqual(@as(?usize, null), measureIndexAt(&measures, 10.5));
    const meta: DocumentMeta = .{};
    try std.testing.expectEqual(@as(u32, 2), barBeatAt(&measures, 4, &meta).bar);
    try std.testing.expectEqual(@as(u32, 1), barBeatAt(&measures, 4, &meta).beat);
    try std.testing.expectEqual(@as(u32, 3), barBeatAt(&measures, 7, &meta).bar);
    try std.testing.expectEqual(@as(u32, 2), barBeatAt(&measures, 7, &meta).beat);
    try std.testing.expectEqual(@as(u32, 4), barBeatAt(&measures, 10, &meta).bar);
}

test "eighth-note meters convert to quarter-note engine time" {
    const three_eight: DocumentMeta = .{ .beats_per_measure = 3, .beat_unit = 8 };
    const six_eight: DocumentMeta = .{ .beats_per_measure = 6, .beat_unit = 8 };
    try std.testing.expectEqual(@as(f32, 0.5), three_eight.beatLength());
    try std.testing.expectEqual(@as(f32, 1.5), three_eight.measureBeats());
    try std.testing.expectEqual(@as(f32, 9), three_eight.systemBeats());
    try std.testing.expectEqual(@as(f32, 18), three_eight.pageBeats());
    try std.testing.expectEqual(@as(f32, 3), six_eight.measureBeats());
    try std.testing.expectEqual(@as(f32, 9), six_eight.systemBeats());
}
