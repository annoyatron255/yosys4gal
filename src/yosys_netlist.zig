//! Parser and data structure for Yosys JSON netlists.
//! Note that this netlist is partially parsed, since we don't
//! know the data structure of the cell types.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const testing = std.testing;
const assert = std.debug.assert;

const JsonStringMap = json.ArrayHashMap([]const u8);

const log = if (builtin.is_test)
    // Downgrade `err` to `warn` for tests.
    // Zig fails any test that does `log.err`, but we want to test those code paths here.
    struct {
        const base = std.log.scoped(.yosys_netlist);
        const err = warn;
        const warn = base.warn;
        const info = base.info;
        const debug = base.debug;
    }
else
    std.log.scoped(.yosys_netlist);

// --------------------------------------------------------------------------------
// String-to-int functions and tests
// --------------------------------------------------------------------------------

/// convert the yosys string-of-bits to a given integer type.
/// Note that the lengths must be exact, i.e if a string is shorter than
/// the container, it will still error.
pub fn strtob(comptime T: type, str: []const u8) !T {
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("strtob only accepts unsigned integer types");
    }
    const n_bits = info.int.bits;

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
            log.err("unexpected character in bitstring: {c}", .{c});
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
    allocator: Allocator,
    val: T,
) ![]u8 {
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("btostr only accepts unsigned integer types");
    }

    const n_bits = info.int.bits;

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

// END string-bits functions

// --------------------------------------------------------------------------------
// JsonStringMap helper functions
// These functions are used to operate on the JsonStringMap type, which is
// a JSON-serializeable string -> string map.
// --------------------------------------------------------------------------------

/// Reads a property from a JsonStringMap. the type can be a string, or an integer type.
/// If it's an integer type, it will convert the string-of-bits to said integer using
/// strtob. If the property does not exist, or it fails to parse with strtob,
/// it will return null.
pub fn readProperty(comptime T: type, map: JsonStringMap, prop: []const u8) ?T {
    const val = map.map.get(prop) orelse return null;

    if (T == []const u8) {
        return val;
    } else {
        return strtob(T, val) catch null;
    }
}

test readProperty {
    const alloc = testing.allocator;
    const j =
        \\{
        \\  "string": "value",
        \\  "binary": "011011"
        \\}
    ;
    const result = try json.parseFromSlice(JsonStringMap, alloc, j, .{});
    defer result.deinit();

    const map = result.value;
    {
        const prop = readProperty([]const u8, map, "string") orelse unreachable;
        try testing.expectEqualStrings("value", prop);
    }
    {
        const prop = readProperty(u8, map, "binary") orelse unreachable;
        try testing.expectEqual(0b011011, prop);
    }
}

// --------------------------------------------------------------------------------
// Yosys Netlist core definitions.
// These are the actual representations of the Yosys netlist.
// We don't add new fields here - if we need to, things get complicated.
// Instead, try and create wrapper or container structs that have fields
// pointing to structures inside the Netlist.
// --------------------------------------------------------------------------------

/// Net type. In Yosys, nets are either a numeric value, or one of xz01 literals
/// which means that the input is fixed to a global or don't care.
pub const Net = union(enum) {
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
    pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !Net {
        const v: json.Value = try json.innerParse(json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    /// parse net from json value
    pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) !Net {
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
        var stream = std.Io.Writer.fixed(&buf);
        var writer = json.Stringify{ .writer = &stream };

        try writer.write(net);
        try testing.expectEqualStrings(j, buf[0..stream.end]);

        const roundtrip = try json.parseFromSlice(Net, alloc, buf[0..stream.end], .{});
        defer roundtrip.deinit();
        try testing.expectEqual(net, roundtrip.value);
    }
}

pub const BitVector = []const Net;

/// Yosys netlist. has a creator string, which gives details
/// on the yosys version. Contains a set of named modules.
pub const Netlist = struct {
    const Self = @This();
    creator: []const u8,
    modules: json.ArrayHashMap(Module),

    /// Finds the top module of the given netlist.
    pub fn findTopModule(self: Self) *Module {
        // iterate through the modules, and attempt to readProperty "top"
        // as a u32. if we find it, and it's >0, then return that module.
        // else return null

        const iter = self.modules.map.values();

        for (iter) |*mod| {
            const attr_top = readProperty(u32, mod.attributes, "top");
            if (attr_top) |top_value| {
                // I think this statement is true generally.
                assert(top_value > 0);
                return mod;
            }
        }

        // if we don't have a top module, we're screwed.
        @panic("unable to find top module");
    }
};

test Netlist {
    const alloc = testing.allocator;
    const netlist = try getExampleNetlist(alloc);
    defer netlist.deinit();
    {
        const top_ptr = netlist.value.modules.map.getPtr("olmc_test");
        try testing.expectEqual(top_ptr, netlist.value.findTopModule());
    }
}

/// A module is an entire netlist consisting of cells (which are typically
/// instances of other modules)
pub const Module = struct {
    attributes: JsonStringMap,
    ports: json.ArrayHashMap(Port),
    cells: json.ArrayHashMap(Cell),
    netnames: json.ArrayHashMap(NetDetails),
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

/// Module Port information. Note that this is different from
/// the "port_directions" parameter of cells.
pub const Port = struct {
    /// The direction of this port.
    direction: PortDirection,
    bits: BitVector,
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
        const result = try json.parseFromSlice(Port, alloc, j, .{});
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
        const result = try json.parseFromSlice(Port, alloc, j, .{});
        defer result.deinit();
        const expected = Port{
            .direction = .output,
            .bits = &.{ Net{ .N = 2 }, .DontCare },
            .upto = 1,
        };
        try testing.expectEqualDeep(expected, result.value);
    }
}

/// Yosys Netlist Cell type.
pub const Cell = struct {
    const Self = @This();
    const PropType = enum {
        attr,
        param,
    };
    /// Cell type. Index into modules to find the root cell.
    type: []const u8,
    /// Parameters of this instance of the cell.
    parameters: JsonStringMap,
    /// misc attributes of the cell
    attributes: JsonStringMap,
    /// Connections on ports of this cell.
    connections: json.ArrayHashMap(BitVector),

    port_directions: json.ArrayHashMap(PortDirection),

    /// Returns a port/idx if a net is present on the cell, otherwise null.
    pub fn hasNet(self: Self, net: Net) ?struct { port: []const u8, idx: usize } {
        // search through the connections
        assert(net == .N);
        const n = net.N;
        const conns = self.connections.map.iterator();
        while (conns.next()) |c| {
            const name = c.key_ptr;
            const nets = c.value_ptr;
            for (nets, 0..) |net_on_conn, idx| {
                if (n == net_on_conn) {
                    return .{ .port = name.*, .idx = idx };
                }
            }
        }
        return null;
    }

    /// Attempt to read a value from the properties of the cell.
    pub fn getProp(self: Self, comptime T: type, prop: PropType, name: []const u8) ?T {
        return switch (prop) {
            .attr => readProperty(T, self.attributes, name),
            .param => readProperty(T, self.parameters, name),
        };
    }
};

/// Internal net naming system. Typically you won't need to access this.
pub const NetDetails = struct {
    /// attributes include hdlname and src
    attributes: JsonStringMap,
    /// all of the bits that belong to this net.
    bits: BitVector,
    /// The ordering of this net.
    upto: u1 = 0,
    /// The offset???
    offset: i8 = 0,
};

// --------------------------------------------------------------------------------
// Auxiliary and helper data structures.
// These exist to aid more complex tasks.
// --------------------------------------------------------------------------------

/// Map a net to a list of objects, which typically contain information/references
/// about elements in the netlist. T should be something like struct { cell: *const Cell }.
/// If there's a guaranteed 1-1 mapping, use NetMap instead.
pub fn NetMapMany(comptime T: type) type {
    return struct {
        const Self = @This();
        const LookupTable = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(T));

        gpa: Allocator,
        lookup: LookupTable,

        pub fn init(allocator: Allocator) !Self {
            return .{
                .gpa = allocator,
                .lookup = .empty,
            };
        }
        pub fn deinit(self: *Self) void {
            // cleanup the arraylists
            var vals = self.lookup.iterator();
            while (vals.next()) |entry| {
                entry.value_ptr.deinit(self.gpa);
            }
            // cleanup the lookup
            self.lookup.deinit(self.gpa);
        }

        /// Add the value to the net, creating the arraylist if necessary.
        pub fn append(self: *Self, key: Net, value: T) !void {
            if (key != .N) {
                return error.InvalidNet;
            }
            const gop = try self.lookup.getOrPut(self.gpa, key.N);
            // invariant: key is either null or non-empty arraylist.
            // it can never be an empty arraylist.
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty; // try std.ArrayListUnmanaged(T).initCapacity(self.gpa, 8);
            }
            try gop.value_ptr.append(self.gpa, value);
        }
        /// Searches a key array for a function matching the predicate.
        pub fn getFiltered(self: Self, key: Net, search: fn (v: T) bool) ?T {
            if (self.lookup.get(key.N)) |list| {
                for (list.items) |entry| {
                    if (search(entry)) {
                        return entry;
                    }
                }
            }
            return null;
        }
    };
}

/// NetCellMap is a mapping of a net to an array of cells. It is used to traverse quickly from
/// Cell -> Net -> Cell -> etc.
pub const NetCellMap = NetMapMany(NetCellMember);
/// References a cell and a port name that the net uses. We include the port
/// name and direction here to speed up filtering.
pub const NetCellMember = struct {
    cell: *const Cell,
    port: []const u8,
    direction: PortDirection,
};

/// Create a map that gives a list of cells when provided with a non-constant net.
pub fn buildNetCellMap(allocator: Allocator, module: *const Module) !NetCellMap {
    var map = try NetCellMap.init(allocator);
    errdefer map.deinit();

    var cells = module.cells.map.iterator();

    while (cells.next()) |entry| {
        const cell = entry.value_ptr;

        var ports = cell.connections.map.iterator();
        while (ports.next()) |port| {
            const port_name = port.key_ptr.*;
            const port_nets = port.value_ptr.*;
            // lookup the cell
            const dir = cell.port_directions.map.get(port_name).?;

            const binding: NetCellMember = .{
                .cell = cell,
                .port = port_name,
                .direction = dir,
            };
            for (port_nets) |net| {
                if (net == .N) {
                    try map.append(net, binding);
                }
            }
        }
    }
    return map;
}

/// Predefined filters for the .getFiltered method
pub const filters = struct {
    /// Finds the singular driver of a net.
    pub fn netDriver(cellInfo: NetCellMember) bool {
        return cellInfo.direction != .input;
    }
};

fn testNetCellMap(alloc: Allocator) !void {
    const netlist = try getExampleNetlist(alloc);
    defer netlist.deinit();

    const top = netlist.value.findTopModule();

    // this is the actual test
    var netmap = try buildNetCellMap(alloc, top);
    defer netmap.deinit();
    // this is an annoyingly fragile test.
    const cells = netmap.lookup.get(5) orelse unreachable;

    // there should just be one OLMC on this net.
    try testing.expectEqual(1, cells.items.len);
    const net = cells.items[0];
    // it should be the output port
    try testing.expectEqualStrings("Y", net.port);
    // it should have the inout direction
    try testing.expectEqual(.inout, net.direction);

    // check that it's the one we think it is.
    const expected = top.cells.map.getPtr("$iopadmap$olmc_test.AND") orelse unreachable;
    const actual = net.cell;
    try testing.expectEqual(expected, actual);
}

test buildNetCellMap {
    const alloc = testing.allocator;
    // getOrPut can swallow OOM if the key already exists.
    testing.checkAllAllocationFailures(alloc, testNetCellMap, .{}) catch |err| switch (err) {
        error.SwallowedOutOfMemoryError => return,
        else => return err,
    };
}

/// Mapping of nets to ports. a net can belong to more than one port?
pub const NetPortMap = NetMapMany(NetPortMember);

pub const NetPortMember = struct {
    port: *Port,
    direction: PortDirection,
    index: usize = 0,
};

pub fn buildNetPortMap(allocator: Allocator, module: *const Module) !NetPortMap {
    var map = try NetPortMap.init(allocator);
    errdefer map.deinit();
    var ports = module.ports.map.iterator();

    while (ports.next()) |entry| {
        const port = entry.value_ptr;

        for (port.bits, 0..) |net, idx| {
            // I don't see how a module could have a hard-coded net value as a port.
            assert(net == .N);
            const member: NetPortMember = .{
                .direction = port.direction,
                .port = port,
                .index = idx,
            };
            try map.append(net, member);
        }
    }
    return map;
}

test buildNetPortMap {
    const alloc = testing.allocator;
    const netlist = try getExampleNetlist(alloc);
    defer netlist.deinit();

    const top = netlist.value.findTopModule();

    var map = try buildNetPortMap(alloc, top);
    defer map.deinit();
}

/// Helper function to read a netlist from a file path.
pub fn readNetlist(alloc: Allocator, io: Io, path: []const u8) !json.Parsed(Netlist) {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var freader = file.reader(io, &buf);
    var reader = std.json.Reader.init(alloc, &freader.interface);
    defer reader.deinit();
    return try std.json.parseFromTokenSource(
        Netlist,
        alloc,
        &reader,
        .{ .ignore_unknown_fields = true },
    );
}

/// Testing function to get the example netlist.
pub fn getExampleNetlist(alloc: Allocator) !json.Parsed(Netlist) {
    const example = "./output/synth_olmc_test.json";
    const io = testing.io;

    return readNetlist(alloc, io, example);
}

fn netlistAllocTest(alloc: Allocator) !void {
    const nl = try getExampleNetlist(alloc);
    defer nl.deinit();
}

test "Netlist Alloc" {
    const alloc = testing.allocator;
    try testing.checkAllAllocationFailures(alloc, netlistAllocTest, .{});
}
