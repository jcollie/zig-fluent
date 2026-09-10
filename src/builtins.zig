// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The two functions every Fluent bundle has.
//!
//! `NUMBER()` and `DATETIME()` exist so that a translator can say how a value
//! should be written without the application having decided for them. The
//! application passes a number; the translation decides whether this
//! particular sentence wants it to two decimal places.
//!
//! ```ftl
//! progress = { NUMBER($ratio, style: "percent") } done
//! saved = Last saved { DATETIME($when, timeStyle: "short") }
//! ```
//!
//! ## Which options a translator may set
//!
//! Only the ones on these lists, which are `fluent-bundle`'s. An option it
//! does not recognize is ignored rather than rejected, so a file written for a
//! newer version still works.
//!
//! The lists are worth reading for what they leave out. `NUMBER()` has no
//! `style`, `currency` or `unit`: a translator cannot turn a plain number into
//! a currency amount, because which currency it is is a fact about the
//! transaction and not about the sentence. An application that wants one
//! passes a value that already is one, and the options here are layered on top
//! of it. This implementation follows that exactly, deviating from the
//! reference in nothing a translation file can observe, so a file written
//! against `fluent.js` behaves the same here.

const std = @import("std");

const bundle_mod = @import("bundle.zig");
const datetime_format = @import("datetime_format.zig");
const number_format = @import("number_format.zig");
const value_mod = @import("value.zig");

const Bundle = bundle_mod.Bundle;
const Call = bundle_mod.Call;
const Value = value_mod.Value;
const Args = value_mod.Args;

/// Register the builtins on a new bundle.
pub fn install(bundle: *Bundle) std.mem.Allocator.Error!void {
    try bundle.addFunction("NUMBER", number);
    try bundle.addFunction("DATETIME", datetime);
}

test install {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    defer bundle.deinit();
    // `Bundle.init` calls this, so both are already there.
    try std.testing.expect(bundle.getFunction("NUMBER") != null);
    try std.testing.expect(bundle.getFunction("DATETIME") != null);
}

/// `NUMBER(value, ...options)` -- a number, formatted as asked.
pub fn number(call: Call) Value {
    const options = numberOptions(call);

    return switch (call.first()) {
        // A number that was already going to be a fallback stays one, with the
        // call wrapped around its label so the message says where it went
        // wrong: `{NUMBER($count)}`.
        .none => |label| .{ .none = std.fmt.allocPrint(
            call.arena,
            "NUMBER({s})",
            .{label},
        ) catch "NUMBER()" },
        .number => |n| .{
            .number = .{
                .value = n.value,
                .options = n.options.override(options),
                // Carried through: whether the number is a count or a rank is the
                // application's to say, and a call that adjusts the formatting
                // must not quietly change it.
                .plural_kind = n.plural_kind,
            },
        },
        // A moment as a number is its timestamp, which is what the reference
        // does and is occasionally what a translator wants to select on.
        .datetime => |d| .{ .number = .{
            .value = @floatFromInt(@divFloor(d.epoch_ms, std.time.ms_per_s)),
            .options = options,
        } },
        .string => {
            call.report(.invalid_argument, "NUMBER");
            return .{ .none = "NUMBER()" };
        },
    };
}

test number {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    defer bundle.deinit();
    bundle.use_isolating = false;
    try bundle.addResource(
        \\plain = { NUMBER($n) }
        \\rounded = { NUMBER($n, maximumFractionDigits: 2) }
        \\ungrouped = { NUMBER($n, useGrouping: "false") }
        \\
    , .{}, null);

    const args: Args = &.{.{ .name = "n", .value = .num(1234.56789) }};
    for ([_]struct { []const u8, []const u8 }{
        .{ "plain", "1,234.568" },
        .{ "rounded", "1,234.57" },
        .{ "ungrouped", "1234.568" },
    }) |case| {
        const name, const expected = case;
        const text = (try bundle.format(std.testing.allocator, name, args, null)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(expected, text);
    }
}

/// Read the options a `NUMBER()` call was written with.
///
/// Only the ones on the reference implementation's list; anything else is
/// ignored rather than refused, so a file written for a newer version still
/// works.
fn numberOptions(call: Call) number_format.Options {
    var options: number_format.Options = .{};

    if (call.numberOption("minimumIntegerDigits")) |v| options.minimum_integer_digits = clamp(v);
    if (call.numberOption("minimumFractionDigits")) |v| options.minimum_fraction_digits = clamp(v);
    if (call.numberOption("maximumFractionDigits")) |v| options.maximum_fraction_digits = clamp(v);
    if (call.numberOption("minimumSignificantDigits")) |v| options.minimum_significant_digits = clamp(v);
    if (call.numberOption("maximumSignificantDigits")) |v| options.maximum_significant_digits = clamp(v);

    // `useGrouping` is a string in FTL, since Fluent has no booleans. The
    // reference treats anything but "false" as true, and so does this.
    if (call.stringOption("useGrouping")) |text| {
        options.use_grouping = !std.mem.eql(u8, text, "false");
    }
    if (call.enumOption(number_format.CurrencyDisplay, "currencyDisplay")) |v| {
        options.currency_display = v;
    }

    return options;
}

/// Narrow a digit count written in FTL, where any number at all can be typed.
///
/// Clamped rather than rejected: `maximumFractionDigits: 500` is a translator
/// mistake, and quietly capping it prints a sensible number where refusing
/// would print a fallback in the middle of their sentence.
fn clamp(v: f64) u8 {
    if (!(v >= 0)) return 0; // also catches NaN
    if (v > 100) return 100;
    return @intFromFloat(v);
}

/// `DATETIME(value, ...options)` -- a moment, formatted as asked.
pub fn datetime(call: Call) Value {
    const options = datetimeOptions(call);

    return switch (call.first()) {
        .none => |label| .{ .none = std.fmt.allocPrint(
            call.arena,
            "DATETIME({s})",
            .{label},
        ) catch "DATETIME()" },
        .datetime => |d| .{ .datetime = .{ .epoch_ms = d.epoch_ms, .options = d.options.override(options) } },
        // A bare number is seconds since the epoch, matching the reference,
        // which takes the JavaScript convention of a numeric timestamp.
        .number => |n| .{ .datetime = .{
            .epoch_ms = epochMilliFromSeconds(n.value),
            .options = options,
        } },
        .string => {
            call.report(.invalid_argument, "DATETIME");
            return .{ .none = "DATETIME()" };
        },
    };
}

test datetime {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    defer bundle.deinit();
    bundle.use_isolating = false;
    try bundle.addResource("m = { DATETIME($t, dateStyle: \"short\") }\n", .{}, null);

    // A moment...
    const from_time = (try bundle.format(std.testing.allocator, "m", &.{
        .{ .name = "t", .value = .time(0) },
    }, null)).?;
    defer std.testing.allocator.free(from_time);
    try std.testing.expectEqualStrings("1970-01-01", from_time);

    // ...or a bare number, which is seconds since the epoch.
    const from_number = (try bundle.format(std.testing.allocator, "m", &.{
        .{ .name = "t", .value = .num(0) },
    }, null)).?;
    defer std.testing.allocator.free(from_number);
    try std.testing.expectEqualStrings("1970-01-01", from_number);
}

/// Seconds since the epoch as a millisecond count, for any float at all.
///
/// Clamping with `@min` and `@max` against the ends of `i64` is not enough,
/// and the reason is the same one that bit the plural evaluator: neither end
/// of `i64` survives the trip through `f64`. The largest rounds *up* to 2^63,
/// which is one past what an `i64` holds, so a value clamped to it still
/// panics on the way in. The comparison has to be against the powers of two
/// either side, and NaN has to be turned away before any of it, since every
/// comparison with NaN is false.
fn epochMilliFromSeconds(seconds: f64) i64 {
    if (std.math.isNan(seconds)) return 0;

    const milliseconds = seconds * std.time.ms_per_s;
    if (!(milliseconds > -9223372036854775808.0)) return std.math.minInt(i64);
    if (!(milliseconds < 9223372036854775808.0)) return std.math.maxInt(i64);
    return @intFromFloat(milliseconds);
}

test "a timestamp out of range clamps rather than panicking" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, 0), epochMilliFromSeconds(0));
    try testing.expectEqual(@as(i64, 1500), epochMilliFromSeconds(1.5));
    try testing.expectEqual(@as(i64, 0), epochMilliFromSeconds(std.math.nan(f64)));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), epochMilliFromSeconds(1e300));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), epochMilliFromSeconds(-1e300));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), epochMilliFromSeconds(std.math.inf(f64)));
    // The value `@floatFromInt(maxInt(i64))` rounds to, which is one past the
    // end and is what a naive clamp would hand to `@intFromFloat`.
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), epochMilliFromSeconds(9223372036854775808.0));
}

/// Read the options a `DATETIME()` call was written with.
fn datetimeOptions(call: Call) datetime_format.Options {
    const O = datetime_format.Options;
    var options: O = .{};

    options.date_style = call.enumOption(O.Style, "dateStyle");
    options.time_style = call.enumOption(O.Style, "timeStyle");
    options.weekday = call.enumOption(O.Width, "weekday");
    options.era = call.enumOption(O.Width, "era");
    options.year = call.enumOption(O.Numeric, "year");
    options.month = call.enumOption(O.MonthWidth, "month");
    options.day = call.enumOption(O.Numeric, "day");
    options.hour = call.enumOption(O.Numeric, "hour");
    options.minute = call.enumOption(O.Numeric, "minute");
    options.second = call.enumOption(O.Numeric, "second");
    options.day_period = call.enumOption(O.Width, "dayPeriod");
    options.time_zone_name = call.enumOption(O.TimeZoneName, "timeZoneName");

    if (call.numberOption("fractionalSecondDigits")) |v| {
        options.fractional_second_digits = @min(@as(u8, 3), clamp(v));
    }
    if (call.stringOption("hour12")) |text| {
        options.hour12 = std.mem.eql(u8, text, "true");
    }

    return options;
}
