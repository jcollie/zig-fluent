// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What a placeable resolves to, and what an application passes in.
//!
//! Fluent's type system is small on purpose. A translation can be given text,
//! a number or a moment in time, and that is all -- because everything a
//! translator can do with a value is print it or select on it, and richer
//! types would only be things they could not inspect. An application with
//! something more elaborate to show formats it first and passes the text.
//!
//! A number and a date each carry their formatting options along with them, so
//! that an application can hand in a value that already knows it is a currency
//! amount, and a translator can still adjust it:
//!
//! ```ftl
//! total = You paid { NUMBER($amount, maximumFractionDigits: 0) }.
//! ```
//!
//! The options in the call are layered over the ones the value arrived with,
//! rather than replacing them, so the amount stays a currency amount.

const std = @import("std");

const datetime_format = @import("datetime_format.zig");
const number_format = @import("number_format.zig");
const plural = @import("plural.zig");

pub const Value = union(enum) {
    string: []const u8,
    number: Number,
    datetime: DateTime,
    /// A value that could not be resolved.
    ///
    /// It is not an error state so much as a placeholder that prints as
    /// something recognizable: a missing `$name` shows as `{$name}`, so the
    /// sentence around it survives and the gap is obvious to whoever sees it.
    /// The text here is the label, without the braces.
    none: []const u8,

    /// A number with no formatting options of its own.
    pub fn num(value: f64) Value {
        return .{ .number = .{ .value = value } };
    }

    test num {
        const three = Value.num(3);
        try testing.expectEqual(@as(f64, 3), three.number.value);
        // No options, so the bundle's locale decides everything about how it
        // is written.
        try testing.expectEqual(@as(?u8, null), three.number.options.maximum_fraction_digits);
    }

    /// A number from whatever integer or float type the caller has.
    pub fn of(value: anytype) Value {
        return switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => .{ .number = .{ .value = @floatFromInt(value) } },
            .float, .comptime_float => .{ .number = .{ .value = value } },
            else => @compileError("no Fluent value for " ++ @typeName(@TypeOf(value))),
        };
    }

    test of {
        // Saves writing `@floatFromInt` at the call site, which is where the
        // count usually comes from.
        try testing.expectEqual(@as(f64, 3), Value.of(@as(usize, 3)).number.value);
        try testing.expectEqual(@as(f64, -7), Value.of(@as(i64, -7)).number.value);
        try testing.expectEqual(@as(f64, 1.5), Value.of(@as(f32, 1.5)).number.value);
    }

    /// A moment, as milliseconds since the Unix epoch.
    pub fn time(epoch_ms: i64) Value {
        return .{ .datetime = .{ .epoch_ms = epoch_ms } };
    }

    test time {
        try testing.expectEqual(@as(i64, 0), Value.time(0).datetime.epoch_ms);
        // Before 1970 is ordinary, which is more than `std.time.epoch` can say.
        try testing.expectEqual(@as(i64, -1), Value.time(-1).datetime.epoch_ms);
    }
};

pub const Number = struct {
    value: f64,
    options: number_format.Options = .{},
    /// Whether a select expression on this number counts it or ranks it.
    ///
    /// Cardinal by default, which is what counting things means and what a
    /// translator writing `[one]` almost always intends. An application with
    /// a position rather than a quantity sets this to `.ordinal`, and the same
    /// `[one] [two] [few] *[other]` then means 1st, 2nd, 3rd and 4th.
    ///
    /// It is deliberately not reachable from FTL. `NUMBER()`'s option list is
    /// the reference implementation's, and it has no entry for this, so a
    /// translation file written here behaves identically under `fluent.js`.
    /// Whether a number is a count or a rank is a fact about the data, and the
    /// application is the one that knows it.
    plural_kind: plural.Kind = .cardinal,
};

pub const DateTime = struct {
    /// Milliseconds since 1970-01-01T00:00:00Z.
    epoch_ms: i64,
    options: datetime_format.Options = .{},
};

/// One named value passed to a message, or one named option passed to a call.
pub const Argument = struct {
    name: []const u8,
    value: Value,
};

/// The arguments a message is formatted with.
///
/// A slice rather than a map: a message takes a handful of arguments at most,
/// a linear scan over three entries beats hashing them, and a slice can be
/// written as a literal at the call site with no allocator involved.
pub const Args = []const Argument;

/// The argument called `name`, or null if it was not passed.
///
/// A linear scan, which is the right shape here: a message takes a handful of
/// arguments at most, and three comparisons beat hashing them.
pub fn find(args: Args, name: []const u8) ?Value {
    for (args) |argument| {
        if (std.mem.eql(u8, argument.name, name)) return argument.value;
    }
    return null;
}

test find {
    const args: Args = &.{
        .{ .name = "count", .value = .num(3) },
        .{ .name = "user", .value = .{ .string = "Ada" } },
    };
    try testing.expectEqual(@as(f64, 3), find(args, "count").?.number.value);
    try testing.expectEqualStrings("Ada", find(args, "user").?.string);
    try testing.expectEqual(@as(?Value, null), find(args, "missing"));
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "a number keeps the options it was built with" {
    const value: Value = .{ .number = .{
        .value = 12.5,
        .options = .{ .style = .currency, .currency = "EUR" },
    } };
    try testing.expectEqual(number_format.Style.currency, value.number.options.style);
}
