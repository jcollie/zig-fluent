// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The C API: this library as `libfluent.a`, `libfluent.so` and `fluent.h`.
//!
//! `include/fluent.h` is the documentation a C programmer reads and the
//! contract this file has to keep; what is here is the translation between
//! that contract and the Zig one, and nothing else. Two rules make the
//! translation safe, and both are load-bearing:
//!
//!  1. **Nothing crosses the boundary that C did not ask for.** Every
//!     allocation this file hands out is NUL-terminated and freed by
//!     `fluent_string_free`, every handle is opaque, and an argument list owns
//!     copies of everything put into it. A C caller can free its own buffers
//!     the moment a call returns.
//!  2. **No error reaches C as a trap.** Zig's error unions become NULL, false
//!     or zero, chosen so that the failure a caller is most likely to hit --
//!     an unparseable tag, a missing message -- is a value rather than
//!     something to check separately. The only error any of this can return is
//!     `error.OutOfMemory`, and where it is indistinguishable from a
//!     legitimate answer the header says which other call tells them apart.
//!
//! The handles are `opaque` types rather than `*anyopaque` so that the
//! generated signatures are typed on both sides of the boundary, and the casts
//! back into real Zig structs happen in one place each.

const builtin = @import("builtin");
const std = @import("std");

const build_options = @import("build_options");
const fluent = @import("fluent");

/// Everything the C API allocates comes from here.
///
/// libc's, because a C program's memory is libc's memory: text handed back
/// across the boundary is freed by `fluent_string_free`, but a caller that
/// mixes this library's strings with its own has a `malloc` heap either way,
/// and a second allocator underneath would only be a second thing to go wrong.
///
/// Except under `zig build test`, where it is the testing allocator instead.
/// Ownership is the whole of what this file does -- who copies, who frees,
/// what happens to a half-built value when the next allocation fails -- and
/// `c_allocator` cannot report a leak, so the tests at the bottom of this file
/// would prove only that nothing crashed. This is the one line that lets them
/// prove the rest.
const gpa = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

comptime {
    // The header sizes `fluent_tag` by hand, because a C header cannot ask.
    std.debug.assert(tag_max == fluent.Locale.max_tag_len + 1);
}

/// Room for a language tag and its NUL, matching `FLUENT_TAG_MAX`.
const tag_max = 13;

// -- text ---------------------------------------------------------------------

/// Text handed across the boundary, with the length that frees it again
/// written in front of the bytes C sees.
///
/// The obvious thing -- allocate `len + 1`, free `strlen + 1` -- is wrong, and
/// wrong in a way that only shows up on the input that provokes it. Nothing
/// stops a NUL from being *inside* what this library produces: a translator
/// may put one in an `.ftl` file, and the parser's own error messages quote
/// whatever byte they stopped on, which at the end of a file is a zero. The
/// text is still NUL-terminated for C, and `strlen` still measures every
/// ordinary string; what it cannot be trusted with is handing the allocator a
/// size, because a size that is short by even one byte is a corrupted heap
/// rather than a wrong answer. So the real length is recorded where only
/// `fluent_string_free` and `fluent_string_len` look for it.
const Str = struct {
    /// One `usize` of header, which also keeps the text `usize`-aligned.
    const header = @sizeOf(usize);
    const Align = std.mem.Alignment.of(usize);

    /// A NUL-terminated copy for C to own, or null if memory ran out.
    fn dupe(text: []const u8) ?[*:0]u8 {
        const block = gpa.alignedAlloc(u8, Align, header + text.len + 1) catch return null;
        @as(*usize, @ptrCast(block.ptr)).* = text.len;
        @memcpy(block[header..][0..text.len], text);
        block[header + text.len] = 0;
        return @ptrCast(block[header..].ptr);
    }

    /// The header in front of text this library handed out.
    fn base(text: [*:0]const u8) [*]align(@alignOf(usize)) u8 {
        return @ptrFromInt(@intFromPtr(text) - header);
    }

    fn len(text: [*:0]const u8) usize {
        return @as(*const usize, @ptrCast(base(text))).*;
    }

    fn free(text: [*:0]u8) void {
        const start = base(text);
        gpa.free(start[0 .. header + len(text) + 1]);
    }
};

/// The shape every allocating export uses: `Str.dupe`, spelled shorter.
fn dupeZ(text: []const u8) ?[*:0]u8 {
    return Str.dupe(text);
}

/// What a C string says, without its NUL.
fn span(text: [*:0]const u8) []const u8 {
    return std.mem.span(text);
}

/// The manifest's version, NUL-terminated for C.
///
/// `addOption` hands over a `[]const u8`, but the literal behind it is a Zig
/// string literal and so has a NUL after it like every other; re-slicing with
/// a sentinel is the assertion of that, checked at compile time, and costs no
/// copy.
const version: [:0]const u8 = build_options.version[0..build_options.version.len :0];

export fn fluent_version() [*:0]const u8 {
    return version.ptr;
}

export fn fluent_string_free(text: ?[*:0]u8) void {
    Str.free(text orelse return);
}

export fn fluent_string_len(text: [*:0]const u8) usize {
    return Str.len(text);
}

// -- locales ------------------------------------------------------------------

/// `fluent_tag`: a language tag and its NUL, laid out for C.
const Tag = extern struct {
    text: [tag_max]u8,

    /// The empty tag, which the header defines as "this was not set".
    const unset: Tag = .{ .text = @splat(0) };

    fn from(locale: fluent.Locale) Tag {
        var self: Tag = .unset;
        const text = locale.tag();
        @memcpy(self.text[0..text.len], text);
        return self;
    }

    fn fromOptional(locale: ?fluent.Locale) Tag {
        return if (locale) |value| .from(value) else .unset;
    }
};

export fn fluent_tag_parse(text: [*:0]const u8, out: ?*Tag) bool {
    const locale = fluent.Locale.parse(span(text)) catch return false;
    if (out) |slot| slot.* = .from(locale);
    return true;
}

export fn fluent_tag_from_posix_name(name: [*:0]const u8, out: ?*Tag) bool {
    const locale = fluent.posix.fromName(span(name)) orelse return false;
    if (out) |slot| slot.* = .from(locale);
    return true;
}

/// The process environment as a map, or null if it could not be read.
///
/// `std.process.Environ.Map` is what every reader in this library takes, and a
/// Zig program is handed one by `std.process.Init`. A C program is not: it
/// arrived through `main`, so the block has to be picked up from wherever this
/// platform keeps it. On Windows that is the PEB, which `createMap` locks and
/// walks itself; everywhere else it is libc's `environ`, which is a
/// null-terminated vector this counts to find the end of.
fn currentEnviron() ?std.process.Environ.Map {
    const Environ = std.process.Environ;
    const environ: Environ = if (Environ.Block == Environ.GlobalBlock)
        .{ .block = .global }
    else block: {
        const vector = std.c.environ;
        var count: usize = 0;
        while (vector[count] != null) count += 1;
        break :block .{ .block = .{ .slice = vector[0..count :null] } };
    };
    return Environ.createMap(environ, gpa) catch null;
}

export fn fluent_preferred_locales(out: [*]Tag, cap: usize) usize {
    if (cap == 0) return 0;

    var environ = currentEnviron() orelse return 0;
    defer environ.deinit();

    // On the stack rather than `out`, because the reader wants `[]Locale` and
    // `out` is `[]Tag`. Bounded by the caller's room, so a caller asking for
    // one locale does not pay for eight.
    var buffer: [max_preferred]fluent.Locale = undefined;
    const wanted = fluent.system.preferredLocales(buffer[0..@min(cap, max_preferred)], &environ);

    for (wanted, out[0..wanted.len]) |locale, *slot| slot.* = .from(locale);
    return wanted.len;
}

/// The most locales either of the list readers will report.
///
/// `LANGUAGE` is the only setting that is a list; the rest contribute one
/// each, and beyond a handful of entries nobody is being served better. The
/// header says eight is more than enough room, so this is what "enough" means.
const max_preferred = 8;

export fn fluent_locales_from_list(list: [*:0]const u8, out: [*]Tag, cap: usize) usize {
    if (cap == 0) return 0;

    var buffer: [max_preferred]fluent.Locale = undefined;
    const found = fluent.posix.fromList(buffer[0..@min(cap, max_preferred)], span(list));

    for (found, out[0..found.len]) |locale, *slot| slot.* = .from(locale);
    return found.len;
}

/// `fluent_categories`: one tag per formatting category.
const Categories = extern struct {
    messages: Tag,
    numeric: Tag,
    time: Tag,
    monetary: Tag,
};

export fn fluent_categories_current(out: *Categories) void {
    // Four unset categories is the honest answer when the environment cannot
    // be read at all, and it is also what an unset environment means, so the
    // caller has nothing extra to handle.
    out.* = .{
        .messages = .unset,
        .numeric = .unset,
        .time = .unset,
        .monetary = .unset,
    };

    var environ = currentEnviron() orelse return;
    defer environ.deinit();

    const found = fluent.system.categories(&environ);
    out.* = .{
        .messages = .fromOptional(found.messages),
        .numeric = .fromOptional(found.numeric),
        .time = .fromOptional(found.time),
        .monetary = .fromOptional(found.monetary),
    };
}

// -- errors -------------------------------------------------------------------

/// `fluent_error_kind`, which is C's `int` and so may hold anything.
const ErrorKind = enum(c_int) {
    parse = 0,
    duplicate_message = 1,
    duplicate_term = 2,
    unknown_variable = 3,
    unknown_message = 4,
    unknown_term = 5,
    unknown_attribute = 6,
    unknown_function = 7,
    missing_value = 8,
    cyclic_reference = 9,
    too_many_placeables = 10,
    invalid_argument = 11,
    _,

    fn from(kind: fluent.Error.Kind) ErrorKind {
        return switch (kind) {
            .parse_error => .parse,
            .duplicate_message => .duplicate_message,
            .duplicate_term => .duplicate_term,
            .unknown_variable => .unknown_variable,
            .unknown_message => .unknown_message,
            .unknown_term => .unknown_term,
            .unknown_attribute => .unknown_attribute,
            .unknown_function => .unknown_function,
            .missing_value => .missing_value,
            .cyclic_reference => .cyclic_reference,
            .too_many_placeables => .too_many_placeables,
            .invalid_argument => .invalid_argument,
        };
    }
};

const CErrors = opaque {};

const ErrorList = struct {
    items: fluent.Errors = .empty,

    fn of(handle: *CErrors) *ErrorList {
        return @ptrCast(@alignCast(handle));
    }

    fn ofConst(handle: *const CErrors) *const ErrorList {
        return @ptrCast(@alignCast(handle));
    }
};

export fn fluent_errors_new() ?*CErrors {
    const list = gpa.create(ErrorList) catch return null;
    list.* = .{};
    return @ptrCast(list);
}

export fn fluent_errors_free(handle: ?*CErrors) void {
    const list = ErrorList.of(handle orelse return);
    list.items.deinit(gpa);
    gpa.destroy(list);
}

export fn fluent_errors_len(handle: *const CErrors) usize {
    return ErrorList.ofConst(handle).items.items.len;
}

export fn fluent_errors_clear(handle: *CErrors) void {
    ErrorList.of(handle).items.clearRetainingCapacity();
}

export fn fluent_errors_kind(handle: *const CErrors, index: usize) ErrorKind {
    const list = ErrorList.ofConst(handle);
    // Out of range is undefined in the header, which leaves this free to pick
    // something. A parse error is the least alarming thing to say.
    if (index >= list.items.items.len) return .parse;
    return .from(list.items.items[index].kind);
}

export fn fluent_errors_message(handle: *const CErrors, index: usize) ?[*:0]u8 {
    const list = ErrorList.ofConst(handle);
    if (index >= list.items.items.len) return null;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    out.writer.print("{f}", .{list.items.items[index]}) catch return null;

    return dupeZ(out.written());
}

export fn fluent_errors_name(handle: *const CErrors, index: usize) ?[*:0]u8 {
    const list = ErrorList.ofConst(handle);
    if (index >= list.items.items.len) return null;

    const name = list.items.items[index].name;
    if (name.len == 0) return null;
    return dupeZ(name);
}

// -- formatting options -------------------------------------------------------

/// Every enum C hands in is non-exhaustive, because C's is an `int` and a
/// caller may pass anything that fits in one. Each `from` therefore names the
/// values it knows and falls back to the default rather than trapping.
const NumberStyle = enum(c_int) { decimal = 0, percent = 1, currency = 2, _ };
const CurrencyDisplay = enum(c_int) { symbol = 0, narrow_symbol = 1, code = 2, name = 3, _ };
const PluralKind = enum(c_int) { cardinal = 0, ordinal = 1, _ };

const NumberOptions = extern struct {
    style: NumberStyle,
    minimum_integer_digits: i16,
    minimum_fraction_digits: i16,
    maximum_fraction_digits: i16,
    minimum_significant_digits: i16,
    maximum_significant_digits: i16,
    use_grouping: bool,
    currency: ?[*:0]const u8,
    currency_display: CurrencyDisplay,
    currency_text: ?[*:0]const u8,
    currency_digits: i16,
    plural_kind: PluralKind,

    const default: NumberOptions = .{
        .style = .decimal,
        .minimum_integer_digits = -1,
        .minimum_fraction_digits = -1,
        .maximum_fraction_digits = -1,
        .minimum_significant_digits = -1,
        .maximum_significant_digits = -1,
        .use_grouping = true,
        .currency = null,
        .currency_display = .symbol,
        .currency_text = null,
        .currency_digits = -1,
        .plural_kind = .cardinal,
    };
};

export fn fluent_number_options_default() NumberOptions {
    return .default;
}

const DateStyle = enum(c_int) { unset = 0, full = 1, long = 2, medium = 3, short = 4, _ };
const Width = enum(c_int) { unset = 0, narrow = 1, short = 2, long = 3, _ };
const Numeric = enum(c_int) { unset = 0, numeric = 1, two_digit = 2, _ };
const MonthWidth = enum(c_int) { unset = 0, numeric = 1, two_digit = 2, narrow = 3, short = 4, long = 5, _ };
const ZoneName = enum(c_int) { unset = 0, short = 1, long = 2, short_offset = 3, long_offset = 4, _ };

const DateTimeOptions = extern struct {
    date_style: DateStyle,
    time_style: DateStyle,
    weekday: Width,
    era: Width,
    year: Numeric,
    month: MonthWidth,
    day: Numeric,
    hour: Numeric,
    minute: Numeric,
    second: Numeric,
    fractional_second_digits: i16,
    day_period: Width,
    hour12: i8,
    time_zone_name: ZoneName,

    const default: DateTimeOptions = .{
        .date_style = .unset,
        .time_style = .unset,
        .weekday = .unset,
        .era = .unset,
        .year = .unset,
        .month = .unset,
        .day = .unset,
        .hour = .unset,
        .minute = .unset,
        .second = .unset,
        .fractional_second_digits = -1,
        .day_period = .unset,
        .hour12 = -1,
        .time_zone_name = .unset,
    };
};

export fn fluent_datetime_options_default() DateTimeOptions {
    return .default;
}

/// A digit count C gave, or null for "unset".
///
/// Narrowing happens **after** the range check and never before: the Zig side
/// is a `u8`, and `@intCast` of an out-of-range value is a panic rather than
/// an error, so a caller that asks for 9999 fraction digits would take the
/// program down instead of being told no.
fn digits(value: i16) ?u8 {
    if (value < 0 or value > std.math.maxInt(u8)) return null;
    return @intCast(value);
}

fn numberStyle(style: NumberStyle) fluent.number_format.Style {
    return switch (style) {
        .percent => .percent,
        .currency => .currency,
        else => .decimal,
    };
}

fn currencyDisplay(display: CurrencyDisplay) fluent.number_format.CurrencyDisplay {
    return switch (display) {
        .narrow_symbol => .narrow_symbol,
        .code => .code,
        .name => .name,
        else => .symbol,
    };
}

fn dateStyle(style: DateStyle) ?fluent.datetime_format.Options.Style {
    return switch (style) {
        .full => .full,
        .long => .long,
        .medium => .medium,
        .short => .short,
        else => null,
    };
}

fn width(value: Width) ?fluent.datetime_format.Options.Width {
    return switch (value) {
        .narrow => .narrow,
        .short => .short,
        .long => .long,
        else => null,
    };
}

fn numeric(value: Numeric) ?fluent.datetime_format.Options.Numeric {
    return switch (value) {
        .numeric => .numeric,
        .two_digit => .@"2-digit",
        else => null,
    };
}

fn monthWidth(value: MonthWidth) ?fluent.datetime_format.Options.MonthWidth {
    return switch (value) {
        .numeric => .numeric,
        .two_digit => .@"2-digit",
        .narrow => .narrow,
        .short => .short,
        .long => .long,
        else => null,
    };
}

fn zoneName(value: ZoneName) ?fluent.datetime_format.Options.TimeZoneName {
    return switch (value) {
        .short => .short,
        .long => .long,
        .short_offset => .short_offset,
        .long_offset => .long_offset,
        else => null,
    };
}

fn dateTimeOptions(from: DateTimeOptions) fluent.datetime_format.Options {
    return .{
        .date_style = dateStyle(from.date_style),
        .time_style = dateStyle(from.time_style),
        .weekday = width(from.weekday),
        .era = width(from.era),
        .year = numeric(from.year),
        .month = monthWidth(from.month),
        .day = numeric(from.day),
        .hour = numeric(from.hour),
        .minute = numeric(from.minute),
        .second = numeric(from.second),
        .fractional_second_digits = digits(from.fractional_second_digits),
        .day_period = width(from.day_period),
        .hour12 = if (from.hour12 < 0) null else from.hour12 != 0,
        .time_zone_name = zoneName(from.time_zone_name),
        // Not reachable from C: a zone is a parsed TZif that belongs to
        // zig-datetime and outlives any one call, so there is nothing sensible
        // for a C caller to pass. The header says dates are read in UTC.
        .time_zone = null,
    };
}

// -- arguments ----------------------------------------------------------------

const CArgs = opaque {};

/// An argument list that owns every byte in it.
///
/// The header promises a caller may free its buffers as soon as a setter
/// returns, so a name, a string value and a currency's two strings are all
/// copied. Everything owned is reachable from the `fluent.Argument` itself,
/// which is why one list is enough and `release` can free a slot without a
/// parallel bookkeeping array to consult.
const ArgList = struct {
    items: std.ArrayList(fluent.Argument) = .empty,

    fn of(handle: *CArgs) *ArgList {
        return @ptrCast(@alignCast(handle));
    }

    fn ofConst(handle: *const CArgs) *const ArgList {
        return @ptrCast(@alignCast(handle));
    }

    fn release(argument: fluent.Argument) void {
        gpa.free(argument.name);
        switch (argument.value) {
            .string, .none => |text| gpa.free(text),
            .number => |number| {
                if (number.options.currency) |code| gpa.free(code);
                // Not optional on the Zig side: the default is a static empty
                // string, which is not ours to free.
                if (number.options.currency_text.len != 0) gpa.free(number.options.currency_text);
            },
            .datetime => {},
        }
    }

    /// Store `value` under `name`, replacing whatever was there.
    ///
    /// Takes ownership of `value`'s allocations, and frees them if it cannot
    /// find room -- so a caller that fails need not unpick what it built.
    fn set(self: *ArgList, name: []const u8, value: fluent.Value) bool {
        const owned_name = gpa.dupe(u8, name) catch {
            release(.{ .name = "", .value = value });
            return false;
        };

        for (self.items.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            release(existing.*);
            existing.* = .{ .name = owned_name, .value = value };
            return true;
        }

        self.items.append(gpa, .{ .name = owned_name, .value = value }) catch {
            gpa.free(owned_name);
            release(.{ .name = "", .value = value });
            return false;
        };
        return true;
    }
};

export fn fluent_args_new() ?*CArgs {
    const list = gpa.create(ArgList) catch return null;
    list.* = .{};
    return @ptrCast(list);
}

export fn fluent_args_free(handle: ?*CArgs) void {
    const list = ArgList.of(handle orelse return);
    for (list.items.items) |argument| ArgList.release(argument);
    list.items.deinit(gpa);
    gpa.destroy(list);
}

export fn fluent_args_clear(handle: *CArgs) void {
    const list = ArgList.of(handle);
    for (list.items.items) |argument| ArgList.release(argument);
    list.items.clearRetainingCapacity();
}

export fn fluent_args_len(handle: *const CArgs) usize {
    return ArgList.ofConst(handle).items.items.len;
}

export fn fluent_args_set_string(
    handle: *CArgs,
    name: [*:0]const u8,
    text: [*]const u8,
    text_len: usize,
) bool {
    const owned = gpa.dupe(u8, text[0..text_len]) catch return false;
    return ArgList.of(handle).set(span(name), .{ .string = owned });
}

export fn fluent_args_set_number(handle: *CArgs, name: [*:0]const u8, value: f64) bool {
    return ArgList.of(handle).set(span(name), .num(value));
}

export fn fluent_args_set_number_with(
    handle: *CArgs,
    name: [*:0]const u8,
    value: f64,
    options: ?*const NumberOptions,
) bool {
    const from = (options orelse &NumberOptions.default).*;

    // Duped before anything is stored, and each cleaned up if the next fails,
    // so a half-built value never reaches the list.
    const currency: ?[]const u8 = if (from.currency) |code|
        gpa.dupe(u8, span(code)) catch return false
    else
        null;
    errdefer if (currency) |code| gpa.free(code);

    const currency_text: []const u8 = if (from.currency_text) |text| text: {
        const said = span(text);
        if (said.len == 0) break :text "";
        break :text gpa.dupe(u8, said) catch {
            if (currency) |code| gpa.free(code);
            return false;
        };
    } else "";

    return ArgList.of(handle).set(span(name), .{ .number = .{
        .value = value,
        .plural_kind = if (from.plural_kind == .ordinal) .ordinal else .cardinal,
        .options = .{
            .style = numberStyle(from.style),
            .minimum_integer_digits = digits(from.minimum_integer_digits),
            .minimum_fraction_digits = digits(from.minimum_fraction_digits),
            .maximum_fraction_digits = digits(from.maximum_fraction_digits),
            .minimum_significant_digits = digits(from.minimum_significant_digits),
            .maximum_significant_digits = digits(from.maximum_significant_digits),
            .use_grouping = from.use_grouping,
            .currency = currency,
            .currency_display = currencyDisplay(from.currency_display),
            .currency_text = currency_text,
            .currency_digits = digits(from.currency_digits) orelse 2,
        },
    } });
}

export fn fluent_args_set_datetime(handle: *CArgs, name: [*:0]const u8, epoch_ms: i64) bool {
    return ArgList.of(handle).set(span(name), .time(epoch_ms));
}

export fn fluent_args_set_datetime_with(
    handle: *CArgs,
    name: [*:0]const u8,
    epoch_ms: i64,
    options: ?*const DateTimeOptions,
) bool {
    const from = (options orelse &DateTimeOptions.default).*;
    return ArgList.of(handle).set(span(name), .{ .datetime = .{
        .epoch_ms = epoch_ms,
        .options = dateTimeOptions(from),
    } });
}

/// What to format with, for a `fluent_args` that may be null.
fn argsOf(handle: ?*const CArgs) fluent.Args {
    const list = ArgList.ofConst(handle orelse return &.{});
    return list.items.items;
}

// -- bundles ------------------------------------------------------------------

const CBundle = opaque {};

const BundleBox = struct {
    inner: fluent.Bundle,
    /// The locale tag, NUL-terminated, for `fluent_bundle_locale` to lend out.
    ///
    /// `Locale.tag()` is a slice of a fixed array that is only NUL-terminated
    /// when the tag is shorter than the array, and the longest tags fill it,
    /// so a C caller cannot be handed a pointer into it.
    tag: [tag_max]u8,

    fn of(handle: *CBundle) *BundleBox {
        return @ptrCast(@alignCast(handle));
    }

    fn ofConst(handle: *const CBundle) *const BundleBox {
        return @ptrCast(@alignCast(handle));
    }
};

export fn fluent_bundle_new(locale: [*:0]const u8) ?*CBundle {
    const parsed = fluent.Locale.parse(span(locale)) catch return null;

    const box = gpa.create(BundleBox) catch return null;
    box.* = .{
        .inner = fluent.Bundle.init(gpa, parsed) catch {
            gpa.destroy(box);
            return null;
        },
        .tag = @splat(0),
    };

    const text = box.inner.locale.tag();
    @memcpy(box.tag[0..text.len], text);

    return @ptrCast(box);
}

export fn fluent_bundle_free(handle: ?*CBundle) void {
    const box = BundleBox.of(handle orelse return);
    box.inner.deinit();
    gpa.destroy(box);
}

export fn fluent_bundle_locale(handle: *const CBundle) [*:0]const u8 {
    // The array is zero-filled at creation and the tag is at most one byte
    // shorter than it, so there is always a NUL to terminate on.
    return @ptrCast(&BundleBox.ofConst(handle).tag);
}

export fn fluent_bundle_set_use_isolating(handle: *CBundle, on: bool) void {
    BundleBox.of(handle).inner.use_isolating = on;
}

fn addResource(
    handle: *CBundle,
    source: [*]const u8,
    source_len: usize,
    errors: ?*CErrors,
    options: fluent.AddOptions,
) bool {
    const box = BundleBox.of(handle);
    const list: ?*fluent.Errors = if (errors) |handle_| &ErrorList.of(handle_).items else null;
    box.inner.addResource(source[0..source_len], options, list) catch return false;
    return true;
}

export fn fluent_bundle_add_resource(
    handle: *CBundle,
    source: [*]const u8,
    source_len: usize,
    errors: ?*CErrors,
) bool {
    return addResource(handle, source, source_len, errors, .{});
}

export fn fluent_bundle_add_resource_overriding(
    handle: *CBundle,
    source: [*]const u8,
    source_len: usize,
    errors: ?*CErrors,
) bool {
    return addResource(handle, source, source_len, errors, .{ .allow_overrides = true });
}

export fn fluent_bundle_has_message(handle: *const CBundle, id: [*:0]const u8) bool {
    return BundleBox.ofConst(handle).inner.hasMessage(span(id));
}

export fn fluent_bundle_format(
    handle: *const CBundle,
    id: [*:0]const u8,
    args: ?*const CArgs,
    errors: ?*CErrors,
) ?[*:0]u8 {
    const box = BundleBox.ofConst(handle);
    const list: ?*fluent.Errors = if (errors) |handle_| &ErrorList.of(handle_).items else null;

    const text = (box.inner.format(gpa, span(id), argsOf(args), list) catch return null) orelse
        return null;
    defer gpa.free(text);
    return dupeZ(text);
}

export fn fluent_bundle_format_attribute(
    handle: *const CBundle,
    id: [*:0]const u8,
    attribute: [*:0]const u8,
    args: ?*const CArgs,
    errors: ?*CErrors,
) ?[*:0]u8 {
    const box = BundleBox.ofConst(handle);
    const list: ?*fluent.Errors = if (errors) |handle_| &ErrorList.of(handle_).items else null;

    const text = (box.inner.formatAttribute(
        gpa,
        span(id),
        span(attribute),
        argsOf(args),
        list,
    ) catch return null) orelse return null;
    defer gpa.free(text);
    return dupeZ(text);
}

export fn fluent_bundle_set_number_locale(handle: *CBundle, locale: [*:0]const u8) bool {
    const parsed = fluent.Locale.parse(span(locale)) catch return false;
    BundleBox.of(handle).inner.setNumberLocale(parsed);
    return true;
}

export fn fluent_bundle_set_currency_locale(handle: *CBundle, locale: [*:0]const u8) bool {
    const parsed = fluent.Locale.parse(span(locale)) catch return false;
    BundleBox.of(handle).inner.setCurrencyLocale(parsed);
    return true;
}

export fn fluent_bundle_set_date_locale(handle: *CBundle, locale: [*:0]const u8) bool {
    const parsed = fluent.Locale.parse(span(locale)) catch return false;
    BundleBox.of(handle).inner.setDateLocale(parsed);
    return true;
}

/// What a category names, or null for "the caller said nothing".
///
/// An empty tag is the header's way of saying unset. Anything that does not
/// parse is read the same way, since a category this library cannot make sense
/// of is one it has no opinion about.
fn categoryLocale(value: Tag) ?fluent.Locale {
    const text = std.mem.sliceTo(&value.text, 0);
    if (text.len == 0) return null;
    return fluent.Locale.parse(text) catch null;
}

export fn fluent_bundle_apply_categories(handle: *CBundle, categories: *const Categories) void {
    fluent.system.applyCategories(&BundleBox.of(handle).inner, .{
        .messages = categoryLocale(categories.messages),
        .numeric = categoryLocale(categories.numeric),
        .time = categoryLocale(categories.time),
        .monetary = categoryLocale(categories.monetary),
    });
}

// -- tests --------------------------------------------------------------------
//
// `tests/c_api.c` is the one that matters: it is compiled by a C compiler
// against `include/fluent.h`, so it is what catches the two sides drifting
// apart. What these add is the thing a C program cannot check about itself --
// that every allocation this file makes is freed again -- because here `gpa`
// is `std.testing.allocator` and a leak fails the test.

const testing = std.testing;

/// Call an exported function the way C would, and free what it returns.
fn formatted(bundle: *const CBundle, id: [*:0]const u8, args: ?*const CArgs) ![]const u8 {
    const text = fluent_bundle_format(bundle, id, args, null) orelse return error.NoSuchMessage;
    defer fluent_string_free(text);
    return testing.allocator.dupe(u8, std.mem.span(text));
}

test "a bundle owns its resources and frees them" {
    const bundle = fluent_bundle_new("en").?;
    defer fluent_bundle_free(bundle);
    fluent_bundle_set_use_isolating(bundle, false);

    const source = "welcome = Welcome!\n";
    try testing.expect(fluent_bundle_add_resource(bundle, source, source.len, null));

    const text = try formatted(bundle, "welcome", null);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Welcome!", text);
}

test "an argument list frees what it copied" {
    const bundle = fluent_bundle_new("en").?;
    defer fluent_bundle_free(bundle);
    fluent_bundle_set_use_isolating(bundle, false);

    const source = "greeting = Hello, { $name }! You paid { $amount }.\n";
    try testing.expect(fluent_bundle_add_resource(bundle, source, source.len, null));

    const args = fluent_args_new().?;
    defer fluent_args_free(args);

    try testing.expect(fluent_args_set_string(args, "name", "Ada", 3));

    // A currency carries two strings of its own, and replacing the argument
    // has to free the pair the old one held.
    var options: NumberOptions = .default;
    options.style = .currency;
    options.currency = "EUR";
    options.currency_text = "€";
    try testing.expect(fluent_args_set_number_with(args, "amount", 12.5, &options));

    options.currency = "GBP";
    options.currency_text = "£";
    try testing.expect(fluent_args_set_number_with(args, "amount", 3, &options));
    try testing.expectEqual(@as(usize, 2), fluent_args_len(args));

    const text = try formatted(bundle, "greeting", args);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Hello, Ada! You paid £3.00.", text);

    // Clearing has to free them too, not merely forget them.
    fluent_args_clear(args);
    try testing.expectEqual(@as(usize, 0), fluent_args_len(args));
}

test "an error list frees what it collected" {
    const bundle = fluent_bundle_new("und").?;
    defer fluent_bundle_free(bundle);

    const errors = fluent_errors_new().?;
    defer fluent_errors_free(errors);

    const source = "before = fine\nbroken = { $x\n";
    try testing.expect(fluent_bundle_add_resource(bundle, source, source.len, errors));
    try testing.expect(fluent_errors_len(errors) >= 1);
    try testing.expectEqual(ErrorKind.parse, fluent_errors_kind(errors, 0));

    const message = fluent_errors_message(errors, 0).?;
    defer fluent_string_free(message);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(message), "parse error"));

    // Cleared and refilled, so that the second round cannot reuse the first's
    // storage without noticing.
    fluent_errors_clear(errors);
    try testing.expectEqual(@as(usize, 0), fluent_errors_len(errors));
    try testing.expect(fluent_bundle_add_resource(bundle, source, source.len, errors));
    try testing.expect(fluent_errors_len(errors) >= 1);
}

test "a value C got wrong is refused rather than trapping" {
    // Every enum C hands over is an `int`, and a digit count is narrowed only
    // after it has been checked. Neither may take the process down.
    try testing.expectEqual(@as(?u8, null), digits(-1));
    try testing.expectEqual(@as(?u8, null), digits(9999));
    try testing.expectEqual(@as(?u8, 0), digits(0));

    try testing.expectEqual(fluent.number_format.Style.decimal, numberStyle(@enumFromInt(77)));
    try testing.expectEqual(@as(?fluent.datetime_format.Options.Style, null), dateStyle(@enumFromInt(-3)));

    try testing.expect(fluent_bundle_new("this is not a language tag") == null);
    try testing.expect(!fluent_tag_parse("nor is this", null));
}

test "text with a NUL in it survives the round trip" {
    // An `.ftl` file is bytes, and a translator is free to put a NUL in one.
    // Freeing such a string by `strlen` hands the allocator a size that is too
    // small, which is a corrupted heap rather than a wrong answer, so this is
    // the case the length header exists for.
    const bundle = fluent_bundle_new("und").?;
    defer fluent_bundle_free(bundle);
    fluent_bundle_set_use_isolating(bundle, false);

    const source = "m = before\x00after\n";
    try testing.expect(fluent_bundle_add_resource(bundle, source, source.len, null));

    const text = fluent_bundle_format(bundle, "m", null, null).?;
    defer fluent_string_free(text);

    // C sees a NUL-terminated string that stops early, and can ask for the
    // whole of it. Either way the allocation is given back intact.
    const whole = text[0..fluent_string_len(text)];
    try testing.expectEqualStrings("before\x00after", whole);
    try testing.expectEqualStrings("before", std.mem.span(text));
}

test "freeing null is allowed everywhere" {
    // What lets a C caller clean up without branching.
    fluent_string_free(null);
    fluent_args_free(null);
    fluent_errors_free(null);
    fluent_bundle_free(null);
}
