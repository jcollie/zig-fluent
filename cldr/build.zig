// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The CLDR table generator, and the CLDR data it reads.
//!
//! Its own project, so that 138 MB of Unicode data is its own project's
//! business. The tables under `../src/cldr/` are committed, so an ordinary
//! build of the library reads them and needs none of this; regenerating them
//! is a maintainer's errand, run about twice a year when CLDR makes a
//! release.
//!
//! `zig build gen-cldr` in the parent runs this, and the parent's manifest
//! mentions none of these packages -- which is the point, since everything
//! generated from that manifest would otherwise carry them too.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const generator = b.addExecutable(.{
        .name = "gen-cldr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_cldr.zig"),
            // Always the machine running the build: it reads and writes files
            // in this working tree, so cross-compiling it would be pointless.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // Fetching is asked for rather than assumed, and the reason is the same
    // one the library's own build has a comment about: `.lazy = true` in a
    // manifest is not what makes a package optional. What makes it optional is
    // whether `b.lazyDependency` is *called*, and `build()` runs in full
    // during the configure phase of every `zig build`, whatever step was
    // named. Without this guard `zig build check` below -- which compiles the
    // generator and runs nothing -- would fetch all 138 MB to do it.
    const fetch = b.option(
        bool,
        "cldr",
        "Fetch the CLDR data packages (138 MB), rather than being given three directories",
    ) orelse false;

    const run = b.addRunArtifact(generator);
    // It writes into the library's source tree, which is the point of it, so
    // it must run every time it is asked for rather than being cached on its
    // inputs.
    run.has_side_effects = true;
    // The repository root, since what it writes is `src/cldr/` relative to
    // there. This project is a directory below it.
    run.setCwd(b.path(".."));
    run.stdio = .inherit;

    if (fetch) {
        if (b.lazyDependency("cldr_core", .{})) |core| {
            run.addDirectoryArg(core.path("."));
        }
        if (b.lazyDependency("cldr_numbers_full", .{})) |numbers| {
            run.addDirectoryArg(numbers.path("."));
        }
        if (b.lazyDependency("cldr_dates_full", .{})) |dates| {
            run.addDirectoryArg(dates.path("."));
        }
    }
    // Without `-Dcldr` the three directories can still be given by hand, which
    // is how to regenerate against a CLDR release this manifest does not pin.
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step(
        "run",
        "Regenerate ../src/cldr/ -- `-Dcldr` to fetch the data, or name three directories after `--`",
    );
    run_step.dependOn(&run.step);

    // Nothing else compiles the generator, so without this it could stop
    // compiling and no test anywhere would notice.
    const check_step = b.step("check", "Compile the generator without running it");
    check_step.dependOn(&generator.step);
}
