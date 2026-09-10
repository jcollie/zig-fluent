// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Fluent abstract syntax tree.
//!
//! The shape follows Fluent's own data model rather than anything convenient
//! for Zig, because the model is the interoperable part: a tool that reads an
//! AST produced here and writes one for `fluent-syntax` to consume has to
//! agree about what a `Placeable` contains and whether a `Message` may have no
//! value. Where Zig offers something better than the reference -- a tagged
//! union in place of a class hierarchy and a nullable field -- the choice is
//! made here, but nothing is added, removed or renamed.
//!
//! ## Who owns the strings
//!
//! Every slice in the tree points into the arena held by the `Resource` that
//! the tree belongs to, including the copy of the source text that `Resource`
//! keeps. Nothing points at the caller's buffer, so a resource stays valid
//! after the file it was read from has been closed and the read buffer freed --
//! which is what a bundle needs, since it holds resources for the life of the
//! program and the caller almost always read them into a temporary.

const std = @import("std");

const errors = @import("errors.zig");

pub const Annotation = errors.Annotation;
pub const Code = errors.Code;

/// An identifier: a message name, a term name, an attribute name, a variable
/// name, a function name, or an argument name.
pub const Identifier = struct {
    name: []const u8,
};

/// A standalone comment, or one attached to a message or a term.
pub const Comment = struct {
    /// How many `#` the comment was written with.
    pub const Level = enum {
        /// `#` -- documents the message or term it precedes.
        comment,
        /// `##` -- documents the group of entries that follows.
        group,
        /// `###` -- documents the whole file.
        resource,
    };

    level: Level,
    /// The text with the leading `#`s and the single following space removed,
    /// with the lines of a multi-line comment joined by newlines.
    content: []const u8,
};

/// A translation, addressable by name from the application and from other
/// translations.
pub const Message = struct {
    id: Identifier,
    /// A message may have no value of its own, in which case it exists purely
    /// as a holder of attributes -- a widget with a `.label` and a `.tooltip`
    /// and nothing to say by itself.
    value: ?Pattern,
    attributes: []const Attribute,
    /// The `#` comment written directly above, if there was one. It is
    /// attached to the message rather than standing alone in the body.
    comment: ?Comment,
};

/// A translation addressable only from other translations.
///
/// Terms exist so that a translator can factor out a noun and then inflect it
/// at each use -- `-brand-name` with a `.gender` attribute that the sentences
/// around it select on. Unlike a message, a term must have a value, and the
/// application cannot ask for one by name.
pub const Term = struct {
    id: Identifier,
    value: Pattern,
    attributes: []const Attribute,
    comment: ?Comment,
};

/// A named sub-translation of a message or a term, written `.name = value`.
pub const Attribute = struct {
    id: Identifier,
    value: Pattern,
};

/// The value of a message, term, attribute or variant: text with holes in it.
pub const Pattern = struct {
    elements: []const PatternElement,

    /// True when the pattern is a single run of text with no placeables, which
    /// the resolver can return without doing any work.
    pub fn isSimple(self: Pattern) bool {
        return self.elements.len == 1 and self.elements[0] == .text;
    }

    test isSimple {
        const parse = @import("parser.zig").parse;

        var plain = try parse(std.testing.allocator, "m = just text\n");
        defer plain.deinit();
        try std.testing.expect(plain.body[0].message.value.?.isSimple());

        var interpolated = try parse(std.testing.allocator, "m = text and { $x }\n");
        defer interpolated.deinit();
        try std.testing.expect(!interpolated.body[0].message.value.?.isSimple());
    }
};

pub const PatternElement = union(enum) {
    /// Literal text. Adjacent runs are joined during parsing, and the common
    /// indent of a multi-line pattern has already been removed, so what is
    /// here is what the translator meant to write.
    text: []const u8,
    /// A `{ ... }` hole.
    placeable: *const Expression,
};

/// Anything that can appear inside `{ }`.
pub const Expression = union(enum) {
    string_literal: StringLiteral,
    number_literal: NumberLiteral,
    /// `$name`
    variable_reference: Identifier,
    message_reference: MessageReference,
    term_reference: TermReference,
    function_reference: FunctionReference,
    select_expression: SelectExpression,
    /// A placeable nested directly inside another, as in `{ { $x } }`. Fluent
    /// permits it, and the extra layer is kept rather than folded away so that
    /// a serializer can write back what the translator wrote.
    placeable: *const Expression,
};

/// A double-quoted string, `"like this"`.
///
/// `value` is the text **as written**, with its escape sequences intact: the
/// literal `"A"` is stored as the six characters `A`, not as `A`.
/// The parser has already checked that every escape is well-formed, so the
/// resolver can unescape without re-validating, and a serializer can write the
/// literal back out byte for byte. Call `unescape` to get the value itself.
/// U+FFFD, which stands in for a code point that names nothing.
const replacement_character = "\u{FFFD}";

pub const StringLiteral = struct {
    value: []const u8,

    /// Resolve the escape sequences and write the result.
    ///
    /// Only the sequences Fluent defines appear here, because the parser
    /// rejected everything else: `\\`, `\"`, `\uXXXX` and `\UXXXXXX`. A code
    /// point that is not a legal scalar value -- a lone surrogate, or one past
    /// `U+10FFFF` -- is replaced with U+FFFD, matching what `fluent-bundle`
    /// does with the same input, since a translation is not worth aborting a
    /// page render for.
    pub fn unescape(self: StringLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.value.len) {
            const c = self.value[i];
            if (c != '\\') {
                try w.writeByte(c);
                i += 1;
                continue;
            }
            // The parser guarantees a backslash is followed by one of these.
            const kind = self.value[i + 1];
            switch (kind) {
                '\\', '"' => {
                    try w.writeByte(kind);
                    i += 2;
                },
                'u', 'U' => {
                    const digits: usize = if (kind == 'u') 4 else 6;
                    const hex = self.value[i + 2 ..][0..digits];
                    i += 2 + digits;

                    // `u32`, not `u21`: `\U` takes six hex digits, which reach
                    // 0xFFFFFF, and a `u21` stops at 0x1FFFFF. The parser
                    // accepts every one of those digits -- being in range is a
                    // question about the value, not about the syntax -- so
                    // `\UFFFFFF` is a well-formed literal that names nothing,
                    // and parsing it into a `u21` was a panic reachable from a
                    // translation file. A fuzz target found it.
                    const scalar = std.fmt.parseInt(u32, hex, 16) catch {
                        try w.writeAll(replacement_character);
                        continue;
                    };

                    const code_point = std.math.cast(u21, scalar) orelse {
                        try w.writeAll(replacement_character);
                        continue;
                    };

                    var utf8: [4]u8 = undefined;
                    // Refuses a surrogate and anything past U+10FFFF, which is
                    // the rest of what six hex digits can say and nothing
                    // names.
                    const len = std.unicode.utf8Encode(code_point, &utf8) catch {
                        try w.writeAll(replacement_character);
                        continue;
                    };
                    try w.writeAll(utf8[0..len]);
                },
                else => unreachable,
            }
        }
    }

    test unescape {
        var buffer: [64]u8 = undefined;

        var w = std.Io.Writer.fixed(&buffer);
        try (StringLiteral{ .value = "a\\\\b\\\"c\\u0041\\U01F600" }).unescape(&w);
        try std.testing.expectEqualStrings("a\\b\"cA\u{1F600}", w.buffered());

        // An escape that is well-formed but names no character at all becomes
        // U+FFFD rather than failing: `\UFFFFFF` is six valid hex digits.
        for ([_][]const u8{ "\\uD800", "\\U110000", "\\UFFFFFF" }) |literal| {
            w = std.Io.Writer.fixed(&buffer);
            try (StringLiteral{ .value = literal }).unescape(&w);
            try std.testing.expectEqualStrings("\u{FFFD}", w.buffered());
        }
    }
};

/// A number, `1`, `-2` or `3.14`.
///
/// The text is kept rather than a parsed value because the number of digits
/// written after the point is meaningful: `{ NUMBER($n) }` against a literal
/// `1.0` must format as `1.0`, so the literal's own precision becomes the
/// `minimumFractionDigits` of the value it resolves to.
pub const NumberLiteral = struct {
    value: []const u8,

    /// The value as a float.
    pub fn toFloat(self: NumberLiteral) f64 {
        return std.fmt.parseFloat(f64, self.value) catch 0;
    }

    test toFloat {
        try std.testing.expectEqual(@as(f64, 1), (NumberLiteral{ .value = "1" }).toFloat());
        try std.testing.expectEqual(@as(f64, -2.5), (NumberLiteral{ .value = "-2.500" }).toFloat());
    }

    /// How many digits were written after the decimal point.
    pub fn precision(self: NumberLiteral) u8 {
        const dot = std.mem.indexOfScalar(u8, self.value, '.') orelse return 0;
        return @intCast(self.value.len - dot - 1);
    }

    test precision {
        // The digits written are the point: `{ NUMBER(1.0) }` must print
        // "1.0", so the literal's own precision becomes a floor on the value.
        try std.testing.expectEqual(@as(u8, 0), (NumberLiteral{ .value = "1" }).precision());
        try std.testing.expectEqual(@as(u8, 1), (NumberLiteral{ .value = "1.0" }).precision());
        try std.testing.expectEqual(@as(u8, 3), (NumberLiteral{ .value = "-2.500" }).precision());
    }
};

/// `name` or `name.attribute`.
pub const MessageReference = struct {
    id: Identifier,
    attribute: ?Identifier,
};

/// `-name`, `-name.attribute`, or either with `(arguments)`.
pub const TermReference = struct {
    id: Identifier,
    attribute: ?Identifier,
    arguments: ?CallArguments,
};

/// `NAME(arguments)`.
pub const FunctionReference = struct {
    id: Identifier,
    arguments: CallArguments,
};

pub const CallArguments = struct {
    positional: []const Expression,
    named: []const NamedArgument,
};

pub const NamedArgument = struct {
    name: Identifier,
    value: Literal,
};

/// The only things that may be passed by name: Fluent deliberately forbids
/// computing a named argument, so that the set of options a call may be given
/// can be read off the source.
pub const Literal = union(enum) {
    string: StringLiteral,
    number: NumberLiteral,
};

/// `selector -> [key] value ...`
pub const SelectExpression = struct {
    selector: *const Expression,
    variants: []const Variant,

    /// The index of the variant marked `*`. The parser refuses a select
    /// expression without exactly one, so this never fails to find one.
    pub fn defaultIndex(self: SelectExpression) usize {
        for (self.variants, 0..) |v, i| if (v.default) return i;
        unreachable;
    }

    test defaultIndex {
        var resource = try @import("parser.zig").parse(std.testing.allocator,
            \\count = { $n ->
            \\    [one] One
            \\   *[other] Many
            \\ }
            \\
        );
        defer resource.deinit();

        const select = resource.body[0].message.value.?.elements[0].placeable.select_expression;
        try std.testing.expectEqual(@as(usize, 1), select.defaultIndex());
    }
};

pub const Variant = struct {
    key: VariantKey,
    value: Pattern,
    /// Whether this variant was written with a `*`.
    default: bool,
};

pub const VariantKey = union(enum) {
    identifier: Identifier,
    number: NumberLiteral,
};

/// A run of source the parser could not make an entry out of.
///
/// Junk is how Fluent keeps a broken translation from taking the rest of the
/// file with it: the parser records what it could not read, skips to something
/// that looks like the start of the next entry, and carries on. A resource
/// with junk in it still yields every message around the junk.
pub const Junk = struct {
    content: []const u8,
    annotations: []const Annotation,
};

pub const Entry = union(enum) {
    message: Message,
    term: Term,
    comment: Comment,
    junk: Junk,
};

/// A parsed `.ftl` file.
///
/// Owns everything reachable from it. `deinit` frees the whole tree in one
/// call, because the tree is one arena.
pub const Resource = struct {
    arena: std.heap.ArenaAllocator,
    /// The source the tree was parsed from, copied into the arena. Kept
    /// because annotations carry byte offsets into it and are worth nothing
    /// without the text they point at.
    source: []const u8,
    body: []const Entry,

    /// Free the whole tree, which is one arena, in a single call.
    pub fn deinit(self: *Resource) void {
        self.arena.deinit();
        self.* = undefined;
    }

    test deinit {
        // One call frees the whole tree, because the whole tree is one arena.
        var resource = try @import("parser.zig").parse(std.testing.allocator, "m = v\n");
        resource.deinit();
    }

    /// Whether any entry failed to parse.
    pub fn hasJunk(self: Resource) bool {
        for (self.body) |entry| if (entry == .junk) return true;
        return false;
    }

    test hasJunk {
        const parse = @import("parser.zig").parse;

        var good = try parse(std.testing.allocator, "m = v\n");
        defer good.deinit();
        try std.testing.expect(!good.hasJunk());

        var bad = try parse(std.testing.allocator, "m = { $x\n");
        defer bad.deinit();
        try std.testing.expect(bad.hasJunk());
    }
};
