// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Ask the environment what language the user reads, pick the closest
//! translation of the ones shipped, and print some messages in it.
//!
//! ```console
//! $ LANG=de_DE.UTF-8 zig build example
//! $ zig build example -- ru            # or say so directly
//! ```
//!
//! The three steps are the whole of what an application has to do, and only
//! the middle one is really this library's business:
//!
//!  1. **What did the user ask for?** POSIX answers with `LANGUAGE`, `LC_ALL`,
//!     `LC_MESSAGES` and `LANG`, which are not language tags and have to be
//!     translated into them.
//!  2. **What do we have?** One `Bundle` per translation, and a negotiation
//!     between what was asked for and what was shipped.
//!  3. **Say it.** `bundle.format`, with the arguments the message needs.
//!
//! Everything grammatical stays inside the `.ftl` files. This program passes a
//! count, a name, a gender and a moment, and never learns that Russian needs
//! four plural forms where English needs two, that German puts the date before
//! the object, or that Japanese counts photos with 枚.

const std = @import("std");
const fluent = @import("fluent");

const Locale = fluent.Locale;

/// The translations shipped with the program.
///
/// Embedded rather than read from disk, which is the usual deployment shape:
/// there is no data directory to install, and a missing translation is a
/// build error rather than something a user discovers.
///
/// The first entry is the source locale and is the last resort, which is why
/// its translation must be complete.
const catalog = [_]struct { tag: []const u8, source: []const u8 }{
    .{ .tag = "en-US", .source = @embedFile("locales/en-US.ftl") },
    .{ .tag = "de", .source = @embedFile("locales/de.ftl") },
    .{ .tag = "fr", .source = @embedFile("locales/fr.ftl") },
    .{ .tag = "ru", .source = @embedFile("locales/ru.ftl") },
    .{ .tag = "ja", .source = @embedFile("locales/ja.ftl") },
};

/// The most locales a user can ask for. `LANGUAGE` is a list, and the rest
/// contribute one each; beyond this many nobody is being served better.
const max_requested = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // -- 1. what the user asked for --------------------------------------
    var requested_buffer: [max_requested]Locale = undefined;
    const requested = if ((try init.minimal.args.toSlice(init.arena.allocator())).len > 1)
        // An argument overrides the environment, so the example can be tried
        // without exporting anything.
        fromList(&requested_buffer, (try init.minimal.args.toSlice(init.arena.allocator()))[1])
    else
        fromEnvironment(&requested_buffer, init.environ_map);

    // -- 2. what we have --------------------------------------------------
    var bundles: [catalog.len]fluent.Bundle = undefined;
    var built: usize = 0;
    defer for (bundles[0..built]) |*bundle| bundle.deinit();

    for (catalog) |entry| {
        bundles[built] = try .init(gpa, try .parse(entry.tag));
        built += 1;

        // Off, because this is a terminal. Isolation wraps every interpolation
        // in U+2068 and U+2069 so that a right-to-left name dropped into a
        // left-to-right sentence does not drag the punctuation around it to
        // the wrong end of the line. A browser honours those marks; a terminal
        // prints them. Leave it on wherever the text is going into a paragraph
        // a person reads, which is most places.
        bundles[built - 1].use_isolating = false;

        var errors: fluent.Errors = .empty;
        defer errors.deinit(gpa);

        try bundles[built - 1].addResource(entry.source, .{}, &errors);
        // A translation that does not parse is a bug in this repository, not
        // something to paper over at run time.
        for (errors.items) |err| std.debug.panic("{s}: {f}", .{ entry.tag, err });
    }

    const chosen = negotiate(&bundles, requested);

    // -- 3. say it --------------------------------------------------------
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;

    try out.print("requested:", .{});
    if (requested.len == 0) try out.print(" (nothing; the environment is unset or C)", .{});
    for (requested) |locale| try out.print(" {f}", .{locale});
    try out.print("\nshowing:   {f}\n\n", .{chosen.locale});

    // 2026-02-14T09:30:00Z, fixed so that running this twice says the same
    // thing. A real application would read a clock.
    const when: i64 = 1_771_061_400_000;

    try say(out, chosen, gpa, "welcome", &.{});
    for ([_]f64{ 0, 1, 2, 5, 21 }) |count| {
        try say(out, chosen, gpa, "new-photos", &.{
            .{ .name = "count", .value = .num(count) },
        });
    }
    try say(out, chosen, gpa, "shared-with-you", &.{
        .{ .name = "user", .value = .{ .string = "Ada" } },
        .{ .name = "gender", .value = .{ .string = "female" } },
        .{ .name = "count", .value = .num(3) },
        .{ .name = "when", .value = .time(when) },
    });
    try say(out, chosen, gpa, "storage", &.{
        .{ .name = "used", .value = .num(12345.678) },
        .{ .name = "total", .value = .num(50000) },
    });

    try out.flush();
}

/// Format one message and print it, or say plainly that it is missing.
///
/// Missing is worth printing rather than skipping: a translation that has
/// fallen behind is invisible otherwise, and this is the shape a `--lint` mode
/// would grow out of.
fn say(
    out: *std.Io.Writer,
    bundle: *const fluent.Bundle,
    gpa: std.mem.Allocator,
    name: []const u8,
    args: fluent.Args,
) !void {
    const text = try bundle.format(gpa, name, args, null) orelse {
        try out.print("  {s}: <missing>\n", .{name});
        return;
    };
    defer gpa.free(text);
    try out.print("  {s}\n", .{text});
}

// -- what the user asked for -------------------------------------------------

/// The locales the environment asks for, most preferred first.
///
/// POSIX spreads the answer over four variables and gives them a precedence:
/// `LC_ALL` overrides everything, then `LC_MESSAGES`, then `LANG`. GNU adds
/// `LANGUAGE`, which is a whole priority list rather than one locale and which
/// is deliberately ignored when the others say `C` -- a user who asked for no
/// localization at all should not be given some anyway.
///
/// Windows has none of these; `GetUserDefaultLocaleName` is the equivalent
/// there, and an application targeting it should call that instead.
pub fn fromEnvironment(buffer: *[max_requested]Locale, env: *const std.process.Environ.Map) []Locale {
    const base = env.get("LC_ALL") orelse env.get("LC_MESSAGES") orelse env.get("LANG") orelse "";
    if (isUnlocalized(base)) return buffer[0..0];

    var count: usize = 0;
    // `LANGUAGE` first, since it is the list the user ranked.
    if (env.get("LANGUAGE")) |list| count = fromList(buffer, list).len;

    if (count < buffer.len) {
        if (parsePosix(base)) |locale| {
            buffer[count] = locale;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// The locales in a colon-separated list such as `"de:fr:en"`.
pub fn fromList(buffer: *[max_requested]Locale, list: []const u8) []Locale {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |item| {
        if (count == buffer.len) break;
        if (parsePosix(item)) |locale| {
            buffer[count] = locale;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// Turn one POSIX locale name into a language tag.
///
/// They are close to BCP 47 but not the same: `de_DE.UTF-8@euro` names the
/// same locale as `de-DE`, with a character set and a variant this library has
/// no use for. The codeset and the modifier are dropped and the separator is
/// normalized; `Locale.parse` does the rest.
pub fn parsePosix(name: []const u8) ?Locale {
    if (isUnlocalized(name)) return null;

    var rest = name;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[0..at];
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| rest = rest[0..dot];
    if (rest.len == 0) return null;

    return Locale.parse(rest) catch null;
}

/// Whether a POSIX locale name means "do not localize".
///
/// `C` and `POSIX` are the same locale under two names, and both mean the
/// user wants the program's own language rather than a translation.
fn isUnlocalized(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "POSIX") or
        std.mem.startsWith(u8, name, "C.");
}

// -- what we have ------------------------------------------------------------

/// The bundle that best serves the locales the user asked for.
///
/// Each requested locale is tried in turn, and for each one the bundles are
/// searched for the closest match: the same tag, then the same language and
/// script, then merely the same language. Asking in that order matters --
/// somebody who asks for `fr` before `en` should get French even though an
/// `en-US` bundle exists and is a better match for nothing they said.
///
/// When nothing matches, the first bundle. It is the source locale, its
/// translation is by construction complete, and printing English is a better
/// outcome than printing message names.
pub fn negotiate(bundles: []const fluent.Bundle, requested: []const Locale) *const fluent.Bundle {
    for (requested) |want| {
        // Exact, then language and script, then language: three passes rather
        // than one, so that a better match later in the list beats a worse
        // match earlier in it.
        for (0..3) |pass| {
            for (bundles) |*bundle| {
                if (matches(&bundle.locale, &want, pass)) return bundle;
            }
        }
    }
    return &bundles[0];
}

/// Whether `have` serves `want` at a given level of exactness.
fn matches(have: *const Locale, want: *const Locale, pass: usize) bool {
    if (!std.mem.eql(u8, have.language(), want.language())) return false;
    return switch (pass) {
        0 => have.eql(want),
        1 => scriptsAgree(have, want),
        else => true,
    };
}

/// Whether two locales name the same script, counting "unstated" as agreeing.
fn scriptsAgree(a: *const Locale, b: *const Locale) bool {
    const left = a.script() orelse return true;
    const right = b.script() orelse return true;
    return std.mem.eql(u8, left, right);
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test parsePosix {
    // The shapes POSIX actually produces.
    try testing.expectEqualStrings("de-DE", (parsePosix("de_DE.UTF-8").?).tag());
    try testing.expectEqualStrings("de-DE", (parsePosix("de_DE@euro").?).tag());
    try testing.expectEqualStrings("pt-BR", (parsePosix("pt_BR").?).tag());
    try testing.expectEqualStrings("en", (parsePosix("en").?).tag());

    // And the ones that mean "no translation, thank you".
    try testing.expectEqual(@as(?Locale, null), parsePosix("C"));
    try testing.expectEqual(@as(?Locale, null), parsePosix("POSIX"));
    try testing.expectEqual(@as(?Locale, null), parsePosix("C.UTF-8"));
    try testing.expectEqual(@as(?Locale, null), parsePosix(""));
    try testing.expectEqual(@as(?Locale, null), parsePosix("not a locale"));
}

test fromList {
    var buffer: [max_requested]Locale = undefined;

    const three = fromList(&buffer, "de_DE.UTF-8:fr:en");
    try testing.expectEqual(@as(usize, 3), three.len);
    try testing.expectEqualStrings("de-DE", three[0].tag());
    try testing.expectEqualStrings("fr", three[1].tag());
    try testing.expectEqualStrings("en", three[2].tag());

    // Entries that name nothing are skipped rather than ending the list.
    const sparse = fromList(&buffer, "de::C:fr");
    try testing.expectEqual(@as(usize, 2), sparse.len);
    try testing.expectEqualStrings("de", sparse[0].tag());
    try testing.expectEqualStrings("fr", sparse[1].tag());
}

test fromEnvironment {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var buffer: [max_requested]Locale = undefined;

    // Nothing set at all: no preference, so the source locale will be used.
    try testing.expectEqual(@as(usize, 0), fromEnvironment(&buffer, &env).len);

    // `LANG` is the usual one.
    try env.put("LANG", "fr_CA.UTF-8");
    var chain = fromEnvironment(&buffer, &env);
    try testing.expectEqual(@as(usize, 1), chain.len);
    try testing.expectEqualStrings("fr-CA", chain[0].tag());

    // `LC_ALL` overrides it.
    try env.put("LC_ALL", "de_DE.UTF-8");
    chain = fromEnvironment(&buffer, &env);
    try testing.expectEqualStrings("de-DE", chain[0].tag());

    // `LANGUAGE` is a ranked list and comes first, with the others behind it.
    try env.put("LANGUAGE", "ru:ja");
    chain = fromEnvironment(&buffer, &env);
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqualStrings("ru", chain[0].tag());
    try testing.expectEqualStrings("ja", chain[1].tag());
    try testing.expectEqualStrings("de-DE", chain[2].tag());

    // ...but a user who asked for no localization is not given some anyway,
    // however long their `LANGUAGE` list is.
    try env.put("LC_ALL", "C");
    try testing.expectEqual(@as(usize, 0), fromEnvironment(&buffer, &env).len);
}

/// Build the catalog's bundles for a test, without their resources.
///
/// Only the locales matter here; negotiation never looks at the messages.
fn testBundles(into: []fluent.Bundle) ![]fluent.Bundle {
    for (catalog, 0..) |entry, i| {
        into[i] = try .init(testing.allocator, try .parse(entry.tag));
    }
    return into[0..catalog.len];
}

test negotiate {
    var storage: [catalog.len]fluent.Bundle = undefined;
    const bundles = try testBundles(&storage);
    defer for (bundles) |*bundle| bundle.deinit();

    var buffer: [max_requested]Locale = undefined;

    // An exact tag.
    try testing.expectEqualStrings("de", negotiate(bundles, fromList(&buffer, "de")).locale.tag());
    // A region we do not ship falls back to the language we do.
    try testing.expectEqualStrings("de", negotiate(bundles, fromList(&buffer, "de_AT")).locale.tag());
    // And a language we do not ship at all falls through to the next asked
    // for, rather than to the source locale.
    try testing.expectEqualStrings(
        "fr",
        negotiate(bundles, fromList(&buffer, "is:fr:de")).locale.tag(),
    );
    // Order is the user's, not ours: `fr` before `en` means French, even
    // though `en-US` is on the shelf.
    try testing.expectEqualStrings("fr", negotiate(bundles, fromList(&buffer, "fr:en")).locale.tag());
    // Nothing asked for, or nothing we have: the source locale.
    try testing.expectEqualStrings("en-US", negotiate(bundles, &.{}).locale.tag());
    try testing.expectEqualStrings(
        "en-US",
        negotiate(bundles, fromList(&buffer, "is:mt")).locale.tag(),
    );
}

test "every shipped translation parses and defines every message" {
    // The catalog is data, and this is what keeps it honest: a translation
    // that has fallen behind, or that has a broken plural in it, fails here
    // rather than printing a message name to a user.
    var reference: fluent.Bundle = try .init(testing.allocator, try .parse(catalog[0].tag));
    defer reference.deinit();
    try reference.addResource(catalog[0].source, .{}, null);

    for (catalog) |entry| {
        var bundle: fluent.Bundle = try .init(testing.allocator, try .parse(entry.tag));
        defer bundle.deinit();

        var errors: fluent.Errors = .empty;
        defer errors.deinit(testing.allocator);
        try bundle.addResource(entry.source, .{}, &errors);

        for (errors.items) |err| {
            std.debug.print("{s}: {f}\n", .{ entry.tag, err });
        }
        try testing.expectEqual(@as(usize, 0), errors.items.len);

        var it = reference.messages.iterator();
        while (it.next()) |message| {
            if (!bundle.hasMessage(message.key_ptr.*)) {
                std.debug.print("{s}: missing message {s}\n", .{ entry.tag, message.key_ptr.* });
                return error.IncompleteTranslation;
            }
        }
    }
}

test "every shipped translation formats without reporting an error" {
    // Formatting each message in each language, with the arguments the
    // program actually passes. A variable a translator misspelled shows up
    // here as an unknown-variable error rather than as a hole in a sentence.
    const args: fluent.Args = &.{
        .{ .name = "user", .value = .{ .string = "Ada" } },
        .{ .name = "gender", .value = .{ .string = "female" } },
        .{ .name = "count", .value = .num(3) },
        .{ .name = "when", .value = .time(1_771_061_400_000) },
        .{ .name = "used", .value = .num(12345.678) },
        .{ .name = "total", .value = .num(50000) },
    };

    for (catalog) |entry| {
        var bundle: fluent.Bundle = try .init(testing.allocator, try .parse(entry.tag));
        defer bundle.deinit();
        try bundle.addResource(entry.source, .{}, null);

        var errors: fluent.Errors = .empty;
        defer errors.deinit(testing.allocator);

        var it = bundle.messages.iterator();
        while (it.next()) |message| {
            const text = try bundle.format(testing.allocator, message.key_ptr.*, args, &errors) orelse continue;
            defer testing.allocator.free(text);
            try testing.expect(text.len > 0);
        }

        for (errors.items) |err| std.debug.print("{s}: {f}\n", .{ entry.tag, err });
        try testing.expectEqual(@as(usize, 0), errors.items.len);
    }
}
