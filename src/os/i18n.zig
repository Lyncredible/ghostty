const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const locales = @import("i18n_locales.zig");
const catalog = @import("i18n_catalog.zig");

const log = std.log.scoped(.i18n);

/// Set for faster membership lookup of locales.
pub const locales_map = map: {
    var kvs: [locales.len]struct { []const u8 } = undefined;
    for (locales, 0..) |locale, i| kvs[i] = .{locale};
    break :map std.StaticStringMap(void).initComptime(kvs);
};

pub const InitError = error{
    InvalidResourcesDir,
    OutOfMemory,
};

/// Initialize i18n support for the application. This should be
/// called automatically by the global state initialization
/// in global.zig.
///
/// This calls `bindtextdomain` for gettext with the proper directory
/// of translations. This does NOT call `textdomain` as we don't
/// want to set the domain for the entire application since this is also
/// used by libghostty.
pub fn init(resources_dir: []const u8) InitError!void {
    if (comptime !build_config.i18n) return;

    switch (builtin.target.os.tag) {
        // gettext is unsupported on Windows; the app has its own
        // catalog, see initEmbedded.
        .windows => return,

        else => {
            // Our resources dir is always nested below the share dir that
            // is standard for translations.
            const share_dir = std.fs.path.dirname(resources_dir) orelse
                return error.InvalidResourcesDir;

            // Build our locale path
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.mem.printSentinel(&buf, "{s}/locale", .{share_dir}, 0) catch
                return error.OutOfMemory;

            // Bind our bundle ID to the given locale path
            log.debug("binding domain={s} path={s}", .{ build_config.bundle_id, path });
            _ = bindtextdomain(build_config.bundle_id, path.ptr) orelse
                return error.OutOfMemory;
        },
    }
}

/// Set the global gettext domain to our bundle ID, allowing unqualified
/// `gettext` (`_`) calls to look up translations for our application.
///
/// This should only be called for apprts that are fully owning the
/// Ghostty application. This should not be called for libghostty users.
pub fn initGlobalDomain() error{OutOfMemory}!void {
    if (comptime !build_config.i18n) return;
    _ = textdomain(build_config.bundle_id) orelse return error.OutOfMemory;
}

/// Translate a message for the Ghostty domain.
///
/// If this is called at comptime, the direct msgid is returned without
/// translation. This still allows the string to be marked for translation
/// while remaining usable in comptime contexts.
pub fn _(msgid: [*:0]const u8) [*:0]const u8 {
    if (comptime embedded) {
        if (@inComptime()) return msgid;
        const current = embedded_catalog orelse return msgid;
        const translated = current.get(std.mem.span(msgid)) orelse return msgid;
        return translated.ptr;
    }
    if (comptime !build_config.i18n) return msgid;
    if (@inComptime()) return msgid;
    return dgettext(build_config.bundle_id, msgid);
}

/// `_` for Zig strings: the message in the user's language, or as it is
/// if there's no translation.
pub fn text(msgid: [:0]const u8) [:0]const u8 {
    return translation(msgid) orelse msgid;
}

/// The message in the user's language, if we have a translation for it.
/// Only the embedded catalog can tell; gettext just returns the message.
pub fn translation(msgid: [:0]const u8) ?[:0]const u8 {
    if (comptime !embedded) return null;
    const current = embedded_catalog orelse return null;
    return current.get(msgid);
}

/// Use a locale's messages from the embedded catalog, or none (English)
/// for null. Returns false if we don't have the locale. For `initEmbedded`,
/// and for tests of translated text; not safe while other threads
/// translate.
pub fn useEmbeddedLocale(locale: ?[]const u8) bool {
    if (comptime !embedded) return locale == null;
    const name = locale orelse {
        embedded_catalog = null;
        return true;
    };
    embedded_catalog = catalog.Catalog.find(@import("i18n_catalog_data").blob, name) orelse
        return false;
    return true;
}

/// Whether translations come from the catalog compiled into the
/// executable rather than gettext: the Windows app, where there's no
/// libintl to read `.mo` files or `msgfmt` to make them. The build
/// compiles the `po/` files itself, see i18n_catalog.zig.
pub const embedded = builtin.target.os.tag == .windows and
    build_config.app_runtime == .win32;

/// The messages of the user's language, if we have it. Set once by
/// `initEmbedded`, before any other thread starts.
var embedded_catalog: ?catalog.Catalog = null;

/// Choose the language of the embedded catalog: the first we have of
/// `LANGUAGE` (as for gettext, "de" or "pt_BR:es"), or else of the
/// display languages the user prefers, as Windows' own apps do. English
/// anywhere before one we have means the messages as they're written.
pub fn initEmbedded() void {
    if (comptime !embedded) return;

    var buf: [512]u8 = undefined;
    var list: [16][]const u8 = undefined;
    const languages = embeddedLanguages(&buf, &list);
    const locale = catalog.localeForLanguages(&supported_locales, languages) orelse {
        log.debug("no translations for the preferred languages count={}", .{languages.len});
        return;
    };
    if (!useEmbeddedLocale(locale)) {
        log.warn("the translations for locale={s} are missing or damaged", .{locale});
        return;
    }
    log.info("translations locale={s} messages={}", .{ locale, embedded_catalog.?.count });
}

/// The user's languages in order of preference, in `list`, with their
/// text in `buf`. Those that don't fit are left out.
fn embeddedLanguages(buf: []u8, list: [][]const u8) []const []const u8 {
    const windows = struct {
        const MUI_LANGUAGE_NAME = 0x8;
        extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
        extern "kernel32" fn GetUserPreferredUILanguages(flags: u32, count: *u32, buf: ?[*]u16, size: *u32) callconv(.winapi) i32;
    };
    var wide: [512]u16 = undefined;

    const env_len = windows.GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("LANGUAGE"),
        &wide,
        wide.len,
    );
    if (env_len > 0 and env_len < wide.len) {
        const languages = splitLanguages(buf, list, wide[0..env_len], ':');
        if (languages.len > 0) return languages;
    }

    // The names come as "de-DE\0en-US\0\0".
    var count: u32 = 0;
    var size: u32 = wide.len;
    if (windows.GetUserPreferredUILanguages(windows.MUI_LANGUAGE_NAME, &count, &wide, &size) == 0 or
        size > wide.len) return &.{};
    return splitLanguages(buf, list, wide[0..size], 0);
}

/// Split UTF-16 language names at a separator into `list`, as ASCII in
/// `buf`: language names are ASCII, and one that isn't matches nothing.
fn splitLanguages(
    buf: []u8,
    list: [][]const u8,
    wide: []const u16,
    separator: u16,
) []const []const u8 {
    var count: usize = 0;
    var used: usize = 0;
    var it = std.mem.tokenizeScalar(u16, wide, separator);
    while (it.next()) |name| {
        if (count == list.len or name.len > buf.len - used) break;
        const dest = buf[used..][0..name.len];
        for (name, dest) |unit, *ch| ch.* = if (unit < 0x80) @intCast(unit) else '?';
        list[count] = dest;
        count += 1;
        used += name.len;
    }
    return list[0..count];
}

const supported_locales = @import("i18n_locales.zig").locales;

/// Mark a string for translation without translating it immediately.
pub fn N_(msgid: [:0]const u8) [:0]const u8 {
    return msgid;
}

/// Canonicalize a locale name from a platform-specific value to
/// a POSIX-compliant value. This is a thin layer over the unexported
/// gnulib-lib function in gettext that does this already.
///
/// The gnulib-lib function modifies the buffer in place but has
/// zero bounds checking, so we do a bit extra to ensure we don't
/// overflow the buffer. This is likely slightly more expensive but
/// this isn't a hot path so it should be fine.
///
/// The buffer must be at least 16 bytes long. This ensures we can
/// fit the longest possible hardcoded locale name. Additionally,
/// it should be at least as long as locale in case the locale
/// is unchanged.
///
/// Here is the logic for macOS, but other platforms also have
/// their own canonicalization logic:
///
/// https://github.com/coreutils/gnulib/blob/5b92dd0a45c8d27f13a21076b57095ea5e220870/lib/localename.c#L1171
pub fn canonicalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    if (comptime !build_config.i18n) {
        if (buf.len < locale.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..locale.len], locale);
        buf[locale.len] = 0;
        return buf[0..locale.len :0];
    }

    // Fix zh locales for macOS
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }

    // Buffer must be 16 or at least as long as the locale and null term
    if (buf.len < @max(16, locale.len + 1)) return error.NoSpaceLeft;

    // Copy our locale into the buffer since it modifies in place.
    // This must be null-terminated.
    @memcpy(buf[0..locale.len], locale);
    buf[locale.len] = 0;

    _libintl_locale_name_canonicalize(buf[0..locale.len :0]);

    // Convert the null-terminated result buffer into a slice. We
    // need to search for the null terminator and slice it back.
    // We have to use `buf` since `slice` len will exclude the
    // null.
    const slice = std.mem.sliceTo(buf, 0);
    return buf[0..slice.len :0];
}

/// Handles some zh locales canonicalization because internal libintl
/// canonicalization function doesn't handle correctly in these cases.
fn fixZhLocale(locale: []const u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, locale, '-');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "zh")) return null;

    const script = it.next() orelse return null;
    const region = it.next() orelse return null;

    if (std.mem.eql(u8, script, "Hans")) {
        if (std.mem.eql(u8, region, "SG")) return "zh_SG";
        return "zh_CN";
    }

    if (std.mem.eql(u8, script, "Hant")) {
        if (std.mem.eql(u8, region, "MO")) return "zh_MO";
        if (std.mem.eql(u8, region, "HK")) return "zh_HK";
        return "zh_TW";
    }

    return null;
}

/// This can be called at any point a compile-time-known locale is
/// available. This will use comptime to verify the locale is supported.
pub fn staticLocale(comptime v: [*:0]const u8) [*:0]const u8 {
    comptime {
        for (locales) |locale| {
            if (std.mem.eql(u8, locale, v)) {
                return locale;
            }
        }

        @compileError("unsupported locale");
    }
}

// Manually include function definitions for the gettext functions
// as libintl.h isn't always easily available (e.g. in musl)
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;

// This is only available if we're building libintl from source
// since its otherwise not exported. We only need it on macOS
// currently but probably will on Windows as well.
extern fn _libintl_locale_name_canonicalize(name: [*:0]u8) void;

test "canonicalizeLocale darwin" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("en_US", try canonicalizeLocale(&buf, "en_US"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant"));

    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans-CN"));
    try testing.expectEqualStrings("zh_SG", try canonicalizeLocale(&buf, "zh-Hans-SG"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant-TW"));
    try testing.expectEqualStrings("zh_HK", try canonicalizeLocale(&buf, "zh-Hant-HK"));
    try testing.expectEqualStrings("zh_MO", try canonicalizeLocale(&buf, "zh-Hant-MO"));

    // This is just an edge case I want to make sure we're aware of:
    // canonicalizeLocale does not handle encodings and will turn them into
    // underscores. We should parse them out before calling this function.
    try testing.expectEqualStrings("en_US.UTF_8", try canonicalizeLocale(&buf, "en_US.UTF-8"));
}

test {
    _ = catalog;
}

test splitLanguages {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [16]u8 = undefined;
    var list: [3][]const u8 = undefined;

    // As GetUserPreferredUILanguages gives them.
    {
        const languages = splitLanguages(&buf, &list, L("de-DE\x00en-US\x00\x00"), 0);
        try testing.expectEqual(2, languages.len);
        try testing.expectEqualStrings("de-DE", languages[0]);
        try testing.expectEqualStrings("en-US", languages[1]);
    }

    // As in LANGUAGE.
    {
        const languages = splitLanguages(&buf, &list, L(":pt_BR::es:"), ':');
        try testing.expectEqual(2, languages.len);
        try testing.expectEqualStrings("pt_BR", languages[0]);
        try testing.expectEqualStrings("es", languages[1]);
    }

    // More than fit in the list, or in the buffer, and no ASCII.
    try testing.expectEqual(3, splitLanguages(&buf, &list, L("a:b:c:d:e"), ':').len);
    try testing.expectEqual(1, splitLanguages(&buf, &list, L("de:a-language-name-that-is-too-long:fr"), ':').len);
    try testing.expectEqualStrings("d?", splitLanguages(&buf, &list, L("dé"), ':')[0]);
    try testing.expectEqual(0, splitLanguages(&buf, &list, L(""), 0).len);
}

test "embedded catalog" {
    if (comptime !embedded) return error.SkipZigTest;
    const testing = std.testing;
    const blob = @import("i18n_catalog_data").blob;

    // Every locale has translations, with the messages every one of
    // them has had since the first.
    for (supported_locales) |locale| {
        errdefer std.debug.print("locale: {s}\n", .{locale});
        const messages = catalog.Catalog.find(blob, locale).?;
        try testing.expect(messages.count > 50);
        try testing.expect(messages.get("Copy") != null);
        try testing.expect(messages.get("New Tab") != null);
        try testing.expect(messages.get("") == null);
    }

    // Tests run in English.
    try testing.expectEqualStrings("Close Tab", std.mem.span(@"_"("Close Tab")));

    try testing.expect(translation("Close Tab") == null);
    try testing.expect(!useEmbeddedLocale("xx"));

    try testing.expect(useEmbeddedLocale("de"));
    defer _ = useEmbeddedLocale(null);
    try testing.expectEqualStrings("Tab schließen", std.mem.span(@"_"("Close Tab")));
    try testing.expectEqualStrings("Tab schließen", text("Close Tab"));
    const untranslated = "A message nobody translated";
    try testing.expectEqual(@as([*:0]const u8, untranslated), @"_"(untranslated));
    try testing.expectEqualStrings(untranslated, text(untranslated));
    try testing.expect(translation(untranslated) == null);
}

test "_ returns msgid at comptime" {
    const testing = std.testing;

    const msgid = comptime @"_"("Ghostty");
    try testing.expectEqualStrings("Ghostty", std.mem.span(msgid));
}
