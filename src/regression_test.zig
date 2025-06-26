//! Regression test framework.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const chipinfo = @import("./chipinfo.zig");
const ChipType = chipinfo.ChipType;
const yosys_netlist = @import("./yosys_netlist.zig");
const Netlist = yosys_netlist.Netlist;
const pcf = @import("./pcf.zig");
const xv8 = @import("./gal_xV8.zig");
const TechMap = @import("./gal_techmap.zig").TechMap;
const jed = @import("./jed.zig");
const FuseMap = @import("./jed.zig").FuseMap;

const Test = struct {
    /// The name of the test file - used to find both the PCF and the netlist json
    name: []const u8,
    /// The chip we are trying to synthesize for
    chip: ChipType = .gal16v8,
    /// If we expect this test to pass or fail.
    /// If a test passes when it should fail, we print a warning to the log.
    passes: bool = true,
};

/// Test helper function
fn testFitterImpl(alloc: Allocator, t: Test) anyerror!void {
    // This is all netlist setup
    const netlist_path = try std.fmt.allocPrint(alloc, "./output/synth_{s}.json", .{t.name});
    defer alloc.free(netlist_path);
    const netlist = try yosys_netlist.readNetlist(alloc, netlist_path);
    defer netlist.deinit();

    const path = try std.fmt.allocPrint(alloc, "./testcases/{s}.pcf", .{t.name});
    defer alloc.free(path);
    var constraints = try pcf.readPcf(alloc, path);
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
    try jed.testJedutil(alloc, fmap, .jed);
}

fn testFitter(t: Test) !void {
    const alloc = testing.allocator;
    // try testing.checkAllAllocationFailures(alloc, testFitterImpl, .{t});
    try testFitterImpl(alloc, t);
}
test "regression_olmc_test" {
    try testFitter(.{ .name = "olmc_test" });
}
test "regression_big_xor" {
    try testFitter(.{ .name = "big_xor" });
}
test "regression_tiny_xor" {
    try testFitter(.{ .name = "tiny_xor" });
}
test "regression_tristate" {
    try testFitter(.{ .name = "tristate" });
}
// test "regression_and_gate" {
//     try testFitter(.{
//         .chip = .gal16v8,
//         .name = "and_gate",
//         .passes = true,
//     });
// }
