// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What this library must do with input nobody wrote.
//!
//! Everything here is a property rather than an example -- not "this file
//! parses to that", which the unit tests have, but "whatever arrives, the
//! parser terminates, stays inside its buffers, and never fails". That last
//! one is unusually strong and is worth stating plainly: `parse` has no error
//! path except running out of memory. Any byte sequence at all is a resource,
//! because a broken entry becomes junk rather than an error, and this is where
//! that claim is tested against input that was not written by hand.
//!
//! Why it matters more here than in most parsers: translation files are data,
//! and on a platform where translators submit their own, they are data
//! supplied by people the application does not control. A `.ftl` file is
//! reached by the same path a user's display name is.
//!
//! Each target is an ordinary test as well as a fuzz target. Without `--fuzz`
//! it runs the seeds beside it, so `zig build test` exercises the same
//! properties on input that has already been interesting once.
//!
//! Note that Zig 0.16.0 cannot build a test executable in fuzz mode without a
//! patched standard library, and leaves the fuzzer's coverage table empty even
//! then; the flake in this repository says more, and `zig build fuzz-run` is
//! the loop that does the work in the meantime.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;

const fluent = @import("fluent");

/// The allocator the targets run against.
///
/// Under `zig build test` that is the testing allocator, which reports a leak
/// as a failure. `tools/fuzz.zig` cannot name it -- it is not a test build --
/// so it sets this to a checked allocator of its own instead.
pub var backing: Allocator = if (builtin.is_test) testing.allocator else undefined;

// -- parsing -----------------------------------------------------------------

const source_seeds = [_][]const u8{
    "hello = Hello, world!\n",
    "# A comment\nhello = Hi\n",
    "### Resource comment\n\n## Group\n\nm = v\n",
    "m =\n    .attr = value\n",
    "-term = Firefox\n    .gender = neuter\n",
    "m = { $n ->\n    [one] one\n   *[other] many\n }\n",
    "m = { NUMBER($n, maximumFractionDigits: 2) }\n",
    "m = { \"a\\\"b\\\\c\\u0041\\U01F600\" }\n",
    "m = { -term.attr }\n",
    "m = { { $x } }\n",
    "multi =\n    first\n        indented\n    last\n",
    "m = a\r\nn = b\r\n",
    "broken = { $x\nafter = fine\n",
    "m = }\n",
    "m = { 1.5 } { -2 } { 0 }\n",
    "",
    "\n\n\n",
    "=",
    "{",
    "\xff\xfe\x00",
};

/// Parsing never fails, and what comes back is coherent.
///
/// Every entry either has the shape its kind requires -- a term with a value,
/// junk with an annotation -- or the tree is lying about what it holds.
fn parseProperty(input: []const u8) !void {
    var resource = try fluent.syntax.parse(backing, input);
    defer resource.deinit();

    for (resource.body) |entry| switch (entry) {
        .message => |message| {
            try testing.expect(message.id.name.len > 0);
            // The parser refuses a message with neither, so one with both
            // absent should not be reachable.
            try testing.expect(message.value != null or message.attributes.len > 0);
        },
        .term => |term| try testing.expect(term.id.name.len > 0),
        .junk => |junk| try testing.expect(junk.annotations.len > 0),
        .comment => {},
    };
}

fn fuzzParse(_: void, smith: *Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    try parseProperty(buffer[0..len]);
}

test "parsing never fails" {
    for (source_seeds) |seed| try parseProperty(seed);
}

// -- the round trip ----------------------------------------------------------

/// Whatever parsed, serializing it and parsing that gives the same tree.
///
/// Junk is kept, because dropping it can move a comment onto the entry below
/// -- the reason is written out in `tests/conformance.zig` -- and this
/// property is about the serializer rather than about that.
fn roundTripProperty(input: []const u8) !void {
    var first = try fluent.syntax.parse(backing, input);
    defer first.deinit();

    var once: std.Io.Writer.Allocating = .init(backing);
    defer once.deinit();
    fluent.syntax.serialize(first, &once.writer, .{ .with_junk = true }) catch return error.OutOfMemory;

    var second = try fluent.syntax.parse(backing, once.written());
    defer second.deinit();

    // Comparing the trees means comparing what they mean, which is what the
    // interchange JSON is: two resources that write the same JSON hold the
    // same messages however they were laid out.
    var a: std.Io.Writer.Allocating = .init(backing);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(backing);
    defer b.deinit();
    fluent.syntax.writeJson(first, &a.writer) catch return error.OutOfMemory;
    fluent.syntax.writeJson(second, &b.writer) catch return error.OutOfMemory;

    // A lone carriage return before a line end is the one thing FTL text
    // cannot represent, and the serializer says so; see its documentation.
    if (std.mem.indexOfScalar(u8, input, '\r') != null) return;

    try testing.expectEqualStrings(a.written(), b.written());
}

fn fuzzRoundTrip(_: void, smith: *Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len = smith.slice(&buffer);
    try roundTripProperty(buffer[0..len]);
}

test "what parsed survives being written back out" {
    for (source_seeds) |seed| try roundTripProperty(seed);
}

// -- resolving ---------------------------------------------------------------

/// Formatting every message of an arbitrary resource terminates and produces
/// text, whatever arguments it is given.
///
/// This is where the placeable budget and the cycle check are exercised on
/// input designed to defeat them.
fn resolveProperty(input: []const u8, count: f64, word: []const u8) !void {
    var bundle: fluent.Bundle = try .init(backing, .root);
    defer bundle.deinit();
    try bundle.addResource(input, .{ .allow_overrides = true }, null);

    const args: fluent.Args = &.{
        .{ .name = "n", .value = .num(count) },
        .{ .name = "count", .value = .num(count) },
        .{ .name = "name", .value = .{ .string = word } },
        .{ .name = "t", .value = .time(if (std.math.isFinite(count))
            @intFromFloat(@min(1e15, @max(-1e15, count)))
        else
            0) },
    };

    var it = bundle.messages.iterator();
    while (it.next()) |entry| {
        const text = try bundle.format(backing, entry.key_ptr.*, args, null) orelse continue;
        backing.free(text);
    }
}

fn fuzzResolve(_: void, smith: *Smith) !void {
    var source_buffer: [4096]u8 = undefined;
    const source_len = smith.slice(&source_buffer);
    var word_buffer: [64]u8 = undefined;
    const word_len = smith.slice(&word_buffer);
    // Every bit pattern, so that the conversions to a timestamp and to plural
    // operands are asked about the infinities and the numbers past the end of
    // an `i64` as well as about plausible counts.
    const count: f64 = @bitCast(smith.value(u64));
    try resolveProperty(source_buffer[0..source_len], count, word_buffer[0..word_len]);
}

test "formatting terminates whatever the resource says" {
    for (source_seeds) |seed| try resolveProperty(seed, 3, "Ada");
    // The shapes the two limits exist for.
    try resolveProperty("a = { b }\nb = { a }\n", 1, "x");
    try resolveProperty("a = { a }\n", 1, "x");
    try resolveProperty(
        \\m0 = { m1 }{ m1 }{ m1 }{ m1 }
        \\m1 = { m2 }{ m2 }{ m2 }{ m2 }
        \\m2 = { m3 }{ m3 }{ m3 }{ m3 }
        \\m3 = { m4 }{ m4 }{ m4 }{ m4 }
        \\m4 = leaf
        \\
    , 1, "x");
}

// -- formatting numbers ------------------------------------------------------

/// No number and no combination of options can make the formatter run past its
/// buffers or fail to terminate.
///
/// The digit options are the interesting part: they are written by a
/// translator, so they arrive as whatever was typed, and the formatter has to
/// hold up against a minimum above a maximum and a hundred significant figures
/// of a subnormal.
fn numberProperty(value: f64, options: fluent.number_format.Options) !void {
    var bundle: fluent.Bundle = try .init(backing, .root);
    defer bundle.deinit();

    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try bundle.numberFormatter(options).format(value, &w);

    // Whatever came out, the plural rules must be able to read it back.
    _ = fluent.plural.Operands.fromDecimal(w.buffered());
}

fn fuzzNumber(_: void, smith: *Smith) !void {
    // Every bit pattern, so the infinities, the NaNs and the subnormals all
    // come up rather than only the numbers a person would think to write.
    const value: f64 = @bitCast(smith.value(u64));
    try numberProperty(value, .{
        // The full `u8` range, not a sensible one: these are written by a
        // translator, so what arrives is whatever was typed.
        .minimum_integer_digits = smith.value(u8),
        .minimum_fraction_digits = smith.value(u8),
        .maximum_fraction_digits = smith.value(u8),
        .minimum_significant_digits = smith.value(u8),
        .maximum_significant_digits = smith.value(u8),
        .use_grouping = smith.value(bool),
    });
}

test "the number formatter holds up against any options" {
    const values = [_]f64{
        0,                      -0.0,                       1,                 -1,
        0.5,                    1234567.891,                1e300,             -1e300,
        std.math.floatMin(f64), std.math.floatTrueMin(f64), std.math.nan(f64), std.math.inf(f64),
        -std.math.inf(f64),
    };
    for (values) |value| {
        try numberProperty(value, .{});
        try numberProperty(value, .{ .maximum_fraction_digits = 40 });
        try numberProperty(value, .{ .minimum_integer_digits = 40 });
        try numberProperty(value, .{ .minimum_fraction_digits = 40, .maximum_fraction_digits = 0 });
        try numberProperty(value, .{ .minimum_significant_digits = 40, .maximum_significant_digits = 1 });
        try numberProperty(value, .{ .maximum_significant_digits = 40 });
    }
}

// -- plural operands ---------------------------------------------------------

const decimal_seeds = [_][]const u8{
    "0",        "1",        "1.0", "-1.230", "1c6", "1.0001c3", "999999999999999999999999",
    "",         ".",        "-",   "1.",     ".5",  "1e",       "1c",
    "+1,234.5", "0.000000",
};

/// Deriving the operands from arbitrary text terminates and stays consistent:
/// the value cannot be negative, and the digit counts cannot exceed the text.
fn operandsProperty(text: []const u8) !void {
    const operands = fluent.plural.Operands.fromDecimal(text);
    try testing.expect(!(operands.n < 0));
    try testing.expect(operands.w <= operands.v);
    try testing.expect(operands.t <= operands.f);
    try testing.expect(operands.v <= text.len);

    // And every locale can be asked about it without failing.
    for ([_][]const u8{ "en", "ru", "cy", "ar", "pl", "und" }) |tag| {
        const locale = try fluent.Locale.parse(tag);
        _ = fluent.plural.select(&locale, .cardinal, operands);
        _ = fluent.plural.select(&locale, .ordinal, operands);
    }
}

fn fuzzOperands(_: void, smith: *Smith) !void {
    var buffer: [64]u8 = undefined;
    const len = smith.slice(&buffer);
    try operandsProperty(buffer[0..len]);
}

test "plural operands come out of any text" {
    for (decimal_seeds) |seed| try operandsProperty(seed);
}

// -- locale tags -------------------------------------------------------------

const tag_seeds = [_][]const u8{
    "en",  "en-US",   "sr-Latn-RS", "es-419", "PT_br",
    "und", "x",       "toolongtag", "en-",    "-en",
    "",    "en-Latn", "e",          "123",    "en-US-u-ca-buddhist",
};

/// A tag either parses to something canonical or is refused; nothing in
/// between, and nothing that walks off the end of the fixed buffer.
fn localeProperty(text: []const u8) !void {
    const locale = fluent.Locale.parse(text) catch return;
    try testing.expect(locale.tag().len > 0);
    try testing.expect(locale.language().len >= 2 and locale.language().len <= 3);

    // Parsing what it printed gives the same locale back.
    const again = try fluent.Locale.parse(locale.tag());
    try testing.expectEqualStrings(locale.tag(), again.tag());

    var buffer: [3][]const u8 = undefined;
    _ = locale.fallbacks(&buffer);
}

fn fuzzLocale(_: void, smith: *Smith) !void {
    var buffer: [64]u8 = undefined;
    const len = smith.slice(&buffer);
    try localeProperty(buffer[0..len]);
}

test "language tags parse or are refused, and nothing else" {
    for (tag_seeds) |seed| try localeProperty(seed);
}

// -- the table the standalone driver reads -----------------------------------

pub const Target = struct {
    name: []const u8,
    run: *const fn (input: []const u8) anyerror!void,
    /// Inputs worth mutating: the same seeds the tests above run, which are
    /// what stands in for the coverage feedback a real fuzzer would have.
    corpus: []const []const u8,
    /// The buffer this target reads its input into.
    ///
    /// `Smith.slice` yields an *empty* slice for a length larger than the
    /// buffer rather than a truncated one, so a generator that does not know
    /// this number hands the target nothing at all most of the time.
    content_max: usize,
};

/// Wraps one of the `fuzz*` functions above so that it takes raw bytes.
fn Driven(comptime one: fn (void, *Smith) anyerror!void) type {
    return struct {
        fn run(input: []const u8) anyerror!void {
            var smith: Smith = .{ .in = input };
            return one({}, &smith);
        }
    };
}

pub const all = [_]Target{
    .{ .name = "parse", .run = Driven(fuzzParse).run, .corpus = &source_seeds, .content_max = 4096 },
    .{ .name = "roundtrip", .run = Driven(fuzzRoundTrip).run, .corpus = &source_seeds, .content_max = 4096 },
    // The smaller of this target's two buffers, so that both slices are fed.
    .{ .name = "resolve", .run = Driven(fuzzResolve).run, .corpus = &source_seeds, .content_max = 64 },
    .{ .name = "numbers", .run = Driven(fuzzNumber).run, .corpus = &decimal_seeds, .content_max = 64 },
    .{ .name = "operands", .run = Driven(fuzzOperands).run, .corpus = &decimal_seeds, .content_max = 64 },
    .{ .name = "locales", .run = Driven(fuzzLocale).run, .corpus = &tag_seeds, .content_max = 64 },
};

test {
    // Zig's fuzzer takes a test at a time, so each target needs one.
    _ = fuzzParse;
    _ = fuzzRoundTrip;
    _ = fuzzResolve;
    _ = fuzzNumber;
    _ = fuzzOperands;
    _ = fuzzLocale;
}
