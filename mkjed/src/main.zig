//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const flags = @import("./flags.zig");

const CLIArgs = union(enum) {
    build: struct {
        type: []const u8,
        mode: []const u8,
        positional: struct {
            file: []const u8,
        },
    },
    format: struct {
        verbose: bool = false,
        positional: struct {
            file: []const u8,
        },
    },

    pub const help =
        \\ mkjed build --type=<type> --mode=<mode> <file>
        \\ mkjed format [--verbose] <file>
        \\
    ;
};

pub fn main() !void {
    var args = std.process.args();
    const cli_args = flags.parse(&args, CLIArgs);
    _ = cli_args;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("mkjed_lib");
