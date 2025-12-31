//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("mkjed_lib");
const flags = @import("./util/flags.zig");

const pcf = lib.pcf;
test {
    _ = flags;
}
const yosys_netlist = lib.yosys_netlist;

const CLIArgs = union(enum) {
    build: struct {
        binary: bool = false,
        // add this back when we support 22v10
        chiptype: lib.info.ChipType = .gal16v8,
        positional: struct {
            netlist: []const u8,
            constraints: ?[]const u8 = null,
            output: ?[]const u8 = null,
        },
    },
    validate: struct {
        binary: bool = false,
    },

    pub const help =
        \\ mkjed build [--binary] [--chiptype=<type>] <netlist> [constraints] [output]
        \\ mkjed validate [--verbose] <file>
        \\ supported chip types are gal16v8 (default) or gal22v10
        \\
    ;
};

pub fn main() !void {
    var args = std.process.args();
    const cli_args = try flags.parse(CLIArgs, &args);
    switch (cli_args) {
        .validate => {
            try validateNetlist(true, "hi.txt");
        },
        .build => |b| {
            try build(
                b.chiptype,
                b.positional.netlist,
                b.positional.constraints,
                b.positional.output,
            );
        },
    }
}

pub fn build(chiptype: lib.info.ChipType, netlist_path: []const u8, pcf_path: ?[]const u8, output: ?[]const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const netlist = try yosys_netlist.readNetlist(allocator, netlist_path);
    defer netlist.deinit();
    var constraints: pcf.PinConstraints = blk: {
        if (pcf_path) |path| {
            break :blk try pcf.readPcf(allocator, path);
        }
        break :blk pcf.PinConstraints.init(allocator);
    };
    defer constraints.deinit();

    var writer_buf: [1024]u8 = undefined;
    var out_file: std.fs.File = blk: {
        if (output) |out_path| {
            break :blk try std.fs.cwd().createFile(out_path, .{});
        } else {
            break :blk std.fs.File.stdout();
        }
    };
    defer out_file.close();

    var file_writer = out_file.writer(&writer_buf);

    var tm = try lib.techmap.TechMap.init(allocator, chiptype, &netlist.value);
    defer tm.deinit();
    try tm.applyConstraints(constraints);
    // create the gal
    var gal = try tm.mapChip();
    defer gal.deinit();
    // create the fuse map and then synthesize.
    var fmap = try lib.jed.FuseMap.init(
        allocator,
        chiptype.getSpec().fusemap_size,
        chiptype.getSpec().num_pins,
        false,
    );
    defer fmap.deinit();
    try gal.synthesize(&fmap);

    const comment = try std.fmt.allocPrint(allocator,
        \\chip: {s}
        \\source: {s}
        \\yosys: {s}
        \\
    , .{ @tagName(chiptype), netlist_path, netlist.value.creator});

    try fmap.writeJed(&file_writer.interface, .{ .comment = comment });
    try file_writer.interface.flush();
}

pub fn validateNetlist(verbose: bool, path: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    _ = verbose;
    const netlist = try yosys_netlist.readNetlist(allocator, path);
    defer netlist.deinit();
}
