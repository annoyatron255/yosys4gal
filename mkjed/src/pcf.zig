//! Parser for pin constraint files, aka PCF
//! This parser supports two commands: set_io and set_clk.
//! set_io is used to bind a module port to a pin number.
//! vector ports use name[index] syntax.
//! set_clk is used to mark the clock port on the module, which will not be
//! placed on the chip because it's a fixed pin.

const std = @import("std");
const builtin = @import("builtin");
const fixedBufferStream = std.io.fixedBufferStream;
const log = if (builtin.is_test)
    // Downgrade `err` to `warn` for tests.
    // Zig fails any test that does `log.err`, but we want to test those code paths here.
    struct {
        const base = std.log.scoped(.pcf);
        const err = warn;
        const warn = base.warn;
        const info = base.info;
        const debug = base.debug;
    }
else
    std.log.scoped(.pcf);

/// Errors returned during pcf parsing/walking
pub const PcfError = error{
    /// Command is not supported or recognized.
    UnknownCommand,
    /// Attempted to add a pin that collides with an existing pin name
    PinCollision,
    /// Statement was ill-formed.
    InvalidStatement,
    /// clock statement is invalid.
    InvalidClock,
};

/// parses arguments from a token stream.
fn parseArg(comptime T: type, args: *std.mem.TokenIterator(u8, .scalar)) !T {
    const info = @typeInfo(T);

    switch (info) {
        .int => {
            const arg = args.next() orelse return PcfError.InvalidStatement;
            return std.fmt.parseInt(T, arg, 10) catch return PcfError.InvalidStatement;
        },
        .pointer => |ptr_info| {
            // check that this is a slice
            if (ptr_info.size != .slice) {
                @compileError("unsupported pointer type, got " ++ @typeName(T));
            }
            return args.next() orelse return PcfError.InvalidStatement;
        },
        .@"struct" => |struct_info| {
            // check that this is an unnamed tuple
            var struct_instance: T = undefined;
            inline for (struct_info.fields) |struct_field| {
                const val = try parseArg(struct_field.type, args);
                @field(struct_instance, struct_field.name) = val;
            }
            return struct_instance;
        },
        .array => |arr_info| {
            const instance: T = undefined;
            for (0..arr_info.len) |i| {
                const val = try parseArg(arr_info.child, args);
                instance[i] = val;
            }
            return instance;
        },
        else => @compileError("unsupported type" ++ @typeName(T)),
    }
}

test parseArg {
    const testing = std.testing;

    const TestStruct = struct { name: []const u8, value: u32, enabled: u32 };

    const line = "test_name 123 1";
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');

    const result = try parseArg(TestStruct, &tokens);
    try testing.expectEqualStrings("test_name", result.name);
    try testing.expectEqual(@as(u32, 123), result.value);
    try testing.expectEqual(@as(u32, 1), result.enabled);
}

/// PCF file statement. consists of a command and then arguments.
const PcfCmd = union(enum) {
    const Self = @This();
    set_io: struct { name: []const u8, net: u32 },
    set_clk: []const u8,
    // set_voltage: struct { []const u8, u32 },

    /// parse a given line of a PCF file.
    /// we assume the line is not a comment or empty
    pub fn parseLine(line: []const u8) !Self {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');

        const cmd_name = tokens.next() orelse return error.EmptyLine;

        const cmds = @typeInfo(Self).@"union";

        inline for (cmds.fields) |field| {
            if (std.mem.eql(u8, cmd_name, field.name)) {
                const val = try parseArg(field.type, &tokens);
                // we've parse the args, check for trailing non-comments.
                if (tokens.next()) |trailing| {
                    if (trailing[0] != '#') {
                        return PcfError.InvalidStatement;
                    }
                }
                return @unionInit(Self, field.name, val);
            }
        }
        return PcfError.UnknownCommand;
    }
};

/// A list of constraints binding net names to hardware pins.
pub const PinConstraints = struct {
    allocator: std.mem.Allocator,
    constraints: std.StringArrayHashMap(u32),
    clk_net: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .constraints = std.StringArrayHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *PinConstraints) void {
        // we have to manually free the keys
        // do we free the values?
        var iter = self.constraints.iterator();

        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.constraints.deinit();

        if (self.clk_net) |c| {
            self.allocator.free(c);
        }
    }

    fn parseLine(self: *PinConstraints, line: []const u8) !void {

        // check if this line is empty or starts with a comment
        {
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            const start = tokens.next() orelse return;
            if (start[0] == '#') return;
        }

        const command = PcfCmd.parseLine(line) catch |err| switch (err) {
            error.InvalidStatement => {
                log.err("Invalid statement: {s}", .{line});
                return err;
            },
            else => |uncaught| {
                return uncaught;
            },
        };
        switch (command) {
            .set_io => |args| {
                // try to insert, but check for collisions.
                const gop = try self.constraints.getOrPut(args.name);
                if (gop.found_existing) {
                    return PcfError.PinCollision;
                } else {
                    // allocate a copy of the string so we can own it.
                    // this MUST be the same as the key we used for getOrPut
                    gop.key_ptr.* = try self.allocator.dupe(u8, args.name);
                    gop.value_ptr.* = args.net;
                }
            },
            .set_clk => |args| {
                if (self.clk_net) |existing| {
                    log.err("Clock collision existing={s}, new={s}", .{ existing, args });
                    return PcfError.InvalidClock;
                }
                self.clk_net = try self.allocator.dupe(u8, args);
            },
        }
    }

    pub fn parseReader(self: *PinConstraints, reader: anytype) !void {
        var buf: [128]u8 = undefined;
        var fbs = fixedBufferStream(&buf);
        const writer = fbs.writer();

        while (reader.streamUntilDelimiter(writer, '\n', 128)) {
            fbs.reset();
            const line = fbs.getWritten();
            try self.parseLine(line);
        } else |err| {
            return err;
        }
    }

    pub fn parseSlice(self: *PinConstraints, data: []const u8) !void {
        var tokstream = std.mem.tokenizeScalar(u8, data, '\n');

        while (tokstream.next()) |line| {
            try self.parseLine(line);
        }
    }

    /// Retrieve a pin constraint if it exists.
    pub fn get(self: PinConstraints, net: []const u8) ?u32 {
        return self.constraints.get(net);
    }
};

test PinConstraints {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pc = PinConstraints.init(alloc);
    defer pc.deinit();

    // should be okay
    const ok_stmt = "set_io scalar 1 # hi";
    try pc.parseLine(ok_stmt);

    try testing.expectEqual(1, pc.get("scalar"));
    try testing.expectEqual(null, pc.get("not real"));

    // should fail, since we already added a pin.
    try testing.expectError(PcfError.PinCollision, pc.parseLine(ok_stmt));
    // should do nothing (silent)
    const comment = "# hi";
    try pc.parseLine(comment);

    // unsupported command (not set_io)
    const bad = "bad_cmd a b";
    try testing.expectError(PcfError.UnknownCommand, pc.parseLine(bad));

    // set_io command is not valid (extra arg)
    const extra_arg = "set_io scalar 1 2";
    try testing.expectError(PcfError.InvalidStatement, pc.parseLine(extra_arg));
    const missing = "set_io scalar";
    try testing.expectError(PcfError.InvalidStatement, pc.parseLine(missing));
    const set_clk = "set_clk clkname";
    try pc.parseLine(set_clk);

    try testing.expectEqualStrings("clkname", pc.clk_net.?);
    try testing.expectError(PcfError.InvalidClock, pc.parseLine(set_clk));
}

test "PCF file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var pc = PinConstraints.init(alloc);
    defer pc.deinit();
    const pcf_path = "./testcases/olmc_test.pcf";
    const pcf_file = try std.fs.cwd().readFileAlloc(alloc, pcf_path, 8192 * 20);
    defer alloc.free(pcf_file);
    try pc.parseSlice(pcf_file);
}
