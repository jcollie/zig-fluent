// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! `fluent-rs`'s resolver fixtures: what a *bundle* must do.
//!
//! The other two suites are about the parser -- what tree a file builds, and
//! which error a broken entry is blamed on. Neither says anything about what
//! comes out the other end: which variant a selector picks, what a missing
//! argument falls back to, where the isolation marks go, whether a cyclic
//! reference is caught or hangs. This one does. It is 58 suites, 164 tests and
//! 180 assertions over 17 files, each assertion naming a message, the
//! arguments to format it with, the text that must come out, and the errors
//! that must be reported while doing it.
//!
//! It has no official standing. `fluent-rs` keeps it and `fluent-rs` alone
//! runs it -- but the file names map one-to-one onto `fluent.js`'s own mocha
//! tests (`macros.yaml` against `macros_test.js`, and so on down the
//! directory), so what it holds is the reference implementation's behaviour
//! transliterated into a language-neutral format. That makes it the only
//! runtime conformance corpus Fluent has, whoever owns it.
//!
//! ## Reading YAML
//!
//! The fixtures are YAML and Zig has no YAML reader. `tests/yaml.zig` reads
//! the subset these files use and refuses everything else; the note at the top
//! of it says why that is safer than a general one.
//!
//! ## What is compared, and what is not
//!
//! The formatted text, exactly. The count and order of the errors, exactly.
//! The *kind* of each error, mapped onto `fluent-rs`'s six names through
//! `errorType` below.
//!
//! ## Where this library disagrees on purpose
//!
//! Eight assertions are expected not to match, and `divergences` below lists
//! every one with the text this library produces instead. Seven of the eight
//! were checked against `fluent.js`'s own test for the same case, and in all
//! seven `fluent.js` asserts what this library produces: `{???}` for a cyclic
//! reference and for the reference bomb, `{key6}` for a reference to an
//! attribute of a message that does not exist, and isolation marks around
//! string literals and term references -- which `fluent-rs` skips, and says
//! so in the name of the suite that asserts it. The eighth, a function called
//! with arguments it cannot use, is a case `fluent.js` skips rather than
//! settles.
//!
//! So this suite is run the way the other two are: a listed assertion must
//! still differ and must still produce exactly what is written here, and one
//! that starts matching fails, because that means the list is stale.
//!
//! The wording is not compared, because there is nothing to compare it to: a
//! `desc` in a fixture is `fluent-rs`'s own sentence, not something the
//! project specifies, and this library words them differently in three places
//! (`No value: key5` against `message has no value: key5`, an attribute error
//! naming the message as well as the attribute, and initial capitals). What is
//! checked instead is that the name this library blames appears in the
//! sentence `fluent-rs` wrote -- so an error of the right kind about the wrong
//! variable still fails.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fluent = @import("fluent");
const options = @import("bundle_fixtures_options");

const yaml = @import("yaml.zig");

/// An assertion this library is expected to fail, and what it produces.
const Divergence = struct {
    fixture: []const u8,
    /// The suites and test that lead to it, as the failure lines print them.
    path: []const u8,
    id: []const u8,
    /// The text this library formats instead of what the fixture asks for.
    produces: []const u8,
};

const divergences = [_]Divergence{
    // `fluent.js`: `assert.strictEqual(val, "{???}")`, and the fixture itself
    // says "# Different from JS" above the expansion it wants. A budget that
    // stops expanding mid-sentence and keeps what it had is the disagreement.
    .{
        .fixture = "bomb.yaml",
        .path = "Reference bombs > Billion Laughs > does not expand all placeables",
        .id = "lolz",
        .produces = "{???}",
    },
    // `fluent.js` skips its own test for this one, pointing at
    // https://bugzil.la/1307124 -- what a function given arguments it cannot
    // use should fall back to is open upstream. This library labels the
    // fallback with the function's name, which is `{IDENTITY}`.
    .{
        .fixture = "functions.yaml",
        .path = "Functions > arguments > falls back when arguments don't match the arity",
        .id = "pass-nothing",
        .produces = "{IDENTITY}",
    },
    // The suite these two are in is called "(Rust) Skip isolation of string
    // literals and terms", which is the whole explanation: `fluent-rs` leaves
    // both un-isolated and `fluent.js` isolates them, as this does.
    .{
        .fixture = "isolating.yaml",
        .path = "(Rust) Skip isolation of string literals and terms > skip isolation of string literals",
        .id = "rs-bar",
        .produces = "Foo \u{2068}Test\u{2069} \u{2068}Bar\u{2069} baz",
    },
    .{
        .fixture = "isolating.yaml",
        .path = "(Rust) Skip isolation of string literals and terms > skip isolation of term references",
        .id = "rs-baz",
        .produces = "Foo \u{2068}Test\u{2069} \u{2068}My Term\u{2069} baz",
    },
    // All three of `fluent.js`'s cyclic tests assert `{???}`; `fluent-rs`
    // falls back to the name of the message the cycle was entered through.
    .{
        .fixture = "patterns.yaml",
        .path = "Patterns > Cyclic reference > returns ???",
        .id = "foo",
        .produces = "{???}",
    },
    .{
        .fixture = "patterns.yaml",
        .path = "Patterns > Cyclic self-reference > returns the raw string",
        .id = "foo",
        .produces = "{???}",
    },
    .{
        .fixture = "patterns.yaml",
        .path = "Patterns > Cyclic self-reference in a member > returns ???",
        .id = "foo",
        .produces = "{???}",
    },
    // `{ key6.a }` where `key6` is not in the bundle. `fluent.js` asserts
    // `{key6}` -- the fallback names what was actually missing, which is the
    // message; `fluent-rs` writes the attribute out as well.
    .{
        .fixture = "values_ref.yaml",
        .path = "Referencing values > missing message reference",
        .id = "ref14",
        .produces = "{key6}",
    },
};

test "every bundle fixture behaves the way fluent-rs records" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, options.fixtures_dir, .{ .iterate = true });
    defer dir.close(io);

    const defaults_text = try dir.readFileAlloc(io, "defaults.yaml", arena, .limited(1 << 20));
    const defaults = (try yaml.parse(arena, defaults_text)).get("bundle") orelse
        yaml.Value{ .map = &.{} };

    var runner: Runner = .{ .gpa = gpa, .arena = arena, .defaults = defaults };

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        if (std.mem.eql(u8, entry.name, "defaults.yaml")) continue;

        const text = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const doc = try yaml.parse(arena, text);

        runner.fixture = entry.name;
        for (doc.list_("suites")) |suite| {
            var scope: Scope = .empty;
            defer scope.deinit(arena);
            try runner.runSuite(suite, &scope);
        }
    }

    // The same guard the other two suites carry: a corpus that turned up empty,
    // or a reader that quietly dropped most of it, would otherwise pass in
    // silence. These are the counts `fluent-rs` runs, less what it skips.
    try std.testing.expect(runner.asserts >= 150);
    try std.testing.expect(runner.tests >= 140);
    try std.testing.expectEqual(@as(usize, 0), runner.failures);
}

/// One level of the nesting: a suite or a test, with whatever it declared.
///
/// Resources and bundle definitions accumulate down the tree, so a bundle
/// built for an assertion is built from every resource declared above it.
const Level = struct {
    name: []const u8,
    resources: []const yaml.Value,
    bundles: []const yaml.Value,
};

const Scope = std.ArrayList(Level);

const Runner = struct {
    gpa: Allocator,
    arena: Allocator,
    defaults: yaml.Value,
    fixture: []const u8 = "",
    suites: usize = 0,
    tests: usize = 0,
    asserts: usize = 0,
    skipped: usize = 0,
    failures: usize = 0,

    fn runSuite(self: *Runner, suite: yaml.Value, scope: *Scope) !void {
        if (suite.bool_("skip") orelse false) {
            self.skipped += 1;
            return;
        }
        self.suites += 1;

        try scope.append(self.arena, .{
            .name = suite.string_("name") orelse "",
            .resources = suite.list_("resources"),
            .bundles = suite.list_("bundles"),
        });
        defer _ = scope.pop();

        for (suite.list_("tests")) |t| try self.runTest(t, scope);
        for (suite.list_("suites")) |sub| try self.runSuite(sub, scope);
    }

    fn runTest(self: *Runner, t: yaml.Value, scope: *Scope) !void {
        if (t.bool_("skip") orelse false) {
            self.skipped += 1;
            return;
        }
        self.tests += 1;

        try scope.append(self.arena, .{
            .name = t.string_("name") orelse "",
            .resources = t.list_("resources"),
            .bundles = t.list_("bundles"),
        });
        defer _ = scope.pop();

        for (t.list_("asserts")) |assert| {
            self.asserts += 1;
            // Every assertion gets bundles of its own, as `fluent-rs` does:
            // adding a resource can report errors, and those are part of what
            // an assertion about overriding is asserting.
            self.runAssert(assert, scope) catch |err| {
                self.fail(scope, "{t}", .{err});
            };
        }
    }

    fn runAssert(self: *Runner, assert: yaml.Value, scope: *Scope) !void {
        var bundles: std.ArrayList(Named) = .empty;
        defer {
            for (bundles.items) |*named| named.bundle.deinit();
            bundles.deinit(self.gpa);
        }
        try self.buildBundles(scope, &bundles);

        const bundle = blk: {
            if (assert.string_("bundle")) |want| {
                for (bundles.items) |*named| {
                    if (named.name != null and std.mem.eql(u8, named.name.?, want)) break :blk &named.bundle;
                }
                self.fail(scope, "no bundle named {s}", .{want});
                return;
            }
            if (bundles.items.len != 1) {
                self.fail(scope, "{d} bundles and no name to choose by", .{bundles.items.len});
                return;
            }
            break :blk &bundles.items[0].bundle;
        };

        const id = assert.string_("id") orelse {
            self.fail(scope, "assertion with no id", .{});
            return;
        };

        if (assert.bool_("missing")) |expected| {
            const missing = !bundle.hasMessage(id);
            if (missing != expected) {
                self.fail(scope, "{s}: missing is {} and should be {}", .{ id, missing, expected });
            }
            return;
        }

        // `value: 3` is a YAML number rather than a string, and what it
        // asserts is the text `3`.
        const expected = switch (assert.get("value") orelse yaml.Value{ .map = &.{} }) {
            .string => |text| text,
            .number => |n| try std.fmt.allocPrint(self.arena, "{d}", .{n}),
            .boolean => |b| if (b) "true" else "false",
            else => {
                self.fail(scope, "{s}: assertion with neither value nor missing", .{id});
                return;
            },
        };

        var args: std.ArrayList(fluent.Argument) = .empty;
        defer args.deinit(self.gpa);
        if (assert.get("args")) |given| {
            if (given == .map) for (given.map) |pair| {
                try args.append(self.gpa, .{ .name = pair.key, .value = switch (pair.value) {
                    .string => |s| .{ .string = s },
                    .number => |n| .num(n),
                    else => {
                        self.fail(scope, "{s}: argument {s} is not a string or a number", .{ id, pair.key });
                        return;
                    },
                } });
            };
        }

        var errors: fluent.Errors = .empty;
        defer errors.deinit(self.gpa);

        const text = blk: {
            if (assert.string_("attribute")) |attribute| {
                break :blk try bundle.formatAttribute(self.gpa, id, attribute, args.items, &errors) orelse {
                    self.fail(scope, "{s}.{s}: no such attribute", .{ id, attribute });
                    return;
                };
            }
            break :blk try bundle.format(self.gpa, id, args.items, &errors) orelse {
                self.fail(scope, "{s}: no such message", .{id});
                return;
            };
        };
        defer self.gpa.free(text);

        // A listed divergence must still diverge, and must still produce
        // exactly what was written down: a fixture that starts matching means
        // the list has gone stale, not that nothing is wrong.
        if (self.divergence(scope, id)) |d| {
            if (std.mem.eql(u8, text, expected)) {
                self.fail(scope, "{s}: now matches fluent-rs; drop it from `divergences`", .{id});
            } else if (!std.mem.eql(u8, text, d.produces)) {
                self.fail(scope, "{s}: formatted {f} and the recorded divergence is {f}", .{
                    id, std.zig.fmtString(text), std.zig.fmtString(d.produces),
                });
            }
            return;
        }

        if (!std.mem.eql(u8, text, expected)) {
            self.fail(scope, "{s}: formatted {f} and should be {f}", .{
                id, std.zig.fmtString(text), std.zig.fmtString(expected),
            });
            return;
        }

        self.checkErrors(scope, id, errors.items, assert.list_("errors"), .all);
    }

    /// Which errors from one list are being checked against a fixture's list.
    ///
    /// Adding a resource reports two kinds of thing at once, and the fixtures
    /// keep them apart: a parse error belongs to the resource that failed to
    /// parse, and a name that was already taken belongs to the bundle the
    /// resource was added to.
    const Selection = enum { all, parse, overriding };

    fn checkErrors(
        self: *Runner,
        scope: *Scope,
        what: []const u8,
        produced: []const fluent.Error,
        expected: []const yaml.Value,
        selection: Selection,
    ) void {
        var got: usize = 0;
        for (produced) |e| {
            if (!selects(selection, e.kind)) continue;
            defer got += 1;

            if (got >= expected.len) {
                self.fail(scope, "{s}: unexpected {f}", .{ what, e });
                continue;
            }
            const want = expected[got];
            const want_type = want.string_("type") orelse "";
            if (!std.mem.eql(u8, errorType(e.kind), want_type)) {
                self.fail(scope, "{s}: error {d} is {s} ({f}) and should be {s}", .{
                    what, got, errorType(e.kind), e, want_type,
                });
                continue;
            }
            // The sentences differ; the name blamed does not.
            if (want.string_("desc")) |desc| {
                if (e.name.len != 0 and std.mem.indexOf(u8, desc, e.name) == null) {
                    self.fail(scope, "{s}: error {d} blames {s}, not {s}", .{
                        what, got, e.name, desc,
                    });
                }
            }
        }
        if (got < expected.len) {
            self.fail(scope, "{s}: {d} errors and should be {d}", .{ what, got, expected.len });
        }
    }

    /// The divergence recorded for the assertion the scope leads to, if any.
    fn divergence(self: *Runner, scope: *Scope, id: []const u8) ?Divergence {
        var buffer: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        writePath(&w, scope) catch return null;
        const path = w.buffered();

        for (divergences) |d| {
            if (!std.mem.eql(u8, d.fixture, self.fixture)) continue;
            if (!std.mem.eql(u8, d.id, id)) continue;
            if (!std.mem.eql(u8, d.path, path)) continue;
            return d;
        }
        return null;
    }

    fn fail(self: *Runner, scope: *Scope, comptime fmt: []const u8, args: anytype) void {
        self.failures += 1;
        var buffer: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        writePath(&w, scope) catch {};
        std.debug.print("bundle fixture {s}: {s}: ", .{ self.fixture, w.buffered() });
        std.debug.print(fmt ++ "\n", args);
    }

    const Named = struct {
        name: ?[]const u8,
        bundle: fluent.Bundle,
    };

    /// Build the bundles an assertion can address, from every level of the
    /// scope above it. A scope that declares none gets one default bundle.
    fn buildBundles(self: *Runner, scope: *Scope, out: *std.ArrayList(Named)) !void {
        var resources: std.ArrayList(yaml.Value) = .empty;
        defer resources.deinit(self.gpa);

        for (scope.items) |level| {
            for (level.resources) |r| try resources.append(self.gpa, r);
            for (level.bundles) |spec| {
                try out.append(self.gpa, .{
                    .name = spec.string_("name"),
                    .bundle = try self.buildBundle(scope, spec, resources.items),
                });
            }
        }

        if (out.items.len == 0) {
            try out.append(self.gpa, .{
                .name = null,
                .bundle = try self.buildBundle(scope, .{ .map = &.{} }, resources.items),
            });
        }
    }

    fn buildBundle(
        self: *Runner,
        scope: *Scope,
        spec: yaml.Value,
        resources: []const yaml.Value,
    ) !fluent.Bundle {
        const tag = firstString(spec.list_("locales")) orelse
            firstString(self.defaults.list_("locales")) orelse "en-US";
        // `x-testing` is a private-use tag with no language in it, which is
        // the point of it: a bundle under it has no plural rules and no
        // formatting data, which is what root is here.
        const locale = fluent.Locale.parse(tag) catch fluent.Locale.root;

        var bundle: fluent.Bundle = try .init(self.gpa, locale);
        errdefer bundle.deinit();

        bundle.use_isolating = spec.bool_("useIsolating") orelse
            self.defaults.bool_("useIsolating") orelse true;

        const transform = spec.string_("transform") orelse self.defaults.string_("transform");
        if (transform) |name| {
            if (std.mem.eql(u8, name, "example")) {
                bundle.transform = transformExample;
            } else {
                self.fail(scope, "no such transform: {s}", .{name});
            }
        }

        for (spec.list_("functions")) |f| {
            if (f != .string) continue;
            const function = customFunction(f.string) orelse {
                self.fail(scope, "no such function: {s}", .{f.string});
                continue;
            };
            try bundle.addFunction(f.string, function);
        }

        // A bundle may take only some of the resources in scope, naming the
        // ones it wants. A resource with no name is always taken.
        const subset = spec.get("resources");

        var errors: fluent.Errors = .empty;
        defer errors.deinit(self.gpa);

        for (resources) |resource| {
            if (subset) |wanted| {
                if (resource.string_("name")) |name| {
                    if (!contains(wanted.list, name)) continue;
                }
            }
            const source = resource.string_("source") orelse continue;

            var resource_errors: fluent.Errors = .empty;
            defer resource_errors.deinit(self.gpa);
            try bundle.addResource(source, .{}, &resource_errors);

            self.checkErrors(
                scope,
                resource.string_("name") orelse "resource",
                resource_errors.items,
                resource.list_("errors"),
                .parse,
            );
            try errors.appendSlice(self.gpa, resource_errors.items);
        }

        self.checkErrors(scope, "bundle", errors.items, spec.list_("errors"), .overriding);
        return bundle;
    }
};

/// The names of the suites and the test, joined the way the fixtures read.
fn writePath(w: *std.Io.Writer, scope: *Scope) std.Io.Writer.Error!void {
    for (scope.items, 0..) |level, i| {
        if (i > 0) try w.writeAll(" > ");
        try w.writeAll(level.name);
    }
}

fn selects(selection: Runner.Selection, kind: fluent.Error.Kind) bool {
    return switch (selection) {
        .all => true,
        .parse => kind == .parse_error,
        .overriding => kind == .duplicate_message or kind == .duplicate_term,
    };
}

/// This library's error kinds under the six names `fluent-rs` reports.
fn errorType(kind: fluent.Error.Kind) []const u8 {
    return switch (kind) {
        .parse_error => "Parser",
        .duplicate_message, .duplicate_term => "Overriding",
        .unknown_variable,
        .unknown_message,
        .unknown_term,
        .unknown_attribute,
        .unknown_function,
        => "Reference",
        .missing_value => "NoValue",
        .cyclic_reference => "Cyclic",
        .too_many_placeables => "TooManyPlaceables",
        // `fluent-rs` has no counterpart: a builtin given something it cannot
        // use falls back there without reporting anything of its own.
        .invalid_argument => "InvalidArgument",
    };
}

fn firstString(list: []const yaml.Value) ?[]const u8 {
    if (list.len == 0) return null;
    return if (list[0] == .string) list[0].string else null;
}

fn contains(list: []const yaml.Value, name: []const u8) bool {
    for (list) |item| {
        if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

/// The transform the fixtures ask for by the name `example`: every `a` in
/// literal text becomes an `A`, which is enough to show that a transform is
/// applied to text and not to what a placeable resolves to.
fn transformExample(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |c| try w.writeByte(if (c == 'a') 'A' else c);
}

/// The four functions the fixtures register by name, as `fluent-rs` defines
/// them in `resolver_fixtures.rs`.
fn customFunction(name: []const u8) ?fluent.Function {
    const table = struct {
        /// Every argument, printed and joined.
        fn concat(call: fluent.Call) fluent.Value {
            var out: std.Io.Writer.Allocating = .init(call.arena);
            for (call.positional) |value| switch (value) {
                .string => |s| out.writer.writeAll(s) catch return .{ .none = "CONCAT()" },
                .number => |n| out.writer.print("{d}", .{n.value}) catch return .{ .none = "CONCAT()" },
                else => {},
            };
            return .{ .string = out.written() };
        }

        /// Every argument added up. Anything that is not a number is an error
        /// in `fluent-rs`, which panics; here it is simply not added.
        fn sum(call: fluent.Call) fluent.Value {
            var total: f64 = 0;
            for (call.positional) |value| switch (value) {
                .number => |n| total += n.value,
                else => return .{ .none = "SUM()" },
            };
            return .num(total);
        }

        /// The first argument, unchanged.
        fn identity(call: fluent.Call) fluent.Value {
            return call.first();
        }
    };

    if (std.mem.eql(u8, name, "CONCAT")) return table.concat;
    if (std.mem.eql(u8, name, "SUM")) return table.sum;
    if (std.mem.eql(u8, name, "IDENTITY")) return table.identity;
    // The fixtures re-register `NUMBER` as a function that returns its
    // argument untouched. This library has a real one, and the assertion that
    // uses it -- `{ NUMBER($num) }` with `num: 3` -- wants `3` from either.
    if (std.mem.eql(u8, name, "NUMBER")) return table.identity;
    return null;
}
