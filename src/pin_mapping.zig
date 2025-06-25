//! Mapping from nets to chip pins.
//! Is used during the fitting process. We provide low level functions
//! but the algorithms belong in the techmap file.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const assert = std.debug.assert;

const yosys_netlist = @import("./yosys_netlist.zig");
const BiMap = @import("./util/bimap.zig").BiMap;
const chip = @import("./chipinfo.zig");

/// Maps design nets to chip pins.
/// When given a chip, it tracks which pins have been bound and which haven't.
/// A useful tool when doing fitting.
pub const PinMap = struct {
    const Self = @This();
    pub const Error = error{
        /// The given pin was not allowed for the chip
        InvalidPin,
        /// The pin has already been assigned to another net
        PinConsumed,
        /// the net was one of the constant values (0,1,x,z)
        InvalidNet,
        /// The net has already been assigned; this is an invariant that
        /// we uphold.
        NetAssigned,
    } || Allocator.Error;
    allocator: Allocator,
    /// underlying chip type.
    spec: chip.ChipType,
    /// The existing bindings.
    bimap: BiMap(yosys_netlist.Net, chip.Pin),
    /// set of unassigned outputs.
    output_set: DynamicBitSetUnmanaged,
    /// set of unassigned inputs
    input_set: DynamicBitSetUnmanaged,
    /// set of unused pins period (in + out)
    unused_set: DynamicBitSetUnmanaged,

    pub fn init(allocator: Allocator, spec: chip.ChipType) !Self {
        const info = spec.getSpec();
        var output_set = try info.makeOlmcPinSet(allocator);
        errdefer output_set.deinit(allocator);
        var unused_set = try info.makeValidPinSet(allocator);
        errdefer unused_set.deinit(allocator);
        var input_pins_unused = try unused_set.clone(allocator);
        {
            var out_iter = output_set.iterator(.{});
            while (out_iter.next()) |op| {
                input_pins_unused.unset(op);
            }
        }
        return Self{
            .allocator = allocator,
            .bimap = .init(allocator),
            .spec = spec,
            .output_set = output_set,
            .unused_set = unused_set,
            .input_set = input_pins_unused,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bimap.deinit();
        self.output_set.deinit(self.allocator);
        self.input_set.deinit(self.allocator);
        self.unused_set.deinit(self.allocator);
    }

    /// perform validation on the invariants. Is a no-op in ReleaseFast
    /// or ReleaseSmall.
    fn validate(self: Self) void {
        assert(self.input_set.subsetOf(self.unused_set));
        assert(self.output_set.subsetOf(self.unused_set));
    }
    /// Binds the given net to the given pin (u32).
    /// Checks that the pin is valid, and hasn't been assigned already.
    /// if the direction is not input, it checks that it's on an
    /// output-capable pin.
    pub fn bindNet(
        self: *Self,
        net: yosys_netlist.Net,
        dir: yosys_netlist.PortDirection,
        pin: u32,
    ) Error!void {
        if (net != .N) {
            return Error.InvalidNet;
        }
        if (self.bimap.containsA(net)) {
            return Error.NetAssigned;
        }
        // get the actual pin enum from the u32.
        // if this fails, the pin wasn't allowed period.
        const pin_enum = self.spec.getSpec().pinFromInt(pin) orelse
            return Error.InvalidPin;
        // check bitsets (assert - caller should have picked a valid one)
        if (!self.unused_set.isSet(pin)) {
            return Error.PinConsumed;
        }
        // non-inputs must be on the output set.
        if (dir != .input and !self.output_set.isSet(pin)) {
            return Error.PinConsumed;
        }
        // insert into mapping
        const inserted = try self.bimap.insert(net, pin_enum);
        assert(inserted);
        // clear bitsets
        self.unused_set.unset(pin);
        self.output_set.unset(pin);
        self.input_set.unset(pin);
    }

    /// Attempts to find a valid pin that can be used for mapping.
    /// Based on the direction, it will either pull from the output_set only
    /// or from the inputs first before trying the outputs.
    pub fn candidate(self: Self, dir: yosys_netlist.PortDirection) ?usize {
        switch (dir) {
            .input => {
                // try to find an input pin, or fall back to the unused set.
                return self.input_set.findFirstSet() orelse self.unused_set.findFirstSet();
            },
            else => {
                return self.output_set.findFirstSet();
            },
        }
    }
};

test PinMap {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pa = try PinMap.init(alloc, chip.ChipType.gal16v8);
    defer pa.deinit();
    // valid cases - an input on pin 2, and output on pin 16.
    try pa.bindNet(.{ .N = 1337 }, .input, 2);
    try pa.bindNet(.{ .N = 1338 }, .output, 16);
    // net collision
    {
        const collide = pa.bindNet(.{ .N = 1337 }, .output, 4);
        try testing.expectError(PinMap.Error.NetAssigned, collide);
    }
    // pin not allowed on chip
    {
        const vcc = pa.bindNet(.{ .N = 42 }, .output, 1);
        try testing.expectError(PinMap.Error.InvalidPin, vcc);
    }
    // pin was already used
    {
        const collide = pa.bindNet(.{ .N = 1 }, .output, 16);
        try testing.expectError(PinMap.Error.PinConsumed, collide);
    }
}


fn allocTester(alloc: Allocator) !void {
    var pa = try PinMap.init(alloc, chip.ChipType.gal16v8);
    defer pa.deinit();
}

test "pinmap allocations" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.checkAllAllocationFailures(alloc, allocTester, .{});
}
