// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What language does this user read? -- as Windows answers it.
//!
//! Windows has none of POSIX's environment variables. It answers two separate
//! questions of its own, and the split happens to be the same one `Categories`
//! makes:
//!
//!  * **Display language** -- what the interface should be written in.
//!    `GetUserPreferredUILanguages` gives a *ranked list* of them, which is
//!    the direct counterpart of GNU's `LANGUAGE` and the only place on either
//!    platform where a user gets to say "this, or failing that, that".
//!  * **Regional format** -- how numbers, dates and money are written.
//!    `GetUserDefaultLocaleName` gives the one locale that governs all three.
//!
//! Somebody in Germany reading an English interface is an ordinary setting,
//! and it is the same shape as `LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8`.
//!
//! ```zig
//! var buffer: [8]fluent.Locale = undefined;
//! const wanted = fluent.windows.preferredUiLanguages(&buffer);
//! ```
//!
//! ## Off Windows
//!
//! The two functions that call the operating system answer with nothing on
//! every other target, rather than failing to compile, so that a program can
//! name them in a branch it never takes.
//!
//! Everything else here is pure and works anywhere, which is what makes it
//! testable: the parsing is exercised on whatever machine runs the tests, on
//! the byte sequences Windows would have produced. That matters more than
//! usual here, because the half that cannot be tested from a Linux machine is
//! the half where a mistake is a memory error rather than a wrong answer --
//! which is also why the bindings come from `zigwin32` rather than from two
//! hand-written `extern` declarations.

const builtin = @import("builtin");
const std = @import("std");

const Locale = @import("locale.zig").Locale;

/// One locale per category. See `fluent.Categories`.
pub const Categories = @import("locale.zig").Categories;

/// Whether this target can be asked at all.
///
/// The two functions that call the operating system answer with nothing
/// everywhere else, rather than failing to compile, so that a program can name
/// them in a branch it never takes.
pub const available = builtin.os.tag == .windows;

/// The Win32 bindings, imported only on the target that has them, so that a
/// build for anything else neither fetches nor compiles them.
///
/// They come from `zigwin32`, which is generated from Microsoft's own Win32
/// metadata. Writing the two `extern` declarations by hand looks like less
/// machinery and is not: each is a fresh chance to get a calling convention or
/// a parameter width wrong, with nothing to check it against, and a mistake
/// would surface as corruption on the one platform that cannot be tested from
/// here. `GetUserDefaultLocaleName` takes a `[*:0]u16` rather than the `[*]u16`
/// it would have been easy to write.
const win32 = if (available) @import("win32").everything else struct {};

/// The longest locale name Windows will hand back, in UTF-16 code units.
///
/// `LOCALE_NAME_MAX_LENGTH`, which counts the terminating NUL.
pub const max_name_len = 85;

/// The languages the user would like the interface in, best first.
///
/// The counterpart of `fluent.posix.fromEnviron`: a ranked list, which is what
/// a fallback between bundles wants. Returns nothing on a target that is not
/// Windows, and nothing if the call fails.
pub fn preferredUiLanguages(buffer: []Locale) []Locale {
    if (!available) return buffer[0..0];

    // Room for a good few names; the call says how much it wanted, and
    // anything past this is more than a person has configured.
    var names: [max_name_len * 8]u16 = undefined;
    var count: u32 = 0;
    var length: u32 = names.len;

    // `MUI_LANGUAGE_NAME` asks for BCP 47 tags rather than numeric `LANGID`s,
    // which is the difference between "en-US" and 0x0409.
    const ok = win32.GetUserPreferredUILanguages(
        win32.MUI_LANGUAGE_NAME,
        &count,
        &names,
        &length,
    );
    if (ok == 0) return buffer[0..0];

    return fromMultiString(buffer, names[0..@min(length, names.len)]);
}

/// The locale the user's numbers, dates and money are written in.
///
/// Windows keeps this apart from the display language -- it is the "regional
/// format" -- so it is the counterpart of `LC_NUMERIC`, `LC_TIME` and
/// `LC_MONETARY` together. Returns null off Windows, and null if the call
/// fails or names the invariant locale.
pub fn userDefaultLocale() ?Locale {
    if (!available) return null;

    // Sentinel-terminated, because that is what the call is declared to take:
    // it writes a NUL of its own and the type says so.
    var name: [max_name_len:0]u16 = undefined;
    const written = win32.GetUserDefaultLocaleName(&name, name.len);
    if (written <= 0) return null;

    // The count it returns includes that terminating NUL.
    return fromWideName(name[0 .. @as(usize, @intCast(written)) - 1]);
}

/// What each category should be formatted for, as Windows has it set.
///
/// The display language answers `messages`; the regional format answers the
/// other three, because Windows keeps one setting for all of them.
pub fn categories() Categories {
    var buffer: [1]Locale = undefined;
    const preferred = preferredUiLanguages(&buffer);
    const regional = userDefaultLocale();

    return .{
        .messages = if (preferred.len > 0) preferred[0] else regional,
        .numeric = regional,
        .time = regional,
        .monetary = regional,
    };
}

/// Parse the multi-string `GetUserPreferredUILanguages` fills in.
///
/// Windows returns a ranked list as one buffer of NUL-separated names with a
/// second NUL after the last, which is its usual way of returning a list. A
/// name that is not a language tag is skipped rather than ending the list.
pub fn fromMultiString(buffer: []Locale, names: []const u16) []Locale {
    var count: usize = 0;
    var rest = names;

    while (rest.len != 0 and count < buffer.len) {
        const end = std.mem.indexOfScalar(u16, rest, 0) orelse rest.len;
        // An empty name is the second NUL: the end of the list.
        if (end == 0) break;

        if (fromWideName(rest[0..end])) |locale| {
            buffer[count] = locale;
            count += 1;
        }
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    return buffer[0..count];
}

test fromMultiString {
    var buffer: [8]Locale = undefined;

    // The shape Windows produces: NUL between, NUL after the last.
    try expectChain(&.{ "en-US", "de-DE" }, fromMultiString(
        &buffer,
        std.unicode.utf8ToUtf16LeStringLiteral("en-US\x00de-DE\x00\x00"),
    ));

    // A single name, and an empty list.
    try expectChain(&.{"fr-FR"}, fromMultiString(
        &buffer,
        std.unicode.utf8ToUtf16LeStringLiteral("fr-FR\x00\x00"),
    ));
    try expectChain(&.{}, fromMultiString(&buffer, std.unicode.utf8ToUtf16LeStringLiteral("\x00")));
    try expectChain(&.{}, fromMultiString(&buffer, &.{}));

    // Windows' pseudo-locales, which it ships for testing that a layout
    // survives translation, are syntactically ordinary tags -- `qps` is in
    // BCP 47's private-use language range -- so they pass through and simply
    // match no bundle, which leaves the source locale showing. That is what
    // somebody who set one should see from a program with no pseudo-locale.
    try expectChain(&.{ "en-GB", "qps-Ploc", "ja-JP" }, fromMultiString(
        &buffer,
        std.unicode.utf8ToUtf16LeStringLiteral("en-GB\x00qps-ploc\x00ja-JP\x00\x00"),
    ));

    // A list longer than the buffer is truncated rather than refused.
    var small: [2]Locale = undefined;
    try expectChain(&.{ "en-US", "de-DE" }, fromMultiString(
        &small,
        std.unicode.utf8ToUtf16LeStringLiteral("en-US\x00de-DE\x00fr-FR\x00\x00"),
    ));
}

/// Parse one locale name as Windows writes it.
///
/// Windows already answers in BCP 47 -- `en-US`, `zh-Hans-CN`, `sr-Latn-RS` --
/// so there is little to do beyond what `Locale.parse` does. The empty name is
/// the invariant locale, which is Windows saying what `C` says on POSIX: no
/// preference, use the program's own language.
pub fn fromName(name: []const u8) ?Locale {
    if (name.len == 0) return null;
    return Locale.parse(name) catch null;
}

test fromName {
    try std.testing.expectEqualStrings("en-US", (fromName("en-US").?).tag());
    try std.testing.expectEqualStrings("zh-Hans-CN", (fromName("zh-Hans-CN").?).tag());
    try std.testing.expectEqualStrings("sr-Latn-RS", (fromName("sr-Latn-RS").?).tag());

    // The invariant locale, which is Windows for "do not translate".
    try std.testing.expectEqual(@as(?Locale, null), fromName(""));
    // A pseudo-locale is a real tag and is kept: `qps` is in BCP 47's
    // private-use language range, and no data will match it, which is exactly
    // what should happen.
    try std.testing.expectEqualStrings("qps-Ploc", (fromName("qps-ploc").?).tag());
    // Something that is not a tag at all is still refused.
    try std.testing.expectEqual(@as(?Locale, null), fromName("not a locale"));
}

/// Parse one UTF-16 locale name.
///
/// A BCP 47 tag is ASCII, so anything outside it is not one and the name is
/// refused rather than transliterated into something that might parse.
fn fromWideName(name: []const u16) ?Locale {
    var narrow: [max_name_len]u8 = undefined;
    if (name.len > narrow.len) return null;

    for (name, narrow[0..name.len]) |wide, *byte| {
        if (wide > 0x7F) return null;
        byte.* = @intCast(wide);
    }
    return fromName(narrow[0..name.len]);
}

test fromWideName {
    try std.testing.expectEqualStrings(
        "en-US",
        (fromWideName(std.unicode.utf8ToUtf16LeStringLiteral("en-US")).?).tag(),
    );
    // Not ASCII, so not a language tag.
    try std.testing.expectEqual(
        @as(?Locale, null),
        fromWideName(std.unicode.utf8ToUtf16LeStringLiteral("日本語")),
    );
    try std.testing.expectEqual(@as(?Locale, null), fromWideName(&.{}));
}

/// Compare a chain of locales against the tags it should hold.
fn expectChain(expected: []const []const u8, actual: []const Locale) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got.tag());
}

test preferredUiLanguages {
    var buffer: [8]Locale = undefined;
    const found = preferredUiLanguages(&buffer);
    // Off Windows this is empty; on Windows it is whatever the user has set,
    // and all that can be asserted without knowing that is that every entry
    // came back a usable locale.
    for (found) |locale| try std.testing.expect(locale.tag().len > 0);
}

test userDefaultLocale {
    if (userDefaultLocale()) |locale| {
        try std.testing.expect(locale.tag().len > 0);
    } else {
        // Which is the only answer possible off Windows.
        try std.testing.expect(!available);
    }
}

test categories {
    const found = categories();
    if (!available) {
        try std.testing.expectEqual(@as(?Locale, null), found.messages);
        try std.testing.expectEqual(@as(?Locale, null), found.numeric);
    }
}
