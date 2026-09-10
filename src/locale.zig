// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Language tags, and the order in which to look things up under them.
//!
//! A locale here is a BCP 47 tag reduced to the three subtags CLDR keys its
//! data by -- language, script and region. Extensions, variants and private
//! use are parsed and then discarded, because no table in this library is
//! keyed by them: `de-DE-u-co-phonebk` sorts differently from `de-DE` but
//! pluralizes and formats numbers identically.
//!
//! ## Why a fixed buffer
//!
//! A `Locale` owns its text in an array inside itself, so it can be copied,
//! stored and compared without an allocator anywhere in sight. The cost is 40
//! bytes; the alternative is making every lookup take an allocator, or making
//! locales borrow from a string the caller has to keep alive, and both are
//! worse deals for something usually created once at start-up.

const std = @import("std");

pub const Locale = struct {
    /// The canonical tag: language, then script, then region, joined by `-`.
    /// Long enough for the longest of those -- three, four and three
    /// characters -- with room to spare.
    text: [15]u8 = undefined,
    len: u8 = 0,
    language_len: u8 = 0,
    script_len: u8 = 0,
    region_len: u8 = 0,

    pub const Error = error{InvalidLanguageTag};

    /// The locale to fall back on when nothing else matches.
    ///
    /// CLDR calls it `root`; it is the data every other locale inherits from,
    /// and it behaves like English without being English -- one plural
    /// category, a dot for the decimal separator, ISO-8601-ish dates.
    pub const root: Locale = parse("und") catch unreachable;

    /// Parse a BCP 47 language tag.
    ///
    /// Case is normalized as BCP 47 specifies -- language lower, script
    /// title, region upper -- so `EN-latn-us` and `en-Latn-US` are the same
    /// locale and compare equal byte for byte.
    pub fn parse(text: []const u8) Error!Locale {
        var self: Locale = .{};

        var it = std.mem.splitAny(u8, text, "-_");
        const lang = it.next() orelse return error.InvalidLanguageTag;

        // `und` is BCP 47's "undetermined", and is how root is spelled in a
        // tag. Everything else must be a two- or three-letter language code.
        if (lang.len < 2 or lang.len > 3) return error.InvalidLanguageTag;
        for (lang) |c| if (!std.ascii.isAlphabetic(c)) return error.InvalidLanguageTag;
        self.appendLower(lang);
        self.language_len = @intCast(lang.len);

        var subtag = it.next();

        if (subtag) |s| if (s.len == 4 and isAllAlphabetic(s)) {
            self.appendSeparator();
            self.text[self.len] = std.ascii.toUpper(s[0]);
            self.len += 1;
            self.appendLower(s[1..]);
            self.script_len = 4;
            subtag = it.next();
        };

        if (subtag) |s| {
            const alpha_region = s.len == 2 and isAllAlphabetic(s);
            // A numeric region is a UN M.49 area code, like `419` for Latin
            // America, which CLDR uses for locales that span countries.
            const numeric_region = s.len == 3 and isAllDigits(s);
            if (alpha_region or numeric_region) {
                self.appendSeparator();
                for (s) |c| {
                    self.text[self.len] = std.ascii.toUpper(c);
                    self.len += 1;
                }
                self.region_len = @intCast(s.len);
            }
        }

        // Whatever follows is a variant, an extension or private use. None of
        // it keys any table here, so it is dropped rather than carried around.
        return self;
    }

    fn appendLower(self: *Locale, s: []const u8) void {
        for (s) |c| {
            self.text[self.len] = std.ascii.toLower(c);
            self.len += 1;
        }
    }

    fn appendSeparator(self: *Locale) void {
        self.text[self.len] = '-';
        self.len += 1;
    }

    fn isAllAlphabetic(s: []const u8) bool {
        for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
        return true;
    }

    fn isAllDigits(s: []const u8) bool {
        for (s) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }

    /// The canonical tag, e.g. `"sr-Latn-RS"`.
    pub fn tag(self: *const Locale) []const u8 {
        return self.text[0..self.len];
    }

    pub fn language(self: *const Locale) []const u8 {
        return self.text[0..self.language_len];
    }

    pub fn script(self: *const Locale) ?[]const u8 {
        if (self.script_len == 0) return null;
        const start = self.language_len + 1;
        return self.text[start..][0..self.script_len];
    }

    pub fn region(self: *const Locale) ?[]const u8 {
        if (self.region_len == 0) return null;
        const start = self.len - self.region_len;
        return self.text[start..self.len];
    }

    pub fn eql(self: *const Locale, other: *const Locale) bool {
        return std.mem.eql(u8, self.tag(), other.tag());
    }

    /// `{f}` prints the canonical tag.
    pub fn format(self: Locale, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.tag());
    }

    /// The tags to try, most specific first.
    ///
    /// CLDR data is inherited: a table may hold an entry for `pt-PT` and
    /// nothing for `pt-BR`, and the right answer for `pt-BR` is the one filed
    /// under `pt`. So a lookup walks this chain and takes the first hit.
    ///
    /// The chain drops one subtag at a time from the right, which is CLDR's
    /// truncation fallback. It stops short of `und`: a caller that wants to
    /// end at root does so by looking there when the chain runs out, and one
    /// that wants to try another locale in the bundle's list does that
    /// instead. Returns slices of `self`, so it borrows for as long as the
    /// locale lives.
    pub fn fallbacks(self: *const Locale, buffer: *[3][]const u8) []const []const u8 {
        var n: usize = 0;
        buffer[n] = self.tag();
        n += 1;

        if (self.region_len != 0 and self.script_len != 0) {
            // language-Script, having dropped the region.
            buffer[n] = self.text[0 .. self.language_len + 1 + self.script_len];
            n += 1;
        }
        if (self.region_len != 0 or self.script_len != 0) {
            buffer[n] = self.language();
            n += 1;
        }
        return buffer[0..n];
    }

    /// Find `self` in a sorted table of tags, trying each fallback in turn.
    ///
    /// The table is the `keys` of a generated CLDR table, which the generator
    /// writes in sorted order precisely so this can be a binary search.
    pub fn lookup(self: *const Locale, keys: []const []const u8) ?usize {
        var buffer: [3][]const u8 = undefined;
        for (self.fallbacks(&buffer)) |candidate| {
            if (binarySearch(keys, candidate)) |index| return index;
        }
        return null;
    }
};

fn binarySearch(keys: []const []const u8, needle: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = keys.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, keys[mid], needle)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return mid,
        }
    }
    return null;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "a bare language tag" {
    const l = try Locale.parse("en");
    try testing.expectEqualStrings("en", l.tag());
    try testing.expectEqualStrings("en", l.language());
    try testing.expectEqual(@as(?[]const u8, null), l.script());
    try testing.expectEqual(@as(?[]const u8, null), l.region());
}

test "case is normalized" {
    const l = try Locale.parse("EN-latn-us");
    try testing.expectEqualStrings("en-Latn-US", l.tag());
    try testing.expectEqualStrings("Latn", l.script().?);
    try testing.expectEqualStrings("US", l.region().?);
}

test "underscores separate subtags too" {
    const l = try Locale.parse("pt_BR");
    try testing.expectEqualStrings("pt-BR", l.tag());
}

test "a numeric region is kept" {
    const l = try Locale.parse("es-419");
    try testing.expectEqualStrings("es-419", l.tag());
    try testing.expectEqualStrings("419", l.region().?);
}

test "extensions and variants are dropped" {
    const l = try Locale.parse("de-DE-u-co-phonebk");
    try testing.expectEqualStrings("de-DE", l.tag());

    const with_variant = try Locale.parse("sl-IT-nedis");
    try testing.expectEqualStrings("sl-IT", with_variant.tag());
}

test "a three-letter language is a language, not a script" {
    const l = try Locale.parse("fil-PH");
    try testing.expectEqualStrings("fil-PH", l.tag());
    try testing.expectEqualStrings("fil", l.language());
    try testing.expectEqual(@as(?[]const u8, null), l.script());
}

test "malformed tags are rejected" {
    try testing.expectError(error.InvalidLanguageTag, Locale.parse(""));
    try testing.expectError(error.InvalidLanguageTag, Locale.parse("e"));
    try testing.expectError(error.InvalidLanguageTag, Locale.parse("engl"));
    try testing.expectError(error.InvalidLanguageTag, Locale.parse("12"));
}

/// Compare a fallback chain by content.
///
/// `expectEqualSlices` would compare the `[]const u8` elements themselves,
/// which for slices means comparing pointers -- and these point into the
/// locale, so it would fail on strings that are equal.
fn expectChain(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "the fallback chain drops subtags from the right" {
    var buffer: [3][]const u8 = undefined;

    const full = try Locale.parse("sr-Latn-RS");
    try expectChain(&.{ "sr-Latn-RS", "sr-Latn", "sr" }, full.fallbacks(&buffer));

    const with_region = try Locale.parse("pt-PT");
    try expectChain(&.{ "pt-PT", "pt" }, with_region.fallbacks(&buffer));

    const with_script = try Locale.parse("zh-Hant");
    try expectChain(&.{ "zh-Hant", "zh" }, with_script.fallbacks(&buffer));

    const bare = try Locale.parse("en");
    try expectChain(&.{"en"}, bare.fallbacks(&buffer));
}

test "lookup takes the most specific entry that exists" {
    const keys: []const []const u8 = &.{ "en", "pt", "pt-PT", "sr" };

    const pt_pt = try Locale.parse("pt-PT");
    try testing.expectEqual(@as(?usize, 2), pt_pt.lookup(keys));

    // No entry for pt-BR, so the one filed under `pt` is the right answer.
    const pt_br = try Locale.parse("pt-BR");
    try testing.expectEqual(@as(?usize, 1), pt_br.lookup(keys));

    const missing = try Locale.parse("zz");
    try testing.expectEqual(@as(?usize, null), missing.lookup(keys));
}

test "root is a locale like any other" {
    try testing.expectEqualStrings("und", Locale.root.tag());
}
