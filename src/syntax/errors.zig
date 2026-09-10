// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parse errors, by the codes the Fluent project assigns them.
//!
//! The codes are not an implementation detail. Fluent's tooling -- linters,
//! editor plugins, translation platforms -- keys off `E0016` rather than off
//! the English sentence next to it, so the numbering here matches
//! `fluent-syntax`'s `errors.ts` exactly and must keep matching it. The
//! sentences are reproduced for the same reason: a tool that shows a parse
//! error to a translator should show them the wording they will find when they
//! search for it.
//!
//! `E0023` is absent from the list because Fluent retired it; the gap is
//! deliberate and is left as it is so that the remaining numbers do not shift.

const std = @import("std");

/// The reason a single entry failed to parse.
pub const Code = enum {
    /// Generic error.
    E0001,
    /// Expected an entry start.
    E0002,
    /// Expected a particular token, named by the annotation's argument.
    E0003,
    /// Expected a character from a range, named by the annotation's argument.
    E0004,
    /// A message has neither a value nor attributes.
    E0005,
    /// A term has no value.
    E0006,
    /// Keyword cannot end with a whitespace.
    E0007,
    /// The callee has to be an upper-case identifier or a term.
    E0008,
    /// The argument name has to be a simple identifier.
    E0009,
    /// No variant was marked as the default with `*`.
    E0010,
    /// A select expression has no variants at all.
    E0011,
    /// Expected a value.
    E0012,
    /// Expected a variant key.
    E0013,
    /// Expected a literal.
    E0014,
    /// More than one variant was marked as the default.
    E0015,
    /// Message references cannot be used as selectors.
    E0016,
    /// Terms cannot be used as selectors.
    E0017,
    /// Attributes of messages cannot be used as selectors.
    E0018,
    /// Attributes of terms cannot be used as placeables.
    E0019,
    /// Unterminated string expression.
    E0020,
    /// Positional arguments must not follow named arguments.
    E0021,
    /// Named arguments must be unique.
    E0022,
    /// Cannot access variants of a message.
    E0024,
    /// Unknown escape sequence.
    E0025,
    /// Invalid Unicode escape sequence.
    E0026,
    /// Unbalanced closing brace in a text element.
    E0027,
    /// Expected an inline expression.
    E0028,
    /// Expected a simple expression as a selector.
    E0029,

    /// The code as it is written down, e.g. `"E0016"`.
    pub fn name(code: Code) []const u8 {
        return @tagName(code);
    }
};

/// A parse error attached to the `Junk` it produced.
///
/// `argument` carries the one piece of context some of the messages
/// interpolate -- the token that was expected, the identifier that was left
/// without a value. It points into the arena of the resource that owns this
/// annotation, or into a string literal, and so lives exactly as long as the
/// resource does.
pub const Annotation = struct {
    code: Code,
    argument: ?[]const u8 = null,
    /// Byte offset into the source at which the parser gave up.
    position: usize,

    /// Write the human-readable message for this annotation.
    ///
    /// The wording is `fluent-syntax`'s, so that an error a translator sees
    /// here is one they can search for and find Fluent's own documentation of.
    pub fn writeMessage(self: Annotation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const arg = self.argument orelse "";
        switch (self.code) {
            .E0001 => try w.writeAll("Generic error"),
            .E0002 => try w.writeAll("Expected an entry start"),
            .E0003 => try w.print("Expected token: \"{s}\"", .{arg}),
            .E0004 => try w.print("Expected a character from range: \"{s}\"", .{arg}),
            .E0005 => try w.print("Expected message \"{s}\" to have a value or attributes", .{arg}),
            .E0006 => try w.print("Expected term \"-{s}\" to have a value", .{arg}),
            .E0007 => try w.writeAll("Keyword cannot end with a whitespace"),
            .E0008 => try w.writeAll("The callee has to be an upper-case identifier or a term"),
            .E0009 => try w.writeAll("The argument name has to be a simple identifier"),
            .E0010 => try w.writeAll("Expected one of the variants to be marked as default (*)"),
            .E0011 => try w.writeAll("Expected at least one variant after \"->\""),
            .E0012 => try w.writeAll("Expected value"),
            .E0013 => try w.writeAll("Expected variant key"),
            .E0014 => try w.writeAll("Expected literal"),
            .E0015 => try w.writeAll("Only one variant can be marked as default (*)"),
            .E0016 => try w.writeAll("Message references cannot be used as selectors"),
            .E0017 => try w.writeAll("Terms cannot be used as selectors"),
            .E0018 => try w.writeAll("Attributes of messages cannot be used as selectors"),
            .E0019 => try w.writeAll("Attributes of terms cannot be used as placeables"),
            .E0020 => try w.writeAll("Unterminated string expression"),
            .E0021 => try w.writeAll("Positional arguments must not follow named arguments"),
            .E0022 => try w.writeAll("Named arguments must be unique"),
            .E0024 => try w.writeAll("Cannot access variants of a message."),
            .E0025 => try w.print("Unknown escape sequence: \\{s}.", .{arg}),
            .E0026 => try w.print("Invalid Unicode escape sequence: {s}.", .{arg}),
            .E0027 => try w.writeAll("Unbalanced closing brace in TextElement."),
            .E0028 => try w.writeAll("Expected an inline expression"),
            .E0029 => try w.writeAll("Expected simple expression as selector"),
        }
    }

    /// `{f}` prints `E0016: Message references cannot be used as selectors`.
    pub fn format(self: Annotation, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: ", .{self.code.name()});
        try self.writeMessage(w);
    }
};

test "annotation messages interpolate their argument" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Annotation{ .code = .E0005, .argument = "hello", .position = 0 }).format(&w);
    try std.testing.expectEqualStrings(
        "E0005: Expected message \"hello\" to have a value or attributes",
        w.buffered(),
    );
}

test "annotation messages without an argument ignore it" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Annotation{ .code = .E0027, .position = 3 }).format(&w);
    try std.testing.expectEqualStrings(
        "E0027: Unbalanced closing brace in TextElement.",
        w.buffered(),
    );
}
