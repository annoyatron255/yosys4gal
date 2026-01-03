//! PinMap is a helper to track complete and incomplete pin<->net assignments.
//! It uses a simple linear search rather than a pair of hashmaps (BiMap)

const std = @import("std");
const assert = std.debug.assert;
const yosys_netlist = @import("./yosys_netlist.zig");
const chipinfo = @import("./chipinfo.zig");
const Spec = chipinfo.Spec;
const Net = yosys_netlist.Net;

const PinMap = @This();
/// the list of pins that this map is tracking
pins: []?PinInfo = undefined,
/// the chip specification.
spec: *const Spec = undefined,

/// Internal storage about a pin.
const PinInfo = struct {
    /// assignment info - input or output from a net.
    const PinAssignment = union(enum) {
        in: yosys_netlist.Net,
        out: yosys_netlist.Net,
    };
    ///  if this pin supports output or is input-only
    const PinMode = enum { io, input };
    /// if the pin is .io, the size of the term it supports for output.
    /// if the size varies, this is the larger of two sizes. 0 for .input
    size: usize = 0,
    /// direction of this pin
    mode: PinMode = .input,
    /// the net this pin is assigned to, if any.
    assignment: ?Net = null,

    /// true if unassigned.
    fn unused(self: *const PinInfo) bool {
        return self.assignment == null;
    }
    fn fits_output(self: *const PinInfo, size: usize) bool {
        return self.unused() and self.size >= size and self.mode == .io;
    }
};

const Error = error{
    /// The given pin was not allowed for the chip
    InvalidPin,
    /// The pin has already been assigned to another net
    PinConsumed,
    /// the net was one of the constant values (0,1,x,z)
    InvalidNet,
    /// The net has already been assigned; this is an invariant that
    /// we uphold.
    NetAssigned,
} || std.mem.Allocator.Error;

/// search for a pin that uses this net, if any.
pub fn net_lookup(self: *const PinMap, needle: Net) ?chipinfo.Pin {
    for (self.pins, 0..) |pinfo, idx| {
        if (pinfo) |p| {
            if (p.assignment != null and std.meta.eql(needle, p.assignment.?)) {
                return @enumFromInt(idx);
            }
        }
    }
    return null;
}
/// find a candidate input pin. Tries to use the exclusive inputs, otherwise
/// burns the smallest OLMC to add more.
pub fn input_candidate(self: *const PinMap) ?chipinfo.Pin {
    var pin_idx: usize = undefined;
    var candidate: ?PinInfo = null;

    for (self.pins, 0..) |p, idx| {
        if (p) |pin| {
            if (pin.unused() and pin.mode == .input) {
                if (candidate == null or candidate.?.size > pin.size) {
                    candidate = pin;
                    pin_idx = idx;
                }
            }
        }
    }
    if (candidate == null) {
        return output_candidate(self, 0);
    } else {
        return @enumFromInt(pin_idx);
    }
}


/// find a candidate for an output of AT LEAST the given size. this
/// will find the smallest non-assigned output.
pub fn output_candidate(self: *const PinMap, size: usize) ?chipinfo.Pin {
    var pin_idx: usize = undefined;
    var candidate: ?PinInfo = null;
    for (self.pins, 0..) |p, idx| {
        if (p) |pin| {
            if (pin.fits_output(size)) {
                if (candidate == null or candidate.?.size > pin.size) {
                    candidate = pin;
                    pin_idx = idx;
                }
            }
        }
    }
    if (candidate == null) {
        return null;
    } else {
        return @enumFromInt(pin_idx);
    }
}
/// bind the given net (with the drive direction) to the pin.
pub fn bind(self: *PinMap, net: Net, dir: yosys_netlist.PortDirection, pin: chipinfo.Pin) Error!void {
    if (net != .N) {
        return Error.InvalidNet;
    }
    if (net_lookup(self, net) != null) {
        return Error.NetAssigned;
    }
    const pidx = @intFromEnum(pin);
    assert(self.pins[pidx] != null);
    if (self.pins[pidx].?.assignment != null) {
        return Error.PinConsumed;
    }
    // if we're an output net, check that the pin is io
    if (dir == .inout or dir == .output) {
        if (self.pins[pidx].?.mode != .io) {
            return Error.InvalidPin;
        }
    }
    self.pins[pidx].?.assignment = net;
}

pub fn init(allocator: std.mem.Allocator, chip: chipinfo.ChipType) !PinMap {
    const spec = chip.getSpec();
    var pins = try allocator.alloc(?PinInfo, spec.num_pins);
    @memset(pins, null);

    for (spec.pins) |pin_spec| {
        const idx = @intFromEnum(pin_spec.@"0");
        pins[idx] = .{};
    }

    for (spec.olmcs) |olmc_spec| {
        const idx = @intFromEnum(olmc_spec.pin);
        pins[idx] = .{
            .size = olmc_spec.sop_fuses.@"1" / spec.num_cols,
            .mode = .io,
        };
    }
    return .{
        .spec = spec,
        .pins = pins,
    };
}
pub fn deinit(self: *PinMap, allocator: std.mem.Allocator) void {
    allocator.free(self.pins);
}

test PinMap {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pa = try PinMap.init(alloc, chipinfo.ChipType.gal16v8);
    defer pa.deinit(alloc);
    try pa.bind(.{ .N = 1337 }, .input, @enumFromInt(2));
    try pa.bind(.{ .N = 1338 }, .output, @enumFromInt(16));
    // net collision
    {
        const collide = pa.bind(.{ .N = 1337 }, .output, @enumFromInt(4));
        try testing.expectError(PinMap.Error.NetAssigned, collide);
    }
    // pin was already used
    {
        const collide = pa.bind(.{ .N = 1 }, .output, @enumFromInt(16));
        try testing.expectError(PinMap.Error.PinConsumed, collide);
    }
}
