//! The compiled (binary) terminfo format that `tic` produces and curses
//! libraries read, so that we can install a terminfo database where `tic`
//! isn't available, such as when building on Windows (where MSYS2 and Git
//! for Windows programs read it).
//!
//! Background: term(5), https://invisible-island.net/ncurses/man/term.5.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("Source.zig");
const caps = @import("caps.zig");

/// The legacy format's magic number, with 16-bit numbers.
const magic: i16 = 0o432;

/// The format's values for a capability that's absent or canceled.
const absent: i16 = -1;
const canceled: i16 = -2;

pub const Error = Allocator.Error || std.Io.Writer.Error || error{
    /// A number doesn't fit the 16-bit format.
    NumberTooLarge,

    /// A section is larger than the format's 16-bit sizes allow.
    TooLarge,

    /// A capability is given twice.
    DuplicateCapability,
};

/// Encode a terminfo entry in the compiled format, as `tic -x` would,
/// including the extended (user-defined) capabilities.
pub fn encode(alloc: Allocator, source: Source, writer: *std.Io.Writer) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The predefined capabilities, by index.
    var bools: [caps.booleans.len]?bool = @splat(null);
    var nums: [caps.numbers.len]?i16 = @splat(null);
    var strs: [caps.strings.len]?Value = @splat(null);

    // The extended capabilities, sorted by name within each type as
    // tic writes them.
    var ext_bools: std.ArrayList(Extended(bool)) = .empty;
    var ext_nums: std.ArrayList(Extended(i16)) = .empty;
    var ext_strs: std.ArrayList(Extended(Value)) = .empty;

    for (source.capabilities) |cap| {
        switch (cap.value) {
            .boolean, .canceled => if (index(&caps.booleans, cap.name)) |i| {
                if (bools[i] != null) return error.DuplicateCapability;
                bools[i] = cap.value == .boolean;
                continue;
            },
            else => {},
        }
        switch (cap.value) {
            .numeric, .canceled => if (index(&caps.numbers, cap.name)) |i| {
                if (nums[i] != null) return error.DuplicateCapability;
                nums[i] = try number(cap.value);
                continue;
            },
            else => {},
        }
        switch (cap.value) {
            .string, .canceled => if (index(&caps.strings, cap.name)) |i| {
                if (strs[i] != null) return error.DuplicateCapability;
                strs[i] = try string(arena, cap.value);
                continue;
            },
            else => {},
        }

        // An extended capability. A canceled one has no type, which
        // tic treats as a string.
        switch (cap.value) {
            .boolean => try ext_bools.append(arena, .{ .name = cap.name, .value = true }),
            .numeric => try ext_nums.append(arena, .{ .name = cap.name, .value = try number(cap.value) }),
            .string, .canceled => try ext_strs.append(arena, .{ .name = cap.name, .value = try string(arena, cap.value) }),
        }
    }

    sortByName(bool, ext_bools.items);
    sortByName(i16, ext_nums.items);
    sortByName(Value, ext_strs.items);

    // Names
    var names: std.Io.Writer.Allocating = .init(arena);
    for (source.names, 0..) |name, i| {
        if (i != 0) try names.writer.writeByte('|');
        try names.writer.writeAll(name);
    }
    try names.writer.writeByte(0);

    // Only up to the last capability present in each section is written.
    const bool_count = lastPresent(?bool, &bools);
    const num_count = lastPresent(?i16, &nums);
    const str_count = lastPresent(?Value, &strs);

    var table: std.Io.Writer.Allocating = .init(arena);
    var offsets: std.ArrayList(i16) = .empty;
    for (strs[0..str_count]) |value| try offsets.append(arena, try addString(&table, value));

    try writeShort(writer, magic);
    try writeShort(writer, try short(names.written().len));
    try writeShort(writer, try short(bool_count));
    try writeShort(writer, try short(num_count));
    try writeShort(writer, try short(str_count));
    try writeShort(writer, try short(table.written().len));

    try writer.writeAll(names.written());
    for (bools[0..bool_count]) |value| try writer.writeByte(@intFromBool(value orelse false));
    if ((names.written().len + bool_count) % 2 != 0) try writer.writeByte(0);
    for (nums[0..num_count]) |value| try writeShort(writer, value orelse absent);
    for (offsets.items) |offset| try writeShort(writer, offset);
    try writer.writeAll(table.written());

    const ext_count = ext_bools.items.len + ext_nums.items.len + ext_strs.items.len;
    if (ext_count == 0) return;

    // The extended section starts on an even boundary.
    const len = 12 + names.written().len + bool_count +
        ((names.written().len + bool_count) % 2) +
        2 * num_count + 2 * str_count + table.written().len;
    if (len % 2 != 0) try writer.writeByte(0);

    // The extended string table has the string values followed by the
    // names of all the extended capabilities, booleans then numbers then
    // strings, with offsets for the names relative to the first name.
    var ext_table: std.Io.Writer.Allocating = .init(arena);
    var ext_offsets: std.ArrayList(i16) = .empty;
    var ext_values: usize = 0;
    for (ext_strs.items) |cap| {
        const offset = try addString(&ext_table, cap.value);
        try ext_offsets.append(arena, offset);
        if (offset >= 0) ext_values += 1;
    }
    const names_start = ext_table.written().len;
    for (ext_bools.items) |cap| try ext_offsets.append(arena, try addName(&ext_table, names_start, cap.name));
    for (ext_nums.items) |cap| try ext_offsets.append(arena, try addName(&ext_table, names_start, cap.name));
    for (ext_strs.items) |cap| try ext_offsets.append(arena, try addName(&ext_table, names_start, cap.name));

    try writeShort(writer, try short(ext_bools.items.len));
    try writeShort(writer, try short(ext_nums.items.len));
    try writeShort(writer, try short(ext_strs.items.len));
    try writeShort(writer, try short(ext_values + ext_count));
    try writeShort(writer, try short(ext_table.written().len));

    for (ext_bools.items) |cap| try writer.writeByte(@intFromBool(cap.value));
    if (ext_bools.items.len % 2 != 0) try writer.writeByte(0);
    for (ext_nums.items) |cap| try writeShort(writer, cap.value);
    for (ext_offsets.items) |offset| try writeShort(writer, offset);
    try writer.writeAll(ext_table.written());
}

/// A string capability's value: its bytes, or canceled.
const Value = union(enum) {
    canceled,
    bytes: []const u8,
};

fn Extended(comptime T: type) type {
    return struct { name: []const u8, value: T };
}

fn sortByName(comptime T: type, items: []Extended(T)) void {
    std.mem.sort(Extended(T), items, {}, struct {
        fn lessThan(_: void, a: Extended(T), b: Extended(T)) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn index(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return i;
    }
    return null;
}

fn lastPresent(comptime T: type, values: []const T) usize {
    var count = values.len;
    while (count > 0 and values[count - 1] == null) count -= 1;
    return count;
}

fn number(value: Source.Capability.Value) Error!i16 {
    return switch (value) {
        .canceled => canceled,
        .numeric => |v| std.math.cast(i16, v) orelse error.NumberTooLarge,
        else => unreachable,
    };
}

fn string(alloc: Allocator, value: Source.Capability.Value) Allocator.Error!Value {
    return switch (value) {
        .canceled => .canceled,
        .string => |v| .{ .bytes = try unescape(alloc, v) },
        else => unreachable,
    };
}

fn short(value: usize) error{TooLarge}!i16 {
    return std.math.cast(i16, value) orelse error.TooLarge;
}

fn writeShort(writer: *std.Io.Writer, value: i16) std.Io.Writer.Error!void {
    try writer.writeInt(i16, value, .little);
}

/// Add a string value to a string table, returning its offset (or the
/// format's value for absent or canceled).
fn addString(table: *std.Io.Writer.Allocating, value: ?Value) Error!i16 {
    const v = value orelse return absent;
    switch (v) {
        .canceled => return canceled,
        .bytes => |bytes| {
            const offset = try short(table.written().len);
            try table.writer.writeAll(bytes);
            try table.writer.writeByte(0);
            return offset;
        },
    }
}

fn addName(table: *std.Io.Writer.Allocating, start: usize, name: []const u8) Error!i16 {
    const offset = try short(table.written().len - start);
    try table.writer.writeAll(name);
    try table.writer.writeByte(0);
    return offset;
}

/// Decode a string capability's escapes as tic does: \E or \e for escape,
/// ^X for control characters, the other backslash escapes, and octal
/// (where \0 is \200, so that the string isn't cut short).
pub fn unescape(alloc: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < value.len) {
        const ch = value[i];
        i += 1;
        switch (ch) {
            '^' => if (i < value.len) {
                const next = value[i];
                i += 1;
                try result.append(alloc, if (next == '?') 0x7F else next & 0x1F);
            } else try result.append(alloc, ch),

            '\\' => if (i < value.len) {
                const next = value[i];
                i += 1;
                switch (next) {
                    'E', 'e' => try result.append(alloc, 0x1B),
                    'n', 'l' => try result.append(alloc, '\n'),
                    'r' => try result.append(alloc, '\r'),
                    't' => try result.append(alloc, '\t'),
                    'b' => try result.append(alloc, 0x08),
                    'f' => try result.append(alloc, 0x0C),
                    's' => try result.append(alloc, ' '),
                    'a' => try result.append(alloc, 0x07),
                    '0'...'7' => {
                        var octal: u16 = next - '0';
                        var digits: usize = 1;
                        while (digits < 3 and i < value.len and value[i] >= '0' and value[i] <= '7') {
                            octal = octal * 8 + (value[i] - '0');
                            i += 1;
                            digits += 1;
                        }
                        const byte: u8 = @truncate(octal);
                        try result.append(alloc, if (byte == 0) 0x80 else byte);
                    },
                    else => try result.append(alloc, next),
                }
            } else try result.append(alloc, ch),

            else => try result.append(alloc, ch),
        }
    }

    return try result.toOwnedSlice(alloc);
}

test unescape {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\\E[%i%p1%d;%p2%dr", "\x1b[%i%p1%d;%p2%dr" },
        .{ "^G^H^?", "\x07\x08\x7f" },
        .{ "\\E]2;\\007", "\x1b]2;\x07" },
        .{ "rgb\\:x\\,y", "rgb:x,y" },
        .{ "\\E\\\\", "\x1b\\" },
        .{ "a\\0b", "a\x80b" },
        .{ "\\n\\r\\t\\s", "\n\r\t " },
    };
    for (cases) |case| {
        const result = try unescape(alloc, case[0]);
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
    }
}

test encode {
    const testing = std.testing;
    const alloc = testing.allocator;

    const source: Source = .{
        .names = &.{ "test", "Test terminal" },
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "cols", .value = .{ .numeric = 80 } },
            .{ .name = "bel", .value = .{ .string = "^G" } },
            .{ .name = "Tc", .value = .{ .boolean = {} } },
            .{ .name = "Ss", .value = .{ .string = "\\E[%p1%d q" } },
        },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try encode(alloc, source, &out.writer);

    const expected =
        // Header: magic, names size, 2 booleans, 1 number, 2 strings,
        // and a string table of 2 bytes.
        "\x1a\x01" ++ "\x13\x00" ++ "\x02\x00" ++ "\x01\x00" ++ "\x02\x00" ++ "\x02\x00" ++
        "test|Test terminal\x00" ++
        "\x00\x01" ++ "\x00" ++ // bw absent, am, then padding
        "\x50\x00" ++ // cols
        "\xff\xff" ++ "\x00\x00" ++ // cbt absent, bel
        "\x07\x00" ++
        // Extended header: 1 boolean, no numbers, 1 string, 3 table
        // entries (1 value and 2 names), and a table of 16 bytes.
        "\x01\x00" ++ "\x00\x00" ++ "\x01\x00" ++ "\x03\x00" ++ "\x10\x00" ++
        "\x01" ++ "\x00" ++ // Tc, then padding
        "\x00\x00" ++ // Ss's value
        "\x00\x00" ++ "\x03\x00" ++ // names: Tc, Ss
        "\x1b[%p1%d q\x00" ++ "Tc\x00" ++ "Ss\x00";
    try testing.expectEqualSlices(u8, expected, out.written());
}
