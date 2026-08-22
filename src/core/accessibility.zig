const model = @import("model.zig");
const ui = @import("ui.zig");

pub const max_items = 32;

pub const Role = enum(u32) {
    document = 0,
    button = 1,
    tab = 2,
};

pub const Flag = struct {
    pub const selected: u32 = 1 << 0;
    pub const pressed: u32 = 1 << 1;
    pub const toggle: u32 = 1 << 2;
};

pub const Id = struct {
    pub const document: u32 = 1;
    pub const input: u32 = 2;
    pub const save: u32 = 3;
    pub const import_score: u32 = 4;
    pub const record: u32 = 5;
    pub const play: u32 = 6;
    pub const loop: u32 = 7;
    pub const metronome: u32 = 8;
    pub const tempo_down: u32 = 9;
    pub const tempo_up: u32 = 10;
    pub const replay: u32 = 11;
    pub const keyboard: u32 = 12;
    pub const library: u32 = 13;
    pub const library_close: u32 = 14;
    pub const library_first: u32 = 15;
    pub const vocal_guide: u32 = 17;
    pub const pedal_guide: u32 = 18;
    pub const export_take: u32 = 19;
    pub const tool_first: u32 = 20;
    pub const page_previous: u32 = 24;
    pub const page_next: u32 = 25;
    pub const tempo_value: u32 = 26;
    pub const view_mode: u32 = 27;
    pub const zoom_down: u32 = 28;
    pub const zoom_up: u32 = 29;
    pub const focus_score: u32 = 30;
};

pub const Item = extern struct {
    id: u32,
    role: Role,
    rect: [4]f32,
    label_len: u32,
    flags: u32,
    label: [48]u8,

    pub fn labelSlice(self: *const Item) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Snapshot = struct {
    items: [max_items]Item = undefined,
    len: usize = 0,

    pub fn build(self: *Snapshot, state: *const model.UiState, transport: *const model.Transport, meta: *const model.DocumentMeta) void {
        self.len = 0;
        const layout = ui.Layout.calculateForState(state);
        self.add(Id.document, .document, layout.stage, meta.titleSlice(), 0);
        if (state.library_open != 0) {
            self.add(Id.library_close, .button, layout.library_close, "Close score library", 0);
            self.add(Id.library_first, .button, layout.library_items[0], "Open Minuet in G major by J. S. Bach", 0);
            self.add(Id.library_first + 1, .button, layout.library_items[1], "Open Fur Elise by Ludwig van Beethoven", 0);
            return;
        }
        if (layout.library_trigger.width > 0) self.add(Id.library, .button, layout.library_trigger, "Open score library", 0);
        if (layout.input_quick.width > 0) {
            self.add(Id.input, .button, layout.input_quick, "Set up music input", 0);
        } else if (layout.input_setup.width > 0) {
            self.add(Id.input, .button, layout.input_setup, "Set up music input", 0);
        }
        self.add(Id.save, .button, layout.export_score, "Export score or MIDI", 0);
        self.add(Id.import_score, .button, layout.import_score, "Import score", 0);
        self.add(Id.record, .button, layout.record, if (transport.recording != 0) "Stop recording" else "Start recording", Flag.toggle | (if (transport.recording != 0) Flag.pressed else 0));
        self.add(Id.play, .button, layout.play, if (transport.playing != 0) "Pause score" else "Play score", Flag.toggle | (if (transport.playing != 0) Flag.pressed else 0));
        if (layout.loop_toggle.width > 0) self.add(Id.loop, .button, layout.loop_toggle, "Loop current measure", Flag.toggle | (if (transport.loop_enabled != 0) Flag.pressed else 0));
        if (layout.metronome_toggle.width > 0) self.add(Id.metronome, .button, layout.metronome_toggle, "Metronome click", Flag.toggle | (if (transport.metronome_enabled != 0) Flag.pressed else 0));
        self.add(Id.keyboard, .button, layout.keyboard_toggle, if (state.keyboard_visible != 0) "Hide guided piano keyboard" else "Show guided piano keyboard", Flag.toggle | (if (state.keyboard_visible != 0) Flag.pressed else 0));
        if (layout.vocal_guide_toggle.width > 0) self.add(Id.vocal_guide, .button, layout.vocal_guide_toggle, if (state.vocal_guide_visible != 0) "Hide vocal guide" else "Show vocal guide", Flag.toggle | (if (state.vocal_guide_visible != 0) Flag.pressed else 0));
        if (layout.pedal_guide_toggle.width > 0) self.add(Id.pedal_guide, .button, layout.pedal_guide_toggle, if (state.pedal_guide_visible != 0) "Hide pedal guidance" else "Show pedal guidance", Flag.toggle | (if (state.pedal_guide_visible != 0) Flag.pressed else 0));
        if (layout.tempo_minus.width > 0) {
            self.add(Id.tempo_down, .button, layout.tempo_minus, "Decrease tempo", 0);
            self.add(Id.tempo_up, .button, layout.tempo_plus, "Increase tempo", 0);
        }
        self.add(Id.tempo_value, .button, layout.tempo_value, if (state.tempo_editing != 0) "Editing tempo; type 30 to 240 and press Enter" else "Edit tempo", 0);
        if (layout.view_mode_toggle.width > 0) self.add(Id.view_mode, .button, layout.view_mode_toggle, switch (state.score_view_mode) {
            .paged => "Use continuous score view",
            .continuous => "Use two-page score view",
            .spread => "Use paged score view",
        }, 0);
        if (layout.zoom_minus.width > 0) {
            self.add(Id.zoom_down, .button, layout.zoom_minus, "Zoom score out", 0);
            self.add(Id.zoom_up, .button, layout.zoom_plus, "Zoom score in", 0);
        }
        if (layout.focus_toggle.width > 0) self.add(Id.focus_score, .button, layout.focus_toggle, if (state.focus_score != 0) "Exit score focus mode" else "Enter score focus mode", Flag.toggle | (if (state.focus_score != 0) Flag.pressed else 0));
        if (layout.replay_take.width > 0) self.add(Id.replay, .button, layout.replay_take, "Replay latest audio and MIDI take", 0);
        if (layout.export_take.width > 0) self.add(Id.export_take, .button, layout.export_take, "Export latest MIDI take", 0);
        self.add(Id.page_previous, .button, layout.page_previous, "Previous score page", 0);
        self.add(Id.page_next, .button, layout.page_next, "Next score page", 0);
        const tool_labels = [_][]const u8{ "Read score", "Edit notes", "Draw annotation", "Practice and assess" };
        for (layout.tool_buttons, 0..) |button, index| {
            const flags = if (index == @intFromEnum(state.tool)) Flag.selected else 0;
            self.add(Id.tool_first + @as(u32, @intCast(index)), .tab, button, tool_labels[index], flags);
        }
    }

    fn add(self: *Snapshot, id: u32, role: Role, rect: ui.Rect, label: []const u8, flags: u32) void {
        if (self.len == self.items.len or rect.width <= 0 or rect.height <= 0) return;
        var item = Item{
            .id = id,
            .role = role,
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .label_len = @intCast(@min(label.len, 48)),
            .flags = flags,
            .label = [_]u8{0} ** 48,
        };
        @memcpy(item.label[0..item.label_len], label[0..item.label_len]);
        self.items[self.len] = item;
        self.len += 1;
    }
};

test "accessibility snapshot mirrors responsive GPU controls" {
    var snapshot: Snapshot = .{};
    var state = model.UiState{ .viewport_width = 1280, .viewport_height = 800 };
    var transport: model.Transport = .{};
    var meta: model.DocumentMeta = .{};
    meta.setTitle("Accessible score");
    snapshot.build(&state, &transport, &meta);
    try @import("std").testing.expect(snapshot.len >= 12);
    try @import("std").testing.expectEqualStrings("Accessible score", snapshot.items[0].labelSlice());
    var found_previous_page = false;
    var found_next_page = false;
    for (snapshot.items[0..snapshot.len]) |item| {
        found_previous_page = found_previous_page or item.id == Id.page_previous;
        found_next_page = found_next_page or item.id == Id.page_next;
    }
    try @import("std").testing.expect(found_previous_page);
    try @import("std").testing.expect(found_next_page);
    state.viewport_width = 390;
    snapshot.build(&state, &transport, &meta);
    try @import("std").testing.expect(snapshot.len >= 8);
}
