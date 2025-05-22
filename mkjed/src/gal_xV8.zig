//! Describes 16V8 and 20V8 GALs and their fuses/configuration.
//! Yosys -> Fitter -> this file -> jed.zig
//! the fitter or other tools will instantiate these objects
//! which will contain validation steps to ensure the configuration
//! is correct. Then it can dump to a fuse map/jed file.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const jed = @import("jed.zig");
const FuseMap = jed.FuseMap;

/// critical parameters for a chip
/// note this is not something that you should instance
/// to make a design - it's got predefined values
/// based on their specs.
const ChipSpec = struct {
    /// Valid input pin type
    pin_type: type,
    /// total number of fuses for this chip.
    fusemap_size: usize,

    /// Starting fuse index for each OLMC rows
    /// Index using OLMC array position.
    olmc_block_address: []const u32,

    /// starting fuse address of the xor bits for OLMCs
    /// Use the index in the OLMC array to increment
    olmc_xor_address: u32,
    /// starting fuse address of the ac1 bits for OLMCs.
    /// Use the index in the OLMC array to increment
    olmc_ac1_address: u32,
};

const GAL16V8Spec: ChipSpec = .{
    .pin_type = Pin16V8,
    .fusemap_size = 2194,
    .olmc_ac1_address = 2120,
    .olmc_xor_address = 2048,
    .olmc_block_address = &.{ 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
};

/// valid pins for gal16v8 in registered mode.
pub const Pin16V8 = enum(u32) {
    p2,
    p3,
    p4,
    p5,
    p6,
    p7,
    p8,
    p9,
    p10,
    p12,
    p13,
    p14,
    p15,
    p16,
    p17,
    p18,
    p19,
    const offsets = .{ 0, 4, 8, 12, 16, 20, 24, 28, 30, 26, 22, 18, 14, 10, 6, 2 };
    /// Convert a pin to the fuse column offset
    pub fn toOffset(self: Pin16V8) usize {
        return offsets[@intFromEnum(self)];
    }
};

/// create a pin from an integer ie from a pcf file.
/// can fail if the integer is not in the valid range.
pub fn pinFromInt(comptime T: type, pin: usize) !T {
    inline for (std.meta.fields(T)) |field| {
        const pin_number = comptime std.fmt.parseInt(usize, field.name[1..], 10) catch unreachable;
        if (pin == pin_number) {
            return @field(Pin16V8, field.name);
        }
    }
    return error.InvalidPin;
}

test pinFromInt {
    try testing.expectEqual(Pin16V8.p10, pinFromInt(Pin16V8, 10));
    try testing.expectError(error.InvalidPin, pinFromInt(Pin16V8, 1));
}

/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub fn PTerm(spec: *const ChipSpec) type {
    return struct {
        pub const InputPin = struct { pin: spec.pin_type, inverted: bool = false };
        const n_entries = std.meta.fields(spec.pin_type).len;
        /// Pin entries
        entries: [n_entries]?InputPin = [_]?InputPin{null} ** n_entries,

        /// Number of items in the PTerm
        items: usize = 0,

        /// Clears the PTerm
        pub fn clear(self: *@This()) void {
            self.items = 0;
            for (&self.entries) |*entry| {
                entry.* = null;
            }
        }

        /// Adds the pin to the PTerm. Will fail if there's no room
        /// or if there's already a pin with the same pin number.
        pub fn addPin(self: *@This(), p: InputPin) !void {
            // check if the pin number exists already
            if (self.items == self.entries.len) {
                // this is a special case of pin collision.
                // we can only be full if we have one of every pin already.
                // so any pin we add would collide.
                // However, pin values are not bounds checked (yet).
                return error.TermFull;
            }

            for (self.entries) |entry| {
                if (entry) |e| {
                    if (e.pin == p.pin) {
                        return error.PinCollision;
                    }
                }
            }
            // add the pin at the end,
            assert(self.entries[self.items] == null);
            self.entries[self.items] = p;
            self.items += 1;
        }

        /// Write out the term to the fuse map. Needs a chip and a base address.
        /// The base address is typically calculated from an OLMC base address.
        pub fn writeFuse(self: *@This(), fmap: *FuseMap, chip: *const ChipSpec) !void {
            for (self.entries) |e| {
                if (e) |entry| {
                    // compute the fuse bit based on the base addr, pin_to_fuse_offset,
                    // and pin inversion status.
                    var fuse = self.base_addr + chip.pin_to_fuse_offset[@intFromEnum(entry.pin)];
                    if (entry.inverted) {
                        fuse += 1;
                    }
                    fmap.set(fuse, true);
                }
            }
        }

        /// Produces a slice of bools that can be added to a fuse map. The length of the slice
        /// is based on the chip. The pins are evaluated based on the ChipSpec used to construct
        /// this PTerm type.
        pub fn synthesize(self: *PTerm) ![]bool {
            // compute the needed buffer size based on the chip.
            //
            var fuses: [n_entries * 2]bool = false;

            for (self.entries) |e| {
                if (e) |entry| {
                    var fuse_offset = spec.pin_to_fuse_offset[@intFromEnum(entry.pin)];
                    if (entry.inverted) {
                        fuse_offset += 1;
                    }
                    fuses[fuse_offset] = true;
                }
            }
            return fuses;
        }
    };
}

test PTerm {
    const Term = PTerm(&GAL16V8Spec);
    // testing pin collision
    {
        var term: Term = .{};
        // add a pin
        const pin1: Term.InputPin = .{ .pin = @enumFromInt(0) };
        try term.addPin(pin1);
        try testing.expectError(error.PinCollision, term.addPin(pin1));
    }
    // testing term capacity
    {
        var term: Term = .{};
        // add pins
        for (0..Term.n_entries) |i| {
            const pin: Term.InputPin = .{ .pin = @enumFromInt(i) };
            try term.addPin(pin);
        }
        const bad_pin: Term.InputPin = .{ .pin = @enumFromInt(0) };
        try testing.expectError(error.TermFull, term.addPin(bad_pin));
        // clear the term, and add.
        term.clear();
        try term.addPin(bad_pin);
    }
    // testing fuse synthesis
    {
        var term: Term = .{};
        // add a pin
        const pin1: Term.InputPin = .{ .pin = @enumFromInt(0) };
        try term.addPin(pin1);
    }
}

// Create an OLMC type with the given number of rows, each
// containing up to pterm_size inputs.
// pub const OLMC = struct {
//     pin: Pin,
//     rows: []PTerm,
//
//     /// Active high/low bit
//     xor: bool = false,
//     /// Determines if this OLMC is registered or combinational
//     ac1: bool = false,
//
//     /// Create an OLMC.
//     fn init(arena: Allocator, n_rows: usize, row_size: usize, pin: Pin, base_addr: usize) !OLMC {
//         const rows = try arena.alloc(PTerm, n_rows);
//
//         for (rows) |term| {
//             // FIXME: base_addr calculations
//             try term.init(arena, row_size, base_addr);
//         }
//
//         return .{
//             .pin = pin,
//             .rows = rows,
//         };
//     }
// };

// Chip -> OLMCs -> PTerms -> Pins
// OLMCs also contain xor and ac1 values
// chip contains SYN + AC0
