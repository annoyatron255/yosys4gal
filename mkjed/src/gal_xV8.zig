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
    olmc_row_sizes: []const u32,

    /// starting fuse address of the xor bits for OLMCs
    /// Use the index in the OLMC array to increment
    olmc_xor_address: u32,
    /// starting fuse address of the ac1 bits for OLMCs.
    /// Use the index in the OLMC array to increment
    olmc_ac1_address: u32,

    /// If, in registered mode, we have a global OE pin, or
    /// OE terms for each OLMC. If the latter, the total size
    /// of the "logic" terms is row_size - 1 for registered
    registered_global_oe: bool,
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
    .olmc_row_sizes = &[_]u32{8} ** 8,
    .registered_global_oe = true,
};

// The Pin type category is an enum with values in the shape of p<uint>. They
// are then processed at compile time to allow for pinFromInt and pinToInt. We
// expect an offsets: [_]u8 constant that contains the pin column offsets.

/// GAL16V8 input pins.
pub const Pin16V8 = enum {
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
    // pin 11 is global OE
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
    pub fn toOffset(self: Pin16V8) u8 {
        return offsets[@intFromEnum(self)];
    }
};

test Pin16V8 {
    validatePinEnum(Pin16V8);
}

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

// compile time check that a type matches the contract for the pin enum.
fn validatePinEnum(comptime T: anytype) void {
    comptime {
        const info = @typeInfo(T);
        assert(info == .@"enum");
        assert(info.@"enum".is_exhaustive);
        assert(@hasDecl(T, "offsets"));
        assert(info.@"enum".fields.len == T.offsets.len);
        for (info.@"enum".fields) |field| {
            assert(field.name[0] == 'p');
            _ = std.fmt.parseInt(usize, field.name[1..], 10) catch unreachable;
        }
    }
}

/// PTerm is a product term. It contains a list of pins, which are then AND'ed together.
/// OLMCs will take an array of PTerms and OR them together to get the final result of
/// the logic array.
pub fn PTerm(spec: *const ChipSpec) type {
    validatePinEnum(spec.pin_type);

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
                    const val = pinToInt(pin.pin) catch unreachable;
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

pub fn SOPTerm(spec: *const ChipSpec) type {
    return struct {
        const Self = @This();
        const Product = PTerm(spec);

        allocator: Allocator,
        products: []Product,

        pub fn init(allocator: Allocator, size: usize) !Self {
            const products = try allocator.alloc(Product, size);
            for (products) |*prod| {
                prod.clear();
            }

            return .{
                .allocator = allocator,
                .products = .rows,
            };
        }

        pub fn format(self: Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            var first = true;
            for (self.products) |prod| {
                if (!first) {
                    // print a plus
                    writer.writeAll(" + ", .{});
                }
                first = false;
                writer.print("{}", .{prod});
            }
        }
    };
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
    var olmc = try OLMC(&GAL16V8Spec).init(alloc, 2, .p2);
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
