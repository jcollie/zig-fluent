// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// The manifest, read for the one thing the C API has to agree with it about:
/// `fluent_version()` returns this rather than a second copy kept in a header.
const manifest = @import("build.zig.zon");

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

    // macOS keeps the user's language in its preferences rather than in the
    // environment, and `src/darwin.zig` asks CoreFoundation for it. There is
    // no zigwin32 for CoreFoundation, so the declarations are written by hand
    // and this links the framework they need. Only for that target: the
    // framework does not exist elsewhere, and on a host without the macOS SDK
    // even a cross build cannot find it.
    if (target.result.os.tag.isDarwin()) {
        mod.linkFramework("CoreFoundation", .{});
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

    // `-Dcldr` is not a preference, it is the guard that keeps 138 MB of CLDR
    // off everybody else's clean build, and it has to sit exactly here.
    //
    // `.lazy = true` in the manifest is not what makes a package optional.
    // What makes it optional is whether `b.lazyDependency` is *called*: the
    // call marks the package as needed, and `build()` runs in full during the
    // configure phase of every `zig build`, whatever step was named on the
    // command line. These three calls used to sit at the top level of this
    // function, wanted only by a step that regenerates committed files when
    // CLDR makes a release -- and so every consumer of this library fetched
    // them, on every clean build, forever. Behind the option they are not
    // fetched at all; that alone is the difference between a 211 MB dependency
    // tree and a 73 MB one.
    //
    // Measured rather than assumed, and assumed wrongly once before: a
    // scratch project with two lazy dependencies, one called unconditionally
    // and one behind an option defaulting to false, fetches exactly the first.
    const with_cldr = b.option(
        bool,
        "cldr",
        "Fetch the CLDR data packages so that `zig build gen-cldr` can read " ++
            "them (138 MB; maintainers only, default false)",
    ) orelse false;

    const gen_cldr_run = b.addRunArtifact(gen_cldr);
    // It writes into the source tree, which is the point of it, so it must run
    // every time it is asked for rather than being cached on its inputs.
    gen_cldr_run.has_side_effects = true;
    gen_cldr_run.setCwd(b.path("."));
    gen_cldr_run.stdio = .inherit;
    if (with_cldr) {
        if (b.lazyDependency("cldr_core", .{})) |core| {
            gen_cldr_run.addDirectoryArg(core.path("."));
        }
        if (b.lazyDependency("cldr_numbers_full", .{})) |numbers| {
            gen_cldr_run.addDirectoryArg(numbers.path("."));
        }
        if (b.lazyDependency("cldr_dates_full", .{})) |dates| {
            gen_cldr_run.addDirectoryArg(dates.path("."));
        }
    }
    // Without `-Dcldr` the three directories can still be given by hand, which
    // is how to regenerate against a CLDR release this manifest does not pin.
    if (b.args) |args| gen_cldr_run.addArgs(args);

    const gen_cldr_step = b.step(
        "gen-cldr",
        "Regenerate src/cldr/ -- `-Dcldr` to fetch the data, or name three " ++
            "directories after `--`",
    );
    gen_cldr_step.dependOn(&gen_cldr_run.step);

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

    // The driver has a doctest of its own, and nothing else would run it.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = fuzz_run.root_module }),
    ).step);

    // Nothing else builds these, so without this they could stop compiling and
    // `zig build test` would not notice.
    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&fuzz_run.step);
    check_step.dependOn(&example.step);
    check_step.dependOn(&gen_cldr.step);

    // -- the C library -------------------------------------------------------
    //
    // What a non-Zig project consumes: `libfluent.a`, `libfluent.so` and
    // `include/fluent.h`, plus a pkg-config file so that a Makefile or a
    // meson build can find them without being told where they are.
    //
    // `src/c.zig` is a wrapper and nothing else -- opaque handles, C strings
    // and the errors turned into return values the header documents. The
    // header is written by hand rather than generated, because it is the
    // documentation a C programmer reads and `zig translate-c` in reverse
    // would produce something nobody would want to read.
    const c_options = b.addOptions();
    c_options.addOption([]const u8, "version", manifest.version);

    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        // libc's allocator, because a C program's memory is libc's memory,
        // and `std.c.environ` is where the environment is read from.
        .link_libc = true,
        .imports = &.{
            .{ .name = "fluent", .module = mod },
            .{ .name = "build_options", .module = c_options.createModule() },
        },
    });

    // Both linkages, because which one a consumer wants is theirs to decide:
    // a static library is the simpler thing to ship, and a shared one is what
    // a distribution packages.
    const c_static = b.addLibrary(.{
        .name = "fluent",
        .linkage = .static,
        .root_module = c_mod,
    });
    const c_shared = b.addLibrary(.{
        .name = "fluent",
        .linkage = .dynamic,
        .version = parseVersion(manifest.version),
        .root_module = c_mod,
    });
    c_static.installHeader(b.path("include/fluent.h"), "fluent.h");

    const install_c = b.step("c", "Build and install the C library and its header");
    install_c.dependOn(&b.addInstallArtifact(c_static, .{}).step);
    install_c.dependOn(&b.addInstallArtifact(c_shared, .{}).step);
    install_c.dependOn(&b.addInstallFileWithDir(
        b.addWriteFiles().add("fluent.pc", pkgConfig(b)),
        .{ .custom = "share/pkgconfig" },
        "fluent.pc",
    ).step);
    b.getInstallStep().dependOn(install_c);

    // Ownership is the whole of what `src/c.zig` does, and a C program cannot
    // check its own for leaks. These can, because in a test build that file's
    // allocator is `std.testing.allocator` rather than libc's.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = c_mod })).step);

    // And the header from the outside: a C program that includes it, links the
    // static library and exercises the API the way a consumer would. It is the
    // only thing that can catch the header and an `export fn` drifting apart,
    // since nothing else in this build reads `include/fluent.h`.
    const c_api_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_test_mod.addCSourceFile(.{
        .file = b.path("tests/c_api.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_api_test_mod.addIncludePath(b.path("include"));
    c_api_test_mod.linkLibrary(c_static);

    const c_api_test = b.addExecutable(.{
        .name = "c-api-test",
        .root_module = c_api_test_mod,
    });

    const run_c_api_test = b.addRunArtifact(c_api_test);
    run_c_api_test.expectExitCode(0);
    test_step.dependOn(&run_c_api_test.step);
    check_step.dependOn(&c_api_test.step);
    check_step.dependOn(&c_shared.step);

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

/// The manifest's version as a `std.SemanticVersion`, for the shared library's
/// soname.
///
/// A version that does not parse is a mistake in `build.zig.zon` rather than
/// something to work around, so this stops the build rather than guessing.
fn parseVersion(text: []const u8) std.SemanticVersion {
    return std.SemanticVersion.parse(text) catch |err| std.debug.panic(
        "build.zig.zon has version \"{s}\", which is not a semantic version: {t}",
        .{ text, err },
    );
}

/// The pkg-config file, so that `pkg-config --cflags --libs fluent` answers.
///
/// Only `prefix` is a literal path; `libdir` and `includedir` are written in
/// terms of it, which is the convention every consumer of a `.pc` file expects
/// -- it is what lets `pkg-config --define-variable=prefix=...` relocate the
/// whole thing, and what lets a packaging tool rewrite one line rather than
/// three. Nix already relies on that: it moves the header into a separate
/// output and rewrites `includedir` to match.
fn pkgConfig(b: *std.Build) []const u8 {
    return b.fmt(
        \\prefix={s}
        \\exec_prefix=${{prefix}}
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: fluent
        \\Description: An implementation of Project Fluent, for C
        \\URL: https://git.jcollie.dev/jeff/zig-fluent
        \\Version: {s}
        \\Libs: -L${{libdir}} -lfluent
        \\Cflags: -I${{includedir}}
        \\
    , .{ b.install_prefix, manifest.version });
}
