//! The UI Automation Text pattern for a surface: text ranges over a
//! snapshot of the visible text, so that screen readers can review the
//! screen by character, word, or line.
//!
//! Ranges are UTF-16 offsets into a snapshot taken when the screen reader
//! asks for the document, the selection (the cursor), or a point. Each
//! range is a COM object holding a reference to its snapshot.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Unit = enum(i32) {
    character = 0,
    format = 1,
    word = 2,
    line = 3,
    paragraph = 4,
    page = 5,
    document = 6,
    _,

    /// The unit we actually move by: we have no formatting, and a line is
    /// our paragraph and page.
    fn effective(self: Unit) Unit {
        return switch (self) {
            .character => .character,
            .format, .word => .word,
            .line, .paragraph, .page => .line,
            else => .document,
        };
    }
};

/// The visible text, shared by ranges.
pub const Snapshot = struct {
    refs: std.atomic.Value(u32) = .init(1),
    alloc: Allocator,
    text: [:0]const u16,

    /// The cursor's offset in the text.
    cursor: u32,

    /// The visible part of the terminal's selection, [start, end).
    selection: ?[2]u32 = null,

    /// Where the text's first line is on the screen, and the size of a
    /// cell, for bounding rectangles.
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    cell_width: f64 = 0,
    cell_height: f64 = 0,

    pub fn ref(self: *Snapshot) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    pub fn unref(self: *Snapshot) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.alloc.free(self.text);
        self.alloc.destroy(self);
    }

    fn len(self: *const Snapshot) u32 {
        return @intCast(self.text.len);
    }

    /// Whether a unit starts at an offset.
    fn isBoundary(self: *const Snapshot, pos: u32, unit: Unit) bool {
        if (pos == 0 or pos >= self.len()) return true;
        return switch (unit.effective()) {
            // Not between the two halves of a surrogate pair (an emoji, say).
            .character => !(std.unicode.utf16IsLowSurrogate(self.text[pos]) and
                std.unicode.utf16IsHighSurrogate(self.text[pos - 1])),
            .word => !isSpace(self.text[pos]) and isSpace(self.text[pos - 1]),
            .line => self.text[pos - 1] == '\n',
            else => false,
        };
    }

    /// The start of the unit containing an offset.
    pub fn unitStart(self: *const Snapshot, pos: u32, unit: Unit) u32 {
        var p = @min(pos, self.len());
        // The end of the text belongs to the last unit, unless that ends
        // with a newline (then it starts an empty last line).
        if (p == self.len() and p > 0 and self.text[p - 1] != '\n') p -= 1;
        while (p > 0 and !self.isBoundary(p, unit)) p -= 1;
        return p;
    }

    /// The start of the next unit after an offset, or the end.
    pub fn nextUnit(self: *const Snapshot, pos: u32, unit: Unit) u32 {
        if (pos >= self.len()) return self.len();
        var p = pos + 1;
        while (p < self.len() and !self.isBoundary(p, unit)) p += 1;
        return p;
    }

    /// The start of the unit before the one containing an offset.
    pub fn previousUnit(self: *const Snapshot, pos: u32, unit: Unit) u32 {
        const start = self.unitStart(pos, unit);
        if (start == 0) return 0;
        return self.unitStart(start - 1, unit);
    }

    /// The zero-based line and column of an offset.
    pub fn lineColumn(self: *const Snapshot, pos: u32) struct { line: u32, column: u32 } {
        var line: u32 = 0;
        var line_start: u32 = 0;
        for (self.text[0..@min(pos, self.len())], 0..) |ch, i| {
            if (ch == '\n') {
                line += 1;
                line_start = @intCast(i + 1);
            }
        }
        return .{ .line = line, .column = pos - line_start };
    }

    /// The offset of a line and column, clamped to the text.
    pub fn offsetOf(self: *const Snapshot, line: u32, column: u32) u32 {
        var current: u32 = 0;
        var start: u32 = 0;
        while (current < line) : (current += 1) {
            const nl = std.mem.indexOfScalarPos(u16, self.text, start, '\n') orelse return self.len();
            start = @intCast(nl + 1);
        }
        const end: u32 = if (std.mem.indexOfScalarPos(u16, self.text, start, '\n')) |nl| @intCast(nl) else self.len();
        return @min(start + column, end);
    }
};

fn isSpace(ch: u16) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// A range of a snapshot: [start, end).
pub const Range = struct {
    snapshot: *Snapshot,
    start: u32,
    end: u32,

    /// Move the range by `count` units: it becomes the unit that many
    /// units from the one at its start. Returns how far it moved.
    pub fn move(self: *Range, unit: Unit, count: i32) i32 {
        const s = self.snapshot;
        if (unit.effective() == .document) {
            self.start = 0;
            self.end = s.len();
            return 0;
        }
        var pos = s.unitStart(self.start, unit);
        var moved: i32 = 0;
        while (moved < count) : (moved += 1) {
            const next = s.nextUnit(pos, unit);
            if (next >= s.len()) break;
            pos = next;
        }
        while (moved > count) : (moved -= 1) {
            if (pos == 0) break;
            pos = s.previousUnit(pos, unit);
        }
        self.start = pos;
        self.end = s.nextUnit(pos, unit);
        return moved;
    }

    /// Move one end of the range by `count` units. The other end follows
    /// if they would cross. Returns how far it moved.
    pub fn moveEndpoint(self: *Range, is_start: bool, unit: Unit, count: i32) i32 {
        const s = self.snapshot;
        var pos = if (is_start) self.start else self.end;
        var moved: i32 = 0;
        if (unit.effective() == .document) {
            if (count > 0 and pos < s.len()) {
                pos = s.len();
                moved = 1;
            } else if (count < 0 and pos > 0) {
                pos = 0;
                moved = -1;
            }
        } else {
            while (moved < count and pos < s.len()) : (moved += 1) pos = s.nextUnit(pos, unit);
            while (moved > count and pos > 0) : (moved -= 1) {
                const start = s.unitStart(pos, unit);
                pos = if (start < pos) start else s.previousUnit(pos, unit);
            }
        }
        if (is_start) {
            self.start = pos;
            if (self.end < pos) self.end = pos;
        } else {
            self.end = pos;
            if (self.start > pos) self.start = pos;
        }
        return moved;
    }

    /// Move one end of the range to an endpoint of another range. That
    /// range can be of another snapshot (screen readers mix the
    /// document's range with a newer selection's), so a position past
    /// this one's text is its end. The other end follows if they'd cross.
    pub fn moveEndpointTo(self: *Range, is_start: bool, pos: u32) void {
        const p = @min(pos, self.snapshot.len());
        if (is_start) {
            self.start = p;
            if (self.end < p) self.end = p;
        } else {
            self.end = p;
            if (self.start > p) self.start = p;
        }
    }

    pub fn expand(self: *Range, unit: Unit) void {
        const s = self.snapshot;
        if (unit.effective() == .document) {
            self.start = 0;
            self.end = s.len();
            return;
        }
        self.start = s.unitStart(self.start, unit);
        self.end = s.nextUnit(self.start, unit);
    }
};

test Range {
    const testing = std.testing;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("ab cd\nef gh\n$ ");
    var snapshot: Snapshot = .{ .alloc = testing.allocator, .text = text, .cursor = 14 };

    var r: Range = .{ .snapshot = &snapshot, .start = 1, .end = 1 };
    r.expand(.word);
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);

    r.expand(.line);
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 6), r.end);

    try testing.expectEqual(@as(i32, 1), r.move(.line, 1));
    try testing.expectEqual(@as(u32, 6), r.start);
    try testing.expectEqual(@as(u32, 12), r.end);

    try testing.expectEqual(@as(i32, -1), r.move(.line, -1));
    try testing.expectEqual(@as(u32, 0), r.start);

    // Moving past the end stops at the last unit.
    try testing.expectEqual(@as(i32, 2), r.move(.line, 5));
    try testing.expectEqual(@as(u32, 12), r.start);

    r = .{ .snapshot = &snapshot, .start = 0, .end = 0 };
    try testing.expectEqual(@as(i32, 2), r.moveEndpoint(false, .character, 2));
    try testing.expectEqual(@as(u32, 2), r.end);

    // At the end of the text (the cursor after a prompt), the line is the
    // last one.
    r = .{ .snapshot = &snapshot, .start = 14, .end = 14 };
    r.expand(.line);
    try testing.expectEqual(@as(u32, 12), r.start);
    try testing.expectEqual(@as(u32, 14), r.end);

    try testing.expectEqual(@as(u32, 1), snapshot.lineColumn(7).line);
    try testing.expectEqual(@as(u32, 1), snapshot.lineColumn(7).column);
    try testing.expectEqual(@as(u32, 9), snapshot.offsetOf(1, 3));
    try testing.expectEqual(@as(u32, 11), snapshot.offsetOf(1, 99));
}

test "Range: characters keep surrogate pairs whole" {
    const testing = std.testing;
    // "a😀b": the emoji is two UTF-16 units, at 1 and 2.
    const text = std.unicode.utf8ToUtf16LeStringLiteral("a\u{1F600}b");
    var snapshot: Snapshot = .{ .alloc = testing.allocator, .text = text, .cursor = 0 };

    var r: Range = .{ .snapshot = &snapshot, .start = 0, .end = 0 };
    try testing.expectEqual(@as(i32, 1), r.move(.character, 1));
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);
    try testing.expectEqual(@as(i32, 1), r.move(.character, 1));
    try testing.expectEqual(@as(u32, 3), r.start);
    try testing.expectEqual(@as(i32, -1), r.move(.character, -1));
    try testing.expectEqual(@as(u32, 1), r.start);

    // Inside the pair, the character is the whole emoji.
    r = .{ .snapshot = &snapshot, .start = 2, .end = 2 };
    r.expand(.character);
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);

    // An end moves over the emoji in one step.
    r = .{ .snapshot = &snapshot, .start = 0, .end = 1 };
    try testing.expectEqual(@as(i32, 1), r.moveEndpoint(false, .character, 1));
    try testing.expectEqual(@as(u32, 3), r.end);
}

test "Range: words, endpoints and the document" {
    const testing = std.testing;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("one  two\nthree");
    var snapshot: Snapshot = .{ .alloc = testing.allocator, .text = text, .cursor = 0 };

    // Words start after spaces and newlines; moving back by words too.
    var r: Range = .{ .snapshot = &snapshot, .start = 0, .end = 0 };
    try testing.expectEqual(@as(i32, 2), r.move(.word, 2));
    try testing.expectEqual(@as(u32, 9), r.start);
    try testing.expectEqual(@as(u32, 14), r.end);
    try testing.expectEqual(@as(i32, -1), r.move(.word, -1));
    try testing.expectEqual(@as(u32, 5), r.start);
    try testing.expectEqual(@as(u32, 9), r.end);
    // Format and paragraph move like word and line.
    try testing.expectEqual(@as(i32, -1), r.move(.format, -1));
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(i32, 1), r.move(.paragraph, 1));
    try testing.expectEqual(@as(u32, 9), r.start);

    // Moving the start past the end takes the end with it.
    r = .{ .snapshot = &snapshot, .start = 0, .end = 2 };
    try testing.expectEqual(@as(i32, 1), r.moveEndpoint(true, .word, 1));
    try testing.expectEqual(@as(u32, 5), r.start);
    try testing.expectEqual(@as(u32, 5), r.end);
    // And the end before the start takes the start.
    try testing.expectEqual(@as(i32, -1), r.moveEndpoint(false, .line, -1));
    try testing.expectEqual(@as(u32, 0), r.end);
    try testing.expectEqual(@as(u32, 0), r.start);

    // The document unit is the whole text, and its endpoints jump.
    try testing.expectEqual(@as(i32, 0), r.move(.document, 3));
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 14), r.end);
    r = .{ .snapshot = &snapshot, .start = 4, .end = 6 };
    try testing.expectEqual(@as(i32, 1), r.moveEndpoint(false, .document, 1));
    try testing.expectEqual(@as(u32, 14), r.end);
    try testing.expectEqual(@as(i32, 0), r.moveEndpoint(false, .document, 1));
    try testing.expectEqual(@as(i32, -1), r.moveEndpoint(true, .document, -1));
    try testing.expectEqual(@as(u32, 0), r.start);
}

test "Range: an empty screen" {
    const testing = std.testing;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("");
    var snapshot: Snapshot = .{ .alloc = testing.allocator, .text = text, .cursor = 0 };
    var r: Range = .{ .snapshot = &snapshot, .start = 0, .end = 0 };
    for ([_]Unit{ .character, .word, .line, .document }) |unit| {
        try testing.expectEqual(@as(i32, 0), r.move(unit, 1));
        try testing.expectEqual(@as(i32, 0), r.move(unit, -1));
        r.expand(unit);
        try testing.expectEqual(@as(u32, 0), r.start);
        try testing.expectEqual(@as(u32, 0), r.end);
        try testing.expectEqual(@as(i32, 0), r.moveEndpoint(false, unit, 1));
    }
    try testing.expectEqual(@as(u32, 0), snapshot.offsetOf(3, 3));
}

test "Range: endpoints from another snapshot" {
    const testing = std.testing;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("ab cd");
    var snapshot: Snapshot = .{ .alloc = testing.allocator, .text = text, .cursor = 0 };
    var r: Range = .{ .snapshot = &snapshot, .start = 1, .end = 3 };
    r.moveEndpointTo(false, 4);
    try testing.expectEqual([2]u32{ 1, 4 }, [2]u32{ r.start, r.end });
    // A newer, longer screen's end is this one's.
    r.moveEndpointTo(false, 200);
    try testing.expectEqual([2]u32{ 1, 5 }, [2]u32{ r.start, r.end });
    r.moveEndpointTo(true, 200);
    try testing.expectEqual([2]u32{ 5, 5 }, [2]u32{ r.start, r.end });
    // The other end follows when they'd cross.
    r.moveEndpointTo(false, 2);
    try testing.expectEqual([2]u32{ 2, 2 }, [2]u32{ r.start, r.end });
}
