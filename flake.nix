# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-fluent: a pure-Zig implementation of Project Fluent";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      # The devshell's Zig, with one line of its own standard library put
      # right, because without it `zig build fuzz --fuzz` cannot compile.
      #
      # Zig 0.16.0's `compiler/test_runner.zig` reports a failing fuzz input by
      # asking `std.debug.writeStackTrace` to print what `@errorReturnTrace()`
      # gave it. Those are two different types: an error return trace is a
      # `builtin.StackTrace`, a ring buffer with a write index, and that
      # function takes a `debug.StackTrace`, which is a plain slice and a count
      # of what was skipped. It is a type error, it is on the path taken only
      # under `-ffuzz`, and it stops *any* project with a fuzz test in it from
      # building one. The fix is the function next door: `writeErrorReturnTrace`
      # takes exactly the type in hand and is what the other three places in
      # the same file use.
      #
      # `--replace-fail` is the whole safety of this: the day Zig ships the fix
      # the pattern will not be found, the build will fail here rather than
      # patch something else, and this can go.
      #
      # It buys the fuzzer and not its coverage. Nothing in this release
      # populates the table of program counters, so a bounded run ends with
      # "corrupted coverage file: pcs_len was zero" and an unbounded one panics
      # in the build runner's coverage thread; neither is a finding, and a
      # finding says "input saved to" above the report. `zig build fuzz-run`
      # is the loop that does the work in the meantime.
      fuzzableZig =
        pkgs:
        let
          # A farm of symlinks rather than a copy: the library is 217 MB, and
          # exactly one file of it is being changed.
          library = pkgs.runCommand "zig-0.16.0-lib-fuzz-fix" { } ''
            cp -rs --no-preserve=mode ${pkgs.zig_0_16}/lib/zig $out
            chmod -R u+w $out
            rm $out/compiler/test_runner.zig
            cp --no-preserve=mode \
              ${pkgs.zig_0_16}/lib/zig/compiler/test_runner.zig \
              $out/compiler/test_runner.zig
            substituteInPlace $out/compiler/test_runner.zig \
              --replace-fail \
                'std.debug.writeStackTrace(trace, stderr)' \
                'std.debug.writeErrorReturnTrace(trace, stderr)'
          '';
        in
        pkgs.symlinkJoin {
          name = "zig-0.16.0-fuzzable";
          paths = [ pkgs.zig_0_16 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/zig --set ZIG_LIB_DIR ${library}
          '';
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          zig-fluent = pkgs.callPackage ./package.nix { };
          default = zig-fluent;

          # The dependency farm on its own, so that a workflow job which runs
          # `zig build` for something other than the package -- the API
          # documentation, say -- can hand Zig the same set without building
          # the package to get at it.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-fluent";
            nativeBuildInputs = [
              (fuzzableZig pkgs)
              pkgs.git-pages-cli
              pkgs.reuse

              # zon2nix shells out to `zig env`, and without a Zig on its PATH
              # it prints "unable to execute zig" and stops, having written
              # nothing -- which leaves the previous build.zig.zon.nix looking
              # untouched rather than obviously broken. Wrapping it pins the
              # Zig it finds to the one this project builds with.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
                '';
              })
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.kcov
            ];
          };
        }
      );
    };
}
