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
const note_dynamic_field_mask: u32 = 0x0f;
pub const dynamic_ppp: u8 = 1;
pub const dynamic_pp: u8 = 2;
pub const dynamic_p: u8 = 3;
pub const dynamic_mp: u8 = 4;
pub const dynamic_mf: u8 = 5;
pub const dynamic_f: u8 = 6;
pub const dynamic_ff: u8 = 7;
pub const dynamic_fff: u8 = 8;
pub const dynamic_sfz: u8 = 9;

/// Semantic notations that do not fit the already-full rhythmic/expression
/// flag word.  Keeping these in their own field preserves MusicXML meaning
/// without overloading fingering or transient editor state.
pub const note_notation_trill: u32 = 1 << 0;
pub const note_notation_turn: u32 = 1 << 1;
pub const note_notation_inverted_turn: u32 = 1 << 2;
pub const note_notation_mordent: u32 = 1 << 3;
pub const note_notation_inverted_mordent: u32 = 1 << 4;
pub const note_notation_arpeggiate: u32 = 1 << 5;
pub const note_notation_arpeggiate_up: u32 = 1 << 6;
pub const note_notation_arpeggiate_down: u32 = 1 << 7;
pub const note_notation_ornament_below: u32 = 1 << 8;
pub const note_notation_grace_slash: u32 = 1 << 9;
const note_grace_following_shift: u5 = 10;
const note_grace_previous_shift: u5 = 17;
const note_grace_percent_mask: u32 = 0x7f;
pub const note_notation_grace_make_time: u32 = 1 << 24;
const note_tremolo_marks_shift: u5 = 25;
const note_tremolo_marks_mask: u32 = 0x0f;
pub const note_notation_ornament_mask: u32 = note_notation_trill | note_notation_turn | note_notation_inverted_turn | note_notation_mordent | note_notation_inverted_mordent;
pub const note_notation_arpeggiate_mask: u32 = note_notation_arpeggiate | note_notation_arpeggiate_up | note_notation_arpeggiate_down;

pub fn withGraceTiming(notations: u32, slash: bool, following_percent: u8, previous_percent: u8, make_time: bool) u32 {
    const timing_mask = note_notation_grace_slash |
        (note_grace_percent_mask << note_grace_following_shift) |
        (note_grace_percent_mask << note_grace_previous_shift) |
        note_notation_grace_make_time;
    var result = notations & ~timing_mask;
    if (slash) result |= note_notation_grace_slash;
    if (make_time) result |= note_notation_grace_make_time;
    result |= @as(u32, @min(following_percent, 100)) << note_grace_following_shift;
    result |= @as(u32, @min(previous_percent, 100)) << note_grace_previous_shift;
    return result;
}

pub fn graceFollowingPercent(note: Note) u8 {
    return @truncate((note.notations >> note_grace_following_shift) & note_grace_percent_mask);
}

pub fn gracePreviousPercent(note: Note) u8 {
    return @truncate((note.notations >> note_grace_previous_shift) & note_grace_percent_mask);
}

/// Preserve MusicXML's single-note tremolo mark count. Attached note beams are
/// separate MusicXML elements and therefore remain in Note.flags.
pub fn withSingleTremolo(notations: u32, marks: u8) u32 {
    return (notations & ~(note_tremolo_marks_mask << note_tremolo_marks_shift)) |
        (@as(u32, @min(marks, 8)) << note_tremolo_marks_shift);
}

pub fn singleTremoloMarks(note: Note) u8 {
    return @truncate((note.notations >> note_tremolo_marks_shift) & note_tremolo_marks_mask);
}

pub fn singleTremoloInterval(note: Note) f32 {
    const marks = singleTremoloMarks(note);
    if (marks == 0) return @max(0.0001, note.duration_beats);
    const subdivisions: u16 = @as(u16, 1) << @intCast(marks);
    return 1.0 / @as(f32, @floatFromInt(subdivisions));
}

pub fn singleTremoloAttackCount(note: Note, performed_duration: f32) usize {
    if (singleTremoloMarks(note) == 0) return 1;
    const safe_duration = @max(0.0001, performed_duration);
    return @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(safe_duration / singleTremoloInterval(note) - 0.0001))));
}

test "single-note tremolo mark count is compact and bounded" {
    const base = note_notation_trill | note_notation_grace_slash;
    const note = Note{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .notations = withSingleTremolo(base, 3) };
    try std.testing.expectEqual(@as(u8, 3), singleTremoloMarks(note));
    try std.testing.expectEqual(base, note.notations & (note_notation_trill | note_notation_grace_slash));
    try std.testing.expectEqual(@as(u8, 8), singleTremoloMarks(.{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .notations = withSingleTremolo(0, 99) }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), singleTremoloInterval(note), 0.0001);
    try std.testing.expectEqual(@as(usize, 8), singleTremoloAttackCount(note, 1));
}

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
    const dynamic_mask: u32 = note_dynamic_field_mask << note_dynamic_shift;
    return (flags & ~dynamic_mask) | (@as(u32, @min(dynamic_code, note_dynamic_field_mask)) << note_dynamic_shift);
}

pub fn dynamic(flags: u32) u8 {
    return @intCast(flags >> note_dynamic_shift);
}

test "withDynamic replaces an existing marking without disturbing notation flags" {
    const notation = note_flag_staccato | note_flag_accent | note_flag_tie_start;
    const first = withDynamic(notation, dynamic_pp);
    const replaced = withDynamic(first, dynamic_ff);
    try std.testing.expectEqual(dynamic_ff, dynamic(replaced));
    try std.testing.expectEqual(notation, replaced & 0x0fff_ffff);
    try std.testing.expectEqual(@as(u8, 0), dynamic(withDynamic(replaced, 0)));
}

/// MusicXML numbers concurrent slurs so a nested or overlapping phrase can be
/// paired with its own stop. One byte is a compact set for numbers 1...8;
/// legacy notes that predate the masks keep their flag-only number-1 meaning.
pub fn slurNumberBit(number: u8) u8 {
    if (number < 1 or number > 8) return 1;
    return @as(u8, 1) << @intCast(number - 1);
}

pub fn slurStartMask(note: Note) u8 {
    if ((note.flags & note_flag_slur_start) == 0) return 0;
    return if (note.slur_start_mask != 0) note.slur_start_mask else 1;
}

pub fn slurStopMask(note: Note) u8 {
    if ((note.flags & note_flag_slur_stop) == 0) return 0;
    return if (note.slur_stop_mask != 0) note.slur_stop_mask else 1;
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

pub const ScoreViewMode = enum(u32) {
    paged,
    continuous,
};

pub const AppView = enum(u32) {
    score,
    controller,
};

pub const ControllerProtocol = enum(u32) {
    midi,
    osc,
};

pub const ControllerBank = enum(u32) {
    pads,
    clips,
    actions,
    user,
};

pub const ControllerAssignmentKind = enum(u8) {
    note,
    drum,
    cc,
    clip,
    action,
};

pub const ControllerBehavior = enum(u8) {
    momentary,
    toggle,
};

/// Compact, platform-independent description of one programmable controller
/// pad. `value` is a note/CC/action number or clip scene; `channel` is a MIDI
/// channel or clip track. Keeping this data in the Flecs UI component lets the
/// exact same editor and mappings run on macOS and iPad.
pub const ControllerAssignment = extern struct {
    kind: ControllerAssignmentKind = .note,
    behavior: ControllerBehavior = .momentary,
    channel: u8 = 0,
    value: u8 = 36,
    color: u8 = 0,
    reserved: [3]u8 = [_]u8{0} ** 3,
};

pub fn defaultControllerAssignments() [16]ControllerAssignment {
    var assignments = [_]ControllerAssignment{.{}} ** 16;
    for (&assignments, 0..) |*assignment, index| {
        assignment.value = @intCast(36 + index);
        assignment.color = @intCast(index / 4);
    }
    return assignments;
}

/// Imported MusicXML keeps the source part index in the high portion of the
/// compact staff byte. Eight local staff slots are available per part, which
/// is enough for the MusicXML staff-number range accepted by the importer and
/// still permits 32 independently selectable parts without enlarging Note.
pub const staff_slots_per_part: u8 = 8;
pub const max_instrument_parts: u32 = 32;
pub const max_score_parts: usize = max_instrument_parts;
pub const score_part_flag_vocal: u32 = 1 << 0;

pub const ScorePart = extern struct {
    source_index: u32 = 0,
    flags: u32 = 0,
    /// General MIDI program number as represented by MusicXML (1...128).
    /// Zero means that the source did not specify one.
    midi_program: u32 = 0,
    name_len: u32 = 0,
    name: [48]u8 = [_]u8{0} ** 48,

    pub fn setName(self: *ScorePart, value: []const u8) void {
        self.name_len = @intCast(@min(value.len, self.name.len));
        @memcpy(self.name[0..self.name_len], value[0..self.name_len]);
    }

    pub fn nameSlice(self: *const ScorePart) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isVocal(self: *const ScorePart) bool {
        return (self.flags & score_part_flag_vocal) != 0;
    }
};

pub fn notePart(note: Note) u32 {
    return @min(@as(u32, note.staff / staff_slots_per_part), max_instrument_parts - 1);
}

pub fn noteLocalStaff(note: Note) u8 {
    return note.staff % staff_slots_per_part;
}

pub fn encodedStaff(part: u32, local_staff: u8) u8 {
    const bounded_part = @min(part, max_instrument_parts - 1);
    const bounded_staff = @min(local_staff, staff_slots_per_part - 1);
    return @intCast(bounded_part * staff_slots_per_part + bounded_staff);
}

pub fn instrumentPartMask(notes: []const Note) u32 {
    var mask: u32 = 0;
    for (notes) |note| {
        if ((note.flags & note_flag_vocal_guide) != 0) continue;
        mask |= @as(u32, 1) << @intCast(notePart(note));
    }
    return if (mask == 0) 1 else mask;
}

pub fn firstInstrumentPart(mask: u32) u32 {
    return @ctz(if (mask == 0) @as(u32, 1) else mask);
}

pub fn instrumentPartOrdinal(mask: u32, part: u32) u32 {
    var ordinal: u32 = 0;
    var index: u32 = 0;
    while (index < max_instrument_parts) : (index += 1) {
        if ((mask & (@as(u32, 1) << @intCast(index))) == 0) continue;
        ordinal += 1;
        if (index == @min(part, max_instrument_parts - 1)) return ordinal;
    }
    return 1;
}

/// Vocal-guide notes remain an independent optional staff. Instrumental notes
/// are visible only when they belong to the selected source part, preventing
/// ensemble imports from being superimposed onto one misleading grand staff.
pub fn noteVisibleInPart(note: Note, selected_part: u32) bool {
    return (note.flags & note_flag_vocal_guide) != 0 or notePart(note) == @min(selected_part, max_instrument_parts - 1);
}

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
    /// Transient editor state; stored as a byte so authored technique data
    /// remains compact in the Flecs component.
    selected: u8 = 0,
    /// MusicXML `<technical><fingering>` value. Zero means the score leaves
    /// the choice to the phrase optimizer; 1...5 is an explicit musician-
    /// authored override that must survive native and MusicXML round trips.
    fingering: u8 = 0,
    /// Bit sets for MusicXML slur numbers 1...8. These occupy the two bytes
    /// that were formerly reserved when the Flecs component was 32 bytes.
    slur_start_mask: u8 = 0,
    slur_stop_mask: u8 = 0,
    flags: u32 = 0,
    /// Ornaments and chord-level notations retained independently from the
    /// packed rhythm/dynamic flags. Versioned persistence migrates old notes
    /// with this field cleared.
    notations: u32 = 0,
};

pub const PerformedNoteRange = struct {
    start: f32,
    end: f32,
};

const GraceGroupTiming = struct {
    raw_total: f32 = 0,
    effective_total: f32 = 0,
    following: bool = false,
};

fn sameGraceLane(candidate: Note, beat: f32, staff: u8, voice: u8) bool {
    return (candidate.flags & note_flag_grace) != 0 and candidate.staff == staff and candidate.voice == voice and @abs(candidate.start_beat - beat) < 0.0001;
}

fn graceReferenceDuration(notes: []const Note, grace: Note, following: bool) f32 {
    if (following) {
        for (notes) |candidate| {
            if ((candidate.flags & (note_flag_grace | note_flag_rest)) != 0 or candidate.staff != grace.staff or candidate.voice != grace.voice) continue;
            if (@abs(candidate.start_beat - grace.start_beat) < 0.0001) return @max(0.01, candidate.duration_beats);
        }
    } else {
        for (notes) |candidate| {
            if ((candidate.flags & (note_flag_grace | note_flag_rest)) != 0 or candidate.staff != grace.staff or candidate.voice != grace.voice) continue;
            if (@abs(candidate.start_beat + candidate.duration_beats - grace.start_beat) < 0.0001) return @max(0.01, candidate.duration_beats);
        }
    }
    return @max(0.125, grace.duration_beats);
}

fn graceRawDuration(notes: []const Note, grace: Note, following: bool) f32 {
    if ((grace.notations & note_notation_grace_make_time) != 0) return @max(0.01, grace.duration_beats);
    const percent = if (following) graceFollowingPercent(grace) else gracePreviousPercent(grace);
    if (percent != 0) return graceReferenceDuration(notes, grace, following) * @as(f32, @floatFromInt(percent)) / 100.0;
    return @max(0.01, grace.duration_beats);
}

fn graceGroupTiming(notes: []const Note, beat: f32, staff: u8, voice: u8) GraceGroupTiming {
    var representative: ?Note = null;
    var explicit_following = false;
    var explicit_previous = false;
    var make_time = false;
    for (notes) |candidate| {
        if (!sameGraceLane(candidate, beat, staff, voice)) continue;
        representative = representative orelse candidate;
        explicit_following = explicit_following or graceFollowingPercent(candidate) != 0;
        explicit_previous = explicit_previous or gracePreviousPercent(candidate) != 0;
        make_time = make_time or (candidate.notations & note_notation_grace_make_time) != 0;
    }
    const sample = representative orelse return .{};
    const following = explicit_following or make_time or (!explicit_previous and beat <= 0.0001);
    var raw_total: f32 = 0;
    for (notes) |candidate| if (sameGraceLane(candidate, beat, staff, voice)) {
        raw_total += graceRawDuration(notes, candidate, following);
    };
    const reference = graceReferenceDuration(notes, sample, following);
    return .{
        .raw_total = raw_total,
        // Keep a playable remnant of the neighboring principal note even when
        // malformed files assign 100% to several consecutive grace attacks.
        .effective_total = @min(raw_total, reference * 0.9),
        .following = following,
    };
}

/// Resolves MusicXML grace playback without changing its authored metric
/// position. Following-time grace groups delay and shorten their principal;
/// previous-time/default mid-score groups shorten the prior note and end on
/// the principal beat. Source order is retained through stable IDs.
pub fn performedNoteRange(notes: []const Note, note: Note) PerformedNoteRange {
    const authored_end = note.start_beat + @max(0.01, note.duration_beats);
    if ((note.flags & note_flag_grace) != 0) {
        const timing = graceGroupTiming(notes, note.start_beat, note.staff, note.voice);
        const scale = if (timing.raw_total > 0.0001) timing.effective_total / timing.raw_total else 1;
        var raw_offset: f32 = 0;
        for (notes) |candidate| {
            if (!sameGraceLane(candidate, note.start_beat, note.staff, note.voice) or candidate.stable_id >= note.stable_id) continue;
            raw_offset += graceRawDuration(notes, candidate, timing.following);
        }
        const duration = graceRawDuration(notes, note, timing.following) * scale;
        const group_start = if (timing.following) note.start_beat else @max(0, note.start_beat - timing.effective_total);
        const start = group_start + raw_offset * scale;
        return .{ .start = start, .end = start + @max(0.005, duration) };
    }

    const following_group = graceGroupTiming(notes, note.start_beat, note.staff, note.voice);
    var start = note.start_beat;
    if (following_group.following) start += following_group.effective_total;

    const previous_group = graceGroupTiming(notes, authored_end, note.staff, note.voice);
    var end = authored_end;
    if (previous_group.raw_total > 0 and !previous_group.following) end -= previous_group.effective_total;
    return .{ .start = start, .end = @max(start + 0.005, end) };
}

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

pub const hairpin_crescendo: u8 = 1;
pub const hairpin_diminuendo: u8 = 2;

pub const hairpin_flag_above: u8 = 1 << 0;
pub const hairpin_flag_vocal: u8 = 1 << 1;
pub const hairpin_flag_niente: u8 = 1 << 2;
pub const hairpin_flag_dashed: u8 = 1 << 3;
pub const hairpin_flag_dotted: u8 = 1 << 4;

/// A numbered MusicXML wedge resolved into one semantic span.  Keeping the
/// complete start/end range independent from notes lets crescendos and
/// diminuendos survive responsive system/page breaks and exchange round trips.
/// `spread` retains MusicXML tenths; zero means the conventional 15-tenth
/// opening. `staff` uses the same encoded source-part/local-staff convention as
/// `Note.staff`, while the vocal flag keeps optional singer directions separate
/// from the selected instrumental workspace.
pub const Hairpin = extern struct {
    start_beat: f32 = 0,
    end_beat: f32 = 0,
    spread: f32 = 15,
    staff: u8 = 0,
    kind: u8 = hairpin_crescendo,
    number: u8 = 1,
    flags: u8 = 0,
};

pub fn hairpinVisibleInPart(hairpin: Hairpin, selected_part: u32, vocal_visible: bool) bool {
    if ((hairpin.flags & hairpin_flag_vocal) != 0) return vocal_visible;
    return @as(u32, hairpin.staff / staff_slots_per_part) == @min(selected_part, max_instrument_parts - 1);
}

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
/// MusicXML 4.0 represents damper and sostenuto pedal marks with `<pedal>`,
/// soft-pedal text with `<words>`, and continuous positions for all three in
/// `<sound>`. The discriminator keeps those exchange semantics independent
/// from platform controller numbers.
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
    /// Packed repeat-barline metadata. The low two bits preserve forward and
    /// backward repeat directions; the upper six retain an authored playback
    /// count (zero means MusicXML's normal two passes). This occupies the byte
    /// that was reserved before repeat semantics were retained.
    repeat: u8 = 0,
    /// Passes on which this alternate-ending measure is performed. Bit zero
    /// is ending 1, bit one ending 2, and so on through MusicXML ending 16.
    ending_mask: u16 = 0,
    ending_flags: u8 = 0,
    ending_reserved: u8 = 0,

    pub fn beatLength(self: Measure) f32 {
        return 4.0 / @as(f32, @floatFromInt(@max(1, self.beat_unit)));
    }

    pub fn nominalBeats(self: Measure) f32 {
        return @as(f32, @floatFromInt(@max(1, self.beats))) * self.beatLength();
    }

    pub fn hasForwardRepeat(self: Measure) bool {
        return (self.repeat & measure_repeat_forward) != 0;
    }

    pub fn hasBackwardRepeat(self: Measure) bool {
        return (self.repeat & measure_repeat_backward) != 0;
    }

    pub fn repeatPasses(self: Measure) u8 {
        if (!self.hasBackwardRepeat()) return 1;
        const authored = self.repeat >> measure_repeat_passes_shift;
        return if (authored == 0) 2 else @max(@as(u8, 2), authored);
    }

    pub fn setRepeatPasses(self: *Measure, passes: u8) void {
        const retained_flags = self.repeat & measure_repeat_flags_mask;
        self.repeat = retained_flags | (@min(@as(u8, 63), @max(@as(u8, 2), passes)) << measure_repeat_passes_shift);
    }

    pub fn endingIncludesPass(self: Measure, pass: u8) bool {
        if (self.ending_mask == 0) return true;
        if (pass == 0 or pass > 16) return false;
        return (self.ending_mask & (@as(u16, 1) << @intCast(pass - 1))) != 0;
    }

    pub fn endingStarts(self: Measure) bool {
        return (self.ending_flags & measure_ending_start) != 0;
    }

    pub fn endingStops(self: Measure) bool {
        return (self.ending_flags & (measure_ending_stop | measure_ending_discontinue)) != 0;
    }
};

pub const measure_repeat_forward: u8 = 1 << 0;
pub const measure_repeat_backward: u8 = 1 << 1;
pub const measure_repeat_flags_mask: u8 = measure_repeat_forward | measure_repeat_backward;
pub const measure_repeat_passes_shift: u3 = 2;
pub const measure_ending_start: u8 = 1 << 0;
pub const measure_ending_stop: u8 = 1 << 1;
pub const measure_ending_discontinue: u8 = 1 << 2;

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

pub const max_tempo_events: usize = 512;

/// An authored tempo transition in quarter-note engine time.  Keeping tempo
/// changes as score data (rather than UI state) preserves rubato through
/// MusicXML/MIDI round trips and lets every platform share one transport.
pub const TempoEvent = extern struct {
    start_beat: f32 = 0,
    bpm: f32 = 72,
};

/// Derived document timing consumed by transport systems. Keeping this in the
/// Flecs world lets a hot-reloaded transport callback stop at the real score
/// boundary without reaching back into host-owned note storage.
pub const PlaybackBounds = extern struct {
    end_beat: f32 = 4,
    /// `Transport.tempo_bpm` is the editable, displayed metronome pulse.
    /// `tempo_base_bpm` and every authored map value are quarter-note engine
    /// rates. Keeping those concepts separate makes, for example, eighth=147
    /// play at 73.5 quarter notes/minute without lying in the score UI.
    tempo_base_bpm: f32 = 72,
    tempo_count: u32 = 1,
    tempo_beat_unit: u32 = 4,
    tempos: [max_tempo_events]TempoEvent = [_]TempoEvent{.{}} ** max_tempo_events,
};

/// Converts a displayed MusicXML metronome pulse to the engine's canonical
/// quarter-note rate. MIDI tempo events and transport integration always use
/// quarter notes, regardless of the note value printed beside the BPM.
pub fn quarterTempoFromPulse(pulse_bpm: f32, beat_unit: u32) f32 {
    const unit = @max(@as(u32, 1), beat_unit);
    return pulse_bpm * 4.0 / @as(f32, @floatFromInt(unit));
}

pub fn pulseTempoFromQuarter(quarter_bpm: f32, beat_unit: u32) f32 {
    const unit = @max(@as(u32, 1), beat_unit);
    return quarter_bpm * @as(f32, @floatFromInt(unit)) / 4.0;
}

pub fn scoreTempoAt(bounds: *const PlaybackBounds, beat: f32) f32 {
    const count = @min(@as(usize, bounds.tempo_count), bounds.tempos.len);
    if (count == 0) return @max(1, bounds.tempo_base_bpm);
    var result = @max(1, bounds.tempos[0].bpm);
    for (bounds.tempos[0..count]) |event| {
        if (event.start_beat > beat + 0.0001) break;
        result = @max(1, event.bpm);
    }
    return result;
}

pub fn effectiveTempoAt(bounds: *const PlaybackBounds, transport: *const Transport, beat: f32) f32 {
    const base = @max(1, bounds.tempo_base_bpm);
    const editable_quarter = quarterTempoFromPulse(@max(1, transport.tempo_bpm), bounds.tempo_beat_unit);
    return scoreTempoAt(bounds, beat) * editable_quarter / base;
}

pub const UiState = extern struct {
    viewport_width: f32 = 1280,
    viewport_height: f32 = 800,
    pixel_ratio: f32 = 1,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    view_start_beat: f32 = 0,
    zoom: f32 = 1,
    /// Fractional vertical offset into the first visible system in continuous
    /// mode. The base beat stays system-aligned; 0...1 provides smooth GPU
    /// panning while preserving deterministic measure/system layout.
    continuous_pan_fraction: f32 = 0,
    tool: Tool = .read,
    input_source: InputSource = .none,
    score_view_mode: ScoreViewMode = .paged,
    focus_score: u32 = 0,
    notice: u32 = 0,
    sidebar_open: u32 = 1,
    keyboard_visible: u32 = 1,
    library_open: u32 = 0,
    sustain_pedal: u32 = 0,
    sostenuto_pedal: u32 = 0,
    soft_pedal: u32 = 0,
    vocal_guide_visible: u32 = 1,
    pedal_guide_visible: u32 = 1,
    /// Edit-mode selection for a score-authored pedal-curve control point.
    /// This is transient UI state; the semantic event remains in the score's
    /// `PedalEvent` array and therefore round-trips through MusicXML/MXL.
    pedal_edit_selected: u32 = 0,
    pedal_edit_kind: u32 = pedal_sustain,
    pedal_edit_beat: f32 = 0,
    /// Source MusicXML instrumental parts represented in this score and the
    /// one currently engraved/practiced. Playback and exchange export retain
    /// every part; these fields control only the focused score workspace.
    instrument_part_mask: u32 = 1,
    selected_part: u32 = 0,
    selected_part_label_len: u32 = 0,
    selected_part_label: [48]u8 = [_]u8{0} ** 48,
    /// Transient native GPU text-entry state. This is intentionally UI-only;
    /// the committed value remains `Transport.tempo_bpm` and exports normally.
    tempo_editing: u32 = 0,
    tempo_edit_value: u32 = 0,
    /// Runtime sampler state supplied by the platform host. The notation core
    /// remains independent of sfizz, while every GPU frontend can present the
    /// same instrument workflow and truthful readiness diagnostics.
    sampler_status: u32 = 0,
    sampler_region_count: u32 = 0,
    sampler_sample_count: u32 = 0,
    sampler_label_len: u32 = 0,
    sampler_label: [48]u8 = [_]u8{0} ** 48,
    /// Runtime input routing supplied by the platform facade. The selected
    /// endpoint name is display-only and never becomes score document state.
    input_device_count: u32 = 0,
    input_label_len: u32 = 0,
    input_label: [48]u8 = [_]u8{0} ** 48,
    /// Independent performance-controller workspace. These values live in the
    /// Flecs UI component so the GPU view and all hot-reloaded systems keep the
    /// same controller state across platform hosts.
    app_view: AppView = .score,
    controller_protocol: ControllerProtocol = .osc,
    controller_bank: ControllerBank = .pads,
    controller_octave: i32 = 3,
    controller_channel: u32 = 0,
    controller_velocity: u32 = 104,
    controller_pressed_pads: u32 = 0,
    controller_pressed_transport: u32 = 0,
    controller_status: u32 = 0,
    controller_target_len: u32 = 0,
    controller_target: [48]u8 = [_]u8{0} ** 48,
    /// Explicit editing mode prevents a sustained musical press from ever
    /// being interpreted as configuration. In edit mode, a pad tap selects it
    /// and the eight inspector cells mutate this mapping without emitting
    /// MIDI or OSC.
    controller_editing: u32 = 0,
    controller_selected_pad: u32 = 0,
    controller_toggled_pads: u32 = 0,
    controller_mapping_revision: u32 = 1,
    controller_assignments: [16]ControllerAssignment = defaultControllerAssignments(),

    pub fn setSelectedPartLabel(self: *UiState, value: []const u8) void {
        self.selected_part_label_len = @intCast(@min(value.len, self.selected_part_label.len));
        @memcpy(self.selected_part_label[0..self.selected_part_label_len], value[0..self.selected_part_label_len]);
    }

    pub fn selectedPartLabel(self: *const UiState) []const u8 {
        return self.selected_part_label[0..self.selected_part_label_len];
    }

    pub fn setSamplerLabel(self: *UiState, value: []const u8) void {
        self.sampler_label_len = @intCast(@min(value.len, self.sampler_label.len));
        @memset(&self.sampler_label, 0);
        @memcpy(self.sampler_label[0..self.sampler_label_len], value[0..self.sampler_label_len]);
    }

    pub fn samplerLabel(self: *const UiState) []const u8 {
        return self.sampler_label[0..self.sampler_label_len];
    }

    pub fn setInputLabel(self: *UiState, value: []const u8) void {
        self.input_label_len = @intCast(@min(value.len, self.input_label.len));
        @memset(&self.input_label, 0);
        @memcpy(self.input_label[0..self.input_label_len], value[0..self.input_label_len]);
    }

    pub fn inputLabel(self: *const UiState) []const u8 {
        return self.input_label[0..self.input_label_len];
    }

    pub fn setControllerTarget(self: *UiState, status: u32, value: []const u8) void {
        self.controller_status = status;
        self.controller_target_len = @intCast(@min(value.len, self.controller_target.len));
        @memset(&self.controller_target, 0);
        @memcpy(self.controller_target[0..self.controller_target_len], value[0..self.controller_target_len]);
    }

    pub fn controllerTarget(self: *const UiState) []const u8 {
        return self.controller_target[0..self.controller_target_len];
    }
};

test "runtime input labels are bounded and clear stale endpoint names" {
    var state: UiState = .{};
    state.setInputLabel("MIDI / Keybaudio Bus 1");
    try std.testing.expectEqualStrings("MIDI / Keybaudio Bus 1", state.inputLabel());

    state.setInputLabel("MIC");
    try std.testing.expectEqualStrings("MIC", state.inputLabel());
    for (state.input_label[state.input_label_len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    state.setInputLabel("012345678901234567890123456789012345678901234567EXTRA");
    try std.testing.expectEqual(@as(u32, state.input_label.len), state.input_label_len);
    try std.testing.expectEqualStrings("012345678901234567890123456789012345678901234567", state.inputLabel());
}

pub const PracticeState = extern struct {
    total_notes: u32 = 0,
    correct_notes: u32 = 0,
    early_notes: u32 = 0,
    late_notes: u32 = 0,
    pitch_errors: u32 = 0,
    /// Played attacks after every distinct expected pitch at the current
    /// onset has already been consumed. These are pitch errors, but keeping a
    /// separate count lets the coach distinguish an incorrect chord tone from
    /// an accidental duplicate/extra key.
    extra_notes: u32 = 0,
    confidence: f32 = 0,
    average_timing_ms: f32 = 0,
    pedal_changes: u32 = 0,
    pedal_errors: u32 = 0,
    /// Authored pedal events whose timing window has elapsed during the
    /// current practice pass. This includes correct, late, and wholly missed
    /// soft/sostenuto/sustain changes.
    expected_pedal_changes: u32 = 0,
    /// Authored pedal events for which no acceptable controller movement was
    /// observed. Unlike `pedal_errors`, this excludes an attempted-but-late
    /// movement so the coach can distinguish absence from timing accuracy.
    missed_pedal_changes: u32 = 0,
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
    /// Printed note value for `Transport.tempo_bpm` (4=quarter, 8=eighth).
    tempo_beat_unit: u8 = 4,

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
        .beat = @as(u32, @intFromFloat(@floor(@max(0, cursor - measure_start) / beat_length))) + 1,
        .measure_start = measure_start,
        .measure_duration = measure_beats,
        .beat_length = beat_length,
    };
}

test "bar beat display is safe immediately before an authored document end" {
    const measures = [_]Measure{.{ .start_beat = 0, .duration_beats = 8, .number = 1, .beats = 4, .beat_unit = 4 }};
    const meta: DocumentMeta = .{ .beats_per_measure = 4, .beat_unit = 4 };
    const position = barBeatAt(&measures, 7.99995, &meta);
    try std.testing.expectEqual(@as(u32, 2), position.bar);
    try std.testing.expectEqual(@as(u32, 1), position.beat);
}

test "portable score components have deterministic layouts" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Note));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Lyric));
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(Harmony));
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Transport));
    try std.testing.expectEqual(@as(usize, 4112), @sizeOf(PlaybackBounds));
    try std.testing.expectEqual(@as(usize, 516), @sizeOf(UiState));
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(PracticeState));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(Measure));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ScorePart));
}

test "encoded staffs retain selectable MusicXML part identity" {
    const upper = Note{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 72, .velocity = 80, .staff = encodedStaff(3, 0), .voice = 0 };
    const lower = Note{ .stable_id = 2, .start_beat = 0, .duration_beats = 1, .pitch = 48, .velocity = 80, .staff = encodedStaff(3, 1), .voice = 1 };
    const other = Note{ .stable_id = 3, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 80, .staff = encodedStaff(7, 0), .voice = 0 };
    const vocal = Note{ .stable_id = 4, .start_beat = 0, .duration_beats = 1, .pitch = 67, .velocity = 0, .staff = encodedStaff(9, 0), .voice = 0, .flags = note_flag_vocal_guide };
    const notes = [_]Note{ upper, lower, other, vocal };
    try std.testing.expectEqual(@as(u32, 3), notePart(upper));
    try std.testing.expectEqual(@as(u8, 1), noteLocalStaff(lower));
    try std.testing.expectEqual((@as(u32, 1) << 3) | (@as(u32, 1) << 7), instrumentPartMask(&notes));
    try std.testing.expectEqual(@as(u32, 3), firstInstrumentPart(instrumentPartMask(&notes)));
    try std.testing.expectEqual(@as(u32, 2), instrumentPartOrdinal(instrumentPartMask(&notes), 7));
    try std.testing.expect(noteVisibleInPart(vocal, 3));
    try std.testing.expect(!noteVisibleInPart(other, 3));
}

test "numbered slurs retain legacy number one and concurrent masks" {
    const legacy: Note = .{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0, .flags = note_flag_slur_start };
    try std.testing.expectEqual(@as(u8, 1), slurStartMask(legacy));
    const concurrent: Note = .{
        .stable_id = 2,
        .start_beat = 1,
        .duration_beats = 1,
        .pitch = 62,
        .velocity = 80,
        .staff = 0,
        .voice = 0,
        .slur_start_mask = slurNumberBit(2) | slurNumberBit(5),
        .flags = note_flag_slur_start,
    };
    try std.testing.expectEqual(@as(u8, 0b0001_0010), slurStartMask(concurrent));
    try std.testing.expectEqual(@as(u8, 1), slurNumberBit(0));
    try std.testing.expectEqual(@as(u8, 1), slurNumberBit(9));
}

test "grace timing steals from the authored neighboring note" {
    const appoggiatura = [_]Note{
        .{ .stable_id = 1, .start_beat = 2, .duration_beats = 0.125, .pitch = 62, .velocity = 72, .staff = 0, .voice = 0, .flags = note_flag_grace, .notations = withGraceTiming(0, false, 25, 0, false) },
        .{ .stable_id = 2, .start_beat = 2, .duration_beats = 1, .pitch = 64, .velocity = 84, .staff = 0, .voice = 0 },
    };
    const grace_range = performedNoteRange(&appoggiatura, appoggiatura[0]);
    const principal_range = performedNoteRange(&appoggiatura, appoggiatura[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 2), grace_range.start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.25), grace_range.end, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.25), principal_range.start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), principal_range.end, 0.0001);

    const acciaccatura = [_]Note{
        .{ .stable_id = 3, .start_beat = 1, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 },
        .{ .stable_id = 4, .start_beat = 2, .duration_beats = 0.125, .pitch = 63, .velocity = 72, .staff = 0, .voice = 0, .flags = note_flag_grace | note_flag_slur_start, .notations = withGraceTiming(0, true, 0, 0, false) },
        .{ .stable_id = 5, .start_beat = 2, .duration_beats = 1, .pitch = 64, .velocity = 84, .staff = 0, .voice = 0 },
    };
    const previous_range = performedNoteRange(&acciaccatura, acciaccatura[0]);
    const short_grace = performedNoteRange(&acciaccatura, acciaccatura[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.875), previous_range.end, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.875), short_grace.start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), short_grace.end, 0.0001);
}

test "authored tempo maps scale around the editable practice baseline" {
    var bounds: PlaybackBounds = .{ .tempo_base_bpm = 120 };
    bounds.tempos[0] = .{ .start_beat = 0, .bpm = 120 };
    bounds.tempos[1] = .{ .start_beat = 8, .bpm = 90 };
    bounds.tempo_count = 2;
    const transport: Transport = .{ .tempo_bpm = 96 };
    try std.testing.expectApproxEqAbs(@as(f32, 96), effectiveTempoAt(&bounds, &transport, 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 72), effectiveTempoAt(&bounds, &transport, 8), 0.001);
}

test "eighth-note metronome pulse preserves quarter-note engine time" {
    var bounds: PlaybackBounds = .{ .tempo_base_bpm = 73.5, .tempo_beat_unit = 8 };
    bounds.tempos[0] = .{ .start_beat = 0, .bpm = 73.5 };
    const transport: Transport = .{ .tempo_bpm = 147 };
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), quarterTempoFromPulse(147, 8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 147), pulseTempoFromQuarter(73.5, 8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 73.5), effectiveTempoAt(&bounds, &transport, 0), 0.001);
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
