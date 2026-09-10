// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fluent's cross-implementation conformance suite.
//!
//! `projectfluent/fluent` ships a directory of `.ftl` files, each paired with
//! the abstract syntax tree it must parse to, written as JSON. It is the only
//! test Fluent has that every implementation is expected to agree on, and it
//! covers the corners that are easy to get subtly wrong and hard to notice:
//! how much of a file one broken entry takes with it, where the common indent
//! of a multi-line pattern is measured from, which expressions may select.
//!
//! The fixtures are not vendored. They arrive as a lazy package dependency, so
//! they are fetched when the tests are run and never by a consumer of the
//! library, and the exact revision compared against is a hash in
//! `build.zig.zon` rather than a copy in this repository that could drift.
//!
//! Trees are compared as parsed JSON rather than as text, because the
//! reference files were written by a different program and there is no reason
//! for the two to agree about key order or spacing -- only about content.

const std = @import("std");

const fluent = @import("fluent");
const options = @import("conformance_options");

test "every fixture parses to the reference tree" {
    const gpa = std.testing.allocator;
    // The suite only ever runs under `zig build test`, so it may name the
    // testing `Io` directly rather than taking one from a caller.
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, options.fixtures_dir, .{ .iterate = true });
    defer dir.close(io);

    var failures: usize = 0;
    var checked: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ftl")) continue;

        const expected_name = try std.fmt.allocPrint(gpa, "{s}.json", .{entry.name[0 .. entry.name.len - 4]});
        defer gpa.free(expected_name);

        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const expected_text = try dir.readFileAlloc(io, expected_name, gpa, .limited(1 << 20));
        defer gpa.free(expected_text);

        checked += 1;
        checkFixture(gpa, entry.name, source, expected_text) catch |err| {
            std.debug.print("conformance: {s} failed: {t}\n", .{ entry.name, err });
            failures += 1;
        };
    }

    // A directory that turned up empty would otherwise pass in silence, which
    // is the one way this test could stop testing anything without saying so.
    try std.testing.expect(checked >= 30);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "every fixture survives being written back out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, options.fixtures_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ftl")) continue;

        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);

        // A lone carriage return -- one not part of a CRLF -- is a character
        // FTL text cannot represent when a line end follows it, so a file
        // built out of them is the one thing the serializer knowingly loses.
        // The reason is written out at the top of `src/syntax/serializer.zig`.
        if (hasLoneCarriageReturn(source)) continue;

        checkRoundTrip(gpa, source) catch |err| {
            std.debug.print("round trip: {s} failed: {t}\n", .{ entry.name, err });
            return err;
        };
    }
}

/// Whether the source holds a carriage return that is not part of a CRLF.
///
/// That is the one character FTL text cannot represent when a line end
/// follows it, which is why such a file is left out of the round trip.
fn hasLoneCarriageReturn(source: []const u8) bool {
    for (source, 0..) |c, i| {
        if (c != '\r') continue;
        if (i + 1 >= source.len or source[i + 1] != '\n') return true;
    }
    return false;
}

/// Two properties, checked together on every fixture.
///
/// **Nothing understood becomes unreadable.** Serializing a resource and
/// parsing the result yields no junk: everything the parser understood, the
/// serializer can write in a form the parser understands again.
///
/// **Formatting converges.** Serializing that result, and the result of that,
/// gives byte-identical text. A formatter that kept changing a file it had
/// already formatted would be unusable in a commit hook.
///
/// The first pass is exempt from the second property, and the reason is worth
/// stating: it is the pass that drops the junk, and dropping junk can move a
/// comment. A `#` comment belongs to the entry directly beneath it, so one
/// written above a broken entry stands alone -- but delete the broken entry
/// and that comment now sits above whatever came next, and belongs to it
/// instead. Nothing is lost and nothing is ambiguous; the file has simply
/// changed, once, in the pass that removed what the comment was about. From
/// there on it is a fixed point.
fn checkRoundTrip(gpa: std.mem.Allocator, source: []const u8) !void {
    var original = try fluent.syntax.parse(gpa, source);
    defer original.deinit();

    var first = try serializeAlloc(gpa, original);
    defer first.deinit();

    var reparsed = try fluent.syntax.parse(gpa, first.written());
    defer reparsed.deinit();

    if (reparsed.hasJunk()) {
        for (reparsed.body) |entry| {
            if (entry == .junk) std.debug.print("  serializer produced junk: \"{f}\"\n", .{
                std.zig.fmtString(entry.junk.content),
            });
        }
        return error.SerializedToJunk;
    }

    var second = try serializeAlloc(gpa, reparsed);
    defer second.deinit();

    var settled = try fluent.syntax.parse(gpa, second.written());
    defer settled.deinit();

    var third = try serializeAlloc(gpa, settled);
    defer third.deinit();

    try std.testing.expectEqualStrings(second.written(), third.written());
}

/// Serialize a resource into a fresh buffer the caller owns.
fn serializeAlloc(gpa: std.mem.Allocator, resource: fluent.syntax.Resource) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try fluent.syntax.serialize(resource, &out.writer, .{});
    return out;
}

/// Parse one fixture and compare its tree against the reference JSON.
fn checkFixture(
    gpa: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected_text: []const u8,
) !void {
    var resource = try fluent.syntax.parse(gpa, source);
    defer resource.deinit();

    var produced: std.Io.Writer.Allocating = .init(gpa);
    defer produced.deinit();
    try fluent.syntax.writeJson(resource, &produced.writer);

    var expected = try std.json.parseFromSlice(std.json.Value, gpa, expected_text, .{});
    defer expected.deinit();
    var actual = try std.json.parseFromSlice(std.json.Value, gpa, produced.written(), .{});
    defer actual.deinit();

    if (!equal(expected.value, actual.value)) {
        try reportDifference(gpa, name, expected.value, actual.value);
        return error.TreeMismatch;
    }
}

/// Structural equality, ignoring the order object keys were written in.
fn equal(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| {
                if (!equal(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!equal(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Print the first entry of the resource that differs.
///
/// Printing whole trees would bury the difference in a fixture with forty
/// messages in it, and the entry is the unit a person debugs in: it maps
/// straight back to one message in the `.ftl` file.
fn reportDifference(
    gpa: std.mem.Allocator,
    name: []const u8,
    expected: std.json.Value,
    actual: std.json.Value,
) !void {
    const want = expected.object.get("body").?.array.items;
    const got = actual.object.get("body").?.array.items;

    for (0..@max(want.len, got.len)) |i| {
        const w: ?std.json.Value = if (i < want.len) want[i] else null;
        const g: ?std.json.Value = if (i < got.len) got[i] else null;
        if (w != null and g != null and equal(w.?, g.?)) continue;

        std.debug.print("conformance: {s}: entry {d} differs\n", .{ name, i });
        try printValue(gpa, "  expected", w);
        try printValue(gpa, "  actual  ", g);
        return;
    }
}

/// Print one JSON value, or `<missing>` when an entry has no counterpart.
fn printValue(gpa: std.mem.Allocator, label: []const u8, value: ?std.json.Value) !void {
    if (value == null) {
        std.debug.print("{s}: <missing>\n", .{label});
        return;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.write(value.?);
    std.debug.print("{s}: {s}\n", .{ label, out.written() });
}
