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
              pkgs.zig_0_17
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
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_17 ]}
                '';
              })
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.kcov

              # The GTK examples, which are built the way a C project builds
              # -- a compiler, a linker and a Makefile -- and find GTK the way
              # one does, through pkg-config. `gtk4` brings
              # `glib-compile-resources` and `gtk4-builder-tool` along with
              # it, which is how the second of the two turns its markup into
              # something the program can carry.
              pkgs.pkg-config
              pkgs.gtk4

              # And the compiler for that markup: `examples/gtk-blueprint`
              # writes its window in Blueprint and compiles it to GtkBuilder
              # XML. Nothing else in this repository needs it, and the
              # example's Makefile says so if it is missing.
              pkgs.blueprint-compiler

              # And run headless in CI. GTK 4 draws through GL by default and
              # there is no GL under Xvfb, so the Makefile's `smoke` target
              # asks for the cairo renderer as well as for a display.
              pkgs.xvfb-run
            ];
          };
        }
      );
    };
}
