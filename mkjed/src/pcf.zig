//! Parser for pin constraint files, aka PCF.

const std = @import("std");
const testing = std.testing;
const fixedBufferStream = std.io.fixedBufferStream;

// TODO: determine if we need to add special vector-based functions.

/// Errors returned during pcf parsing/walking
const PinConstraintsError = error{
    /// Command is not supported or recognized.
    UnknownCommand,
    /// Attempted to add a pin that collides with an existing pin name
    PinCollision,
    /// Statement was ill-formed.
    InvalidStatement,
};

/// A list of constraints binding net names to hardware pins.
pub const PinConstraints = struct {
    allocator: std.mem.Allocator,
    constraints: std.StringArrayHashMap(u32),

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
    }

    fn parseLine(self: *PinConstraints, line: []const u8) !void {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');

        // TODO: error type
        const command = tokens.next() orelse return;

        if (command[0] == '#') {
            // comment, skip
            return;
        }
        // match the command. right now we only support set_io.

        if (std.mem.eql(u8, command, "set_io")) {
            // parse the next token, which is the net name
            const name = tokens.next() orelse return PinConstraintsError.InvalidStatement;

            // parse out the number.
            const num = tokens.next() orelse return PinConstraintsError.InvalidStatement;
            const n = try std.fmt.parseUnsigned(u8, num, 10);

            // check the next token. if it's null, we're ok.
            // if it's not null, but starts with #, we're ok.
            // if it's not null and starts with something other than #,
            // invalid statement.

            if (tokens.next()) |val| {
                if (val[0] != '#') {
                    return PinConstraintsError.InvalidStatement;
                }
            }

            // try to insert, but check for collisions.
            const gop = try self.constraints.getOrPut(name);
            if (gop.found_existing) {
                return PinConstraintsError.PinCollision;
            } else {
                // allocate a copy of the string so we can own it.
                // this MUST be the same as the key we used for getOrPut
                gop.key_ptr.* = try self.allocator.dupe(u8, name);
                gop.value_ptr.* = n;
            }
        } else {
            return PinConstraintsError.UnknownCommand;
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

    /// Retrieve a pin constraint if it exists.
    pub fn get(self: *PinConstraints, net: []const u8) ?u32 {
        return self.constraints.get(net);
    }
};

test PinConstraints {
    const alloc = testing.allocator;
    var pc = PinConstraints.init(alloc);
    defer pc.deinit();

    // should be okay
    const ok_stmt = "set_io scalar 1 # hi";
    try pc.parseLine(ok_stmt);

    try testing.expectEqual(1, pc.get("scalar"));
    try testing.expectEqual(null, pc.get("not real"));

    // should fail, since we already added a pin.
    try testing.expectError(PinConstraintsError.PinCollision, pc.parseLine(ok_stmt));
    // should do nothing (silent)
    const comment = "# hi";
    try pc.parseLine(comment);

    // unsupported command (not set_io)
    const bad = "set_net a b";
    try testing.expectError(PinConstraintsError.UnknownCommand, pc.parseLine(bad));

    // set_io command is not valid (extra arg)
    const extra_arg = "set_io scalar 1 2";
    try testing.expectError(PinConstraintsError.InvalidStatement, pc.parseLine(extra_arg));
    const missing = "set_io scalar";
    try testing.expectError(PinConstraintsError.InvalidStatement, pc.parseLine(missing));
}
