//! Symbolic representation of GAL-style chips.
//! Yosys -> Fitter -> this file -> jed.zig
//! the fitter or other tools will instantiate these objects
//! which will contain validation steps to ensure the configuration
//! is correct. Then it can dump to a fuse map/jed file.
//! This is "post-routing" - we only refer to actual hardware pins.
//! Net-to-pin mapping should be handled prior to this step.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;

const Array2D = @import("util/array2d.zig").Array2D;
const jed = @import("jed.zig");
const FuseMap = jed.FuseMap;
const chipinfo = @import("./chipinfo.zig");
const ChipType = chipinfo.ChipType;

/// Represents a SOP element that feeds into an OLMC.
pub const SopTerm = Array2D(bool);

/// The supported states for a tristate control.
/// unknown: not yet assigned. must be assigned before writing.
/// term: a dedicated product term for this OLMC
/// in: this OLMC is disabled and should always be an input.
/// out: force this OLMC to always be an output
/// global: special case of registered OLMC in 16v8: shared global pin
pub const TristateMode = union(enum) {
    unknown,
    term: *SopTerm,
    in,
    out,
    global,
};

/// Represents an OLMC instace with actual data.
pub const OLMC = struct {
    /// the spec backing this OLMC. contains info for the fuse locations.
    spec: *const chipinfo.OlmcSpec,
    /// The rows for the OLMC terms. Supports mixed-size rows (22v10)
    output: ?*SopTerm = null,

    tristate: TristateMode = .unknown,
    /// Active high or low.
    active_high: bool = false,
    /// Registered or combinational.
    /// Note that the combinational mode uses the first term
    /// as the OE in certain chips/modes.
    /// read the chip spec registered_global_oe value.
    comb: bool = false,

    /// set the OE term to the AND of the given pins
    pub fn set_tristate(self: *OLMC, sop: *SopTerm) !void {
        // a oe term is one product.
        assert(sop.data.rows == 1);
        self.tristate = sop;
    }
    pub fn set_output(self: *OLMC, sop: *SopTerm) void {
        self.output = sop;
    }

    /// Write this OLMC to the fusemap using the assigned spec.
    /// the OLMC must be finalized.
    pub fn write(self: *const OLMC, fmap: *FuseMap, product_size: usize, global_registered_oe: bool) void {
        // do nothing if no output.
        // TODO: should we still write tristates?
        if (!self.output) return;
        assert(self.tristate != .unknown);
        const base = self.spec.sop_fuses.@"0";
        var offset: usize = 0;
        switch (self.tristate) {
            .global => {
                // the chip is 16v8 and this SOP is registered.
                assert(!self.comb and global_registered_oe);
                fmap.setSlice(self.spec.sop_fuses.@"0", self.output.?);
            },
            .term => |term| {
                // we are using a term.
                assert(term.data.items.len == product_size);
                assert(term.rows == 1);
                fmap.setSlice(base, term);
                offset += product_size;
            },
            .in => {},
        }
    }
};

/// represents the active state of a gal.
pub const GAL = struct {
    const Self = @This();
    arena: ArenaAllocator,
    chip: ChipType,
    olmcs: []OLMC,
    pt: ?[]bool = null,
    syn: bool,
    ac0: bool,

    /// Create a GAL representation of the given chip.
    pub fn init(allocator: Allocator, chip: ChipType) !GAL {
        var arena = ArenaAllocator.init(allocator);
        const spec = chip.getSpec();
        const olmcs = try arena.allocator().alloc(OLMC, spec.olmcs.len);
        for (spec.olmcs, 0..) |olmc_spec, idx| {
            olmcs[idx] = .{ .spec = &olmc_spec };
        }

        var result: GAL = .{
            .arena = arena,
            .chip = chip,
            .olmcs = olmcs,
            .ac0 = false,
            .syn = false,
        };
        // use registered mode on both chips
        switch (chip) {
            // .gal22v10 => {
            //     // do nothing
            // },
            .gal16v8 => {
                const pt: []bool = try result.arena.allocator().alloc(bool, 64);
                @memset(pt, true);
                result.pt = pt;
                result.ac0 = true;
                result.syn = false;
            },
        }
        // allocate ptd even though we don't use it.
        return result;
    }

    pub fn deinit(self: *GAL) void {
        self.arena.deinit();
    }

    /// Returns the SOP for a given olmc. When first called for an OLMC,
    /// it will create the SopTerm. Afterwards, it will return the same SopTerm.
    /// during the first call, `comb` is used to indicate if the OLMC is combinational
    /// or registered. When called again, it is an error to give a different value for `comb`.
    pub fn getOrMakeSop(self: *GAL, olmc_idx: usize, comb: bool) !*SopTerm {
        const spec = self.chip.getSpec();
        const olmc = &self.olmcs[olmc_idx];
        if (olmc.output) |existing| {
            if (comb != olmc.comb) {
                return error.ArgumentError;
            }
            return existing;
        }
        // it doesn't exist, allocate a new one on our arena.
        olmc.comb = comb;
        const newsop: *SopTerm = try self.arena.allocator().create(SopTerm);
        const rows: usize = if (comb) 7 else 8;
        newsop.* = try SopTerm.initFilled(self.arena.allocator(), rows, spec.num_cols, false);
        olmc.output = newsop;
        return newsop;
    }

    /// Get an OLMC SOP using the output pin rather than the raw index.
    pub fn getSopPin(self: *GAL, pin: chipinfo.Pin, comb: bool) !*SopTerm {
        // convert the pin to the olmc index.
        const spec = self.chip.getSpec();
        const idx = spec.getOlmcIdx(pin);
        if (idx) |i| {
            return self.getOrMakeSop(i, comb);
        }
        return error.InvalidPin;
    }
    /// make a tristate term for a pin, if the olmc supports it.
    pub fn getOETerm(self: *GAL, olmc_idx: usize) !*SopTerm {
        const spec = self.chip.getSpec();
        const olmc = &self.olmcs[olmc_idx];
        if (!olmc.comb and spec.registered_global_oe) {
            return error.InvalidMode;
        }
        switch (olmc.tristate) {
            .term => |t| return t,
            else => {
                const new_oe: *SopTerm = try self.arena.allocator().create(SopTerm);
                new_oe.* = try SopTerm.initSize(self.arena.allocator(), 1, spec.num_cols);
                olmc.tristate = .{ .term = new_oe };
                return new_oe;
            },
        }
    }

    // special case handler for gal22v10
    fn needs_flip(self: *GAL, olmc_idx: usize) bool {
        if (self.chip != .gal22v10) {
            return false;
        }
        const olmc = &self.olmcs[olmc_idx];
        if (!olmc.comb and olmc.active_high) {
            return true;
        }
        return false;
    }

    pub fn synthesize(self: *GAL, fmap: *FuseMap) !void {
        const spec = self.chip.getSpec();
        assert(fmap.qf == spec.fusemap_size);

        // start with the output fuse maps.
        for (self.olmcs, 0..) |olmc, idx| {
            const olmc_spec = spec.olmcs[idx];
            var base: usize = olmc_spec.sop_fuses.@"0";
            var tristate = false;
            // if we're a combinational olmc, OR we're a gal22v10
            // and have local tristate in registered mode, we have
            // to do this.
            // handle the tristate row
            if (olmc.comb or !spec.registered_global_oe) {
                // tristate row. write one if it exists
                // blank it otherwise.
                // bump the base out.
                switch (olmc.tristate) {
                    .term => |t| {

                    }
                }
                if (olmc.tristate) |tri| {
                    assert(olmc.output != null);
                    assert(tri.data.items.len == spec.num_cols);
                    assert(tri.rows == 1);
                    assert(tri.cols == spec.num_cols);
                    try fmap.setSlice(base, tri.data.items);
                } else {
                    // set all fuses in this row to true, which always works.
                    for (0..spec.num_cols) |i| {
                        try fmap.set(base + i, true);
                    }
                }
                // bump the base fuse addr.
                base += spec.num_cols;
                // we used tristate
                tristate = true;
            } else {
                // we're a gal16v8 in registered mode, we shouldn't have
                // a tristate block and should instead be global
                assert(olmc.tristate == .global);
            }

            if (olmc.output) |out| {
                // test that the output fits
                const maxsize = olmc_spec.term_size(spec.num_cols, tristate);
                assert(out.rows <= maxsize);
                try fmap.setSlice(base, out.data.items);
                base += out.data.items.len;
            }
        }
        // in 16v8, it's then olmc xors,
        // user signature,
        // ac1, ptd, syn, ac0.
        // write olmc xors.
        var base: usize = spec.num_cols * spec.num_rows;
        for (self.olmcs) |olmc| {
            try fmap.set(base, olmc.active_high);
            base += 1;
        }
        {
            const data = &[_]bool{false} ** 64;
            try fmap.setSlice(base, data);
            base += data.len;
        }
        for (self.olmcs) |olmc| {
            try fmap.set(base, olmc.comb);
            base += 1;
        }
        if (self.pt) |ptd| {
            try fmap.setSlice(base, ptd);
            base += ptd.len;
        } else {
            // we don't support this case yet, 22v10
            unreachable;
        }

        try fmap.set(base, self.syn);
        base += 1;
        try fmap.set(base, self.ac0);
        base += 1;
    }
};

test "gal olmc comb" {
    const alloc = testing.allocator;
    const spec = &chipinfo.GAL16V8Spec;
    var gal = try GAL.init(alloc, .gal16v8);
    defer gal.deinit();
    // create a random combinational term
    const sop: *SopTerm = try gal.getOrMakeSop(0, true);
    try testing.expectEqual(sop, try gal.getOrMakeSop(0, true));
    try testing.expectEqual(7, sop.rows);
    // we can't change the value of comb after we first call it
    try testing.expectError(error.ArgumentError, gal.getOrMakeSop(0, false));
    // we should be able to make an oe term.
    const oe: *SopTerm = try gal.getOETerm(0);
    try testing.expectEqual(sop.cols, oe.cols);
    var fusemap = try FuseMap.init(alloc, spec.fusemap_size, spec.num_pins, false);
    defer fusemap.deinit();
    try gal.synthesize(&fusemap);
}

test "gal olmc registered" {
    const alloc = testing.allocator;
    const spec = &chipinfo.GAL16V8Spec;
    var gal = try GAL.init(alloc, .gal16v8);
    defer gal.deinit();
    // create a random combinational term
    const sop: *SopTerm = try gal.getOrMakeSop(0, false);
    try testing.expectEqual(sop, try gal.getOrMakeSop(0, false));
    try testing.expectEqual(8, sop.rows);
    // we can't change the value of comb after we first call it
    try testing.expectError(error.ArgumentError, gal.getOrMakeSop(0, true));
    // can't make an oe term, since registered uses the global oe pin
    try testing.expectError(error.InvalidMode, gal.getOETerm(0));
    var fusemap = try FuseMap.init(alloc, spec.fusemap_size, spec.num_pins, false);
    defer fusemap.deinit();
    try gal.synthesize(&fusemap);
}

test "gal getSopPin" {
    const alloc = testing.allocator;
    // const spec = &chipinfo.GAL16V8Spec;
    var gal = try GAL.init(alloc, .gal16v8);
    defer gal.deinit();
    const pin: chipinfo.Pin = @enumFromInt(13);
    const sop: *SopTerm = try gal.getSopPin(pin, false);
    _ = sop;
    // should error for non-olmc pin
    const input_pin: chipinfo.Pin = @enumFromInt(2);
    try testing.expectError(error.InvalidPin, gal.getSopPin(input_pin, false));
}
