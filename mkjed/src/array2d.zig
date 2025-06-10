//! Simple 2D array with fixed but runtime-dynamic size.
//! Backed by a single array list with indexing options.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The ordering for the indexing of the array.
/// TODO: do we care about this?
pub const Order = enum { row, column };

/// A dynamically sized 2D array.
/// TODO: make bools more memory efficient.
pub fn Array2D(comptime T: type) type {
    return struct {
        const DataArray = std.ArrayListUnmanaged(T);
        const Self = @This();
        allocator: Allocator,
        /// Underlying data representation
        data: DataArray,
        /// current number of rows.
        rows: usize = 0,
        /// current number of columns
        cols: usize = 0,

        /// Create an empty, unsized matrix.
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .data = .empty,
            };
        }
        /// Create an array that is already allocated for the correct size, but doesn't have
        pub fn initSize(allocator: Allocator, rows: usize, cols: usize) !Self {
            var self = init(allocator);
            try self.resize(rows, cols);
            return self;
        }

        pub fn initFilled(allocator: Allocator, rows: usize, cols: usize, value: T) !Self {
            var self = try initSize(allocator, rows, cols);
            try self.fill(value);
            return self;
        }

        /// Create a copy of this array using a new allocator.
        pub fn clone(self: Self, allocator: Allocator) !Self {

            // use the incoming allocator, since we want them to be able to manage it.
            const items_copy = try self.data.clone(allocator);
            return .{
                .allocator = allocator,
                .data = items_copy,
                .rows = self.rows,
                .cols = self.cols,
            };
        }

        pub fn deinit(self: *Self) void {
            self.data.deinit(self.allocator);
        }

        pub fn resize(self: *Self, rows: usize, cols: usize) !void {
            self.rows = rows;
            self.cols = cols;
            try self.data.resize(self.allocator, rows * cols);
        }

        pub fn fill(self: *Self, value: T) void {
            @memset(self.data.items, value);
        }

        /// gets a value from the matrix
        pub fn get(self: *Self, row: usize, col: usize) T {
            return self.data.items[row * self.cols + col];
        }

        /// Gets a mutable value from the matrix.
        pub fn getPtr(self: *Self, row: usize, col: usize) *T {
            return &self.data.items[row * self.cols + col];
        }
        /// return a contiguous slice of the matrix based on the backing order.
        /// if row-major, returns a row. if column major, returns a column.
        pub fn getSlice(self: *Self, axis: usize) []T {
            const start = axis * self.cols;
            const end = (axis + 1) * self.cols;
            return self.data.items[start..end];
        }

        pub fn set(self: *Self, row: usize, col: usize, val: T) void {
            const ptr = self.getPtr(row, col);
            ptr.* = val;
        }
    };
}

test Array2D {
    const alloc = testing.allocator;

    const IntArray = Array2D(i32);
    const BoolArray = Array2D(bool);

    {
        var arr = IntArray.init(alloc);
        defer arr.deinit();
    }
    {
        var arr = BoolArray.init(alloc);
        defer arr.deinit();
    }
}
