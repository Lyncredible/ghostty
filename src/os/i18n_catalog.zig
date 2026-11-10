//! Translation catalogs without gettext, for the Windows app.
//!
//! Windows has no libintl or `msgfmt`, so the build compiles the `po/`
//! files itself (`src/build/po_compile.zig`) into one blob that's embedded
//! in the executable, and `i18n._` looks messages up in the user's
//! language. This file has the three parts that takes and nothing else,
//! since the build tool uses it too: the `.po` parser, the blob's format,
//! and choosing a locale for a Windows language name.
//!
//! The blob, all integers little endian:
//!
//!     "GTR2", locale count: u32, message count: u32
//!     for each message that some locale translates, sorted: its
//!       msgid's offset: u32
//!     for each locale: name ([16]u8, NUL padded), and the offset of its
//!       translations: u32
//!     the msgids, then for each locale its translations: for each
//!       message its msgstr's offset: u32, or 0 if it has none; then the
//!       msgstrs
//!
//! Offsets are from the start of the blob, and strings are NUL
//! terminated. The msgids are stored once: they're half the text.
const std = @import("std");
const Allocator = std.mem.Allocator;

const magic = "GTR2";
const name_len = 16;
const locale_entry_len = name_len + 4;

/// A translated message from a `.po` file.
pub const Message = struct {
    id: []const u8,
    str: []const u8,
};

pub const ParseError = error{InvalidPo} || Allocator.Error;

/// The translated messages of a `.po` file, in the file's order. Messages
/// without a translation, fuzzy ones (a guess made by `msgmerge` that
/// nobody checked), and those with a context or plural forms (which
/// `i18n._` can't ask for) are left out, as is the header.
pub fn parse(alloc: Allocator, po: []const u8) ParseError![]Message {
    var result: std.ArrayList(Message) = .empty;
    errdefer result.deinit(alloc);

    errdefer for (result.items) |message| {
        alloc.free(message.id);
        alloc.free(message.str);
    };

    // The message being read: its strings so far, which of them a quoted
    // line continues, and what's been seen of it.
    var id: std.ArrayList(u8) = .empty;
    defer id.deinit(alloc);
    var str: std.ArrayList(u8) = .empty;
    defer str.deinit(alloc);
    var field: enum { none, id, str, skipped } = .none;
    var seen_id = false;
    var seen_str = false;
    var fuzzy = false;
    var unsupported = false;

    var lines = std.mem.splitScalar(u8, po, '\n');
    var at_end = false;
    while (!at_end) {
        const raw = lines.next() orelse end: {
            at_end = true;
            break :end "";
        };
        const line = std.mem.trim(u8, raw, " \t\r");

        // A message ends at a blank line, or where the next one starts,
        // with its comments.
        const is_comment = std.mem.startsWith(u8, line, "#");
        const is_id = std.mem.startsWith(u8, line, "msgid ");
        const is_context = std.mem.startsWith(u8, line, "msgctxt ");
        if (line.len == 0 or ((is_comment or is_id or is_context) and seen_str)) {
            if (seen_id != seen_str) return error.InvalidPo;
            if (seen_id and !fuzzy and !unsupported and id.items.len > 0 and str.items.len > 0) {
                const id_copy = try alloc.dupe(u8, id.items);
                errdefer alloc.free(id_copy);
                const str_copy = try alloc.dupe(u8, str.items);
                errdefer alloc.free(str_copy);
                try result.append(alloc, .{ .id = id_copy, .str = str_copy });
            }
            id.clearRetainingCapacity();
            str.clearRetainingCapacity();
            field = .none;
            if (seen_id) {
                fuzzy = false;
                unsupported = false;
            }
            seen_id = false;
            seen_str = false;
            if (line.len == 0) continue;
        }

        // A flag comment belongs to the message after it.
        if (is_comment) {
            if (std.mem.startsWith(u8, line, "#,") and
                std.mem.indexOf(u8, line, "fuzzy") != null) fuzzy = true;
            continue;
        }

        if (std.mem.startsWith(u8, line, "\"")) {
            switch (field) {
                .id => try unquote(alloc, &id, line),
                .str => try unquote(alloc, &str, line),
                .skipped => {},
                .none => return error.InvalidPo,
            }
        } else if (is_id) {
            if (seen_id) return error.InvalidPo;
            seen_id = true;
            field = .id;
            try unquote(alloc, &id, line["msgid ".len..]);
        } else if (std.mem.startsWith(u8, line, "msgstr ")) {
            if (!seen_id or seen_str) return error.InvalidPo;
            seen_str = true;
            field = .str;
            try unquote(alloc, &str, line["msgstr ".len..]);
        } else if (is_context) {
            if (seen_id) return error.InvalidPo;
            unsupported = true;
            field = .skipped;
        } else if (std.mem.startsWith(u8, line, "msgid_plural ")) {
            if (!seen_id or seen_str) return error.InvalidPo;
            unsupported = true;
            field = .skipped;
        } else if (std.mem.startsWith(u8, line, "msgstr[")) {
            if (!seen_id) return error.InvalidPo;
            unsupported = true;
            seen_str = true;
            field = .skipped;
        } else return error.InvalidPo;
    }

    return try result.toOwnedSlice(alloc);
}

/// Append a quoted `.po` string's contents, with its escapes undone.
fn unquote(alloc: Allocator, out: *std.ArrayList(u8), quoted: []const u8) ParseError!void {
    const text = std.mem.trim(u8, quoted, " \t");
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return error.InvalidPo;
    const inner = text[1 .. text.len - 1];
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch == '"') return error.InvalidPo;
        if (ch != '\\') {
            try out.append(alloc, ch);
            continue;
        }
        i += 1;
        if (i == inner.len) return error.InvalidPo;
        try out.append(alloc, switch (inner[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"', '\\' => inner[i],
            else => return error.InvalidPo,
        });
    }
}

pub fn freeMessages(alloc: Allocator, messages: []Message) void {
    for (messages) |message| {
        alloc.free(message.id);
        alloc.free(message.str);
    }
    alloc.free(messages);
}

/// A locale's `.po` file, for `compile`.
pub const Source = struct {
    locale: []const u8,
    po: []const u8,
};

pub const CompileError = error{ InvalidPo, LocaleNameTooLong, CatalogTooLarge } || Allocator.Error;

/// Compile `.po` files into the blob that `Catalog.find` reads.
pub fn compile(alloc: Allocator, sources: []const Source) CompileError![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every locale's messages, and the messages any of them translates,
    // sorted for the binary search.
    const translations = try arena.alloc([]Message, sources.len);
    var ids: std.ArrayList([]const u8) = .empty;
    for (sources, translations) |source, *messages| {
        if (source.locale.len == 0 or source.locale.len > name_len) return error.LocaleNameTooLong;
        messages.* = try parse(arena, source.po);
        for (messages.*) |message| {
            // The strings are NUL terminated, so they can't hold one.
            if (std.mem.indexOfScalar(u8, message.id, 0) != null or
                std.mem.indexOfScalar(u8, message.str, 0) != null) return error.InvalidPo;
            try ids.append(arena, message.id);
        }
    }
    std.mem.sort([]const u8, ids.items, {}, lessThan);
    var id_count: usize = 0;
    for (ids.items, 0..) |id, i| {
        if (i > 0 and std.mem.eql(u8, ids.items[id_count - 1], id)) continue;
        ids.items[id_count] = id;
        id_count += 1;
    }
    ids.items.len = id_count;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, magic);
    try appendInt(alloc, &out, sources.len);
    try appendInt(alloc, &out, ids.items.len);
    const id_table = out.items.len;
    try out.appendNTimes(alloc, 0, ids.items.len * 4);
    const locale_table = out.items.len;
    try out.appendNTimes(alloc, 0, sources.len * locale_entry_len);

    for (ids.items, 0..) |id, i| {
        try writeInt(out.items[id_table + i * 4 ..], out.items.len);
        try out.appendSlice(alloc, id);
        try out.append(alloc, 0);
    }

    for (sources, translations, 0..) |source, messages, i| {
        const entry = out.items[locale_table + i * locale_entry_len ..][0..locale_entry_len];
        @memcpy(entry[0..source.locale.len], source.locale);
        try writeInt(entry[name_len..], out.items.len);

        const table = out.items.len;
        try out.appendNTimes(alloc, 0, ids.items.len * 4);
        for (messages) |message| {
            const index = std.sort.binarySearch([]const u8, ids.items, message.id, order).?;
            // Of messages given twice, which msgfmt refuses, the first
            // stays.
            const slot = table + index * 4;
            if (readInt(out.items, slot).? != 0) continue;
            try writeInt(out.items[slot..], out.items.len);
            try out.appendSlice(alloc, message.str);
            try out.append(alloc, 0);
        }
    }

    return try out.toOwnedSlice(alloc);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn order(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

fn appendInt(alloc: Allocator, out: *std.ArrayList(u8), value: usize) CompileError!void {
    try out.appendNTimes(alloc, 0, 4);
    try writeInt(out.items[out.items.len - 4 ..], value);
}

fn writeInt(dest: []u8, value: usize) error{CatalogTooLarge}!void {
    const v = std.math.cast(u32, value) orelse return error.CatalogTooLarge;
    std.mem.writeInt(u32, dest[0..4], v, .little);
}

fn readInt(data: []const u8, offset: usize) ?usize {
    if (offset > data.len or data.len - offset < 4) return null;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

/// One locale's messages in a compiled blob.
pub const Catalog = struct {
    blob: []const u8,

    /// Where the offsets of the messages, and of this locale's
    /// translations of them, start.
    ids: usize,
    translations: usize,

    /// How many messages the blob has, and how many of them this locale
    /// translates.
    messages: usize,
    count: usize,

    /// The locale's catalog in a blob, if it has one and it's well formed
    /// (so that `get` can't read outside it).
    pub fn find(blob: []const u8, locale: []const u8) ?Catalog {
        if (!std.mem.startsWith(u8, blob, magic)) return null;
        const locale_count = readInt(blob, magic.len) orelse return null;
        const messages = readInt(blob, magic.len + 4) orelse return null;
        const ids = magic.len + 8;
        if ((blob.len - ids) / 4 < messages) return null;
        const locales = ids + messages * 4;
        if ((blob.len - locales) / locale_entry_len < locale_count) return null;

        const translations = for (0..locale_count) |i| {
            const entry = locales + i * locale_entry_len;
            const name = std.mem.sliceTo(blob[entry..][0..name_len], 0);
            if (std.mem.eql(u8, name, locale)) break readInt(blob, entry + name_len).?;
        } else return null;
        if (translations > blob.len or (blob.len - translations) / 4 < messages) return null;

        // Every string starts inside the blob, which ends with a
        // string's NUL.
        if (messages > 0 and blob[blob.len - 1] != 0) return null;
        var count: usize = 0;
        for (0..messages) |i| {
            if (readInt(blob, ids + i * 4).? >= blob.len) return null;
            const translation = readInt(blob, translations + i * 4).?;
            if (translation >= blob.len) return null;
            if (translation != 0) count += 1;
        }
        return .{
            .blob = blob,
            .ids = ids,
            .translations = translations,
            .messages = messages,
            .count = count,
        };
    }

    /// The translation of a message, if the locale has one.
    pub fn get(self: Catalog, msgid: []const u8) ?[:0]const u8 {
        var low: usize = 0;
        var high: usize = self.messages;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.string(readInt(self.blob, self.ids + mid * 4).?), msgid)) {
                .eq => {
                    const translation = readInt(self.blob, self.translations + mid * 4).?;
                    return if (translation == 0) null else self.string(translation);
                },
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }

    fn string(self: Catalog, offset: usize) [:0]const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(self.blob[offset..].ptr)), 0);
    }
};

/// The locale, of those we have translations for, to use for a language
/// as Windows names it ("de-DE", "zh-Hans-CN", "sr-Latn-RS"; a POSIX name
/// like "pt_BR" works too). Null if we have none for the language.
///
/// The region is used when we have that one ("pt-BR", "es-AR"); otherwise
/// the language alone, or failing that its first locale in `locales`
/// (their order says which is preferred), since another region's
/// translation still beats English for most people.
pub fn localeFor(locales: []const [:0]const u8, language: []const u8) ?[:0]const u8 {
    var parts = std.mem.tokenizeAny(u8, language, "-_.@");
    var lang_buf: [8]u8 = undefined;
    const lang_raw = parts.next() orelse return null;
    if (lang_raw.len > lang_buf.len) return null;
    var lang: []const u8 = std.ascii.lowerString(&lang_buf, lang_raw);
    // Windows calls Norwegian Bokmål "nb", but older names say "no".
    if (std.mem.eql(u8, lang, "no")) lang = "nb";

    var script: []const u8 = "";
    var region: []const u8 = "";
    while (parts.next()) |part| {
        if (part.len == 4 and script.len == 0) {
            script = part;
        } else if ((part.len == 2 or part.len == 3) and region.len == 0) {
            region = part;
        } else if (std.ascii.eqlIgnoreCase(part, "latin")) {
            script = "Latn";
        }
    }

    // Chinese is written two ways, which matter more than the region.
    if (std.mem.eql(u8, lang, "zh")) {
        const traditional = if (script.len > 0)
            std.ascii.eqlIgnoreCase(script, "Hant")
        else for ([_][]const u8{ "TW", "HK", "MO" }) |v| {
            if (std.ascii.eqlIgnoreCase(region, v)) break true;
        } else false;
        return exact(locales, if (traditional) "zh_TW" else "zh_CN");
    }

    // Serbian too, where the script is part of our locale's name.
    if (std.mem.eql(u8, lang, "sr")) {
        const latin = std.ascii.eqlIgnoreCase(script, "Latn");
        return exact(locales, if (latin) "sr@latin" else "sr");
    }

    if (region.len > 0) {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}_{s}", .{ lang, region }) catch return null;
        _ = std.ascii.upperString(name[lang.len + 1 ..], region);
        if (exact(locales, name)) |v| return v;
    }
    if (exact(locales, lang)) |v| return v;
    for (locales) |locale| {
        if (locale.len > lang.len and
            locale[lang.len] == '_' and
            std.mem.startsWith(u8, locale, lang)) return locale;
    }
    return null;
}

fn exact(locales: []const [:0]const u8, name: []const u8) ?[:0]const u8 {
    for (locales) |locale| {
        if (std.mem.eql(u8, locale, name)) return locale;
    }
    return null;
}

/// Whether a language name is English, which the messages are written
/// in: a user who prefers it wants them as they are, not the next
/// language in their list.
pub fn isEnglish(language: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, language, "-_.@");
    const lang = parts.next() orelse return false;
    return std.ascii.eqlIgnoreCase(lang, "en") or std.ascii.eqlIgnoreCase(lang, "C") or
        std.ascii.eqlIgnoreCase(lang, "POSIX");
}

/// The locale for a list of languages in the user's order of preference.
pub fn localeForLanguages(locales: []const [:0]const u8, languages: []const []const u8) ?[:0]const u8 {
    for (languages) |language| {
        if (isEnglish(language)) return null;
        if (localeFor(locales, language)) |v| return v;
    }
    return null;
}

const test_po =
    \\# German translations.
    \\msgid ""
    \\msgstr ""
    \\"Language: de\n"
    \\"Content-Type: text/plain; charset=UTF-8\n"
    \\
    \\#: src/apprt/gtk/ui/1.0/search-overlay.blp:29
    \\msgid "Find…"
    \\msgstr "Suchen…"
    \\
    \\#: one.zig:1
    \\#: two.zig:2
    \\msgid "Close"
    \\msgstr "Schließen"
    \\
    \\msgid ""
    \\"This terminal is in read-only mode. You can \"still\" view "
    \\"the content.\n"
    \\msgstr ""
    \\"Dieses Terminal ist schreibgeschützt.\n"
    \\"Zweite\tZeile \\ Ende"
    \\
    \\msgid "Not translated"
    \\msgstr ""
    \\
    \\#, fuzzy
    \\msgid "Guessed"
    \\msgstr "Geraten"
    \\
    \\#, c-format
    \\msgid "Flagged but fine"
    \\msgstr "In Ordnung"
    \\
    \\msgctxt "menu"
    \\msgid "With context"
    \\msgstr "Mit Kontext"
    \\
    \\msgid "One file"
    \\msgid_plural "%d files"
    \\msgstr[0] "Eine Datei"
    \\msgstr[1] "%d Dateien"
    \\
    \\#~ msgid "Obsolete"
    \\#~ msgstr "Veraltet"
    \\
    \\msgid "Close"
    \\msgstr "Zu"
    \\msgid "No blank line before"
    \\msgstr "Ohne Leerzeile"
    \\#, fuzzy
    \\msgid "Guessed too"
    \\msgstr "Auch geraten"
;

test parse {
    const testing = std.testing;
    const messages = try parse(testing.allocator, test_po);
    defer freeMessages(testing.allocator, messages);

    const expected = [_]Message{
        .{ .id = "Find…", .str = "Suchen…" },
        .{ .id = "Close", .str = "Schließen" },
        .{
            .id = "This terminal is in read-only mode. You can \"still\" view the content.\n",
            .str = "Dieses Terminal ist schreibgeschützt.\nZweite\tZeile \\ Ende",
        },
        .{ .id = "Flagged but fine", .str = "In Ordnung" },
        .{ .id = "Close", .str = "Zu" },
        .{ .id = "No blank line before", .str = "Ohne Leerzeile" },
    };
    try testing.expectEqual(expected.len, messages.len);
    for (expected, messages) |want, got| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqualStrings(want.str, got.str);
    }
}

test "parse: Windows line endings and no final newline" {
    const testing = std.testing;
    const messages = try parse(testing.allocator, "msgid \"a\"\r\nmsgstr \"b\"\r\n\r\nmsgid \"c\"\r\nmsgstr \"d\"");
    defer freeMessages(testing.allocator, messages);
    try testing.expectEqual(2, messages.len);
    try testing.expectEqualStrings("b", messages[0].str);
    try testing.expectEqualStrings("d", messages[1].str);
}

test "parse: invalid files" {
    const testing = std.testing;
    for ([_][]const u8{
        "msgid \"a\nmsgstr \"b\"", // no closing quote
        "msgid \"a\"\nmsgstr \"b\\q\"", // an escape we don't know
        "msgid \"a\"\nmsgstr \"b\\\"", // an escape cut short
        "msgid \"a\"\nmsgstr \"b\" \"c\"", // a quote inside
        "msgstr \"b\"", // a translation of nothing
        "\"text\"", // a string that continues nothing
        "msgid \"a\"\nnonsense", // not a .po line
    }) |po| {
        try testing.expectError(error.InvalidPo, parse(testing.allocator, po));
    }
}

test "compile and look up" {
    const testing = std.testing;
    const blob = try compile(testing.allocator, &.{
        .{ .locale = "de", .po = test_po },
        .{ .locale = "empty", .po = "" },
        .{ .locale = "sr@latin", .po = "msgid \"Close\"\nmsgstr \"Zatvori\"\n" },
    });
    defer testing.allocator.free(blob);

    const de = Catalog.find(blob, "de").?;
    try testing.expectEqual(5, de.count);
    try testing.expectEqualStrings("Suchen…", de.get("Find…").?);
    // The first of two translations of a message.
    try testing.expectEqualStrings("Schließen", de.get("Close").?);
    try testing.expectEqualStrings("Ohne Leerzeile", de.get("No blank line before").?);
    try testing.expectEqualStrings("In Ordnung", de.get("Flagged but fine").?);
    for ([_][]const u8{ "", "Not translated", "Guessed", "With context", "One file", "Obsolete", "Clos", "Closed", "zzz", "\x00" }) |msgid| {
        try testing.expect(de.get(msgid) == null);
    }

    const empty = Catalog.find(blob, "empty").?;
    try testing.expectEqual(0, empty.count);
    try testing.expect(empty.get("Close") == null);

    try testing.expectEqualStrings("Zatvori", Catalog.find(blob, "sr@latin").?.get("Close").?);
    try testing.expect(Catalog.find(blob, "fr") == null);
    try testing.expect(Catalog.find(blob, "") == null);

    try testing.expectError(error.LocaleNameTooLong, compile(testing.allocator, &.{
        .{ .locale = "a-locale-name-that-is-too-long", .po = "" },
    }));
    try testing.expectError(error.InvalidPo, compile(testing.allocator, &.{
        .{ .locale = "de", .po = "msgid \"a\"\nmsgstr" },
    }));
}

test "Catalog.find: damaged blobs" {
    const testing = std.testing;
    const blob = try compile(testing.allocator, &.{
        .{ .locale = "de", .po = test_po },
    });
    defer testing.allocator.free(blob);

    // Cut anywhere, it's refused rather than read past its end.
    for (0..blob.len) |len| {
        try testing.expect(Catalog.find(blob[0..len], "de") == null);
    }

    // With any one byte changed, it's refused or lookups still end
    // (finding nothing, or a wrong string from inside it).
    const copy = try testing.allocator.dupe(u8, blob);
    defer testing.allocator.free(copy);
    for (0..copy.len) |i| {
        for ([_]u8{ 0x00, 0x7f, 0xff }) |value| {
            const old = copy[i];
            defer copy[i] = old;
            copy[i] = value;
            const catalog = Catalog.find(copy, "de") orelse continue;
            _ = catalog.get("Close");
            _ = catalog.get("zzz");
        }
    }
}

test localeFor {
    const testing = std.testing;
    const locales = @import("i18n_locales.zig").locales;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "de-DE", "de" },
        .{ "de", "de" },
        .{ "DE-at", "de" },
        .{ "fr-CA", "fr" },
        .{ "ja-JP", "ja" },
        .{ "ko-KR", "ko_KR" },
        .{ "ko", "ko_KR" },
        .{ "pt-BR", "pt_BR" },
        .{ "pt-PT", "pt_BR" },
        .{ "es-ES", "es_ES" },
        .{ "es-AR", "es_AR" },
        .{ "es-BO", "es_BO" },
        // Another region's Spanish: the first in our list.
        .{ "es-MX", "es_BO" },
        .{ "es-419", "es_BO" },
        .{ "nb-NO", "nb" },
        .{ "no", "nb" },
        .{ "zh-CN", "zh_CN" },
        .{ "zh-Hans-CN", "zh_CN" },
        .{ "zh-SG", "zh_CN" },
        .{ "zh", "zh_CN" },
        .{ "zh-TW", "zh_TW" },
        .{ "zh-HK", "zh_TW" },
        .{ "zh-Hant-HK", "zh_TW" },
        .{ "zh-Hant", "zh_TW" },
        // The script wins over the region.
        .{ "zh-Hans-HK", "zh_CN" },
        .{ "sr-Cyrl-RS", "sr" },
        .{ "sr-RS", "sr" },
        .{ "sr-Latn-RS", "sr@latin" },
        // POSIX names, as in LANGUAGE.
        .{ "pt_BR.UTF-8", "pt_BR" },
        .{ "sr@latin", "sr@latin" },
        .{ "de_DE.UTF-8", "de" },
        // Languages we have nothing for.
        .{ "en-US", null },
        .{ "sv-SE", null },
        .{ "fil-PH", null },
        .{ "", null },
        .{ "-", null },
        .{ "averylonglanguagename", null },
    };
    for (cases) |case| {
        const got = localeFor(&locales, case[0]);
        if (case[1]) |want| {
            errdefer std.debug.print("language: {s}\n", .{case[0]});
            try testing.expect(got != null);
            try testing.expectEqualStrings(want, got.?);
        } else try testing.expect(got == null);
    }
}

test localeForLanguages {
    const testing = std.testing;
    const locales = @import("i18n_locales.zig").locales;
    try testing.expectEqualStrings("de", localeForLanguages(&locales, &.{ "de-DE", "en-US" }).?);
    // A language we don't have, then one we do.
    try testing.expectEqualStrings("fr", localeForLanguages(&locales, &.{ "sv-SE", "fr-FR" }).?);
    // English first means English, whatever comes after.
    try testing.expect(localeForLanguages(&locales, &.{ "en-GB", "de-DE" }) == null);
    try testing.expect(localeForLanguages(&locales, &.{ "sv-SE", "en-US", "de-DE" }) == null);
    try testing.expect(localeForLanguages(&locales, &.{"C"}) == null);
    try testing.expect(localeForLanguages(&locales, &.{}) == null);
}
