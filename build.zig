// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module. The parser and the runtime live together because splitting
    // them would cost every consumer a dependency edge to save nothing: Zig
    // only analyses what is referenced, so a linter that imports the parser
    // never compiles the resolver, and an application that formats messages
    // never compiles the serializer.
    // Dates, the proleptic Gregorian calendar and the IANA timezone database
    // come from zig-datetime rather than being written again here. Not a lazy
    // dependency: formatting a date is part of what this library does, so a
    // consumer needs it.
    const datetime = b.dependency("datetime", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("fluent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "datetime", .module = datetime.module("datetime") },
        },
    });

    // Windows has none of POSIX's environment variables and answers with an
    // API instead, so `src/windows.zig` needs bindings for two calls. Lazy,
    // and only for that target, so a build for anything else neither fetches
    // nor compiles them.
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
            mod.addImport("win32", zigwin32.module("win32"));
        }
    }

    // Regenerate the CLDR tables under src/cldr/. The three packages it reads
    // are lazy dependencies totalling 135 MB unpacked, so only this step
    // fetches them -- `zig build`, `zig build test` and anything depending on
    // this library never see them. What it writes is committed; see the
    // comment at the top of tools/gen_cldr.zig for why.
    const gen_cldr = b.addExecutable(.{
        .name = "gen-cldr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_cldr.zig"),
            // Always the machine running the build: it reads and writes files
            // in this working tree, so cross-compiling it would be pointless.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const gen_cldr_step = b.step("gen-cldr", "Regenerate src/cldr/ from the CLDR data packages");
    if (b.lazyDependency("cldr_core", .{})) |core| {
        if (b.lazyDependency("cldr_numbers_full", .{})) |numbers| {
            if (b.lazyDependency("cldr_dates_full", .{})) |dates| {
                const run = b.addRunArtifact(gen_cldr);
                run.addDirectoryArg(core.path("."));
                run.addDirectoryArg(numbers.path("."));
                run.addDirectoryArg(dates.path("."));
                // It writes into the source tree, which is the point of it,
                // so it must run every time it is asked for rather than being
                // cached on its inputs.
                run.has_side_effects = true;
                run.setCwd(b.path("."));
                run.stdio = .inherit;
                gen_cldr_step.dependOn(&run.step);
            }
        }
    }

    // A worked example: read the user's language out of the environment, pick
    // the closest of the translations shipped with it, and print in that one.
    // It is built and tested like everything else, so it cannot rot.
    const example = b.addExecutable(.{
        .name = "greeting",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/greeting.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluent", .module = mod }},
        }),
    });

    const run_example = b.addRunArtifact(example);
    run_example.stdio = .inherit;
    if (b.args) |args| run_example.addArgs(args);
    const example_step = b.step("example", "Run the worked example; pass a locale to override the environment");
    example_step.dependOn(&run_example.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = example.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    // The library from the outside: real `.ftl` text through a real bundle.
    // A module of its own so that `zig build test` runs it while a consumer of
    // the library never compiles it.
    const bundle_tests = b.createModule(.{
        .root_source_file = b.path("tests/bundle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluent", .module = mod }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bundle_tests })).step);

    // Fluent's own conformance fixtures: 39 `.ftl` files, each paired with the
    // tree it must parse to. They come from the upstream repository as a lazy
    // dependency, so running the tests fetches them and merely depending on
    // this library does not.
    if (b.lazyDependency("fluent_spec", .{})) |fluent_spec| {
        const conformance_options = b.addOptions();
        conformance_options.addOptionPath("fixtures_dir", fluent_spec.path("test/fixtures"));

        const conformance = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluent", .module = mod },
                .{ .name = "conformance_options", .module = conformance_options.createModule() },
            },
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = conformance })).step);
    }

    // -- fuzzing -------------------------------------------------------------
    //
    // What the parser and the formatters must do with input nobody wrote. The
    // targets are ordinary tests as well, so `zig build test` exercises the
    // same properties on the seeds checked in beside them.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluent", .module = mod }},
    });

    // Zig's fuzzer takes one test at a time and keeps a coverage file per
    // test, so naming a target is what you want when a finding is being
    // chased: `zig build fuzz --fuzz -Dfuzz-filter=parse`.
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Fuzz or test only the targets whose name contains this",
    );
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // A step of its own for `zig build fuzz --fuzz`, holding nothing else: the
    // fuzzer takes over the terminal and runs until it is stopped, so it must
    // not be reached by `zig build test`.
    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The loop that drives those same targets without Zig's fuzzer, which this
    // toolchain cannot usefully run: `tools/fuzz.zig` says why, and the short
    // version is that the coverage table comes back empty. Optimised, because
    // a fuzzer's whole job is how many inputs it gets through, and ReleaseSafe
    // keeps every check that makes a failure a failure.
    const fuzz_run = b.addExecutable(.{
        .name = "zig-fluent-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "fuzz_targets", .module = fuzz_mod }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_run);
    run_fuzz.stdio = .inherit;
    if (b.args) |a| run_fuzz.addArgs(a);
    const fuzz_run_step = b.step("fuzz-run", "Fuzz the targets with a loop of our own");
    fuzz_run_step.dependOn(&run_fuzz.step);

    // Nothing else builds these, so without this they could stop compiling and
    // `zig build test` would not notice.
    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&fuzz_run.step);
    check_step.dependOn(&example.step);
    check_step.dependOn(&gen_cldr.step);

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it. What comes out is not
    // a page but a program: a WebAssembly viewer, its javascript, and a tar of
    // the sources it reads from.
    const library = b.addLibrary(.{ .name = "fluent", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // The documentation is also what a plain `zig build` installs, because it
    // is the only artifact this project has: a Zig library is consumed as
    // source through the package manager, so there is no `.a` worth producing
    // and an install step with nothing in it makes a Nix build fail for want
    // of an output. It costs one extra compile of the module and nothing to
    // anyone depending on this library, who never runs this build script's
    // install step.
    b.getInstallStep().dependOn(&install_docs.step);

    // That viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs locally
    // means serving them. It is the same reason `zig std` runs a server rather
    // than opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for
            // whatever -Dtarget the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}
