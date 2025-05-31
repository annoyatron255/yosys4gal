//! Chip information file, including chipspecs, and pin enums.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

/// Enum for chip types.
pub const ChipType = enum {
    gal16v8,
    gal22v10,
};
/// Definitions for a chip.
/// This is used by many of the comptime-generated structs
/// to create instances of these structs for a specific chip.
pub const ChipSpec = struct {
    const Self = @This();
    /// TOTAL size of the main fusemap array.
    /// ex 16v8 has 8 OLMCs with 8 rows = 64
    num_rows: u32,
    /// Columns of the main fusemap array.
    /// ex 16v8 has 16 inputs, so 32
    /// (don't forget inversions)
    num_cols: u32,

    /// total number of fuses for this chip.
    fusemap_size: usize,

    /// Starting fuse index for each OLMC rows
    /// Index using OLMC array position.
    olmc_row: []const u32,

    /// starting fuse address of the xor bits for OLMCs
    /// Use the index in the OLMC array to increment
    olmc_xor_address: u32,
    /// starting fuse address of the ac1 bits for OLMCs.
    /// Use the index in the OLMC array to increment
    olmc_ac1_address: u32,

    /// If, in registered mode, we have a global OE pin, or
    /// OE terms for each OLMC. If the latter, the total size
    /// of the "logic" terms is row_size - 1 for registered
    /// mainly for 22v10.
    registered_global_oe: bool,

    pub fn get_olmc_baseaddr(self: Self, index: usize) usize {
        const row = self.olmc_row[index];
        return row * self.num_cols;
    }
};

/// Registered-mode GAL16V8.
pub const GAL16V8Spec: ChipSpec = .{
    .ac0_addr = 2193,
    .syn_addr = 2192,
    .fusemap_size = 2194,
    .olmc_ac1_address = 2120,
    .olmc_xor_address = 2048,
    // .olmc_block_address = &.{ 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
    .olmc_row = &.{ 0, 8, 16, 24, 32, 40, 48, 56 },
    .olmc_row_sizes = &[_]u32{8} ** 8,
    .registered_global_oe = true,
};

// The Pin type category is an enum with values in the shape of p<uint>. They
// are then processed at compile time to allow for pinFromInt and pinToInt. We
// expect an offsets: [_]u8 constant that contains the pin column offsets.

/// GAL16V8 input pins.
pub const Pin16V8 = enum {
    //pin 1 is clk
    p2,
    p3,
    p4,
    p5,
    p6,
    p7,
    p8,
    p9,
    // pin 10 is gnd
    // pin 11 is global OE
    p12,
    p13,
    p14,
    p15,
    p16,
    p17,
    p18,
    p19,
    // pin 20 is vcc

    /// Pin offsets in the fuse column.
    const offsets = [_]u8{ 0, 4, 8, 12, 16, 20, 24, 28, 30, 26, 22, 18, 14, 10, 6, 2 };
    /// Convert a pin to the fuse column offset
    pub fn toOffset(self: Pin16V8) u8 {
        return offsets[@intFromEnum(self)];
    }
};

test Pin16V8 {
    validatePinEnum(Pin16V8);
}

/// create a pin from an integer ie from a pcf file.
/// can fail if the integer is not in the valid range.
/// Example is 2 => .p2 of the provided enum type, if it exists.
pub fn pinFromInt(comptime T: type, pin: usize) !T {
    // this isn't the fastest, i think it could be one-shotted.
    inline for (std.meta.fields(T)) |field| {
        const pin_number = comptime std.fmt.parseInt(usize, field.name[1..], 10) catch unreachable;
        if (pin == pin_number) {
            return @field(Pin16V8, field.name);
        }
    }
    return error.InvalidPin;
}

test pinFromInt {
    try testing.expectEqual(Pin16V8.p12, pinFromInt(Pin16V8, 12));
    try testing.expectError(error.InvalidPin, pinFromInt(Pin16V8, 1));
}

/// Convert a pin-enum back into the integer pin value.
pub fn pinToInt(pin: anytype) !usize {
    const t = std.enums.tagName(@TypeOf(pin), pin) orelse return error.InvalidPin;
    return std.fmt.parseInt(usize, t[1..], 10) catch error.InvalidPin;
}

test pinToInt {
    try testing.expectEqual(12, pinToInt(Pin16V8.p12));
}

/// compile time check that a type matches the contract for the pin enum.
pub fn validatePinEnum(comptime T: anytype) void {
    comptime {
        const info = @typeInfo(T);
        assert(info == .@"enum");
        assert(info.@"enum".is_exhaustive);
        assert(@hasDecl(T, "offsets"));
        assert(info.@"enum".fields.len == T.offsets.len);
        for (info.@"enum".fields) |field| {
            assert(field.name[0] == 'p');
            _ = try std.fmt.parseInt(usize, field.name[1..], 10);
        }
    }
}
