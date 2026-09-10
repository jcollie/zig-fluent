// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A bundle: the messages of one locale, ready to be formatted.
//!
//! This is the object an application holds. It owns the parsed resources, the
//! index from message name to pattern, the functions translations may call,
//! and the locale that decides how numbers and dates come out.
//!
//! ```zig
//! var bundle: Bundle = try .init(gpa, try .parse("en-US"));
//! defer bundle.deinit();
//! try bundle.addResource(@embedFile("en.ftl"), .{}, null);
//!
//! const text = try bundle.format(gpa, "unread", &.{
//!     .{ .name = "count", .value = .num(3) },
//! }, null);
//! defer gpa.free(text);
//! ```
//!
//! ## One locale, not a list
//!
//! Fluent's own bundles take a list, and applications commonly hold several
//! bundles and fall back from one to the next when a message is missing.
//! Choosing that order is a separate problem -- matching what a user asked for
//! against what has been translated -- and Fluent keeps it in a separate
//! package for that reason. So a bundle here has one locale, and an
//! application that wants a chain holds a slice of bundles and asks each in
//! turn. `hasMessage` is what such a loop is for.

const std = @import("std");
const Allocator = std.mem.Allocator;

const datetime_format = @import("datetime_format.zig");
const number_format = @import("number_format.zig");
const resolver = @import("resolver.zig");
const syntax = @import("syntax.zig");
const value_mod = @import("value.zig");

const Locale = @import("locale.zig").Locale;
const ast = syntax.ast;

pub const Args = value_mod.Args;
pub const Argument = value_mod.Argument;
pub const Value = value_mod.Value;

/// Something that went wrong while adding a resource or formatting a message.
///
/// None of these stop anything: a resource with a broken entry still
/// contributes its good ones, and a message with an unresolvable reference
/// still renders. They are collected for whoever wants to know -- a test, a
/// linter, a log line in development -- and a caller that passes null for the
/// error list simply gets the fallback text.
pub const Error = struct {
    kind: Kind,
    /// The name this is about: a variable, message, term, function or
    /// attribute. Borrowed from the resource or the arguments, so it lives as
    /// long as whichever of those it came from.
    name: []const u8 = "",
    /// For a parse error, what the parser said.
    annotation: ?syntax.Annotation = null,

    pub const Kind = enum {
        /// An entry in the resource did not parse and became junk.
        parse_error,
        /// A message with this name was already in the bundle.
        duplicate_message,
        /// A term with this name was already in the bundle.
        duplicate_term,

        /// `$name` was not among the arguments.
        unknown_variable,
        /// A message referred to one that is not in the bundle.
        unknown_message,
        /// A message referred to a term that is not in the bundle.
        unknown_term,
        /// The message or term exists, but has no such attribute.
        unknown_attribute,
        /// A translation called a function the bundle does not have.
        unknown_function,
        /// The message exists and has attributes, but no value to print.
        missing_value,
        /// A pattern referred to itself, directly or through others.
        cyclic_reference,
        /// One call expanded more placeables than the budget allows.
        too_many_placeables,
        /// A builtin was given something it cannot work with.
        invalid_argument,
    };

    /// `{f}` prints the error as a sentence, e.g. `unknown variable: $count`.
    pub fn format(self: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .parse_error => {
                try w.writeAll("parse error");
                if (self.annotation) |a| try w.print(": {f}", .{a});
            },
            .duplicate_message => try w.print("duplicate message: {s}", .{self.name}),
            .duplicate_term => try w.print("duplicate term: -{s}", .{self.name}),
            .unknown_variable => try w.print("unknown variable: ${s}", .{self.name}),
            .unknown_message => try w.print("unknown message: {s}", .{self.name}),
            .unknown_term => try w.print("unknown term: -{s}", .{self.name}),
            .unknown_attribute => try w.print("unknown attribute: .{s}", .{self.name}),
            .unknown_function => try w.print("unknown function: {s}()", .{self.name}),
            .missing_value => try w.print("message has no value: {s}", .{self.name}),
            .cyclic_reference => try w.writeAll("cyclic reference"),
            .too_many_placeables => try w.writeAll("too many placeables expanded"),
            .invalid_argument => try w.print("invalid argument to {s}()", .{self.name}),
        }
    }

    test format {
        var buffer: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try w.print("{f}", .{Error{ .kind = .unknown_variable, .name = "count" }});
        try std.testing.expectEqualStrings("unknown variable: $count", w.buffered());
    }
};

/// A list of things that went wrong, for a caller that wants to know.
///
/// Unmanaged, and always allocated with the **bundle's** allocator -- the one
/// given to `Bundle.init` -- whichever call filled it in. Free it with that
/// same allocator. Passing null wherever one of these is asked for is fine and
/// costs nothing; the fallbacks happen either way.
pub const Errors = std.ArrayList(Error);

/// A message or term, as the bundle holds it.
pub const Entry = struct {
    /// Null only for a message that exists purely to hold attributes. A term
    /// always has a value; the parser refuses one without.
    value: ?ast.Pattern,
    attributes: []const ast.Attribute,

    /// The pattern of the attribute called `name`, or null if there is none.
    pub fn attribute(self: Entry, name: []const u8) ?ast.Pattern {
        for (self.attributes) |a| {
            if (std.mem.eql(u8, a.id.name, name)) return a.value;
        }
        return null;
    }

    test attribute {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();
        try bundle.addResource("input = Value\n    .placeholder = Type here\n", .{}, null);

        const message = bundle.getMessage("input").?;
        try std.testing.expect(message.attribute("placeholder") != null);
        try std.testing.expectEqual(@as(?ast.Pattern, null), message.attribute("missing"));
    }
};

/// What a translation gets when it calls a function.
pub const Call = struct {
    /// Lives until the current `format` call returns. A function that builds a
    /// string puts it here.
    arena: Allocator,
    /// The caller's allocator, which owns the error list. Nothing else.
    gpa: Allocator,
    bundle: *const Bundle,
    errors: ?*Errors,
    /// The name it was called by, for error messages.
    name: []const u8,
    positional: []const Value,
    named: []const Argument,

    /// The first positional argument, or a `.none` labelled with the call's own
    /// name when it was given none.
    pub fn first(self: Call) Value {
        if (self.positional.len == 0) return .{ .none = self.name };
        return self.positional[0];
    }

    test first {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const call: Call = .{
            .arena = arena.allocator(),
            .gpa = std.testing.allocator,
            .bundle = &bundle,
            .errors = null,
            .name = "NUMBER",
            .positional = &.{.num(3)},
            .named = &.{},
        };
        try std.testing.expectEqual(@as(f64, 3), call.first().number.value);

        // Given nothing, a fallback labelled with the call's own name.
        const empty: Call = .{ .arena = arena.allocator(), .gpa = std.testing.allocator, .bundle = &bundle, .errors = null, .name = "NUMBER", .positional = &.{}, .named = &.{} };
        try std.testing.expectEqualStrings("NUMBER", empty.first().none);
    }

    /// The named option called `name`, whatever type it resolved to.
    pub fn option(self: Call, name: []const u8) ?Value {
        return value_mod.find(self.named, name);
    }

    test option {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const call: Call = .{
            .arena = arena.allocator(),
            .gpa = std.testing.allocator,
            .bundle = &bundle,
            .errors = null,
            .name = "NUMBER",
            .positional = &.{},
            .named = &.{.{ .name = "style", .value = .{ .string = "percent" } }},
        };
        try std.testing.expectEqualStrings("percent", call.option("style").?.string);
        try std.testing.expectEqual(@as(?Value, null), call.option("absent"));
    }

    /// A named option as a number, when it is one.
    pub fn numberOption(self: Call, name: []const u8) ?f64 {
        const v = self.option(name) orelse return null;
        return switch (v) {
            .number => |n| n.value,
            else => null,
        };
    }

    test numberOption {
        var bundle = try testBundle("m = { NUMBER($n, maximumFractionDigits: 2) }\n");
        defer bundle.deinit();
        // Reached through a real call, since that is the only way an option arrives.
        const text = (try bundle.format(std.testing.allocator, "m", &.{
            .{ .name = "n", .value = .num(1.23456) },
        }, null)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("1.23", text);
    }

    /// A named option as text, when it is text.
    ///
    /// Fluent's grammar only allows a literal here, so this is reading what
    /// the translator wrote rather than something computed.
    pub fn stringOption(self: Call, name: []const u8) ?[]const u8 {
        const v = self.option(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    test stringOption {
        // Fluent has no booleans, so `useGrouping` arrives as the text "false".
        var bundle = try testBundle("m = { NUMBER($n, useGrouping: \"false\") }\n");
        defer bundle.deinit();
        const text = (try bundle.format(std.testing.allocator, "m", &.{
            .{ .name = "n", .value = .num(1234) },
        }, null)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("1234", text);
    }

    /// A named option matched against an enum's field names.
    pub fn enumOption(self: Call, comptime T: type, name: []const u8) ?T {
        const text = self.stringOption(name) orelse return null;
        return std.meta.stringToEnum(T, text);
    }

    test enumOption {
        // `dateStyle: "short"` is matched against the field names of an enum.
        var bundle = try testBundle("m = { DATETIME($t, dateStyle: \"short\") }\n");
        defer bundle.deinit();
        const text = (try bundle.format(std.testing.allocator, "m", &.{
            .{ .name = "t", .value = .time(0) },
        }, null)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("1970-01-01", text);
    }

    /// Record a problem. `name` must outlive the call -- a static string, or
    /// something owned by a resource -- because the error list does.
    pub fn report(self: Call, kind: Error.Kind, name: []const u8) void {
        const errors = self.errors orelse return;
        errors.append(self.gpa, .{ .kind = kind, .name = name }) catch {};
    }

    test report {
        // A builtin given something it cannot use says so, and still renders.
        var bundle = try testBundle("m = { NUMBER($s) }\n");
        defer bundle.deinit();

        var errors: Errors = .empty;
        defer errors.deinit(std.testing.allocator);

        const text = (try bundle.format(std.testing.allocator, "m", &.{
            .{ .name = "s", .value = .{ .string = "not a number" } },
        }, &errors)).?;
        defer std.testing.allocator.free(text);

        try std.testing.expectEqualStrings("{NUMBER()}", text);
        try std.testing.expectEqual(Error.Kind.invalid_argument, errors.items[0].kind);
    }
};

/// A function a translation may call, such as `NUMBER()`.
///
/// It gets values that are already resolved and returns one. It cannot fail:
/// anything it cannot do becomes a `.none` with a label, which is what every
/// other unresolvable thing becomes, so a broken call renders as `{NUMBER()}`
/// rather than blanking the message around it.
pub const Function = *const fn (call: Call) Value;

pub const AddOptions = struct {
    /// Whether a later resource may replace messages an earlier one defined.
    ///
    /// Off by default, matching the reference. A bundle is usually built from
    /// one file plus overrides, and silently taking the last definition makes
    /// a duplicated name impossible to notice.
    allow_overrides: bool = false,
};

/// A bundle over `source`, for the doctests below.
///
/// Isolation is switched off because these assert on exact text, and it wraps
/// every interpolation in invisible characters.
fn testBundle(source: []const u8) !Bundle {
    var bundle: Bundle = try .init(std.testing.allocator, .root);
    errdefer bundle.deinit();
    bundle.use_isolating = false;
    try bundle.addResource(source, .{}, null);
    return bundle;
}

pub const Bundle = struct {
    gpa: Allocator,
    locale: Locale,

    /// Whether to wrap interpolations in Unicode isolation marks.
    ///
    /// On by default, as in the reference. Turn it off when the result is
    /// going somewhere the invisible characters would be a problem -- a test
    /// asserting on exact text, a command-line tool, a value about to be
    /// compared -- and on when it is going into a paragraph a person reads.
    use_isolating: bool = true,

    /// A hook applied to every run of literal text, for pseudolocalization.
    transform: ?*const fn (text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void = null,

    /// The formatting data for this locale. Set once at `init` from the CLDR
    /// tables, so that formatting a number is a struct copy rather than a
    /// table lookup.
    number_symbols: number_format.Symbols = .{},
    decimal_pattern: number_format.Pattern = .{},
    percent_pattern: number_format.Pattern = .{},
    currency_pattern: number_format.Pattern = .{},

    /// The names and patterns this locale writes dates with. Set once at
    /// `init` from the CLDR tables.
    date_names: datetime_format.Names = .{},

    /// The zone dates are read in. Null means UTC.
    ///
    /// Borrowed: a zone is parsed from TZif once and used for the life of the
    /// program, so the bundle only points at it.
    time_zone: ?*const datetime_format.TimeZone = null,

    messages: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    terms: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    functions: std.StringArrayHashMapUnmanaged(Function) = .empty,
    /// The parsed resources, which own every pattern the indexes point into.
    resources: std.ArrayList(syntax.Resource) = .empty,

    /// A bundle for `locale`, with `NUMBER()` and `DATETIME()` installed.
    ///
    /// The locale's CLDR data is resolved once, here, so that formatting a value
    /// later is a struct copy rather than a table lookup.
    pub fn init(gpa: Allocator, locale: Locale) Allocator.Error!Bundle {
        var self: Bundle = .{ .gpa = gpa, .locale = locale };
        errdefer self.deinit();

        // Resolved once here rather than on every format call. A locale CLDR
        // does not cover keeps the root defaults, which are ISO-like and never
        // wrong so much as unidiomatic.
        const numbers = @import("cldr/numbers.zig");
        if (locale.lookup(numbers.keys)) |i| {
            self.number_symbols = numbers.symbols[i];
            self.decimal_pattern = numbers.decimal_patterns[i];
            self.percent_pattern = numbers.percent_patterns[i];
            self.currency_pattern = numbers.currency_patterns[i];
        }

        const dates = @import("cldr/dates.zig");
        if (locale.lookup(dates.keys)) |i| self.date_names = dates.names[i];

        try @import("builtins.zig").install(&self);
        return self;
    }

    test init {
        var bundle: Bundle = try .init(std.testing.allocator, try .parse("de"));
        defer bundle.deinit();

        // The locale's CLDR data is already resolved.
        try std.testing.expectEqualStrings(",", bundle.number_symbols.decimal);
        // And the builtins are already installed.
        try std.testing.expect(bundle.getFunction("NUMBER") != null);
    }

    /// Free the bundle and every resource added to it.
    pub fn deinit(self: *Bundle) void {
        for (self.resources.items) |*resource| resource.deinit();
        self.resources.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        self.terms.deinit(self.gpa);
        self.functions.deinit(self.gpa);
        self.* = undefined;
    }

    test deinit {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        try bundle.addResource("m = v\n", .{}, null);
        // One call frees the bundle and every resource in it.
        bundle.deinit();
    }

    /// Parse `source` and add its messages and terms to the bundle.
    ///
    /// The bundle takes a copy of the source, so the caller may free it. An
    /// entry that does not parse is reported and skipped; the rest of the file
    /// is added regardless, which is the whole point of Fluent's junk
    /// recovery.
    pub fn addResource(
        self: *Bundle,
        source: []const u8,
        options: AddOptions,
        errors: ?*Errors,
    ) Allocator.Error!void {
        const resource = try syntax.parse(self.gpa, source);
        try self.resources.append(self.gpa, resource);
        const stored = &self.resources.items[self.resources.items.len - 1];

        for (stored.body) |entry| switch (entry) {
            .message => |message| try self.define(
                &self.messages,
                message.id.name,
                .{ .value = message.value, .attributes = message.attributes },
                .duplicate_message,
                options,
                errors,
            ),
            .term => |term| try self.define(
                &self.terms,
                term.id.name,
                .{ .value = term.value, .attributes = term.attributes },
                .duplicate_term,
                options,
                errors,
            ),
            .junk => |junk| if (errors) |list| {
                for (junk.annotations) |annotation| {
                    try list.append(self.gpa, .{ .kind = .parse_error, .annotation = annotation });
                }
            },
            .comment => {},
        };
    }

    test addResource {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();

        var errors: Errors = .empty;
        defer errors.deinit(std.testing.allocator);

        try bundle.addResource(
            \\before = fine
            \\broken = { $x
            \\after = also fine
            \\
        , .{}, &errors);

        // The broken entry is reported and skipped; the rest of the file is added.
        try std.testing.expect(bundle.hasMessage("before"));
        try std.testing.expect(bundle.hasMessage("after"));
        try std.testing.expectEqual(Error.Kind.parse_error, errors.items[0].kind);
    }

    /// Record one message or term, refusing a duplicate unless overrides were
    /// asked for.
    fn define(
        self: *Bundle,
        into: *std.StringArrayHashMapUnmanaged(Entry),
        name: []const u8,
        entry: Entry,
        duplicate: Error.Kind,
        options: AddOptions,
        errors: ?*Errors,
    ) Allocator.Error!void {
        if (!options.allow_overrides and into.contains(name)) {
            if (errors) |list| try list.append(self.gpa, .{ .kind = duplicate, .name = name });
            return;
        }
        try into.put(self.gpa, name, entry);
    }

    /// The message called `name`, or null.
    pub fn getMessage(self: *const Bundle, name: []const u8) ?Entry {
        return self.messages.get(name);
    }

    test getMessage {
        var bundle = try testBundle("m = v\n");
        defer bundle.deinit();
        try std.testing.expect(bundle.getMessage("m") != null);
        try std.testing.expectEqual(@as(?Entry, null), bundle.getMessage("absent"));
    }

    /// The term called `name`, written without its leading `-`.
    pub fn getTerm(self: *const Bundle, name: []const u8) ?Entry {
        return self.terms.get(name);
    }

    test getTerm {
        var bundle = try testBundle("-brand = Firefox\n");
        defer bundle.deinit();
        // Without the leading `-`, which is syntax rather than part of the name.
        try std.testing.expect(bundle.getTerm("brand") != null);
        // A term is not a message: the application cannot ask for one by name.
        try std.testing.expectEqual(@as(?Entry, null), bundle.getMessage("brand"));
    }

    /// Whether this bundle defines `name`.
    ///
    /// What a fallback chain is built out of: ask each bundle in turn and format
    /// with the first that says yes.
    pub fn hasMessage(self: *const Bundle, name: []const u8) bool {
        return self.messages.contains(name);
    }

    test hasMessage {
        var bundle = try testBundle("m = v\n");
        defer bundle.deinit();
        try std.testing.expect(bundle.hasMessage("m"));
        try std.testing.expect(!bundle.hasMessage("absent"));
    }

    /// The function called `name`, builtin or added by the application.
    pub fn getFunction(self: *const Bundle, name: []const u8) ?Function {
        return self.functions.get(name);
    }

    test getFunction {
        var bundle: Bundle = try .init(std.testing.allocator, .root);
        defer bundle.deinit();
        try std.testing.expect(bundle.getFunction("NUMBER") != null);
        try std.testing.expect(bundle.getFunction("SHOUT") == null);
    }

    /// Make a function available to translations.
    ///
    /// The name must be upper case, because that is how Fluent's grammar tells
    /// a function call from a message reference.
    pub fn addFunction(self: *Bundle, name: []const u8, function: Function) Allocator.Error!void {
        try self.functions.put(self.gpa, name, function);
    }

    test addFunction {
        const shout = struct {
            /// An example function, upper-casing whatever text it is given.
            fn call(c: Call) Value {
                const text = switch (c.first()) {
                    .string => |s| s,
                    else => return .{ .none = "SHOUT()" },
                };
                const upper = c.arena.alloc(u8, text.len) catch return .{ .none = "SHOUT()" };
                for (text, upper) |ch, *out| out.* = std.ascii.toUpper(ch);
                return .{ .string = upper };
            }
        }.call;

        var bundle = try testBundle("m = { SHOUT($name) }!\n");
        defer bundle.deinit();
        try bundle.addFunction("SHOUT", shout);

        const text = (try bundle.format(std.testing.allocator, "m", &.{
            .{ .name = "name", .value = .{ .string = "ada" } },
        }, null)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("ADA!", text);
    }

    /// Format a message by name. The caller owns the returned text.
    ///
    /// A message that is not in the bundle returns null rather than an error,
    /// so that an application falling back through several bundles can just
    /// try the next one.
    pub fn format(
        self: *const Bundle,
        gpa: Allocator,
        name: []const u8,
        args: Args,
        errors: ?*Errors,
    ) Allocator.Error!?[]u8 {
        const message = self.getMessage(name) orelse return null;
        const pattern = message.value orelse {
            if (errors) |list| try list.append(gpa, .{ .kind = .missing_value, .name = name });
            return null;
        };
        return try self.formatPattern(gpa, pattern, args, errors);
    }

    test format {
        // English, not root: root has only the `other` category, so `[one]`
        // would never match and the example would say nothing.
        var bundle: Bundle = try .init(std.testing.allocator, try .parse("en"));
        defer bundle.deinit();
        bundle.use_isolating = false;
        try bundle.addResource(
            \\unread =
            \\    { $count ->
            \\        [one] One unread message
            \\       *[other] { $count } unread messages
            \\    }
            \\
        , .{}, null);

        const one = (try bundle.format(std.testing.allocator, "unread", &.{
            .{ .name = "count", .value = .num(1) },
        }, null)).?;
        defer std.testing.allocator.free(one);
        try std.testing.expectEqualStrings("One unread message", one);

        const many = (try bundle.format(std.testing.allocator, "unread", &.{
            .{ .name = "count", .value = .num(5) },
        }, null)).?;
        defer std.testing.allocator.free(many);
        try std.testing.expectEqualStrings("5 unread messages", many);

        // Null rather than an error, so an application holding several
        // bundles can simply ask the next one.
        try std.testing.expectEqual(
            @as(?[]u8, null),
            try bundle.format(std.testing.allocator, "absent", &.{}, null),
        );
    }

    /// Format one attribute of a message, such as a `.label`.
    pub fn formatAttribute(
        self: *const Bundle,
        gpa: Allocator,
        name: []const u8,
        attribute: []const u8,
        args: Args,
        errors: ?*Errors,
    ) Allocator.Error!?[]u8 {
        const message = self.getMessage(name) orelse return null;
        const pattern = message.attribute(attribute) orelse return null;
        return try self.formatPattern(gpa, pattern, args, errors);
    }

    test formatAttribute {
        var bundle = try testBundle("input = Value\n    .placeholder = Type here\n");
        defer bundle.deinit();

        const text = (try bundle.formatAttribute(
            std.testing.allocator,
            "input",
            "placeholder",
            &.{},
            null,
        )).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("Type here", text);
    }

    /// Format a pattern taken from the syntax tree. The caller owns the text.
    pub fn formatPattern(
        self: *const Bundle,
        gpa: Allocator,
        pattern: ast.Pattern,
        args: Args,
        errors: ?*Errors,
    ) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try self.writePattern(gpa, pattern, args, errors, &out.writer);
        return out.toOwnedSlice();
    }

    test formatPattern {
        var bundle = try testBundle("m = Hello, { $name }!\n");
        defer bundle.deinit();

        // Straight from the tree, which is what a tool walking a resource has.
        const pattern = bundle.getMessage("m").?.value.?;
        const text = try bundle.formatPattern(std.testing.allocator, pattern, &.{
            .{ .name = "name", .value = .{ .string = "Ada" } },
        }, null);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("Hello, Ada!", text);
    }

    /// Format a pattern into a writer of the caller's choosing.
    ///
    /// `scratch` is used for the strings built along the way and is released
    /// before this returns; it is a separate allocator from whatever `w`
    /// writes into so that a caller writing straight to a socket or a file
    /// pays nothing for the intermediate values. The error list, if there is
    /// one, is filled in with the bundle's allocator rather than this one,
    /// because it outlives the call.
    pub fn writePattern(
        self: *const Bundle,
        scratch: Allocator,
        pattern: ast.Pattern,
        args: Args,
        errors: ?*Errors,
        w: *std.Io.Writer,
    ) Allocator.Error!void {
        var arena_state = std.heap.ArenaAllocator.init(scratch);
        defer arena_state.deinit();

        var scope: resolver.Scope = .{
            .bundle = self,
            .arena = arena_state.allocator(),
            // The bundle's allocator, not `scratch`: the error list outlives
            // this call and belongs to the caller, and every call must agree
            // about which allocator it was built with.
            .gpa = self.gpa,
            .args = args,
            .errors = errors,
        };
        defer scope.deinit();

        resolver.write(&scope, pattern, w) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.OutOfMemory,
            error.TooManyPlaceables => unreachable, // handled inside `write`
        };
    }

    test writePattern {
        var bundle = try testBundle("m = Hello, { $name }!\n");
        defer bundle.deinit();

        // Into a writer of the caller's choosing, so nothing is allocated for the
        // result itself.
        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try bundle.writePattern(
            std.testing.allocator,
            bundle.getMessage("m").?.value.?,
            &.{.{ .name = "name", .value = .{ .string = "Ada" } }},
            null,
            &w,
        );
        try std.testing.expectEqualStrings("Hello, Ada!", w.buffered());
    }

    /// The formatter to use for a number carrying these options.
    pub fn numberFormatter(self: *const Bundle, options: number_format.Options) number_format.Formatter {
        return .{
            .symbols = self.number_symbols,
            .pattern = switch (options.style) {
                .decimal => self.decimal_pattern,
                .percent => self.percent_pattern,
                .currency => self.currency_pattern,
            },
            .options = options,
        };
    }

    test numberFormatter {
        var bundle: Bundle = try .init(std.testing.allocator, try .parse("de"));
        defer bundle.deinit();

        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try bundle.numberFormatter(.{}).format(1234.5, &w);
        try std.testing.expectEqualStrings("1.234,5", w.buffered());
    }

    /// The formatter to use for a moment carrying these options.
    pub fn dateTimeFormatter(self: *const Bundle, options: datetime_format.Options) datetime_format.Formatter {
        return .{
            .names = self.date_names,
            .options = options,
            .zone = self.time_zone,
            .digits = self.number_symbols.digits,
        };
    }

    test dateTimeFormatter {
        var bundle: Bundle = try .init(std.testing.allocator, try .parse("de"));
        defer bundle.deinit();

        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try bundle.dateTimeFormatter(.{ .date_style = .short }).format(0, &w);
        try std.testing.expectEqualStrings("01.01.70", w.buffered());
    }

    /// Write a moment, with whatever options it carries.
    pub fn writeDateTime(
        self: *const Bundle,
        moment: value_mod.DateTime,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return self.dateTimeFormatter(moment.options).format(moment.epoch_ms, w);
    }

    test writeDateTime {
        var bundle: Bundle = try .init(std.testing.allocator, try .parse("de"));
        defer bundle.deinit();

        var buffer: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try bundle.writeDateTime(.{ .epoch_ms = 0, .options = .{ .date_style = .short } }, &w);
        try std.testing.expectEqualStrings("01.01.70", w.buffered());
    }
};
