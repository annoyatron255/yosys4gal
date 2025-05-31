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

const Array2D = @import("array2d.zig").Array2D;
const jed = @import("jed.zig");
const FuseMap = jed.FuseMap;
const chipinfo = @import("./chipinfo.zig");
const ChipSpec = chipinfo.ChipSpec;

pub const Pin = struct { pin: u32, inverted: bool = false };

/// Represents a SOP element that feeds into an OLMC.
pub const SopTerm = struct {
    const Self = @This();

    data: Array2D(bool),

    pub fn init(allocator: Allocator, width: usize, depth: usize) Self {
        return .{
            .data = .initFilled(allocator, width, depth, true),
        };
    }
    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }
    pub fn synthesize(self: *Self, fmap: *FuseMap) void {
        fmap.streamSlice(self.data.data);
    }

    pub fn set(self: *Self, row: usize, col: usize) void {
        self.data.set(row, col, false);
    }
    pub fn clear(self: *Self) void {
        self.data.fill(true);
    }
};
test SopTerm {}

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

    ///writes the OLMC to the fuse map.
    pub fn synthesize(self: Self, fmap: *FuseMap, chip: *const ChipSpec) !void {
        // FIXME: get index from output pin
        const index = 0;
        try fmap.set(chip.olmc_ac1_address + index, self.comb);
        try fmap.set(chip.olmc_xor_address + index, self.active_high);
        var base = chip.olmc_block_address[index];
        if (self.tristate) |tri| {
            tri.synthesize(fmap);
            base += tri.data.cols;
        }

        if (self.output) |out| {
            out.synthesize(fmap);
        }
    }

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

pub const GAL = struct {
    const Self = @This();
    chip: *ChipSpec,
    olmcs: []OLMC,
    pt: []bool,
    syn: bool,
    ac0: bool,

    pub fn synthesize(self: *Self, fmap: *FuseMap) void {
        assert(fmap.qf == self.chip.fusemap_size);

        for (self.olmcs, 0..) |olmc, idx| {
            const base = self.chip.get_olmc_baseaddr(idx);
            assert(olmc.output);
            olmc.synthesize(fmap, base);
        }
    }
};
