//! Regression test framework.

const std = @import("std");
const testing = std.testing;
const chipinfo = @import("./chipinfo.zig");
const ChipType = chipinfo.ChipType;
const yosys_netlist = @import("./yosys_netlist.zig");
const Netlist = yosys_netlist.Netlist;
const pcf = @import("./pcf.zig");
const xv8 = @import("./gal_xV8.zig");
const TechMap = @import("./gal_techmap.zig").TechMap;
const FuseMap = @import("./jed.zig").FuseMap;

const Test = struct {
    /// The name of the test file - used to find both the PCF and the netlist json
    name: []const u8,
    /// The chip we are trying to synthesize for
    chip: ChipType,
    /// If we expect this test to pass or fail.
    /// If a test passes when it should fail, we print a warning to the log.
    passes: bool,
};

const tests: []const Test = &[_]Test{
    .{ .chip = .gal16v8, .name = "olmc_test", .passes = true },
    .{ .chip = .gal16v8, .name = "nand_gate", .passes = true },
    .{ .chip = .gal16v8, .name = "big_xor", .passes = true },
};

/// Test helper function
fn testFitter(t: Test) anyerror!void {
    const alloc = testing.allocator;
    // This is all netlist setup
    const netlist = blk: {
        const path = try std.fmt.allocPrint(alloc, "./output/synth_{s}.json", .{t.name});
        defer alloc.free(path);

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var reader = std.json.reader(alloc, file.reader());
        defer reader.deinit();
        break :blk try std.json.parseFromTokenSource(
            Netlist,
            alloc,
            &reader,
            .{ .ignore_unknown_fields = true },
        );
    };
    defer netlist.deinit();

    var constraints = blk: {
        var c = pcf.PinConstraints.init(alloc);

        const path = try std.fmt.allocPrint(alloc, "./testcases/{s}.pcf", .{t.name});
        defer alloc.free(path);
        const pcf_file = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024);
        defer alloc.free(pcf_file);
        try c.parseSlice(pcf_file);
        break :blk c;
    };
    defer constraints.deinit();
    var tm = try TechMap.init(alloc, t.chip, &netlist.value);
    defer tm.deinit();
    try tm.applyConstraints(constraints);
    // create the gal
    var gal = try tm.mapChip();
    defer gal.deinit();
    // create the fuse map and then synthesize.
    var fmap = try FuseMap.init(
        alloc,
        t.chip.getSpec().fusemap_size,
        t.chip.getSpec().num_pins,
        false,
    );
    defer fmap.deinit();
    try gal.synthesize(&fmap);
}
test "regression_olmc_test" {
    try testFitter(.{
        .chip = .gal16v8,
        .name = "olmc_test",
        .passes = true,
    });
}
test "regression_big_xor" {
    try testFitter(.{
        .chip = .gal16v8,
        .name = "big_xor",
        .passes = true,
    });
}
test "regression_tiny_xor" {
    try testFitter(.{
        .chip = .gal16v8,
        .name = "tiny_xor",
        .passes = true,
    });
}
// test "regression_tristate" {
//     try testFitter(.{
//         .chip = .gal16v8,
//         .name = "tristate",
//         .passes = true,
//     });
// }
// test "regression_and_gate" {
//     try testFitter(.{
//         .chip = .gal16v8,
//         .name = "and_gate",
//         .passes = true,
//     });
// }
