//! Describes various Yosys cells that form a Verilog to GAL
//! mapping flow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const yosys = @import("./yosys_netlist.zig");
const BiMap = @import("./bimap.zig").BiMap;
const xv8 = @import("./gal_xV8.zig");
// Validation function that ensures that the netlist is using our techmap.
/// One of the invariants we assume about the gal netlist is invalid.
const ValidationError = error{
    UnknownCellType,
};

const validCellTypes = [_][]const u8{ "GAL_OLMC", "GAL_SOP", "GAL_INPUT" };

pub fn validate(netlist: *const yosys.Netlist) ValidationError!void {
    const top = netlist.findTopModule();

    // iterate through the cells, ensuring that each one is one of validCellTypes.

    const cells = top.cells.map.values();
    found: for (cells) |cell| {
        for (validCellTypes) |valid_cell| {
            if (std.mem.eql(u8, cell.type, valid_cell)) continue :found;
        }
        return ValidationError.UnknownCellType;
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

pub const NetlistOlmc = struct {
    ref: *yosys.Cell,
    src: ?*NetlistSop,
};

pub const NetlistInput = struct {
    ref: *yosys.Cell,
};

pub const NetlistSop = struct {
    ref: *yosys.Cell,
    dest: ?*NetlistOlmc,
};

pub const CellsList = struct {
    const Self = @This();
    allocator: Allocator,
    npm: yosys.NetPortMap,
    ncm: yosys.NetCellMap,
    olmcs: std.ArrayListUnmanaged(NetlistOlmc),
    sops: std.ArrayListUnmanaged(NetlistSop),
    inputs: std.ArrayListUnmanaged(NetlistInput),

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    ///
    pub fn populate(self: *Self, netlist: *const yosys.Netlist) !void {
        self.ncm = yosys.buildNetCellMap(self.allocator, netlist);
    }
};

/// Maps the nets to the pins.
/// Optionally takes a PCF constraint file to bind module's ports to
/// specific pins.
pub fn PinAssignment(comptime T: type) type {
    xv8.validatePinEnum(T);
    return struct {
        const Self = @This();
        const PinType = T;
        bimap: BiMap(yosys.Net, T),

        pub fn init(allocator: Allocator) Self {
            return .{
                .bimap = .init(allocator),
            };
        }
    };
}
