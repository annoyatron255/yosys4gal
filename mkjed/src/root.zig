//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

pub const yosys_netlist = @import("./yosys_netlist.zig");
pub const pcf = @import("./pcf.zig");
pub const jed = @import("./jed.zig");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

test "main" {
    @import("std").testing.refAllDecls(@This());
}
