// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Ask the environment what language the user reads, pick the closest
//! translation of the ones shipped, and print some messages in it.
//!
//! ```console
//! $ LANG=de_DE.UTF-8 zig build example
//! $ zig build example -- fi            # or say so directly
//! ```
//!
//! The three steps are the whole of what an application has to do, and only
//! the middle one is really this library's business:
//!
//!  1. **What did the user ask for?** POSIX answers with `LANGUAGE`, `LC_ALL`,
//!     `LC_MESSAGES` and `LANG`, which are not language tags; Windows answers
//!     with an API instead. `fluent.system` asks whichever is running.
//!  2. **What do we have?** One `Bundle` per translation, and a negotiation
//!     between what was asked for and what was shipped.
//!  3. **Say it.** `bundle.format`, with the arguments the message needs.
//!
//! Everything grammatical stays inside the `.ftl` files. This program passes a
//! count, a name, a gender and a moment, and never learns that Polish needs
//! four plural forms where English needs two and agrees its past tense with
//! the sharer, that Finnish counts photos in the partitive and has no use for
//! a gender at all, that German puts the date before the object, or that
//! Japanese counts them with 枚.

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
    .{ .tag = "fi", .source = @embedFile("locales/fi.ftl") },
    .{ .tag = "pl", .source = @embedFile("locales/pl.ftl") },
    .{ .tag = "ja", .source = @embedFile("locales/ja.ftl") },
};

/// The most locales a user can ask for. `LANGUAGE` is a list, and the rest
/// contribute one each; beyond this many nobody is being served better.
const max_requested = 8;

/// The locales this run should try, in order.
///
/// An argument overrides the environment, so the example can be tried without
/// exporting anything.
fn requestedLocales(buffer: []Locale, init: std.process.Init) ![]Locale {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) return fluent.posix.fromList(buffer, args[1]);
    return fluent.system.preferredLocales(buffer, init.environ_map);
}

/// Read the environment, choose a bundle, and print in that language.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // -- 1. what the user asked for --------------------------------------
    var requested_buffer: [max_requested]Locale = undefined;
    const wanted = try requestedLocales(&requested_buffer, init);

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

    const chosen = negotiate(&bundles, wanted);

    // POSIX lets a user set the language apart from the way numbers and dates
    // are written, and it is an ordinary thing to want: English messages with
    // a twenty-four hour clock is `LANG=en_US.UTF-8 LC_TIME=en_GB.UTF-8`.
    // Without this, that user is shown "2:03 PM".
    //
    // The message language is not touched, so the plural rules stay those of
    // the language the text is written in.
    const categories = fluent.system.categories(init.environ_map);
    fluent.system.applyCategories(chosen, categories);

    // -- 3. say it --------------------------------------------------------
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;

    try out.print("requested:", .{});
    if (wanted.len == 0) try out.print(" (nothing; the environment is unset or C)", .{});
    for (wanted) |locale| try out.print(" {f}", .{locale});
    try out.print("\nshowing:   {f}", .{chosen.locale});
    // Only worth reporting when the user actually asked for a category to
    // differ. `LANG` alone sets every category to the same thing, and saying
    // so three times is noise rather than information.
    if (categories.messages) |messages| {
        if (categories.numeric) |locale| {
            if (!locale.eql(&messages)) try out.print("  (numbers: {f})", .{locale});
        }
        if (categories.monetary) |locale| {
            if (!locale.eql(&messages)) try out.print("  (money: {f})", .{locale});
        }
        if (categories.time) |locale| {
            if (!locale.eql(&messages)) try out.print("  (dates: {f})", .{locale});
        }
    }
    try out.print("\n\n", .{});

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
pub fn negotiate(bundles: []fluent.Bundle, requested: []const Locale) *fluent.Bundle {
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
    try testing.expectEqualStrings("de", negotiate(bundles, fluent.posix.fromList(&buffer, "de")).locale.tag());
    // A region we do not ship falls back to the language we do.
    try testing.expectEqualStrings("de", negotiate(bundles, fluent.posix.fromList(&buffer, "de_AT")).locale.tag());
    // And a language we do not ship at all falls through to the next asked
    // for, rather than to the source locale.
    try testing.expectEqualStrings(
        "fr",
        negotiate(bundles, fluent.posix.fromList(&buffer, "is:fr:de")).locale.tag(),
    );
    // Order is the user's, not ours: `fr` before `en` means French, even
    // though `en-US` is on the shelf.
    try testing.expectEqualStrings("fr", negotiate(bundles, fluent.posix.fromList(&buffer, "fr:en")).locale.tag());
    // Nothing asked for, or nothing we have: the source locale.
    try testing.expectEqualStrings("en-US", negotiate(bundles, &.{}).locale.tag());
    try testing.expectEqualStrings(
        "en-US",
        negotiate(bundles, fluent.posix.fromList(&buffer, "is:mt")).locale.tag(),
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

test "the Polish translation counts four ways and agrees with gender" {
    // The two things `pl.ftl` is in the catalog for, and the tests around this
    // one reach neither: they pass a single gender and a single count.
    var bundle: fluent.Bundle = try .init(testing.allocator, try .parse("pl"));
    defer bundle.deinit();
    // Off so that the assertions can be written as the text a reader sees;
    // see `bundleFor` in tests/bundle.zig for the same reasoning.
    bundle.use_isolating = false;
    try bundle.addResource(@embedFile("locales/pl.ftl"), .{}, null);

    const counted = [_]struct { count: f64, want: []const u8 }{
        .{ .count = 0, .want = "Brak nowych zdjęć" },
        .{ .count = 1, .want = "1 nowe zdjęcie" },
        .{ .count = 2, .want = "2 nowe zdjęcia" },
        .{ .count = 5, .want = "5 nowych zdjęć" },
        // The rule worth pinning: 2 to 4 are `few` and 12 to 14 are not, so
        // 22 agrees with 2 and 12 agrees with 5.
        .{ .count = 12, .want = "12 nowych zdjęć" },
        .{ .count = 22, .want = "22 nowe zdjęcia" },
        // And a fraction is `other`, which Polish puts in the genitive
        // singular rather than the genitive plural whole numbers take.
        .{ .count = 1.5, .want = "1,5 nowego zdjęcia" },
    };

    for (counted) |case| {
        const args: fluent.Args = &.{.{ .name = "count", .value = .num(case.count) }};
        const text = try bundle.format(testing.allocator, "new-photos", args, null) orelse
            return error.MissingMessage;
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.want, text);
    }

    // The past tense agrees with the sharer, which is the whole reason the
    // program passes a gender it cannot itself use.
    const gendered = [_]struct { gender: []const u8, want: []const u8 }{
        .{ .gender = "female", .want = "Ada udostępniła ci zdjęcie 14 lutego 2026." },
        .{ .gender = "male", .want = "Ada udostępnił ci zdjęcie 14 lutego 2026." },
        // Anything else takes the default, which is the masculine form; a
        // translator who wanted a third would write one.
        .{ .gender = "other", .want = "Ada udostępnił ci zdjęcie 14 lutego 2026." },
    };

    for (gendered) |case| {
        const args: fluent.Args = &.{
            .{ .name = "user", .value = .{ .string = "Ada" } },
            .{ .name = "gender", .value = .{ .string = case.gender } },
            .{ .name = "count", .value = .num(1) },
            .{ .name = "when", .value = .time(1_771_061_400_000) },
        };
        const text = try bundle.format(testing.allocator, "shared-with-you", args, null) orelse
            return error.MissingMessage;
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.want, text);
    }

    // And the term declines: the welcome asks for the locative, which changes
    // the stem rather than only the ending.
    const welcome = try bundle.format(testing.allocator, "welcome", &.{}, null) orelse
        return error.MissingMessage;
    defer testing.allocator.free(welcome);
    try testing.expectEqualStrings("Witamy w Skarbcu Zdjęć!", welcome);
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
