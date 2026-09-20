// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The three corpora this library is measured against, and the code that
//! reads them.
//!
//! Its own project, so that two monorepos and a spec repository are its own
//! project's business. They are 7.4 MB of download for 245 KB of fixtures,
//! and nothing that merely builds the library -- or packages it, or depends
//! on it -- should have to fetch them. Keeping them here keeps them out of
//! the library's manifest and out of everything generated from it.
//!
//! `zig build conformance` in the parent runs this. The library comes from
//! the checkout this sits inside, by path, so the two are always the same
//! code.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fluent = b.dependency("fluent", .{
        .target = target,
        .optimize = optimize,
    }).module("fluent");

    const test_step = b.step("test", "Run the conformance suites");

    // One suite per corpus. Each is lazy, so a run that names only one of
    // them by `--test-filter` still fetches all three -- the calls are what
    // marks a package as wanted, and `build()` runs in full whatever was
    // asked for. That is the right trade here: this project exists to run
    // them, and there is no cheaper thing to come in for.
    const Suite = struct {
        /// The package the fixtures come from.
        dependency: []const u8,
        /// Where inside it they are.
        fixtures: []const u8,
        /// The test file that reads them.
        source: []const u8,
        /// What that file imports the directory path as.
        options: []const u8,
    };

    const suites = [_]Suite{
        // Fluent's own: 39 `.ftl` files, each paired with the tree it must
        // parse to. The suite every implementation is expected to agree on.
        .{
            .dependency = "fluent_spec",
            .fixtures = "test/fixtures",
            .source = "src/conformance.zig",
            .options = "conformance_options",
        },
        // `fluent.js`'s: 62 more pairs, most of them broken on purpose, and
        // the only corpus anywhere that says which error code a broken entry
        // must be blamed on.
        .{
            .dependency = "fluent_js",
            .fixtures = "fluent-syntax/test/fixtures_structure",
            .source = "src/conformance_structure.zig",
            .options = "structure_options",
        },
        // `fluent-rs`'s: 180 assertions about what a bundle does with a
        // message once it is parsed, in YAML.
        .{
            .dependency = "fluent_rs",
            .fixtures = "fluent-bundle/tests/fixtures",
            .source = "src/conformance_bundle.zig",
            .options = "bundle_fixtures_options",
        },
    };

    for (suites) |suite| {
        if (b.lazyDependency(suite.dependency, .{})) |corpus| {
            const options = b.addOptions();
            options.addOptionPath("fixtures_dir", corpus.path(suite.fixtures));

            const mod = b.createModule(.{
                .root_source_file = b.path(suite.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "fluent", .module = fluent },
                    .{ .name = suite.options, .module = options.createModule() },
                },
            });
            test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
        }
    }
}
