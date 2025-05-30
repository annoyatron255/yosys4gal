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

const jed = @import("jed.zig");
const FuseMap = jed.FuseMap;
const chipinfo = @import("./chipinfo.zig");
const ChipSpec = chipinfo.ChipSpec;

pub const Pin = struct {
    pin: u32,
    inv: bool,
};
pub fn SopTerm(spec: *const ChipSpec) type {
    chipinfo.validatePinEnum(spec.pin_type);
    return struct {
        const Self = @This();
        /// how "long" each row is i.e number of columns.
        const depth = std.meta.fields(spec.pin_type).len;

        const pinRow = [depth]?Pin;
        const emptyRow: pinRow = [_]?Pin{null} ** depth;

        pins: []pinRow,

        pub fn init(allocator: Allocator, width: u32) Self {
            const pins = allocator.alloc(pinRow, width);
            @memset(pins, emptyRow);
            return .{
                .pins = pins,
            };
        }
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.pins);
        }

        pub fn clear(self: *Self) void {
            @memset(self.pins, emptyRow);
        }
    };
}
/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub fn PTerm(spec: *const ChipSpec) type {
    chipinfo.validatePinEnum(spec.pin_type);

    return struct {
        const Self = @This();
        /// InputPin stores the pin enum and an inversion flag
        pub const InputPin = struct { pin: spec.pin_type, inverted: bool = false };
        const n_entries = std.meta.fields(spec.pin_type).len;

        /// Array of pin entries. The size is based on the size of the pin enum.
        entries: [n_entries]?InputPin = [_]?InputPin{null} ** n_entries,

        /// Clears the PTerm
        pub fn clear(self: *Self) void {
            @memset(&self.entries, null);
        }

        /// Adds the pin to the PTerm. Will fail if there's no room
        /// or if there's already a pin with the same pin number.
        pub fn addPin(self: *Self, p: InputPin) !void {
            // zero shot insertion
            const idx = @intFromEnum(p.pin);
            if (self.entries[idx] == null) {
                self.entries[idx] = p;
            } else {
                return error.PinCollision;
            }
        }

        /// Produces a slice of bools that can be added to a fuse map.
        pub fn synthesize(self: *Self) ![]bool {
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

        pub fn format(self: Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;

            for (self.entries) |entry| {
                if (entry) |pin| {
                    const val = chipinfo.pinToInt(pin.pin) catch unreachable;
                    if (pin.inverted) {
                        try writer.print("(~{d})", .{val});
                    } else {
                        try writer.print("({d})", .{val});
                    }
                }
            }
        }
    };
}
test PTerm {
    const Term = PTerm(&chipinfo.GAL16V8Spec);
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
    // testing print
    {
        var term: Term = .{};
        const pin1: Term.InputPin = .{ .pin = .p2, .inverted = true };
        try term.addPin(pin1);
        var buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try std.fmt.format(fbs.writer(), "{}", .{term});
        try testing.expectEqualStrings("(~2)", fbs.getWritten());
    }
}

pub fn OLMC(spec: *const ChipSpec) type {
    // OLMCs can have a variable number of rows.
    return struct {
        const Self = @This();
        const Term = PTerm(spec);
        const PinType = spec.pin_type;
        allocator: Allocator,
        /// the pin that this OLMC drives.
        output_pin: PinType,
        /// The rows for the OLMC terms. Supports mixed-size rows (22v10)
        rows: []Term,
        /// Active high or low.
        active_high: bool = false,
        /// Registered or combinational.
        /// Note that the combinational mode uses the first term as the OE
        comb: bool = false,

        pub fn init(allocator: Allocator, size: usize, pin: PinType) !Self {
            const rows = try allocator.alloc(Term, size);
            for (rows) |*row| {
                row.clear();
            }
            return .{
                .allocator = allocator,
                .output_pin = pin,
                .rows = rows,
            };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
        }

        ///writes the OLMC to the fuse map.
        pub fn synthesize(self: Self, fmap: *FuseMap, index: usize) !void {
            try fmap.set(spec.olmc_ac1_address + index, self.comb);
            try fmap.set(spec.olmc_xor_address + index, self.active_high);
            var base = spec.olmc_block_address[index];
            for (self.rows) |row| {
                const data = try row.synthesize();
                try fmap.setSlice(base, data);
                base += data.len;
            }
        }

        /// set the OE term to the AND of the given pins
        pub fn set_oe_term(self: *Self, term: []const PinType) !void {
            // If the chip uses a global OE for registered outputs,
            // we will only allow OE terms on combinational rows
            if (spec.registered_global_oe) {
                assert(self.comb == true);
            }
            self.rows[0].clear();
            for (term) |p| {
                try self.rows[0].addPin(p);
            }
        }
    };
}

test OLMC {
    const alloc = testing.allocator;
    var olmc = try OLMC(&chipinfo.GAL16V8Spec).init(alloc, 2, .p2);
    defer olmc.deinit();
}

pub fn Chip(spec: *const ChipSpec) type {
    return struct {
        const Self = @This();
        const TermType = PTerm(spec);
        const OlmcType = OLMC(spec);

        allocator: Allocator,
        olmcs: []OlmcType,
        fusemap: *FuseMap,
    };
}
