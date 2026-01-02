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
    gal22v10,

    /// retrieve the details about the chip.
    pub fn getSpec(self: Self) *const Spec {
        return switch (self) {
            .gal16v8 => &GAL16V8Spec,
            .gal22v10 => &GAL22V10Spec,
        };
    }
};

pub const Pin = enum(u32) { _ };

/// Simple struct declaring a range of fuses (base, len)
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
        var len = self.sop_fuses.@"1";
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
    ptd: ?FuseBlock = null,

    /// location of the AR term
    ar: ?FuseBlock = null,
    /// location of the SP term
    sp: ?FuseBlock = null,
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
        try testing.expect(olmc.sop_fuses.@"0" < spec.fusemap_size);
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
        OlmcSpec{ .pin = @enumFromInt(18), .s0 = 2049, .s1 = 2121, .sop_fuses = .{ 256, 256 } },
        OlmcSpec{ .pin = @enumFromInt(17), .s0 = 2050, .s1 = 2122, .sop_fuses = .{ 512, 256 } },
        OlmcSpec{ .pin = @enumFromInt(16), .s0 = 2051, .s1 = 2123, .sop_fuses = .{ 768, 256 } },
        OlmcSpec{ .pin = @enumFromInt(15), .s0 = 2052, .s1 = 2124, .sop_fuses = .{ 1024, 256 } },
        OlmcSpec{ .pin = @enumFromInt(14), .s0 = 2053, .s1 = 2125, .sop_fuses = .{ 1280, 256 } },
        OlmcSpec{ .pin = @enumFromInt(13), .s0 = 2054, .s1 = 2126, .sop_fuses = .{ 1536, 256 } },
        OlmcSpec{ .pin = @enumFromInt(12), .s0 = 2055, .s1 = 2127, .sop_fuses = .{ 1792, 256 } },
    },
    .registered_global_oe = true,
    .ptd = .{ 2128, 64 },
};

test "gal16v8" {
    try validate(GAL16V8Spec);
}
test "gal22v10" {
    try validate(GAL22V10Spec);
}

pub const GAL22V10Spec = Spec{
    .num_cols = 44,
    // 120 main + 2 (ar/sp) + 10 tristate
    .num_rows = 132,
    .fusemap_size = 5892,
    .num_pins = 24,
    .pins = &.{
        .{ @enumFromInt(1), 0 }, // unlike 16v8, the clock pin is also a valid input.
        .{ @enumFromInt(2), 4 },
        .{ @enumFromInt(3), 8 },
        .{ @enumFromInt(4), 12 },
        .{ @enumFromInt(5), 16 },
        .{ @enumFromInt(6), 20 },
        .{ @enumFromInt(7), 24 },
        .{ @enumFromInt(8), 28 },
        .{ @enumFromInt(9), 32 },
        .{ @enumFromInt(10), 36 },
        .{ @enumFromInt(11), 40 },
        .{ @enumFromInt(13), 42 },
        .{ @enumFromInt(14), 38 },
        .{ @enumFromInt(15), 34 },
        .{ @enumFromInt(16), 30 },
        .{ @enumFromInt(17), 26 },
        .{ @enumFromInt(18), 22 },
        .{ @enumFromInt(19), 18 },
        .{ @enumFromInt(20), 14 },
        .{ @enumFromInt(21), 10 },
        .{ @enumFromInt(22), 6 },
        .{ @enumFromInt(23), 2 },
    },

    .olmcs = &.{
        OlmcSpec{ .pin = @enumFromInt(23), .s0 = 5808, .s1 = 5809, .sop_fuses = .{ 44, 9 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(22), .s0 = 5810, .s1 = 5811, .sop_fuses = .{ 440, 11 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(21), .s0 = 5812, .s1 = 5813, .sop_fuses = .{ 924, 13 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(20), .s0 = 5814, .s1 = 5815, .sop_fuses = .{ 1496, 15 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(19), .s0 = 5816, .s1 = 5817, .sop_fuses = .{ 2156, 17 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(18), .s0 = 5818, .s1 = 5819, .sop_fuses = .{ 2904, 17 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(17), .s0 = 5820, .s1 = 5821, .sop_fuses = .{ 3652, 15 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(16), .s0 = 5822, .s1 = 5823, .sop_fuses = .{ 4312, 13 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(15), .s0 = 5824, .s1 = 5825, .sop_fuses = .{ 4884, 11 * 44 } },
        OlmcSpec{ .pin = @enumFromInt(14), .s0 = 5826, .s1 = 5827, .sop_fuses = .{ 5368, 9 * 44 } },
    },
    .registered_global_oe = false,
    .ar = .{ 0, 44 },
    .sp = .{ 5764, 44 },
};
