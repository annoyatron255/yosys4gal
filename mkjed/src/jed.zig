//! JED file (fuse map) format support.
//! Good references:
//! https://git.redump.net/mame/tree/src/tools/jedutil.cpp MAME
//! https://k1.spdns.de/Develop/Projects/GalAsm/info/galer/jedecfile.html
//!
//! The general usage is that a higher-level construct should represent
//! blocks in the chip. Then those blocks can be converted into fuse slices
//! at various offsets and applied to the fuse map using `setSlice()`
//! Then the write_jed method takes that fuse map and outputs a valid JED file.

const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");

fn bool2char(val: bool) u8 {
    return if (val) '1' else '0';
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
pub const FuseMap = struct {
    allocator: std.mem.Allocator,
    /// Number of fuses in the file
    qf: u16,
    /// Number of pins on the device
    qp: u16,
    /// What the default (unspecified) fuse state should be
    default_state: bool = false,

    /// If the security fuse should be set
    security: bool = false,

    /// the actual fuses.
    fuses: []bool,

    /// Initializes a new fuse map
    pub fn init(allocator: std.mem.Allocator, fuses: u16, pins: u16, default_state: bool) !FuseMap {
        const fusemap: []bool = try allocator.alloc(bool, fuses);
        errdefer allocator.free(fusemap);
        @memset(fusemap, default_state);
        return .{
            .allocator = allocator,
            .default_state = default_state,
            .qf = fuses,
            .qp = pins,
            .fuses = fusemap,
        };
    }

    /// Tear down the fuse map.
    pub fn deinit(self: *FuseMap) void {
        self.allocator.free(self.fuses);
    }

    /// Set the fusemap bit to the provided value
    pub fn set(self: *FuseMap, fuse: u16, value: bool) !void {
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
    pub fn setSlice(self: *FuseMap, start: u16, data: []const bool) !void {
        // bounds check.
        if (start + data.len > self.qf) {
            return error.OutOfBounds;
        }
        @memcpy(self.fuses[start..], data);
    }

    /// Compute the checksum of the fuses.
    fn computeChecksum(self: *FuseMap) u16 {
        var chksum = Checksum{};
        for (self.fuses) |fuse| {
            chksum.add(fuse);
        }
        return chksum.get();
    }

    /// Write the fusemap in the jed format to the given output.
    pub fn writeJed(self: *FuseMap, output: anytype, options: jedOptions) !void {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 8192);
        defer buf.deinit();
        // write to this buffer
        var writer = buf.writer();
        // start of file
        try writer.writeAll(&.{ 0x02, '\n' });
        try writer.writeAll(jedHeader);
        try writer.print("\n{s}*\n", .{options.comment});
        // start writing fuse information.
        // default fuse value
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
            const chunk = self.fuses[i .. i + chunk_size];
            // process this chunk.

            // this is mildly inefficient.
            // first we check if any of the values in our chunk are not default.
            var should_write = false;
            for (chunk) |bit| {
                if (bit != self.default_state) {
                    should_write = true;
                    break;
                }
            }
            if (should_write) {
                // construct the chunk_text.
                for (chunk, 0..) |bit, idx| {
                    chunk_text[idx] = bool2char(bit);
                }
                // now, print the index, as well as the actual fuse contents.
                try writer.print("L{} {s}*\n", .{ i, chunk_text });
            }

            // move our index to where the chunk ends.
            i += chunk_size;
        }
        // add the checksum.
        const chk = self.computeChecksum();
        try writer.print("C{x:04}*\n", .{chk});
        try writer.writeAll(&.{0x03});

        const file_chk = file_checksum(buf.items);
        try writer.print("{x:04}", .{file_chk});
        // now, dump our finalized buffer to the output.
        try output.writeAll(buf.items);
    }
};

test "fusemap" {
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

test "jed file" {
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
        \\{c}1e8a
    , .{ 0x02, jedHeader, 0x03 });
    const alloc = std.testing.allocator;
    var fmap = try FuseMap.init(alloc, 64, 20, false);
    defer fmap.deinit();
    try fmap.set(0, true);

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    try fmap.writeJed(output.writer(), .{});

    try std.testing.expectEqualSlices(u8, expected_file, output.items);
}
