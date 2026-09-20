// swift-tools-version:5.9
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

import PackageDescription

// The header and the library are not baked in anywhere: `Makefile` passes
// `-Xcc -I<prefix>/include` and hands the linker the archive by path, so the
// same package builds against this repository's `zig-out` or against an
// installed copy without being edited.
let package = Package(
	name: "Greeting",
	platforms: [.macOS(.v14)],
	targets: [
		// A C library SwiftPM does not build: the module map next door is
		// all Swift needs in order to import `fluent.h` as a module.
		.systemLibrary(name: "CFluent", path: "Sources/CFluent"),

		// The wrapper, which is the part worth reading. It is also what
		// the tests exercise, which is why it is a library rather than
		// being folded into the app.
		.target(name: "FluentKit", dependencies: ["CFluent"]),

		.executableTarget(name: "Greeting", dependencies: ["FluentKit"]),

		.testTarget(name: "FluentKitTests", dependencies: ["FluentKit"]),
	]
)
