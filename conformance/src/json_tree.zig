// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Comparing a parsed tree against a reference tree, and saying where they
//! differ.
//!
//! Both conformance suites compare trees as parsed JSON rather than as text,
//! because the reference files were written by a different program and there
//! is no reason for the two to agree about key order or spacing -- only about
//! content. This is what they share.

const std = @import("std");

/// Structural equality, ignoring the order object keys were written in.
pub fn equal(a: std.json.Value, b: std.json.Value) bool {
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

test equal {
    const gpa = std.testing.allocator;

    // The same object with its keys written in the other order is the same
    // object, which is the whole reason this function exists.
    var a = try std.json.parseFromSlice(std.json.Value, gpa, "{\"x\":1,\"y\":[2]}", .{});
    defer a.deinit();
    var b = try std.json.parseFromSlice(std.json.Value, gpa, "{\"y\":[2],\"x\":1}", .{});
    defer b.deinit();
    try std.testing.expect(equal(a.value, b.value));

    var c = try std.json.parseFromSlice(std.json.Value, gpa, "{\"y\":[3],\"x\":1}", .{});
    defer c.deinit();
    try std.testing.expect(!equal(a.value, c.value));
}

/// Print the first entry of the resource that differs.
///
/// Printing whole trees would bury the difference in a fixture with forty
/// messages in it, and the entry is the unit a person debugs in: it maps
/// straight back to one message in the `.ftl` file.
pub fn reportDifference(
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
