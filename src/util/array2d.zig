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
/// TODO: don't hold allocator.
pub fn Array2D(comptime T: type) type {
    return struct {
        const DataArray = std.ArrayListUnmanaged(T);
        const Self = @This();
        /// Underlying data representation
        data: DataArray,
        /// current number of rows.
        rows: usize = 0,
        /// current number of columns
        cols: usize = 0,

        pub const init: Self = .{ .data = .empty };
        /// Create an array that is already allocated for the correct size, but doesn't have
        pub fn initSize(allocator: Allocator, rows: usize, cols: usize) !Self {
            var self = init;
            try self.resize(allocator, rows, cols);
            return self;
        }

        pub fn initFilled(allocator: Allocator, rows: usize, cols: usize, value: T) !Self {
            var self = try initSize(allocator, rows, cols);
            self.fill(value);
            return self;
        }

        /// Create a copy of this array using a new allocator.
        pub fn clone(self: Self, allocator: Allocator) !Self {

            // use the incoming allocator, since we want them to be able to manage it.
            const items_copy = try self.data.clone(allocator);
            return .{
                .data = items_copy,
                .rows = self.rows,
                .cols = self.cols,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.data.deinit(allocator);
        }

        pub fn resize(self: *Self, allocator: Allocator, rows: usize, cols: usize) !void {
            self.rows = rows;
            self.cols = cols;
            try self.data.resize(allocator, rows * cols);
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
    // init
    {
        var arr = IntArray.init;
        defer arr.deinit(alloc);

        try testing.expect(arr.rows == 0);
        try testing.expect(arr.cols == 0);
        try testing.expect(arr.data.items.len == 0);
    }
    // initsize
    {
        var arr = try IntArray.initSize(alloc, 3, 4);
        defer arr.deinit(alloc);

        try testing.expect(arr.rows == 3);
        try testing.expect(arr.cols == 4);
        try testing.expect(arr.data.items.len == 12);
    }
    // clone
    {
        var original = try IntArray.initFilled(alloc, 2, 2, 10);
        defer original.deinit(alloc);

        var cloned = try original.clone(alloc);
        defer cloned.deinit(alloc);

        try testing.expect(cloned.rows == original.rows);
        try testing.expect(cloned.cols == original.cols);
        try testing.expect(cloned.data.items.len == original.data.items.len);

        // Verify data is copied
        for (original.data.items, cloned.data.items) |orig, clone| {
            try testing.expect(orig == clone);
        }

        // Verify they are independent (modify original, clone should be unchanged)
        original.set(0, 0, 99);
        try testing.expect(original.get(0, 0) == 99);
        try testing.expect(cloned.get(0, 0) == 10);
    }
    // resize
    {
        var arr = IntArray.init;
        defer arr.deinit(alloc);

        // Initial resize
        try arr.resize(alloc, 2, 3);
        try testing.expect(arr.rows == 2);
        try testing.expect(arr.cols == 3);
        try testing.expect(arr.data.items.len == 6);

        // Resize to larger
        try arr.resize(alloc, 4, 5);
        try testing.expect(arr.rows == 4);
        try testing.expect(arr.cols == 5);
        try testing.expect(arr.data.items.len == 20);

        // Resize to smaller
        try arr.resize(alloc, 1, 2);
        try testing.expect(arr.rows == 1);
        try testing.expect(arr.cols == 2);
        try testing.expect(arr.data.items.len == 2);
    }
    // fill
    {
        var arr = try IntArray.initSize(alloc, 3, 3);
        defer arr.deinit(alloc);

        arr.fill(7);

        for (arr.data.items) |item| {
            try testing.expect(item == 7);
        }

        // Fill with different value
        arr.fill(-1);

        for (arr.data.items) |item| {
            try testing.expect(item == -1);
        }
    }
    // get/set
    {
        var arr = try IntArray.initSize(alloc, 3, 4);
        defer arr.deinit(alloc);

        // Set values at different positions
        arr.set(0, 0, 1);
        arr.set(0, 3, 2);
        arr.set(1, 1, 3);
        arr.set(2, 3, 4);

        // Get and verify values
        try testing.expect(arr.get(0, 0) == 1);
        try testing.expect(arr.get(0, 3) == 2);
        try testing.expect(arr.get(1, 1) == 3);
        try testing.expect(arr.get(2, 3) == 4);
    }
    // getptr
    {
        var arr = try IntArray.initFilled(alloc, 2, 2, 0);
        defer arr.deinit(alloc);

        // Modify through pointer
        const ptr = arr.getPtr(1, 1);
        ptr.* = 100;

        try testing.expect(arr.get(1, 1) == 100);

        // Verify other values unchanged
        try testing.expect(arr.get(0, 0) == 0);
        try testing.expect(arr.get(0, 1) == 0);
        try testing.expect(arr.get(1, 0) == 0);
    }
    // Test with bool
    {
        const BoolArray = Array2D(bool);
        var arr = try BoolArray.initFilled(alloc, 2, 2, true);
        defer arr.deinit(alloc);

        try testing.expect(arr.get(0, 0) == true);
        arr.set(1, 1, false);
        try testing.expect(arr.get(1, 1) == false);
    }
    // Test with f32
    {
        const FloatArray = Array2D(f32);
        var arr = try FloatArray.initSize(alloc, 2, 2);
        defer arr.deinit(alloc);

        arr.set(0, 0, 3.14);
        try testing.expect(arr.get(0, 0) == 3.14);
    }
}

test "Array2D - getSlice" {
    const alloc = testing.allocator;
    const IntArray = Array2D(i32);

    var arr = try IntArray.initSize(alloc, 3, 4);
    defer arr.deinit(alloc);

    // Fill with identifiable pattern
    for (0..arr.rows) |row| {
        for (0..arr.cols) |col| {
            arr.set(row, col, @intCast(row * 10 + col));
        }
    }

    // Test getting row slices (assuming row-major order)
    const row0 = arr.getSlice(0);
    try testing.expect(row0.len == 4);
    try testing.expect(row0[0] == 0);
    try testing.expect(row0[1] == 1);
    try testing.expect(row0[2] == 2);
    try testing.expect(row0[3] == 3);

    const row1 = arr.getSlice(1);
    try testing.expect(row1.len == 4);
    try testing.expect(row1[0] == 10);
    try testing.expect(row1[1] == 11);
    try testing.expect(row1[2] == 12);
    try testing.expect(row1[3] == 13);
}
