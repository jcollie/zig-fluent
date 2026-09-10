// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! CLDR plural rules: which of `zero`, `one`, `two`, `few`, `many` or `other`
//! a number takes in a given language.
//!
//! This is the part of Fluent that cannot be done without data. A select
//! expression written by a translator names categories:
//!
//! ```ftl
//! unread =
//!     { $count ->
//!         [one] One unread message
//!        *[other] { $count } unread messages
//!     }
//! ```
//!
//! and `[one]` has to mean what it means in *their* language. In English it is
//! exactly 1; in Russian it is 1, 21, 31 but not 11; in Welsh it is 1 and
//! nothing else, while `[few]` is 3. Getting this wrong does not produce a
//! slightly awkward sentence, it produces a wrong one, and the translator has
//! no way to work around it from inside the file.
//!
//! ## What the rules operate on
//!
//! Not the number -- the number *as it will be displayed*. CLDR defines six
//! operands, and half of them are about the digits rather than the value:
//!
//! | | |
//! |-|-|
//! | `n` | the absolute value |
//! | `i` | the integer part |
//! | `v` | how many fraction digits are shown, counting trailing zeros |
//! | `w` | how many are shown, not counting trailing zeros |
//! | `f` | those fraction digits as an integer, with trailing zeros |
//! | `t` | those fraction digits as an integer, without |
//!
//! So English's `one` is `i = 1 and v = 0`, and `1.0` is therefore *other*:
//! "1.0 files", not "1.0 file". This is why `Operands` is derived from
//! formatted text rather than from an `f64` -- by the time the rules run, how
//! many digits will be shown is already decided, and it is part of the answer.
//!
//! A seventh operand, `e` (also spelled `c`), is the exponent of a compact
//! decimal like "1.2M", written `1.2c6`. Several Romance languages use it: in
//! French, `many` is reserved for round millions and for anything written
//! compactly. Nothing in this library produces compact notation yet, so in
//! practice it is zero -- but `Operands.fromDecimal` reads the notation, both
//! because CLDR's own sample data is written in it and because a caller with
//! its own compact formatter should be able to plural it correctly.
//!
//! ## Where the rules come from
//!
//! `src/cldr/plurals.zig`, generated from CLDR's `plurals.json` and
//! `ordinals.json` by `zig build gen-cldr`. The generator compiles each rule
//! from CLDR's little rule language into the structures below, so nothing
//! parses anything at run time.

const std = @import("std");

const Locale = @import("locale.zig").Locale;
const data = @import("cldr/plurals.zig");

/// The plural categories. Every language uses `other`; the rest are used by
/// the languages that need them, and a variant key naming a category a
/// language does not use simply never matches.
pub const Category = enum {
    zero,
    one,
    two,
    few,
    many,
    other,

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }

    /// The category a variant key names, or null if the key is not a category
    /// at all -- `[masculine]`, say, which selects on something else.
    pub fn fromName(text: []const u8) ?Category {
        return std.meta.stringToEnum(Category, text);
    }
};

/// Cardinal counts things ("3 files"); ordinal ranks them ("the 3rd file").
/// They are different rule sets: English cardinal has `one` and `other`, while
/// English ordinal has `one` (1st), `two` (2nd), `few` (3rd) and `other` (4th).
pub const Kind = enum { cardinal, ordinal };

/// Which of CLDR's operands a relation is about.
pub const Operand = enum { n, i, v, w, f, t, e };

/// An inclusive range of integers. A single value is a range whose ends are
/// equal, which is how CLDR's own grammar treats it.
pub const Range = struct { low: u64, high: u64 };

/// One comparison, such as `n % 10 = 2..4`.
pub const Relation = struct {
    operand: Operand,
    /// Zero when the relation has no `%`, since no rule takes a modulus of 0.
    modulus: u32 = 0,
    negated: bool = false,
    ranges: []const Range,
};

/// A rule's condition: a disjunction of conjunctions, which is the only shape
/// CLDR's grammar can produce -- `and` binds tighter than `or` and there are
/// no parentheses.
pub const Condition = []const []const Relation;

pub const Rule = struct {
    category: Category,
    condition: Condition,
};

/// The rules for one locale, in the order they must be tried.
pub const RuleSet = []const Rule;

/// A table of rule sets, keyed by language tag. `keys` is sorted so that the
/// lookup can be a binary search.
pub const Table = struct {
    keys: []const []const u8,
    rules: []const RuleSet,
};

/// The number a plural rule is asked about, decomposed into CLDR's operands.
pub const Operands = struct {
    /// The absolute value.
    n: f64 = 0,
    /// The integer part.
    i: u64 = 0,
    /// Visible fraction digits, with trailing zeros.
    v: u32 = 0,
    /// Visible fraction digits, without trailing zeros.
    w: u32 = 0,
    /// Those digits as an integer, with trailing zeros.
    f: u64 = 0,
    /// Those digits as an integer, without trailing zeros.
    t: u64 = 0,
    /// Compact decimal exponent; always zero here.
    e: u32 = 0,

    /// Derive the operands from a plain decimal string such as `"-1.230"`.
    ///
    /// This is the definition rather than a convenience: the operands are
    /// about the digits that will be shown, so the formatted text is the
    /// honest input. Grouping separators and a leading `+` are tolerated; a
    /// localized decimal separator is not, because this is meant to be handed
    /// the digits before they are localized.
    ///
    /// A `c` or `e` suffix is CLDR's compact notation: `1.2c6` is 1.2 million,
    /// the way it would be written if it were about to be displayed as "1.2M".
    /// The exponent shifts the decimal point before the other operands are
    /// taken, so `1c6` has six figures and no fraction digits at all.
    pub fn fromDecimal(text: []const u8) Operands {
        var self: Operands = .{};

        var rest = text;
        if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) rest = rest[1..];

        if (std.mem.indexOfAny(u8, rest, "ce")) |at| {
            self.e = std.fmt.parseInt(u32, rest[at + 1 ..], 10) catch 0;
            rest = rest[0..at];
        }

        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const integer_text = rest[0..dot];
        var fraction_text = if (dot < rest.len) rest[dot + 1 ..] else "";

        // Applying the exponent moves digits from the fraction to the integer.
        // Once they have moved they are integer digits like any other, which
        // is why `1c6` has v = 0 rather than the fraction it was written with.
        //
        // Saturating, and tolerant of a byte that is not a digit. This is a
        // public entry point taking an arbitrary slice, and both of the
        // obvious spellings panic on input nobody would write: `carried * 10`
        // overflows on a long enough run of digits, and `byte - '0'` wraps
        // below zero for any byte under `'0'`. A fuzz target found both.
        var shift = self.e;
        var carried: u64 = 0;
        while (shift > 0 and fraction_text.len > 0) : (shift -= 1) {
            const byte = fraction_text[0];
            fraction_text = fraction_text[1..];
            if (!std.ascii.isDigit(byte)) continue;
            carried = std.math.mul(u64, carried, 10) catch std.math.maxInt(u64);
            carried = std.math.add(u64, carried, byte - '0') catch std.math.maxInt(u64);
        }

        for (integer_text) |c| {
            if (!std.ascii.isDigit(c)) continue; // a grouping separator
            self.i = std.math.mul(u64, self.i, 10) catch std.math.maxInt(u64);
            self.i = std.math.add(u64, self.i, c - '0') catch std.math.maxInt(u64);
        }

        // The digits that moved across, then the zeros for whatever exponent
        // was left over after the fraction ran out.
        const moved = self.e - shift;
        self.i = saturatingScale(self.i, moved);
        self.i = std.math.add(u64, self.i, carried) catch std.math.maxInt(u64);
        self.i = saturatingScale(self.i, shift);

        // Saturating, because this is public and takes any slice: a string
        // with four billion digits after the point is nobody's number, but it
        // must not be a panic either.
        self.v = std.math.cast(u32, fraction_text.len) orelse std.math.maxInt(u32);
        self.f = parseDigits(fraction_text);

        const trimmed = std.mem.trimEnd(u8, fraction_text, "0");
        self.w = std.math.cast(u32, trimmed.len) orelse std.math.maxInt(u32);
        self.t = parseDigits(trimmed);

        // Reconstructed from the parts rather than parsed from the text, so
        // that `n` agrees with `i` and `f` exactly even when the integer part
        // saturated.
        self.n = @as(f64, @floatFromInt(self.i)) +
            @as(f64, @floatFromInt(self.f)) / std.math.pow(f64, 10, @floatFromInt(self.v));

        return self;
    }

    /// Multiply by a power of ten, saturating rather than wrapping.
    fn saturatingScale(value: u64, power: u32) u64 {
        const factor = std.math.powi(u64, 10, power) catch return std.math.maxInt(u64);
        return std.math.mul(u64, value, factor) catch std.math.maxInt(u64);
    }

    fn parseDigits(text: []const u8) u64 {
        var total: u64 = 0;
        for (text) |c| {
            if (!std.ascii.isDigit(c)) continue;
            total = std.math.mul(u64, total, 10) catch return std.math.maxInt(u64);
            total = std.math.add(u64, total, c - '0') catch return std.math.maxInt(u64);
        }
        return total;
    }

    fn operandValue(self: Operands, operand: Operand) f64 {
        return switch (operand) {
            .n => self.n,
            .i => @floatFromInt(self.i),
            .v => @floatFromInt(self.v),
            .w => @floatFromInt(self.w),
            .f => @floatFromInt(self.f),
            .t => @floatFromInt(self.t),
            .e => @floatFromInt(self.e),
        };
    }
};

/// Which category `operands` falls into for `locale`.
///
/// A locale with no rules of its own -- one CLDR does not cover, or any locale
/// at all when asked for ordinals it has no rules for -- gets `other`, which
/// is the category every language has and every select expression must
/// provide a variant for.
pub fn select(locale: *const Locale, kind: Kind, operands: Operands) Category {
    const table = switch (kind) {
        .cardinal => data.cardinal,
        .ordinal => data.ordinal,
    };
    const index = locale.lookup(table.keys) orelse return .other;
    return selectFrom(table.rules[index], operands);
}

/// Apply a rule set. The rules are tried in order and the first whose
/// condition holds wins, so a generated table must keep CLDR's order.
pub fn selectFrom(rules: RuleSet, operands: Operands) Category {
    for (rules) |rule| {
        if (matches(rule.condition, operands)) return rule.category;
    }
    return .other;
}

fn matches(condition: Condition, operands: Operands) bool {
    // An empty condition is the unconditional rule CLDR writes for `other`.
    if (condition.len == 0) return true;

    for (condition) |conjunction| {
        var all = true;
        for (conjunction) |relation| {
            if (!relationHolds(relation, operands)) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

fn relationHolds(relation: Relation, operands: Operands) bool {
    var x = operands.operandValue(relation.operand);
    if (relation.modulus != 0) {
        // CLDR's `mod` is a remainder that keeps the sign of the dividend, but
        // every operand here is non-negative, so it is the ordinary one.
        x = @mod(x, @as(f64, @floatFromInt(relation.modulus)));
    }

    var found = false;
    for (relation.ranges) |range| {
        if (inRange(x, range)) {
            found = true;
            break;
        }
    }
    return found != relation.negated;
}

/// Whether `x` is one of the integers a range covers.
///
/// The integrality test is not an optimization, it is the rule: CLDR ranges
/// enumerate integers, so `n = 0..1` is true of 0, 1 and `1.0`, and false of
/// `0.5`. Without it every language whose `one` is written as a range would
/// claim the halves between.
fn inRange(x: f64, range: Range) bool {
    // Not finite, not whole, or negative: no range covers it. `n` is an
    // absolute value so the sign test is belt and braces, but the operands can
    // be reached from arbitrary text and this is cheaper than being sure.
    if (!std.math.isFinite(x)) return false;
    if (x != @floor(x)) return false;
    if (x < 0) return false;
    // Strictly less than 2^64, not "not greater than the largest u64": the
    // largest u64 does not survive the trip through `f64` -- it rounds up to
    // 2^64 exactly -- so comparing against it lets 2^64 through, and
    // `@intFromFloat` on that is a panic rather than an error. A fuzz target
    // found this.
    if (x >= 18446744073709551616.0) return false;
    const integer: u64 = @intFromFloat(x);
    return integer >= range.low and integer <= range.high;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "operands come from the digits, not the value" {
    const one = Operands.fromDecimal("1");
    try testing.expectEqual(@as(f64, 1), one.n);
    try testing.expectEqual(@as(u64, 1), one.i);
    try testing.expectEqual(@as(u32, 0), one.v);
    try testing.expectEqual(@as(u32, 0), one.w);

    // The same value, shown to two places, is a different set of operands --
    // which is exactly why English says "1.00 files" and not "1.00 file".
    const padded = Operands.fromDecimal("1.00");
    try testing.expectEqual(@as(f64, 1), padded.n);
    try testing.expectEqual(@as(u64, 1), padded.i);
    try testing.expectEqual(@as(u32, 2), padded.v);
    try testing.expectEqual(@as(u32, 0), padded.w);
    try testing.expectEqual(@as(u64, 0), padded.f);
    try testing.expectEqual(@as(u64, 0), padded.t);
}

test "trailing zeros separate v from w and f from t" {
    const o = Operands.fromDecimal("1.230");
    try testing.expectEqual(@as(u32, 3), o.v);
    try testing.expectEqual(@as(u32, 2), o.w);
    try testing.expectEqual(@as(u64, 230), o.f);
    try testing.expectEqual(@as(u64, 23), o.t);
    try testing.expectApproxEqAbs(@as(f64, 1.23), o.n, 1e-12);
}

test "nonsense decimals saturate instead of panicking" {
    // `fromDecimal` is public and takes any slice at all, so every one of
    // these has to produce operands rather than a crash.
    for ([_][]const u8{
        "1c99",
        "9999999999999999999999999999999c30",
        "1.!!!!c3",
        "0.99999999999999999999999999999999c25",
        "..",
        "-.c",
        "1c",
    }) |text| {
        const operands = Operands.fromDecimal(text);
        try testing.expect(!(operands.n < 0));
    }
}

test "compact notation shifts the point before the operands are taken" {
    // The table in UTS #35 gives these exactly: a compact million has six
    // figures and no fraction digits, however its mantissa was written.
    const millions = Operands.fromDecimal("1c6");
    try testing.expectEqual(@as(f64, 1000000), millions.n);
    try testing.expectEqual(@as(u64, 1000000), millions.i);
    try testing.expectEqual(@as(u32, 0), millions.v);
    try testing.expectEqual(@as(u32, 6), millions.e);

    const with_fraction = Operands.fromDecimal("1.1c3");
    try testing.expectEqual(@as(f64, 1100), with_fraction.n);
    try testing.expectEqual(@as(u64, 1100), with_fraction.i);
    try testing.expectEqual(@as(u32, 0), with_fraction.v);

    // More fraction digits than the exponent consumes: what is left stays
    // fraction, and is still visible.
    const leftover = Operands.fromDecimal("1.0001c3");
    try testing.expectApproxEqAbs(@as(f64, 1000.1), leftover.n, 1e-9);
    try testing.expectEqual(@as(u64, 1000), leftover.i);
    try testing.expectEqual(@as(u32, 1), leftover.v);
    try testing.expectEqual(@as(u64, 1), leftover.f);
}

test "French reserves many for round millions and compact notation" {
    const fr = try Locale.parse("fr");
    try testing.expectEqual(Category.many, select(&fr, .cardinal, Operands.fromDecimal("1000000")));
    try testing.expectEqual(Category.many, select(&fr, .cardinal, Operands.fromDecimal("1c6")));
    try testing.expectEqual(Category.other, select(&fr, .cardinal, Operands.fromDecimal("1000001")));
    try testing.expectEqual(Category.one, select(&fr, .cardinal, Operands.fromDecimal("1")));
    // French counts zero and one alike, which English does not.
    try testing.expectEqual(Category.one, select(&fr, .cardinal, Operands.fromDecimal("0")));
}

test "the sign is dropped and grouping separators are ignored" {
    const negative = Operands.fromDecimal("-42");
    try testing.expectEqual(@as(f64, 42), negative.n);
    try testing.expectEqual(@as(u64, 42), negative.i);

    const grouped = Operands.fromDecimal("1,234");
    try testing.expectEqual(@as(u64, 1234), grouped.i);
}

test "a range refuses what cannot be an integer in it" {
    try testing.expect(!inRange(std.math.nan(f64), .{ .low = 0, .high = 1 }));
    try testing.expect(!inRange(std.math.inf(f64), .{ .low = 0, .high = 1 }));
    try testing.expect(!inRange(-1, .{ .low = 0, .high = 1 }));
    // 2^64 exactly, which is what the largest u64 becomes as an f64.
    try testing.expect(!inRange(18446744073709551616.0, .{ .low = 0, .high = 1 }));
}

test "a range covers integers only" {
    try testing.expect(inRange(0, .{ .low = 0, .high = 1 }));
    try testing.expect(inRange(1, .{ .low = 0, .high = 1 }));
    try testing.expect(!inRange(0.5, .{ .low = 0, .high = 1 }));
    try testing.expect(!inRange(2, .{ .low = 0, .high = 1 }));
}

test "English cardinal: one is exactly one, undecorated" {
    const en = try Locale.parse("en");
    try testing.expectEqual(Category.one, select(&en, .cardinal, Operands.fromDecimal("1")));
    try testing.expectEqual(Category.other, select(&en, .cardinal, Operands.fromDecimal("0")));
    try testing.expectEqual(Category.other, select(&en, .cardinal, Operands.fromDecimal("2")));
    // `i = 1 and v = 0`, so a shown decimal place takes it out of `one`.
    try testing.expectEqual(Category.other, select(&en, .cardinal, Operands.fromDecimal("1.0")));
}

test "English ordinal has four categories where cardinal has two" {
    const en = try Locale.parse("en");
    try testing.expectEqual(Category.one, select(&en, .ordinal, Operands.fromDecimal("1")));
    try testing.expectEqual(Category.two, select(&en, .ordinal, Operands.fromDecimal("2")));
    try testing.expectEqual(Category.few, select(&en, .ordinal, Operands.fromDecimal("3")));
    try testing.expectEqual(Category.other, select(&en, .ordinal, Operands.fromDecimal("4")));
    // 11th, 12th, 13th -- the exceptions English speakers know without knowing.
    try testing.expectEqual(Category.other, select(&en, .ordinal, Operands.fromDecimal("11")));
    try testing.expectEqual(Category.other, select(&en, .ordinal, Operands.fromDecimal("13")));
    try testing.expectEqual(Category.one, select(&en, .ordinal, Operands.fromDecimal("21")));
}

test "Russian cardinal distinguishes one, few and many" {
    const ru = try Locale.parse("ru");
    try testing.expectEqual(Category.one, select(&ru, .cardinal, Operands.fromDecimal("1")));
    try testing.expectEqual(Category.one, select(&ru, .cardinal, Operands.fromDecimal("21")));
    try testing.expectEqual(Category.many, select(&ru, .cardinal, Operands.fromDecimal("11")));
    try testing.expectEqual(Category.few, select(&ru, .cardinal, Operands.fromDecimal("2")));
    try testing.expectEqual(Category.few, select(&ru, .cardinal, Operands.fromDecimal("23")));
    try testing.expectEqual(Category.many, select(&ru, .cardinal, Operands.fromDecimal("5")));
    try testing.expectEqual(Category.many, select(&ru, .cardinal, Operands.fromDecimal("0")));
}

test "Welsh uses every category there is" {
    const cy = try Locale.parse("cy");
    try testing.expectEqual(Category.zero, select(&cy, .cardinal, Operands.fromDecimal("0")));
    try testing.expectEqual(Category.one, select(&cy, .cardinal, Operands.fromDecimal("1")));
    try testing.expectEqual(Category.two, select(&cy, .cardinal, Operands.fromDecimal("2")));
    try testing.expectEqual(Category.few, select(&cy, .cardinal, Operands.fromDecimal("3")));
    try testing.expectEqual(Category.many, select(&cy, .cardinal, Operands.fromDecimal("6")));
    try testing.expectEqual(Category.other, select(&cy, .cardinal, Operands.fromDecimal("4")));
}

test "Japanese has one category and uses it for everything" {
    const ja = try Locale.parse("ja");
    for ([_][]const u8{ "0", "1", "2", "11", "100", "1.5" }) |sample| {
        try testing.expectEqual(Category.other, select(&ja, .cardinal, Operands.fromDecimal(sample)));
    }
}

test "a region falls back to its language, and pt-PT does not" {
    // CLDR files a rule set for pt-PT that differs from pt's, so the two must
    // not collapse into each other.
    const pt = try Locale.parse("pt");
    const pt_pt = try Locale.parse("pt-PT");
    const pt_br = try Locale.parse("pt-BR");

    try testing.expectEqual(Category.one, select(&pt, .cardinal, Operands.fromDecimal("0")));
    try testing.expectEqual(Category.other, select(&pt_pt, .cardinal, Operands.fromDecimal("0")));
    // No rules for pt-BR, so it inherits pt's.
    try testing.expectEqual(Category.one, select(&pt_br, .cardinal, Operands.fromDecimal("0")));
}

test "an unknown locale gets the one category every language has" {
    const zz = try Locale.parse("zz");
    try testing.expectEqual(Category.other, select(&zz, .cardinal, Operands.fromDecimal("1")));
    try testing.expectEqual(Category.other, select(&Locale.root, .cardinal, Operands.fromDecimal("1")));
}

test "every sample CLDR publishes lands in the category CLDR assigns it" {
    // Around fifteen thousand assertions, and the strongest check there is
    // that the compiled rules and the operand derivation are right: CLDR
    // states the category of each of these values itself, so a disagreement is
    // this library being wrong rather than a test being out of date. The
    // samples are only compiled by the test build.
    const samples = @import("cldr/plural_samples.zig");

    for ([_]struct { Kind, []const samples.Sample }{
        .{ .cardinal, samples.cardinal_samples },
        .{ .ordinal, samples.ordinal_samples },
    }) |group| {
        const kind, const list = group;
        for (list) |sample| {
            const locale = try Locale.parse(sample.tag);
            const got = select(&locale, kind, Operands.fromDecimal(sample.value));
            if (got != sample.category) {
                std.debug.print("{s} {t} {s}: expected {t}, got {t}\n", .{
                    sample.tag, kind, sample.value, sample.category, got,
                });
                return error.WrongPluralCategory;
            }
        }
    }
}

test "a variant key is only a category if it names one" {
    try testing.expectEqual(Category.few, Category.fromName("few").?);
    try testing.expectEqual(@as(?Category, null), Category.fromName("masculine"));
    try testing.expectEqual(@as(?Category, null), Category.fromName(""));
}
