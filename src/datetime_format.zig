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
    day_periods: [2][]const u8 = .{ "AM", "PM" },
    /// Before the common era, then within it.
    eras: [2][]const u8 = .{ "BCE", "CE" },
    eras_wide: [2][]const u8 = .{ "BCE", "CE" },

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

    /// Whether the locale writes the time on a twelve-hour clock.
    hour12: bool = false,

    pub const Available = struct {
        /// The field letters, in CLDR's canonical order, e.g. `"MMMMd"`.
        skeleton: []const u8,
        pattern: []const u8,
    };
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
    pub fn format(self: Formatter, epoch_ms: i64, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const zone = self.options.time_zone orelse self.zone;
        const moment = if (zone) |z| fromEpochMilliIn(epoch_ms, z.*) else fromEpochMilli(epoch_ms);

        var glue_buffer: [192]u8 = undefined;
        var adjust_buffer: [192]u8 = undefined;
        const pattern = self.choosePattern(&glue_buffer, &adjust_buffer);
        try self.writePattern(pattern, moment, w);
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

    /// Work out which CLDR pattern to use for the options in force.
    ///
    /// Three cases, in the order ECMA-402 gives them. A `dateStyle` or
    /// `timeStyle` names one of the locale's four presets outright. A set of
    /// individual fields is turned into a skeleton and matched against the
    /// locale's `availableFormats`. And nothing at all means year, month and
    /// day, which is what a bare `DATETIME($d)` shows.
    fn choosePattern(self: Formatter, glue_buffer: []u8, adjust_buffer: []u8) []const u8 {
        if (self.options.date_style != null or self.options.time_style != null) {
            return self.chooseStyledPattern(glue_buffer);
        }

        var skeleton_buffer: [64]u8 = undefined;
        var skeleton = self.buildSkeleton(&skeleton_buffer);
        // ECMA-402's default when nothing at all was asked for: the year, the
        // month and the day, each numeric. It is what makes a bare
        // `DATETIME($d)` show a date rather than nothing.
        if (skeleton.len == 0) skeleton = "yMd";

        const matched = self.matchSkeleton(skeleton);
        return adjustWidths(matched.pattern, matched.skeleton, skeleton, adjust_buffer);
    }

    /// Join the locale's preset date and time formats, or take whichever of the two was asked for on its own.
    fn chooseStyledPattern(self: Formatter, buffer: []u8) []const u8 {
        const date = if (self.options.date_style) |style| self.names.date_formats[@intFromEnum(style)] else null;
        const time = if (self.options.time_style) |style| self.names.time_formats[@intFromEnum(style)] else null;

        if (date != null and time == null) return date.?;
        if (time != null and date == null) return time.?;

        // Both: the locale says how they are joined, and the glue is chosen by
        // the *date* style, which is what ECMA-402 specifies. It is the "at
        // time" form, because asking for a date style and a time style
        // together is asking when something happened.
        const glue = self.names.datetime_at_formats[@intFromEnum(self.options.date_style.?)];
        var w = std.Io.Writer.fixed(buffer);
        var rest = glue;
        while (std.mem.indexOfScalar(u8, rest, '{')) |at| {
            w.writeAll(rest[0..at]) catch return date.?;

            // `{1}` is the date and `{0}` the time. A brace that does not
            // begin a complete placeholder is literal text: CLDR's own glue
            // never has one, but a `Names` supplied by a consumer is arbitrary
            // and a glue ending in `{` would otherwise be read past the end.
            if (at + 2 >= rest.len or rest[at + 2] != '}') {
                w.writeByte('{') catch return date.?;
                rest = rest[at + 1 ..];
                continue;
            }

            w.writeAll(if (rest[at + 1] == '1') date.? else time.?) catch return date.?;
            rest = rest[at + 3 ..];
        }
        w.writeAll(rest) catch return date.?;
        return w.buffered();
    }

    /// Turn the requested fields into a CLDR skeleton.
    ///
    /// The letters and their counts are CLDR's: a numeric month is `M`, a
    /// two-digit one `MM`, an abbreviated name `MMM`, a full name `MMMM`. The
    /// order is CLDR's canonical field order, because that is the order the
    /// `availableFormats` keys are written in and the match is on the text.
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
        if (o.weekday) |width| w.splatByteAll('E', switch (width) {
            .narrow => 5,
            .short => 3,
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

    /// Find the locale's pattern for a skeleton, or the closest thing to it.
    ///
    /// An exact match is what usually happens, since CLDR lists the
    /// combinations people actually ask for. Failing that, the best match is
    /// the one sharing the most field letters, so asking for a long month and
    /// a day in a locale that only lists `MMMd` gets that rather than nothing.
    fn matchSkeleton(self: Formatter, skeleton: []const u8) Names.Available {
        var best: ?Names.Available = null;
        var best_score: isize = -1;

        for (self.names.available_formats) |available| {
            if (std.mem.eql(u8, available.skeleton, skeleton)) return available;

            var score: isize = 0;
            for ("GyMEdhHmsSa") |letter| {
                const wanted = std.mem.count(u8, skeleton, &.{letter});
                const has = std.mem.count(u8, available.skeleton, &.{letter});
                if (wanted == 0 and has == 0) continue;

                // Having the field at all is most of the battle.
                if (wanted == 0 or has == 0) {
                    score -= 16;
                    continue;
                }
                score += 16;

                // Then how nearly the widths agree -- but crossing between a
                // number and a name is a far bigger difference than one digit,
                // and has to cost more. Without that, German scores `yMMdd`
                // ("dd.MM.y") and `yMMMd` ("d. MMM y") equally for a request
                // wanting a named month, and picks whichever comes first.
                const wanted_is_text = wanted >= 3;
                const has_is_text = has >= 3;
                if (wanted_is_text != has_is_text) {
                    score -= 8;
                } else {
                    score -= @intCast(@max(wanted, has) - @min(wanted, has));
                }
            }
            if (score > best_score) {
                best_score = score;
                best = available;
            }
        }

        return best orelse .{ .skeleton = skeleton, .pattern = self.names.date_formats[3] };
    }

    /// Widen or narrow the fields of a matched pattern to what was asked for.
    ///
    /// The rule is not "make the pattern match the request", which sounds
    /// right and is wrong. It is: **for each field, if the request asks for a
    /// different width than the matched entry was filed under, use the
    /// requested width; otherwise leave the pattern exactly as the locale
    /// wrote it.**
    ///
    /// The difference is the entry's declared skeleton -- the key CLDR filed
    /// the pattern under -- rather than the widths in the pattern itself, and
    /// it matters because the two often disagree on purpose:
    ///
    ///   - Japanese files `y年M月d日` under `yMMMd`. The key says "an
    ///     abbreviated month"; the pattern writes it as a numeral followed by
    ///     月, because that *is* the abbreviated month in Japanese. A request
    ///     for `MMM` agrees with the key, so the pattern is left alone.
    ///     Rewriting its `M` as `MMM` would look up the month name and produce
    ///     "9月月".
    ///   - Czech files `d. M. y` under `yMMMd` for the same reason.
    ///   - French files `d MMM y` under `yMMMd`, and a request for a two-digit
    ///     day disagrees with the key's `d`, so the day is widened and the
    ///     month is not: "09 sept. 2026".
    ///
    /// This is what ICU does, and so what `Intl` gives.
    fn adjustWidths(
        pattern: []const u8,
        matched: []const u8,
        skeleton: []const u8,
        buffer: []u8,
    ) []const u8 {
        var w = std.Io.Writer.fixed(buffer);

        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];

            // Quoted runs are literal text and hold no fields.
            if (c == '\'') {
                const start = i;
                i += 1;
                if (i < pattern.len and pattern[i] == '\'') {
                    i += 1;
                } else {
                    while (i < pattern.len and pattern[i] != '\'') i += 1;
                    if (i < pattern.len) i += 1;
                }
                w.writeAll(pattern[start..i]) catch return pattern;
                continue;
            }

            if (!std.ascii.isAlphabetic(c)) {
                w.writeByte(c) catch return pattern;
                i += 1;
                continue;
            }

            var count: usize = 0;
            while (i + count < pattern.len and pattern[i + count] == c) count += 1;
            i += count;

            // `c` and `e` are other spellings of the weekday field, and a
            // skeleton always spells it `E`.
            const field = if (c == 'c' or c == 'e') 'E' else c;
            const requested = std.mem.count(u8, skeleton, &.{field});
            const declared = std.mem.count(u8, matched, &.{field});

            // The month is the one field that is a number at one width and a
            // name at another, and the two are never interchangeable. Japanese
            // files `y年M月d日` under `yMMMd`: the key calls the month
            // abbreviated, and in Japanese the abbreviated month *is* the
            // numeral with 月 after it. Turning that `M` into `MMMM` because a
            // long month was asked for looks up the name and writes "9月月".
            const crosses_kind = (field == 'M' or field == 'L') and
                (count >= 3) != (requested >= 3);

            const adjust = requested != 0 and requested != declared and !crosses_kind;
            w.splatByteAll(c, if (adjust) requested else count) catch return pattern;
        }

        return w.buffered();
    }

    /// Render a CLDR date pattern.
    ///
    /// The letters are UTS #35's date field symbols, repeated to say how wide
    /// the field should be. Text between single quotes is literal, and `''`
    /// is a literal quote -- which is why a pattern cannot simply be copied
    /// through looking for letters.
    fn writePattern(
        self: Formatter,
        pattern: []const u8,
        moment: DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];

            if (c == '\'') {
                i += 1;
                if (i < pattern.len and pattern[i] == '\'') {
                    try w.writeByte('\'');
                    i += 1;
                    continue;
                }
                while (i < pattern.len and pattern[i] != '\'') : (i += 1) try w.writeByte(pattern[i]);
                if (i < pattern.len) i += 1;
                continue;
            }

            if (!std.ascii.isAlphabetic(c)) {
                try w.writeByte(c);
                i += 1;
                continue;
            }

            var count: usize = 0;
            while (i + count < pattern.len and pattern[i + count] == c) count += 1;
            i += count;

            try self.writeField(c, count, moment, w);
        }
    }

    /// Write one field of a pattern, given its letter and how many were written.
    fn writeField(
        self: Formatter,
        letter: u8,
        count: usize,
        moment: DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (letter) {
            'G' => {
                const era: usize = if (moment.year > 0) 1 else 0;
                try w.writeAll(if (count >= 4) self.names.eras_wide[era] else self.names.eras[era]);
            },
            'y', 'u' => {
                // A year is written within its era, never as a negative
                // number. Astronomical year 0 *is* 1 BC and -1 is 2 BC, so the
                // era-relative year below the common era is `1 - y`; checked
                // against `Intl`, which writes those two as "1 BC" and "2 BC".
                //
                // Widened to `i64` first, because `1 - y` overflows an `i32`
                // at the bottom of the range and a date is decoded from a
                // timestamp that a caller chose.
                const astronomical: i64 = moment.year;
                const year: u64 = @abs(if (astronomical <= 0) 1 - astronomical else astronomical);
                if (count == 2) {
                    try self.writePadded(w, year % 100, 2);
                } else {
                    try self.writePadded(w, year, count);
                }
            },
            'M', 'L' => try self.writeMonth(letter == 'L', count, moment, w),
            'd' => try self.writePadded(w, moment.day, count),
            'D' => try self.writePadded(w, moment.dayOfThisYear(), count),
            'E', 'e', 'c' => try self.writeWeekday(letter, count, moment, w),
            // `a` is am/pm, `b` adds noon and midnight, and `B` is the
            // locale's flexible period -- morning, afternoon, evening, night.
            // All three are written with the am/pm names: several East Asian
            // locales write their short time with `B`, and the two names CLDR
            // gives for those hours are the ones it would use.
            'a', 'b', 'B' => {
                const half: usize = if (moment.hour < 12) 0 else 1;
                try w.writeAll(self.names.day_periods[half]);
            },
            'h' => {
                const hour = moment.hour % 12;
                try self.writePadded(w, if (hour == 0) 12 else hour, count);
            },
            'H' => try self.writePadded(w, moment.hour, count),
            'K' => try self.writePadded(w, moment.hour % 12, count),
            'k' => try self.writePadded(w, if (moment.hour == 0) 24 else moment.hour, count),
            'm' => try self.writePadded(w, moment.minute, count),
            's' => try self.writePadded(w, moment.second, count),
            'S' => {
                // Fractions of a second, truncated to the width asked for.
                //
                // A nanosecond is nine digits and there is no tenth: past that
                // the answer is zeros, and dividing to find them is a division
                // by zero. A pattern may ask for more -- patterns are data,
                // and `Options.fractional_second_digits` is a `u8` -- so the
                // bound is checked rather than assumed. A fuzz seed found it.
                var scale: u64 = 1_000_000_000;
                const value: u64 = moment.nanosecond;
                for (0..count) |_| {
                    if (scale == 0) {
                        try self.writeDigit(w, '0');
                        continue;
                    }
                    scale /= 10;
                    const digit: u8 = if (scale == 0) 0 else @intCast((value / scale) % 10);
                    try self.writeDigit(w, '0' + digit);
                }
            },
            'z', 'Z', 'O', 'v', 'V', 'x', 'X' => try self.writeZone(letter, count, moment, w),
            else => {},
        }
    }

    /// Write the month as a number or as one of its three names.
    fn writeMonth(
        self: Formatter,
        standalone: bool,
        count: usize,
        moment: DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const index: usize = @as(usize, moment.month.as(u8)) - 1;
        switch (count) {
            1, 2 => try self.writePadded(w, moment.month.as(u8), count),
            3 => try w.writeAll(if (standalone)
                self.names.months_standalone_abbreviated[index]
            else
                self.names.months_abbreviated[index]),
            4 => try w.writeAll(if (standalone)
                self.names.months_standalone_wide[index]
            else
                self.names.months_wide[index]),
            else => try w.writeAll(if (standalone)
                self.names.months_standalone_narrow[index]
            else
                self.names.months_narrow[index]),
        }
    }

    /// Write the weekday, in its format or its stand-alone form.
    fn writeWeekday(
        self: Formatter,
        letter: u8,
        count: usize,
        moment: DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const index: usize = @intFromEnum(moment.weekday);
        // `e` and `c` in their one- and two-letter forms are the day's number
        // within the week rather than its name.
        if (letter != 'E' and count <= 2) return self.writePadded(w, index + 1, count);

        // `c` is the stand-alone weekday; `E` and `e` are the format one.
        const standalone = letter == 'c';
        switch (count) {
            5 => try w.writeAll(if (standalone)
                self.names.weekdays_standalone_narrow[index]
            else
                self.names.weekdays_narrow[index]),
            4 => try w.writeAll(if (standalone)
                self.names.weekdays_standalone_wide[index]
            else
                self.names.weekdays_wide[index]),
            else => try w.writeAll(if (standalone)
                self.names.weekdays_standalone_abbreviated[index]
            else
                self.names.weekdays_abbreviated[index]),
        }
    }

    /// Write the zone as an offset from UTC.
    ///
    /// Only the offset forms are produced, whatever was asked for. The names --
    /// "Central European Summer Time", "CEST" -- are a per-locale table as
    /// large as everything else here put together, and an offset is never
    /// wrong, only less friendly.
    fn writeZone(
        self: Formatter,
        letter: u8,
        count: usize,
        moment: DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // A `Designation` is what the zone calls itself at this instant, and
        // only a real timezone can say. When there is one, it is better than
        // an offset.
        if ((letter == 'z' or letter == 'v') and count <= 3) {
            const designation = moment.designation.slice();
            if (designation.len != 0) return w.writeAll(designation);
        }

        const total_minutes = @divTrunc(moment.offset, 60);
        if (total_minutes == 0 and (letter == 'X' or letter == 'x')) {
            return w.writeAll("Z");
        }

        if (letter == 'z' or letter == 'O' or letter == 'v' or letter == 'V') try w.writeAll("GMT");

        try w.writeByte(if (total_minutes < 0) '-' else '+');
        const magnitude: u32 = @abs(total_minutes);
        try self.writePadded(w, magnitude / 60, 2);
        try w.writeByte(':');
        try self.writePadded(w, magnitude % 60, 2);
    }

    /// Write a number to at least `width` digits, in the locale's numbering
    /// system.
    fn writePadded(self: Formatter, w: *std.Io.Writer, value: anytype, width: usize) std.Io.Writer.Error!void {
        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
        if (text.len < width) for (0..width - text.len) |_| try self.writeDigit(w, '0');
        for (text) |digit| try self.writeDigit(w, digit);
    }

    /// Write one ASCII digit in the locale's numbering system.
    fn writeDigit(self: Formatter, w: *std.Io.Writer, digit: u8) std.Io.Writer.Error!void {
        if (self.digits.ptr == default_digits.ptr) return w.writeByte(digit);

        var it = std.unicode.Utf8Iterator{ .bytes = self.digits, .i = 0 };
        var wanted = digit -% '0';
        while (it.nextCodepointSlice()) |slice| {
            if (wanted == 0) return w.writeAll(slice);
            wanted -= 1;
        }
        try w.writeByte(digit);
    }
};

// -- tests -------------------------------------------------------------------
