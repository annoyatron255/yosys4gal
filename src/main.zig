//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const flags = @import("./util/flags.zig");

test {
    _ = flags;
}
const yosys_netlist = lib.yosys_netlist;

const CLIArgs = union(enum) {
    build: struct {
        type: []const u8,
        mode: []const u8,
        positional: struct {
            netlist: []const u8,
            constraints: ?[]const u8 = null,
        },
    },
    validate: struct {
        verbose: bool = false,
        positional: struct {
            file: []const u8,
        },
    },

    pub const help =
        \\ mkjed build --type=<type> --mode=<mode> <netlist> [constraints]
        \\ mkjed validate [--verbose] <file>
        \\
    ;
};

pub fn main() !void {
    var args = std.process.args();
    const cli_args = flags.parse(&args, CLIArgs);
    switch (cli_args) {
        .validate => |v| {
            try validateNetlist(v.verbose, v.positional.file);
        },
        .build => |b| {
            _ = b;
        },
    }
}

pub fn validateNetlist(verbose: bool, path: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    _ = verbose;
    const f = try std.fs.cwd().readFileAlloc(allocator, path, 8192 * 4096);
    defer allocator.free(f);
    const netlist = try std.json.parseFromSlice(yosys_netlist.Netlist, allocator, f, .{
        .ignore_unknown_fields = true,
    });
    defer netlist.deinit();
}

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("mkjed_lib");
