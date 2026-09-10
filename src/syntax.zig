// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fluent Translation List syntax: the parser, the tree it builds, and the
//! errors it reports.
//!
//! This half of the library is useful on its own. A linter, an editor plugin,
//! a translation-memory importer or a tool that reorders a file all want the
//! tree and nothing else, and none of them pay for the resolver by importing
//! this namespace, because Zig only analyses what is referenced.

const parser = @import("syntax/parser.zig");

pub const ast = @import("syntax/ast.zig");

pub const Annotation = ast.Annotation;
pub const Code = ast.Code;
pub const Resource = ast.Resource;

/// Parse FTL source into a resource. Never fails on malformed input: what
/// cannot be parsed becomes `Junk` and the rest of the file is read anyway.
pub const parse = parser.parse;

/// Serialize a resource back to FTL. Writes Fluent's canonical formatting
/// rather than reproducing the original layout, so it doubles as a formatter.
pub const serialize = @import("syntax/serializer.zig").serialize;
pub const SerializeOptions = @import("syntax/serializer.zig").Options;

/// Write a resource as Fluent's interchange JSON.
pub const writeJson = @import("syntax/json.zig").write;

test {
    _ = @import("syntax/ast.zig");
    _ = @import("syntax/errors.zig");
    _ = @import("syntax/json.zig");
    _ = @import("syntax/parser.zig");
    _ = @import("syntax/serializer.zig");
    _ = @import("syntax/stream.zig");

    // See the note in `root.zig`: this is what makes the doctests nested
    // inside the AST's types run.
    const std = @import("std");
    std.testing.refAllDecls(ast);
    std.testing.refAllDecls(@This());
}
