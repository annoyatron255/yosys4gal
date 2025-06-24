//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.

pub const yosys_netlist = @import("./yosys_netlist.zig");
pub const pcf = @import("./pcf.zig");
pub const jed = @import("./jed.zig");
pub const xv8 = @import("./gal_xV8.zig");
pub const bimap = @import("./util/bimap.zig");
pub const techmap = @import("./gal_techmap.zig");
pub const array2d = @import("./util/array2d.zig");
pub const info = @import("./chipinfo.zig");

test "main" {
    @import("std").testing.refAllDecls(@This());
}
test {
    _ = @import("regression_test.zig");
}
