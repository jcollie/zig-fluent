// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Rendering a moment the way a locale writes it.
//!
//! The calendar itself is not here. Dates, the proleptic Gregorian calendar
//! and the IANA timezone database are `zig-datetime`'s job, and it does the
//! whole of it: `Instant.fromMilliTimestamp` decodes a moment reliably either
//! side of 1970, which `std.time.epoch` cannot, and a `TimeZone` read from
//! TZif says what a clock in a given place actually read at a given instant --
//! which no amount of arithmetic can work out on its own.
//!
//! What is left for this file is the presentation: which fields to show, in
//! which order, with which names. That part belongs to Fluent rather than to a
//! calendar, because the vocabulary is ECMA-402's -- it is what `DATETIME()`
//! lets a translator write.
//!
//! ```ftl
//! due = Due { DATETIME($date, month: "long", day: "numeric") }
//! ```

const std = @import("std");

const datetime = @import("datetime");

const testing = std.testing;

pub const DateTime = datetime.DateTime;
pub const Instant = datetime.Instant;
pub const TimeZone = datetime.TimeZone;
pub const DayOfWeek = datetime.DayOfWeek;
pub const DayPeriodRule = datetime.cldr.DayPeriodRule;

/// Decompose a moment given as milliseconds since the Unix epoch, as UTC.
pub fn fromEpochMilli(epoch_ms: i64) DateTime {
    return Instant.fromMilliTimestamp(epoch_ms).asDateTime();
}

test fromEpochMilli {
    const epoch = fromEpochMilli(0);
    try testing.expectEqual(@as(datetime.Year, 1970), epoch.year);
    try testing.expectEqual(datetime.Month.Jan, epoch.month);

    // A moment before 1970, which `std.time.epoch` cannot represent at all.
    const before = fromEpochMilli(-1);
    try testing.expectEqual(@as(datetime.Year, 1969), before.year);
    try testing.expectEqual(datetime.Month.Dec, before.month);
    try testing.expectEqual(@as(datetime.Day, 31), before.day);
}

/// Decompose a moment as the wall clock read in `zone`.
pub fn fromEpochMilliIn(epoch_ms: i64, zone: TimeZone) DateTime {
    return zone.atInstant(Instant.fromMilliTimestamp(epoch_ms));
}

test fromEpochMilliIn {
    // What a clock in a given place actually read at an instant is a question
    // only the IANA database can answer; UTC is the one zone that needs none.
    try testing.expectEqual(@as(i32, 0), fromEpochMilli(0).offset);
}

/// How much of a date or time to show, and in what style.
///
/// The names and values are ECMA-402's, because they are what Fluent's
/// `DATETIME()` builtin lets a translator write:
///
/// ```ftl
/// due = Due { DATETIME($date, month: "long", day: "numeric") }
/// ```
pub const Options = struct {
    /// A whole preset date format. When set, the individual field options are
    /// ignored, which is what ECMA-402 specifies.
    date_style: ?Style = null,
    time_style: ?Style = null,

    weekday: ?Width = null,
    era: ?Width = null,
    year: ?Numeric = null,
    month: ?MonthWidth = null,
    day: ?Numeric = null,
    hour: ?Numeric = null,
    minute: ?Numeric = null,
    second: ?Numeric = null,
    fractional_second_digits: ?u8 = null,
    day_period: ?Width = null,

    /// Force a 12- or 24-hour clock, overriding what the locale prefers.
    hour12: ?bool = null,

    time_zone_name: ?TimeZoneName = null,
    /// The zone to read the clock in. Null means UTC.
    ///
    /// Borrowed: a zone is parsed from TZif once and used for the life of the
    /// program, so the bundle holds it and the options only point at it.
    time_zone: ?*const TimeZone = null,

    pub const Style = enum { full, long, medium, short };
    pub const Width = enum { narrow, short, long };
    pub const Numeric = enum { numeric, @"2-digit" };
    pub const MonthWidth = enum { numeric, @"2-digit", narrow, short, long };
    pub const TimeZoneName = enum { short, long, short_offset, long_offset };

    /// Whether any field at all was asked for.
    ///
    /// ECMA-402 falls back to year, month and day when nothing is requested,
    /// which is what makes a bare `DATETIME($d)` show a date rather than
    /// nothing.
    /// Whether any field at all was asked for.
    ///
    /// ECMA-402 falls back to year, month and day when nothing is requested,
    /// which is what makes a bare `DATETIME($d)` show a date rather than
    /// nothing.
    pub fn isEmpty(self: Options) bool {
        return self.date_style == null and self.time_style == null and
            self.weekday == null and self.era == null and self.year == null and
            self.month == null and self.day == null and self.hour == null and
            self.minute == null and self.second == null and
            self.fractional_second_digits == null and self.day_period == null and
            self.time_zone_name == null;
    }

    test isEmpty {
        try testing.expect((Options{}).isEmpty());
        try testing.expect(!(Options{ .year = .numeric }).isEmpty());
        try testing.expect(!(Options{ .date_style = .short }).isEmpty());
    }

    /// Layer `other`'s options over these, keeping every one it did not set.
    pub fn override(self: Options, other: Options) Options {
        var merged = self;
        inline for (@typeInfo(Options).@"struct".fields) |field| {
            if (@typeInfo(field.type) == .optional) {
                if (@field(other, field.name)) |v| @field(merged, field.name) = v;
            }
        }
        return merged;
    }

    test override {
        const base: Options = .{ .year = .numeric, .month = .long };
        const merged = base.override(.{ .day = .numeric });

        try testing.expectEqual(Numeric.numeric, merged.day.?);
        try testing.expectEqual(Numeric.numeric, merged.year.?);
        try testing.expectEqual(MonthWidth.long, merged.month.?);
    }
};

const default_digits = "0123456789";

/// The names and patterns one locale writes dates with.
///
/// This is CLDR's `ca-gregorian` data for a locale, reduced to what
/// `DATETIME()` can ask for. The defaults are CLDR's root locale, which is
/// what an unknown language falls back to and is deliberately ISO-like.
pub const Names = struct {
    /// January first.
    months_wide: [12][]const u8 = .{
        "M01", "M02", "M03", "M04", "M05", "M06",
        "M07", "M08", "M09", "M10", "M11", "M12",
    },
    months_abbreviated: [12][]const u8 = .{
        "M01", "M02", "M03", "M04", "M05", "M06",
        "M07", "M08", "M09", "M10", "M11", "M12",
    },
    months_narrow: [12][]const u8 = .{
        "1", "2", "3", "4",  "5",  "6",
        "7", "8", "9", "10", "11", "12",
    },
    /// The month named on its own rather than inside a date. Identical to the
    /// format names in most languages and different in the ones that inflect.
    months_standalone_wide: [12][]const u8 = .{
        "M01", "M02", "M03", "M04", "M05", "M06",
        "M07", "M08", "M09", "M10", "M11", "M12",
    },
    months_standalone_abbreviated: [12][]const u8 = .{
        "M01", "M02", "M03", "M04", "M05", "M06",
        "M07", "M08", "M09", "M10", "M11", "M12",
    },
    months_standalone_narrow: [12][]const u8 = .{
        "1", "2", "3", "4",  "5",  "6",
        "7", "8", "9", "10", "11", "12",
    },
    /// Sunday first, which is CLDR's order regardless of which day the locale
    /// considers the week to start on.
    weekdays_wide: [7][]const u8 = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    weekdays_abbreviated: [7][]const u8 = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    weekdays_narrow: [7][]const u8 = .{ "S", "M", "T", "W", "T", "F", "S" },
    /// The weekday named on its own. Finnish's format name is the essive
    /// "keskiviikkona" -- on Wednesday -- and its stand-alone name is the
    /// plain "keskiviikko"; which one a date wants is the pattern's to say.
    weekdays_standalone_wide: [7][]const u8 = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    weekdays_standalone_abbreviated: [7][]const u8 = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    weekdays_standalone_narrow: [7][]const u8 = .{ "S", "M", "T", "W", "T", "F", "S" },
    /// Before noon, then after.
    ///
    /// What `a` writes, and what `B` falls back to in a locale CLDR gives
    /// no flexible periods; see `day_periods_flexible`.
    day_periods: [2][]const u8 = .{ "AM", "PM" },

    /// CLDR's twelve day periods, at the three widths, for a locale that
    /// has rules for choosing between them.
    ///
    /// `B` is the flexible day period: where `a` knows only morning and
    /// afternoon, this divides the day as the language actually does, and
    /// which period an hour falls in is `day_period_rules`. Traditional
    /// Chinese writes 凌晨 before dawn, 上午 in the morning, 中午 around noon,
    /// 下午 in the afternoon and 晚上 in the evening, and its own short time
    /// pattern is `Bh:mm` -- so a locale without this writes 下午 at noon
    /// where ICU writes 中午.
    ///
    /// Null for the 344 locales CLDR gives no rules for, which can never
    /// reach any period but the meridiem and would carry thirty-six mostly
    /// empty slots for nothing. Indexed as `[width][period]`, in the order
    /// of `cldr.Width` and `cldr.DayPeriod`.
    day_periods_flexible: ?*const [3][12][]const u8 = null,

    /// When each of those periods runs. Empty where there are none.
    day_period_rules: []const DayPeriodRule = &.{},
    /// Before the common era, then within it.
    eras: [2][]const u8 = .{ "BCE", "CE" },
    eras_wide: [2][]const u8 = .{ "BCE", "CE" },
    /// The narrow era, which `GGGGG` writes. Several locales' own patterns
    /// ask for it -- French files `GyMEd` as `E dd/MM/y GGGGG` -- so leaving
    /// it out did not mean it went unasked for, it meant the wide name was
    /// written in its place: "après Jésus-Christ" where ICU says "ap. J.-C.".
    eras_narrow: [2][]const u8 = .{ "BCE", "CE" },

    /// The four preset date formats, longest first.
    date_formats: [4][]const u8 = .{ "y MMMM d, EEEE", "y MMMM d", "y MMM d", "y-MM-dd" },
    /// The four preset time formats, longest first.
    time_formats: [4][]const u8 = .{ "HH:mm:ss zzzz", "HH:mm:ss z", "HH:mm:ss", "HH:mm" },
    /// How a date and a time are joined, `{1}` being the date and `{0}` the
    /// time. Longest first, and often the same string four times.
    datetime_formats: [4][]const u8 = .{ "{1} {0}", "{1} {0}", "{1} {0}", "{1} {0}" },
    /// How a date is joined to a time it happened *at*, which several
    /// languages write as a small sentence: English's `{1} 'at' {0}`, German's
    /// `{1} 'um' {0}`. Used when a date style and a time style were both
    /// asked for.
    datetime_at_formats: [4][]const u8 = .{ "{1} {0}", "{1} {0}", "{1} {0}", "{1} {0}" },

    /// CLDR's `availableFormats`: a pattern for each combination of fields the
    /// locale has an opinion about, keyed by its skeleton.
    ///
    /// This is what makes `month: "long", day: "numeric"` come out as
    /// "September 9" in English and "9. September" in German. A skeleton names
    /// the fields; the locale decides their order and what goes between them,
    /// and nothing but its own data can supply that.
    available_formats: []const Available = &.{},

    /// How an offset from UTC is wrapped when a zone has no name to give:
    /// `GMT{0}` in English, `UTC{0}` in French, `{0} گرینویچ` in Persian,
    /// with `{0}` standing for the offset itself.
    gmt_format: []const u8 = "GMT{0}",
    /// What the locale writes for a zero offset with nothing after it.
    gmt_zero_format: []const u8 = "GMT",
    /// How the offset itself is written east of UTC, as a miniature pattern
    /// of `H`, `HH`, `mm` and `ss` with the sign as a literal.
    hour_format_positive: []const u8 = "+HH:mm",
    /// The same west of UTC. Held separately rather than derived, because
    /// the sign is not always a hyphen: French writes a real minus sign and
    /// Persian puts a bidirectional mark in front of it.
    hour_format_negative: []const u8 = "-HH:mm",

    /// Whether the locale writes the time on a twelve-hour clock.
    hour12: bool = false,

    /// The day a week begins on here, and how many days of January the first
    /// week of the year must hold. Together they are the whole of a week rule,
    /// which is what the `Y` field -- the year a *week* belongs to -- is
    /// counted against.
    ///
    /// CLDR keeps this per territory rather than per locale, so a tag without
    /// a region is resolved through `likelySubtags` first; the defaults are
    /// the root's, `001`. The two are separate from everything else in this
    /// struct in that they are supplemental data rather than the locale's own
    /// `ca-gregorian` file.
    first_day: DayOfWeek = .Mon,
    min_days_in_first_week: u8 = 1,

    /// A skeleton and the pattern it maps to.
    ///
    /// `zig-datetime`'s own type, so that a table generated here can be
    /// handed to `cldr.formatSkeleton` as it stands rather than copied into
    /// a structurally identical one on every call.
    pub const Available = datetime.cldr.AvailableFormat;
};

/// Everything needed to write a moment for one locale.
pub const Formatter = struct {
    names: Names = .{},
    options: Options = .{},
    /// The zone the clock is read in. Null means UTC.
    zone: ?*const TimeZone = null,
    /// The ten digits of the locale's numbering system, as one UTF-8 string.
    ///
    /// A date is full of numbers, and a locale that writes numbers in
    /// Arabic-Indic digits writes the day of the month in them too: Egyptian
    /// Arabic's ninth of September is `٩ سبتمبر ٢٠٢٦`, not `9 سبتمبر 2026`.
    digits: []const u8 = "0123456789",

    /// Write the moment `epoch_ms` the way this locale writes dates.
    ///
    /// The three cases are ECMA-402's, in the order it gives them. A
    /// `dateStyle` or `timeStyle` names one of the locale's four presets
    /// outright, and both together are joined by the locale's own "at time"
    /// pattern. A set of individual fields becomes a CLDR skeleton, which
    /// the locale's `availableFormats` turns into a pattern. And nothing at
    /// all means year, month and day, which is what a bare `DATETIME($d)`
    /// shows.
    ///
    /// The writing itself is `zig-datetime`'s: it owns the CLDR pattern
    /// vocabulary and checks its rendering against ICU, so this decides
    /// *what* to ask for and lets that decide how it is written. What is
    /// left here is the part that is Fluent's rather than a calendar's --
    /// turning `DATETIME()`'s options into a skeleton.
    pub fn format(self: Formatter, epoch_ms: i64, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const zone = self.options.time_zone orelse self.zone;
        const moment = if (zone) |z| fromEpochMilliIn(epoch_ms, z.*) else fromEpochMilli(epoch_ms);

        const tables: Tables = .init(self.names, self.digits);
        const locale = tables.locale(self.names);

        // A pattern that came out of CLDR is a pattern, and a `Names` a
        // consumer wrote by hand may not be. Neither is worth failing a
        // whole message for, so a bad one writes nothing rather than
        // propagating an error `DATETIME()` has no way to report.
        self.write(moment, locale, w) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => {},
        };
    }

    fn write(
        self: Formatter,
        moment: DateTime,
        locale: datetime.cldr.Locale,
        w: *std.Io.Writer,
    ) !void {
        const cldr = datetime.cldr;
        const o = self.options;

        if (o.date_style) |date| {
            if (o.time_style) |time| return cldr.formatDateTime(moment, style(date), style(time), locale, w);
            return cldr.formatDate(moment, style(date), locale, w);
        }
        if (o.time_style) |time| return cldr.formatTime(moment, style(time), locale, w);

        // ECMA-402 asks for the flexible day period only when `dayPeriod`
        // was, and `Intl` bears that out: Traditional Chinese files `hms` as
        // `Bh:mm:ss`, and asking for hour, minute and second gives 下午
        // 12:00:00 where asking for a `timeStyle` gives 中午 12:00:00. The
        // same pattern, written two ways, because the field path substitutes
        // the meridiem for `B` unless the caller said it wanted the period.
        //
        // Withholding the rules is that substitution: with nothing to say
        // which period an hour falls in, `B` falls back to writing am or pm,
        // which is what `a` would have written. The styled path above keeps
        // them, so `timeStyle` still says 中午.
        var flexible = locale;
        if (self.options.day_period == null) flexible.day_period_rules = &.{};

        // A `Names` with no `availableFormats` has nothing to match a
        // skeleton against -- the root's tables are like that, and so is one
        // a consumer wrote by hand -- so the locale's short date stands in.
        // It is what this did before the matching was `zig-datetime`'s, and
        // a date in the wrong order beats no date at all.
        if (locale.available_formats.len == 0) {
            return cldr.formatRuntime(moment, self.names.date_formats[3], flexible, w);
        }

        var buffer: [64]u8 = undefined;
        var skeleton = self.buildSkeleton(&buffer);
        // ECMA-402's default when nothing at all was asked for.
        if (skeleton.len == 0) skeleton = "yMd";

        return cldr.formatSkeleton(moment, skeleton, flexible, w);
    }

    /// `Options.Style` and `cldr.Length` are the same four lengths in the
    /// same order, named by two specifications that do not know about each
    /// other.
    fn style(value: Options.Style) datetime.cldr.Length {
        return @enumFromInt(@intFromEnum(value));
    }

    test format {
        var buffer: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);

        // A style names one of the locale's four presets outright. With no
        // locale data loaded these are root's, which are ISO-like.
        try (Formatter{ .options = .{ .date_style = .short } }).format(0, &w);
        try testing.expectEqualStrings("1970-01-01", w.buffered());

        // Individual fields are turned into a CLDR skeleton and matched
        // against the ones the locale lists, which is what puts them in the
        // order that locale writes them.
        const names: Names = .{ .available_formats = &.{
            .{ .skeleton = "Hm", .pattern = "HH:mm" },
        } };
        w = std.Io.Writer.fixed(&buffer);
        try (Formatter{
            .names = names,
            .options = .{ .hour = .@"2-digit", .minute = .@"2-digit" },
        }).format(0, &w);
        try testing.expectEqualStrings("00:00", w.buffered());
    }

    test "B writes the period the hour falls in, and only when asked" {
        // Traditional Chinese divides the day and files its short time as
        // `Bh:mm`, so noon is 中午 and the evening 晚上 where the meridiem
        // would say 下午 for both.
        const flexible: [3][12][]const u8 = @splat(.{
            "",
            "上午",
            "",
            "下午",
            "",
            "上午",
            "中午",
            "下午",
            "晚上",
            "",
            "凌晨",
            "",
        });
        const names: Names = .{
            .time_formats = .{ "Bh:mm", "Bh:mm", "Bh:mm", "Bh:mm" },
            .available_formats = &.{.{ .skeleton = "hm", .pattern = "Bh:mm" }},
            .day_periods = .{ "上午", "下午" },
            .day_periods_flexible = &flexible,
            .day_period_rules = &.{
                .{ .period = .night1, .from = 0, .before = 300 },
                .{ .period = .morning1, .from = 300, .before = 480 },
                .{ .period = .morning2, .from = 480, .before = 720 },
                .{ .period = .afternoon1, .from = 720, .before = 780 },
                .{ .period = .afternoon2, .from = 780, .before = 1140 },
                .{ .period = .evening1, .from = 1140, .before = 1440 },
            },
            .hour12 = true,
        };
        var buffer: [64]u8 = undefined;

        // A time style takes the locale's pattern as it stands, so `B` is
        // the period: noon is 中午 and 20:17 is 晚上.
        var noon = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .time_style = .short } }).format(43_200_000, &noon);
        try testing.expectEqualStrings("中午12:00", noon.buffered());

        var evening = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .time_style = .short } }).format(73_020_000, &evening);
        try testing.expectEqualStrings("晚上8:17", evening.buffered());

        // Asking for the fields instead is ECMA-402's other path, and there
        // `B` stands for the meridiem unless `dayPeriod` was asked for --
        // which is what `Intl` does with the very same pattern.
        var fields = std.Io.Writer.fixed(&buffer);
        try (Formatter{
            .names = names,
            .options = .{ .hour = .numeric, .minute = .numeric },
        }).format(43_200_000, &fields);
        try testing.expectEqualStrings("下午12:00", fields.buffered());

        // Unless it was.
        var asked = std.Io.Writer.fixed(&buffer);
        try (Formatter{
            .names = names,
            .options = .{ .hour = .numeric, .minute = .numeric, .day_period = .short },
        }).format(43_200_000, &asked);
        try testing.expectEqualStrings("中午12:00", asked.buffered());
    }

    test "the wrapper around a zone offset is the locale's own" {
        // French writes `UTC` where English writes `GMT`, and a real minus
        // sign where English writes a hyphen. Both are CLDR data rather than
        // anything this could work out.
        const names: Names = .{
            .time_formats = @splat("HH:mm zzzz"),
            .gmt_format = "UTC{0}",
            .gmt_zero_format = "UTC",
            .hour_format_positive = "+HH:mm",
            .hour_format_negative = "\u{2212}HH:mm",
        };
        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .time_style = .full } }).format(0, &w);
        try testing.expectEqualStrings("00:00 UTC+00:00", w.buffered());
    }

    test "a locale with no availableFormats still writes a date" {
        // Nothing to match against, so the short date stands in rather than
        // the field options producing an empty string.
        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .options = .{ .year = .numeric, .month = .long, .day = .numeric } }).format(0, &w);
        try testing.expectEqualStrings("1970-01-01", w.buffered());
    }

    test "an abbreviated weekday is a single E in a skeleton key" {
        // CLDR files both `yMMMEd` and `yMMMEEEEd`, and they are not the same
        // pattern with a different weekday in it: Japanese parenthesises the
        // weekday in the first and not the second. Asking for an abbreviated
        // weekday has to build `E` to match the first, because `EEE` matches
        // neither and the nearest entry by score is the wide one.
        const names: Names = .{ .available_formats = &.{
            .{ .skeleton = "yMMMEd", .pattern = "y-M-d(E)" },
            .{ .skeleton = "yMMMEEEEd", .pattern = "y-M-d EEEE" },
        } };
        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try (Formatter{
            .names = names,
            .options = .{ .year = .numeric, .month = .short, .day = .numeric, .weekday = .short },
        }).format(0, &w);
        try testing.expectEqualStrings("1970-1-1(Thu)", w.buffered());

        // And a wide one still reaches the other entry.
        w = std.Io.Writer.fixed(&buffer);
        try (Formatter{
            .names = names,
            .options = .{ .year = .numeric, .month = .short, .day = .numeric, .weekday = .long },
        }).format(0, &w);
        try testing.expectEqualStrings("1970-1-1 Thu", w.buffered());
    }

    test "the era takes the width that was asked for" {
        // CLDR spells the era `G` in every `availableFormats` key while the
        // patterns behind them use `G`, `GGGG` and `GGGGG`, so the key can
        // never disagree with the request and the pattern's own width would
        // otherwise always win. Russian files `yMEd`-with-an-era as a narrow
        // `GGGGG`; a request for a short era has to widen it.
        const names: Names = .{
            .available_formats = &.{.{ .skeleton = "Gy", .pattern = "y GGGGG" }},
            .eras = .{ "BCE", "n. e." },
            .eras_wide = .{ "Before Common Era", "Common Era" },
            .eras_narrow = .{ "B", "n.e." },
        };
        var buffer: [64]u8 = undefined;

        var w = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .era = .short, .year = .numeric } }).format(0, &w);
        try testing.expectEqualStrings("1970 n. e.", w.buffered());

        w = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .era = .long, .year = .numeric } }).format(0, &w);
        try testing.expectEqualStrings("1970 Common Era", w.buffered());

        w = std.Io.Writer.fixed(&buffer);
        try (Formatter{ .names = names, .options = .{ .era = .narrow, .year = .numeric } }).format(0, &w);
        try testing.expectEqualStrings("1970 n.e.", w.buffered());
    }

    test "Y is the week's year, not the calendar year" {
        // `ksh` files `Y-MM` under the `yM` skeleton, and Cologne keeps the
        // ISO week rule: a week begins on Monday and week 1 is the one holding
        // January 4th.
        const names: Names = .{
            .available_formats = &.{.{ .skeleton = "yM", .pattern = "Y-MM" }},
            .first_day = .Mon,
            .min_days_in_first_week = 4,
        };
        const formatter: Formatter = .{
            .names = names,
            .options = .{ .year = .numeric, .month = .numeric },
        };

        var buffer: [64]u8 = undefined;

        // 2024-12-30 is a Monday, and under that rule it opens week 1 of 2025 --
        // so the week's year is 2025 while the calendar's is still 2024.
        var w = std.Io.Writer.fixed(&buffer);
        try formatter.format(1_735_560_000_000, &w);
        try testing.expectEqualStrings("2025-12", w.buffered());

        // 2023-01-01 is a Sunday, the last day of week 52 of 2022, and the
        // year runs the other way.
        w = std.Io.Writer.fixed(&buffer);
        try formatter.format(1_672_560_000_000, &w);
        try testing.expectEqualStrings("2022-01", w.buffered());

        // The rule is read rather than assumed: the same instant under the
        // American rule -- weeks begin on Sunday, week 1 holds January 1st --
        // falls in week 1 of 2023 instead.
        const american: Formatter = .{
            .names = .{
                .available_formats = names.available_formats,
                .first_day = .Sun,
                .min_days_in_first_week = 1,
            },
            .options = formatter.options,
        };
        w = std.Io.Writer.fixed(&buffer);
        try american.format(1_672_560_000_000, &w);
        try testing.expectEqualStrings("2023-01", w.buffered());
    }

    fn buildSkeleton(self: Formatter, buffer: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buffer);
        const o = self.options;

        if (o.era) |width| w.splatByteAll('G', switch (width) {
            .narrow => 5,
            .short => 1,
            .long => 4,
        }) catch {};
        if (o.year) |width| w.splatByteAll('y', if (width == .@"2-digit") 2 else 1) catch {};
        if (o.month) |width| w.splatByteAll('M', switch (width) {
            .numeric => 1,
            .@"2-digit" => 2,
            .short => 3,
            .long => 4,
            .narrow => 5,
        }) catch {};
        // CLDR spells an abbreviated weekday as a *single* `E` in a skeleton
        // key -- `yMMMEd` -- and the wide one as four. Writing three here
        // matched neither, so the scorer fell through to the nearest entry it
        // could find, which for Japanese and Korean is the wide-weekday one:
        // `yMMMEEEEd` is filed as `y年M月d日EEEE`, where `yMMMEd` is
        // `y年M月d日(E)`, and the parentheses went missing along with the
        // exact match. `E`, `EE` and `EEE` are all the abbreviated name, so
        // the rendered width is unchanged either way; only the key differs.
        if (o.weekday) |width| w.splatByteAll('E', switch (width) {
            .narrow => 5,
            .short => 1,
            .long => 4,
        }) catch {};
        if (o.day) |width| w.splatByteAll('d', if (width == .@"2-digit") 2 else 1) catch {};
        if (o.hour) |width| {
            const twelve = o.hour12 orelse self.names.hour12;
            w.splatByteAll(if (twelve) 'h' else 'H', if (width == .@"2-digit") 2 else 1) catch {};
        }
        if (o.minute) |width| w.splatByteAll('m', if (width == .@"2-digit") 2 else 1) catch {};
        if (o.second) |width| w.splatByteAll('s', if (width == .@"2-digit") 2 else 1) catch {};
        if (o.fractional_second_digits) |digits| w.splatByteAll('S', digits) catch {};

        return w.buffered();
    }

    /// The tables a `datetime.cldr.Locale` points at.
    ///
    /// zig-datetime holds its name tables width-major -- one `[3][12]` of
    /// months rather than three `[12]`s -- and `Names` holds them the other
    /// way round, so a `Locale` cannot simply borrow them. They are built
    /// here, on the stack of whatever call is formatting, which is what
    /// keeps `Names` the shape a consumer overrides it in.
    const Tables = struct {
        months: [3][12][]const u8,
        months_standalone: [3][12][]const u8,
        weekdays: [4][7][]const u8,
        weekdays_standalone: [4][7][]const u8,
        day_periods: [3][12][]const u8,
        eras: [3][2][]const u8,
        digits: [10][]const u8,

        /// Quarters and the flexible day periods are fields no `DATETIME()`
        /// option can ask for and no pattern under `src/cldr/` writes --
        /// checked across all 1383 of them. A `Locale` still has to have
        /// them, so every locale here shares this one rather than carrying
        /// 766 copies of the same nothing.
        const unused_quarters: [3][4][]const u8 = @splat(@splat(""));

        fn init(names: Names, digits: []const u8) Tables {
            var self: Tables = undefined;

            // Width-major, in CLDR's order: wide, abbreviated, narrow.
            self.months = .{ names.months_wide, names.months_abbreviated, names.months_narrow };
            self.months_standalone = .{
                names.months_standalone_wide,
                names.months_standalone_abbreviated,
                names.months_standalone_narrow,
            };

            // Weekdays have a fourth width between the abbreviated and the
            // narrow one -- English's "Tu" -- which `Names` does not carry
            // and no `DATETIME()` option asks for. The abbreviated name
            // stands in, which is what CLDR's own generator does for a
            // locale that leaves it out.
            self.weekdays = .{
                names.weekdays_wide,
                names.weekdays_abbreviated,
                names.weekdays_abbreviated,
                names.weekdays_narrow,
            };
            self.weekdays_standalone = .{
                names.weekdays_standalone_wide,
                names.weekdays_standalone_abbreviated,
                names.weekdays_standalone_abbreviated,
                names.weekdays_standalone_narrow,
            };

            // `DayPeriod` numbers am 1 and pm 3, with midnight, noon and the
            // eight flexible periods around them. A locale that has the whole
            // table points at it instead of building this one; see `locale`.
            var periods: [12][]const u8 = @splat("");
            periods[1] = names.day_periods[0];
            periods[3] = names.day_periods[1];
            self.day_periods = .{ periods, periods, periods };

            self.eras = .{ names.eras_wide, names.eras, names.eras_narrow };

            // `Names` keeps the numbering system as one UTF-8 string of ten
            // codepoints, which is how CLDR writes it; a `Locale` wants ten
            // slices.
            self.digits = @splat("");
            var it: std.unicode.Utf8Iterator = .{ .bytes = digits, .i = 0 };
            for (&self.digits) |*slot| slot.* = it.nextCodepointSlice() orelse "";

            return self;
        }

        fn locale(self: *const Tables, names: Names) datetime.cldr.Locale {
            return .{
                .tag = "",
                .months = &self.months,
                .months_stand_alone = &self.months_standalone,
                .weekdays = &self.weekdays,
                .weekdays_stand_alone = &self.weekdays_standalone,
                .quarters = &unused_quarters,
                // CLDR's own table where there is one, so that `B` writes the
                // period the hour actually falls in; the meridiem in the two
                // slots it knows otherwise.
                .day_periods = names.day_periods_flexible orelse &self.day_periods,
                .day_period_rules = names.day_period_rules,
                .eras = &self.eras,
                .date_formats = &names.date_formats,
                .time_formats = &names.time_formats,
                .date_time_formats = &names.datetime_formats,
                .date_time_at_time_formats = &names.datetime_at_formats,
                .available_formats = names.available_formats,
                .gmt_format = names.gmt_format,
                .gmt_zero_format = names.gmt_zero_format,
                .hour_format_positive = names.hour_format_positive,
                .hour_format_negative = names.hour_format_negative,
                .first_day = names.first_day,
                .min_days_in_first_week = names.min_days_in_first_week,
                .digits = if (std.mem.eql(u8, self.digits[0], "0")) null else &self.digits,
            };
        }
    };
};

// -- tests -------------------------------------------------------------------
