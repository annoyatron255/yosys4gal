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
    /// total number of fuses for this chip.
    fusemap_size: usize,
    /// number of OLMCs for this chip.
    num_olmcs: usize,
    /// OLMC type,
    olmc_type: type,
    /// number of pins. double this for "row size".
    /// This is typically the GAL<xx>V8 value, ie 16 for GAL16V8
    num_pins: usize,
    /// maps pin numbers to fuse columns/offsets.
    /// this is used for input column resolution
    pin_to_fuse_offset: []?u16,

    /// Starting fuse index for each OLMC rows
    /// Index using OLMC array position.
    olmc_start_addresses: []u32,

    /// starting fuse address of the xor bits for OLMCs
    /// Use the index in the OLMC array to increment
    olmc_xor_address: u32,
    /// starting fuse address of the ac1 bits for OLMCs.
    /// Use the index in the OLMC array to increment
    olmc_ac1_address: u32,
};

const GAL16V8Spec: ChipSpec = .{
    .num_olmcs = 8,
    .num_pins = 16,
    .olmc_type = OLMC(8, 16),
    // TODO: fix
    .pin_to_fuse_offset = &.{ null, null, 0, 2, 4, null },
};

/// GAL modes. see datasheet for more info.
pub const Mode = enum {
    /// Simple mode is pure combinational.
    /// I/O pins are fixed input or output.
    Simple,
    /// Complex mode allows for dynamic I/O logic.
    Complex,
    /// OLMC can either be registered OR I/O, but not both.
    /// you almost always want this mode.
    Registered,
};

/// Device Pin identifier.
pub const Pin = enum(u32) { _ };

/// InputPin is the core input primitive. Several InputPins make up one product
/// term. Note that this is still referenced to the chip and not an abstract
/// net.
pub const InputPin = struct { pin: Pin, inverted: bool = false };

/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub const PTerm = struct {
    allocator: Allocator,
    /// Pin entries
    entries: []?InputPin,

    /// Number of items in the pin
    items: usize = 0,

    /// Fuse map offset.
    base_addr: usize,

    pub fn init(allocator: Allocator, size: usize, base_addr: usize) !@This() {
        const entries = try allocator.alloc(?InputPin, size);
        @memset(entries, null);
        return .{
            .entries = entries,
            .base_addr = base_addr,
            .allocator = allocator,
        };
    }

    /// Clears the PTerm
    pub fn clear(self: *@This()) void {
        self.items = 0;
        for (self.entries) |*entry| {
            entry.* = null;
        }
    }

    /// Adds the pin to the term. Will fail if there's no room
    /// or if there's already a pin with the same pin number
    pub fn addPin(self: *@This(), p: InputPin) !void {
        // check if the pin number exists already
        if (self.items == self.entries.len) {
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
    pub fn writeFuse(self: *@This(), fmap: *FuseMap, chip: *ChipSpec) !void {
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
};

test PTerm {
    const allocator = testing.allocator;
    // testing pin collision
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var term = try PTerm.init(arena.allocator(), 8, 0);
        // add a pin
        const pin1: InputPin = .{ .pin = @enumFromInt(0) };
        try term.addPin(pin1);
        try testing.expectError(error.PinCollision, term.addPin(pin1));
    }
    // testing term capacity
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var term = try PTerm.init(arena.allocator(), 2, 0);
        // add a pin
        const pin1: InputPin = .{ .pin = @enumFromInt(0) };
        const pin2: InputPin = .{ .pin = @enumFromInt(1) };
        const pin3: InputPin = .{ .pin = @enumFromInt(2) };
        try term.addPin(pin1);
        try term.addPin(pin2);
        try testing.expectError(error.TermFull, term.addPin(pin3));
        // clear the term, and add.
        term.clear();
        try term.addPin(pin1);
    }
}

/// Create an OLMC type with the given number of rows, each
/// containing up to pterm_size inputs.
pub const OLMC = struct {
    pin: Pin,
    rows: []PTerm,

    xor: bool = false,
    ac1: bool = false,

    /// Create an OLMC.
    fn init(arena: Allocator, n_rows: usize, row_size: usize, pin: Pin, base_addr: usize) !OLMC {
        const rows = try arena.alloc(PTerm, n_rows);

        for (rows) |term| {
            // FIXME: base_addr calculations
            try term.init(arena, row_size, base_addr);
        }

        return .{
            .pin = pin,
            .rows = rows,
        };
    }
};

// Chip -> OLMCs -> PTerms -> Pins
// OLMCs also contain xor and ac1 values
// chip contains SYN + AC0
