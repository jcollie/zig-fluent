// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A recursive-descent parser for Fluent Translation List syntax.
//!
//! It is a close port of `fluent-syntax`'s `parser.ts`, deliberately so. The
//! grammar in `spec/fluent.ebnf` describes the language but not the recovery,
//! and the recovery is observable: which byte a broken entry stops at decides
//! how much of the file becomes junk, and every Fluent implementation is
//! expected to agree. Where this file departs from the reference it is only to
//! be Zig -- an arena instead of a garbage collector, a tagged union instead of
//! a class hierarchy, a parked annotation instead of an exception with fields.
//!
//! ## Never fails on bad input
//!
//! `parse` returns a `Resource` for any byte sequence at all. A syntax error
//! does not abort the parse: the offending run of source becomes a `Junk`
//! entry carrying the annotation that explains it, the parser skips to
//! something that looks like the start of the next entry, and every message
//! after the break is still parsed. The only error `parse` can return is
//! `OutOfMemory`. That is Fluent's design, and it is the right one for
//! localization: one translator's broken plural should not blank an interface.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const errors = @import("errors.zig");
const Stream = @import("stream.zig").Stream;

/// What the parser's internals can go wrong with. `ParseError` never escapes
/// `parse`; it is caught and turned into junk.
pub const Error = Stream.Error || Allocator.Error;

/// Parse FTL source into a resource.
///
/// The resource copies the source and owns everything reachable from it, so
/// `source` may be freed as soon as this returns.
pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!ast.Resource {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const owned = try a.dupe(u8, source);

    var p: Parser = .{ .arena = a, .stream = Stream.init(owned) };
    const body = try p.parseResource();

    return .{ .arena = arena, .source = owned, .body = body };
}

test parse {
    var resource = try parse(std.testing.allocator,
        \\hello = Hello, world!
        \\broken = { $x
        \\
    );
    defer resource.deinit();

    // The good entry is there...
    try std.testing.expectEqualStrings("hello", resource.body[0].message.id.name);
    // ...and the broken one is junk carrying the reason, rather than an error
    // that would have cost us the whole file.
    try std.testing.expectEqual(ast.Code.E0003, resource.body[1].junk.annotations[0].code);
}

const Parser = struct {
    arena: Allocator,
    stream: Stream,

    // -- the file -----------------------------------------------------------

    /// Read entries until the source runs out.
    fn parseResource(self: *Parser) Allocator.Error![]const ast.Entry {
        var entries: std.ArrayList(ast.Entry) = .empty;
        _ = self.stream.skipBlankBlockCount();

        // A `#` comment directly above a message belongs to that message, but
        // only if the message parses. So a comment is held back for one round
        // and either handed to what follows or emitted on its own.
        var last_comment: ?ast.Comment = null;

        while (self.stream.currentChar() != null) {
            var entry = try self.getEntryOrJunk();
            const blank_lines = self.stream.skipBlankBlockCount();

            if (entry == .comment and entry.comment.level == .comment and
                blank_lines == 0 and self.stream.currentChar() != null)
            {
                // Something follows it immediately; decide next time round.
                if (last_comment) |held| try entries.append(self.arena, .{ .comment = held });
                last_comment = entry.comment;
                continue;
            }

            if (last_comment) |held| {
                switch (entry) {
                    .message => |*m| m.comment = held,
                    .term => |*t| t.comment = held,
                    // Junk gets no comment: the comment was written about
                    // something that did not parse, and is worth keeping as a
                    // comment in its own right.
                    else => try entries.append(self.arena, .{ .comment = held }),
                }
                last_comment = null;
            }

            try entries.append(self.arena, entry);
        }

        if (last_comment) |held| try entries.append(self.arena, .{ .comment = held });
        return entries.toOwnedSlice(self.arena);
    }

    /// Read one entry, or make junk of whatever could not be read.
    fn getEntryOrJunk(self: *Parser) Allocator.Error!ast.Entry {
        const entry_start = self.stream.index;

        if (self.getEntry()) |entry| {
            if (self.stream.expectLineEnd()) {
                return entry;
            } else |err| switch (err) {
                error.ParseError => {},
            }
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {},
        }

        var annotation = self.stream.pending;

        self.stream.skipToNextEntryStart(entry_start);
        const next_entry_start = self.stream.index;
        // The annotation has to point inside the junk it annotates. Recovery
        // can land before the error when the parser had already run past the
        // end of the broken line.
        if (next_entry_start < annotation.position) annotation.position = next_entry_start;

        const annotations = try self.arena.dupe(errors.Annotation, &.{annotation});
        return .{ .junk = .{
            .content = self.stream.source[entry_start..next_entry_start],
            .annotations = annotations,
        } };
    }

    /// Dispatch on the first character, which is what decides the kind.
    fn getEntry(self: *Parser) Error!ast.Entry {
        if (self.stream.currentChar() == '#') return .{ .comment = try self.getComment() };
        if (self.stream.currentChar() == '-') return .{ .term = try self.getTerm() };
        if (self.stream.isIdentifierStart()) return .{ .message = try self.getMessage() };
        return self.stream.fail(.E0002, null);
    }

    // -- entries ------------------------------------------------------------

    /// Read a comment, joining the consecutive lines of the same depth.
    fn getComment(self: *Parser) Error!ast.Comment {
        // -1 until the first line has been read and has said how deep this
        // comment is; after that, every continuation line must be exactly as
        // deep, so that `##` below `#` starts a new comment rather than
        // extending the one above.
        var level: i8 = -1;
        var content: std.ArrayList(u8) = .empty;

        while (true) {
            var i: i8 = -1;
            while (self.stream.currentChar() == '#' and i < (if (level == -1) @as(i8, 2) else level)) {
                _ = self.stream.next();
                i += 1;
            }
            if (level == -1) level = i;

            if (self.stream.currentChar() != '\n') {
                // Exactly one space separates the `#`s from the text, and it
                // is not part of the text. `#comment` is not a comment.
                try self.stream.expectChar(' ');
                while (self.stream.takeChar(notNewline)) |ch| try content.append(self.arena, ch);
            }

            if (self.stream.isNextLineComment(@intCast(level))) {
                try content.append(self.arena, '\n');
                _ = self.stream.next();
            } else break;
        }

        return .{
            .level = switch (level) {
                0 => .comment,
                1 => .group,
                else => .resource,
            },
            .content = try content.toOwnedSlice(self.arena),
        };
    }

    /// Whether `ch` may appear in the body of a comment line.
    fn notNewline(ch: u8) bool {
        return ch != '\n';
    }

    /// Read `id = value` with its attributes.
    fn getMessage(self: *Parser) Error!ast.Message {
        const id = try self.getIdentifier();
        _ = self.stream.skipBlankInline();
        try self.stream.expectChar('=');

        const value = try self.maybeGetPattern();
        const attributes = try self.getAttributes();

        // A message that says nothing and has no attributes is almost always a
        // typo -- an `=` with an empty right-hand side -- and is rejected so
        // that the mistake surfaces rather than resolving to the empty string.
        if (value == null and attributes.len == 0) return self.stream.fail(.E0005, id.name);

        return .{ .id = id, .value = value, .attributes = attributes, .comment = null };
    }

    /// Read `-id = value` with its attributes.
    fn getTerm(self: *Parser) Error!ast.Term {
        try self.stream.expectChar('-');
        const id = try self.getIdentifier();
        _ = self.stream.skipBlankInline();
        try self.stream.expectChar('=');

        // Unlike a message, a term must have a value: it exists to be
        // interpolated, and attributes alone give nothing to interpolate.
        const value = try self.maybeGetPattern() orelse return self.stream.fail(.E0006, id.name);
        const attributes = try self.getAttributes();

        return .{ .id = id, .value = value, .attributes = attributes, .comment = null };
    }

    /// Read one `.name = value`.
    fn getAttribute(self: *Parser) Error!ast.Attribute {
        try self.stream.expectChar('.');
        const id = try self.getIdentifier();
        _ = self.stream.skipBlankInline();
        try self.stream.expectChar('=');
        const value = try self.maybeGetPattern() orelse return self.stream.fail(.E0012, null);
        return .{ .id = id, .value = value };
    }

    /// Read the attributes that follow a message or a term.
    ///
    /// An attribute that does not parse ends the list rather than failing the
    /// entry: the cursor is wound back to before it, the message keeps its
    /// value and whatever attributes were already good, and the broken text
    /// becomes junk on its own. Fluent's reference grammar behaves this way
    /// because it is a parsing expression grammar and `Attribute*` simply
    /// stops matching, and the conformance fixtures record that outcome.
    ///
    /// `fluent-syntax` does not do this -- a broken attribute takes the whole
    /// entry down, which is
    /// [fluent.js#237](https://github.com/projectfluent/fluent.js/issues/237),
    /// and it skips the `leading_dots` fixture on account of it. The
    /// fault-isolating behavior is both the specified one and the one that
    /// matches what Fluent is for, so it is the one implemented here.
    fn getAttributes(self: *Parser) Error![]const ast.Attribute {
        var attributes: std.ArrayList(ast.Attribute) = .empty;
        self.stream.peekBlank();
        while (self.stream.isAttributeStart()) {
            // Where to return to if this attribute turns out to be broken:
            // the end of the last good one, before the whitespace leading up
            // to the `.`, so that the junk starts at the beginning of its line.
            const before = self.stream.index;
            self.stream.skipToPeek();

            const attribute = self.getAttribute() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    self.stream.index = before;
                    self.stream.resetPeek(0);
                    break;
                },
            };

            try attributes.append(self.arena, attribute);
            self.stream.peekBlank();
        }
        return attributes.toOwnedSlice(self.arena);
    }

    /// Read a name: a letter, then letters, digits, `_` and `-`.
    fn getIdentifier(self: *Parser) Error!ast.Identifier {
        const start = self.stream.index;
        _ = try self.stream.takeIdStart();
        while (self.stream.takeIdChar()) |_| {}
        return .{ .name = self.stream.source[start..self.stream.index] };
    }

    // -- patterns -----------------------------------------------------------

    /// An element of a pattern before dedentation, which may still be the
    /// whitespace that began a line. Indents are not part of the AST: they are
    /// trimmed by the common indent and then merged into the text around them,
    /// or dropped if nothing is left of them.
    const RawElement = union(enum) {
        text: []const u8,
        placeable: *const ast.Expression,
        indent: []const u8,
    };

    /// Read a value, distinguishing one that starts on the `=` line from one
    /// that starts on the next line.
    ///
    /// The distinction is not cosmetic. A pattern that begins on a line of its
    /// own has its first line's indentation counted towards the common indent
    /// that gets stripped; one that begins after the `=` does not, because its
    /// first line has no indentation to speak of.
    fn maybeGetPattern(self: *Parser) Error!?ast.Pattern {
        _ = self.stream.peekBlankInline();
        if (self.stream.isValueStart()) {
            self.stream.skipToPeek();
            return try self.getPattern(false);
        }

        _ = self.stream.peekBlankBlockCount();
        if (self.stream.isValueContinuation()) {
            self.stream.skipToPeek();
            return try self.getPattern(true);
        }

        return null;
    }

    /// Read a value, tracking the indent that will be stripped from it.
    fn getPattern(self: *Parser, is_block: bool) Error!ast.Pattern {
        var elements: std.ArrayList(RawElement) = .empty;
        // Tracked as "no indent seen yet" rather than as a number, because
        // there is no natural largest indent to start a minimum from.
        var common_indent: ?usize = null;

        if (is_block) {
            const first_indent = self.stream.skipBlankInline();
            try elements.append(self.arena, .{ .indent = first_indent });
            common_indent = first_indent.len;
        }

        while (self.stream.currentChar()) |ch| {
            switch (ch) {
                '\n' => {
                    const blank_lines = self.stream.peekBlankBlockCount();
                    if (!self.stream.isValueContinuation()) {
                        // A newline not followed by a continuation is where
                        // the pattern ends. There is no terminator to consume.
                        self.stream.resetPeek(0);
                        break;
                    }
                    self.stream.skipToPeek();
                    const indent = self.stream.skipBlankInline();
                    common_indent = @min(common_indent orelse indent.len, indent.len);

                    // The newlines that were skipped are part of the value:
                    // a blank line inside a pattern is a blank line in the
                    // translation. They lead, so that stripping the common
                    // indent from the end of this run takes the spaces.
                    var run: std.ArrayList(u8) = .empty;
                    try run.appendNTimes(self.arena, '\n', blank_lines);
                    try run.appendSlice(self.arena, indent);
                    try elements.append(self.arena, .{ .indent = try run.toOwnedSlice(self.arena) });
                },
                '{' => try elements.append(self.arena, .{ .placeable = try self.getPlaceable() }),
                // A closing brace with nothing open is always a mistake, and
                // saying so beats silently putting it in the translation.
                '}' => return self.stream.fail(.E0027, null),
                else => try elements.append(self.arena, .{ .text = try self.getTextElement() }),
            }
        }

        return .{ .elements = try self.dedent(elements.items, common_indent orelse 0) };
    }

    /// Strip the common indent, merge what is left into the surrounding text,
    /// and trim the trailing whitespace of the pattern as a whole.
    fn dedent(self: *Parser, elements: []const RawElement, common_indent: usize) Error![]const ast.PatternElement {
        var out: std.ArrayList(ast.PatternElement) = .empty;
        // Adjacent text is one element in the AST, so text accumulates here
        // until a placeable or the end of the pattern closes the run.
        var run: std.ArrayList(u8) = .empty;
        var run_open = false;

        for (elements) |element| {
            const text: []const u8 = switch (element) {
                .placeable => |p| {
                    if (run_open) {
                        try out.append(self.arena, .{ .text = try run.toOwnedSlice(self.arena) });
                        run_open = false;
                    }
                    try out.append(self.arena, .{ .placeable = p });
                    continue;
                },
                .text => |t| t,
                // The indent's spaces sit at the end of the run, so removing
                // the common indent means dropping that many trailing bytes.
                .indent => |v| v[0 .. v.len - @min(common_indent, v.len)],
            };
            if (text.len == 0 and element == .indent) continue;

            try run.appendSlice(self.arena, text);
            run_open = true;
        }

        if (run_open) {
            // Whitespace at the very end of a pattern is the newline before
            // the next entry and the indentation that led up to it, not part
            // of the translation.
            //
            // A carriage return is deliberately not trimmed. Fluent's line
            // endings are LF and CRLF, and a CRLF has already been read as the
            // single newline it is, so a `\r` that survives to here is a lone
            // one in the middle of a line -- an ordinary character that the
            // translator wrote, and not this parser's to remove.
            const trimmed = std.mem.trimEnd(u8, run.items, " \n");
            if (trimmed.len != 0) try out.append(self.arena, .{ .text = try self.arena.dupe(u8, trimmed) });
        }

        return out.toOwnedSlice(self.arena);
    }

    /// Read a run of literal text, stopping at a brace or a line end.
    fn getTextElement(self: *Parser) Error![]const u8 {
        const start = self.stream.index;
        while (self.stream.currentChar()) |ch| {
            if (ch == '{' or ch == '}' or ch == '\n') break;
            _ = self.stream.next();
        }
        return self.stream.source[start..self.stream.index];
    }

    // -- placeables and expressions -----------------------------------------

    /// Read `{ expression }`.
    fn getPlaceable(self: *Parser) Error!*const ast.Expression {
        try self.stream.expectChar('{');
        self.stream.skipBlank();
        const expression = try self.getExpression();
        try self.stream.expectChar('}');
        return expression;
    }

    /// Move an expression into the arena and return a pointer to it.
    fn box(self: *Parser, expression: ast.Expression) Error!*const ast.Expression {
        const p = try self.arena.create(ast.Expression);
        p.* = expression;
        return p;
    }

    /// An expression, which is an inline expression unless `->` turns what was
    /// read into the selector of a select expression.
    fn getExpression(self: *Parser) Error!*const ast.Expression {
        const selector = try self.getInlineExpression();
        self.stream.skipBlank();

        if (self.stream.currentChar() == '-') {
            if (self.stream.peek() != '>') {
                self.stream.resetPeek(0);
                return selector;
            }

            // Not every expression may select. The rules come from
            // `spec/valid.md`, and each has a reason a translator can act on.
            switch (selector.*) {
                // A message's value is arbitrary text that may itself contain
                // placeables, so matching on it would be matching on something
                // the translator of *another* message controls.
                .message_reference => |m| return self.stream.fail(
                    if (m.attribute == null) .E0016 else .E0018,
                    null,
                ),
                // A term's value is likewise a pattern; its attributes are the
                // part meant to be selected on, and those are allowed.
                .term_reference => |t| if (t.attribute == null) return self.stream.fail(.E0017, null),
                // `{ { $x } } ->` is a placeable selecting on a placeable,
                // which says nothing the inner one does not.
                .placeable => return self.stream.fail(.E0029, null),
                else => {},
            }

            _ = self.stream.next();
            _ = self.stream.next();

            _ = self.stream.skipBlankInline();
            try self.stream.expectLineEnd();

            const variants = try self.getVariants();
            return self.box(.{ .select_expression = .{ .selector = selector, .variants = variants } });
        }

        // A term attribute is for selecting on, not for printing: it holds a
        // grammatical feature like a gender, which has no rendering of its own.
        if (selector.* == .term_reference and selector.term_reference.attribute != null) {
            return self.stream.fail(.E0019, null);
        }

        return selector;
    }

    /// Read whatever may appear in a placeable other than a select.
    fn getInlineExpression(self: *Parser) Error!*const ast.Expression {
        if (self.stream.currentChar() == '{') {
            return self.box(.{ .placeable = try self.getPlaceable() });
        }

        if (self.stream.isNumberStart()) return self.box(.{ .number_literal = try self.getNumber() });
        if (self.stream.currentChar() == '"') return self.box(.{ .string_literal = try self.getString() });

        if (self.stream.currentChar() == '$') {
            _ = self.stream.next();
            return self.box(.{ .variable_reference = try self.getIdentifier() });
        }

        if (self.stream.currentChar() == '-') {
            _ = self.stream.next();
            const id = try self.getIdentifier();

            var attribute: ?ast.Identifier = null;
            if (self.stream.currentChar() == '.') {
                _ = self.stream.next();
                attribute = try self.getIdentifier();
            }

            var arguments: ?ast.CallArguments = null;
            self.stream.peekBlank();
            if (self.stream.currentPeek() == '(') {
                self.stream.skipToPeek();
                arguments = try self.getCallArguments();
            }

            return self.box(.{ .term_reference = .{ .id = id, .attribute = attribute, .arguments = arguments } });
        }

        if (self.stream.isIdentifierStart()) {
            const id = try self.getIdentifier();
            self.stream.peekBlank();

            if (self.stream.currentPeek() == '(') {
                // Only a function may be called, and Fluent tells a function
                // from a message by its case alone -- so an all-caps name is
                // not a convention here, it is the syntax.
                if (!isFunctionName(id.name)) return self.stream.fail(.E0008, null);
                self.stream.skipToPeek();
                const arguments = try self.getCallArguments();
                return self.box(.{ .function_reference = .{ .id = id, .arguments = arguments } });
            }

            var attribute: ?ast.Identifier = null;
            if (self.stream.currentChar() == '.') {
                _ = self.stream.next();
                attribute = try self.getIdentifier();
            }
            return self.box(.{ .message_reference = .{ .id = id, .attribute = attribute } });
        }

        return self.stream.fail(.E0028, null);
    }

    /// Whether a name is all upper case, which is how a call is recognized.
    fn isFunctionName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!std.ascii.isUpper(name[0])) return false;
        for (name[1..]) |c| {
            if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
        }
        return true;
    }

    // -- calls --------------------------------------------------------------

    const Argument = union(enum) {
        positional: ast.Expression,
        named: ast.NamedArgument,
    };

    /// Read one argument, which is positional unless a `:` follows it.
    fn getCallArgument(self: *Parser) Error!Argument {
        const expression = try self.getInlineExpression();
        self.stream.skipBlank();

        if (self.stream.currentChar() != ':') return .{ .positional = expression.* };

        // `name: value` -- and the name has to be a bare identifier, so that
        // the options a call is given can be read straight off the source
        // rather than depending on what some variable resolves to.
        if (expression.* == .message_reference and expression.message_reference.attribute == null) {
            _ = self.stream.next();
            self.stream.skipBlank();
            const value = try self.getLiteral();
            return .{ .named = .{ .name = expression.message_reference.id, .value = value } };
        }

        return self.stream.fail(.E0009, null);
    }

    /// Read `(a, b, name: "c")`.
    fn getCallArguments(self: *Parser) Error!ast.CallArguments {
        var positional: std.ArrayList(ast.Expression) = .empty;
        var named: std.ArrayList(ast.NamedArgument) = .empty;

        try self.stream.expectChar('(');
        self.stream.skipBlank();

        while (self.stream.currentChar() != ')') {
            switch (try self.getCallArgument()) {
                .named => |arg| {
                    for (named.items) |existing| {
                        if (std.mem.eql(u8, existing.name.name, arg.name.name)) {
                            return self.stream.fail(.E0022, null);
                        }
                    }
                    try named.append(self.arena, arg);
                },
                .positional => |arg| {
                    // Positional after named would make the call's shape
                    // depend on reading it right to left.
                    if (named.items.len > 0) return self.stream.fail(.E0021, null);
                    try positional.append(self.arena, arg);
                },
            }

            self.stream.skipBlank();
            if (self.stream.currentChar() != ',') break;
            _ = self.stream.next();
            self.stream.skipBlank();
        }

        try self.stream.expectChar(')');
        return .{
            .positional = try positional.toOwnedSlice(self.arena),
            .named = try named.toOwnedSlice(self.arena),
        };
    }

    // -- variants -----------------------------------------------------------

    /// Read the `[key]` of a variant: a number or an identifier.
    fn getVariantKey(self: *Parser) Error!ast.VariantKey {
        const ch = self.stream.currentChar() orelse return self.stream.fail(.E0013, null);
        if (std.ascii.isDigit(ch) or ch == '-') return .{ .number = try self.getNumber() };
        return .{ .identifier = try self.getIdentifier() };
    }

    /// Read one variant of a select expression.
    fn getVariant(self: *Parser, has_default: bool) Error!ast.Variant {
        var is_default = false;
        if (self.stream.currentChar() == '*') {
            if (has_default) return self.stream.fail(.E0015, null);
            _ = self.stream.next();
            is_default = true;
        }

        try self.stream.expectChar('[');
        self.stream.skipBlank();
        const key = try self.getVariantKey();
        self.stream.skipBlank();
        try self.stream.expectChar(']');

        const value = try self.maybeGetPattern() orelse return self.stream.fail(.E0012, null);
        return .{ .key = key, .value = value, .default = is_default };
    }

    /// Read every variant, checking that exactly one is the default.
    fn getVariants(self: *Parser) Error![]const ast.Variant {
        var variants: std.ArrayList(ast.Variant) = .empty;
        var has_default = false;

        self.stream.skipBlank();
        while (self.stream.isVariantStart()) {
            const variant = try self.getVariant(has_default);
            if (variant.default) has_default = true;
            try variants.append(self.arena, variant);
            try self.stream.expectLineEnd();
            self.stream.skipBlank();
        }

        if (variants.items.len == 0) return self.stream.fail(.E0011, null);
        // Exactly one variant must be the default, so that resolution can
        // always produce something even when no key matches. This is what
        // makes a select expression total.
        if (!has_default) return self.stream.fail(.E0010, null);

        return variants.toOwnedSlice(self.arena);
    }

    // -- literals -----------------------------------------------------------

    /// Consume one or more digits, failing if there are none.
    fn getDigits(self: *Parser) Error!void {
        var any = false;
        while (self.stream.takeDigit()) |_| any = true;
        if (!any) return self.stream.fail(.E0004, "0-9");
    }

    /// Read a number literal, keeping the text as written.
    fn getNumber(self: *Parser) Error!ast.NumberLiteral {
        const start = self.stream.index;
        if (self.stream.currentChar() == '-') _ = self.stream.next();
        try self.getDigits();
        if (self.stream.currentChar() == '.') {
            _ = self.stream.next();
            try self.getDigits();
        }
        return .{ .value = self.stream.source[start..self.stream.index] };
    }

    /// Read a `"quoted string"`, validating its escapes as it goes.
    fn getString(self: *Parser) Error!ast.StringLiteral {
        try self.stream.expectChar('"');
        const start = self.stream.index;

        while (self.stream.takeChar(isStringChar)) |ch| {
            // The escape is validated now and stored as written. Checking here
            // means the resolver never has to, and keeping the text means a
            // serializer can write the literal back byte for byte.
            if (ch == '\\') try self.getEscapeSequence();
        }

        // A string literal may not span lines: an unterminated one would
        // otherwise swallow the rest of the file.
        if (self.stream.currentChar() == '\n') return self.stream.fail(.E0020, null);

        const value = self.stream.source[start..self.stream.index];
        try self.stream.expectChar('"');
        return .{ .value = value };
    }

    /// Whether `ch` may appear in a string literal unescaped.
    fn isStringChar(ch: u8) bool {
        return ch != '"' and ch != '\n';
    }

    /// Check the escape after a backslash and consume it.
    fn getEscapeSequence(self: *Parser) Error!void {
        const next = self.stream.currentChar() orelse return self.stream.fail(.E0025, "");
        switch (next) {
            '\\', '"' => _ = self.stream.next(),
            'u' => try self.getUnicodeEscapeSequence(4),
            'U' => try self.getUnicodeEscapeSequence(6),
            else => return self.stream.fail(.E0025, self.stream.source[self.stream.index..][0..1]),
        }
    }

    /// Check the hex digits of a `\\u` or `\\U` escape.
    fn getUnicodeEscapeSequence(self: *Parser, digits: usize) Error!void {
        const start = self.stream.index;
        _ = self.stream.next(); // the `u` or `U`

        var i: usize = 0;
        while (i < digits) : (i += 1) {
            if (self.stream.takeHexDigit() == null) {
                // The argument is the sequence as far as it got plus the
                // character that spoiled it, which is what a translator needs
                // to see to find the typo.
                const end = @min(self.stream.index + 1, self.stream.source.len);
                const seen = self.stream.source[start - 1 .. end];
                return self.stream.fail(.E0026, seen);
            }
        }
    }

    /// Read the literal on the right of a named argument.
    fn getLiteral(self: *Parser) Error!ast.Literal {
        if (self.stream.isNumberStart()) return .{ .number = try self.getNumber() };
        if (self.stream.currentChar() == '"') return .{ .string = try self.getString() };
        return self.stream.fail(.E0014, null);
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

/// Parse `source` and check the names of the messages it defines.
fn expectMessages(source: []const u8, expected: []const []const u8) !void {
    var resource = try parse(testing.allocator, source);
    defer resource.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    for (resource.body) |entry| {
        if (entry == .message) try names.append(testing.allocator, entry.message.id.name);
    }
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "a simple message" {
    var resource = try parse(testing.allocator, "hello = Hello, world!\n");
    defer resource.deinit();

    try testing.expectEqual(@as(usize, 1), resource.body.len);
    const message = resource.body[0].message;
    try testing.expectEqualStrings("hello", message.id.name);
    try testing.expectEqualStrings("Hello, world!", message.value.?.elements[0].text);
}

test "junk does not stop the file being parsed" {
    try expectMessages(
        \\before = fine
        \\broken = { $x
        \\after = also fine
        \\
    , &.{ "before", "after" });
}

test "a comment above a message is attached to it" {
    var resource = try parse(testing.allocator, "# Says hello.\nhello = Hi\n");
    defer resource.deinit();

    try testing.expectEqual(@as(usize, 1), resource.body.len);
    try testing.expectEqualStrings("Says hello.", resource.body[0].message.comment.?.content);
}

test "a comment above junk stands alone" {
    var resource = try parse(testing.allocator, "# Orphan.\nbroken = { $x\n");
    defer resource.deinit();

    try testing.expectEqual(@as(usize, 2), resource.body.len);
    try testing.expectEqualStrings("Orphan.", resource.body[0].comment.content);
    try testing.expect(resource.body[1] == .junk);
}

test "a blank line detaches a comment from what follows" {
    var resource = try parse(testing.allocator, "# Standalone.\n\nhello = Hi\n");
    defer resource.deinit();

    try testing.expectEqual(@as(usize, 2), resource.body.len);
    try testing.expect(resource.body[0] == .comment);
    try testing.expectEqual(@as(?ast.Comment, null), resource.body[1].message.comment);
}

test "a multi-line pattern loses its common indent" {
    var resource = try parse(testing.allocator,
        \\multi =
        \\    First line
        \\        Indented further
        \\    Back again
        \\
    );
    defer resource.deinit();

    try testing.expectEqualStrings(
        "First line\n    Indented further\nBack again",
        resource.body[0].message.value.?.elements[0].text,
    );
}

test "a select expression records which variant is the default" {
    var resource = try parse(testing.allocator,
        \\count = { $n ->
        \\    [one] One
        \\   *[other] Many
        \\ }
        \\
    );
    defer resource.deinit();

    const select = resource.body[0].message.value.?.elements[0].placeable.select_expression;
    try testing.expectEqual(@as(usize, 2), select.variants.len);
    try testing.expectEqual(@as(usize, 1), select.defaultIndex());
    try testing.expectEqualStrings("n", select.selector.variable_reference.name);
}

test "a term may not be a selector but its attribute may" {
    var bad = try parse(testing.allocator, "m = { -t ->\n   *[a] A\n }\n");
    defer bad.deinit();
    try testing.expectEqual(ast.Code.E0017, bad.body[0].junk.annotations[0].code);

    var good = try parse(testing.allocator, "m = { -t.case ->\n   *[a] A\n }\n");
    defer good.deinit();
    try testing.expect(good.body[0] == .message);
}

test "a select expression must have exactly one default" {
    var none = try parse(testing.allocator, "m = { $n ->\n    [a] A\n }\n");
    defer none.deinit();
    try testing.expectEqual(ast.Code.E0010, none.body[0].junk.annotations[0].code);

    var two = try parse(testing.allocator, "m = { $n ->\n   *[a] A\n   *[b] B\n }\n");
    defer two.deinit();
    try testing.expectEqual(ast.Code.E0015, two.body[0].junk.annotations[0].code);
}

test "a lower-case callee is not a function" {
    var resource = try parse(testing.allocator, "m = { foo() }\n");
    defer resource.deinit();
    try testing.expectEqual(ast.Code.E0008, resource.body[0].junk.annotations[0].code);
}

test "named arguments must be unique and must follow the positional ones" {
    var duplicate = try parse(testing.allocator, "m = { NUMBER($n, a: 1, a: 2) }\n");
    defer duplicate.deinit();
    try testing.expectEqual(ast.Code.E0022, duplicate.body[0].junk.annotations[0].code);

    var out_of_order = try parse(testing.allocator, "m = { NUMBER(a: 1, $n) }\n");
    defer out_of_order.deinit();
    try testing.expectEqual(ast.Code.E0021, out_of_order.body[0].junk.annotations[0].code);
}

test "an unterminated string literal is caught at the end of the line" {
    var resource = try parse(testing.allocator, "m = { \"oops }\n");
    defer resource.deinit();
    try testing.expectEqual(ast.Code.E0020, resource.body[0].junk.annotations[0].code);
}

test "string literals keep their escapes as written" {
    var resource = try parse(testing.allocator, "m = { \"a\\\"b\" }\n");
    defer resource.deinit();
    const literal = resource.body[0].message.value.?.elements[0].placeable.string_literal;
    try testing.expectEqualStrings("a\\\"b", literal.value);
}

test "an unknown escape is rejected while the literal is scanned" {
    var resource = try parse(testing.allocator, "m = { \"\\x\" }\n");
    defer resource.deinit();
    try testing.expectEqual(ast.Code.E0025, resource.body[0].junk.annotations[0].code);
}

test "a message needs a value or an attribute" {
    var resource = try parse(testing.allocator, "m =\n");
    defer resource.deinit();
    try testing.expectEqual(ast.Code.E0005, resource.body[0].junk.annotations[0].code);

    var attributes_only = try parse(testing.allocator, "m =\n    .label = Hi\n");
    defer attributes_only.deinit();
    try testing.expectEqualStrings("label", attributes_only.body[0].message.attributes[0].id.name);
}

test "a broken attribute becomes junk without taking its message with it" {
    // Fluent's reference grammar keeps the message and makes junk of only the
    // attribute; `fluent-syntax` loses the whole entry, which is a bug it
    // tracks as fluent.js#237.
    var resource = try parse(testing.allocator, "key = Value\n    .Continued\n\nnext = Also fine\n");
    defer resource.deinit();

    try testing.expectEqual(@as(usize, 3), resource.body.len);
    try testing.expectEqualStrings("key", resource.body[0].message.id.name);
    try testing.expectEqualStrings("Value", resource.body[0].message.value.?.elements[0].text);
    try testing.expectEqual(@as(usize, 0), resource.body[0].message.attributes.len);
    try testing.expectEqualStrings("    .Continued\n\n", resource.body[1].junk.content);
    try testing.expectEqualStrings("next", resource.body[2].message.id.name);
}

test "a good attribute before a broken one is kept" {
    var resource = try parse(testing.allocator, "key = Value\n    .good = yes\n    .bad\n");
    defer resource.deinit();

    const message = resource.body[0].message;
    try testing.expectEqual(@as(usize, 1), message.attributes.len);
    try testing.expectEqualStrings("good", message.attributes[0].id.name);
    try testing.expect(resource.body[1] == .junk);
}

test "a term needs a value" {
    var resource = try parse(testing.allocator, "-t =\n    .case = nominative\n");
    defer resource.deinit();
    try testing.expectEqual(ast.Code.E0006, resource.body[0].junk.annotations[0].code);
}

test "CRLF line endings parse as newlines" {
    var resource = try parse(testing.allocator, "a = one\r\nb = two\r\n");
    defer resource.deinit();
    try testing.expectEqual(@as(usize, 2), resource.body.len);
    try testing.expectEqualStrings("one", resource.body[0].message.value.?.elements[0].text);
}

test "an empty resource has no entries" {
    var resource = try parse(testing.allocator, "");
    defer resource.deinit();
    try testing.expectEqual(@as(usize, 0), resource.body.len);
    try testing.expect(!resource.hasJunk());
}

test "the resource owns its source" {
    const source = try testing.allocator.dupe(u8, "hello = Hi\n");
    var resource = try parse(testing.allocator, source);
    defer resource.deinit();
    testing.allocator.free(source);
    // Still readable with the caller's copy gone.
    try testing.expectEqualStrings("Hi", resource.body[0].message.value.?.elements[0].text);
}
