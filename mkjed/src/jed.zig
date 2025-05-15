//! JED file (fuse map) format support.
//! Good references:
//! https://git.redump.net/mame/tree/src/tools/jedutil.cpp MAME
//! https://k1.spdns.de/Develop/Projects/GalAsm/info/galer/jedecfile.html
//!
//! The general usage is that a higher-level construct should represent
//! blocks in the chip. Then those blocks can be converted into fuse slices
//! at various offsets and applied to the fuse map using `setSlice()`
//! Then the write_jed function takes that fuse map and outputs a valid JED file.

const std = @import("std");

/// JEDEC 16-bit checksum for fuses.
const Checksum = struct {
    bit: u8,
    byte: u8,
    sum: u16,

    pub fn add(self: *@This(), bit: bool) void {
        // construct a byte from 8 bools
        if (bit) {
            self.byte |= 1 << self.bit;
        }
        self.bit += 1;

        // we finished a byte, so add it with overflow
        // and reset
        if (self.bit == 8) {
            self.sum = @addWithOverflow(self.sum, self.byte);
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
        sum = @addWithOverflow(sum, byte);
    }
    return sum;
}

const jedHeader =
    \\GAL Assembler: mkjed
;

pub const jedOptions = struct {
    header: []const u8 = jedHeader,
};

/// Writes the fuse map to a jed.
pub fn writeJed(writer: anytype, fuse_map: []const u8) !void {
    // TODO
    _ = writer;
    _ = fuse_map;
}

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
        const map = FuseMap{
            .allocator = allocator,
            .default_state = default_state,
            .qf = fuses,
            .qp = pins,
            .fuses = fusemap,
        };
        return map;
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
};

test "fusemap" {
    const alloc = std.testing.allocator;
    var fmap = try FuseMap.init(alloc, 100, 20, false);
    defer fmap.deinit();

    try fmap.set(0, true);
    try std.testing.expectError(error.OutOfBounds, fmap.set(100, true));

    const fblock: []const bool = &.{ false, true, true, false };
    try fmap.setSlice(96, fblock);
    try std.testing.expectError(error.OutOfBounds, fmap.setSlice(97, fblock));
}
