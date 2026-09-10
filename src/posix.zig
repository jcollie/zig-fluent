// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What language does this user read? -- as POSIX answers it.
//!
//! POSIX spreads the answer over four environment variables, ranks them, and
//! writes the answer in something that is not a language tag. This turns that
//! into the `Locale` values the rest of the library takes.
//!
//! ```zig
//! var buffer: [8]fluent.Locale = undefined;
//! const wanted = fluent.posix.fromEnviron(&buffer, init.environ_map);
//! ```
//!
//! ## The rules, and why they are what they are
//!
//! POSIX does not ask what your locale is, but what it is *for a given
//! category*: `LC_MESSAGES` decides what language to speak, `LC_NUMERIC` how
//! numbers are punctuated, `LC_TIME` how dates are written, `LC_MONETARY` how
//! money is. `LC_COLLATE` and `LC_CTYPE` are the other two, and govern sorting
//! and character classification, which this library does not do.
//!
//! For each of them: `LC_ALL` if it is set, else the category's own variable,
//! else `LANG`. `Categories` reads all four that matter here; `fromVariables`
//! answers the narrower question of which language to speak, and is the one
//! that ranks.
//!
//! `LC_ALL` overrides everything, then `LC_MESSAGES`, then `LANG`. GNU adds
//! `LANGUAGE`, which is a whole priority list rather than one locale, and
//! which is deliberately ignored when the others say `C` or say nothing: a
//! user who asked for no localization at all should not be handed some anyway
//! because a list was left set in a shell profile.
//!
//! A name is `language[_territory][.codeset][@modifier]`. The codeset is about
//! bytes rather than language and is dropped. Most modifiers are variants --
//! `@euro`, `@valencia` -- and are dropped too, but a few name a script, and
//! `sr_RS@latin` really is Serbian written in Latin rather than Cyrillic, so
//! those are kept and turned into the script subtag they mean.
//!
//! ## Not Windows
//!
//! Windows has none of these variables. `GetUserDefaultLocaleName` is the
//! equivalent, it already answers in a BCP 47 tag, and `Locale.parse` takes
//! its answer directly. Nothing here helps there, and nothing here is needed.

const std = @import("std");

const Locale = @import("locale.zig").Locale;

/// The environment variables that decide the language, most significant last.
///
/// Taken as a struct rather than read from the process, so that the rules can
/// be applied to values from anywhere -- a test, a configuration file, a
/// request header, a server deciding on behalf of a user who is not the one
/// running the process. `fromEnviron` is the five-line adapter for a real
/// environment.
pub const Variables = struct {
    /// `LANGUAGE`: a colon-separated list, in the user's own order.
    language: ?[]const u8 = null,
    /// `LC_ALL`: overrides every other category.
    lc_all: ?[]const u8 = null,
    /// `LC_MESSAGES`: the category that decides what language to speak.
    lc_messages: ?[]const u8 = null,
    /// `LC_NUMERIC`: how numbers are punctuated.
    lc_numeric: ?[]const u8 = null,
    /// `LC_TIME`: how dates and times are written.
    lc_time: ?[]const u8 = null,
    /// `LC_MONETARY`: how amounts of money are written.
    lc_monetary: ?[]const u8 = null,
    /// `LANG`: the default for every category.
    lang: ?[]const u8 = null,
};

/// One locale per category. See `fluent.Categories`.
pub const Categories = @import("locale.zig").Categories;

/// The locale each category asks for.
///
/// The precedence is POSIX's, per category: `LC_ALL` if it is set, else the
/// category's own variable, else `LANG`. `LANGUAGE` plays no part -- it is
/// gettext's, it ranks translations, and there is nothing to rank about a
/// decimal separator.
pub fn categoriesFromVariables(variables: Variables) Categories {
    return .{
        .messages = categoryLocale(variables, variables.lc_messages),
        .numeric = categoryLocale(variables, variables.lc_numeric),
        .time = categoryLocale(variables, variables.lc_time),
        .monetary = categoryLocale(variables, variables.lc_monetary),
    };
}

test categoriesFromVariables {
    // The common shape: English messages, a British clock, German numbers.
    const mixed = categoriesFromVariables(.{
        .lang = "en_US.UTF-8",
        .lc_time = "en_GB.UTF-8",
        .lc_numeric = "de_DE.UTF-8",
    });
    try std.testing.expectEqualStrings("en-US", mixed.messages.?.tag());
    try std.testing.expectEqualStrings("en-GB", mixed.time.?.tag());
    try std.testing.expectEqualStrings("de-DE", mixed.numeric.?.tag());
    // Unset, so it falls to `LANG` like the rest.
    try std.testing.expectEqualStrings("en-US", mixed.monetary.?.tag());

    // `LC_ALL` overrides every category, however they were set.
    const all = categoriesFromVariables(.{
        .lc_all = "fr_FR.UTF-8",
        .lc_time = "en_GB",
        .lc_numeric = "de_DE",
        .lang = "ja_JP",
    });
    try std.testing.expectEqualStrings("fr-FR", all.time.?.tag());
    try std.testing.expectEqualStrings("fr-FR", all.numeric.?.tag());

    // Nothing set, or set to `C`: no preference at all.
    const none = categoriesFromVariables(.{});
    try std.testing.expectEqual(@as(?Locale, null), none.messages);
    const posix_c = categoriesFromVariables(.{ .lang = "C", .lc_time = "C" });
    try std.testing.expectEqual(@as(?Locale, null), posix_c.time);
}

/// The locale each category asks for, from the process's own environment.
pub fn categoriesFromEnviron(environ: *const std.process.Environ.Map) Categories {
    return categoriesFromVariables(variablesFromEnviron(environ));
}

test categoriesFromEnviron {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try environ.put("LANG", "en_US.UTF-8");
    try environ.put("LC_TIME", "en_GB.UTF-8");

    const categories = categoriesFromEnviron(&environ);
    try std.testing.expectEqualStrings("en-US", categories.messages.?.tag());
    try std.testing.expectEqualStrings("en-GB", categories.time.?.tag());
}

/// Resolve one category: `LC_ALL`, else the category's own value, else `LANG`.
fn categoryLocale(variables: Variables, specific: ?[]const u8) ?Locale {
    const name = variables.lc_all orelse specific orelse variables.lang orelse return null;
    return fromName(name);
}

test categoryLocale {
    const variables: Variables = .{ .lc_all = null, .lang = "de_DE", .lc_time = "en_GB" };
    try std.testing.expectEqualStrings("en-GB", categoryLocale(variables, variables.lc_time).?.tag());
    // A category with no variable of its own falls through to `LANG`.
    try std.testing.expectEqualStrings("de-DE", categoryLocale(variables, null).?.tag());
}

/// The locales these variables ask for, most preferred first.
///
/// Writes into `buffer` and returns the part of it that was filled, so nothing
/// is allocated and the result lives as long as the caller's array. A chain
/// longer than the buffer is truncated: past a handful nobody is being served
/// better.
///
/// An empty result means "no preference" -- the variables are unset, or say
/// `C` -- and a caller should use whatever locale its own messages are written
/// in.
pub fn fromVariables(buffer: []Locale, variables: Variables) []Locale {
    // The category that decides the language, by POSIX's precedence.
    const base = variables.lc_all orelse variables.lc_messages orelse variables.lang orelse "";

    // `LANGUAGE` is honoured only when a real locale is in force. This is
    // gettext's rule, and the reason for it is that `LC_ALL=C` is how somebody
    // says "no translations, please" -- a `LANGUAGE` left over in a profile
    // must not undo that.
    if (isUnlocalized(base)) return buffer[0..0];

    var count: usize = 0;
    if (variables.language) |list| count = fromList(buffer, list).len;

    // Then the base category itself, behind anything `LANGUAGE` ranked.
    if (count < buffer.len) {
        if (fromName(base)) |locale| {
            buffer[count] = locale;
            count += 1;
        }
    }
    return buffer[0..count];
}

test fromVariables {
    var buffer: [8]Locale = undefined;

    // `LANG` is the usual one.
    try expectChain(&.{"fr-CA"}, fromVariables(&buffer, .{ .lang = "fr_CA.UTF-8" }));

    // `LC_ALL` overrides it, and `LC_MESSAGES` sits between them.
    try expectChain(&.{"de-DE"}, fromVariables(&buffer, .{
        .lc_all = "de_DE.UTF-8",
        .lc_messages = "es_ES",
        .lang = "fr_CA",
    }));

    // `LANGUAGE` is a ranked list and comes first, with the base behind it.
    try expectChain(&.{ "ru", "ja", "de-DE" }, fromVariables(&buffer, .{
        .language = "ru:ja",
        .lang = "de_DE.UTF-8",
    }));

    // But a user who asked for no localization is not given some anyway,
    // however long their `LANGUAGE` list is.
    try expectChain(&.{}, fromVariables(&buffer, .{ .language = "ru:ja", .lc_all = "C" }));
    try expectChain(&.{}, fromVariables(&buffer, .{ .language = "ru:ja" }));
    try expectChain(&.{}, fromVariables(&buffer, .{}));
}

/// The locales the process's own environment asks for.
///
/// A thin adapter over `fromVariables`; see it for the rules. Zig hands the
/// environment to `main` as part of `std.process.Init`.
pub fn fromEnviron(buffer: []Locale, environ: *const std.process.Environ.Map) []Locale {
    return fromVariables(buffer, variablesFromEnviron(environ));
}

/// Read the variables this module cares about out of a real environment.
fn variablesFromEnviron(environ: *const std.process.Environ.Map) Variables {
    return .{
        .language = environ.get("LANGUAGE"),
        .lc_all = environ.get("LC_ALL"),
        .lc_messages = environ.get("LC_MESSAGES"),
        .lc_numeric = environ.get("LC_NUMERIC"),
        .lc_time = environ.get("LC_TIME"),
        .lc_monetary = environ.get("LC_MONETARY"),
        .lang = environ.get("LANG"),
    };
}

test variablesFromEnviron {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("LANG", "de_DE.UTF-8");
    try environ.put("LC_TIME", "en_GB.UTF-8");

    const variables = variablesFromEnviron(&environ);
    try std.testing.expectEqualStrings("de_DE.UTF-8", variables.lang.?);
    try std.testing.expectEqualStrings("en_GB.UTF-8", variables.lc_time.?);
    try std.testing.expectEqual(@as(?[]const u8, null), variables.lc_all);
}

test fromEnviron {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    var buffer: [8]Locale = undefined;
    try expectChain(&.{}, fromEnviron(&buffer, &environ));

    try environ.put("LANG", "de_DE.UTF-8");
    try environ.put("LANGUAGE", "fr:de");
    try expectChain(&.{ "fr", "de", "de-DE" }, fromEnviron(&buffer, &environ));
}

/// The locales in a colon-separated list, as `LANGUAGE` is written.
///
/// Entries that name nothing -- an empty one, or `C` -- are skipped rather
/// than ending the list, since a stray colon should not silently discard
/// everything a user ranked after it.
pub fn fromList(buffer: []Locale, list: []const u8) []Locale {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |item| {
        if (count == buffer.len) break;
        if (fromName(item)) |locale| {
            buffer[count] = locale;
            count += 1;
        }
    }
    return buffer[0..count];
}

test fromList {
    var buffer: [8]Locale = undefined;

    try expectChain(&.{ "de-DE", "fr", "en" }, fromList(&buffer, "de_DE.UTF-8:fr:en"));
    // A stray colon, and an entry asking for no translation, are stepped over.
    try expectChain(&.{ "de", "fr" }, fromList(&buffer, "de::C:fr"));
    try expectChain(&.{}, fromList(&buffer, ""));

    // A list longer than the buffer is truncated rather than refused.
    var small: [2]Locale = undefined;
    try expectChain(&.{ "de", "fr" }, fromList(&small, "de:fr:en:ja"));
}

/// Turn one POSIX locale name into a language tag.
///
/// `de_DE.UTF-8@euro` and `de-DE` name the same locale: the codeset says how
/// bytes are encoded and the modifier is usually a variant, and neither keys
/// anything here. A modifier that names a script is the exception and is kept
/// -- `sr_RS@latin` is Serbian in Latin script, which is a different locale
/// from Serbian in Cyrillic and formats differently.
///
/// Returns null for a name that asks for no translation, and for one that is
/// not a locale at all.
pub fn fromName(name: []const u8) ?Locale {
    if (isUnlocalized(name)) return null;

    var rest = name;

    var script: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        script = scriptForModifier(rest[at + 1 ..]);
        rest = rest[0..at];
    }
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| rest = rest[0..dot];
    if (rest.len == 0) return null;

    const found = script orelse return Locale.parse(rest) catch null;

    // Put the script where BCP 47 wants it, between the language and the
    // region, and let `Locale.parse` do the rest.
    const parsed = Locale.parse(rest) catch return null;
    var tag: [Locale.max_tag_len]u8 = undefined;
    var w = std.Io.Writer.fixed(&tag);
    w.print("{s}-{s}", .{ parsed.language(), found }) catch return parsed;
    if (parsed.region()) |region| w.print("-{s}", .{region}) catch return parsed;

    return Locale.parse(w.buffered()) catch parsed;
}

test fromName {
    // The shapes POSIX actually produces.
    try std.testing.expectEqualStrings("de-DE", (fromName("de_DE.UTF-8").?).tag());
    try std.testing.expectEqualStrings("de-DE", (fromName("de_DE@euro").?).tag());
    try std.testing.expectEqualStrings("pt-BR", (fromName("pt_BR").?).tag());
    try std.testing.expectEqualStrings("en", (fromName("en").?).tag());

    // A modifier that names a script really does name a different locale.
    try std.testing.expectEqualStrings("sr-Latn-RS", (fromName("sr_RS@latin").?).tag());
    try std.testing.expectEqualStrings("uz-Cyrl", (fromName("uz@cyrillic").?).tag());
    try std.testing.expectEqualStrings("sd-Deva-IN", (fromName("sd_IN@devanagari").?).tag());

    // And the names that mean "no translation, thank you".
    try std.testing.expectEqual(@as(?Locale, null), fromName("C"));
    try std.testing.expectEqual(@as(?Locale, null), fromName("POSIX"));
    try std.testing.expectEqual(@as(?Locale, null), fromName("C.UTF-8"));
    try std.testing.expectEqual(@as(?Locale, null), fromName(""));
    try std.testing.expectEqual(@as(?Locale, null), fromName("not a locale"));
}

/// Whether a POSIX locale name means "do not localize".
///
/// `C` and `POSIX` are one locale under two names, and both mean the user
/// wants the program's own language rather than a translation of it. An unset
/// variable arrives here as the empty string and means the same.
pub fn isUnlocalized(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "POSIX") or
        std.mem.startsWith(u8, name, "C.") or
        std.mem.startsWith(u8, name, "POSIX.");
}

test isUnlocalized {
    try std.testing.expect(isUnlocalized(""));
    try std.testing.expect(isUnlocalized("C"));
    try std.testing.expect(isUnlocalized("POSIX"));
    try std.testing.expect(isUnlocalized("C.UTF-8"));
    try std.testing.expect(!isUnlocalized("de_DE.UTF-8"));
    // Not a prefix match on the language: Catalan is not `C`.
    try std.testing.expect(!isUnlocalized("ca_ES"));
}

/// The script subtag a glibc modifier names, if it names one.
///
/// Most modifiers are variants and collations -- `@euro`, `@valencia`,
/// `@abegede` -- and mean nothing to CLDR. These four are the ones that say
/// what alphabet the language is written in, which is a different locale
/// rather than a flavour of the same one.
fn scriptForModifier(modifier: []const u8) ?[]const u8 {
    const known = .{
        .{ "latin", "Latn" },
        .{ "cyrillic", "Cyrl" },
        .{ "devanagari", "Deva" },
        .{ "arabic", "Arab" },
    };
    inline for (known) |pair| {
        if (std.ascii.eqlIgnoreCase(modifier, pair[0])) return pair[1];
    }
    return null;
}

test scriptForModifier {
    try std.testing.expectEqualStrings("Latn", scriptForModifier("latin").?);
    try std.testing.expectEqualStrings("Cyrl", scriptForModifier("cyrillic").?);
    // A modifier about currency or collation names no script.
    try std.testing.expectEqual(@as(?[]const u8, null), scriptForModifier("euro"));
    try std.testing.expectEqual(@as(?[]const u8, null), scriptForModifier("valencia"));
}

/// Compare a chain of locales against the tags it should hold.
///
/// `expectEqualSlices` would compare the `Locale` values themselves, which
/// carry an undefined tail beyond their length, so the comparison is on tags.
fn expectChain(expected: []const []const u8, actual: []const Locale) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got.tag());
}
