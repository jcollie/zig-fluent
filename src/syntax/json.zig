// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Write a resource as Fluent's interchange JSON.
//!
//! Fluent publishes its abstract syntax tree as a JSON shape, and the project
//! ships a set of `.ftl` files paired with the tree each one must produce.
//! That pairing is the only cross-implementation conformance test Fluent has,
//! and this file is what lets `zig build test` take it: the tree built here is
//! written out in the reference shape and compared against the reference file.
//!
//! It is worth having for its own sake too. A tool written against
//! `fluent-syntax` -- a linter, a translation-platform importer -- reads this
//! JSON, so anything in this repository can feed one without reimplementing it.
//!
//! Spans are not written, deliberately. They are optional in the model, and
//! this parser counts bytes where `fluent-syntax` counts UTF-16 code units, so
//! a span written here would not compare equal to the reference for any file
//! with a non-ASCII character in it. The one exception is the point an
//! annotation reports, which `Options.annotations` writes in bytes and says so.
//!
//! Annotations are an empty array by default, because the reference fixtures
//! are generated with them stripped. `fluent.js` keeps a second corpus that
//! does record them -- what code each broken entry is blamed on, and where --
//! and `Options.annotations` is what lets `zig build test` take that one too.

const std = @import("std");

const ast = @import("ast.zig");

/// What to include beyond the tree itself.
pub const Options = struct {
    /// Whether to write out the annotations that say why an entry became junk,
    /// rather than an empty array.
    ///
    /// Each one carries its code, the arguments the code interpolates, the
    /// message `fluent-syntax` words it with, and a zero-width span at the
    /// byte offset the parser gave up at. That offset is the one place this
    /// writer emits a position at all, and it is in bytes: a consumer
    /// comparing it against `fluent-syntax`, which counts UTF-16 code units,
    /// has to convert.
    annotations: bool = false,
};

/// Write `resource` as JSON in Fluent's interchange shape.
pub fn write(resource: ast.Resource, w: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try writeResource(&s, resource, options);
}

test write {
    var resource = try @import("parser.zig").parse(std.testing.allocator, "hello = Hi\n");
    defer resource.deinit();

    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(resource, &w, .{});

    try std.testing.expectEqualStrings(
        \\{"type":"Resource","body":[{"type":"Message","id":{"type":"Identifier","name":"hello"},"value":{"type":"Pattern","elements":[{"type":"TextElement","value":"Hi"}]},"attributes":[],"comment":null}]}
    , w.buffered());
}

/// The `Resource` node, which is the whole file.
fn writeResource(s: *std.json.Stringify, resource: ast.Resource, options: Options) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Resource");
    try s.objectField("body");
    try s.beginArray();
    for (resource.body) |entry| try writeEntry(s, entry, options);
    try s.endArray();
    try s.endObject();
}

/// One entry: a message, a term, a standalone comment, or junk.
fn writeEntry(s: *std.json.Stringify, entry: ast.Entry, options: Options) std.Io.Writer.Error!void {
    switch (entry) {
        .message => |m| {
            try s.beginObject();
            try field(s, "type", "Message");
            try s.objectField("id");
            try writeIdentifier(s, m.id);
            try s.objectField("value");
            if (m.value) |p| try writePattern(s, p) else try s.write(null);
            try s.objectField("attributes");
            try writeAttributes(s, m.attributes);
            try s.objectField("comment");
            if (m.comment) |c| try writeComment(s, c) else try s.write(null);
            try s.endObject();
        },
        .term => |t| {
            try s.beginObject();
            try field(s, "type", "Term");
            try s.objectField("id");
            try writeIdentifier(s, t.id);
            try s.objectField("value");
            try writePattern(s, t.value);
            try s.objectField("attributes");
            try writeAttributes(s, t.attributes);
            try s.objectField("comment");
            if (t.comment) |c| try writeComment(s, c) else try s.write(null);
            try s.endObject();
        },
        .comment => |c| try writeComment(s, c),
        .junk => |j| {
            try s.beginObject();
            try field(s, "type", "Junk");
            try s.objectField("annotations");
            try s.beginArray();
            if (options.annotations) for (j.annotations) |a| try writeAnnotation(s, a);
            try s.endArray();
            try field(s, "content", j.content);
            try s.endObject();
        },
    }
}

/// One annotation: why an entry became junk, and where the parser gave up.
///
/// The shape is `fluent-syntax`'s, down to the `arguments` array that is empty
/// for most codes and holds one string for the few whose message interpolates
/// something. The span is zero-width, as `fluent-syntax` writes it, and is a
/// byte offset rather than a UTF-16 one; see `Options.annotations`.
fn writeAnnotation(s: *std.json.Stringify, annotation: ast.Annotation) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Annotation");
    try field(s, "code", annotation.code.name());
    try s.objectField("arguments");
    try s.beginArray();
    if (annotation.argument) |argument| try s.write(argument);
    try s.endArray();

    // The message is printed rather than returned, and an argument taken from
    // the source puts no bound on its length, so it goes out through an
    // escaping writer instead of a slice handed to `Stringify`.
    try s.objectField("message");
    try s.beginWriteRaw();
    try s.writer.writeByte('"');
    var escaping: Escaping = .init(s.writer);
    try annotation.writeMessage(&escaping.writer);
    try escaping.writer.flush();
    try s.writer.writeByte('"');
    s.endWriteRaw();

    try s.objectField("span");
    try s.beginObject();
    try field(s, "type", "Span");
    try s.objectField("start");
    try s.write(annotation.position);
    try s.objectField("end");
    try s.write(annotation.position);
    try s.endObject();
    try s.endObject();
}

test "an annotation naming bytes that are not text is still valid JSON" {
    const gpa = std.testing.allocator;

    // `\` followed by a lone UTF-8 continuation byte. The parser rejects the
    // escape and quotes what it found, so the byte lands inside the message.
    var resource = try @import("parser.zig").parse(gpa, "m = { \"a\\\xa8b\" }\n");
    defer resource.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(resource, &out.writer, .{ .annotations = true });

    // The whole point: a consumer can still read it.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();

    const junk = parsed.value.object.get("body").?.array.items[0].object;
    const annotation = junk.get("annotations").?.array.items[0].object;
    try std.testing.expectEqualStrings("E0025", annotation.get("code").?.string);
    try std.testing.expectEqualStrings(
        "Unknown escape sequence: \\\u{FFFD}.",
        annotation.get("message").?.string,
    );
}

/// A writer that JSON-escapes everything written through it into another.
///
/// It exists for annotation messages, which are the one string here that
/// arrives as a series of writes rather than as a finished slice. It carries
/// no buffer of its own, so every write is escaped straight into the target
/// and there is never anything buffered to lose.
///
/// Anything that is not valid UTF-8 becomes U+FFFD. That is not tidiness: an
/// annotation message interpolates text the *source* chose -- the escape
/// sequence in `Unknown escape sequence: \xNN` is whatever bytes followed the
/// backslash -- and a `.ftl` file is reached by the same path a user's display
/// name is, so those bytes are not necessarily text at all. Writing them
/// through would produce a JSON string that is not valid JSON, which a fuzz
/// run found in about ten seconds. `Stringify` answers the same problem for a
/// finished slice by writing it as an array of numbers instead of a string;
/// that is no use here, where the bad bytes are in the middle of a sentence.
const Escaping = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,

    /// What an unencodable byte is written as, already encoded.
    const replacement = "\u{FFFD}";

    fn init(out: *std.Io.Writer) Escaping {
        return .{
            .out = out,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Escaping = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.write(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.write(pattern);
        return written + pattern.len * splat;
    }

    /// Escape one run, a character at a time, so that a bad byte costs the
    /// character it is part of rather than the rest of the message.
    ///
    /// A multi-byte character split across two writes would be two
    /// replacements. Nothing splits one -- `writeMessage` hands each piece of
    /// a sentence over whole -- and the result of being wrong about that is a
    /// message with a U+FFFD in it rather than anything worse.
    fn write(self: *Escaping, bytes: []const u8) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                try self.out.writeAll(replacement);
                i += 1;
                continue;
            };
            if (i + length > bytes.len or
                !std.unicode.utf8ValidateSlice(bytes[i..][0..length]))
            {
                try self.out.writeAll(replacement);
                i += 1;
                continue;
            }
            try std.json.Stringify.encodeJsonStringChars(bytes[i..][0..length], .{}, self.out);
            i += length;
        }
    }
};

test Escaping {
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    var escaping: Escaping = .init(&out);
    try escaping.writer.print("a \"quoted\" \\ tab\t", .{});
    try escaping.writer.flush();

    try std.testing.expectEqualStrings("a \\\"quoted\\\" \\\\ tab\\t", out.buffered());
}

test "Escaping replaces what is not text" {
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    var escaping: Escaping = .init(&out);
    // A lone continuation byte, a truncated sequence, and a good character
    // between them. Only the bad bytes are lost.
    try escaping.writer.writeAll("a\xa8b\xe2\x82c\u{00e4}");
    try escaping.writer.flush();

    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}c\u{00e4}", out.buffered());
}

/// A comment, whose node type says how many `#` it was written with.
fn writeComment(s: *std.json.Stringify, comment: ast.Comment) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", switch (comment.level) {
        .comment => "Comment",
        .group => "GroupComment",
        .resource => "ResourceComment",
    });
    try field(s, "content", comment.content);
    try s.endObject();
}

/// The `.name = value` attributes of a message or term.
fn writeAttributes(s: *std.json.Stringify, attributes: []const ast.Attribute) std.Io.Writer.Error!void {
    try s.beginArray();
    for (attributes) |a| {
        try s.beginObject();
        try field(s, "type", "Attribute");
        try s.objectField("id");
        try writeIdentifier(s, a.id);
        try s.objectField("value");
        try writePattern(s, a.value);
        try s.endObject();
    }
    try s.endArray();
}

/// An `Identifier` node, which is how every name is written.
fn writeIdentifier(s: *std.json.Stringify, id: ast.Identifier) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Identifier");
    try field(s, "name", id.name);
    try s.endObject();
}

/// A `Pattern`: the text and placeables that make up a value.
fn writePattern(s: *std.json.Stringify, pattern: ast.Pattern) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Pattern");
    try s.objectField("elements");
    try s.beginArray();
    for (pattern.elements) |element| switch (element) {
        .text => |t| {
            try s.beginObject();
            try field(s, "type", "TextElement");
            try field(s, "value", t);
            try s.endObject();
        },
        .placeable => |e| try writePlaceable(s, e),
    };
    try s.endArray();
    try s.endObject();
}

/// A `Placeable`, the `{ ... }` wrapper around an expression.
fn writePlaceable(s: *std.json.Stringify, expression: *const ast.Expression) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Placeable");
    try s.objectField("expression");
    try writeExpression(s, expression);
    try s.endObject();
}

/// Whatever sits inside a placeable, by its own node type.
fn writeExpression(s: *std.json.Stringify, expression: *const ast.Expression) std.Io.Writer.Error!void {
    switch (expression.*) {
        .string_literal => |l| {
            try s.beginObject();
            try field(s, "type", "StringLiteral");
            try field(s, "value", l.value);
            try s.endObject();
        },
        .number_literal => |l| {
            try s.beginObject();
            try field(s, "type", "NumberLiteral");
            try field(s, "value", l.value);
            try s.endObject();
        },
        .variable_reference => |id| {
            try s.beginObject();
            try field(s, "type", "VariableReference");
            try s.objectField("id");
            try writeIdentifier(s, id);
            try s.endObject();
        },
        .message_reference => |r| {
            try s.beginObject();
            try field(s, "type", "MessageReference");
            try s.objectField("id");
            try writeIdentifier(s, r.id);
            try s.objectField("attribute");
            if (r.attribute) |a| try writeIdentifier(s, a) else try s.write(null);
            try s.endObject();
        },
        .term_reference => |r| {
            try s.beginObject();
            try field(s, "type", "TermReference");
            try s.objectField("id");
            try writeIdentifier(s, r.id);
            try s.objectField("attribute");
            if (r.attribute) |a| try writeIdentifier(s, a) else try s.write(null);
            try s.objectField("arguments");
            if (r.arguments) |args| try writeCallArguments(s, args) else try s.write(null);
            try s.endObject();
        },
        .function_reference => |r| {
            try s.beginObject();
            try field(s, "type", "FunctionReference");
            try s.objectField("id");
            try writeIdentifier(s, r.id);
            try s.objectField("arguments");
            try writeCallArguments(s, r.arguments);
            try s.endObject();
        },
        .select_expression => |e| {
            try s.beginObject();
            try field(s, "type", "SelectExpression");
            try s.objectField("selector");
            try writeExpression(s, e.selector);
            try s.objectField("variants");
            try s.beginArray();
            for (e.variants) |v| {
                try s.beginObject();
                try field(s, "type", "Variant");
                try s.objectField("key");
                switch (v.key) {
                    .identifier => |id| try writeIdentifier(s, id),
                    .number => |n| {
                        try s.beginObject();
                        try field(s, "type", "NumberLiteral");
                        try field(s, "value", n.value);
                        try s.endObject();
                    },
                }
                try s.objectField("value");
                try writePattern(s, v.value);
                try s.objectField("default");
                try s.write(v.default);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
        },
        // A placeable nested straight inside another keeps its own wrapper, so
        // that `{ { $x } }` round-trips as the two braces it was written with.
        .placeable => |inner| try writePlaceable(s, inner),
    }
}

/// The positional and named arguments of a call.
fn writeCallArguments(s: *std.json.Stringify, args: ast.CallArguments) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "CallArguments");
    try s.objectField("positional");
    try s.beginArray();
    for (args.positional) |*a| try writeExpression(s, a);
    try s.endArray();
    try s.objectField("named");
    try s.beginArray();
    for (args.named) |a| {
        try s.beginObject();
        try field(s, "type", "NamedArgument");
        try s.objectField("name");
        try writeIdentifier(s, a.name);
        try s.objectField("value");
        switch (a.value) {
            .string => |l| {
                try s.beginObject();
                try field(s, "type", "StringLiteral");
                try field(s, "value", l.value);
                try s.endObject();
            },
            .number => |l| {
                try s.beginObject();
                try field(s, "type", "NumberLiteral");
                try field(s, "value", l.value);
                try s.endObject();
            },
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// A string-valued object member, which is most of what this file writes.
fn field(s: *std.json.Stringify, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try s.objectField(name);
    try s.write(value);
}

test "a message is written in the reference shape" {
    const parse = @import("parser.zig").parse;
    var resource = try parse(std.testing.allocator, "hello = Hi\n");
    defer resource.deinit();

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(resource, &w, .{});

    try std.testing.expectEqualStrings(
        \\{"type":"Resource","body":[{"type":"Message","id":{"type":"Identifier","name":"hello"},"value":{"type":"Pattern","elements":[{"type":"TextElement","value":"Hi"}]},"attributes":[],"comment":null}]}
    , w.buffered());
}
