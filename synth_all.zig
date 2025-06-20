//! Script to synthesize all of the testcases.
//! Output of the yosys command will be written to a log file alongside.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Progress = std.Progress;
const fs = std.fs;

const TESTCASE_DIR = "testcases/";
const OUTPUT_DIR = "output/";

/// Runs yosys synth_gal.tcl and writes the output to output/synth_basename_log.txt
fn synth(
    alloc: Allocator,
    path: []const u8,
) !void {
    var log_name_buf: [100]u8 = undefined;
    const log_name = try std.fmt.bufPrint(&log_name_buf, "synth_{s}_log.txt", .{fs.path.stem(path)});
    const log_path = try fs.path.join(alloc, &[_][]const u8{ OUTPUT_DIR, log_name });
    defer alloc.free(log_path);

    // build the yosys command.
    const args = [_][]const u8{ "yosys", "-c", "synth_gal.tcl", "--", path };
    var proc = std.process.Child.init(&args, alloc);
    // send it.
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    // open the file
    const log_file = try std.fs.cwd().createFile(log_path, .{});
    defer log_file.close();

    const writer = log_file.writer();
    const output = try proc.stdout.?.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(output);
    _ = try proc.wait();
    try writer.writeAll(output);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const progress = Progress.start(.{});
    defer progress.end();

    var testcase_dir = try fs.cwd().openDir(TESTCASE_DIR, .{ .iterate = true });
    defer testcase_dir.close();
    var test_walker = testcase_dir.iterate();

    // build the list
    var files = std.ArrayList([]const u8).init(allocator);
    defer {
        // loop through and free all the strings.
        for (files.items) |item| {
            allocator.free(item);
        }
        files.deinit();
    }

    const scan_progress = progress.start("scan", 0);
    while (try test_walker.next()) |item| {
        if (item.kind != .file) continue;

        if (!std.mem.endsWith(u8, item.name, ".v")) continue;

        const fullpath = try testcase_dir.realpathAlloc(allocator, item.name);
        try files.append(fullpath);
        scan_progress.completeOne();
    }
    scan_progress.end();
    // start executing the stuff.
    const synth_progress = progress.start("synth", files.items.len);
    for (files.items) |f| {
        try synth(allocator, f);
        synth_progress.completeOne();
    }
    synth_progress.end();
}
