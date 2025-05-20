//! Parser and data structure for Yosys JSON netlists.
//! Note that this netlist is partially parsed, since we don't
//! know the data structure of the cell types.

const std = @import("std");
const json = std.json;

const testing = std.testing;

/// convert the yosys string-of-bits to a given integer type.
/// Note that the lengths must be exact, i.e if a string is shorter than
/// the container, it will still error.
pub fn strtob(comptime T: type, str: []const u8) !T {
    comptime {
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("strtob only accepts unsigned integer types");
        }
    }
    const n_bits = @typeInfo(T).int.bits;

    // check that our target uint is big enough to hold the string.
    // note that technically we could find the most significant 1 bit,
    // but that's complex and probably means the program has a bug.
    if (str.len > n_bits) {
        return error.SizeMismatch;
    }
    //
    var result: T = 0;

    for (str, 0..) |c, i| {
        if (c == '1') {
            result |= @as(T, 1) << @intCast(str.len - i - 1);
        } else if (c != '0') {
            // not 0 or 1, so error
            return error.InvalidChar;
        }
    }
    return result;
}

test strtob {
    {
        const result = try strtob(u8, "101");
        try testing.expectEqual(5, result);
    }
    {
        const result = try strtob(u8, "001");
        try testing.expectEqual(1, result);
    }
    try testing.expectError(error.SizeMismatch, strtob(u3, "1010"));
    try testing.expectError(error.InvalidChar, strtob(u8, "a"));
}

/// Take a unsigned integer and convert it to a binary string.
/// similar to the yosys format. will allocate a []u8
/// that must be manually freed.
pub fn btostr(
    comptime T: type,
    allocator: std.mem.Allocator,
    val: T,
) ![]u8 {
    comptime {
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned) {
            @compileError("btostr only accepts unsigned integer types");
        }
    }

    const n_bits = @typeInfo(T).int.bits;

    var result = try allocator.alloc(u8, n_bits);
    errdefer allocator.free(result);

    var temp = val;
    var i: usize = n_bits;
    while (i > 0) : (i -= 1) {
        result[i - 1] = if (temp & 1 == 1) '1' else '0';
        temp >>= 1;
    }

    return result;
}

test btostr {
    const streql = testing.expectEqualStrings;

    const actual = try btostr(u8, testing.allocator, 5);

    try streql("00000101", actual);
    testing.allocator.free(actual);
}

/// Net type. In Yosys, nets are either a numeric value, or one of xz01
/// which means that the input is fixed to a global or don't care.
const Net = union(enum) {
    /// "x" meaning we don't care about the value
    DontCare,
    /// "z" High-Z
    HiZ,
    /// Literal one, as in tied high
    LitOne,
    /// Literal zero, tied low
    LitZero,
    /// A net that is routed to other cells
    N: u32,

    /// Serializes this net type into json.
    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        return switch (self.*) {
            .N => |net| jws.write(net),
            .LitOne => jws.write("1"),
            .LitZero => jws.write("0"),
            .HiZ => jws.write("z"),
            .DontCare => jws.write("x"),
        };
    }

    /// parse a net from json.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Net {
        const v: std.json.Value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    /// parse net from json value
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Net {
        _ = allocator;
        _ = options;
        return switch (source) {
            json.Value.integer => |i| @This(){ .N = @intCast(i) },
            json.Value.string => |i| {
                if (i.len != 1) {
                    return error.ValueTooLong;
                }
                return switch (i[0]) {
                    'x' => .DontCare,
                    'z' => .HiZ,
                    '0' => .LitZero,
                    '1' => .LitOne,
                    else => error.UnexpectedToken,
                };
            },
            else => error.UnexpectedToken,
        };
    }
};

test Net {
    var buf: [128]u8 = undefined;
    const alloc = testing.allocator;

    const tests = [_]struct { Net, []const u8 }{
        .{ Net{ .N = 32 }, "32" },
        .{ .DontCare, "\"x\"" },
        .{ .HiZ, "\"z\"" },
        .{ .LitZero, "\"0\"" },
        .{ .LitOne, "\"1\"" },
    };

    for (tests) |t| {
        const net, const j = t;
        var stream = std.io.fixedBufferStream(&buf);

        try std.json.stringify(net, .{}, stream.writer());
        const serialized = stream.getWritten();
        try testing.expectEqualStrings(j, serialized);

        const roundtrip = try std.json.parseFromSlice(Net, alloc, serialized, .{});
        defer roundtrip.deinit();
        try testing.expectEqual(net, roundtrip.value);
    }
}

/// Yosys netlist. has a creator string, which gives details
/// on the yosys version. Contains a set of named modules.
pub const Netlist = struct {
    creator: []const u8,
    modules: std.StringHashMap(Module),

    /// ensures invariants about the netlist
    pub fn validate(self: *Netlist) !void {
        // expect only one top module
        //
        _ = self;
    }
};

/// A module is an entire netlist consisting of cells (which are typically
/// instances of other modules)
pub const Module = struct {
    attributes: std.StringHashMap([]const u8),
    ports: std.StringHashMap(Port),
    cells: std.StringHashMap(Cell),
    netnames: std.StringHashMap(NetName),
};

/// A port direction. Ports attach to one or more nets.
/// There are constraints on the nets.
/// basically can have 1 output per net, or 1 or more inouts (but not both).
/// can have as many inputs on a net as you want.
pub const PortDirection = enum {
    input,
    output,
    inout,
};

pub const Port = struct {
    /// The direction of this port.
    direction: PortDirection,
    bits: []const Net,
    upto: u1 = 0,
    offset: i8 = 0,
};

test Port {
    const alloc = testing.allocator;
    {
        const j =
            \\{
            \\  "direction": "input",
            \\  "bits": [ 2 ]
            \\}
        ;
        const result = try std.json.parseFromSlice(Port, alloc, j, .{});
        defer result.deinit();
        const expected = Port{
            .direction = .input,
            .bits = &.{Net{ .N = 2 }},
        };
        try testing.expectEqualDeep(expected, result.value);
    }
    {
        const j =
            \\{
            \\  "direction": "output",
            \\  "upto": 1,
            \\  "bits": [ 2, "x" ]
            \\}
        ;
        const result = try std.json.parseFromSlice(Port, alloc, j, .{});
        defer result.deinit();
        const expected = Port{
            .direction = .output,
            .bits = &.{ Net{ .N = 2 }, .DontCare },
            .upto = 1,
        };
        try testing.expectEqualDeep(expected, result.value);
    }
}

pub const Cell = struct {
    /// Cell type. Index into modules to find the root cell.
    type: []const u8,
    /// Parameters of this instance of the cell.
    parameters: std.StringHashMap([]const u8),
    /// misc attributes of the cell
    ///
    attributes: std.StringHashMap([]const u8),
    /// Connections on ports of this cell.
    connections: std.StringHashMap([]const Net),
};

/// Internal net naming system. typically you won't need to access this.
pub const NetName = struct {
    /// attributes include hdlname and src
    attributes: std.StringHashMap([]const u8),
    /// all of the bits that belong to this net.
    bits: []const Net,
    /// The ordering of this net.
    upto: u1 = 0,
    /// The offset???
    offset: i8 = 0,
};
