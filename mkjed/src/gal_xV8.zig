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

/// Definitions for a chip.
/// This is used by many of the comptime-generated structs
/// to create instances of these structs for a specific chip.
const ChipSpec = struct {
    ac0_addr: u32,
    syn_addr: u32,
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

/// Registered-mode GAL16V8.
const GAL16V8Spec: ChipSpec = .{
    .ac0_addr = 2193,
    .syn_addr = 2192,
    .pin_type = Pin16V8,
    .fusemap_size = 2194,
    .olmc_ac1_address = 2120,
    .olmc_xor_address = 2048,
    .olmc_block_address = &.{ 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
};

// The Pin type category is an enum(u32) with values in the shape of
// p<uint>. They are then processed at compile time to allow for
// pinFromInt and pinToInt

/// GAL16V8 input pins.
pub const Pin16V8 = enum(u32) {
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
    // pin 11 is OE
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
    pub fn toOffset(self: Pin16V8) usize {
        return offsets[@intFromEnum(self)];
    }
};

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

/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub fn PTerm(spec: *const ChipSpec) type {
    return struct {
        /// InputPin stores the pin enum and an inversion flag
        pub const InputPin = struct { pin: spec.pin_type, inverted: bool = false };
        const n_entries = std.meta.fields(spec.pin_type).len;

        /// Array of pin entries. The size is based on the size of the pin enum.
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
            // there's a secret invariant here - since entries is
            // the same size as the pin enum, we can have at most n_entries
            // elements, which means that the uniqueness property here
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

        /// Produces a slice of bools that can be added to a fuse map.
        pub fn synthesize(self: *@This()) ![]bool {
            // compute the needed buffer size based on the chip.
            var fuses: [n_entries * 2]bool = undefined;
            @memset(&fuses, false);

            for (self.entries) |e| {
                if (e) |entry| {
                    // the toOffset function on pin-enums matches the enums
                    // to their columns.
                    var fuse_offset = entry.pin.toOffset();
                    if (entry.inverted) {
                        fuse_offset += 1;
                    }
                    fuses[fuse_offset] = true;
                }
            }
            return &fuses;
        }
    };
}

test PTerm {
    const Term = PTerm(&GAL16V8Spec);
    // testing pin collision
    {
        var term: Term = .{};
        // add a pin
        const pin: Term.InputPin = .{ .pin = .p2 };
        try term.addPin(pin);
        try testing.expectError(error.PinCollision, term.addPin(pin));
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
        try testing.expectError(error.PinCollision, term.addPin(bad_pin));
        // clear the term, and add.
        term.clear();
        try term.addPin(bad_pin);
    }
    // testing fuse synthesis
    {
        var term: Term = .{};
        // add a pin
        const pin1: Term.InputPin = .{ .pin = @enumFromInt(0), .inverted = true };
        try term.addPin(pin1);
        const fuses = try term.synthesize();
        try testing.expectEqual(true, fuses[1]);
    }
}

pub fn OLMC(spec: *const ChipSpec) type {
    const Term = PTerm(spec);
    // OLMCs can have a variable number of rows.
    return struct {
        allocator: Allocator,
        output_pin: spec.pin_type,
        rows: []Term,
        xor: bool = false,
        ac1: bool = false,

        pub fn init(allocator: Allocator, size: usize, pin: spec.pin_type) !@This() {
            const rows = try allocator.alloc(Term, size);
            return .{
                .allocator = allocator,
                .output_pin = pin,
                .rows = rows,
            };
        }
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.rows);
        }
    };
}

test OLMC {
    const alloc = testing.allocator;
    var olmc = try OLMC(&GAL16V8Spec).init(alloc, 2, .p2);
    defer olmc.deinit();
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
