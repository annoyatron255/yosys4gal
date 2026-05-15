//! Regression test framework.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const ChipType = @import("./chipinfo.zig").ChipType;
const yosys_netlist = @import("./yosys_netlist.zig");
const Netlist = yosys_netlist.Netlist;
const pcf = @import("./pcf.zig");
const TechMap = @import("./gal_techmap.zig").TechMap;
const jed = @import("./jed.zig");
const FuseMap = @import("./jed.zig").FuseMap;
const meta = @import("meta");

/// From a testing directory, you can get back to the cwd using this.
const tmp_to_cwd = "../../../";

const OUTPUT_DIR = "output/";

/// Synthesize a verilog testcase inside a tmpdir.
/// The tmpdir must be passed to the synth script. We assume it's in
/// .zig-cache/tmp/<random> and will traverse back to the cwd manually.
fn synth(alloc: Allocator, io: Io, name: []const u8, dir: Io.Dir) !std.json.Parsed(Netlist) {
    try dir.createDirPath(io, OUTPUT_DIR);

    // build the script path
    const path_to_script = try std.fs.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "synth_gal.tcl" });
    defer alloc.free(path_to_script);
    try dir.access(io, path_to_script, .{});
    // build the source path
    const src_name = try std.fmt.allocPrint(alloc, "{s}.v", .{name});
    defer alloc.free(src_name);
    const path_to_src = try std.fs.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "testcases", src_name });
    defer alloc.free(path_to_src);
    try dir.access(io, path_to_src, .{});

    const args = [_][]const u8{ "yosys", "-c", path_to_script, "--", path_to_src };
    var proc = try std.process.spawn(io, .{
        .argv = &args,
        .cwd = .{ .dir = dir },
        .stderr = .ignore,
        .stdout = .ignore,
    });

    _ = try proc.wait(io);

    const netlist_path = try std.fmt.allocPrint(alloc, "{s}/synth_{s}.json", .{ OUTPUT_DIR, name });
    defer alloc.free(netlist_path);
    const netlist_file = try dir.openFile(io, netlist_path, .{});
    defer netlist_file.close(io);
    var buf: [1024]u8 = undefined;
    var netlist_reader = netlist_file.reader(io, &buf);
    var reader = std.json.Reader.init(alloc, &netlist_reader.interface);
    defer reader.deinit();
    return try std.json.parseFromTokenSource(
        Netlist,
        alloc,
        &reader,
        .{ .ignore_unknown_fields = true },
    );
}

fn equivalence(alloc: Allocator, io: Io, name: []const u8, fmap: FuseMap, dir: Io.Dir) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}.jed", .{name});
    defer alloc.free(filename);
    // create our jed file.
    {
        var jed_buf: [256]u8 = undefined;
        var jed_file = try dir.createFile(io, filename, .{});
        defer jed_file.close(io);
        var jed_writer = jed_file.writer(io, &jed_buf);
        try fmap.writeJed(&jed_writer.interface, .{});
        try jed_writer.interface.flush();
    }

    const path_to_script = try Io.Dir.path.join(alloc, &[_][]const u8{ tmp_to_cwd, "models", "prove_equiv.tcl" });
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
    var proc = std.process.spawn(io, .{
        .argv = &args,
        .cwd = .{ .dir = dir },
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |other| return other,
    };

    const res = try proc.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res);
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
fn testFitterImpl(alloc: Allocator, io: Io, t: Test) anyerror!void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Synthesize the testcase with yosys
    const netlist = try synth(alloc, io, t.name, tmp.dir);

    defer netlist.deinit();

    const path = try std.fmt.allocPrint(alloc, "./testcases/{s}.pcf", .{t.name});
    defer alloc.free(path);
    var constraints = try pcf.readPcf(alloc, io, path);
    defer constraints.deinit();

    var tm = try TechMap.init(alloc, t.chip, &netlist.value);
    defer tm.deinit();
    try tm.applyConstraints(&constraints);
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
    try equivalence(alloc, io, t.name, fmap, tmp.dir);
}

fn testFitter(t: Test) !void {
    if (!meta.run_regression) {
        return error.SkipZigTest;
    }
    const alloc = testing.allocator;
    const io = testing.io;
    // try testing.checkAllAllocationFailures(alloc, testFitterImpl, .{t});
    try testFitterImpl(alloc, io, t);
}

test "gal16v8_olmc_test" {
    try testFitter(.{ .name = "olmc_test", .chip = .gal16v8 });
}
test "gal16v8_tiny_xor" {
    try testFitter(.{ .name = "tiny_xor", .chip = .gal16v8 });
}
test "gal16v8_tristate" {
    try testFitter(.{ .name = "tristate", .chip = .gal16v8 });
}
test "gal16v8_complex_single_sop" {
    try testFitter(.{ .name = "complex_single_sop", .chip = .gal16v8 });
}
test "gal16v8_and_gate" {
    try testFitter(.{ .name = "and_gate", .chip = .gal16v8 });
}
// fails - constraints file pin mapping is not the same.
// test "gal16v8_up_counter_downto" {
//     try testFitter(.{ .name = "up_counter_downto", .chip = .gal16v8 });
// }

test "gal22v10_olmc_test" {
    try testFitter(.{ .name = "olmc_test", .chip = .gal22v10 });
}
test "gal22v10_big_xor" {
    try testFitter(.{ .name = "big_xor", .chip = .gal22v10 });
}
test "gal22v10_tiny_xor" {
    try testFitter(.{ .name = "tiny_xor", .chip = .gal22v10 });
}
test "gal22v10_tristate" {
    try testFitter(.{ .name = "tristate", .chip = .gal22v10 });
}
test "gal22v10_complex_single_sop" {
    try testFitter(.{ .name = "complex_single_sop", .chip = .gal22v10 });
}
test "gal22v10_and_gate" {
    try testFitter(.{ .name = "and_gate", .chip = .gal22v10 });
}
test "gal22v10_up_counter_downto" {
    try testFitter(.{ .name = "up_counter_downto", .chip = .gal22v10 });
}
