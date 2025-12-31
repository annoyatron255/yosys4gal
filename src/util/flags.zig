const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Format and print an error message to stderr, then exit with an exit code of 1.
fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    stderr.print("error: " ++ fmt_string ++ "\n", args) catch {};
    stderr.flush() catch unreachable;
    std.process.exit(1);
}

/// Updated parse function that accepts any iterator with a `next() ?[:0]const u8` method.
pub fn parse(comptime T: type, args_it: anytype) !T {
    // Skip executable name
    assert(args_it.next() != null);

    const sub_name = args_it.next() orelse {
        if (@hasDecl(T, "help")) std.debug.print("{s}\n", .{T.help});
        return error.UnknownSubcommand;
    };

    inline for (std.meta.fields(T)) |subfield| {
        if (std.mem.eql(u8, subfield.name, sub_name)) {
            const SubT = subfield.type;
            if (@typeInfo(SubT) != .@"struct") {
                @compileError("all subcommands must be structs");
            }
            // this command matches.
            var counts: std.enums.EnumFieldStruct(std.meta.FieldEnum(SubT), u32, 0) = .{};
            var instance: SubT = undefined;
            if (@hasField(SubT, "positional")) {
                const PositionalT = @FieldType(SubT, "positional");
                inline for (std.meta.fields(PositionalT)) |pos| {
                    if (@typeInfo(pos.type) == .optional)
                        @field(@field(instance, "positional"), pos.name) = null;
                    if (pos.defaultValue()) |default|
                        @field(@field(instance, "positional"), pos.name) = default;
                }
            }

            // have we entered positional
            var positional = false;
            var posidx: usize = 0;
            // var pos_idx: usize = 0;
            next_arg: while (args_it.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "--")) {
                    assert(!positional);
                    var it = std.mem.splitScalar(u8, arg[2..], '=');
                    const key = it.first();
                    const value = it.rest();

                    inline for (std.meta.fields(SubT)) |SubTFieldT| {
                        comptime if (std.mem.eql(u8, SubTFieldT.name, "positional")) continue;
                        if (std.mem.eql(u8, SubTFieldT.name, key)) {
                            @field(instance, SubTFieldT.name) = try parseValue(SubTFieldT.type, value, true);
                            @field(counts, SubTFieldT.name) += 1;
                            continue :next_arg;
                        }
                    }
                    return error.UnknownOption;
                } else {
                    positional = true;
                    if (!@hasField(SubT, "positional")) {
                        return error.UnknownArgument;
                    }

                    // could be a positional argument.
                    const PositionalT = @FieldType(SubT, "positional");
                    inline for (std.meta.fields(PositionalT), 0..) |pos, i| {
                        if (i == posidx) {
                            @field(instance.positional, pos.name) = try parseValue(pos.type, arg, false);
                            posidx += 1;
                            continue :next_arg;
                        }
                    }
                }
            }
            // default initialize what we can.
            inline for (std.meta.fields(SubT)) |f| {
                switch (@field(counts, f.name)) {
                    0 => if (f.defaultValue()) |default| {
                        @field(instance, f.name) = default;
                    },
                    1 => {},
                    else => {
                        std.debug.print("missing argument {s}\n", .{f.name});
                        return error.MissingArg;
                    },
                }
            }
            // TODO: check that all values are set.
            return @unionInit(T, subfield.name, instance);
        }
    }

    return error.UnknownSubcommand;
}

fn parseValue(comptime T: type, val: []const u8, is_option: bool) !T {
    const ActualT = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;

    if (ActualT == bool) {
        if (is_option and val.len == 0) return true;
        if (std.mem.eql(u8, val, "true")) return true;
        if (std.mem.eql(u8, val, "false")) return false;
        return error.InvalidValue;
    }

    if (ActualT == []const u8) return val;

    switch (@typeInfo(ActualT)) {
        .int => return try std.fmt.parseInt(ActualT, val, 10),
        .float => return try std.fmt.parseFloat(ActualT, val),
        .@"enum" => return std.meta.stringToEnum(ActualT, val) orelse error.InvalidValue,
        else => @compileError("Unsupported type: " ++ @typeName(ActualT)),
    }
}

const MockIterator = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(self: *MockIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }

    pub fn skip(self: *MockIterator) bool {
        if (self.index >= self.args.len) return false;
        self.index += 1;
        return true;
    }
};

test MockIterator {
    var mock = MockIterator{ .args = &.{ "exe", "run", "--mode=fast" } };

    var idx: usize = 0;
    while (mock.next()) |n| {
        try std.testing.expectEqualStrings(mock.args[idx], n);
        idx += 1;
    }
}
const TestArgs = union(enum) {
    run: struct {
        verbose: bool = false,
        mode: []const u8,
    },
    validate: struct {
        mode: []const u8,
        positional: struct {
            path: []const u8,
            threshold: ?i32,
        },
    },
};

test "parse: subcommand with options and defaults" {
    var mock = MockIterator{ .args = &.{ "exe", "run", "--mode=fast" } };
    const result = try parse(TestArgs, &mock);

    try std.testing.expect(result == .run);
    try std.testing.expectEqualStrings("fast", result.run.mode);
    try std.testing.expectEqual(false, result.run.verbose);
}

test "parse: boolean flag presence" {
    var mock = MockIterator{ .args = &.{ "exe", "run", "--verbose", "--mode=slow" } };
    const result = try parse(TestArgs, &mock);

    try std.testing.expect(result == .run);
    try std.testing.expectEqual(true, result.run.verbose);
    try std.testing.expectEqualStrings("slow", result.run.mode);
}

test "parse: positional arguments and optional values" {
    // Test with optional positional present
    {
        var mock = MockIterator{ .args = &.{ "exe", "validate", "--mode=strict", "/etc/config", "42" } };
        const result = try parse(TestArgs, &mock);
        try std.testing.expectEqualStrings("/etc/config", result.validate.positional.path);
        try std.testing.expectEqual(@as(i32, 42), result.validate.positional.threshold.?);
    }

    // Test with optional positional missing
    {
        var mock = MockIterator{ .args = &.{ "exe", "validate", "--mode=lax", "input.txt" } };
        const result = try parse(TestArgs, &mock);
        try std.testing.expectEqualStrings("input.txt", result.validate.positional.path);
        try std.testing.expect(result.validate.positional.threshold == null);
    }
}

test "parse: unknown subcommand error" {
    var mock = MockIterator{ .args = &.{ "exe", "ghost-command" } };
    const result = parse(TestArgs, &mock);
    try std.testing.expectError(error.UnknownSubcommand, result);
}

test "parse: unknown option error" {
    var mock = MockIterator{ .args = &.{ "exe", "run", "--unknown=123" } };
    const result = parse(TestArgs, &mock);
    try std.testing.expectError(error.UnknownOption, result);
}
