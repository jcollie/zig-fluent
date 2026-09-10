// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning a parsed pattern into the text a person reads.
//!
//! The rules are Fluent's, and this follows `fluent-bundle`'s resolver closely
//! for the same reason the parser follows its parser: the behavior is
//! observable and implementations are expected to agree about it.
//!
//! ## It always produces something
//!
//! No failure here empties a message. A missing variable renders as
//! `{$name}`, an unknown message as `{name}`, a select expression whose
//! selector went wrong falls to its default variant -- and in every case the
//! rest of the sentence is still built. This is not leniency for its own sake:
//! a localization system sits between an application and everyone using it,
//! and a translation with one hole in it is worth far more than a blank
//! screen. Errors are reported through an out-parameter for whoever wants to
//! know, and ignored by whoever does not.
//!
//! ## What stops it running away
//!
//! Two limits, both from the reference. A pattern already being resolved
//! cannot be resolved again inside itself, which catches `a = { b }` and
//! `b = { a }`. And a single call may expand a hundred placeables, which is
//! what stops a message from referring to one that refers to two that refer to
//! four -- the shape that turns a few lines of translation into a gigabyte of
//! output, and which is a real attack when translations are user-supplied.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("syntax/ast.zig");
const bundle_mod = @import("bundle.zig");
const number_format = @import("number_format.zig");
const plural = @import("plural.zig");
const value_mod = @import("value.zig");

const Args = value_mod.Args;
const Bundle = bundle_mod.Bundle;
const Value = value_mod.Value;

/// How many placeables one call to `format` may expand.
///
/// The reference's number, and the reason for it is the "billion laughs"
/// shape: ten messages, each referring to the next ten times, is a hundred
/// million expansions from eleven short lines. A translation file is data, and
/// on a platform where translators submit their own it is untrusted data.
pub const max_placeables = 100;

/// Unicode's first-strong isolate and pop-directional-isolate.
///
/// A right-to-left name dropped into a left-to-right sentence, or the reverse,
/// will otherwise drag the punctuation around it to the wrong end of the line.
/// Wrapping each interpolation tells the bidirectional algorithm to work the
/// inserted text out on its own and put it back as one unit.
const first_strong_isolate = "\u{2068}";
const pop_directional_isolate = "\u{2069}";

pub const Error = error{
    OutOfMemory,
    /// The placeable budget ran out. Fatal to the whole call rather than to
    /// one placeable: carrying on would be doing the expensive thing that the
    /// budget exists to prevent.
    TooManyPlaceables,
};

pub const Scope = struct {
    bundle: *const Bundle,
    /// Freed all at once when the call returns. Every string built here lives
    /// in it, so nothing needs freeing individually and nothing outlives the
    /// call that made it.
    arena: Allocator,
    /// The caller's allocator, used only for the error list.
    ///
    /// Deliberately not the arena: the list belongs to the caller, who created
    /// it before this call and will free it afterwards, and an arena that goes
    /// away when the call returns cannot be the one that allocated it. Every
    /// name stored in an error points into a resource or into a string
    /// literal, so nothing in the list points into the arena either.
    gpa: Allocator,
    /// The arguments the caller passed.
    args: Args,
    /// The arguments a term was called with, while one is being resolved.
    ///
    /// Non-null means "inside a term", which changes what a missing variable
    /// means: a term's parameters are its whole world, and one it was not
    /// given is a silent `{$name}` rather than an error, because the term may
    /// legitimately be used both ways.
    params: ?Args = null,
    errors: ?*bundle_mod.Errors = null,
    /// The patterns currently being resolved, by the identity of their element
    /// slice. A pattern that turns up twice is a cycle.
    dirty: std.ArrayList([*]const ast.PatternElement) = .empty,
    placeables: usize = 0,

    /// Release the bookkeeping the scope allocated.
    ///
    /// The strings it built are the arena's business and go with it.
    pub fn deinit(self: *Scope) void {
        self.dirty.deinit(self.arena);
    }

    test deinit {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();

        var scope: Scope = .{
            .bundle = &bundle,
            .arena = arena.allocator(),
            .gpa = std.testing.allocator,
            .args = &.{},
        };
        scope.deinit();
    }

    /// Record a problem, if the caller asked for them.
    ///
    /// `name` must outlive the call: it points into a resource or a string
    /// literal, never into the arena, because the error list does not go away
    /// when the arena does.
    fn report(self: *Scope, kind: bundle_mod.Error.Kind, name: []const u8) void {
        const errors = self.errors orelse return;
        errors.append(self.gpa, .{ .kind = kind, .name = name }) catch {};
    }
};

/// Resolve a pattern and write the result.
///
/// The entry point for the whole resolver. A pattern that cannot be resolved
/// at all -- only the placeable budget can do that -- writes the `{???}`
/// fallback, so this still produces text.
pub fn write(scope: *Scope, pattern: ast.Pattern, w: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
    const resolved = resolvePattern(scope, pattern) catch |err| switch (err) {
        error.TooManyPlaceables => {
            scope.report(.too_many_placeables, "");
            try w.writeAll("{???}");
            return;
        },
        else => |e| return e,
    };
    try writeValue(scope, resolved, w);
}

test write {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    defer bundle.deinit();
    bundle.use_isolating = false;
    try bundle.addResource("m = Hello, { $name }!\n", .{}, null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scope: Scope = .{
        .bundle = &bundle,
        .arena = arena.allocator(),
        .gpa = std.testing.allocator,
        .args = &.{.{ .name = "name", .value = .{ .string = "Ada" } }},
    };
    defer scope.deinit();

    var buffer: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&scope, bundle.getMessage("m").?.value.?, &w);
    try std.testing.expectEqualStrings("Hello, Ada!", w.buffered());
}

/// Resolve a pattern to a string value.
fn resolvePattern(scope: *Scope, pattern: ast.Pattern) Error!Value {
    // A pattern with nothing in it but text needs no work at all, and this is
    // the overwhelmingly common case: most messages are a sentence.
    if (pattern.elements.len == 0) return .{ .string = "" };
    if (pattern.isSimple()) return .{ .string = try transform(scope, pattern.elements[0].text) };

    const identity = pattern.elements.ptr;
    for (scope.dirty.items) |seen| {
        if (seen == identity) {
            scope.report(.cyclic_reference, "");
            return .{ .none = "???" };
        }
    }
    try scope.dirty.append(scope.arena, identity);
    defer _ = scope.dirty.pop();

    var out: std.Io.Writer.Allocating = .init(scope.arena);

    // Isolation is for interpolations sitting inside surrounding text. A
    // pattern that is nothing but one placeable has no surroundings to be
    // confused with, and wrapping it would put invisible characters into a
    // value the application may be about to compare or store.
    const isolate = scope.bundle.use_isolating and pattern.elements.len > 1;

    for (pattern.elements) |element| {
        switch (element) {
            .text => |text| out.writer.writeAll(try transform(scope, text)) catch return error.OutOfMemory,
            .placeable => |expression| {
                scope.placeables += 1;
                if (scope.placeables > max_placeables) return error.TooManyPlaceables;

                // An allocating writer fails only when the allocator does, so
                // `WriteFailed` from one of these is `OutOfMemory` restated.
                if (isolate) out.writer.writeAll(first_strong_isolate) catch return error.OutOfMemory;
                const resolved = try resolveExpression(scope, expression);
                writeValue(scope, resolved, &out.writer) catch return error.OutOfMemory;
                if (isolate) out.writer.writeAll(pop_directional_isolate) catch return error.OutOfMemory;
            },
        }
    }

    return .{ .string = out.written() };
}

/// Run the bundle's text transform, if it has one.
///
/// The hook exists for pseudolocalization: replacing every letter with an
/// accented one, or padding every string by thirty percent, to find the
/// hard-coded English and the layouts that break in German before a translator
/// ever sees them.
fn transform(scope: *Scope, text: []const u8) Error![]const u8 {
    const f = scope.bundle.transform orelse return text;
    var out: std.Io.Writer.Allocating = .init(scope.arena);
    f(text, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// Resolve whatever was inside a placeable.
fn resolveExpression(scope: *Scope, expression: *const ast.Expression) Error!Value {
    return switch (expression.*) {
        .string_literal => |literal| blk: {
            var out: std.Io.Writer.Allocating = .init(scope.arena);
            literal.unescape(&out.writer) catch return error.OutOfMemory;
            break :blk .{ .string = out.written() };
        },
        .number_literal => |literal| .{
            .number = .{
                .value = literal.toFloat(),
                // A literal's own precision is meaningful: `{ NUMBER(1.0) }` must
                // print `1.0`, so the digits written become the floor.
                .options = .{ .minimum_fraction_digits = literal.precision() },
            },
        },
        .variable_reference => |id| resolveVariable(scope, id.name),
        .message_reference => |reference| resolveMessageReference(scope, reference),
        .term_reference => |reference| resolveTermReference(scope, reference),
        .function_reference => |reference| resolveFunctionReference(scope, reference),
        .select_expression => |select| resolveSelect(scope, select),
        .placeable => |inner| resolveExpression(scope, inner),
    };
}

/// Look up `$name` in the term's parameters, or in the caller's arguments.
fn resolveVariable(scope: *Scope, name: []const u8) Value {
    if (scope.params) |params| {
        // Inside a term. Its parameters are all it can see, and one it was not
        // given is not an error: the same term is often used both with
        // arguments and without.
        if (value_mod.find(params, name)) |v| return v;
        return .{ .none = dollarName(scope, name) };
    }

    if (value_mod.find(scope.args, name)) |v| return v;
    scope.report(.unknown_variable, name);
    return .{ .none = dollarName(scope, name) };
}

/// The `$name` label a missing variable renders as.
fn dollarName(scope: *Scope, name: []const u8) []const u8 {
    return std.fmt.allocPrint(scope.arena, "${s}", .{name}) catch "???";
}

/// Resolve `name` or `name.attribute`.
fn resolveMessageReference(scope: *Scope, reference: ast.MessageReference) Error!Value {
    const message = scope.bundle.getMessage(reference.id.name) orelse {
        scope.report(.unknown_message, reference.id.name);
        return .{ .none = reference.id.name };
    };

    if (reference.attribute) |attribute| {
        const pattern = message.attribute(attribute.name) orelse {
            scope.report(.unknown_attribute, attribute.name);
            return .{ .none = try std.fmt.allocPrint(scope.arena, "{s}.{s}", .{
                reference.id.name,
                attribute.name,
            }) };
        };
        return resolvePattern(scope, pattern);
    }

    const pattern = message.value orelse {
        scope.report(.missing_value, reference.id.name);
        return .{ .none = reference.id.name };
    };
    return resolvePattern(scope, pattern);
}

/// Resolve `-name`, with its arguments in scope for the duration.
fn resolveTermReference(scope: *Scope, reference: ast.TermReference) Error!Value {
    const term = scope.bundle.getTerm(reference.id.name) orelse {
        scope.report(.unknown_term, reference.id.name);
        return .{ .none = try std.fmt.allocPrint(scope.arena, "-{s}", .{reference.id.name}) };
    };

    // A term's arguments are evaluated in the scope that called it, before the
    // scope is swapped, so `-term($n)` passes the caller's `$n`.
    const arguments = if (reference.arguments) |call|
        try resolveNamedArguments(scope, call)
    else
        &.{};

    const pattern = if (reference.attribute) |attribute|
        term.attribute(attribute.name) orelse {
            scope.report(.unknown_attribute, attribute.name);
            return .{ .none = try std.fmt.allocPrint(scope.arena, "-{s}.{s}", .{
                reference.id.name,
                attribute.name,
            }) };
        }
    else
        term.value.?;

    const saved = scope.params;
    scope.params = arguments;
    defer scope.params = saved;

    return resolvePattern(scope, pattern);
}

/// Evaluate the named arguments of a call, in the caller's scope.
fn resolveNamedArguments(scope: *Scope, call: ast.CallArguments) Error!Args {
    const arguments = try scope.arena.alloc(value_mod.Argument, call.named.len);
    for (call.named, arguments) |named, *out| {
        out.* = .{
            .name = named.name.name,
            .value = switch (named.value) {
                .string => |literal| blk: {
                    var text: std.Io.Writer.Allocating = .init(scope.arena);
                    literal.unescape(&text.writer) catch return error.OutOfMemory;
                    break :blk .{ .string = text.written() };
                },
                .number => |literal| .{ .number = .{
                    .value = literal.toFloat(),
                    .options = .{ .minimum_fraction_digits = literal.precision() },
                } },
            },
        };
    }
    return arguments;
}

/// Call a function with its arguments already resolved.
fn resolveFunctionReference(scope: *Scope, reference: ast.FunctionReference) Error!Value {
    const function = scope.bundle.getFunction(reference.id.name) orelse {
        scope.report(.unknown_function, reference.id.name);
        return .{ .none = try std.fmt.allocPrint(scope.arena, "{s}()", .{reference.id.name}) };
    };

    const positional = try scope.arena.alloc(Value, reference.arguments.positional.len);
    for (reference.arguments.positional, positional) |*expression, *out| {
        out.* = try resolveExpression(scope, expression);
    }

    return function(.{
        .arena = scope.arena,
        .gpa = scope.gpa,
        .bundle = scope.bundle,
        .errors = scope.errors,
        .name = reference.id.name,
        .positional = positional,
        .named = try resolveNamedArguments(scope, reference.arguments),
    });
}

/// Choose a variant, falling to the default when nothing matches.
fn resolveSelect(scope: *Scope, select: ast.SelectExpression) Error!Value {
    const selector = try resolveExpression(scope, select.selector);

    // A selector that did not resolve carries no information, so there is
    // nothing to match on and the default is the honest answer.
    if (selector != .none) {
        for (select.variants) |variant| {
            if (matches(scope, selector, variant.key)) return resolvePattern(scope, variant.value);
        }
    }

    return resolvePattern(scope, select.variants[select.defaultIndex()].value);
}

/// Whether a variant key selects this value.
///
/// The interesting case is the third: a number against a word. That is the
/// plural rule, and it is what lets a translator write `[one]` and `[few]` and
/// have them mean what they mean in their own language rather than in English.
fn matches(scope: *Scope, selector: Value, key: ast.VariantKey) bool {
    switch (key) {
        .number => |literal| return switch (selector) {
            .number => |number| number.value == literal.toFloat(),
            else => false,
        },
        .identifier => |id| switch (selector) {
            .string => |text| return std.mem.eql(u8, text, id.name),
            .number => |number| {
                const category = plural.Category.fromName(id.name) orelse return false;
                return pluralCategory(scope, number) == category;
            },
            else => return false,
        },
    }
}

/// Which plural category a number falls into, for the bundle's locale.
///
/// Cardinal unless the application said the number was a rank rather than a
/// count; see `value.Number.plural_kind`.
///
/// The number has to be written out first, because CLDR's rules are about the
/// digits that will be shown rather than the value -- English's `one` is "one
/// integer digit and no fraction digits", so `1.0` is not it. Only the digit
/// options are carried over: `Intl.PluralRules` takes no `style`, so a
/// currency amount pluralizes as the bare number it is, and the reference does
/// the same.
fn pluralCategory(scope: *Scope, number: value_mod.Number) plural.Category {
    const plain: number_format.Formatter = .{
        .options = .{
            .minimum_fraction_digits = number.options.minimum_fraction_digits,
            .maximum_fraction_digits = number.options.maximum_fraction_digits,
            .minimum_significant_digits = number.options.minimum_significant_digits,
            .maximum_significant_digits = number.options.maximum_significant_digits,
            .use_grouping = false,
        },
    };

    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    plain.format(number.value, &w) catch return .other;

    return plural.select(
        &scope.bundle.locale,
        number.plural_kind,
        plural.Operands.fromDecimal(w.buffered()),
    );
}

/// Write a resolved value as the text it stands for.
pub fn writeValue(scope: *Scope, v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .string => |text| try w.writeAll(text),
        // The braces are the point: they make a value that could not be
        // resolved look wrong to whoever sees it, rather than looking like
        // something the translator wrote.
        .none => |label| try w.print("{{{s}}}", .{label}),
        .number => |number| try scope.bundle.numberFormatter(number.options).format(number.value, w),
        .datetime => |moment| try scope.bundle.writeDateTime(moment, w),
    }
}

test writeValue {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    defer bundle.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scope: Scope = .{
        .bundle = &bundle,
        .arena = arena.allocator(),
        .gpa = std.testing.allocator,
        .args = &.{},
    };
    defer scope.deinit();

    var buffer: [64]u8 = undefined;

    var w = std.Io.Writer.fixed(&buffer);
    try writeValue(&scope, .{ .string = "plain" }, &w);
    try std.testing.expectEqualStrings("plain", w.buffered());

    w = std.Io.Writer.fixed(&buffer);
    try writeValue(&scope, .num(1234.5), &w);
    try std.testing.expectEqualStrings("1,234.5", w.buffered());

    // A value that could not be resolved renders inside braces, so that it
    // looks wrong to whoever sees it rather than like something a translator
    // wrote.
    w = std.Io.Writer.fixed(&buffer);
    try writeValue(&scope, .{ .none = "$missing" }, &w);
    try std.testing.expectEqualStrings("{$missing}", w.buffered());
}
