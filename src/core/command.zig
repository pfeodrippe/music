const std = @import("std");
const model = @import("model.zig");

pub const max_history = 512;

pub const Kind = enum(u32) { insert_note, delete_note, replace_note };

pub const Command = extern struct {
    kind: Kind,
    before: model.Note,
    after: model.Note,
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
