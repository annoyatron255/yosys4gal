//! Describes various Yosys cells that form a Verilog to GAL
//! mapping flow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const testing = std.testing;
const assert = std.debug.assert;

const yosys = @import("./yosys_netlist.zig");
const BiMap = @import("./bimap.zig").BiMap;
const xv8 = @import("./gal_xV8.zig");
const chip = @import("./chipinfo.zig");
const pcf = @import("./pcf.zig");
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

fn validate(netlist: *const yosys.Netlist) TechmapError!void {
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
    const example = "./testcases/synth_olmc_test.json";
    const file = try std.fs.cwd().readFileAlloc(alloc, example, 1024 * 8192);
    defer alloc.free(file);

    const netlist = try std.json.parseFromSlice(yosys.Netlist, alloc, file, .{
        .ignore_unknown_fields = true,
    });
    defer netlist.deinit();
    try validate(&netlist.value);
}

// all of these cells have a ref which points to their parent.
// methods reach into the cell to extract information

pub const OlmcCell = struct {
    ref: *yosys.Cell,
    src: ?*SopCell = null,
    oe_src: ?*SopCell = null,
};

pub const InputCell = struct {
    ref: *yosys.Cell,
};

pub const SopCell = struct {
    ref: *yosys.Cell,
};

pub const TechMap = struct {
    const Self = @This();
    allocator: Allocator,
    npm: yosys.NetPortMap,
    ncm: yosys.NetCellMap,
    olmcs: std.ArrayListUnmanaged(OlmcCell) = .empty,
    sops: std.ArrayListUnmanaged(SopCell) = .empty,
    inputs: std.ArrayListUnmanaged(InputCell) = .empty,

    pub fn init(allocator: Allocator, netlist: *const yosys.Netlist) !Self {
        const top = netlist.findTopModule();
        const ncm = try yosys.buildNetCellMap(allocator, top);
        const npm = try yosys.buildNetPortMap(allocator, top);
        var self = Self{
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
    const example = "./testcases/synth_olmc_test.json";
    const file = try std.fs.cwd().readFileAlloc(alloc, example, 1024 * 8192);
    defer alloc.free(file);
    const netlist = try std.json.parseFromSlice(yosys.Netlist, alloc, file, .{ .ignore_unknown_fields = true });
    defer netlist.deinit();
    var tm = try TechMap.init(alloc, &netlist.value);
    defer tm.deinit();
}

/// Maps the nets to the pins.
/// Optionally takes a PCF constraint file to bind module's ports to
/// specific pins.
pub const PinAssignment = struct {
    const Self = @This();
    /// Used for storing deferred items.
    const DeferredPort = struct {
        net: yosys.Net,
        dir: yosys.PortDirection,
    };
    allocator: Allocator,
    spec: chip.ChipType,
    bimap: BiMap(yosys.Net, chip.Pin),
    /// set of unassigned outputs.
    output_set: DynamicBitSetUnmanaged,
    /// set of unassigned any-pin (input or output)
    unused_set: DynamicBitSetUnmanaged,

    pub fn init(allocator: Allocator, spec: chip.ChipType) !Self {
        const info = spec.getSpec();
        return Self{
            .allocator = allocator,
            .bimap = .init(allocator),
            .spec = spec,
            .output_set = try info.makeOlmcPinSet(allocator),
            .unused_set = try info.makeValidPinSet(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.bimap.deinit();
        self.output_set.deinit(self.allocator);
        self.unused_set.deinit(self.allocator);
    }

    /// binds a net to a port. If the net is an output, it removes
    /// it from the
    fn bindPort(
        self: *Self,
        net: yosys.Net,
        dir: yosys.PortDirection,
        pin: u32,
    ) !void {
        assert(net == .N);
        // get the actual pin enum from the u32.
        const pin_enum = self.spec.getSpec().pinFromInt(pin) orelse return TechmapError.InvalidPin;
        // check bitsets (assert - caller should have picked a valid one)
        assert(self.unused_set.isSet(pin));
        // non-inputs must be on the output set.
        if (dir != .input) assert(self.output_set.isSet(pin));
        // insert into mapping
        assert(try self.bimap.insert(net, pin_enum));
        // clear bitsets
        self.unused_set.unset(pin);
        self.output_set.unset(pin);
    }

    /// bind the constraints from the pcf file, and then bind the remaining ports.
    fn bind(
        self: *Self,
        ports: std.json.ArrayHashMap(yosys.Port),
        constraints: *const pcf.PinConstraints,
    ) !void {
        // ports that we need to assign later, after we're done with the PCF.
        var deferred_nets = std.ArrayList(DeferredPort).init(self.allocator);
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
                    try self.bindPort(port.bits[0], dir, pin);
                } else {
                    try deferred_nets.append(.{ .dir = dir, .net = port.bits[0] });
                }
            } else {
                for (port.bits, 0..) |net, idx| {
                    // construct the port[index].
                    var buf: [100]u8 = undefined;
                    const fullname = try std.fmt.bufPrint(&buf, "{s}[{d}]", .{ port_name, idx });
                    if (constraints.get(fullname)) |pin| {
                        try self.bindPort(net, dir, pin);
                    } else {
                        try deferred_nets.append(.{ .dir = dir, .net = net });
                    }
                }
            }
        }
        // now clean up the deferred pins.
        // compute non-output pins:
        var input_pins_unused = try self.unused_set.clone(self.allocator);
        defer input_pins_unused.deinit(self.allocator);
        {
            var out_iter = self.output_set.iterator(.{});
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
                    candidate = self.unused_set.findFirstSet() orelse return TechmapError.PinNotFound;
                }
                try self.bindPort(dnet.net, dnet.dir, @intCast(candidate.?));
                input_pins_unused.unset(candidate.?);
            } else {
                // it's an output or inout, we can only use the output set.
                const candidate = self.output_set.findFirstSet() orelse return TechmapError.PinNotFound;
                try self.bindPort(dnet.net, dnet.dir, @intCast(candidate));
            }
        }
    }
};
test PinAssignment {
    const alloc = testing.allocator;
    // This is all netlist setup
    const example = "./testcases/synth_olmc_test.json";
    const file = try std.fs.cwd().readFileAlloc(alloc, example, 1024 * 8192);
    defer alloc.free(file);
    const netlist = try std.json.parseFromSlice(yosys.Netlist, alloc, file, .{ .ignore_unknown_fields = true });
    defer netlist.deinit();

    const pcf_path = "./testcases/olmc_test.pcf";
    const pcf_file = try std.fs.cwd().readFileAlloc(alloc, pcf_path, 8192 * 20);
    defer alloc.free(pcf_file);
    var constraints = pcf.PinConstraints.init(alloc);
    defer constraints.deinit();
    try constraints.parseSlice(pcf_file);

    var pa = try PinAssignment.init(alloc, chip.ChipType.gal16v8);
    defer pa.deinit();
    const top = netlist.value.findTopModule();
    try pa.bind(top.ports, &constraints);
    try pa.bimap.print();
}

// pcf constrained outputs
// pcf bound inputs
// unconstrained outputs
// unconstrained inputs
// I guess for unconstrained, we just have to prefer non-outputs if available
// but if there's non left there's nothing we can do.
// clock? we don't want to assign the clock to a random net, but we do need to mark it somehow
// add new pcf file command
