// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `fluent.js`'s structure fixtures: the corpus of things written wrong.
//!
//! The reference suite in `tests/conformance.zig` is the one every
//! implementation is expected to agree on, and it is almost entirely made of
//! files that parse. Where it does have junk in it, the fixtures are generated
//! with the annotations stripped, so nothing in it says *why* an entry was
//! rejected. This corpus does: 62 more `.ftl` files, most of them broken on
//! purpose, paired with trees that name the error code, the message, and the
//! point the parser gave up at.
//!
//! That matters because the codes are the interoperable part. Fluent's tooling
//! -- linters, editor plugins, translation platforms -- keys off `E0016`
//! rather than off the English sentence beside it, and a parser that rejects
//! the right files for the wrong stated reason is wrong in a way no
//! round-trip test can see. It is also the only thing that checks how far a
//! broken entry reaches: junk runs to the start of the next entry, and a
//! parser that recovers a line early or a line late still parses every valid
//! file correctly while losing a message out of a real one.
//!
//! The corpus lives in `fluent.js` rather than in the specification
//! repository, so it arrives as its own pinned dependency. `python-fluent`
//! keeps a copy, but a copy that deliberately differs in one fixture for
//! compatibility with Syntax 0.4, which is why the comparison here is against
//! `fluent.js`.
//!
//! ## Where this parser disagrees on purpose
//!
//! Four fixtures are expected not to match, and all four for one reason: a
//! broken attribute takes the whole entry down in `fluent.js` and does not
//! here. That is [fluent.js#237][], a bug its own maintainers record, and it
//! is why `fluent.js` skips `leading_dots.ftl` when it runs itself against the
//! reference corpus -- the reference parser keeps the message, and so does
//! this one. `divergences` below lists them, and the test fails if one of them
//! ever starts matching, because that would mean the list has gone stale
//! rather than that nothing is wrong.
//!
//! [fluent.js#237]: https://github.com/projectfluent/fluent.js/issues/237
//!
//! ## Spans
//!
//! Every node in these trees carries one, and they are dropped before
//! comparing, for the reason written at the top of `src/syntax/json.zig`: this
//! parser counts bytes and `fluent-syntax` counts UTF-16 code units, so the
//! two disagree about every offset after the first non-ASCII character.
//!
//! Annotations are the exception. Where the parser gave up is worth checking,
//! it is a single point rather than a range, and there are few enough of them
//! -- 89 in the whole corpus -- to convert: the expected offset is counted
//! forward through the fixture's own text as UTF-16 and turned into the byte
//! offset this parser would report.

const std = @import("std");

const fluent = @import("fluent");
const options = @import("structure_options");

const json_tree = @import("json_tree.zig");
const equal = json_tree.equal;
const reportDifference = json_tree.reportDifference;

/// A fixture this parser is expected to disagree with, and what it produces
/// instead.
const Divergence = struct {
    fixture: []const u8,
    /// The body this parser builds, as its `Entry` tags in order, where
    /// `fluent.js` builds junk out of whole entries. Null where the
    /// reference corpus in `tests/conformance.zig` already pins the tree
    /// exactly, which it does for `leading_dots.ftl` -- the fixture both
    /// corpora contain, and the one `fluent.js` skips against the reference.
    entries: ?[]const u8,
};

/// See the note above: every one of these is `fluent.js` failing an entry that
/// this parser, and Fluent's reference parser, recover most of.
const divergences = [_]Divergence{
    .{
        // `key = Value` and then `.label`, with no `=` after it.
        .fixture = "attribute_without_equal_sign.ftl",
        .entries = "message,junk",
    },
    .{
        // Five messages whose attributes have nothing after the `=`. The two
        // with a value of their own keep it; the three without have neither a
        // value nor a good attribute left, which is `E0005` and junk.
        .fixture = "attribute_with_empty_pattern.ftl",
        .entries = "message,junk,junk,message,junk,junk,junk",
    },
    .{
        // `.2 = Foo`, whose attribute name does not begin with a letter.
        .fixture = "non_id_attribute_name.ftl",
        .entries = "message,junk",
    },
    .{
        .fixture = "leading_dots.ftl",
        .entries = null,
    },
};

/// The divergence recorded for `fixture`, if there is one.
fn divergence(fixture: []const u8) ?Divergence {
    for (divergences) |d| {
        if (std.mem.eql(u8, d.fixture, fixture)) return d;
    }
    return null;
}

test "every structure fixture parses to the reference tree" {
    const gpa = std.testing.allocator;
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
        const check = if (divergence(entry.name)) |d|
            checkDivergence(gpa, d, source, expected_text)
        else
            checkFixture(gpa, entry.name, source, expected_text);
        check catch |err| {
            std.debug.print("structure: {s} failed: {t}\n", .{ entry.name, err });
            failures += 1;
        };
    }

    // A directory that turned up empty would otherwise pass in silence, which
    // is the one way this test could stop testing anything without saying so.
    try std.testing.expect(checked >= 50);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

/// Hold a fixture this parser disagrees with to the disagreement it is
/// supposed to have.
///
/// The tree must still differ from the reference -- a fixture that started
/// matching would mean `fluent.js` had fixed its side and this list should
/// lose an entry -- and where the divergence says what this parser builds
/// instead, it must build exactly that.
fn checkDivergence(
    gpa: std.mem.Allocator,
    d: Divergence,
    source: []const u8,
    expected_text: []const u8,
) !void {
    if (try matches(gpa, source, expected_text)) {
        std.debug.print(
            "structure: {s} now matches fluent.js; drop it from `divergences`\n",
            .{d.fixture},
        );
        return error.DivergenceGone;
    }

    const entries = d.entries orelse return;

    var resource = try fluent.syntax.parse(gpa, source);
    defer resource.deinit();

    var produced: std.Io.Writer.Allocating = .init(gpa);
    defer produced.deinit();
    for (resource.body, 0..) |entry, i| {
        if (i > 0) try produced.writer.writeByte(',');
        try produced.writer.writeAll(@tagName(entry));
    }

    try std.testing.expectEqualStrings(entries, produced.written());
}

/// Whether the fixture parses to the reference tree, with nothing printed
/// either way.
fn matches(gpa: std.mem.Allocator, source: []const u8, expected_text: []const u8) !bool {
    var resource = try fluent.syntax.parse(gpa, source);
    defer resource.deinit();

    var produced: std.Io.Writer.Allocating = .init(gpa);
    defer produced.deinit();
    try fluent.syntax.writeJson(resource, &produced.writer, .{ .annotations = true });

    var expected = try std.json.parseFromSlice(std.json.Value, gpa, expected_text, .{});
    defer expected.deinit();
    var actual = try std.json.parseFromSlice(std.json.Value, gpa, produced.written(), .{});
    defer actual.deinit();

    normalize(&expected.value, source);
    return equal(expected.value, actual.value);
}

/// Parse one fixture and compare its tree, annotations and all, against the
/// reference tree, saying where they differ if they do.
fn checkFixture(
    gpa: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    expected_text: []const u8,
) !void {
    if (try matches(gpa, source, expected_text)) return;

    // Only a failing fixture pays for a second parse, and what it buys is the
    // entry the two trees disagree about rather than the two whole trees.
    var resource = try fluent.syntax.parse(gpa, source);
    defer resource.deinit();

    var produced: std.Io.Writer.Allocating = .init(gpa);
    defer produced.deinit();
    try fluent.syntax.writeJson(resource, &produced.writer, .{ .annotations = true });

    var expected = try std.json.parseFromSlice(std.json.Value, gpa, expected_text, .{});
    defer expected.deinit();
    var actual = try std.json.parseFromSlice(std.json.Value, gpa, produced.written(), .{});
    defer actual.deinit();

    normalize(&expected.value, source);
    try reportDifference(gpa, name, expected.value, actual.value);
    return error.TreeMismatch;
}

/// Make a reference tree comparable: drop the spans this writer does not
/// produce, and put the ones it does into the units it produces them in.
fn normalize(value: *std.json.Value, source: []const u8) void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| normalize(item, source),
        .object => |*object| {
            const is_annotation = if (object.get("type")) |t|
                t == .string and std.mem.eql(u8, t.string, "Annotation")
            else
                false;

            if (is_annotation) {
                if (object.getPtr("span")) |span| {
                    if (span.object.getPtr("start")) |start| {
                        start.* = .{ .integer = @intCast(byteOffset(source, start.integer)) };
                    }
                    if (span.object.getPtr("end")) |end| {
                        end.* = .{ .integer = @intCast(byteOffset(source, end.integer)) };
                    }
                }
            } else {
                _ = object.orderedRemove("span");
            }

            var it = object.iterator();
            while (it.next()) |kv| normalize(kv.value_ptr, source);
        },
        else => {},
    }
}

/// The byte offset in `source` of the character `units` UTF-16 code units in.
///
/// An offset past the end of the text -- which is what `fluent-syntax` reports
/// for an entry that ran out of file -- is the length of the text.
fn byteOffset(source: []const u8, units: i64) usize {
    if (units <= 0) return 0;
    const want: usize = @intCast(units);

    var seen: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (seen >= want) return i;
        const length = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
        const end = @min(i + length, source.len);
        const codepoint = std.unicode.utf8Decode(source[i..end]) catch source[i];
        // Everything outside the basic multilingual plane is a surrogate pair,
        // and counts as two of the units `fluent-syntax` measures in.
        seen += if (codepoint > 0xFFFF) 2 else 1;
        i = end;
    }
    return source.len;
}

test byteOffset {
    // ASCII is its own index...
    try std.testing.expectEqual(@as(usize, 3), byteOffset("hello", 3));
    // ...a Finnish ä is two bytes and one unit...
    try std.testing.expectEqual(@as(usize, 4), byteOffset("äiti", 3));
    // ...and an emoji is four bytes and two units.
    try std.testing.expectEqual(@as(usize, 4), byteOffset("🐟x", 2));
    // Past the end is the end.
    try std.testing.expectEqual(@as(usize, 5), byteOffset("hello", 99));
}
