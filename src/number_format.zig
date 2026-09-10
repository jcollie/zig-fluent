// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning a number into the digits a reader of a given language expects.
//!
//! Everything locale-specific arrives as data -- the separators, the digits
//! themselves, where the groups fall, what goes around a negative number or a
//! currency amount. What is here is the part that is the same everywhere:
//! rounding to a number of places or a number of significant figures, padding
//! to a minimum, and inserting the group separators.
//!
//! The option names and their defaults are ECMA-402's, because that is what
//! Fluent's `NUMBER()` builtin exposes to translators and what an application
//! passing a preconfigured value will expect:
//!
//! ```ftl
//! pi = π is about { NUMBER($pi, maximumFractionDigits: 2) }
//! ```
//!
//! ## Rounding
//!
//! A double almost never holds the number that was written down. `1.005` is
//! really 1.00499999999999989..., so there are two defensible answers when it
//! is rounded to two places, and they differ: round the value stored and the
//! answer is `1.00`; round its shortest printable form -- the decimal that
//! reads back as the same double, which is `1.005` -- and the answer is
//! `1.01`.
//!
//! This rounds the shortest form, which is what ICU does and therefore what
//! `Intl.NumberFormat` gives in a browser. It is also the answer a person
//! expects, since `1.005` is what they wrote. Note that it is *not* what
//! JavaScript's `toFixed` gives, which rounds the stored value and answers
//! `1.00`; the two disagree in exactly this corner and always have.
//!
//! The behavior comes for free from `std.fmt.float.render`, which works from
//! the shortest form the same way.

const std = @import("std");

/// The characters a locale writes numbers with.
///
/// The defaults are CLDR's root locale, which is what an unknown language
/// falls back to.
pub const Symbols = struct {
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    minus_sign: []const u8 = "-",
    plus_sign: []const u8 = "+",
    percent_sign: []const u8 = "%",
    nan: []const u8 = "NaN",
    infinity: []const u8 = "∞",
    /// The ten digits of the locale's default numbering system, in order, as
    /// one UTF-8 string. Not always ASCII: Eastern Arabic numerals, Devanagari
    /// digits and a dozen others are the default for the languages that use
    /// them, and each digit may be several bytes.
    digits: []const u8 = "0123456789",
};

/// What a CLDR number pattern says, once compiled.
///
/// CLDR writes these as strings like `#,##0.###` or `¤ #,##0.00;¤ -#,##0.00`.
/// The interesting parts are the affixes -- everything that is not a digit
/// placeholder -- and where the group separators fall, which is not always
/// every three: several South Asian languages group the lowest three digits
/// and then every two, so 1234567 is written `12,34,567`.
pub const Pattern = struct {
    positive_prefix: []const u8 = "",
    positive_suffix: []const u8 = "",
    /// Empty means "the positive prefix with the minus sign in front", which
    /// is what CLDR means by a pattern with no negative subpattern.
    negative_prefix: ?[]const u8 = null,
    negative_suffix: ?[]const u8 = null,

    /// Digits in the lowest group, and in every group above it.
    primary_grouping: u8 = 3,
    secondary_grouping: u8 = 3,
    /// How many integer digits a number needs before it is grouped at all.
    ///
    /// CLDR's `minimumGroupingDigits`. Polish sets it to 2, so 1000 is written
    /// `1000` and only 10000 becomes `10 000`.
    minimum_grouping_digits: u8 = 1,

    minimum_integer_digits: u8 = 1,
    minimum_fraction_digits: u8 = 0,
    maximum_fraction_digits: u8 = 3,
};

pub const Style = enum { decimal, percent, currency };

pub const CurrencyDisplay = enum { symbol, narrow_symbol, code, name };

/// ECMA-402's number formatting options, restricted to what this implements.
///
/// A null means "whatever the pattern for this style says", which is how
/// ECMA-402 defines the defaults: they come from the locale rather than being
/// fixed numbers.
pub const Options = struct {
    style: Style = .decimal,

    minimum_integer_digits: ?u8 = null,
    minimum_fraction_digits: ?u8 = null,
    maximum_fraction_digits: ?u8 = null,
    minimum_significant_digits: ?u8 = null,
    maximum_significant_digits: ?u8 = null,

    use_grouping: bool = true,

    /// The ISO 4217 code, e.g. `"EUR"`. Required when the style is currency.
    currency: ?[]const u8 = null,
    currency_display: CurrencyDisplay = .symbol,

    /// The text to put where the pattern has its currency placeholder. The
    /// caller resolves `currency` and `currency_display` against the locale's
    /// data and passes the answer, because which of a currency's several names
    /// applies is a question about the locale and not about the number.
    currency_text: []const u8 = "",

    /// How many fraction digits this currency is normally written with, when
    /// the style is currency and the caller has not said otherwise. Two for
    /// most currencies, zero for the yen, three for the dinar.
    currency_digits: u8 = 2,

    /// Merge in only the options that were set, leaving the rest alone.
    ///
    /// This is how `NUMBER()` layers a call's options over those a value
    /// already carried: `{ NUMBER($n, maximumFractionDigits: 2) }` where `$n`
    /// arrived as a currency amount must stay a currency amount.
    pub fn override(self: Options, other: Options) Options {
        var merged = self;
        if (other.style != .decimal) merged.style = other.style;
        if (other.minimum_integer_digits) |v| merged.minimum_integer_digits = v;
        if (other.minimum_fraction_digits) |v| merged.minimum_fraction_digits = v;
        if (other.maximum_fraction_digits) |v| merged.maximum_fraction_digits = v;
        if (other.minimum_significant_digits) |v| merged.minimum_significant_digits = v;
        if (other.maximum_significant_digits) |v| merged.maximum_significant_digits = v;
        if (!other.use_grouping) merged.use_grouping = false;
        if (other.currency) |v| merged.currency = v;
        if (other.currency_display != .symbol) merged.currency_display = other.currency_display;
        if (other.currency_text.len != 0) merged.currency_text = other.currency_text;
        if (other.currency_digits != 2) merged.currency_digits = other.currency_digits;
        return merged;
    }
};

/// Everything needed to format a number for one locale.
pub const Formatter = struct {
    symbols: Symbols = .{},
    pattern: Pattern = .{},
    options: Options = .{},

    /// The largest number of fraction digits that can be asked for.
    ///
    /// ECMA-402 allows up to 100, but a double carries at most 17 significant
    /// figures and everything past that is an artifact of the binary
    /// representation rather than information. Capping keeps the working
    /// buffers on the stack.
    const max_precision = 40;

    /// How many digits either side of the point the working buffers hold.
    ///
    /// The bound that matters is not the option but the number: `1e308` has
    /// 309 integer digits before anything is asked for, and the smallest
    /// subnormal has 323 leading zeros after the point. Add the largest
    /// padding a caller can request and 512 covers every case with room over.
    /// A fuzz target found this the hard way, against a 64-entry array.
    const max_digits = 512;

    pub fn format(self: Formatter, value: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.math.isNan(value)) {
            try w.writeAll(self.symbols.nan);
            return;
        }

        // Signed zero counts as negative: a rounded-away -0.4 should still
        // read as a small negative quantity rather than flipping sign.
        const negative = std.math.signbit(value);
        var magnitude = @abs(value);
        if (self.options.style == .percent) magnitude *= 100;

        // A pattern with no negative form of its own means "the positive one
        // with a minus sign in front", which is what CLDR says such a pattern
        // means. A pattern that does have one has already put the sign
        // wherever the locale puts it -- in brackets, or after the amount.
        if (negative and !self.hasNegativePattern()) try w.writeAll(self.symbols.minus_sign);
        try self.writeAffix(w, self.prefix(negative));

        if (std.math.isInf(magnitude)) {
            try w.writeAll(self.symbols.infinity);
        } else {
            var integer_buffer: [max_digits]u8 = undefined;
            var fraction_buffer: [max_digits]u8 = undefined;
            const parts = self.round(magnitude, &integer_buffer, &fraction_buffer);

            try self.writeInteger(w, parts.integer);
            if (parts.fraction.len != 0) {
                try w.writeAll(self.symbols.decimal);
                try self.writeDigits(w, parts.fraction);
            }
        }

        try self.writeAffix(w, self.suffix(negative));
    }

    fn hasNegativePattern(self: Formatter) bool {
        return self.pattern.negative_prefix != null or self.pattern.negative_suffix != null;
    }

    fn prefix(self: Formatter, negative: bool) []const u8 {
        if (!negative) return self.pattern.positive_prefix;
        return self.pattern.negative_prefix orelse self.pattern.positive_prefix;
    }

    fn suffix(self: Formatter, negative: bool) []const u8 {
        if (!negative) return self.pattern.positive_suffix;
        return self.pattern.negative_suffix orelse self.pattern.positive_suffix;
    }

    /// Write an affix, expanding the placeholders CLDR leaves in it.
    ///
    /// CLDR patterns carry `¤` where the currency goes and `%` where the
    /// percent sign goes, and both are stand-ins for text the locale supplies
    /// rather than the characters themselves.
    fn writeAffix(self: Formatter, w: *std.Io.Writer, affix: []const u8) std.Io.Writer.Error!void {
        var rest = affix;
        while (rest.len != 0) {
            const next = std.mem.indexOfAny(u8, rest, "%¤-+") orelse {
                try w.writeAll(rest);
                return;
            };
            try w.writeAll(rest[0..next]);
            switch (rest[next]) {
                '%' => try w.writeAll(self.symbols.percent_sign),
                '-' => try w.writeAll(self.symbols.minus_sign),
                '+' => try w.writeAll(self.symbols.plus_sign),
                else => {
                    // The currency placeholder is U+00A4, whose UTF-8 is two
                    // bytes; `indexOfAny` found the first of them.
                    try w.writeAll(self.options.currency_text);
                    rest = rest[next + 2 ..];
                    continue;
                },
            }
            rest = rest[next + 1 ..];
        }
    }

    const Parts = struct {
        integer: []const u8,
        fraction: []const u8,
    };

    /// Round `magnitude` and return its digits, already padded to the minima.
    fn round(
        self: Formatter,
        magnitude: f64,
        integer_buffer: []u8,
        fraction_buffer: []u8,
    ) Parts {
        if (self.options.maximum_significant_digits != null or
            self.options.minimum_significant_digits != null)
        {
            return self.roundSignificant(magnitude, integer_buffer, fraction_buffer);
        }
        return self.roundFractional(magnitude, integer_buffer, fraction_buffer);
    }

    /// The default: round to a number of decimal places.
    fn roundFractional(self: Formatter, magnitude: f64, integer_buffer: []u8, fraction_buffer: []u8) Parts {
        const minimum, const maximum = self.fractionDigits();

        var render_buffer: [max_digits * 2]u8 = undefined;
        // `max_digits` is chosen so this cannot happen; falling back rather
        // than asserting means a future change to the bound is a wrong number
        // instead of a crash in whatever was rendering a page.
        const text = std.fmt.float.render(&render_buffer, magnitude, .{
            .mode = .decimal,
            .precision = maximum,
        }) catch "0";

        const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        var fraction = if (dot < text.len) text[dot + 1 ..] else "";

        // Trailing zeros past the minimum are not shown: `maximumFractionDigits`
        // is a ceiling, not a width.
        while (fraction.len > minimum and fraction[fraction.len - 1] == '0') {
            fraction = fraction[0 .. fraction.len - 1];
        }

        return .{
            .integer = self.padInteger(text[0..dot], integer_buffer),
            .fraction = copy(fraction_buffer, fraction),
        };
    }

    /// Round to a number of significant figures, which ECMA-402 says takes
    /// precedence over the fraction-digit settings when either is given.
    fn roundSignificant(self: Formatter, magnitude: f64, integer_buffer: []u8, fraction_buffer: []u8) Parts {
        // At least one significant figure, whatever was asked for. ECMA-402
        // requires these to be between 1 and 21 and refuses anything else, but
        // they arrive from a translation file where any number at all can be
        // typed, and clamping prints a sensible number where refusing would
        // print a fallback in the middle of somebody's sentence. Zero is the
        // one that mattered: it made the scientific rendering below ask for a
        // precision of minus one, which a fuzz target found as an overflow.
        const minimum: usize = @max(1, self.options.minimum_significant_digits orelse 1);
        const maximum: usize = @max(
            minimum,
            self.options.maximum_significant_digits orelse 21,
        );

        if (magnitude == 0) {
            // Zero has no significant figures of its own, so it is written
            // with as many as were asked for at least.
            var fraction_length: usize = 0;
            if (minimum > 1) fraction_length = minimum - 1;
            @memset(fraction_buffer[0..fraction_length], '0');
            return .{
                .integer = self.padInteger("0", integer_buffer),
                .fraction = fraction_buffer[0..fraction_length],
            };
        }

        // Scientific notation at precision N-1 rounds to exactly N significant
        // figures, and hands back the digits and the exponent already split.
        var render_buffer: [max_digits * 2]u8 = undefined;
        const text = std.fmt.float.render(&render_buffer, magnitude, .{
            .mode = .scientific,
            .precision = @min(maximum, max_precision) - 1,
        }) catch "0e0";

        const e = std.mem.indexOfScalar(u8, text, 'e').?;
        const exponent = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch 0;

        var digits: [max_precision + 2]u8 = undefined;
        var digit_count: usize = 0;
        for (text[0..e]) |c| {
            if (!std.ascii.isDigit(c)) continue;
            digits[digit_count] = c;
            digit_count += 1;
        }

        // Drop trailing zeros that are not needed to reach the minimum.
        while (digit_count > minimum and digits[digit_count - 1] == '0') digit_count -= 1;

        // `exponent` is the power of ten of the first digit, so there are
        // exponent + 1 digits before the point when it is not negative.
        var integer_length: usize = 0;
        var fraction_length: usize = 0;
        var integer_text: []const u8 = "0";

        if (exponent >= 0) {
            integer_length = @min(@as(usize, @intCast(exponent)) + 1, digit_count);
            @memcpy(integer_buffer[0..integer_length], digits[0..integer_length]);
            // A number bigger than the digits it was rounded to: pad with the
            // zeros that carry it up to its magnitude, as in 1200 from "12e3".
            const zeros = @as(usize, @intCast(exponent)) + 1 - integer_length;
            @memset(integer_buffer[integer_length..][0..zeros], '0');
            integer_length += zeros;
            integer_text = integer_buffer[0..integer_length];

            const rest = digits[@min(@as(usize, @intCast(exponent)) + 1, digit_count)..digit_count];
            fraction_length = copy(fraction_buffer, rest).len;
        } else {
            // Smaller than one: leading zeros after the point, then the digits.
            const leading = @as(usize, @intCast(-exponent)) - 1;
            @memset(fraction_buffer[0..leading], '0');
            @memcpy(fraction_buffer[leading..][0..digit_count], digits[0..digit_count]);
            fraction_length = leading + digit_count;
        }

        // The integer digits were built in `integer_buffer` already; padding it
        // to a minimum width has to shift them, so it is done into a copy.
        var padded_buffer: [max_digits]u8 = undefined;
        const padded = self.padInteger(integer_text, &padded_buffer);
        return .{
            .integer = copy(integer_buffer, padded),
            .fraction = fraction_buffer[0..fraction_length],
        };
    }

    /// The fraction-digit bounds in force, given the style and the pattern.
    fn fractionDigits(self: Formatter) struct { usize, usize } {
        var minimum: usize = self.pattern.minimum_fraction_digits;
        var maximum: usize = self.pattern.maximum_fraction_digits;

        switch (self.options.style) {
            .decimal => {},
            // ECMA-402: a percentage is a whole number of percent unless asked
            // otherwise, however the locale's decimal pattern is written.
            .percent => {
                minimum = 0;
                maximum = 0;
            },
            // And a currency amount is written to that currency's own number
            // of places: two for most, none for the yen, three for the dinar.
            .currency => {
                minimum = self.options.currency_digits;
                maximum = self.options.currency_digits;
            },
        }

        if (self.options.minimum_fraction_digits) |v| minimum = v;
        if (self.options.maximum_fraction_digits) |v| maximum = v;
        // Asking for more places at least than at most is a contradiction; the
        // floor wins, which is what ECMA-402 does.
        maximum = @max(minimum, maximum);

        return .{ @min(minimum, max_precision), @min(maximum, max_precision) };
    }

    fn padInteger(self: Formatter, digits: []const u8, buffer: []u8) []const u8 {
        const requested: usize = self.options.minimum_integer_digits orelse
            self.pattern.minimum_integer_digits;
        const minimum = @min(requested, buffer.len);
        if (digits.len >= minimum) return copy(buffer, digits);

        const zeros = minimum - digits.len;
        @memset(buffer[0..zeros], '0');
        @memcpy(buffer[zeros..][0..digits.len], digits);
        return buffer[0 .. zeros + digits.len];
    }

    /// Write the integer digits with group separators in the right places.
    fn writeInteger(self: Formatter, w: *std.Io.Writer, digits: []const u8) std.Io.Writer.Error!void {
        const primary = self.pattern.primary_grouping;
        const secondary = self.pattern.secondary_grouping;

        const grouped = self.options.use_grouping and primary > 0 and
            digits.len >= @as(usize, primary) + self.pattern.minimum_grouping_digits;
        if (!grouped) return self.writeDigits(w, digits);

        // Work out where the separators fall by counting from the right, then
        // write left to right.
        if (digits.len > max_digits) return self.writeDigits(w, digits);
        var boundaries: [max_digits]bool = @splat(false);
        var position: usize = primary;
        while (position < digits.len) {
            boundaries[digits.len - position] = true;
            position += secondary;
            if (secondary == 0) break;
        }

        for (digits, 0..) |digit, i| {
            if (i != 0 and boundaries[i]) try w.writeAll(self.symbols.group);
            try self.writeDigit(w, digit);
        }
    }

    fn writeDigits(self: Formatter, w: *std.Io.Writer, digits: []const u8) std.Io.Writer.Error!void {
        for (digits) |digit| try self.writeDigit(w, digit);
    }

    /// Write one ASCII digit in the locale's numbering system.
    fn writeDigit(self: Formatter, w: *std.Io.Writer, digit: u8) std.Io.Writer.Error!void {
        if (self.symbols.digits.ptr == default_digits.ptr) return w.writeByte(digit);

        // The digits are ten code points in a string, and outside Latin script
        // they are rarely one byte each, so the string is walked rather than
        // indexed.
        var it = std.unicode.Utf8Iterator{ .bytes = self.symbols.digits, .i = 0 };
        var wanted = digit - '0';
        while (it.nextCodepointSlice()) |slice| {
            if (wanted == 0) return w.writeAll(slice);
            wanted -= 1;
        }
        try w.writeByte(digit);
    }
};

const default_digits = "0123456789";

fn copy(buffer: []u8, text: []const u8) []const u8 {
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectFormat(formatter: Formatter, value: f64, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try formatter.format(value, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "the default is three places at most and none at least" {
    const f: Formatter = .{};
    try expectFormat(f, 1, "1");
    try expectFormat(f, 1.5, "1.5");
    try expectFormat(f, 1.23456, "1.235");
    try expectFormat(f, 0, "0");
}

test "groups every three digits, and not before there are four" {
    const f: Formatter = .{};
    try expectFormat(f, 999, "999");
    try expectFormat(f, 1000, "1,000");
    try expectFormat(f, 1234567, "1,234,567");
    try expectFormat(f, -1234567.5, "-1,234,567.5");
}

test "grouping can be switched off" {
    const f: Formatter = .{ .options = .{ .use_grouping = false } };
    try expectFormat(f, 1234567, "1234567");
}

test "a locale may need more digits before it groups at all" {
    // Polish writes 1000 without a separator and 10 000 with one.
    const f: Formatter = .{
        .symbols = .{ .group = "\u{00A0}" },
        .pattern = .{ .minimum_grouping_digits = 2 },
    };
    try expectFormat(f, 1000, "1000");
    try expectFormat(f, 10000, "10\u{00A0}000");
}

test "Indian grouping takes three digits and then two" {
    const f: Formatter = .{ .pattern = .{ .primary_grouping = 3, .secondary_grouping = 2 } };
    try expectFormat(f, 1234567, "12,34,567");
    try expectFormat(f, 100000, "1,00,000");
    try expectFormat(f, 1000, "1,000");
}

test "fraction digits are a floor and a ceiling" {
    try expectFormat(.{ .options = .{ .minimum_fraction_digits = 2 } }, 1, "1.00");
    try expectFormat(.{ .options = .{ .maximum_fraction_digits = 2 } }, 1.239, "1.24");
    try expectFormat(.{ .options = .{ .maximum_fraction_digits = 0 } }, 1.5, "2");
    // A floor above the ceiling: the floor wins.
    try expectFormat(
        .{ .options = .{ .minimum_fraction_digits = 3, .maximum_fraction_digits = 1 } },
        1.23456,
        "1.235",
    );
}

test "rounding matches Intl, which rounds the number as written" {
    // Each of these was checked against `Intl.NumberFormat` in V8. The value
    // stored for 1.005 is a shade under it, so rounding *that* would give
    // 1.00 -- but the shortest form that reads back as the same double is
    // "1.005", and rounding that is what ICU, and this, do.
    try expectFormat(.{ .options = .{ .maximum_fraction_digits = 2 } }, 1.005, "1.01");
    try expectFormat(.{ .options = .{ .maximum_fraction_digits = 2 } }, 2.675, "2.68");
    // 0.125 is exact in binary, and a half rounds away from zero.
    try expectFormat(.{ .options = .{ .maximum_fraction_digits = 2 } }, 0.125, "0.13");
}

test "integer digits can be padded to a minimum" {
    try expectFormat(.{ .options = .{ .minimum_integer_digits = 3 } }, 7, "007");
    try expectFormat(.{ .options = .{ .minimum_integer_digits = 2 } }, 1234, "1,234");
}

test "significant digits take over from fraction digits" {
    try expectFormat(.{ .options = .{ .maximum_significant_digits = 3 } }, 123456, "123,000");
    try expectFormat(.{ .options = .{ .maximum_significant_digits = 3 } }, 1.23456, "1.23");
    try expectFormat(.{ .options = .{ .maximum_significant_digits = 3 } }, 0.000123456, "0.000123");
    try expectFormat(.{ .options = .{ .minimum_significant_digits = 5 } }, 1.5, "1.5000");
    try expectFormat(.{ .options = .{ .minimum_significant_digits = 3 } }, 0, "0.00");
}

test "asking for no significant figures still gives a number" {
    // Not a legal request -- ECMA-402 wants 1 to 21 -- but a translator can
    // type it, so it has to mean something rather than crash.
    try expectFormat(.{ .options = .{ .minimum_significant_digits = 0 } }, 1234.5, "1,234.5");
    try expectFormat(.{ .options = .{ .maximum_significant_digits = 0 } }, 1234.5, "1,000");
    try expectFormat(.{ .options = .{
        .minimum_significant_digits = 0,
        .maximum_significant_digits = 0,
    } }, 1234.5, "1,000");
}

test "a percentage is scaled and given its sign" {
    const f: Formatter = .{
        .pattern = .{ .positive_suffix = "%" },
        .options = .{ .style = .percent },
    };
    try expectFormat(f, 0.25, "25%");
    try expectFormat(f, 1, "100%");
    // Whole percent by default, however many places the value has.
    try expectFormat(f, 0.1234, "12%");
}

test "a currency amount takes the currency's own number of places" {
    const euro: Formatter = .{
        .pattern = .{ .positive_prefix = "¤" },
        .options = .{ .style = .currency, .currency_text = "€", .currency_digits = 2 },
    };
    try expectFormat(euro, 1234.5, "€1,234.50");

    const yen: Formatter = .{
        .pattern = .{ .positive_prefix = "¤" },
        .options = .{ .style = .currency, .currency_text = "¥", .currency_digits = 0 },
    };
    try expectFormat(yen, 1234.5, "¥1,235");
}

test "a pattern with no negative form gets the minus sign in front" {
    const f: Formatter = .{ .pattern = .{ .positive_prefix = "¤" }, .options = .{
        .style = .currency,
        .currency_text = "$",
    } };
    try expectFormat(f, -5, "-$5.00");
}

test "a pattern may put the negative sign elsewhere" {
    // Several locales bracket a negative amount rather than signing it.
    const f: Formatter = .{ .pattern = .{
        .positive_prefix = "¤",
        .negative_prefix = "(¤",
        .negative_suffix = ")",
    }, .options = .{ .style = .currency, .currency_text = "$" } };
    try expectFormat(f, -5, "($5.00)");
    try expectFormat(f, 5, "$5.00");
}

test "the locale's own digits are used" {
    const f: Formatter = .{ .symbols = .{
        .digits = "٠١٢٣٤٥٦٧٨٩",
        .decimal = "٫",
        .group = "٬",
    } };
    try expectFormat(f, 1234.5, "١٬٢٣٤٫٥");
}

test "not a number, and the infinities" {
    const f: Formatter = .{};
    try expectFormat(f, std.math.nan(f64), "NaN");
    try expectFormat(f, std.math.inf(f64), "∞");
    try expectFormat(f, -std.math.inf(f64), "-∞");
}

test "negative zero keeps its sign" {
    try expectFormat(.{}, -0.0, "-0");
}

test "options are layered rather than replaced" {
    const base: Options = .{ .style = .currency, .currency = "EUR", .currency_digits = 2 };
    const merged = base.override(.{ .maximum_fraction_digits = 4 });
    try testing.expectEqual(Style.currency, merged.style);
    try testing.expectEqualStrings("EUR", merged.currency.?);
    try testing.expectEqual(@as(?u8, 4), merged.maximum_fraction_digits);
}
