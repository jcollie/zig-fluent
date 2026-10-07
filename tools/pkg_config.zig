// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Write `fluent.pc`, given the install prefix and everything after it.
//!
//! ```console
//! $ pkg-config-writer OUTPUT PREFIX BODY
//! ```
//!
//! The build script cannot write the file itself, because the install prefix
//! is not known while the build is being configured -- only once it runs. So
//! `build.zig` formats every line but the first and hands this the prefix as a
//! path the build runner resolves when it runs the step.
//!
//! That path may be relative -- `--prefix zig-out` is an ordinary thing to
//! write -- and a `.pc` file is read from anywhere but here, so it is made
//! absolute against the directory this runs in.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 4) {
        std.debug.print("usage: {s} OUTPUT PREFIX BODY\n", .{args[0]});
        std.process.exit(2);
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const prefix = try std.fs.path.resolve(arena, &.{ cwd, args[2] });

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = args[1],
        .data = try contents(arena, prefix, args[3]),
    });
}

fn contents(arena: std.mem.Allocator, prefix: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "prefix={s}\n{s}", .{ prefix, body });
}

test contents {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "prefix=/usr\nlibdir=${prefix}/lib\n",
        try contents(arena.allocator(), "/usr", "libdir=${prefix}/lib\n"),
    );
}
