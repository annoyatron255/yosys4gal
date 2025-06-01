//! Describes 16V8 and 20V8 GALs and their fuses/configuration.
//! Yosys -> Fitter -> this file -> jed.zig
//! the fitter or other tools will instantiate these objects
//! which will contain validation steps to ensure the configuration
//! is correct. Then it can dump to a fuse map/jed file.
//! This is "post-routing" - we only refer to actual hardware pins.
//! Net-to-pin routing should be handled prior to this step.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;

const Array2D = @import("array2d.zig").Array2D;
const jed = @import("jed.zig");
const FuseMap = jed.FuseMap;
const chipinfo = @import("./chipinfo.zig");
const ChipType = chipinfo.ChipType;

pub const Pin = struct { pin: u32, inverted: bool = false };

/// Represents a SOP element that feeds into an OLMC.
pub const SopTerm = Array2D(bool);

pub const OLMC = struct {
    const Self = @This();
    /// the pin that this OLMC drives.
    output_pin: usize,
    /// The rows for the OLMC terms. Supports mixed-size rows (22v10)
    output: ?*SopTerm = null,

    tristate: ?*SopTerm = null,
    /// Active high or low.
    active_high: bool = false,
    /// Registered or combinational.
    /// Note that the combinational mode uses the first term as the OE
    comb: bool = false,

    /// set the OE term to the AND of the given pins
    pub fn set_oe_term(self: *Self, sop: *SopTerm) !void {
        // a oe term is one product.
        assert(sop.data.rows == 1);
        self.tristate = sop;
    }
    pub fn set_output(self: *Self, sop: *SopTerm) void {
        self.output = sop;
    }
};

test OLMC {}

/// represents the active state of a gal.
pub const GAL = struct {
    const Self = @This();
    arena: ArenaAllocator,
    chip: ChipType,
    olmcs: []OLMC,
    pt: ?[]bool = null,
    syn: bool,
    ac0: bool,

    pub fn init(allocator: Allocator, chip: ChipType) !Self {
        const arena = ArenaAllocator.init(allocator);
        const spec = chip.getSpec();
        const olmcs = arena.allocator().alloc(OLMC, spec.olmc_row.len);

        const result: Self = .{
            .arena = arena,
            .chip = chip,
            .olmcs = olmcs,
            .ac0 = false,
            .syn = false,
        };
        // use registered mode on both chips
        switch (chip) {
            .gal22v10 => {
                // do nothing
            },
            .gal16v8 => {
                result.ac0 = true;
                result.syn = false;
            },
        }
    }

    /// Attach a sop to a given OLMC. Will error if the sop is too big.
    /// the SOP is copied and then owned by this struct.
    pub fn bindSop(self: *Self, olmc: usize, sop: *SopTerm) !void {
        // check if the given sop is too large for the olmc index.

        // TODO: adjust size limit based on combinational or registered.
        const spec = self.chip.getSpec();
        var size = spec.olmc_row_sizes[olmc];
        // if we have local OE in registered mode
        if (!spec.registered_global_oe or self.olmcs[olmc].comb) {
            size -= 1;
        }
        if (sop.rows > size) {
            return error.TermTooLarge;
        }
        // copy the term, attach it to the olmc
    }

    pub fn setOETerm(self: *Self, olmc_idx: usize, oe: *SopTerm) !void {
        const spec = self.chip.getSpec();
        // conditions where we can do this:
        // - gal22v10 always
        // - gal xv8 if the olmc is comb.
        const olmc = self.olmcs[olmc_idx];
        if (!olmc.comb and spec.registered_global_oe) {
            return error.Invalid;
        }
        olmc.set_oe_term(oe);
    }

    pub fn synthesize(self: *Self, fmap: *FuseMap) void {
        const spec = self.chip.getSpec();
        assert(fmap.qf == self.chip.fusemap_size);

        // start with the output fuse maps.
        for (self.olmcs, 0..) |olmc, idx| {
            var base = spec.getOlmcBaseAddr(idx);
            fmap.setCursor(base);
            if (olmc.tristate) |tri| {
                assert(olmc.output);
                assert(tri.data.items.len == spec.num_cols);
                assert(tri.rows == 1);
                assert(tri.cols == spec.num_cols);
                fmap.streamSlice(tri.data.items);
                base += tri.data.items.len;
            }
            if (olmc.output) |out| {
                // test that the output fits
                const maxsize = self.chip.olmc_row_sizes[idx];
                if (out.rows > maxsize) {
                    // hmm
                    @panic("row2big");
                }
                fmap.streamSlice(out.data.items);
                base += out.data.items.len;
            }
        }
    }
};
