// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! As much YAML as `fluent-rs`'s fixtures are written in, and no more.
//!
//! The resolver fixtures are the one corpus that says what a *bundle* must
//! do rather than what the parser must build, and they are YAML. Zig's
//! standard library has no YAML reader, and pulling in a general one to read
//! 2000 lines of a closed format would be a dependency with far more surface
//! than the job. So this reads the subset those files use, which the corpus
//! itself defines: block mappings, block sequences, `|-` block scalars,
//! double-quoted and plain scalars, `true`/`false`, numbers, and `#` comments.
//!
//! What it does **not** accept is as important, because a reader that quietly
//! mis-parses a fixture reports a passing test that checked nothing. There is
//! no flow style, no anchor, no alias, no tag, no folded scalar, no single
//! quote and no tab; every one of those is an error naming the line rather
//! than something skipped. The corpus was surveyed for each before this was
//! written, and a fixture that grows one will stop the suite instead of
//! slipping through it.
//!
//! The one subtlety worth stating: a block scalar's content is taken by
//! indentation alone, before anything looks for a comment. FTL sources are
//! full of `#` comment lines and of blank lines that decide where an entry
//! ends, and both have to survive into the string the bundle is given.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    number: f64,
    list: []const Value,
    map: []const Pair,

    /// The value of `key`, or null. Mapping keys keep the order they were
    /// written in, and there are never enough of them for that to matter.
    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .map) return null;
        for (self.map) |pair| {
            if (std.mem.eql(u8, pair.key, key)) return pair.value;
        }
        return null;
    }

    /// The value of `key` when it is a string, or null.
    pub fn string_(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// The value of `key` when it is a boolean, or null.
    pub fn bool_(self: Value, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        return if (v == .boolean) v.boolean else null;
    }

    /// The items of `key` when it is a list, or an empty slice. A key that is
    /// absent and a key holding nothing are the same thing to every caller
    /// here, which is why this does not distinguish them.
    pub fn list_(self: Value, key: []const u8) []const Value {
        const v = self.get(key) orelse return &.{};
        return if (v == .list) v.list else &.{};
    }
};

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const Error = error{
    /// A construct outside the subset: flow style, an anchor, a tag, a folded
    /// scalar, a single-quoted string, or a tab.
    Unsupported,
    /// Indentation or punctuation that is not valid YAML at all.
    Malformed,
} || Allocator.Error;

/// Parse `text`. Everything returned points into `arena` or into `text`.
pub fn parse(arena: Allocator, text: []const u8) Error!Value {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }

    var reader: Reader = .{ .arena = arena, .lines = lines.items };
    const first = reader.nextContent() orelse return Value{ .map = &.{} };
    return reader.parseBlock(indentOf(reader.lines[first]));
}

const Reader = struct {
    arena: Allocator,
    lines: []const []const u8,
    index: usize = 0,

    /// The index of the next line with something on it, leaving the cursor
    /// where it was. Blank lines and whole-line comments are not content.
    fn nextContent(self: *Reader) ?usize {
        var i = self.index;
        while (i < self.lines.len) : (i += 1) {
            const body = std.mem.trim(u8, self.lines[i], " ");
            if (body.len == 0) continue;
            if (body[0] == '#') continue;
            return i;
        }
        return null;
    }

    /// A mapping or a sequence, whichever begins at `indent`.
    fn parseBlock(self: *Reader, indent: usize) Error!Value {
        const i = self.nextContent() orelse return Value{ .map = &.{} };
        const line = self.lines[i];
        if (indentOf(line) != indent) return error.Malformed;
        const body = line[indent..];
        return if (body[0] == '-' and (body.len == 1 or body[1] == ' '))
            self.parseSequence(indent)
        else
            self.parseMapping(indent);
    }

    fn parseMapping(self: *Reader, indent: usize) Error!Value {
        var pairs: std.ArrayList(Pair) = .empty;

        while (self.nextContent()) |i| {
            const line = self.lines[i];
            const line_indent = indentOf(line);
            if (line_indent < indent) break;
            if (line_indent > indent) return error.Malformed;

            const body = line[indent..];
            if (body[0] == '-') break;

            const colon = findKeyEnd(body) orelse return error.Malformed;
            const key = body[0..colon];
            const rest = std.mem.trim(u8, body[colon + 1 ..], " ");
            self.index = i + 1;

            const value: Value = if (rest.len == 0)
                try self.parseNested(indent)
            else if (std.mem.eql(u8, rest, "|-"))
                .{ .string = try self.parseBlockScalar(indent) }
            else
                try scalar(self.arena, rest);

            try pairs.append(self.arena, .{ .key = key, .value = value });
        }

        return .{ .map = try pairs.toOwnedSlice(self.arena) };
    }

    fn parseSequence(self: *Reader, indent: usize) Error!Value {
        var items: std.ArrayList(Value) = .empty;

        while (self.nextContent()) |i| {
            const line = self.lines[i];
            if (indentOf(line) != indent) break;

            const body = line[indent..];
            if (body[0] != '-' or (body.len > 1 and body[1] != ' ')) break;

            self.index = i + 1;
            const rest = std.mem.trim(u8, body[1..], " ");
            const value: Value = if (rest.len == 0)
                try self.parseNested(indent)
            else
                try scalar(self.arena, rest);

            try items.append(self.arena, value);
        }

        return .{ .list = try items.toOwnedSlice(self.arena) };
    }

    /// The block belonging to a key or a dash written at `indent`, which has
    /// to be indented further than it is.
    fn parseNested(self: *Reader, indent: usize) Error!Value {
        const i = self.nextContent() orelse return Value{ .map = &.{} };
        const nested = indentOf(self.lines[i]);
        if (nested <= indent) return error.Malformed;
        return self.parseBlock(nested);
    }

    /// A `|-` scalar: every following line indented past `indent`, with the
    /// common indent removed and the trailing newlines stripped.
    ///
    /// Blank lines inside belong to the scalar, and so does anything that
    /// looks like a comment: this is the text of an FTL file, where a `#` is
    /// a Fluent comment and a blank line ends an entry.
    fn parseBlockScalar(self: *Reader, indent: usize) Error![]const u8 {
        var end = self.index;
        var block_indent: ?usize = null;
        while (end < self.lines.len) : (end += 1) {
            const line = self.lines[end];
            if (std.mem.trim(u8, line, " ").len == 0) continue;
            const line_indent = indentOf(line);
            if (line_indent <= indent) break;
            if (block_indent == null) block_indent = line_indent;
        }

        const strip = block_indent orelse {
            self.index = end;
            return "";
        };

        var out: std.ArrayList(u8) = .empty;
        var first = true;
        for (self.lines[self.index..end]) |line| {
            if (!first) try out.append(self.arena, '\n');
            first = false;
            if (std.mem.trim(u8, line, " ").len == 0) continue;
            if (indentOf(line) < strip) return error.Malformed;
            try out.appendSlice(self.arena, line[strip..]);
        }
        self.index = end;

        // `|-` strips every trailing line break, which is what makes an FTL
        // source end in the newline its last entry needs and nothing more.
        return std.mem.trimEnd(u8, out.items, "\n");
    }
};

/// How many spaces a line begins with. A tab is not indentation in YAML, and
/// silently treating one as a space is how a file parses to the wrong shape.
fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// The offset of the `:` that ends a key, or null when the line is not a
/// mapping entry. A `:` inside a quoted key would need more than this; no
/// fixture has one, and a key that needs quoting is rejected below.
fn findKeyEnd(body: []const u8) ?usize {
    for (body, 0..) |c, i| {
        if (c == ':' and (i + 1 == body.len or body[i + 1] == ' ')) return i;
        if (c == '"' or c == '\'' or c == '{' or c == '[') return null;
    }
    return null;
}

/// One scalar written on the same line as its key or dash.
fn scalar(arena: Allocator, text: []const u8) Error!Value {
    if (text[0] == '\'') return error.Unsupported;
    if (text[0] == '{' or text[0] == '[') return error.Unsupported;
    if (text[0] == '&' or text[0] == '*' or text[0] == '!') return error.Unsupported;
    if (text[0] == '>') return error.Unsupported;
    if (std.mem.indexOfScalar(u8, text, '\t') != null) return error.Unsupported;

    if (text[0] == '"') return .{ .string = try unquote(arena, text) };
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (std.fmt.parseFloat(f64, text)) |n| return .{ .number = n } else |_| {}

    // A plain scalar runs to a ` #` comment, and is otherwise itself.
    const comment = std.mem.indexOf(u8, text, " #");
    return .{ .string = if (comment) |c| std.mem.trimEnd(u8, text[0..c], " ") else text };
}

/// A double-quoted scalar, with the escapes the corpus uses.
fn unquote(arena: Allocator, text: []const u8) Error![]const u8 {
    if (text.len < 2 or text[text.len - 1] != '"') return error.Malformed;
    const body = text[1 .. text.len - 1];

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '\\') {
            try out.append(arena, body[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) return error.Malformed;
        switch (body[i]) {
            'n' => try out.append(arena, '\n'),
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            '0' => try out.append(arena, 0),
            '"', '\\', '/' => try out.append(arena, body[i]),
            'u' => {
                if (i + 4 >= body.len) return error.Malformed;
                const code = std.fmt.parseInt(u21, body[i + 1 ..][0..4], 16) catch
                    return error.Malformed;
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(code, &buffer) catch return error.Malformed;
                try out.appendSlice(arena, buffer[0..n]);
                i += 4;
            },
            else => return error.Unsupported,
        }
        i += 1;
    }
    return out.items;
}

// -- tests ------------------------------------------------------------------

fn parseForTest(arena: Allocator, text: []const u8) !Value {
    return parse(arena, text);
}

test "a mapping of scalars" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseForTest(arena.allocator(),
        \\name: Errors
        \\useIsolating: false
        \\count: 3
        \\quoted: "a ⁨b⁩ c"
    );

    try std.testing.expectEqualStrings("Errors", doc.string_("name").?);
    try std.testing.expectEqual(false, doc.bool_("useIsolating").?);
    try std.testing.expectEqual(@as(f64, 3), doc.get("count").?.number);
    try std.testing.expectEqualStrings("a \u{2068}b\u{2069} c", doc.string_("quoted").?);
}

test "sequences of mappings and of scalars" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseForTest(arena.allocator(),
        \\functions:
        \\  - CONCAT
        \\  - SUM
        \\suites:
        \\  -
        \\    name: One
        \\  -
        \\    name: Two
    );

    const functions = doc.list_("functions");
    try std.testing.expectEqual(@as(usize, 2), functions.len);
    try std.testing.expectEqualStrings("SUM", functions[1].string);

    const suites = doc.list_("suites");
    try std.testing.expectEqual(@as(usize, 2), suites.len);
    try std.testing.expectEqualStrings("Two", suites[1].string_("name").?);
}

test "a block scalar keeps its blank lines, its comments and its deeper indent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // The `#` line and the blank line are Fluent's, not YAML's: a comment
    // documents the entry beneath it and a blank line ends an entry, so a
    // reader that dropped either would hand the bundle a different file.
    const doc = try parseForTest(arena.allocator(),
        \\source: |-
        \\  # A comment
        \\  foo = Foo
        \\      .attr = Attr
        \\
        \\  bar = Bar
        \\name: after
    );

    try std.testing.expectEqualStrings(
        "# A comment\nfoo = Foo\n    .attr = Attr\n\nbar = Bar",
        doc.string_("source").?,
    );
    try std.testing.expectEqualStrings("after", doc.string_("name").?);
}

test "comments and blank lines between entries are not content" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseForTest(arena.allocator(),
        \\# leading comment
        \\
        \\bundle:
        \\  # about the locales
        \\  locales:
        \\    - en-US
    );

    try std.testing.expectEqualStrings("en-US", doc.get("bundle").?.list_("locales")[0].string);
}

test "what is outside the subset is an error rather than a guess" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectError(error.Unsupported, parseForTest(gpa, "locales: [en-US]\n"));
    try std.testing.expectError(error.Unsupported, parseForTest(gpa, "name: 'single'\n"));
    try std.testing.expectError(error.Unsupported, parseForTest(gpa, "source: >\n  folded\n"));
    try std.testing.expectError(error.Unsupported, parseForTest(gpa, "base: &anchor\n"));
}
