//! Describes various Yosys cells that form a Verilog to GAL
//! This file handles the techmap details from the yosys netlist.
//! Then it will map the cells into real hardware.
//! Constraints are built/applied here.

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
const Cell = yosys_netlist.Cell;
const Netlist = yosys_netlist.Netlist;
const PinMap = @import("./PinMap.zig");
const Array2D = @import("./util/array2d.zig").Array2D;
const builtin = @import("builtin");

const log = if (builtin.is_test)
    // Downgrade `err` to `warn` for tests.
    // Zig fails any test that does `log.err`, but we want to test those code paths here.
    struct {
        const base = std.log.scoped(.gal_techmap);
        const err = warn;
        const warn = base.warn;
        const info = base.info;
        const debug = base.debug;
    }
else
    std.log.scoped(.gal_techmap);

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

/// Helper function to convert TABLE characters to booleans.
fn ctobool(char: u8) bool {
    return switch (char) {
        '0' => false,
        '1' => true,
        else => std.debug.panic("unexpected character {c}", .{char}),
    };
}

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

/// all of these cells have a ref which points to their parent.
/// methods reach into the cell to extract information
pub const OlmcCell = struct {
    /// the ports that a sop should be on
    const SopPort = enum { A, E };
    ref: *Cell,

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
        if (tm.ncm.getFiltered(input, yosys_netlist.filters.netDriver)) |driver| {
            return SopCell.init(driver.cell);
        }

        return null;
    }

    /// Returns the output pin for this olmc by using the pin map
    pub fn getOutputPin(self: OlmcCell, tm: *TechMap) chip.Pin {
        // get the output net
        const output_net = self.ref.connections.map.get("Y").?[0];
        return tm.pinmap.net_lookup(output_net).?;
    }

    pub fn registered(self: OlmcCell) bool {
        return self.ref.getProp(u8, .param, "REGISTERED").? > 0;
    }

    pub fn inverted(self: OlmcCell) bool {
        return self.ref.getProp(u8, .param, "INVERTED").? > 0;
    }

    pub fn format(self: *const OlmcCell, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const reg = self.registered();
        const inv = self.inverted();
        const output_net = self.ref.connections.map.get("Y").?[0];

        return writer.print("OLMC(inv={}, reg={}, out_net={})", .{ inv, reg, output_net });
    }
};

pub const OlmcCell2 = struct {
    ref: *Cell,
    name: *[]const u8,
    io_net: Net,
    tristate: Net,
    input: *Cell,
    inverted: bool,
    registered: bool,

    pub fn init(cell: *Cell, name: *[]const u8) OlmcCell2 {
        assert(GALCell.fromString(cell.type).? == .Olmc);

        const inputs = cell.connections.map.get("A").?;
        assert(inputs.len == 1);
        const tristate = blk: {
            const nets = cell.connections.map.get("E").?;
            assert(nets.len == 1);
            break :blk nets[0];
        };
        const registered = cell.getProp(u8, .param, "REGISTERED").? > 0;
        const inverted = cell.getProp(u8, .param, "INVERTED").? > 0;

        const io_net = cell.connections.map.get("Y").?[0];

        return .{
            .ref = cell,
            .name = name,
            .io_net = io_net,
            .tristate = tristate,
            .input = inputs[0],
            .inverted = inverted,
            .registered = registered,
        };
    }
};

/// find the chip pin that drives this net. traversing GAL_INPUT.
fn getSopInputPin(input: Net, tm: *TechMap) chip.Pin {
    if (tm.pinmap.net_lookup(input)) |pin| {
        return pin;
    } else {
        // This happens when a SOP input net goes through a GAL_INPUT cell.
        if (tm.ncm.getFiltered(input, yosys_netlist.filters.netDriver)) |driver| {
            const backtrack = driver.cell.connections.map.get("A").?[0];
            return tm.pinmap.net_lookup(backtrack).?;
        }
        std.debug.panic("Could not find pin on Net {any}", .{input});
    }
}

pub const SopCell = struct {
    ref: *const Cell,
    /// Convert this SOP and place it on the given array2d.
    pub fn toArray(self: SopCell, tm: *TechMap, out: *gal.SopTerm) !void {
        // extract the params.
        // depth aka number of products
        const d = self.depth();
        // width
        const w = self.width();
        // table is []const u8 still - could be huge.
        const table = self.ref.getProp([]const u8, .param, "TABLE").?;
        const inputs = self.ref.connections.map.get("A").?;
        assert(d <= out.rows);
        assert(w <= @divExact(out.cols, 2));
        // set the entire row to 1 first - then clear bits.
        for (0..d) |row| {
            for (0..out.cols) |i| {
                out.set(row, i, true);
            }
        }

        // look at each input, map to net, then pin.
        // based on the pin compute the column we need to edit.
        // then go through each product term with that input,
        // and set the rows based on table
        for (inputs, 0..) |input_net, idx| {
            // find the pin that this net is on.
            const pin = getSopInputPin(input_net, tm);
            // now use that pin to get the column of this net.
            const col = tm.chip_type.getSpec().getPinCol(pin);
            // compute the table.
            for (0..d) |row| {
                // the table is actually backwards from how we expect it.
                const reverse_idx = inputs.len - 1 - idx;
                // width * row -> put us in the correct product
                // idx * 2 - select inside the product
                const pos = (w * row * 2 + reverse_idx * 2);

                out.set(row, col, !ctobool(table[pos]));
                out.set(row, col + 1, !ctobool(table[pos + 1]));
            }
        }
    }

    pub fn width(self: SopCell) u32 {
        return self.ref.getProp(u32, .param, "WIDTH").?;
    }

    pub fn depth(self: SopCell) u32 {
        return self.ref.getProp(u32, .param, "DEPTH").?;
    }

    /// Create a SopCell from a given Cell. When in ReleaseSafe or Debug,
    /// will perform validation of the cell.
    pub fn init(cell: *const Cell) SopCell {
        const d = cell.getProp(u32, .param, "DEPTH");
        const w = cell.getProp(u32, .param, "WIDTH");
        const table = cell.getProp([]const u8, .param, "TABLE");
        const inputs = cell.connections.map.get("A");
        // FIXME: replace with errors
        assert(d != null);
        assert(w != null);
        assert(table != null);
        assert(inputs != null);
        assert(w.? == inputs.?.len);
        assert(table.?.len == w.? * d.? * 2);
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
                .Olmc => {
                    const olmc: OlmcCell = .{ .ref = cell };
                    try self.olmcs.append(self.allocator, olmc);
                },
                else => {},
            }
        }
    }

    /// Apply PCF constraints and then fit the remaining ports onto the chip based on
    /// sizing rules.
    pub fn applyConstraints(self: *TechMap, constraints: *const pcf.PinConstraints) !void {
        const spec = self.chip_type.getSpec();
        const top = self.netlist.findTopModule();
        // save for later, assign based on sizing.
        var deferred = std.ArrayList(DeferredPort).empty;
        defer deferred.deinit(self.allocator);

        var ports = top.ports.map.iterator();

        while (ports.next()) |entry| {
            const name = entry.key_ptr;
            const port = entry.value_ptr;
            if (constraints.clk_net) |clk| {
                if (std.mem.eql(u8, clk, name.*)) {
                    log.info("skipping clock {s}", .{clk});
                    continue;
                }
            }
            assert(port.bits.len > 0);
            for (port.bits, 0..) |net, idx| {
                var buf: [100]u8 = undefined;
                const port_name = if (port.bits.len == 1)
                    name.*
                else
                    try std.fmt.bufPrint(&buf, "{s}[{d}]", .{ name.*, idx });
                // if this port is constrained, try to assign it.
                // otherwise it will get picked up later by the OLMC pass.
                if (constraints.get(port_name)) |pin| {
                    if (spec.pinFromInt(pin)) |p| {
                        log.debug("binding port {s} to pin {d}", .{ port_name, pin });
                        try self.pinmap.bind(net, port.direction, p);
                    } else {
                        log.warn("Port {s} constrained to invalid pin {d}", .{ port_name, pin });
                    }
                } else if (port.direction == .input) {
                    // any port that's unconstrained is added to the deferred list
                    // but only if it's an input.
                    // output/inout will be picked up by OLMC pass below.
                    try deferred.append(self.allocator, .{ .net = net, .dir = .input, .size = 0 });
                }
            }
        }

        // look for any remaining OLMCs that haven't been constrained.
        // this will also find OLMCs that are on a port but not constrained
        for (self.olmcs.items) |olmc| {
            // get the output net, check for lack of pin, and then add it to the deferred list.
            const output_net = olmc.ref.connections.map.get("Y").?[0];
            if (self.pinmap.net_lookup(output_net) == null) {
                const size = if (olmc.getSopCell(.A, self)) |sop| sop.depth() else 0;
                try deferred.append(self.allocator, .{ .net = output_net, .dir = .inout, .size = size });
            }
        }
        // deduplicate the port list.

        for (deferred.items) |dnet| {
            const candidate = if (dnet.dir == .inout or dnet.dir == .output)
                self.pinmap.output_candidate(dnet.size)
            else
                self.pinmap.input_candidate();
            if (candidate == null) {
                log.err("unable to find candidate for {any} ({s})", .{ dnet.net, @tagName(dnet.dir) });
                return TechmapError.PinNotFound;
            }

            log.debug("deferred placement of {any} ({s}) to pin {d}", .{ dnet.net, @tagName(dnet.dir), candidate.? });

            try self.pinmap.bind(dnet.net, dnet.dir, candidate.?);
        }
    }

    pub fn mapChip(self: *TechMap) !gal.GAL {
        var gal_instance = try gal.GAL.init(self.allocator, self.chip_type);
        for (self.olmcs.items) |olmc_cell| {
            const pin = olmc_cell.getOutputPin(self);
            // using the pin, get the olmc index
            const olmc_idx = self.chip_type.getSpec().getOlmcIdx(pin).?;
            // using this, get the sop from the GAL representation
            const sop_array = try gal_instance.getOrMakeSop(olmc_idx, !olmc_cell.registered());
            const sop_cell = olmc_cell.getSopCell(.A, self).?;
            try sop_cell.toArray(self, sop_array);
            // use this olmc to map to the chip olmc
            gal_instance.olmcs[olmc_idx].comb = !olmc_cell.registered();
            gal_instance.olmcs[olmc_idx].active_high = !olmc_cell.inverted();
            // finally check for tristate
            if (olmc_cell.getSopCell(.E, self)) |oe_sop| {
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
        self.pinmap.deinit(self.allocator);
    }

    /// Maps the nets to the pins.
    /// Optionally takes a PCF constraint file to bind module's ports to
    /// specific pins.
    const DeferredPort = struct { net: Net, dir: yosys_netlist.PortDirection, size: usize };
};

test TechMap {
    const alloc = testing.allocator;
    // This is all netlist setup
    const netlist = try yosys_netlist.getExampleNetlist(alloc);
    defer netlist.deinit();
    var tm = try TechMap.init(alloc, chip.ChipType.gal16v8, &netlist.value);
    defer tm.deinit();
    var constraints = pcf.PinConstraints.init(alloc);
    defer constraints.deinit();
    try tm.applyConstraints(&constraints);
}
