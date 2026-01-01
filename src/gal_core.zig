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
/// global: special case of registered OLMC in 16v8: common dedicated pin
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
    spec: *const chipinfo.OlmcSpec = undefined,
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

    /// determine if this OLMC should have feedback flipped on gal22v10.
    /// NOTE: only use this on gal22v10!
    pub fn needs_flip(self: *const OLMC) bool {
        if (!self.comb and self.active_high) {
            return true;
        }
        return false;
    }

    /// Write this OLMC to the fusemap using the assigned spec.
    /// the OLMC must be finalized.
    pub fn write(self: *const OLMC, fmap: *FuseMap, product_size: usize, registered_global_oe: bool) !void {
        // do nothing if no output.
        // TODO: should we still write tristates?
        if (self.output == null) return;
        assert(self.tristate != .unknown);
        const base = self.spec.sop_fuses.@"0";
        assert(base < fmap.qf);
        // by default, we assume that the first term is a tristate term.
        var offset: usize = product_size;
        switch (self.tristate) {
            .global => {
                // the chip is 16v8 and this SOP is registered.
                assert(!self.comb and registered_global_oe);
                // in this rare case, our offset is 0.
                offset = 0;
            },
            .term => |term| {
                // we are using a term.
                assert(term.data.items.len == product_size);
                assert(term.rows == 1);
                try fmap.setSlice(base, term.data.items);
            },
            .in => {
                // OE should always be zero, so blank it.
                for (0..product_size) |i| {
                    try fmap.set(base + i, false);
                }
            },
            .out => {
                // OE term should always be 1, so we set everything to true.
                for (0..product_size) |i| {
                    try fmap.set(base + i, true);
                }
            },
            .unknown => unreachable,
        }
        const out = &self.output.?.data.items;
        const max_size = self.spec.sop_fuses.@"1";
        assert(out.len + offset <= max_size);
        try fmap.setSlice(base + offset, out.*);
        // set the xor/mode
        try fmap.set(self.spec.s0, self.active_high);
        try fmap.set(self.spec.s1, self.comb);
    }
};
// indicates if this term pair (fuse map) is actually set to be useful
// 00 -> don'tcare, 11 -> don'tcare but makes the produce always true.
fn is_term(orig: []const bool) bool {
    return std.mem.eql(bool, orig, &.{ false, true }) or
        std.mem.eql(bool, orig, &.{ true, false });
}

/// represents the active state of a gal.
pub const GAL = struct {
    const Self = @This();
    const ExtraFuse = struct { idx: usize, val: bool };
    arena: ArenaAllocator,
    chip: ChipType,
    olmcs: []OLMC,
    pt: ?[]bool = null,
    extra_fuses: []ExtraFuse = &.{},

    /// Create a GAL representation of the given chip.
    pub fn init(allocator: Allocator, chip: ChipType) !GAL {
        var arena = ArenaAllocator.init(allocator);
        const spec = chip.getSpec();
        const olmcs = try arena.allocator().alloc(OLMC, spec.olmcs.len);
        for (spec.olmcs, 0..) |*olmc_spec, idx| {
            olmcs[idx] = .{ .spec = olmc_spec };
        }

        var result: GAL = .{
            .arena = arena,
            .chip = chip,
            .olmcs = olmcs,
        };
        // use registered mode on both chips
        switch (chip) {
            .gal22v10 => {},
            .gal16v8 => {
                const pt: []bool = try result.arena.allocator().alloc(bool, 64);
                @memset(pt, true);
                result.pt = pt;
                // syn=false, ac0=true for 16v8 to be registered mode
                // TODO: move this into the chip spec.
                result.extra_fuses = try result.arena.allocator().alloc(ExtraFuse, 2);
                result.extra_fuses[0] = .{ .idx = 2192, .val = false };
                result.extra_fuses[1] = .{ .idx = 2193, .val = true };
            },
        }
        // allocate ptd even though we don't use it.
        return result;
    }

    pub fn deinit(self: *GAL) void {
        self.arena.deinit();
    }

    /// helper to initialize all of the remaining tristate to global/out
    fn setRemainingTristate(self: *GAL) void {
        const spec = self.chip.getSpec();
        for (self.olmcs) |*olmc| {
            if (olmc.tristate == .unknown) {
                // registered and we have a dedicated pin for registered OE
                if (!olmc.comb and spec.registered_global_oe) {
                    olmc.tristate = .global;
                } else if (olmc.output != null) {
                    olmc.tristate = .out;
                } else {
                    olmc.tristate = .in;
                }
            }
        }
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
        const rows: usize = olmc.spec.term_size(spec.num_cols, comb or !spec.registered_global_oe);
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

    pub fn synthesize(self: *GAL, fmap: *FuseMap) !void {
        self.setRemainingTristate();
        const spec = self.chip.getSpec();
        assert(fmap.qf == spec.fusemap_size);

        for (self.olmcs) |olmc| {
            try olmc.write(fmap, spec.num_cols, spec.registered_global_oe);
        }
        // flip terms that are connected to OLMC feedback on registered + active high OLMcs
        if (self.chip == .gal22v10) {
            for (self.olmcs) |olmc| {
                if (olmc.needs_flip()) {
                    std.log.info("flipping feedback @ pin={d}", .{@intFromEnum(olmc.spec.pin)});
                    const col = spec.getPinCol(olmc.spec.pin);
                    // invert every term that uses this pin.
                    // what this means is that 01 <-> 10,
                    // but 11 and 00 stay the same.
                    for (0..spec.num_rows) |row| {
                        const idx = row * spec.num_cols + col;
                        const orig = fmap.fuses[idx .. idx + 1];
                        if (is_term(orig)) {
                            fmap.fuses[idx] = !fmap.fuses[idx];
                            fmap.fuses[idx + 1] = !fmap.fuses[idx + 1];
                        }
                    }
                }
            }
        }

        if (self.pt) |ptd| {
            assert(spec.ptd != null);
            const base = spec.ptd.?.@"0";
            try fmap.setSlice(base, ptd);
        }

        for (self.extra_fuses) |efuse| {
            try fmap.set(efuse.idx, efuse.val);
        }
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
    try testing.expectEqual(sop.cols, spec.num_cols);
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
