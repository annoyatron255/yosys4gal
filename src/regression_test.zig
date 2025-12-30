//! Regression test framework.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ChipType = @import("./chipinfo.zig").ChipType;
const yosys_netlist = @import("./yosys_netlist.zig");
const Netlist = yosys_netlist.Netlist;
const pcf = @import("./pcf.zig");
const TechMap = @import("./gal_techmap.zig").TechMap;
const jed = @import("./jed.zig");
const FuseMap = @import("./jed.zig").FuseMap;

/// From a testing directory, you can get back to the cwd using this.
const tmp_to_cwd = "../../../";

const OUTPUT_DIR = "output/";

/// Synthesize a verilog testcase inside a tmpdir.
/// The tmpdir must be passed to the synth script. We assume it's in
/// .zig-cache/tmp/<random> and will traverse back to the cwd manually.
fn synth(alloc: Allocator, name: []const u8, dir: std.fs.Dir) !std.json.Parsed(Netlist) {
    try dir.makePath(OUTPUT_DIR);

    // build the script path
    const path_to_script = try std.fs.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "synth_gal.tcl" });
    defer alloc.free(path_to_script);
    try dir.access(path_to_script, .{});
    // build the source path
    const src_name = try std.fmt.allocPrint(alloc, "{s}.v", .{name});
    defer alloc.free(src_name);
    const path_to_src = try std.fs.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "testcases", src_name });
    defer alloc.free(path_to_src);
    try dir.access(path_to_src, .{});

    const args = [_][]const u8{ "yosys", "-c", path_to_script, "--", path_to_src };
    var proc = std.process.Child.init(&args, alloc);
    // run inside the tmp dir, using the relative paths.
    proc.cwd_dir = dir;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;
    try proc.spawn();

    _ = try proc.wait();

    const netlist_path = try std.fmt.allocPrint(alloc, "{s}/synth_{s}.json", .{ OUTPUT_DIR, name });
    defer alloc.free(netlist_path);
    const netlist_file = try dir.openFile(netlist_path, .{});
    defer netlist_file.close();
    var buf: [1024]u8 = undefined;
    var netlist_reader = netlist_file.reader(&buf);
    var reader = std.json.Reader.init(alloc, &netlist_reader.interface);
    defer reader.deinit();
    return try std.json.parseFromTokenSource(
        Netlist,
        alloc,
        &reader,
        .{ .ignore_unknown_fields = true },
    );
}

fn equivalence(alloc: Allocator, name: []const u8, fmap: FuseMap, dir: std.fs.Dir) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}.jed", .{name});
    defer alloc.free(filename);
    // create our jed file.
    {
        var jed_buf: [256]u8 = undefined;
        var jed_file = try dir.createFile(filename, .{});
        defer jed_file.close();
        var jed_writer = jed_file.writer(&jed_buf);
        try fmap.writeJed(&jed_writer.interface, .{});
        try jed_writer.interface.flush();

    }

    const path_to_script = try std.fs.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "models", "prove_equiv.tcl" });
    defer alloc.free(path_to_script);
    const pcf_name = try std.fmt.allocPrint(alloc, "../../../testcases/{s}.pcf", .{name});
    defer alloc.free(pcf_name);
    const vlog_name = try std.fmt.allocPrint(alloc, "../../../testcases/{s}.v", .{name});
    defer alloc.free(vlog_name);
    const args = [_][]const u8{
        "yosys",
        "-c",
        path_to_script,
        "--",
        filename,
        pcf_name,
        vlog_name,
    };
    var proc = std.process.Child.init(&args, alloc);
    proc.cwd_dir = dir;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Ignore;

    try proc.spawn();

    const res = proc.wait() catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |other| return other,
    };
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, res);
}

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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Synthesize the testcase with yosys
    const netlist = try synth(alloc, t.name, tmp.dir);

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
    // try jed.testJedutil(alloc, fmap, t.chip, .jed);
    try equivalence(alloc, t.name, fmap, tmp.dir);
}

fn testFitter(t: Test) !void {
    const alloc = testing.allocator;
    // try testing.checkAllAllocationFailures(alloc, testFitterImpl, .{t});
    try testFitterImpl(alloc, t);
}
test "regression olmc_test" {
    try testFitter(.{ .name = "olmc_test" });
}
// test "regression big_xor" {
//     try testFitter(.{ .name = "big_xor", .passes = false });
// }
test "regression tiny_xor" {
    try testFitter(.{ .name = "tiny_xor" });
}
test "tristate" {
    try testFitter(.{ .name = "tristate" });
}
// test "tristate gal22v10" {
//     try testFitter(.{ .name = "tristate", .chip = .gal22v10 });
// }
test "regression complex_single_sop" {
    try testFitter(.{ .name = "complex_single_sop" });
}
test "regression_and_gate" {
    try testFitter(.{
        .chip = .gal16v8,
        .name = "and_gate",
        .passes = true,
    });
}
