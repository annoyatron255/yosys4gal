//! Describes 16V8 and 20V8 GALs and their fuses/configuration.
//! Yosys -> Fitter -> this file -> jed.zig
//! the fitter or other tools will instantiate these objects
//! which will contain validation steps to ensure the configuration
//! is correct. Then it can dump to a fuse map/jed file.

const std = @import("std");
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

    /// Starting fuse index for each OLMC.
    olmc_start_addresses: []u32,
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

/// Pin is the core logic primitive - a set of pins
/// makes up one product term. Note that this is
/// still referenced to the chip and not an abstract net.
pub const Pin = struct { pin: u32, inverted: bool = false };

/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub fn PTerm(comptime size: usize) type {
    return struct {
        /// Pin entries
        entries: [size]?Pin,

        /// Number of items in the pin
        items: usize = 0,

        /// Fuse map offset.
        base_addr: usize,

        pub fn init(alloc: Allocator, base: usize) @This() {
            return .{
                .base_addr = base,
                .entries = alloc.alloc(?Pin, size),
            };
        }

        /// Clears the PTerm. mainly to avoid allocatipn.
        pub fn clear(self: *@This()) void {
            self.items = 0;
            for (self.entries) |entry| {
                entry = null;
            }
        }

        /// Adds the pin to the term. Will fail if there's no room
        /// or if there's already a pin with the same pin number
        pub fn addPin(self: *@This(), p: Pin) !void {
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
                    var fuse = chip.pin_to_fuse_offset[entry.pin];
                    if (entry.inverted) {
                        fuse += 1;
                    }
                    fmap.set(fuse, true);
                }
            }
        }
    };
}

/// Create an OLMC type with the given number of rows, each
/// containing up to pterm_size inputs.
fn OLMC(comptime n_rows: u16, comptime pterm_size: u16, comptime mode: Mode) type {
    return struct {
        const Term = PTerm(pterm_size);
        /// Output pin for this macrocell
        pin: u16,
        rows: [n_rows]Term = null,

        // OLMC configuration bits

        /// active high or active low
        xor: bool = false,
        /// In simple mode, this is pin input/output configuration.
        /// in complex mode, this is if we should use the OE term
        /// in registered mode, this is if the pin should use the OE at all.
        ac1: bool = false,
    };
}

// Chip -> OLMCs -> PTerms -> Pins
// OLMCs also contain xor and ac1 values
// chip contains SYN + AC0

pub const OLMC_16V8 = OLMC(8, 16);
