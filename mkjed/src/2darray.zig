//! Simple 2D array with fixed but runtime-dynamic size.
//! Backed by a single array list with indexing options.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The ordering for the indexing of the array.
pub const Order = enum { row, column };


/// A dynamically sized 2D array.
pub fn Array2D(comptime T: type, order: Order) type {

}
