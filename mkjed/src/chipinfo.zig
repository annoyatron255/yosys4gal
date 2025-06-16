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
            // .gal22v10 => &GAL22V10Spec,
        };
    }
};

pub const Pin = enum(u32) { _ };

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

    /// number of pins on the chip.
    num_pins: u32,

    /// List of valid pin numbers.
    valid_pins: []const Pin,

    /// Maps pins to column numbers.
    /// use getPinCol and make sure that you're sourcing from valid_pins!
    pin_to_col: []const ?u32,

    /// total number of fuses for this chip.
    fusemap_size: usize,

    /// Starting fuse index for each OLMC rows
    /// Index using OLMC array position.
    olmc_row: []const u32,
    /// size of each olmc in rows.
    olmc_row_sizes: []const u32,
    /// Pin numbers for each olmc
    olmc_pins: []const Pin,

    /// If, in registered mode, we have a global OE pin, or
    /// OE terms for each OLMC. If the latter, the total size
    /// of the "logic" terms is row_size - 1 for registered
    /// mainly for 22v10.
    registered_global_oe: bool,
    /// if the chip has a ptd line.
    has_ptd: bool,

    pub fn getOlmcBaseAddr(self: Self, index: usize) usize {
        const row = self.olmc_row[index];
        return row * self.num_cols;
    }

    /// creates a bit set with the valid pins set to 1.
    pub fn makeValidPinSet(self: Self, allocator: Allocator) !DynamicBitSetUnmanaged {
        var bs = try DynamicBitSetUnmanaged.initEmpty(allocator, self.num_pins);

        for (self.valid_pins) |valid_pin| {
            bs.set(@intFromEnum(valid_pin));
        }
        return bs;
    }

    /// Create a bit set with the OLMC output pins set to 1.
    /// note that the *highest* bit is the 0th OLMC!
    pub fn makeOlmcPinSet(self: Self, allocator: Allocator) !DynamicBitSetUnmanaged {
        var bs = try DynamicBitSetUnmanaged.initEmpty(allocator, self.num_pins);

        for (self.olmc_pins) |pin| {
            bs.set(@intFromEnum(pin));
        }
        return bs;
    }

    /// internal lookup function for pins
    /// pin must be valid!
    pub fn getPinCol(self: Self, pin: Pin) u32 {
        return self.pin_to_col[@intFromEnum(pin) - 1].?;
    }
    /// given a pin, returns the index of the olmc that outputs to that pin, if any.
    pub fn getOlmcIdx(self: Self, pin: Pin) ?usize {
        for (self.olmc_pins, 0..) |olmc_pin, idx| {
            if (olmc_pin == pin) {
                return idx;
            }
        }
        return null;
    }
    /// Returns a pin, or null if the given integer was invalid.
    pub fn pinFromInt(self: Self, val: usize) ?Pin {
        for (self.valid_pins) |pin| {
            if (val == @intFromEnum(pin)) {
                return pin;
            }
        }
        return null;
    }
};

/// internal helper to ensure invariants
fn validate(spec: Spec) !void {
    try testing.expectEqual(spec.olmc_row.len, spec.olmc_row_sizes.len);
    try testing.expectEqual(spec.olmc_row.len, spec.olmc_pins.len);
    // all olmc pins should be valid pins.
    for (spec.olmc_pins) |olmc_pin| {
        const is_valid: bool = blk: {
            for (spec.valid_pins) |valid_pin| {
                if (olmc_pin == valid_pin) break :blk true;
            }
            break :blk false;
        };

        try testing.expect(is_valid);
    }

    try testing.expect(spec.valid_pins.len < spec.num_pins);
    try testing.expect(spec.pin_to_col.len == spec.num_pins);

    // all valid pins should have non-null pin_to_col maps.
    for (spec.valid_pins) |vpin| {
        try testing.expect(spec.pin_to_col[@intFromEnum(vpin) - 1] != null);
    }
}

/// Registered-mode GAL16V8.
pub const GAL16V8Spec = Spec{
    .num_cols = 32,

    .num_rows = 64,
    .fusemap_size = 2194,
    .num_pins = 20,
    .valid_pins = @ptrCast(&[_]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17, 18, 19 }),
    .pin_to_col = &.{ null, 0, 4, 8, 12, 16, 20, 24, 28, null, null, 30, 26, 22, 18, 14, 10, 6, 2, null },
    .olmc_row = &.{ 0, 8, 16, 24, 32, 40, 48, 56 },
    .olmc_row_sizes = &[_]u32{8} ** 8,
    .olmc_pins = @ptrCast(&[_]u32{ 19, 18, 17, 16, 15, 14, 13, 12 }),
    .registered_global_oe = true,
    .has_ptd = true,
};

test "gal16v8" {
    const alloc = testing.allocator;
    try validate(GAL16V8Spec);
    try testing.expectEqual(0, GAL16V8Spec.getOlmcBaseAddr(0));
    try testing.expectEqual(256, GAL16V8Spec.getOlmcBaseAddr(1));
    var valids = try GAL16V8Spec.makeValidPinSet(alloc);
    defer valids.deinit(alloc);
    try testing.expectEqual(GAL16V8Spec.valid_pins.len, valids.count());
}

pub const GAL22V10Spec = Spec{
    .fusemap_size = 5892,
    .olmc_row = &.{ 1, 10, 21, 34, 49, 66, 83, 98, 111, 122 },
    .olmc_row_sizes = &.{ 9, 11, 13, 15, 17, 17, 15, 13, 11, 9 },
    .registered_global_oe = false,
    .has_ptd = false,
};
