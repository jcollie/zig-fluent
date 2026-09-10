// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What language does this user read? -- asked of whichever system is running.
//!
//! POSIX answers with environment variables and Windows with an API, and an
//! application that runs on both should not have to care:
//!
//! ```zig
//! var buffer: [8]fluent.Locale = undefined;
//! const wanted = fluent.system.preferredLocales(&buffer, init.environ_map);
//! const category = fluent.system.categories(init.environ_map);
//! ```
//!
//! ## The environment wins on Windows too
//!
//! Not because Windows uses it -- it does not -- but because somebody running
//! under MSYS2, Cygwin or Git Bash has a shell that sets `LANG`, and somebody
//! who exported `LC_ALL` did it on purpose. Asking the environment first and
//! the operating system second is what GNU gettext does on Windows, and it
//! means `LC_ALL=C` silences translation there as well, which is the setting
//! it would be worst to ignore.
//!
//! An environment that says nothing costs one failed lookup, and then the
//! Windows answer is used.

const builtin = @import("builtin");
const std = @import("std");

const Locale = @import("locale.zig").Locale;
const darwin = @import("darwin.zig");
const posix = @import("posix.zig");
const windows = @import("windows.zig");

/// One locale per formatting category. See `fluent.Categories`.
pub const Categories = @import("locale.zig").Categories;

/// The locales the user would like, best first.
///
/// Only two things rank: GNU's `LANGUAGE` and Windows' preferred UI languages.
/// Everything else contributes one locale, so a chain longer than one means
/// the user said so explicitly.
///
/// An empty result means no preference -- nothing is set, or `LC_ALL=C` -- and
/// the caller should use whatever locale its own messages are written in.
pub fn preferredLocales(buffer: []Locale, environ: *const std.process.Environ.Map) []Locale {
    const from_environment = posix.fromEnviron(buffer, environ);
    if (from_environment.len != 0) return from_environment;

    // An empty chain means one of two different things, and on POSIX they lead
    // to the same place so the difference never shows. `LC_ALL=C` is a request
    // for no translation and is the whole answer; an environment that merely
    // says nothing has not answered at all.
    //
    // Windows is where that matters, and it took a Windows runner to notice:
    // without this the operating system's preferred UI languages were handed
    // back to somebody who had just asked, in the one way POSIX gives them, to
    // be left alone.
    if (posix.saysUnlocalizedFromEnviron(environ)) return buffer[0..0];

    // Nothing in the environment. On POSIX that settles it; on Windows and
    // macOS the question has only just been asked of the right place -- and on
    // macOS this is the ordinary case rather than the odd one, because a
    // program started from the Finder has no `LANG` at all.
    if (darwin.available) return darwin.preferredUiLanguages(buffer);
    return windows.preferredUiLanguages(buffer);
}

test preferredLocales {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var buffer: [8]Locale = undefined;

    // Set, and so honoured on either platform.
    try environ.put("LANGUAGE", "fr:de");
    try environ.put("LANG", "en_US.UTF-8");
    const wanted = preferredLocales(&buffer, &environ);
    try std.testing.expectEqual(@as(usize, 3), wanted.len);
    try std.testing.expectEqualStrings("fr", wanted[0].tag());

    // `LC_ALL=C` means no translation, and must not fall through to asking
    // Windows -- which would undo exactly what the user asked for.
    try environ.put("LC_ALL", "C");
    try std.testing.expectEqual(@as(usize, 0), preferredLocales(&buffer, &environ).len);
}

/// What each category should be formatted for.
///
/// POSIX lets a user set these four apart with `LC_NUMERIC`, `LC_TIME` and
/// `LC_MONETARY`; Windows splits them two ways, into a display language and a
/// regional format that governs the other three. Either way a null means the
/// category was not set and the caller's own default applies.
pub fn categories(environ: *const std.process.Environ.Map) Categories {
    const from_environment = posix.categoriesFromEnviron(environ);
    // Any category set at all means the environment is being used, and
    // mixing the two sources would answer one question from each.
    if (from_environment.messages != null or from_environment.numeric != null or
        from_environment.time != null or from_environment.monetary != null)
    {
        return from_environment;
    }
    // Four nulls, and again for two different reasons: `LC_ALL=C` asks for the
    // C locale in every category, which is a preference and not the lack of
    // one. Windows' regional settings must not be substituted for it.
    if (posix.saysUnlocalizedFromEnviron(environ)) return from_environment;
    if (darwin.available) return darwin.categories();
    return windows.categories();
}

test categories {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    // The POSIX split, honoured wherever the variables are set.
    try environ.put("LANG", "en_US.UTF-8");
    try environ.put("LC_TIME", "en_GB.UTF-8");
    const found = categories(&environ);
    try std.testing.expectEqualStrings("en-US", found.messages.?.tag());
    try std.testing.expectEqualStrings("en-GB", found.time.?.tag());

    // Nothing set: off Windows there is nothing else to ask, so no preference.
    var empty: std.process.Environ.Map = .init(std.testing.allocator);
    defer empty.deinit();
    if (!windows.available) {
        try std.testing.expectEqual(@as(?Locale, null), categories(&empty).messages);
    }

    // `LC_ALL=C` is a preference, though, and holds on every platform: the
    // user asked for the C locale and must not be given Windows' regional
    // settings instead.
    var unlocalized: std.process.Environ.Map = .init(std.testing.allocator);
    defer unlocalized.deinit();
    try unlocalized.put("LC_ALL", "C");
    const none = categories(&unlocalized);
    try std.testing.expectEqual(@as(?Locale, null), none.messages);
    try std.testing.expectEqual(@as(?Locale, null), none.numeric);
    try std.testing.expectEqual(@as(?Locale, null), none.time);
    try std.testing.expectEqual(@as(?Locale, null), none.monetary);
}

/// Apply the environment's formatting preferences to a bundle.
///
/// The three lines every application writes, so that it need not write them:
/// numbers, money and dates each follow the category the user set for them,
/// and a category left unset leaves the bundle as it was.
///
/// The bundle's own locale is untouched, and so are its plural rules -- those
/// belong to the language the text is written in, not to the reader's
/// preferences about punctuation.
pub fn applyCategories(bundle: anytype, found: Categories) void {
    if (found.numeric) |locale| bundle.setNumberLocale(locale);
    if (found.monetary) |locale| bundle.setCurrencyLocale(locale);
    if (found.time) |locale| bundle.setDateLocale(locale);
}

test applyCategories {
    const Bundle = @import("bundle.zig").Bundle;

    var bundle: Bundle = try .init(std.testing.allocator, try .parse("en-US"));
    defer bundle.deinit();

    applyCategories(&bundle, .{
        .messages = try .parse("en-US"),
        .numeric = try .parse("de-DE"),
        .time = try .parse("en-GB"),
    });

    try std.testing.expectEqualStrings("de-DE", bundle.number_locale.tag());
    try std.testing.expectEqualStrings("en-GB", bundle.date_locale.tag());

    // No `monetary` was given, so money follows the number locale -- CLDR
    // files the currency pattern with the rest of a locale's number data, and
    // `setNumberLocale` takes all of it. A reader who punctuates numbers in
    // German writes amounts in German too, unless they said otherwise.
    try std.testing.expectEqualStrings("de-DE", bundle.currency_locale.tag());

    // And the language is untouched, because it is not one of these
    // categories: the plural rules stay those of the text.
    try std.testing.expectEqualStrings("en-US", bundle.locale.tag());
}
