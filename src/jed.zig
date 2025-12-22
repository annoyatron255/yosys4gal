//! JED file (fuse map) format support.
//! Good references:
//! https://git.redump.net/mame/tree/src/tools/jedutil.cpp
//! https://k1.spdns.de/Develop/Projects/GalAsm/info/galer/jedecfile.html
//!
//! The general usage is that a higher-level construct should represent
//! blocks in the chip. Then those blocks can be converted into fuse slices
//! at various offsets and applied to the fuse map using `setSlice()`
//! Then the write_jed method takes that fuse map and outputs a valid JED file.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const chipinfo = @import("./chipinfo.zig");
const meta = @import("meta");

fn bool2char(val: bool) u8 {
    return if (val) '1' else '0';
}

/// Compact a slice of bools to bytes.
/// the 0th bool becomes the msb of the byte.
fn boolpack(comptime T: type, vals: []const bool) T {
    const info = @typeInfo(T);
    assert(vals.len <= info.int.bits);
    var result: T = 0;
    for (vals, 0..) |v, idx| {
        if (v) {
            result |= @as(T, 1) << @intCast(info.int.bits - idx - 1);
        }
    }
    return result;
}

test boolpack {
    const expected: u8 = 0b01011111;
    const input = &.{ false, true, false, true, true, true, true, true };
    const actual = boolpack(u8, input);

    try testing.expectEqual(expected, actual);
}

/// JEDEC 16-bit checksum for fuses.
const Checksum = struct {
    bit: u8 = 0,
    byte: u8 = 0,
    sum: u16 = 0,

    pub fn add(self: *@This(), bit: bool) void {
        // construct a byte from 8 bools
        if (bit) {
            self.byte |= @as(u8, 1) << @truncate(self.bit);
        }
        self.bit += 1;

        // we finished a byte, so add it with overflow
        // and reset
        if (self.bit == 8) {
            self.sum = @addWithOverflow(self.sum, self.byte).@"0";
            self.byte = 0;
            self.bit = 0;
        }
    }

    pub fn get(self: *@This()) u16 {
        // include the last byte, since we might not be at a byte boundary
        return self.sum + self.byte;
    }
};

/// File checksum for jedec whole file.
/// note that this is not related to the fuse checksum above
fn file_checksum(data: []const u8) u16 {
    var sum: u16 = 0;
    for (data) |byte| {
        sum = @addWithOverflow(sum, byte).@"0";
    }
    return sum;
}

const jedFileChecksum = struct {
    sum: u16 = 0,
    pub fn update(self: *jedFileChecksum, data: []const u8) void {
        for (data) |byte| {
            self.sum = @addWithOverflow(self.sum, byte).@"0";
        }
    }
};

const jedHeader = std.fmt.comptimePrint(
    \\GAL Assembler: mkjed {s}
    \\Zig version: {s}
, .{ meta.version, builtin.zig_version_string });

/// options for the JED serialization
pub const jedOptions = struct {
    /// Additional note to put at the start of the file.
    comment: []const u8 = "",
    /// Length of the fuse statement "L" blocks.
    /// Note that if a chunk of fuses is all the default value,
    /// it will be skipped.
    fuse_segment_size: usize = 32,
};

/// Low-level fuse map file.
/// contains a number of bits which are 0 or 1.
/// This file is then written to a .jed
pub const FuseMap = struct {
    allocator: std.mem.Allocator,
    /// Number of fuses in the file
    qf: usize,
    /// Number of pins on the device
    qp: usize,
    /// What the default (unspecified) fuse state should be
    default_state: bool = false,

    /// If the security fuse should be set
    security: bool = false,

    /// the actual fuses.
    fuses: []bool,

    /// Initializes a new fuse map
    pub fn init(allocator: std.mem.Allocator, n_fuses: usize, pins: usize, default_state: bool) !FuseMap {
        const fuses: []bool = try allocator.alloc(bool, n_fuses);
        errdefer allocator.free(fuses);
        @memset(fuses, default_state);
        return .{
            .allocator = allocator,
            .default_state = default_state,
            .qf = n_fuses,
            .qp = pins,
            .fuses = fuses,
        };
    }

    /// Tear down the fuse map.
    pub fn deinit(self: *FuseMap) void {
        self.allocator.free(self.fuses);
    }

    /// Set the fusemap bit to the provided value
    pub fn set(self: *FuseMap, fuse: usize, value: bool) !void {
        if (fuse >= self.qf) {
            return error.OutOfBounds;
        }
        self.fuses[fuse] = value;
    }

    /// Copies the given slice to the fuse map at the start offset.
    /// This is often used for OLMCs or other blocks. The block will have a
    /// `to_fuses` function or similar which will give a bare configuration
    /// then you can use that plus the offset for that block to write the
    /// instance to the map.
    pub fn setSlice(self: *FuseMap, start: usize, data: []const bool) !void {
        const end = start + data.len;
        // bounds check.
        if (end > self.qf) {
            return error.OutOfBounds;
        }
        @memcpy(self.fuses[start..end], data);
    }

    /// Compute the checksum of the fuses.
    fn computeChecksum(self: FuseMap) u16 {
        var chksum = Checksum{};
        for (self.fuses) |fuse| {
            chksum.add(fuse);
        }
        return chksum.get();
    }

    /// Write the fusemap in the jed format to the given output.
    pub fn writeJed(self: FuseMap, output: *std.io.Writer, options: jedOptions) !void {
        // internal write out buffer
        var buf: [1024]u8 = undefined;
        // we want a checksum of the written contents.
        var hasher = std.io.Writer.Hashed(jedFileChecksum).init(output, &buf);
        var writer = &hasher.writer;

        // start of file
        try writer.writeAll(&.{ 0x02, '\n' });
        try writer.writeAll(jedHeader);
        try writer.print("\n{s}*\n", .{options.comment});
        // start writing fuse information.
        // default fuse value and parameters
        try writer.print(
            \\F{c}*
            \\G{c}*
            \\QF{}*
            \\QP{}*
            \\
        , .{ bool2char(self.default_state), bool2char(self.security), self.qf, self.qp });

        // chunk the fuse map into blocks.
        var i: usize = 0;
        // allocate a chunk of text.
        var chunk_text = try self.allocator.alloc(u8, options.fuse_segment_size);
        defer self.allocator.free(chunk_text);
        while (i < self.fuses.len) {
            const remaining = self.fuses.len - i;
            const chunk_size = @min(options.fuse_segment_size, remaining);
            const chunk_bits = self.fuses[i .. i + chunk_size];
            // process this chunk.

            // first we check if any of the values in our chunk are not default.
            var should_write = false;
            for (chunk_bits) |bit| {
                if (bit != self.default_state) {
                    should_write = true;
                    break;
                }
            }
            // if we have a non-default, we write the entire chunk.
            if (should_write) {
                // construct the chunk_text.
                for (chunk_bits, 0..) |bit, idx| {
                    chunk_text[idx] = bool2char(bit);
                }
                // now, print the index, as well as the actual fuse contents.
                try writer.print("L{} {s}*\n", .{ i, chunk_text[0..chunk_size] });
            }

            // move our index to where the chunk ends.
            i += chunk_size;
        }
        // add the checksum.
        const chk = self.computeChecksum();
        try writer.print("C{x:04}*\n", .{chk});
        try writer.writeAll(&.{0x03});
        try writer.flush(); // this flush makes it so that the checksum is updated.

        // append the checksum - note that the checksum changes after this write!
        try writer.print("{x:04}", .{hasher.hasher.sum});
        try writer.flush();
    }

    /// Writes the binary output using jedutil's binary format.
    /// The format contains a u32 for the fuse count, and then
    /// bit-packed fuse bits. This is largely untested.
    pub fn writeBin(self: FuseMap, output: *std.io.Writer) !void {
        // first, write the length as a 4-byte value.
        try output.writeInt(u32, @intCast(self.fuses.len), .big);
        var count: u3 = 0;
        var byte: u8 = 0;
        for (self.fuses) |fuse| {
            byte &= @as(u8, @intFromBool(fuse)) << count;
            if (count == 7) {
                try output.writeByte(byte);
                byte = 0;
                count = 0;
            } else {
                count = count + 1;
            }
        }
        // flush the last partial
        if (count != 0) {
            try output.writeByte(byte);
        }
        try output.flush();
    }
};

test FuseMap {
    const alloc = std.testing.allocator;
    var fmap = try FuseMap.init(alloc, 100, 20, false);
    defer fmap.deinit();

    try fmap.set(0, true);
    try std.testing.expectError(error.OutOfBounds, fmap.set(100, true));
    try std.testing.expectEqual(true, fmap.fuses[0]);

    const fblock: []const bool = &.{ false, true, true, false };
    try fmap.setSlice(96, fblock);
    try std.testing.expectError(error.OutOfBounds, fmap.setSlice(97, fblock));
}

test "writeJed" {
    const expected_file = std.fmt.comptimePrint(
        \\{c}
        \\{s}
        \\*
        \\F0*
        \\G0*
        \\QF64*
        \\QP20*
        \\L0 10000000000000000000000000000000*
        \\C0001*
        \\{c}
    , .{ 0x02, jedHeader, 0x03 });
    const alloc = std.testing.allocator;
    var fmap = try FuseMap.init(alloc, 64, 20, false);
    defer fmap.deinit();
    try fmap.set(0, true);

    var output = std.io.Writer.Allocating.init(alloc);
    defer output.deinit();

    try fmap.writeJed(&output.writer, .{});

    var buf = output.toArrayList();
    defer buf.deinit(alloc);

    // skip the checksum, since it depends on the zig version.
    // use slices, since we have the 0x02 and 0x03.
    try std.testing.expectEqualSlices(u8, expected_file, buf.items[0 .. buf.items.len - 4]);
}

// test to see if the jed is valid. using jedutil.

test "jedutil valid jed" {
    const alloc = testing.allocator;
    var fmap = try FuseMap.init(alloc, 2194, 20, false);
    defer fmap.deinit();

    try fmap.set(768, true);
    try testJedutil(alloc, fmap, .gal16v8, .jed);
}
test "jedutil valid bin" {
    const alloc = testing.allocator;
    var fmap = try FuseMap.init(alloc, 2194, 20, false);
    defer fmap.deinit();

    try fmap.set(768, true);
    try testJedutil(alloc, fmap, .gal16v8, .bin);
}

pub const JedMode = enum {
    jed,
    bin,
};

/// Validate the fusemap with jedutil if present, skipping the test otherwise.
/// Can only be called as part of a test
pub fn testJedutil(alloc: std.mem.Allocator, fmap: FuseMap, chip: chipinfo.ChipType, mode: JedMode) !void {
    const file = try std.fmt.allocPrint(alloc, "output.{s}", .{@tagName(mode)});
    defer alloc.free(file);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // create the jed file.
    {
        var out = try tmp.dir.createFile(file, .{});
        var buf: [1024]u8 = undefined;
        var writer = out.writer(&buf);
        defer out.close();

        switch (mode) {
            .jed => try fmap.writeJed(&writer.interface, .{}),
            .bin => try fmap.writeBin(&writer.interface),
        }
        try writer.interface.flush();
    }

    // invoke jedutil -view output.jed gal16v8
    const args = [_][]const u8{ "jedutil", "-view", file, @tagName(chip) };
    var proc = std.process.Child.init(&args, alloc);
    proc.cwd_dir = tmp.dir;
    proc.stdout_behavior = .Ignore;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();
    // assert that the stderr is empty

    const output = try proc.stderr.?.readToEndAlloc(alloc, 1024);
    defer alloc.free(output);

    const res = proc.wait() catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |other| return other,
    };
    testing.expectEqual(0, output.len) catch |err| {
        std.debug.print("unexpected jedutil output: {s}", .{output});
        return err;
    };

    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, res);
}
