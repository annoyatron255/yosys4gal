//! Simple bidirectional map. We make the following asserts:
//! For types A and B, which may be identical (A=B),
//! - there may be at most one pair between A-B
//! - Lookups are driven by their "side", i.e you have to choose which part of
//!     the pair you're using.
//! - an attempt to insert a new pair will fail if either the A or B value already exist.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

/// Creates a bidirectional map.
pub fn BiMap(comptime A: type, comptime B: type) type {
    return struct {
        const Self = @This();
        const FwdMap = blk: {
            // strings use the stringhashmap
            if (A == []const u8) {
                break :blk std.StringHashMapUnmanaged(B);
            } else {
                break :blk std.AutoHashMapUnmanaged(A, B);
            }
        };
        const RevMap = blk: {
            if (B == []const u8) {
                break :blk std.StringHashMapUnmanaged(A);
            } else {
                break :blk std.AutoHashMapUnmanaged(B, A);
            }
        };

        forward: FwdMap = .empty,
        reverse: RevMap = .empty,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.forward.deinit(self.allocator);
            self.reverse.deinit(self.allocator);
        }

        /// Attempt to insert a new pair. If either key already exists,
        /// it will return false. It will return true if the insertion
        /// was successful.
        pub fn insert(self: *Self, a: A, b: B) Allocator.Error!bool {
            // we can't use getorput here because
            // we may *not* put if the other hashmap has a key
            if (self.forward.contains(a) or self.reverse.contains(b)) {
                return false;
            }
            // clobber
            try self.put(a, b);
            return true;
        }

        /// Add a new pair, clobbering whatever was there.
        pub fn put(self: *Self, a: A, b: B) Allocator.Error!void {
            try self.forward.put(self.allocator, a, b);
            try self.reverse.put(self.allocator, b, a);
        }

        /// Removes a pair given a value of the A type.
        pub fn removeA(self: *Self, a: A) void {
            if (self.forward.contains(a)) {
                const b = self.forward.get(a) orelse unreachable;
                const rm_a = self.forward.remove(a);
                assert(rm_a);
                const rm_b = self.reverse.remove(b);
                assert(rm_b);
            }
        }
        pub fn removeB(self: *Self, b: B) void {
            if (self.reverse.contains(b)) {
                const a = self.reverse.get(b) orelse unreachable;
                const rm_a = self.forward.remove(a);
                assert(rm_a);
                const rm_b = self.reverse.remove(b);
                assert(rm_b);
            }
        }

        pub fn getA(self: Self, a: A) ?B {
            return self.forward.get(a);
        }

        pub fn getB(self: Self, b: B) ?A {
            return self.reverse.get(b);
        }

        pub fn containsA(self: Self, a: A) bool {
            return self.forward.contains(a);
        }
        pub fn containsB(self: Self, b: B) bool {
            return self.reverse.contains(b);
        }

        pub fn print(self: Self) !void {
            std.debug.print("{s} | {s}\n", .{ @typeName(A), @typeName(B) });
            var iter = self.forward.iterator();
            while (iter.next()) |entry| {
                const a_val: A = entry.key_ptr.*;
                const b_val: B = entry.value_ptr.*;
                std.debug.print("{any} <=> {any}\n", .{ a_val, b_val });
            }
        }
    };
}

test "BiMap with distinct types (string to int)" {
    const allocator = testing.allocator;

    var bimap = BiMap([]const u8, i32).init(allocator);
    defer bimap.deinit();

    // Test insertion
    try testing.expect(try bimap.insert("hello", 42));
    try testing.expect(try bimap.insert("world", 100));

    // Test duplicate insertion fails
    try testing.expect(!try bimap.insert("hello", 50)); // A already exists
    try testing.expect(!try bimap.insert("test", 42)); // B already exists
    try testing.expect(!try bimap.insert("hello", 42)); // Both exist

    // Test forward lookups
    try testing.expectEqual(42, bimap.getA("hello"));
    try testing.expectEqual(100, bimap.getA("world"));
    try testing.expectEqual(null, bimap.getA("nonexistent"));

    // Test reverse lookups
    try testing.expectEqualStrings("hello", bimap.getB(42).?);
    try testing.expectEqualStrings("world", bimap.getB(100).?);
    try testing.expectEqual(null, bimap.getB(999));

    // Test contains
    try testing.expect(bimap.containsA("hello"));
    try testing.expect(bimap.containsB(42));
    try testing.expect(!bimap.containsA("missing"));
    try testing.expect(!bimap.containsB(999));

    // Test removal by A
    bimap.removeA("hello");
    try testing.expect(!bimap.containsA("hello"));
    try testing.expect(!bimap.containsB(42));
    try testing.expectEqual(null, bimap.getA("hello"));
    try testing.expectEqual(null, bimap.getB(42));

    // Test removal by B
    bimap.removeB(100);
    try testing.expect(!bimap.containsA("world"));
    try testing.expect(!bimap.containsB(100));
}
test "BiMap with same types (int to int)" {
    const allocator = testing.allocator;

    var bimap = BiMap(i32, i32).init(allocator);
    defer bimap.deinit();

    // Test insertion with same types
    try testing.expect(try bimap.insert(1, 10));
    try testing.expect(try bimap.insert(2, 20));
    try testing.expect(try bimap.insert(3, 30));

    // Test that we can't insert if either side exists
    try testing.expect(!try bimap.insert(1, 40)); // A=1 already exists
    try testing.expect(!try bimap.insert(4, 10)); // B=10 already exists
    try testing.expect(!try bimap.insert(2, 20)); // Both exist

    // Test bidirectional lookups
    try testing.expectEqual(10, bimap.getA(1));
    try testing.expectEqual(1, bimap.getB(10));
    try testing.expectEqual(20, bimap.getA(2));
    try testing.expectEqual(2, bimap.getB(20));

    // Test edge case: same value on both sides (should work)
    try testing.expect(try bimap.insert(5, 5));
    try testing.expectEqual(5, bimap.getA(5));
    try testing.expectEqual(5, bimap.getB(5));

    // After inserting (5,5), we can't insert anything with 5 on either side
    try testing.expect(!try bimap.insert(5, 6));
    try testing.expect(!try bimap.insert(6, 5));

    // Test removal
    bimap.removeA(1);
    try testing.expect(!bimap.containsA(1));
    try testing.expect(!bimap.containsB(10));

    bimap.removeB(20);
    try testing.expect(!bimap.containsA(2));
    try testing.expect(!bimap.containsB(20));
}
