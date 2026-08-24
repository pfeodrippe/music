const std = @import("std");
const model = @import("model.zig");

pub const max_history = 512;

const empty_note = model.Note{
    .stable_id = 0,
    .start_beat = 0,
    .duration_beats = 0,
    .pitch = 0,
    .velocity = 0,
    .staff = 0,
    .voice = 0,
};

pub const Kind = enum(u32) {
    insert_note,
    delete_note,
    replace_note,
    insert_pedal,
    delete_pedal,
    replace_pedal,
};

pub const Command = extern struct {
    kind: Kind,
    before: model.Note = empty_note,
    after: model.Note = empty_note,
    before_pedal: model.PedalEvent = .{},
    after_pedal: model.PedalEvent = .{},
};

pub const Journal = struct {
    entries: [max_history]Command = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn push(self: *Journal, command: Command) void {
        if (self.cursor < self.len) self.len = self.cursor;
        if (self.len == self.entries.len) {
            std.mem.copyForwards(Command, self.entries[0 .. self.entries.len - 1], self.entries[1..]);
            self.len -= 1;
            self.cursor -= 1;
        }
        self.entries[self.len] = command;
        self.len += 1;
        self.cursor = self.len;
    }

    pub fn undo(self: *Journal) ?Command {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        return self.entries[self.cursor];
    }

    pub fn redo(self: *Journal) ?Command {
        if (self.cursor >= self.len) return null;
        const result = self.entries[self.cursor];
        self.cursor += 1;
        return result;
    }
};

test "journal truncates the redo branch after a new edit" {
    var journal: Journal = .{};
    const one = model.Note{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 };
    const two = model.Note{ .stable_id = 2, .start_beat = 1, .duration_beats = 1, .pitch = 62, .velocity = 80, .staff = 0, .voice = 0 };
    journal.push(.{ .kind = .insert_note, .before = one, .after = one });
    journal.push(.{ .kind = .insert_note, .before = two, .after = two });
    _ = journal.undo();
    journal.push(.{ .kind = .delete_note, .before = one, .after = one });
    try std.testing.expect(journal.redo() == null);
    try std.testing.expectEqual(@as(usize, 2), journal.len);
}

test "journal interleaves note and pedal edits in one undo order" {
    var journal: Journal = .{};
    const note = model.Note{ .stable_id = 1, .start_beat = 0, .duration_beats = 1, .pitch = 60, .velocity = 80, .staff = 0, .voice = 0 };
    const before = model.PedalEvent{ .start_beat = 1, .pedal = model.pedal_soft, .value = 40, .action = model.pedal_action_start };
    const after = model.PedalEvent{ .start_beat = 1.5, .pedal = model.pedal_soft, .value = 88, .action = model.pedal_action_start };
    journal.push(.{ .kind = .insert_note, .before = note, .after = note });
    journal.push(.{ .kind = .replace_pedal, .before_pedal = before, .after_pedal = after });
    try std.testing.expectEqual(Kind.replace_pedal, (journal.undo() orelse return error.TestUnexpectedResult).kind);
    try std.testing.expectEqual(Kind.insert_note, (journal.undo() orelse return error.TestUnexpectedResult).kind);
    try std.testing.expectEqual(Kind.insert_note, (journal.redo() orelse return error.TestUnexpectedResult).kind);
    try std.testing.expectEqual(Kind.replace_pedal, (journal.redo() orelse return error.TestUnexpectedResult).kind);
}
