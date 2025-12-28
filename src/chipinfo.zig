//! Chip information file, which describes chips
//! and supporting data structures to work with them
//! used by the GAL representation as well as the fitter algorithm.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;

/// Enum for chip types.
pub const ChipType = enum {
    const Self = @This();
    gal16v8,
    // gal22v10,

    pub fn getSpec(self: Self) *const Spec {
        return switch (self) {
            .gal16v8 => &GAL16V8Spec,
            // .gal22v10 => &GAL16V8Spec,
        };
    }
};

pub const Pin = enum(u32) { _ };

/// Simple struct declaring a range of fuses
pub const FuseBlock = struct { usize, usize };
/// details of where the OLMC lies in the fuse map, as well as what pin it goes to.
pub const OlmcSpec = struct {
    pin: Pin,
    /// location of the s0 fuse. This should be the xor fuse.
    s0: usize,
    /// location of the s1 fuse. This usually controls if it's registered or combinational.
    s1: usize,

    /// fuses for the SOP terms, including the dedicated tristate.
    sop_fuses: FuseBlock,

    /// Compute how many rows this OLMC can have for output. takes the row size from the chip spec,
    /// and a boolean to indicate if the first row is reserved for the tristate term.
    pub fn term_size(self: *const OlmcSpec, row_len: usize, uses_tristate: bool) usize {
        var len = self.sop_fuses.@"1" - self.sop_fuses.@"0";
        if (uses_tristate) {
            len -= row_len;
        }

        return @divExact(len, row_len);
    }
};

/// Definitions for a chip.
/// This is used by many of the comptime-generated structs
/// to create instances of these structs for a specific chip.
pub const Spec = struct {
    const Self = @This();
    /// TOTAL size of the main fusemap array.
    /// ex 16v8 has 8 OLMCs with 8 rows = 64
    num_rows: u32,

    /// Columns of the main fusemap array.
    /// ex 16v8 has 16 inputs, so 32
    /// (don't forget inversions)
    num_cols: u32,

    /// number of pins on the chip, not which are valid on the SOP array.
    num_pins: u32,

    /// Map of valid pins and their columns in the array.
    pins: []const struct { Pin, u32 },

    /// total number of fuses for this chip.
    fusemap_size: usize,

    /// details about the locations of the olmcs.
    olmcs: []const OlmcSpec,

    /// If, in registered mode, we have a global OE pin, or
    /// OE terms for each OLMC. If the latter, the total size
    /// of the "logic" terms is row_size - 1 for registered
    /// mainly for 22v10.
    registered_global_oe: bool,
    /// the location of any product term disable fuses, if present.
    ptd: ?FuseBlock,

    /// creates a bit set with the valid pins set to 1.
    pub fn makeValidPinSet(self: Self, allocator: Allocator) !DynamicBitSetUnmanaged {
        var bs = try DynamicBitSetUnmanaged.initEmpty(allocator, self.num_pins);

        for (self.pins) |p| {
            bs.set(@intFromEnum(p.@"0"));
        }
        return bs;
    }

    /// Create a bit set with the OLMC output pins set to 1.
    /// note that the *highest* bit is the 0th OLMC!
    /// caller is responsible for cleanup.
    pub fn makeOlmcPinSet(self: Self, allocator: Allocator) !DynamicBitSetUnmanaged {
        var bs = try DynamicBitSetUnmanaged.initEmpty(allocator, self.num_pins);

        for (self.olmcs) |o| {
            bs.set(@intFromEnum(o.pin));
        }
        return bs;
    }

    /// internal lookup function for pins
    /// pin must be valid!
    pub fn getPinCol(self: Self, pin: Pin) u32 {
        for (self.pins) |candidate| {
            if (pin == candidate.@"0") {
                return candidate.@"1";
            }
        }
        unreachable;
    }
    /// given a pin, returns the index of the olmc that outputs to that pin, if any.
    pub fn getOlmcIdx(self: Self, pin: Pin) ?usize {
        for (self.olmcs, 0..) |o, idx| {
            if (o.pin == pin) {
                return idx;
            }
        }
        return null;
    }
    /// Returns a pin, or null if the given integer was invalid.
    pub fn pinFromInt(self: Self, val: usize) ?Pin {
        for (self.pins) |pin| {
            if (val == @intFromEnum(pin.@"0")) {
                return pin.@"0";
            }
        }
        return null;
    }
};

/// internal helper to ensure invariants
fn validate(spec: Spec) !void {
    // all olmc pins should be valid pins.
    for (spec.olmcs) |olmc| {
        const is_valid: bool = blk: {
            for (spec.pins) |p| {
                if (olmc.pin == p.@"0") break :blk true;
            }
            break :blk false;
        };

        try testing.expect(is_valid);
    }

}

/// Registered-mode GAL16V8.
pub const GAL16V8Spec = Spec{
    .num_cols = 32,

    .num_rows = 64,
    .fusemap_size = 2194,
    .num_pins = 20,
    .pins = &.{
        .{ @enumFromInt(2), 0 },
        .{ @enumFromInt(3), 4 },
        .{ @enumFromInt(4), 8 },
        .{ @enumFromInt(5), 12 },
        .{ @enumFromInt(6), 16 },
        .{ @enumFromInt(7), 20 },
        .{ @enumFromInt(8), 24 },
        .{ @enumFromInt(9), 28 },
        .{ @enumFromInt(12), 30 },
        .{ @enumFromInt(13), 26 },
        .{ @enumFromInt(14), 22 },
        .{ @enumFromInt(15), 18 },
        .{ @enumFromInt(16), 14 },
        .{ @enumFromInt(17), 10 },
        .{ @enumFromInt(18), 6 },
        .{ @enumFromInt(19), 2 },
    },
    .olmcs = &.{
        OlmcSpec{ .pin = @enumFromInt(19), .s0 = 2048, .s1 = 2120, .sop_fuses = .{ 0, 256 } },
        OlmcSpec{ .pin = @enumFromInt(18), .s0 = 2049, .s1 = 2121, .sop_fuses = .{ 256, 512 } },
        OlmcSpec{ .pin = @enumFromInt(17), .s0 = 2050, .s1 = 2122, .sop_fuses = .{ 512, 768 } },
        OlmcSpec{ .pin = @enumFromInt(16), .s0 = 2051, .s1 = 2123, .sop_fuses = .{ 768, 1024 } },
        OlmcSpec{ .pin = @enumFromInt(15), .s0 = 2052, .s1 = 2124, .sop_fuses = .{ 1024, 1280 } },
        OlmcSpec{ .pin = @enumFromInt(14), .s0 = 2053, .s1 = 2125, .sop_fuses = .{ 1280, 1536 } },
        OlmcSpec{ .pin = @enumFromInt(13), .s0 = 2054, .s1 = 2126, .sop_fuses = .{ 1536, 1792 } },
        OlmcSpec{ .pin = @enumFromInt(12), .s0 = 2055, .s1 = 2127, .sop_fuses = .{ 1792, 2048 } },
    },
    .registered_global_oe = true,
    .ptd = .{ 2128, 2191 },
};

test "gal16v8" {
    try validate(GAL16V8Spec);
}
//
// pub const GAL22V10Spec = Spec{
//     .num_cols = 44,
//     // 120 main + 2 (ar/sp) + 10 tristate
//     .num_rows = 132,
//     .fusemap_size = 5892,
//     .num_pins = 24,
//     .valid_pins = @ptrCast(&[_]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 }),
//     .pin_to_col = &.{ null, 0, 4, 8, 12, 16, 20, 24, 28, null, null, 30, 26, 22, 18, 14, 10, 6, 2, null },
//     .pins = &.{.{ @enumFromInt(2), 3 }},
//     .olmc_row = &.{ 1, 10, 21, 34, 49, 66, 83, 98, 111, 122 },
//     .olmc_row_sizes = &.{ 8, 10, 12, 14, 16, 16, 14, 12, 10, 8 },
//     .registered_global_oe = false,
//     .ptd = null,
// };
