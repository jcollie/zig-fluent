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
//! Two deliberate omissions, both matching the reference fixtures. Spans are
//! not written: they are optional in the model, and this parser counts bytes
//! where `fluent-syntax` counts UTF-16 code units, so they would not compare
//! equal for any file with a non-ASCII character in it. Annotations are
//! written as an empty array: the fixtures are generated with them stripped,
//! since their wording is not part of what implementations agree on.

const std = @import("std");

const ast = @import("ast.zig");

/// Write `resource` as JSON in Fluent's interchange shape.
pub fn write(resource: ast.Resource, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    try writeResource(&s, resource);
}

fn writeResource(s: *std.json.Stringify, resource: ast.Resource) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Resource");
    try s.objectField("body");
    try s.beginArray();
    for (resource.body) |entry| try writeEntry(s, entry);
    try s.endArray();
    try s.endObject();
}

fn writeEntry(s: *std.json.Stringify, entry: ast.Entry) std.Io.Writer.Error!void {
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
            try s.endArray();
            try field(s, "content", j.content);
            try s.endObject();
        },
    }
}

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

fn writeIdentifier(s: *std.json.Stringify, id: ast.Identifier) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Identifier");
    try field(s, "name", id.name);
    try s.endObject();
}

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

fn writePlaceable(s: *std.json.Stringify, expression: *const ast.Expression) std.Io.Writer.Error!void {
    try s.beginObject();
    try field(s, "type", "Placeable");
    try s.objectField("expression");
    try writeExpression(s, expression);
    try s.endObject();
}

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
    try write(resource, &w);

    try std.testing.expectEqualStrings(
        \\{"type":"Resource","body":[{"type":"Message","id":{"type":"Identifier","name":"hello"},"value":{"type":"Pattern","elements":[{"type":"TextElement","value":"Hi"}]},"attributes":[],"comment":null}]}
    , w.buffered());
}
