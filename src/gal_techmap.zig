//! Describes various Yosys cells that form a Verilog to GAL

const std = @import("std");
const Allocator = std.mem.Allocator;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const testing = std.testing;
const assert = std.debug.assert;

const yosys_netlist = @import("./yosys_netlist.zig");
const BiMap = @import("./util/bimap.zig").BiMap;
const Array2D = @import("./util/array2d.zig").Array2D;
const xv8 = @import("./gal_xV8.zig");
const chip = @import("./chipinfo.zig");
const pcf = @import("./pcf.zig");
const PinMap = @import("./pin_mapping.zig").PinMap;
// Validation function that ensures that the netlist is using our techmap.
/// One of the invariants we assume about the gal netlist is invalid.
const TechmapError = error{
    UnknownCellType,
    MissingSop,
    SopSizeError,
    Unknown,
    InvalidPin,
    PinNotFound,
};

const CellType = enum {
    const Self = @This();
    Olmc,
    Sop,
    Input,
    pub const strings = blk: {
        const fields = std.meta.fields(Self);
        var arr: [fields.len][]const u8 = undefined;

        // Build each entry
        for (fields, 0..) |f, i| {
            var buf: [1024]u8 = undefined;
            const name_up = std.ascii.upperString(&buf, f.name);
            // "GAL_" prefix, e.g. "GAL_OLMC"
            arr[i] = std.fmt.comptimePrint("GAL_{s}", .{name_up});
        }
        break :blk arr;
    };
    pub fn toString(self: Self) []const u8 {
        return strings[@intFromEnum(self)];
    }
    pub fn fromString(s: []const u8) ?Self {
        inline for (strings, 0..) |name, idx| {
            if (std.mem.eql(u8, s, name)) {
                return @enumFromInt(idx);
            }
        }
        return null;
    }
};

fn validate(netlist: *const yosys_netlist.Netlist) TechmapError!void {
    const top = netlist.findTopModule();

    // iterate through the cells, ensuring that each one is one of validCellTypes.

    const cells = top.cells.map.values();
    for (cells) |cell| {
        if (CellType.fromString(cell.type) == null)
            return TechmapError.UnknownCellType;
    }
}

test validate {
    const alloc = testing.allocator;
    // This is all netlist setup
    const netlist = try yosys_netlist.getExampleNetlist(alloc);
    defer netlist.deinit();
    try validate(&netlist.value);
}

// all of these cells have a ref which points to their parent.
// methods reach into the cell to extract information

pub const OlmcCell = struct {
    ref: *yosys_netlist.Cell,
    src: ?*SopCell = null,
    oe_src: ?*SopCell = null,
};

pub const InputCell = struct {
    ref: *yosys_netlist.Cell,
};
fn ctobool(char: u8) bool {
    return switch (char) {
        '0' => false,
        '1' => true,
        _ => unreachable,
    };
}
pub const SopCell = struct {
    ref: *yosys_netlist.Cell,
    /// Convert this SOP and place it on the given array2d.
    pub fn toArray(self: SopCell, tm: *TechMap, pm: PinMap, out: *Array2D(bool)) !void {
        // extract the params.
        // depth aka number of products
        const depth = self.ref.getProp(u32, .param, "DEPTH");
        // width
        const width = self.ref.getProp(u32, .param, "WIDTH");
        // table is []const u8 still - could be huge.
        const table = self.ref.getProp([]const u8, .param, "TABLE");
        const inputs = self.ref.connections.map.get("A").?;
        assert(width == inputs.len);
        assert(table.len == width * depth * 2);

        // look at each input, map to net, then pin.
        // based on the pin compute the column we need to edit.
        // then go through each product term with that input,
        // and set the rows based on table
        for (inputs, 0..) |input, idx| {
            // do we always have this?
            const pin = pm.bimap.getA(input).?;
            const col = tm.chip_type.getSpec().getPinCol(pin);
            // compute the table.
            for (0..depth) |row| {
                // width * row -> put us in the correct product
                // idx * 2 - select inside the product
                const pos = width * row + idx * 2;
                out.set(row, col, ctobool(table[pos]));
                out.set(row, col + 1, ctobool(table[pos + 1]));
            }
        }
    }
};

/// GAL chip mapping state
pub const TechMap = struct {
    const Self = @This();
    allocator: Allocator,
    npm: yosys_netlist.NetPortMap,
    ncm: yosys_netlist.NetCellMap,
    chip_type: chip.ChipType,
    olmcs: std.ArrayListUnmanaged(OlmcCell) = .empty,
    sops: std.ArrayListUnmanaged(SopCell) = .empty,
    inputs: std.ArrayListUnmanaged(InputCell) = .empty,
    netlist: *const yosys_netlist.Netlist,

    pub fn init(
        allocator: Allocator,
        chip_type: chip.ChipType,
        netlist: *const yosys_netlist.Netlist,
    ) !Self {
        const top = netlist.findTopModule();
        const ncm = try yosys_netlist.buildNetCellMap(allocator, top);
        const npm = try yosys_netlist.buildNetPortMap(allocator, top);
        var self = Self{
            .chip_type = chip_type,
            .netlist = netlist,
            .npm = npm,
            .ncm = ncm,
            .allocator = allocator,
        };
        // iterate through the cells. for each cell, determine the type.
        var cells = top.cells.map.iterator();

        var sop_count: usize = 0;
        var olmc_count: usize = 0;
        while (cells.next()) |entry| {
            const cell_name = entry.key_ptr;
            const cell = entry.value_ptr;

            std.log.debug("processing cell {s}", .{cell_name});

            const ctype = CellType.fromString(cell.type) orelse return TechmapError.UnknownCellType;

            switch (ctype) {
                .Input => {
                    const input: InputCell = .{ .ref = cell };
                    try self.inputs.append(self.allocator, input);
                },
                .Sop => {
                    const sop: SopCell = .{ .ref = cell };
                    try self.sops.append(self.allocator, sop);
                    sop_count += 1;
                },
                .Olmc => {
                    // find the net of the output ("Y");
                    const olmc: OlmcCell = .{ .ref = cell };
                    try self.olmcs.append(self.allocator, olmc);
                    olmc_count += 1;
                },
            }
        }
        return self;
    }
    pub fn deinit(self: *Self) void {
        self.npm.deinit();
        self.ncm.deinit();
        self.olmcs.deinit(self.allocator);
        self.sops.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
    }
};

test TechMap {
    const alloc = testing.allocator;
    // This is all netlist setup
    const netlist = try yosys_netlist.getExampleNetlist(alloc);
    defer netlist.deinit();
    var tm = try TechMap.init(alloc, chip.ChipType.gal16v8, &netlist.value);
    defer tm.deinit();
}

/// Maps the nets to the pins.
/// Optionally takes a PCF constraint file to bind module's ports to
/// specific pins.
const DeferredPort = struct {
    net: yosys_netlist.Net,
    dir: yosys_netlist.PortDirection,
};


/// bind the constraints from the pcf file, and then bind the remaining ports.
fn mapPins(
    allocator: Allocator,
    pinmap: *PinMap,
    ports: std.json.ArrayHashMap(yosys_netlist.Port),
    constraints: *const pcf.PinConstraints,
) !void {
    // ports that we need to assign later, after we're done with the PCF.
    var deferred_nets = std.ArrayList(DeferredPort).init(allocator);
    defer deferred_nets.deinit();
    // first pass - bind PCF constrained pins.
    var port_iter = ports.map.iterator();
    while (port_iter.next()) |entry| {
        const port_name = entry.key_ptr;
        const port = entry.value_ptr;
        if (constraints.clk_net) |clk_net| {
            if (std.mem.eql(u8, clk_net, port_name.*)) {
                continue;
            }
        }
        const dir = port.direction;
        assert(port.bits.len > 0);
        if (port.bits.len == 1) {
            // check if we have a constraint
            if (constraints.get(port_name.*)) |pin| {
                try pinmap.bindNet(port.bits[0], dir, pin);
            } else {
                try deferred_nets.append(.{ .dir = dir, .net = port.bits[0] });
            }
        } else {
            for (port.bits, 0..) |net, idx| {
                // construct the port[index].
                var buf: [100]u8 = undefined;
                const fullname = try std.fmt.bufPrint(&buf, "{s}[{d}]", .{ port_name, idx });
                if (constraints.get(fullname)) |pin| {
                    try pinmap.bindNet(net, dir, pin);
                } else {
                    try deferred_nets.append(.{ .dir = dir, .net = net });
                }
            }
        }
    }
    // now clean up the deferred pins.
    // compute non-output pins:
    var input_pins_unused = try pinmap.unused_set.clone(allocator);
    defer input_pins_unused.deinit(allocator);
    {
        var out_iter = pinmap.output_set.iterator(.{});
        while (out_iter.next()) |op| {
            input_pins_unused.unset(op);
        }
    }

    // Iterate through the deferred ports. if it's an input,
    // try to use the input pins first.
    // if it's an output or inout, we must use the output sets.
    for (deferred_nets.items) |dnet| {
        if (dnet.dir == .input) {
            // pick unassigned bit from input_pins_unused;
            var candidate = input_pins_unused.findFirstSet();
            if (candidate == null) {
                // we couldn't find an input pin, so let's reach for an output pin to sacrifice.
                candidate = pinmap.unused_set.findFirstSet() orelse return TechmapError.PinNotFound;
            }
            try pinmap.bindNet(dnet.net, dnet.dir, @intCast(candidate.?));
            input_pins_unused.unset(candidate.?);
        } else {
            // it's an output or inout, we can only use the output set.
            const candidate = pinmap.output_set.findFirstSet() orelse return TechmapError.PinNotFound;
            try pinmap.bindNet(dnet.net, dnet.dir, @intCast(candidate));
        }
    }
}
test mapPins {
    const alloc = testing.allocator;
    // This is all netlist setup
    const netlist = try yosys_netlist.getExampleNetlist(alloc);
    defer netlist.deinit();

    const pcf_path = "./testcases/olmc_test.pcf";
    const pcf_file = try std.fs.cwd().readFileAlloc(alloc, pcf_path, 8192);
    defer alloc.free(pcf_file);
    var constraints = pcf.PinConstraints.init(alloc);
    defer constraints.deinit();
    try constraints.parseSlice(pcf_file);

    var pa = try PinMap.init(alloc, chip.ChipType.gal16v8);
    defer pa.deinit();
    const top = netlist.value.findTopModule();
    try mapPins(alloc, &pa, top.ports, &constraints);
}

// pcf constrained outputs
// pcf bound inputs
// unconstrained outputs
// unconstrained inputs
// I guess for unconstrained, we just have to prefer non-outputs if available
// but if there's non left there's nothing we can do.
// clock? we don't want to assign the clock to a random net, but we do need to mark it somehow
// add new pcf file command
