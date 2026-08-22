const std = @import("std");

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
    selected: u32 = 0,
};

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
};

pub const PracticeState = extern struct {
    total_notes: u32 = 0,
    correct_notes: u32 = 0,
    early_notes: u32 = 0,
    late_notes: u32 = 0,
    pitch_errors: u32 = 0,
    confidence: f32 = 0,
    average_timing_ms: f32 = 0,
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
};

test "portable score components have deterministic layouts" {
    try std.testing.expect(@sizeOf(Note) <= 32);
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Transport));
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(UiState));
}
