// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What macOS says the user's language and formats are.
//!
//! The counterpart of `fluent.posix` and `fluent.windows`, and the reason it
//! exists is that macOS is POSIX-but-not-quite: a program started from a
//! terminal has `LANG` and `LC_*` like any Unix, and a program started from
//! the Finder has none of them. For a GUI application the environment is
//! silent and the answer lives in the user's preferences, which is where
//! `AppleLanguages` and `AppleLocale` are.
//!
//! macOS also lets a user override the *formats* independently of the locale,
//! under Language & Region → Advanced, and those are read here too: a person
//! whose language is English and whose dates are `yyyy-MM-dd` has said
//! something that no locale identifier can express.
//!
//! ## On the declarations below
//!
//! These are written by hand, which is the thing this project avoids doing
//! for Win32: `src/windows.zig` takes its bindings from `zigwin32` precisely
//! because a hand-written `extern` is a fresh chance to get a calling
//! convention or a parameter width wrong with nothing to check it against.
//! There is no zigwin32 for CoreFoundation, so the same care has to come from
//! somewhere else, and here it is narrowness: six functions and three types,
//! every one of them documented as a `CFTypeRef`-shaped opaque pointer, no
//! structs passed by value, no callbacks, no ownership passed anywhere except
//! the `Copy` calls that this file releases itself.
//!
//! **Every `CF*Copy*` returns a +1 reference and every one of them is
//! released here**; the `Get` calls return a borrowed reference and are not.
//! That is the whole of CoreFoundation's memory rule and the only way to get
//! it wrong is to forget, so each call site says which it is.

const builtin = @import("builtin");
const std = @import("std");

const Locale = @import("locale.zig").Locale;

/// One locale per category. See `fluent.Categories`.
pub const Categories = @import("locale.zig").Categories;

/// Whether this target can be asked at all.
///
/// Every function here answers with nothing everywhere else, rather than
/// failing to compile, so that a program can name them in a branch it never
/// takes -- which is what `fluent.system` does.
pub const available = builtin.os.tag.isDarwin();

/// The longest locale identifier worth reading back, in bytes.
///
/// `AppleLocale` is a POSIX-shaped name with ICU keywords after an `@`:
/// `en_US@currency=EUR;calendar=japanese`. Only the part before the `@` is a
/// locale, but the whole string has to be read before it can be cut.
pub const max_name_len = 128;

// ---------------------------------------------------------------------------
// CoreFoundation
// ---------------------------------------------------------------------------

/// An opaque CoreFoundation object. Every type below is one of these.
const CFTypeRef = ?*anyopaque;
const CFStringRef = CFTypeRef;
const CFArrayRef = CFTypeRef;
const CFDictionaryRef = CFTypeRef;
const CFPropertyListRef = CFTypeRef;

const CFIndex = isize;
const CFTypeID = usize;
const Boolean = u8;

/// `kCFStringEncodingUTF8`.
const utf8 = 0x0800_0100;

/// `kCFNumberSInt64Type`, which is what every number read here is asked for:
/// a preference holding a small integer may be stored as any width, and
/// CoreFoundation converts.
const number_sint64 = 4;

const cf = if (available) struct {
    // The preferences themselves. `CFPreferencesCopyAppValue` searches the
    // whole domain chain -- the application's own, then the user's, then the
    // host's -- which is what `defaults read -g` shows and what a GUI
    // application sees.
    extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, applicationID: CFStringRef) CFPropertyListRef;

    // Lifetime.
    extern "c" fn CFRelease(cf: CFTypeRef) void;

    // Types, so that a preference holding the wrong kind of object is
    // ignored rather than reinterpreted. A user can put anything in here
    // with `defaults write`, and a wrong guess would be a crash.
    extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
    extern "c" fn CFStringGetTypeID() CFTypeID;
    extern "c" fn CFArrayGetTypeID() CFTypeID;
    extern "c" fn CFDictionaryGetTypeID() CFTypeID;
    extern "c" fn CFBooleanGetTypeID() CFTypeID;
    extern "c" fn CFNumberGetTypeID() CFTypeID;

    // Strings.
    extern "c" fn CFStringCreateWithBytes(
        alloc: CFTypeRef,
        bytes: [*]const u8,
        numBytes: CFIndex,
        encoding: u32,
        isExternalRepresentation: Boolean,
    ) CFStringRef;
    extern "c" fn CFStringGetCString(
        theString: CFStringRef,
        buffer: [*]u8,
        bufferSize: CFIndex,
        encoding: u32,
    ) Boolean;

    // Arrays and dictionaries. Both `Get` calls return a borrowed reference.
    extern "c" fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;
    extern "c" fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) CFTypeRef;
    extern "c" fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: CFTypeRef) CFTypeRef;

    // Scalars.
    extern "c" fn CFBooleanGetValue(boolean: CFTypeRef) Boolean;
    extern "c" fn CFNumberGetValue(number: CFTypeRef, theType: c_int, valuePtr: *anyopaque) Boolean;
} else struct {};

/// A CoreFoundation string made from `text`, to be released by the caller.
///
/// `CFSTR` is a compiler literal and cannot be reached from here, so keys are
/// built at the call site instead. Returns null if CoreFoundation declines,
/// which it does only for invalid encodings.
fn cfString(text: []const u8) CFStringRef {
    if (!available) return null;
    return cf.CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), utf8, 0);
}

/// Copy a CoreFoundation string into `buffer` as UTF-8.
///
/// Returns null when the object is not a string, or does not fit. Nothing
/// read here is long -- the longest is a date pattern -- so not fitting means
/// the preference is not what it claims to be.
fn stringInto(buffer: []u8, value: CFTypeRef) ?[]const u8 {
    if (!available) return null;
    if (value == null) return null;
    if (cf.CFGetTypeID(value) != cf.CFStringGetTypeID()) return null;
    if (cf.CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), utf8) == 0) return null;
    return std.mem.sliceTo(buffer, 0);
}

/// The value of a preference in the global domain, as a +1 reference the
/// caller must release.
fn copyGlobal(key: []const u8) CFPropertyListRef {
    if (!available) return null;

    const key_string = cfString(key);
    if (key_string == null) return null;
    defer cf.CFRelease(key_string);

    // `kCFPreferencesAnyApplication` is the global domain -- what `defaults
    // read -g` reads, and where Language & Region writes.
    const domain = cfString("kCFPreferencesAnyApplication");
    if (domain == null) return null;
    defer cf.CFRelease(domain);

    return cf.CFPreferencesCopyAppValue(key_string, domain);
}

// ---------------------------------------------------------------------------
// Locales
// ---------------------------------------------------------------------------

/// The languages the user would like the interface in, best first.
///
/// `AppleLanguages` is an array of BCP 47 tags in the order the user dragged
/// them into, which is exactly the ranked list a fallback between bundles
/// wants -- the same shape `fluent.windows.preferredUiLanguages` returns and
/// a longer `LANGUAGE` chain than POSIX usually carries.
///
/// Returns nothing off macOS, and nothing if the preference is unset or holds
/// something that is not an array of strings.
pub fn preferredUiLanguages(buffer: []Locale) []Locale {
    if (!available) return buffer[0..0];

    const value = copyGlobal("AppleLanguages");
    if (value == null) return buffer[0..0];
    defer cf.CFRelease(value);

    if (cf.CFGetTypeID(value) != cf.CFArrayGetTypeID()) return buffer[0..0];

    var count: usize = 0;
    const wanted = cf.CFArrayGetCount(value);
    var index: CFIndex = 0;
    while (index < wanted and count < buffer.len) : (index += 1) {
        // Borrowed: the array owns it.
        const element = cf.CFArrayGetValueAtIndex(value, index);
        var name: [max_name_len]u8 = undefined;
        const text = stringInto(&name, element) orelse continue;
        // A tag macOS offers that this cannot parse is skipped rather than
        // ending the list, which is what the Windows path does with the same
        // problem.
        buffer[count] = Locale.parse(text) catch continue;
        count += 1;
    }
    return buffer[0..count];
}

/// The locale the user's numbers, dates and money are written in.
///
/// `AppleLocale` is the "Region" setting, which macOS keeps apart from the
/// display language the way Windows keeps the regional format apart from the
/// interface language. It is a POSIX-shaped name -- `en_US`, `pt_BR` -- with
/// ICU keywords after an `@` that are not part of the locale and are cut.
pub fn userDefaultLocale() ?Locale {
    if (!available) return null;

    const value = copyGlobal("AppleLocale");
    if (value == null) return null;
    defer cf.CFRelease(value);

    var name: [max_name_len]u8 = undefined;
    const text = stringInto(&name, value) orelse return null;
    return fromName(text);
}

/// Parse an `AppleLocale`-shaped name.
///
/// Split out and public because it is the part worth testing, and the only
/// part that can be tested anywhere but on macOS.
pub fn fromName(name: []const u8) ?Locale {
    // `en_US@currency=EUR` -- everything from the `@` is ICU keywords, which
    // say what calendar or currency to use rather than which locale this is.
    const without_keywords = if (std.mem.findScalar(u8, name, '@')) |at| name[0..at] else name;
    if (without_keywords.len == 0) return null;
    // `en_US` is the POSIX spelling of `en-US`, and `Locale.parse` reads the
    // BCP 47 one; `posix.fromName` is the same conversion for `LANG`.
    return @import("posix.zig").fromName(without_keywords);
}

test fromName {
    const testing = std.testing;

    const plain = fromName("en_US");
    try testing.expect(plain != null);
    try testing.expectEqualStrings("en-US", plain.?.tag());

    // The keywords say what calendar or currency to use, not which locale
    // this is, so they are cut before parsing.
    const with_keywords = fromName("en_US@currency=EUR;calendar=japanese");
    try testing.expect(with_keywords != null);
    try testing.expectEqualStrings("en-US", with_keywords.?.tag());

    // A bare language, which is what a user who has never touched Region
    // gets, and the degenerate cases.
    try testing.expect(fromName("de") != null);
    try testing.expect(fromName("") == null);
    try testing.expect(fromName("@currency=EUR") == null);
}

/// What each category should be formatted for, as macOS has it set.
///
/// The display language answers `messages`; the region answers the other
/// three, because macOS keeps one setting for all of them -- the same shape
/// as Windows and unlike POSIX, which has an environment variable apiece.
pub fn categories() Categories {
    var buffer: [1]Locale = undefined;
    const preferred = preferredUiLanguages(&buffer);
    const region = userDefaultLocale();

    return .{
        .messages = if (preferred.len > 0) preferred[0] else region,
        .numeric = region,
        .time = region,
        .monetary = region,
    };
}

// ---------------------------------------------------------------------------
// Format overrides
// ---------------------------------------------------------------------------

/// The longest date pattern worth reading back. CLDR's own longest is well
/// under this; a preference longer than it is not a pattern.
pub const max_pattern_len = 96;
/// The longest number symbol worth reading back. These are one character in
/// every locale CLDR ships, and a few bytes of UTF-8 at most.
pub const max_symbol_len = 16;

/// Somewhere for the strings an `Overrides` points at to live.
///
/// The slices in `Overrides` point into this, so it has to outlive them --
/// which is why it is the caller's to declare rather than something returned.
/// No allocator: everything here has a known bound.
pub const OverrideStorage = struct {
    patterns: [4][max_pattern_len]u8 = undefined,
    symbols: [4][max_symbol_len]u8 = undefined,
};

/// What the user has overridden under Language & Region → Advanced.
///
/// Every field is null when the user has not overridden that thing, which is
/// the common case: these exist so that a person whose language is English
/// and whose dates are `yyyy-MM-dd` gets both.
///
/// Applied by the caller rather than here, because a `Bundle` is the
/// application's and this module does not own one:
///
/// ```zig
/// var storage: fluent.darwin.OverrideStorage = .{};
/// const over = fluent.darwin.overrides(&storage);
/// if (over.date_formats) |formats| bundle.date_names.date_formats = formats;
/// if (over.hour12) |twelve| options.hour12 = twelve;
/// ```
pub const Overrides = struct {
    /// The four preset date patterns, **longest first**, matching
    /// `datetime_format.Names.date_formats` and `Options.Style`.
    ///
    /// macOS stores them the other way up -- it keys them `"1"` to `"4"`
    /// running short to long -- so they are reversed on the way out and a
    /// caller can assign them straight across. All four or none: a partial
    /// override would leave two of the styles disagreeing about which end
    /// they came from.
    date_formats: ?[4][]const u8 = null,

    /// The separators, matching `number_format.Symbols`.
    decimal: ?[]const u8 = null,
    grouping: ?[]const u8 = null,
    /// The monetary pair, which CLDR does not keep separately and this
    /// library therefore cannot serve from its own tables -- so a caller
    /// reading these has better information than the tables do.
    monetary_decimal: ?[]const u8 = null,
    monetary_grouping: ?[]const u8 = null,

    /// The clock, whatever the locale prefers. True for twelve-hour.
    hour12: ?bool = null,

    /// The day the user's weeks begin on, which `Y` is counted against.
    first_weekday: ?@import("datetime_format.zig").DayOfWeek = null,
};

/// Read all of the above.
pub fn overrides(storage: *OverrideStorage) Overrides {
    if (!available) return .{};

    return .{
        .date_formats = dateFormats(storage),
        .decimal = numberSymbol(&storage.symbols[0], "0"),
        .grouping = numberSymbol(&storage.symbols[1], "1"),
        .monetary_decimal = numberSymbol(&storage.symbols[2], "10"),
        .monetary_grouping = numberSymbol(&storage.symbols[3], "17"),
        .hour12 = hour12(),
        .first_weekday = firstWeekday(),
    };
}

/// `AppleICUDateFormatStrings`, reversed into this library's order.
///
/// A dictionary keyed `"1"` through `"4"` running short to long, where this
/// library indexes by `Style` running long to short: macOS's `"1"` is
/// `date_formats[3]`. Null unless all four are present and readable, since a
/// half-filled set would silently mix the two orders.
fn dateFormats(storage: *OverrideStorage) ?[4][]const u8 {
    if (!available) return null;

    const value = copyGlobal("AppleICUDateFormatStrings");
    if (value == null) return null;
    defer cf.CFRelease(value);
    if (cf.CFGetTypeID(value) != cf.CFDictionaryGetTypeID()) return null;

    var out: [4][]const u8 = undefined;
    for (0..4) |i| {
        // "1" through "4"; `"1"` is the shortest and lands at index 3.
        const key_text = [_]u8{'1' + @as(u8, @intCast(i))};
        const key = cfString(&key_text);
        if (key == null) return null;
        defer cf.CFRelease(key);

        // Borrowed: the dictionary owns it.
        const pattern = cf.CFDictionaryGetValue(value, key);
        out[3 - i] = stringInto(&storage.patterns[3 - i], pattern) orelse return null;
    }
    return out;
}

/// One entry of `AppleICUNumberSymbols`, by its `UNumberFormatSymbol` number.
///
/// The keys are the numbers ICU gives its symbols, written as strings: `0` is
/// the decimal separator, `1` the grouping one, `10` and `17` the monetary
/// pair.
fn numberSymbol(storage: *[max_symbol_len]u8, key_text: []const u8) ?[]const u8 {
    if (!available) return null;

    const value = copyGlobal("AppleICUNumberSymbols");
    if (value == null) return null;
    defer cf.CFRelease(value);
    if (cf.CFGetTypeID(value) != cf.CFDictionaryGetTypeID()) return null;

    const key = cfString(key_text);
    if (key == null) return null;
    defer cf.CFRelease(key);

    return stringInto(storage, cf.CFDictionaryGetValue(value, key));
}

/// `AppleICUForce24HourTime` and `AppleICUForce12HourTime`.
///
/// Two keys rather than one, because they are two switches in the interface
/// and either may be absent. Both set is a contradiction the user cannot
/// actually produce; twelve wins, arbitrarily and documented.
fn hour12() ?bool {
    if (!available) return null;

    if (readBoolean("AppleICUForce12HourTime")) |forced| {
        if (forced) return true;
    }
    if (readBoolean("AppleICUForce24HourTime")) |forced| {
        if (forced) return false;
    }
    return null;
}

fn readBoolean(key: []const u8) ?bool {
    const value = copyGlobal(key);
    if (value == null) return null;
    defer cf.CFRelease(value);
    if (cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID()) return null;
    return cf.CFBooleanGetValue(value) != 0;
}

/// `AppleFirstWeekday`, which is a dictionary keyed by calendar.
///
/// Only the Gregorian entry is read, since that is the only calendar this
/// library implements. The value is CLDR's numbering, 1 for Sunday through 7
/// for Saturday, which is one more than `DayOfWeek`'s.
fn firstWeekday() ?@import("datetime_format.zig").DayOfWeek {
    if (!available) return null;

    const value = copyGlobal("AppleFirstWeekday");
    if (value == null) return null;
    defer cf.CFRelease(value);
    if (cf.CFGetTypeID(value) != cf.CFDictionaryGetTypeID()) return null;

    const key = cfString("gregorian");
    if (key == null) return null;
    defer cf.CFRelease(key);

    const entry = cf.CFDictionaryGetValue(value, key);
    if (entry == null) return null;
    if (cf.CFGetTypeID(entry) != cf.CFNumberGetTypeID()) return null;

    var day: i64 = 0;
    if (cf.CFNumberGetValue(entry, number_sint64, &day) == 0) return null;
    if (day < 1 or day > 7) return null;
    return @enumFromInt(@as(u3, @intCast(day - 1)));
}
