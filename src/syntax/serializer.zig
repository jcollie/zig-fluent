// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Write a resource back out as FTL.
//!
//! Serializing is not the inverse of parsing and does not try to be. The
//! parser throws away how a file was laid out -- how many spaces the indent
//! was, whether the value began on the `=` line -- because none of it changes
//! what the file means. What comes back is Fluent's canonical formatting, so
//! `serialize` doubles as a formatter: parse a file, write it back, and it is
//! laid out the way every other Fluent tool lays it out.
//!
//! What it does guarantee is that the meaning survives. `parse(serialize(r))`
//! yields a tree equal to `r`, which is the property the round-trip test
//! pins down, and it is what a tool that rewrites translation files needs.
//!
//! ## The one thing that cannot be written
//!
//! A text element ending in a lone carriage return cannot be expressed in FTL
//! and is lost. Text elements have no escape syntax -- that is deliberate,
//! since a translator should be able to type a backslash without thinking --
//! so the only way to write a control character is a string literal inside a
//! placeable. And the newline this serializer must emit to end the entry turns
//! a trailing `\r` into a CRLF, which the parser reads back as a single
//! newline, so the carriage return is gone.
//!
//! Writing it as `{"\u000D"}` instead would preserve the character but change
//! the pattern from one element to two, which turns bidirectional isolation on
//! for it and so changes what the message resolves to. Losing a stray control
//! character is the smaller harm, and a lone carriage return in a translation
//! is a mangled file rather than something anyone meant.
//!
//! ## How indentation is handled
//!
//! The reference serializer builds the text of a pattern and then pushes four
//! spaces after every newline in it, once for each level it is nested inside.
//! Doing that with strings would mean allocating one per nesting level. This
//! writes straight through instead and carries the nesting level as a number:
//! a newline emitted at depth `d` is followed by `4 * d` spaces. That is the
//! same rule stated the other way round, and it needs no allocator at all.

const std = @import("std");

const ast = @import("ast.zig");

pub const Options = struct {
    /// Whether to write out the entries that failed to parse.
    ///
    /// Off by default, matching the reference: a tool that reads a file,
    /// changes a message and writes it back would otherwise be preserving text
    /// it does not understand, in a file it has just rewritten around it. A
    /// formatter that must not lose anything should turn it on.
    with_junk: bool = false,
};

/// Write `resource` as FTL.
pub fn serialize(resource: ast.Resource, w: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    var out: Out = .{ .w = w };
    var state: State = .{};

    for (resource.body) |entry| {
        if (entry == .junk and !options.with_junk) continue;
        try writeEntry(&out, entry, state);
        state = .{
            .wrote_any = true,
            .after_junk = entry == .junk,
            .after_standalone_comment = entry == .comment and entry.comment.level == .comment,
        };
    }
}

test serialize {
    var resource = try parse(std.testing.allocator, "hello   =    Hi\n");
    defer resource.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(resource, &out.writer, .{});

    // Canonical formatting rather than the original layout, which is what
    // makes this a formatter as well as a serializer.
    try std.testing.expectEqualStrings("hello = Hi\n", out.written());
}

/// What has been written so far, as far as the spacing between entries goes.
const State = struct {
    wrote_any: bool = false,
    /// Whether the last entry written was junk.
    after_junk: bool = false,
    /// Whether the last entry written was a `#` comment standing on its own.
    after_standalone_comment: bool = false,
};

/// A writer that knows how deep it is nested and how it ended.
const Out = struct {
    w: *std.Io.Writer,
    depth: usize = 0,
    /// The last two bytes written, so that the entry separator can tell
    /// whether the output is already at a blank line.
    tail: [2]u8 = .{ 0, 0 },

    /// Write text, indenting every line after the first by the current depth.
    fn write(self: *Out, text: []const u8) std.Io.Writer.Error!void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try self.raw(rest[0 .. nl + 1]);
            try self.w.splatByteAll(' ', self.depth * 4);
            if (self.depth != 0) self.tail = .{ self.tail[1], ' ' };
            rest = rest[nl + 1 ..];
        }
        try self.raw(rest);
    }

    /// Write text as it is, without expanding newlines into indentation.
    fn raw(self: *Out, text: []const u8) std.Io.Writer.Error!void {
        if (text.len == 0) return;
        try self.w.writeAll(text);
        self.tail = if (text.len == 1)
            .{ self.tail[1], text[0] }
        else
            .{ text[text.len - 2], text[text.len - 1] };
    }

    /// Whether a blank line has just been written, or nothing has been.
    fn atBlankLine(self: Out) bool {
        return (self.tail[0] == '\n' or self.tail[0] == 0) and self.tail[1] == '\n';
    }
};

/// Whether the first line this entry writes is a comment line.
///
/// True for a standalone comment and for a message or term that has one
/// attached, since an attached comment is written directly above its entry.
fn startsWithComment(entry: ast.Entry) bool {
    return switch (entry) {
        .comment => true,
        .message => |m| m.comment != null,
        .term => |t| t.comment != null,
        .junk => false,
    };
}

/// Write one entry, with the blank line that has to come before it if any
/// does.
fn writeEntry(out: *Out, entry: ast.Entry, state: State) std.Io.Writer.Error!void {
    // An entry that begins with a comment is set off from what came before by
    // a blank line. That is partly how a standalone comment should read -- as
    // introducing what follows rather than trailing what precedes -- but it is
    // also what keeps two comments apart. Consecutive `#` lines are one
    // comment to the parser, so a standalone comment written flush against the
    // comment of the message below it would be read back as a single comment
    // belonging to that message, and an entry would have silently absorbed one
    // that was never about it.
    //
    // Never after junk, though. Junk is the text the parser could not read,
    // written back exactly, and it runs to wherever the next entry began --
    // trailing blank lines and all. A separator after it would be adding a
    // line to the junk itself: reparsing swallows it, and the file grows a
    // line every time it is formatted. The blank-line check does the same job
    // for anything else that already ends in one.
    // And a blank line after a standalone `#` comment, for the same reason
    // read the other way round: a `#` comment belongs to the entry directly
    // beneath it, so a comment that stood alone must not be written flush
    // against whatever comes next, or the next entry adopts it.
    const wants_gap = startsWithComment(entry) or state.after_standalone_comment;

    const separate = state.wrote_any and wants_gap and
        !state.after_junk and !out.atBlankLine();
    if (separate) try out.write("\n");

    switch (entry) {
        .message => |m| {
            if (m.comment) |c| try writeComment(out, c);
            try out.write(m.id.name);
            try out.write(" =");
            if (m.value) |value| try writePattern(out, value);
            for (m.attributes) |a| try writeAttribute(out, a);
            try out.write("\n");
        },
        .term => |t| {
            if (t.comment) |c| try writeComment(out, c);
            try out.write("-");
            try out.write(t.id.name);
            try out.write(" =");
            try writePattern(out, t.value);
            for (t.attributes) |a| try writeAttribute(out, a);
            try out.write("\n");
        },
        .comment => |c| try writeComment(out, c),
        .junk => |j| try out.write(j.content),
    }
}

/// Write a comment, prefixing each of its lines with the right number of `#`.
fn writeComment(out: *Out, comment: ast.Comment) std.Io.Writer.Error!void {
    const prefix = switch (comment.level) {
        .comment => "#",
        .group => "##",
        .resource => "###",
    };

    var lines = std.mem.splitScalar(u8, comment.content, '\n');
    while (lines.next()) |line| {
        try out.write(prefix);
        // An empty line in a comment is written as a bare `#`: `"# "` with a
        // trailing space would be whitespace nobody typed.
        if (line.len != 0) {
            try out.write(" ");
            try out.write(line);
        }
        try out.write("\n");
    }
}

/// Write one attribute, indented under the entry it belongs to.
fn writeAttribute(out: *Out, attribute: ast.Attribute) std.Io.Writer.Error!void {
    try out.write("\n    .");
    try out.write(attribute.id.name);
    try out.write(" =");

    out.depth += 1;
    defer out.depth -= 1;
    try writePattern(out, attribute.value);
}

/// Write a value, on the `=` line or under it as its shape requires.
fn writePattern(out: *Out, pattern: ast.Pattern) std.Io.Writer.Error!void {
    if (shouldStartOnNewLine(pattern)) {
        try out.write("\n");
        try out.raw("    ");
    } else {
        try out.write(" ");
    }

    out.depth += 1;
    defer out.depth -= 1;
    for (pattern.elements) |element| switch (element) {
        .text => |t| try out.write(t),
        .placeable => |e| try writePlaceable(out, e),
    };
}

/// Whether a pattern is laid out under its `=` rather than after it.
///
/// A pattern goes on its own line when it spans lines anyway -- because it
/// contains a newline, or a select expression, which always does. The
/// exception is a pattern whose text begins with `[`, `.` or `*`: those cannot
/// be the first character of an indented continuation line, since each already
/// means something at the start of a line, so such a pattern has to stay on
/// the `=` line where they are unambiguous.
fn shouldStartOnNewLine(pattern: ast.Pattern) bool {
    var multiline = false;
    for (pattern.elements) |element| switch (element) {
        .text => |t| {
            if (std.mem.indexOfScalar(u8, t, '\n') != null) multiline = true;
        },
        .placeable => |e| {
            if (e.* == .select_expression) multiline = true;
        },
    };
    if (!multiline) return false;

    if (pattern.elements.len > 0 and pattern.elements[0] == .text) {
        const text = pattern.elements[0].text;
        if (text.len > 0 and (text[0] == '[' or text[0] == '.' or text[0] == '*')) return false;
    }
    return true;
}

/// Write a placeable, choosing the spacing its contents call for.
fn writePlaceable(out: *Out, expression: *const ast.Expression) std.Io.Writer.Error!void {
    switch (expression.*) {
        // `{{ ... }}`: the braces go together, with no spaces between them.
        .placeable => |inner| {
            try out.write("{");
            try writePlaceable(out, inner);
            try out.write("}");
        },
        // A select expression ends with a newline of its own, so the closing
        // brace lands on a line by itself and must not be preceded by a space.
        .select_expression => {
            try out.write("{ ");
            try writeExpression(out, expression);
            try out.write("}");
        },
        else => {
            try out.write("{ ");
            try writeExpression(out, expression);
            try out.write(" }");
        },
    }
}

/// Write one expression -- the contents of a placeable, without its braces.
pub fn writeExpression(out: *Out, expression: *const ast.Expression) std.Io.Writer.Error!void {
    switch (expression.*) {
        .string_literal => |l| {
            try out.write("\"");
            try out.write(l.value);
            try out.write("\"");
        },
        .number_literal => |l| try out.write(l.value),
        .variable_reference => |id| {
            try out.write("$");
            try out.write(id.name);
        },
        .message_reference => |r| {
            try out.write(r.id.name);
            if (r.attribute) |a| {
                try out.write(".");
                try out.write(a.name);
            }
        },
        .term_reference => |r| {
            try out.write("-");
            try out.write(r.id.name);
            if (r.attribute) |a| {
                try out.write(".");
                try out.write(a.name);
            }
            if (r.arguments) |args| try writeCallArguments(out, args);
        },
        .function_reference => |r| {
            try out.write(r.id.name);
            try writeCallArguments(out, r.arguments);
        },
        .select_expression => |e| {
            try writeExpression(out, e.selector);
            try out.write(" ->");
            for (e.variants) |v| try writeVariant(out, v);
            try out.write("\n");
        },
        .placeable => |inner| try writePlaceable(out, inner),
    }
}

test writeExpression {
    var resource = try parse(std.testing.allocator, "m = { NUMBER($n, minimumFractionDigits: 2) }\n");
    defer resource.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: Out = .{ .w = &out.writer };

    // The expression alone, without the braces a placeable would add.
    const placeable = resource.body[0].message.value.?.elements[0].placeable;
    try writeExpression(&writer, placeable);
    try testing.expectEqualStrings("NUMBER($n, minimumFractionDigits: 2)", out.written());
}

/// Write one variant of a select expression, on a line of its own.
fn writeVariant(out: *Out, variant: ast.Variant) std.Io.Writer.Error!void {
    // The default variant's `*` sits in the column the others indent into, so
    // that the keys themselves stay aligned.
    try out.write(if (variant.default) "\n   *[" else "\n    [");
    switch (variant.key) {
        .identifier => |id| try out.write(id.name),
        .number => |n| try out.write(n.value),
    }
    try out.write("]");

    out.depth += 1;
    defer out.depth -= 1;
    try writePattern(out, variant.value);
}

/// Write a call's arguments, positional ones first as the grammar requires.
fn writeCallArguments(out: *Out, args: ast.CallArguments) std.Io.Writer.Error!void {
    try out.write("(");
    for (args.positional, 0..) |*a, i| {
        if (i != 0) try out.write(", ");
        try writeExpression(out, a);
    }
    for (args.named, 0..) |a, i| {
        if (i != 0 or args.positional.len != 0) try out.write(", ");
        try out.write(a.name.name);
        try out.write(": ");
        switch (a.value) {
            .string => |l| {
                try out.write("\"");
                try out.write(l.value);
                try out.write("\"");
            },
            .number => |l| try out.write(l.value),
        }
    }
    try out.write(")");
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;
const parse = @import("parser.zig").parse;

/// Parse `source`, serialize it, and check the result against `expected`.
fn expectSerialized(source: []const u8, expected: []const u8) !void {
    var resource = try parse(testing.allocator, source);
    defer resource.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try serialize(resource, &out.writer, .{});

    try testing.expectEqualStrings(expected, out.written());
}

test "a simple message keeps its shape" {
    try expectSerialized("hello = Hi\n", "hello = Hi\n");
}

test "layout is normalized rather than preserved" {
    try expectSerialized("hello   =    Hi\n", "hello = Hi\n");
}

test "a multi-line pattern moves under the equals sign" {
    try expectSerialized(
        "multi = First\n  Second\n",
        "multi =\n    First\n    Second\n",
    );
}

test "a pattern beginning with a special character stays on the equals line" {
    // `.` cannot start an indented continuation line -- it would be read as an
    // attribute -- so this pattern cannot be moved down even though it spans
    // lines, and its continuation is indented under the value instead.
    try expectSerialized(
        "leading = .First\n  Second\n",
        "leading = .First\n    Second\n",
    );
}

test "a select expression is laid out with its variants aligned" {
    try expectSerialized("count = { $n ->\n [one] One\n *[other] Many\n }\n",
        \\count =
        \\    { $n ->
        \\        [one] One
        \\       *[other] Many
        \\    }
        \\
    );
}

test "attributes are indented under their message" {
    try expectSerialized("widget =\n .label = Save\n .tooltip = Save the file\n",
        \\widget =
        \\    .label = Save
        \\    .tooltip = Save the file
        \\
    );
}

test "a comment above a message stays with it" {
    try expectSerialized("# Greets.\nhello = Hi\n", "# Greets.\nhello = Hi\n");
}

test "an empty line in a comment is written as a bare hash" {
    try expectSerialized("# One\n#\n# Two\nm = x\n", "# One\n#\n# Two\nm = x\n");
}

test "a standalone comment is kept apart from an attached one" {
    // Without the blank line the two would be consecutive `#` lines, which the
    // parser reads as a single comment belonging to `b`.
    try expectSerialized(
        "# Standalone.\n\n# About b.\nb = two\n",
        "# Standalone.\n\n# About b.\nb = two\n",
    );
}

test "a standalone comment is kept apart from what follows it" {
    // Without the blank line after it, `b` would adopt the comment: adjacency
    // is exactly what attachment means to the parser.
    try expectSerialized(
        "# Standalone.\n\nb = two\n",
        "# Standalone.\n\nb = two\n",
    );
}

test "a blank line already there is not doubled" {
    // Junk carries the blank line that followed it, so the separator before
    // the next comment must not add a second one -- otherwise the file grows
    // a line every time it is formatted.
    var resource = try parse(testing.allocator, "broken = { $x\n\n## Group\nm = v\n");
    defer resource.deinit();

    var once: std.Io.Writer.Allocating = .init(testing.allocator);
    defer once.deinit();
    try serialize(resource, &once.writer, .{ .with_junk = true });

    var again = try parse(testing.allocator, once.written());
    defer again.deinit();
    var twice: std.Io.Writer.Allocating = .init(testing.allocator);
    defer twice.deinit();
    try serialize(again, &twice.writer, .{ .with_junk = true });

    try testing.expectEqualStrings(once.written(), twice.written());
}

test "a standalone comment is set off from what came before" {
    try expectSerialized(
        "a = one\n### About this file.\n",
        "a = one\n\n### About this file.\n",
    );
}

test "junk is dropped unless asked for" {
    var resource = try parse(testing.allocator, "good = yes\nbroken = { $x\n");
    defer resource.deinit();

    var without: std.Io.Writer.Allocating = .init(testing.allocator);
    defer without.deinit();
    try serialize(resource, &without.writer, .{});
    try testing.expectEqualStrings("good = yes\n", without.written());

    var with: std.Io.Writer.Allocating = .init(testing.allocator);
    defer with.deinit();
    try serialize(resource, &with.writer, .{ .with_junk = true });
    try testing.expectEqualStrings("good = yes\nbroken = { $x\n", with.written());
}

test "call arguments keep positional before named" {
    try expectSerialized(
        "m = {NUMBER($n,minimumFractionDigits:2)}\n",
        "m = { NUMBER($n, minimumFractionDigits: 2) }\n",
    );
}

test "term references keep their attribute and arguments" {
    try expectSerialized(
        "m = {-brand(case:\"genitive\")}\n",
        "m = { -brand(case: \"genitive\") }\n",
    );
}

test "a nested placeable keeps both pairs of braces" {
    try expectSerialized("m = {{ $x }}\n", "m = {{ $x }}\n");
}

test "a trailing carriage return cannot be written back" {
    // Pinned rather than fixed: see the note at the top of this file. The
    // parser keeps the `\r`, the serializer emits it, and the newline that
    // ends the entry makes a CRLF of it, so reading the result back loses it.
    var resource = try parse(testing.allocator, "m = value\r");
    defer resource.deinit();
    try testing.expectEqualStrings("value\r", resource.body[0].message.value.?.elements[0].text);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try serialize(resource, &out.writer, .{});
    try testing.expectEqualStrings("m = value\r\n", out.written());

    var again = try parse(testing.allocator, out.written());
    defer again.deinit();
    try testing.expectEqualStrings("value", again.body[0].message.value.?.elements[0].text);
}
