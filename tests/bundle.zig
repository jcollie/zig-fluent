// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The library from the outside: real `.ftl` text through a real bundle.
//!
//! These go through the public API only -- `addResource`, `format` -- so they
//! say what a consumer can rely on rather than how it is arranged inside.

const std = @import("std");
const testing = std.testing;

const fluent = @import("fluent");

const Bundle = fluent.Bundle;

/// A bundle for `tag`, with isolation off.
///
/// Isolation is on by default and should be, but it wraps every interpolation
/// in invisible characters, and a test asserting on exact text is one of the
/// two cases the switch exists for. It gets its own tests below.
fn bundleFor(tag: []const u8, source: []const u8) !Bundle {
    var bundle: Bundle = try .init(testing.allocator, try .parse(tag));
    errdefer bundle.deinit();
    bundle.use_isolating = false;
    try bundle.addResource(source, .{}, null);
    return bundle;
}

fn expectMessage(bundle: *const Bundle, name: []const u8, args: fluent.Args, expected: []const u8) !void {
    const text = try bundle.format(testing.allocator, name, args, null) orelse {
        std.debug.print("no such message: {s}\n", .{name});
        return error.MessageNotFound;
    };
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "a message with no placeables" {
    var bundle = try bundleFor("en", "hello = Hello, world!\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "hello", &.{}, "Hello, world!");
}

test "a variable is interpolated" {
    var bundle = try bundleFor("en", "greet = Hello, { $name }!\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "greet", &.{
        .{ .name = "name", .value = .{ .string = "Ada" } },
    }, "Hello, Ada!");
}

test "a missing variable renders as its own name" {
    var bundle = try bundleFor("en", "greet = Hello, { $name }!\n");
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "greet", &.{}, &errors)).?;
    defer testing.allocator.free(text);

    // The sentence survives, and the gap is visible.
    try testing.expectEqualStrings("Hello, {$name}!", text);
    try testing.expectEqual(@as(usize, 1), errors.items.len);
    try testing.expectEqual(fluent.Error.Kind.unknown_variable, errors.items[0].kind);
    try testing.expectEqualStrings("name", errors.items[0].name);
}

test "a message that is not in the bundle is not an error" {
    var bundle = try bundleFor("en", "hello = Hi\n");
    defer bundle.deinit();
    // Null rather than a failure, so an application can try the next bundle.
    try testing.expectEqual(
        @as(?[]u8, null),
        try bundle.format(testing.allocator, "absent", &.{}, null),
    );
    try testing.expect(bundle.hasMessage("hello"));
    try testing.expect(!bundle.hasMessage("absent"));
}

test "English plurals" {
    var bundle = try bundleFor("en",
        \\unread =
        \\    { $count ->
        \\        [one] One unread message
        \\       *[other] { $count } unread messages
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "unread", &.{
        .{ .name = "count", .value = .num(1) },
    }, "One unread message");
    try expectMessage(&bundle, "unread", &.{
        .{ .name = "count", .value = .num(0) },
    }, "0 unread messages");
    try expectMessage(&bundle, "unread", &.{
        .{ .name = "count", .value = .num(5) },
    }, "5 unread messages");
}

test "Russian plurals, where one and few and many all differ" {
    var bundle = try bundleFor("ru",
        \\files =
        \\    { $n ->
        \\        [one] { $n } файл
        \\        [few] { $n } файла
        \\       *[many] { $n } файлов
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "files", &.{.{ .name = "n", .value = .num(1) }}, "1 файл");
    try expectMessage(&bundle, "files", &.{.{ .name = "n", .value = .num(2) }}, "2 файла");
    try expectMessage(&bundle, "files", &.{.{ .name = "n", .value = .num(5) }}, "5 файлов");
    // 11 is `many` in Russian even though 21 is `one`.
    try expectMessage(&bundle, "files", &.{.{ .name = "n", .value = .num(11) }}, "11 файлов");
    try expectMessage(&bundle, "files", &.{.{ .name = "n", .value = .num(21) }}, "21 файл");
}

test "an exact number matches before its plural category does" {
    var bundle = try bundleFor("en",
        \\count =
        \\    { $n ->
        \\        [0] none at all
        \\        [one] just one
        \\       *[other] { $n } of them
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "count", &.{.{ .name = "n", .value = .num(0) }}, "none at all");
    try expectMessage(&bundle, "count", &.{.{ .name = "n", .value = .num(1) }}, "just one");
    try expectMessage(&bundle, "count", &.{.{ .name = "n", .value = .num(7) }}, "7 of them");
}

test "selecting on a string, which is how gender is handled" {
    var bundle = try bundleFor("en",
        \\shared =
        \\    { $gender ->
        \\        [male] He shared a photo
        \\        [female] She shared a photo
        \\       *[other] They shared a photo
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "shared", &.{
        .{ .name = "gender", .value = .{ .string = "female" } },
    }, "She shared a photo");
    try expectMessage(&bundle, "shared", &.{
        .{ .name = "gender", .value = .{ .string = "unstated" } },
    }, "They shared a photo");
    // No argument at all still produces a sentence.
    try expectMessage(&bundle, "shared", &.{}, "They shared a photo");
}

test "one message may refer to another" {
    var bundle = try bundleFor("en",
        \\-brand = Firefox
        \\about = About { -brand }
        \\welcome = Welcome to { about }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "about", &.{}, "About Firefox");
    try expectMessage(&bundle, "welcome", &.{}, "Welcome to About Firefox");
}

test "a term carries grammatical features on its attributes" {
    // The point of terms: the translator factors out a noun and then agrees
    // with it, which the application cannot do on their behalf.
    var bundle = try bundleFor("en",
        \\-tab = tab
        \\    .gender = neuter
        \\
        \\close =
        \\    Close { -tab } and { -tab.gender ->
        \\        [neuter] discard it
        \\       *[other] discard them
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "close", &.{}, "Close tab and discard it");
}

test "a term may be called with arguments" {
    var bundle = try bundleFor("en",
        \\-thing =
        \\    { $case ->
        \\        [genitive] thing's
        \\       *[nominative] thing
        \\    }
        \\
        \\plain = The { -thing }
        \\owned = The { -thing(case: "genitive") } colour
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "plain", &.{}, "The thing");
    try expectMessage(&bundle, "owned", &.{}, "The thing's colour");
}

test "a term cannot see the caller's arguments unless it is passed them" {
    var bundle = try bundleFor("en",
        \\-who = { $name }
        \\direct = Hello { $name }
        \\through-term = Hello { -who }
        \\passed = Hello { -who(name: "Ada") }
        \\
    );
    defer bundle.deinit();

    const args: fluent.Args = &.{.{ .name = "name", .value = .{ .string = "Grace" } }};
    try expectMessage(&bundle, "direct", args, "Hello Grace");
    // A term's parameters are its whole world; it does not inherit `$name`.
    try expectMessage(&bundle, "through-term", args, "Hello {$name}");
    try expectMessage(&bundle, "passed", args, "Hello Ada");
}

test "a missing variable inside a term is not reported" {
    // The same term is often used both with arguments and without, so a
    // parameter it was not given is expected rather than wrong.
    var bundle = try bundleFor("en", "-who = { $name }\nm = { -who }\n");
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "m", &.{}, &errors)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{$name}", text);
    try testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "attributes are formatted by name" {
    var bundle = try bundleFor("en",
        \\login-input = Predefined value
        \\    .placeholder = email@example.com
        \\    .aria-label = Login input value
        \\
    );
    defer bundle.deinit();

    const text = (try bundle.formatAttribute(
        testing.allocator,
        "login-input",
        "placeholder",
        &.{},
        null,
    )).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("email@example.com", text);
}

test "numbers are formatted for the locale" {
    var english = try bundleFor("en", "m = { $n }\n");
    defer english.deinit();
    try expectMessage(&english, "m", &.{.{ .name = "n", .value = .num(1234.5) }}, "1,234.5");
}

test "NUMBER passes the translator's options through" {
    var bundle = try bundleFor("en",
        \\pi = { NUMBER($v, maximumFractionDigits: 2) }
        \\padded = { NUMBER($v, minimumFractionDigits: 4) }
        \\plain = { NUMBER($v, useGrouping: "false") }
        \\
    );
    defer bundle.deinit();

    const args: fluent.Args = &.{.{ .name = "v", .value = .num(1234.56789) }};
    try expectMessage(&bundle, "pi", args, "1,234.57");
    try expectMessage(&bundle, "padded", args, "1,234.5679");
    try expectMessage(&bundle, "plain", args, "1234.568");
}

test "a number literal keeps the precision it was written with" {
    var bundle = try bundleFor("en", "m = { 1.0 } and { 1 }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{}, "1.0 and 1");
}

test "the digits shown decide the plural category" {
    // English's `one` is one integer digit and no fraction digits, so a value
    // shown to one place is `other` however close to 1 it is.
    var bundle = try bundleFor("en",
        \\m =
        \\    { NUMBER($n, minimumFractionDigits: 1) ->
        \\        [one] one thing
        \\       *[other] things
        \\    }
        \\
    );
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1) }}, "things");
}

test "a string literal may be used to control whitespace" {
    var bundle = try bundleFor("en", "m = {\"    \"}indented\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{}, "    indented");
}

test "escapes in a string literal are resolved" {
    var bundle = try bundleFor("en", "m = { \"a\\\"b\\\\c\\u0041\" }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{}, "a\"b\\cA");
}

test "a cyclic reference is caught and reported" {
    var bundle = try bundleFor("en", "a = { b }\nb = { a }\n");
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "a", &.{}, &errors)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{???}", text);

    var found = false;
    for (errors.items) |e| {
        if (e.kind == .cyclic_reference) found = true;
    }
    try testing.expect(found);
}

test "a message that refers to itself is caught" {
    var bundle = try bundleFor("en", "a = { a } and more\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "a", &.{}, "{???} and more");
}

test "the placeable budget stops an exponential expansion" {
    // Each message refers to the one below it four times, so eight levels
    // would be sixty-five thousand expansions from twenty short lines.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..8) |i| {
        try source.print(testing.allocator, "m{d} = {{ m{d} }}{{ m{d} }}{{ m{d} }}{{ m{d} }}\n", .{
            i, i + 1, i + 1, i + 1, i + 1,
        });
    }
    try source.appendSlice(testing.allocator, "m8 = leaf\n");

    var bundle = try bundleFor("en", source.items);
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "m0", &.{}, &errors)).?;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("{???}", text);
    try testing.expectEqual(fluent.Error.Kind.too_many_placeables, errors.items[errors.items.len - 1].kind);
}

test "interpolations are isolated by default" {
    var bundle: Bundle = try .init(testing.allocator, try .parse("en"));
    defer bundle.deinit();
    try bundle.addResource("m = Hello, { $name }!\n", .{}, null);

    const text = (try bundle.format(testing.allocator, "m", &.{
        .{ .name = "name", .value = .{ .string = "Ada" } },
    }, null)).?;
    defer testing.allocator.free(text);

    // U+2068 FIRST STRONG ISOLATE, U+2069 POP DIRECTIONAL ISOLATE.
    try testing.expectEqualStrings("Hello, \u{2068}Ada\u{2069}!", text);
}

test "a pattern that is only a placeable is not isolated" {
    // There is no surrounding text for it to be confused with, and the marks
    // would end up in a value the application may be about to compare.
    var bundle: Bundle = try .init(testing.allocator, try .parse("en"));
    defer bundle.deinit();
    try bundle.addResource("m = { $name }\n", .{}, null);

    const text = (try bundle.format(testing.allocator, "m", &.{
        .{ .name = "name", .value = .{ .string = "Ada" } },
    }, null)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Ada", text);
}

test "an unknown function renders as a call and is reported" {
    var bundle = try bundleFor("en", "m = { MISSING($x) }\n");
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "m", &.{}, &errors)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{MISSING()}", text);
    try testing.expectEqual(fluent.Error.Kind.unknown_function, errors.items[errors.items.len - 1].kind);
}

fn shout(call: fluent.Call) fluent.Value {
    const text = switch (call.first()) {
        .string => |s| s,
        else => return .{ .none = "SHOUT()" },
    };
    const upper = call.arena.alloc(u8, text.len) catch return .{ .none = "SHOUT()" };
    for (text, upper) |c, *out| out.* = std.ascii.toUpper(c);
    return .{ .string = upper };
}

test "an application may add functions of its own" {
    var bundle = try bundleFor("en", "m = { SHOUT($name) }!\n");
    defer bundle.deinit();
    try bundle.addFunction("SHOUT", shout);

    try expectMessage(&bundle, "m", &.{
        .{ .name = "name", .value = .{ .string = "ada" } },
    }, "ADA!");
}

test "a broken entry does not take the rest of the file with it" {
    var bundle: Bundle = try .init(testing.allocator, try .parse("en"));
    defer bundle.deinit();
    bundle.use_isolating = false;

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    try bundle.addResource(
        \\before = fine
        \\broken = { $x
        \\after = also fine
        \\
    , .{}, &errors);

    try expectMessage(&bundle, "before", &.{}, "fine");
    try expectMessage(&bundle, "after", &.{}, "also fine");
    try testing.expectEqual(@as(usize, 1), errors.items.len);
    try testing.expectEqual(fluent.Error.Kind.parse_error, errors.items[0].kind);
}

test "a duplicate definition is refused unless overrides are allowed" {
    var bundle: Bundle = try .init(testing.allocator, try .parse("en"));
    defer bundle.deinit();
    bundle.use_isolating = false;

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    try bundle.addResource("m = first\n", .{}, &errors);
    try bundle.addResource("m = second\n", .{}, &errors);
    try expectMessage(&bundle, "m", &.{}, "first");
    try testing.expectEqual(fluent.Error.Kind.duplicate_message, errors.items[0].kind);

    try bundle.addResource("m = third\n", .{ .allow_overrides = true }, null);
    try expectMessage(&bundle, "m", &.{}, "third");
}

test "resources may be freed by the caller once added" {
    const source = try testing.allocator.dupe(u8, "m = borrowed\n");
    var bundle = try bundleFor("en", source);
    defer bundle.deinit();
    testing.allocator.free(source);
    try expectMessage(&bundle, "m", &.{}, "borrowed");
}

test "a multi-line pattern keeps its shape" {
    var bundle = try bundleFor("en",
        \\poem =
        \\    The first line
        \\    The second line
        \\
    );
    defer bundle.deinit();
    try expectMessage(&bundle, "poem", &.{}, "The first line\nThe second line");
}

test "a nested select expression" {
    var bundle = try bundleFor("en",
        \\shared =
        \\    { $count ->
        \\        [one]
        \\            { $gender ->
        \\                [female] She shared a photo
        \\               *[other] They shared a photo
        \\            }
        \\       *[other]
        \\            { $gender ->
        \\                [female] She shared { $count } photos
        \\               *[other] They shared { $count } photos
        \\            }
        \\    }
        \\
    );
    defer bundle.deinit();

    try expectMessage(&bundle, "shared", &.{
        .{ .name = "count", .value = .num(1) },
        .{ .name = "gender", .value = .{ .string = "female" } },
    }, "She shared a photo");
    try expectMessage(&bundle, "shared", &.{
        .{ .name = "count", .value = .num(3) },
        .{ .name = "gender", .value = .{ .string = "male" } },
    }, "They shared 3 photos");
}

// -- locale-sensitive number formatting ---------------------------------------
//
// Each expectation here was checked against `Intl.NumberFormat` in V8, which
// is ICU, which is CLDR. They are the point of carrying the tables at all.

test "German swaps the decimal separator and the group separator" {
    var bundle = try bundleFor("de", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1234.5) }}, "1.234,5");
}

test "Indian grouping is three digits and then two" {
    var bundle = try bundleFor("hi", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1234567) }}, "12,34,567");
}

test "Polish does not group four-digit numbers" {
    var bundle = try bundleFor("pl", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1000) }}, "1000");
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(10000) }}, "10\u{00A0}000");
}

test "Egyptian Arabic writes its own digits" {
    var bundle = try bundleFor("ar-EG", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1234.5) }}, "١٬٢٣٤٫٥");
}

test "a locale CLDR does not know falls back to its language" {
    // No data for de-XX, so it gets de's.
    var bundle = try bundleFor("de-XX", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1234.5) }}, "1.234,5");
}

test "a locale CLDR does not know at all keeps the root defaults" {
    var bundle = try bundleFor("zxx", "m = { $n }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "m", &.{.{ .name = "n", .value = .num(1234.5) }}, "1,234.5");
}

// -- locale-sensitive date formatting -----------------------------------------
//
// Checked against `Intl.DateTimeFormat` in V8 (ICU 78, CLDR 48) over a matrix
// of thirty locales and twelve option sets. Of 1160 date cases, 1134 agreed
// exactly and the rest are the two divergences documented in the README: the
// narrow no-break space, where CLDR's data says U+202F and V8 substitutes an
// ordinary space, and the Buddhist calendar, which Thai uses by default and
// which this library does not implement.

/// 2026-09-09T14:03:07.250Z, a Wednesday.
const moment: i64 = 1788962587250;

fn expectDate(tag: []const u8, options: []const u8, expected: []const u8) !void {
    const source = try std.fmt.allocPrint(testing.allocator, "d = {{ DATETIME($t{s}) }}\n", .{options});
    defer testing.allocator.free(source);

    var bundle = try bundleFor(tag, source);
    defer bundle.deinit();

    try expectMessage(&bundle, "d", &.{.{ .name = "t", .value = .time(moment) }}, expected);
}

test "a bare DATETIME shows the date, numerically" {
    try expectDate("en", "", "9/9/2026");
    try expectDate("de", "", "9.9.2026");
}

test "the preset date styles" {
    try expectDate("en", ", dateStyle: \"full\"", "Wednesday, September 9, 2026");
    try expectDate("en", ", dateStyle: \"long\"", "September 9, 2026");
    try expectDate("en", ", dateStyle: \"medium\"", "Sep 9, 2026");
    try expectDate("en", ", dateStyle: \"short\"", "9/9/26");
    try expectDate("de", ", dateStyle: \"full\"", "Mittwoch, 9. September 2026");
    try expectDate("ja", ", dateStyle: \"long\"", "2026年9月9日");
}

test "a date and a time together read as a sentence" {
    // CLDR's "at time" connector, which is why English says "at" and German
    // says "um" rather than both using a comma.
    try expectDate(
        "en",
        ", dateStyle: \"long\", timeStyle: \"short\"",
        "September 9, 2026 at 2:03\u{202F}PM",
    );
    try expectDate("de", ", dateStyle: \"long\", timeStyle: \"short\"", "9. September 2026 um 14:03");
    try expectDate("fr", ", dateStyle: \"long\", timeStyle: \"short\"", "9 septembre 2026 à 14:03");
}

test "individual fields are arranged the way the locale arranges them" {
    // The whole reason for carrying CLDR's skeletons: the same request comes
    // out in a different order, with different punctuation, per language.
    try expectDate("en", ", month: \"long\", day: \"numeric\"", "September 9");
    try expectDate("de", ", month: \"long\", day: \"numeric\"", "9. September");
    try expectDate("ja", ", month: \"long\", day: \"numeric\"", "9月9日");
}

test "a width the locale never listed is filled in" {
    // French lists `yMMMd` and no `yMMMdd`, so a two-digit day matches the
    // former and has its day widened afterwards.
    try expectDate("fr", ", year: \"numeric\", month: \"short\", day: \"2-digit\"", "09 sept. 2026");
    try expectDate("de", ", year: \"numeric\", month: \"short\", day: \"2-digit\"", "09. Sept. 2026");
}

test "a width the locale did list is left alone" {
    // Japanese files `y年M月d日` under `yMMMd`: the key says the month is
    // abbreviated and the pattern writes it as a numeral, because in Japanese
    // that is what an abbreviated month is. Rewriting it would give "9月月".
    try expectDate("ja", ", year: \"numeric\", month: \"short\", day: \"2-digit\"", "2026年9月09日");
    // British English files `dd/MM/y` under `yMd`, and asking for a numeric
    // day does not narrow it, because the locale already answered.
    try expectDate("en-GB", "", "09/09/2026");
}

test "a weekday takes the form the pattern asks for" {
    // Finnish's format weekday is the essive "keskiviikkona" -- on Wednesday.
    // Its full date pattern asks for the stand-alone one, "keskiviikko".
    try expectDate("fi", ", dateStyle: \"full\"", "keskiviikko 9. syyskuuta 2026");
    try expectDate("en", ", weekday: \"long\", month: \"long\", day: \"numeric\"", "Wednesday, September 9");
    try expectDate("en", ", weekday: \"short\", month: \"long\", day: \"numeric\"", "Wed, September 9");
}

test "the clock is the one the locale keeps" {
    try expectDate("en", ", timeStyle: \"short\"", "2:03\u{202F}PM");
    try expectDate("de", ", timeStyle: \"short\"", "14:03");
    try expectDate("zh-Hant", ", timeStyle: \"short\"", "下午2:03");
}

test "a date is written in the locale's own digits" {
    try expectDate("ar-EG", ", dateStyle: \"long\"", "٩ سبتمبر ٢٠٢٦");
}

test "a moment before the epoch formats like any other" {
    var bundle = try bundleFor("en", "d = { DATETIME($t, dateStyle: \"long\") }\n");
    defer bundle.deinit();
    // 1969-07-20T20:17:40Z.
    try expectMessage(&bundle, "d", &.{.{ .name = "t", .value = .time(-14182940000) }}, "July 20, 1969");
}

test "a number passed to DATETIME is seconds since the epoch" {
    var bundle = try bundleFor("en", "d = { DATETIME($t, dateStyle: \"short\") }\n");
    defer bundle.deinit();
    try expectMessage(&bundle, "d", &.{.{ .name = "t", .value = .num(0) }}, "1/1/70");
}

test "DATETIME refuses text and says so" {
    var bundle = try bundleFor("en", "d = { DATETIME($t) }\n");
    defer bundle.deinit();

    var errors: fluent.Errors = .empty;
    defer errors.deinit(testing.allocator);

    const text = (try bundle.format(testing.allocator, "d", &.{
        .{ .name = "t", .value = .{ .string = "not a date" } },
    }, &errors)).?;
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("{DATETIME()}", text);
    try testing.expectEqual(fluent.Error.Kind.invalid_argument, errors.items[0].kind);
}

test "a number may be ranked rather than counted" {
    // English ordinals have four categories where its cardinals have two, and
    // a translator writes the same variant keys for both. Which one applies is
    // the application's to say, because only it knows whether the number is a
    // quantity or a position.
    var bundle = try bundleFor("en",
        \\place =
        \\    { $n ->
        \\        [one] { $n }st
        \\        [two] { $n }nd
        \\        [few] { $n }rd
        \\       *[other] { $n }th
        \\    }
        \\
    );
    defer bundle.deinit();

    for ([_]struct { f64, []const u8 }{
        .{ 1, "1st" },   .{ 2, "2nd" },   .{ 3, "3rd" },
        .{ 4, "4th" },   .{ 11, "11th" }, .{ 21, "21st" },
        .{ 22, "22nd" }, .{ 13, "13th" },
    }) |case| {
        const n, const expected = case;
        try expectMessage(&bundle, "place", &.{
            .{ .name = "n", .value = .{ .number = .{ .value = n, .plural_kind = .ordinal } } },
        }, expected);
    }

    // The same message with a cardinal number counts instead, and English
    // cardinals only ever say `one` or `other`.
    try expectMessage(&bundle, "place", &.{.{ .name = "n", .value = .num(3) }}, "3th");
}
