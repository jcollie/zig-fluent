# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  callPackage,
  zig_0_16,
}:
let
  # Generated from build.zig.zon by zon2nix; regenerate with
  #   nix develop -c zon2nix --16 --nix=build.zig.zon.nix build.zig.zon
  zigDeps = callPackage ./build.zig.zon.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zig-fluent";
  version = "0.1.0";

  # Named rather than filtered, so that editing something outside this list --
  # the flake, a scratch file, the plan -- does not rebuild the package.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./examples
      ./include
      ./src
      ./tests
      ./tools
      ./LICENSES
      ./README.md
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_16 ];

  # `--system` does not merely offer the directory, it forbids fetching
  # outright, so a dependency missing from the farm is a build error naming the
  # package rather than a silent reach for a network the sandbox does not have.
  zigBuildFlags = [
    "--system"
    "${zigDeps}"
  ];
  # The check phase assembles its own flags rather than reusing the build's, so
  # without this `zig build test` runs without --system and tries to fetch.
  zigCheckFlags = finalAttrs.zigBuildFlags;

  # The tests are pure -- a parser, a resolver and a table of locale data, with
  # no clock, no network and no files but the conformance fixtures, which come
  # from the dependency farm. So they run here rather than only in CI, and are
  # most of what this derivation is for.
  #
  # They include a C program compiled against `include/fluent.h` and linked
  # against the static library, which is what proves the two agree.
  doCheck = true;

  # `zig build` installs the C library -- `libfluent.a`, `libfluent.so`, the
  # header and a pkg-config file -- alongside the API documentation. A Zig
  # consumer needs none of it, since a Zig library is consumed as source
  # through the package manager; a C one needs nothing else.
  outputs = [
    "out"
    "dev"
  ];

  postInstall = ''
    moveToOutput include "$dev"
    moveToOutput share/pkgconfig "$dev"
  '';

  meta = {
    description = "An implementation of Project Fluent for Zig";
    longDescription = ''
      Localization for Zig built on Project Fluent, with CLDR plural rules,
      number formatting and date formatting generated into the library rather
      than delegated to ICU. The derivation builds and tests the library and
      installs its API documentation along with a C library and header, so
      that a project in any language that can call C can use it.
    '';
    homepage = "https://git.jcollie.dev/jeff/zig-fluent";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
