//! Describes various Yosys cells that form a Verilog to GAL
//! This portion of the code takes a netlist and binds it to the xv8 gal
//! specification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const testing = std.testing;
const assert = std.debug.assert;
const chip = @import("./chipinfo.zig");
const gal = @import("./gal_core.zig");
const pcf = @import("./pcf.zig");
const yosys_netlist = @import("./yosys_netlist.zig");

const Net = yosys_netlist.Net;
const Netlist = yosys_netlist.Netlist;
const PinMap = @import("./pin_mapping.zig").PinMap;
const Array2D = @import("./util/array2d.zig").Array2D;
const BiMap = @import("./util/bimap.zig").BiMap;
const builtin = @import("builtin");

const log = if (builtin.is_test)
    // Downgrade `err` to `warn` for tests.
    // Zig fails any test that does `log.err`, but we want to test those code paths here.
    struct {
        const base = std.log.scoped(.techmap_gal);
        const err = warn;
        const warn = base.warn;
        const info = base.info;
        const debug = base.debug;
    }
else
    std.log.scoped(.techmap_gal);

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

const GALCell = enum {
    Olmc,
    Sop,
    Input,
    pub const strings = blk: {
        const fields = std.meta.fields(GALCell);
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
    pub fn toString(self: GALCell) []const u8 {
        return strings[@intFromEnum(self)];
    }
    pub fn fromString(s: []const u8) ?GALCell {
        inline for (strings, 0..) |name, idx| {
            if (std.mem.eql(u8, s, name)) {
                return @enumFromInt(idx);
            }
        }
        // custom override for 1SOP
        if (std.mem.eql(u8, s, "GAL_1SOP")) {
            return .Sop;
        }
        return null;
    }
};

fn validate(netlist: *const Netlist) TechmapError!void {
    const top = netlist.findTopModule();

    // iterate through the cells, ensuring that each one is one of validCellTypes.

    const cells = top.cells.map.values();
    for (cells) |cell| {
        if (GALCell.fromString(cell.type) == null)
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
    // FIXME: use this.
    const SopPort = enum { A, E };
    ref: *yosys_netlist.Cell,

    /// Returns the sop cell on the port, which is one of A or E
    pub fn getSopCell(self: OlmcCell, port: SopPort, tm: *TechMap) ?SopCell {
        var input: Net = undefined;
        {
            const inputs = self.ref.connections.map.get(@tagName(port)).?;
            assert(inputs.len == 1);
            input = inputs[0];
        }
        if (input != .N) return null;
        // search through the ncm to find the driver net. assert that it's a valid SOP.
        const cells_on_net = tm.ncm.lookup.get(input.N).?.items;

        for (cells_on_net) |cell| {
            if (cell.direction == .output) {
                assert(std.mem.eql(u8, cell.port, "Y"));
                // found one - assert that it's a sop.
                return SopCell.init(cell.cell);
            }
        }
        return null;
    }

    /// Returns the output pin for this olmc by using the pin map
    pub fn getOutputPin(self: OlmcCell, tm: *TechMap) chip.Pin {
        // get the output net
        const output_net = self.ref.connections.map.get("Y").?[0];
        return tm.pinmap.bimap.getA(output_net).?;
    }

    pub fn registered(self: OlmcCell) bool {
        return self.ref.getProp(u8, .param, "REGISTERED").? > 0;
    }
    pub fn inverted(self: OlmcCell) bool {
        return self.ref.getProp(u8, .param, "INVERTED").? > 0;
    }
    pub fn format(self: *const OlmcCell, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) {
            std.fmt.invalidFmtError(fmt, self);
        }
        const reg = self.registered();
        const inv = self.inverted();
        const output_net = self.ref.connections.map.get("Y").?[0];

        return writer.print("OLMC(inv={}, reg={}, out_net={})", .{ inv, reg, output_net });
    }
};

pub const InputCell = struct {
    ref: *const yosys_netlist.Cell,
};
fn ctobool(char: u8) bool {
    return switch (char) {
        '0' => false,
        '1' => true,
        else => unreachable,
    };
}

fn getSopInputPin(input: Net, tm: *TechMap) chip.Pin {
    if (tm.pinmap.bimap.getA(input)) |pin| {
        return pin;
    } else {
        // This happens when a SOP input net goes through a GAL_INPUT cell.
        const pin: chip.Pin = blk: {
            for (tm.ncm.lookup.get(input.N).?.items) |netcell| {
                if (netcell.direction == .output or netcell.direction == .inout) {
                    assert(std.mem.eql(u8, netcell.port, "Y"));
                    assert(GALCell.fromString(netcell.cell.type).? == .Input);
                    // find the pin on the A side...
                    const inp_cell_A = netcell.cell.connections.map.get("A").?[0];
                    break :blk tm.pinmap.bimap.getA(inp_cell_A).?;
                }
            }
            @panic("Could not find Pin on Net");
        };
        return pin;
    }
}
pub const SopCell = struct {
    ref: *const yosys_netlist.Cell,
    /// Convert this SOP and place it on the given array2d.
    pub fn toArray(self: SopCell, tm: *TechMap, out: *gal.SopTerm) !void {
        // extract the params.
        // depth aka number of products
        const depth = self.ref.getProp(u32, .param, "DEPTH").?;
        // width
        const width = self.ref.getProp(u32, .param, "WIDTH").?;
        // table is []const u8 still - could be huge.
        const table = self.ref.getProp([]const u8, .param, "TABLE").?;
        const inputs = self.ref.connections.map.get("A").?;
        assert(depth <= out.rows);
        assert(width <= out.cols / 2);
        // set the entire row to 1 first - then clear bits.
        for (0..depth) |row| {
            for (0..out.cols) |i| {
                out.set(row, i, true);
            }
        }

        // look at each input, map to net, then pin.
        // based on the pin compute the column we need to edit.
        // then go through each product term with that input,
        // and set the rows based on table
        for (inputs, 0..) |input, idx| {
            const pin = getSopInputPin(input, tm);
            const col = tm.chip_type.getSpec().getPinCol(pin);
            // compute the table.
            for (0..depth) |row| {
                // the table is actually backwards from how we expect it.
                const reverse_idx = inputs.len - 1 - idx;
                // width * row -> put us in the correct product
                // idx * 2 - select inside the product
                const pos = (width * row * 2 + reverse_idx * 2);

                out.set(row, col, !ctobool(table[pos]));
                out.set(row, col + 1, !ctobool(table[pos + 1]));
            }
        }
    }
    /// Create a SopCell from a given Cell. When in ReleaseSafe or Debug,
    /// will perform validation of the cell.
    pub fn init(cell: *const yosys_netlist.Cell) SopCell {
        const depth = cell.getProp(u32, .param, "DEPTH");
        const width = cell.getProp(u32, .param, "WIDTH");
        const table = cell.getProp([]const u8, .param, "TABLE");
        const inputs = cell.connections.map.get("A");
        // FIXME: replace with errors
        assert(depth != null);
        assert(width != null);
        assert(table != null);
        assert(inputs != null);
        assert(width.? == inputs.?.len);
        assert(table.?.len == width.? * depth.? * 2);
        const output = cell.connections.map.get("Y");
        assert(output != null);
        assert(output.?.len == 1);
        return SopCell{ .ref = cell };
    }
};

/// GAL chip mapping state
pub const TechMap = struct {
    allocator: Allocator,
    npm: yosys_netlist.NetPortMap,
    ncm: yosys_netlist.NetCellMap,
    chip_type: chip.ChipType,
    olmcs: std.ArrayListUnmanaged(OlmcCell) = .empty,
    sops: std.ArrayListUnmanaged(SopCell) = .empty,
    inputs: std.ArrayListUnmanaged(InputCell) = .empty,
    netlist: *const Netlist,
    pinmap: PinMap,

    pub fn init(
        allocator: Allocator,
        chip_type: chip.ChipType,
        netlist: *const Netlist,
    ) !TechMap {
        const top = netlist.findTopModule();
        var ncm = try yosys_netlist.buildNetCellMap(allocator, top);
        errdefer ncm.deinit();
        var npm = try yosys_netlist.buildNetPortMap(allocator, top);
        errdefer npm.deinit();

        const pm = try PinMap.init(allocator, chip_type);
        var self = TechMap{
            .chip_type = chip_type,
            .netlist = netlist,
            .npm = npm,
            .ncm = ncm,
            .allocator = allocator,
            .pinmap = pm,
        };
        errdefer self.deinit();
        // iterate through the cells. for each cell, determine the type.
        // now loop through OLMCs and find their parent if it exists.
        try self.populateArrays();

        return self;
    }
    /// internal function to split up the scope.
    fn populateArrays(self: *TechMap) !void {
        const top = self.netlist.findTopModule();
        var cells = top.cells.map.iterator();

        while (cells.next()) |entry| {
            const cell_name = entry.key_ptr;
            const cell = entry.value_ptr;

            log.debug("processing cell {s}", .{cell_name.*});

            const ctype = GALCell.fromString(cell.type) orelse return TechmapError.UnknownCellType;

            switch (ctype) {
                .Input => {
                    const input: InputCell = .{ .ref = cell };
                    try self.inputs.append(self.allocator, input);
                },
                .Sop => {
                    const sop: SopCell = .{ .ref = cell };
                    try self.sops.append(self.allocator, sop);
                },
                .Olmc => {
                    const olmc: OlmcCell = .{ .ref = cell };
                    try self.olmcs.append(self.allocator, olmc);
                },
            }
        }
    }

    /// Bind the OLMCs to pins using a pinmap
    pub fn applyConstraints(self: *TechMap, constraints: pcf.PinConstraints) !void {
        const top = self.netlist.findTopModule();
        try bindPorts(self.allocator, self.chip_type, &self.pinmap, top.ports, constraints);
        // look for any remaining OLMCs that are not on a port.
        for (self.olmcs.items) |olmc| {
            // get the output net, check for lack of pin, map.
            const output_net = olmc.ref.connections.map.get("Y").?[0];
            if (self.pinmap.bimap.getA(output_net) == null) {
                const candidate = self.pinmap.candidate(.output) orelse return TechmapError.PinNotFound;
                try self.pinmap.bindNet(output_net, .inout, @intCast(candidate));
            }
        }
    }
    pub fn mapChip(self: *TechMap) !gal.GAL {
        var gal_instance = try gal.GAL.init(self.allocator, self.chip_type);
        for (self.olmcs.items) |olmc| {
            log.debug("OLMC = {any}", .{olmc});
            const pin = olmc.getOutputPin(self);
            log.info("pin is {any}", .{pin});
            // using the pin, get the olmc index
            const olmc_idx = self.chip_type.getSpec().getOlmcIdx(pin).?;
            log.debug("index is {d}", .{olmc_idx});
            // using this, get the sop from the GAL representation
            const sop_array = try gal_instance.getOrMakeSop(olmc_idx, !olmc.registered());
            const sop_cell = olmc.getSopCell(.A, self).?;
            try sop_cell.toArray(self, sop_array);
            // use this olmc to map to the chip olmc
            gal_instance.olmcs[olmc_idx].comb = !olmc.registered();
            gal_instance.olmcs[olmc_idx].active_high = !olmc.inverted();
            // finally check for tristate
            if (olmc.getSopCell(.E, self)) |oe_sop| {
                const oe_array = try gal_instance.getOETerm(olmc_idx);

                try oe_sop.toArray(self, oe_array);
            }
        }
        return gal_instance;
    }

    pub fn deinit(self: *TechMap) void {
        self.npm.deinit();
        self.ncm.deinit();
        self.olmcs.deinit(self.allocator);
        self.sops.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.pinmap.deinit();
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
    net: Net,
    dir: yosys_netlist.PortDirection,
};

fn bindSinglePort(
    port_name: []const u8,
    dir: yosys_netlist.PortDirection,
    net: yosys_netlist.Net,
    chip_type: chip.ChipType,
    deferred_ports: *std.ArrayList(DeferredPort),
    constraints: pcf.PinConstraints,
    pinmap: *PinMap,
) !void {
    if (constraints.get(port_name)) |pin| {
        if (chip_type.getSpec().pinFromInt(pin) != null) {
            try pinmap.bindNet(net, dir, pin);
        } else {
            log.warn("Port {s} constrained to invalid pin {d}", .{
                port_name,
                pin,
            });
        }
    } else {
        try deferred_ports.append(.{ .dir = dir, .net = net });
    }
}

/// bind the ports from the pcf file, and then bind the remaining ports.
/// NOTE: this does not handle the raw OLMCs that are only used internally.
/// Those are handled in applyConstraints as part of the pcf.
fn bindPorts(
    allocator: Allocator,
    chip_type: chip.ChipType,
    pinmap: *PinMap,
    ports: std.json.ArrayHashMap(yosys_netlist.Port),
    constraints: pcf.PinConstraints,
) !void {
    //TODO: make this public/common? I feel like this logic is pretty universal.
    // ports that we need to assign later, after we're done with the PCF.
    var deferred_ports = std.ArrayList(DeferredPort).init(allocator);
    defer deferred_ports.deinit();
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
            // single bit port, handle it directly.
            try bindSinglePort(
                port_name.*,
                dir,
                port.bits[0],
                chip_type,
                &deferred_ports,
                constraints,
                pinmap,
            );
        } else {
            // multi-bit port - split it up here
            for (port.bits, 0..) |net, idx| {
                // construct the port[index].
                var buf: [100]u8 = undefined;
                const fullname = try std.fmt.bufPrint(&buf, "{s}[{d}]", .{ port_name, idx });
                try bindSinglePort(
                    fullname,
                    dir,
                    net,
                    chip_type,
                    &deferred_ports,
                    constraints,
                    pinmap,
                );
            }
        }
    }

    for (deferred_ports.items) |dnet| {
        const candidate = pinmap.candidate(dnet.dir) orelse return TechmapError.PinNotFound;
        try pinmap.bindNet(dnet.net, dnet.dir, @intCast(candidate));
    }
}
test bindPorts {
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

    var pa = try PinMap.init(alloc, .gal16v8);
    defer pa.deinit();
    const top = netlist.value.findTopModule();
    try bindPorts(alloc, .gal16v8, &pa, top.ports, constraints);
}
