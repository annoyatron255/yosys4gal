//! The purpose of `flags` is to define standard behavior for parsing CLI arguments and provide
//! a specific parsing library, implementing this behavior.
//!
//! These are TigerBeetle CLI guidelines:
//!
//!    - The main principle is robustness --- make operator errors harder to make.
//!    - For production usage, avoid defaults.
//!    - Thoroughly validate options.
//!    - In particular, check that no options are repeated.
//!    - Use only long options (`--addresses`).
//!    - Exception: `-h/--help` is allowed.
//!    - Use `--key=value` syntax for an option with an argument.
//!      Don't use `--key value`, as that can be ambiguous (e.g., `--key --verbose`).
//!    - Use subcommand syntax when appropriate.
//!    - Use positional arguments when appropriate.
//!
//! Design choices for this particular `flags` library:
//!
//! - Be a 80% solution. Parsing arguments is a surprisingly vast topic: auto-generated help,
//!   bash completions, typo correction. Rather than providing a definitive solution, `flags`
//!   is just one possible option. It is ok to re-implement arg parsing in a different way, as long
//!   as the CLI guidelines are observed.
//!
//! - No auto-generated help. Zig doesn't expose doc comments through `@typeInfo`, so its hard to
//!   implement auto-help nicely. Additionally, fully hand-crafted `--help` message can be of
//!   higher quality.
//!
//! - Fatal errors. It might be "cleaner" to use `try` to propagate the error to the caller, but
//!   during early CLI parsing, it is much simpler to terminate the process directly and save the
//!   caller the hassle of propagating errors. The `fatal` function is public, to allow the caller
//!   to run additional validation or parsing using the same error reporting mechanism.
//!
//! - Concise DSL. Most cli parsing is done for ad-hoc tools like benchmarking, where the ability to
//!   quickly add a new argument is valuable. As this is a 80% solution, production code may use
//!   more verbose approach if it gives better UX.
//!
//! - Caller manages ArgsIterator. ArgsIterator owns the backing memory of the args, so we let the
//!   caller to manage the lifetime. The caller should be skipping program name.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Format and print an error message to stderr, then exit with an exit code of 1.
fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    var buf: [128]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const stderr = &stderr_writer.interface;
    stderr.print("error: " ++ fmt_string ++ "\n", args) catch {};
    // NB: this status must match vsr.FatalReason.cli, but it would be wrong for flags to depend on
    // vsr. The right way would be to parametrize flags by this behavior, and let the caller inject
    // the implementation of fatal function, but let's be pragmatic here and just match the behavior
    // manually.
    std.process.exit(1);
}

/// Parse CLI arguments for subcommands specified as Zig `struct` or `union(enum)`:
///
/// ```
/// const CLIArgs = union(enum) {
///    start: struct { addresses: []const u8, replica: u32 },
///    format: struct {
///        verbose: bool = false,
///        positional: struct {
///            path: []const u8,
///        }
///    },
///
///    pub const help =
///        \\ tigerbeetle start --addresses=<addresses> --replica=<replica>
///        \\ tigerbeetle format [--verbose] <path>
/// }
///
/// const cli_args = parse_commands(&args, CLIArgs);
/// ```
///
/// `positional` field is treated specially, it designates positional arguments.
///
/// If `pub const help` declaration is present, it is used to implement `-h/--help` argument.
///
/// Value parsing can be customized on per-type basis via `parse_flag_value` customization point.
pub fn parse(args: *std.process.ArgIterator, comptime CLIArgs: type) CLIArgs {
    comptime assert(CLIArgs != void);
    assert(args.skip()); // Discard executable name.
    return parse_flags(args, CLIArgs);
}

fn parse_commands(args: *std.process.ArgIterator, comptime Commands: type) Commands {
    comptime assert(@typeInfo(Commands) == .@"union");
    comptime assert(std.meta.fields(Commands).len >= 2);

    const first_arg = args.next() orelse fatal(
        "subcommand required, expected {s}",
        .{comptime fields_to_comma_list(Commands)},
    );

    // NB: help must be declared as *pub* const to be visible here.
    if (@hasDecl(Commands, "help")) {
        if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
            stdout_writer.interface.writeAll(Commands.help) catch std.process.exit(1);
            std.process.exit(0);
        }
    }

    inline for (comptime std.meta.fields(Commands)) |field| {
        comptime assert(std.mem.indexOfScalar(u8, field.name, '_') == null);
        if (std.mem.eql(u8, first_arg, field.name)) {
            return @unionInit(Commands, field.name, parse_flags(args, field.type));
        }
    }
    fatal("unknown subcommand: '{s}'", .{first_arg});
}

fn parse_flags(args: *std.process.ArgIterator, comptime Flags: type) Flags {
    @setEvalBranchQuota(5_000);

    if (Flags == void) {
        if (args.next()) |arg| {
            fatal("unexpected argument: '{s}'", .{arg});
        }
        return {};
    }

    if (@typeInfo(Flags) == .@"union") {
        return parse_commands(args, Flags);
    }

    assert(@typeInfo(Flags) == .@"struct");

    const fields = std.meta.fields(Flags);
    comptime var fields_named, const fields_positional = for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "--")) {
            assert(field.type == void);
            assert(index != fields.len - 1);
            break .{
                fields[0..index].*,
                fields[index + 1 ..].*,
            };
        }
    } else .{
        fields[0..fields.len].*,
        [_]std.builtin.Type.StructField{},
    };

    comptime {
        if (fields_positional.len == 0) {
            assert(fields.len == fields_named.len);
        } else {
            assert(fields.len == fields_named.len + 1 + fields_positional.len);
        }

        // When parsing named arguments, we must consider longer arguments first, such that
        // `--foo-bar=92` is not confused for a misspelled `--foo=92`. Using `std.sort` for
        // comptime-only values does not work, so open-code insertion sort, and comptime assert
        // order during the actual parsing.
        for (fields_named[0..], 0..) |*field_right, i| {
            for (fields_named[0..i]) |*field_left| {
                if (field_left.name.len < field_right.name.len) {
                    std.mem.swap(std.builtin.Type.StructField, field_left, field_right);
                }
            }
        }

        for (fields_named) |field| {
            switch (@typeInfo(field.type)) {
                .bool => {
                    // Boolean flags must have a default.
                    assert(field.defaultValue() != null);
                    assert(field.defaultValue().? == false);
                },
                .optional => |optional| {
                    // Optional flags must have a default.
                    assert(field.defaultValue() != null);
                    assert(field.defaultValue().? == null);

                    assert_valid_value_type(optional.child);
                },
                else => {
                    assert_valid_value_type(field.type);
                },
            }
        }

        var optional_tail: bool = false;
        for (fields_positional) |field| {
            if (field.defaultValue() == null) {
                if (optional_tail) @panic("optional positional arguments must be trailing");
            } else {
                optional_tail = true;
            }
            switch (@typeInfo(field.type)) {
                .optional => |optional| {
                    // optional flags should have a default
                    assert(field.defaultValue() != null);
                    assert(field.defaultValue().? == null);
                    assert_valid_value_type(optional.child);
                },
                else => {
                    assert_valid_value_type(field.type);
                },
            }
        }
    }

    var counts: std.enums.EnumFieldStruct(std.meta.FieldEnum(Flags), u32, 0) = .{};
    var result: Flags = undefined;
    var parsed_positional = false;
    next_arg: while (args.next()) |arg| {
        comptime var field_len_prev = std.math.maxInt(usize);
        inline for (fields_named) |field| {
            const flag = comptime flag_name(field);

            comptime assert(field_len_prev >= field.name.len);
            field_len_prev = field.name.len;
            if (std.mem.startsWith(u8, arg, flag)) {
                if (parsed_positional) {
                    fatal("unexpected trailing option: '{s}'", .{arg});
                }

                @field(counts, field.name) += 1;
                const flag_value = parse_flag(field.type, flag, arg);
                @field(result, field.name) = flag_value;
                continue :next_arg;
            }
        }

        if (fields_positional.len > 0) {
            counts.@"--" += 1;
            switch (counts.@"--" - 1) {
                inline 0...fields_positional.len - 1 => |field_index| {
                    const field = fields_positional[field_index];
                    const flag = comptime flag_name_positional(field);

                    if (arg.len == 0) fatal("{s}: empty argument", .{flag});
                    // Prevent ambiguity between a flag and positional argument value. We could add
                    // support for bare ` -- ` as a disambiguation mechanism once we have a real
                    // use-case.
                    if (arg[0] == '-') fatal("unexpected argument: '{s}'", .{arg});
                    parsed_positional = true;

                    @field(result, field.name) =
                        parse_value(field.type, flag, arg);
                    continue :next_arg;
                },
                else => {}, // Fall-through to the unexpected argument error.
            }
        }

        fatal("unexpected argument: '{s}'", .{arg});
    }

    inline for (fields_named) |field| {
        const flag = flag_name(field);
        switch (@field(counts, field.name)) {
            0 => if (field.defaultValue()) |default| {
                @field(result, field.name) = default;
            } else {
                fatal("{s}: argument is required", .{flag});
            },
            1 => {},
            else => fatal("{s}: duplicate argument", .{flag}),
        }
    }

    if (fields_positional.len > 0) {
        assert(counts.@"--" <= fields_positional.len);
        inline for (fields_positional, 0..) |field, field_index| {
            if (field_index >= counts.@"--") {
                const flag = comptime flag_name_positional(field);
                if (field.defaultValue()) |default| {
                    @field(result, field.name) = default;
                } else {
                    fatal("{s}: argument is required", .{flag});
                }
            }
        }
    }

    return result;
}

fn assert_valid_value_type(comptime T: type) void {
    comptime {
        if (T == []const u8 or T == [:0]const u8 or @typeInfo(T) == .int) return;
        if (@hasDecl(T, "parse_flag_value")) return;

        if (@typeInfo(T) == .@"enum") {
            const info = @typeInfo(T).@"enum";
            assert(info.is_exhaustive);
            assert(info.fields.len >= 2);
            return;
        }

        @compileError("flags: unsupported type: " ++ @typeName(T));
    }
}

/// Parse, e.g., `--cluster=123` into `123` integer
fn parse_flag(comptime T: type, flag: []const u8, arg: [:0]const u8) T {
    assert(flag[0] == '-' and flag[1] == '-');

    if (T == bool) {
        if (std.mem.eql(u8, arg, flag)) {
            // Bool argument may not have a value.
            return true;
        }
    }

    const value = parse_flag_split_value(flag, arg);
    assert(value.len > 0);
    return parse_value(T, flag, value);
}

/// Splits the value part from a `--arg=value` syntax.
fn parse_flag_split_value(flag: []const u8, arg: [:0]const u8) [:0]const u8 {
    assert(flag[0] == '-' and flag[1] == '-');
    assert(std.mem.startsWith(u8, arg, flag));

    const value = arg[flag.len..];
    if (value.len == 0) {
        fatal("{s}: expected value separator '='", .{flag});
    }
    if (value[0] != '=') {
        fatal(
            "{s}: expected value separator '=', but found '{c}' in '{s}'",
            .{ flag, value[0], arg },
        );
    }
    if (value.len == 1) fatal("{s}: argument requires a value", .{flag});
    return value[1..];
}

fn parse_value(comptime T: type, flag: []const u8, value: [:0]const u8) T {
    assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');
    assert(value.len > 0);

    const V = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };

    if (V == []const u8 or V == [:0]const u8) return value;
    if (V == bool) return parse_value_bool(flag, value);
    if (@typeInfo(V) == .int) return parse_value_int(V, flag, value);
    if (@typeInfo(V) == .@"enum") return parse_value_enum(V, flag, value);
    if (@hasDecl(V, "parse_flag_value")) {

        // Contracts:
        // - Input string is guaranteed to be not empty.
        // - Output diagnostic must point to statically-allocated data.
        // - Diagnostic must start with a lower case letter.
        // - Diagnostic must end with a ':' (it will be concatenated with original input).
        // - (static_diagnostic != null) iff error.InvalidFlagValue is returned.
        const parse_flag_value: fn (
            string: []const u8,
            static_diagnostic: *?[]const u8,
        ) error{InvalidFlagValue}!V = V.parse_flag_value;

        var diagnostic: ?[]const u8 = null;
        if (parse_flag_value(value, &diagnostic)) |result| {
            assert(diagnostic == null);
            return result;
        } else |err| switch (err) {
            error.InvalidFlagValue => {
                const message = diagnostic.?;
                assert(std.ascii.isLower(message[0]));
                assert(message[message.len - 1] == ':');
                fatal("{s}: {s} '{s}'", .{ flag, message, value });
            },
        }
    }
    comptime unreachable;
}

/// Parse string value into an integer, providing a nice error message for the user.
fn parse_value_int(comptime T: type, flag: []const u8, value: [:0]const u8) T {
    assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');

    return std.fmt.parseInt(T, value, 10) catch |err| {
        switch (err) {
            error.Overflow => fatal(
                "{s}: value exceeds {d}-bit {s} integer: '{s}'",
                .{ flag, @typeInfo(T).int.bits, @tagName(@typeInfo(T).int.signedness), value },
            ),
            error.InvalidCharacter => fatal(
                "{s}: expected an integer value, but found '{s}' (invalid digit)",
                .{ flag, value },
            ),
        }
    };
}

fn parse_value_bool(flag: []const u8, value: [:0]const u8) bool {
    return switch (parse_value_enum(
        enum {
            true,
            false,
        },
        flag,
        value,
    )) {
        .true => true,
        .false => false,
    };
}

fn parse_value_enum(comptime E: type, flag: []const u8, value: [:0]const u8) E {
    assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');
    comptime assert(@typeInfo(E).@"enum".is_exhaustive);

    return std.meta.stringToEnum(E, value) orelse fatal(
        "{s}: expected one of {s}, but found '{s}'",
        .{ flag, comptime fields_to_comma_list(E), value },
    );
}

fn fields_to_comma_list(comptime E: type) []const u8 {
    comptime {
        const field_count = std.meta.fields(E).len;
        assert(field_count >= 2);

        var result: []const u8 = "";
        for (std.meta.fields(E), 0..) |field, field_index| {
            const separator = switch (field_index) {
                0 => "",
                else => ", ",
                field_count - 1 => if (field_count == 2) " or " else ", or ",
            };
            result = result ++ separator ++ "'" ++ field.name ++ "'";
        }
        return result;
    }
}

fn flag_name(comptime field: std.builtin.Type.StructField) []const u8 {
    return comptime blk: {
        assert(!std.mem.eql(u8, field.name, "positional"));

        var result: []const u8 = "--";
        var index = 0;
        while (std.mem.indexOfScalar(u8, field.name[index..], '_')) |i| {
            result = result ++ field.name[index..][0..i] ++ "-";
            index = index + i + 1;
        }
        result = result ++ field.name[index..];
        break :blk result;
    };
}

test flag_name {
    const field = @typeInfo(struct { statsd: bool }).@"struct".fields[0];
    try std.testing.expectEqualStrings(flag_name(field), "--statsd");
}

fn flag_name_positional(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime assert(std.mem.indexOfScalar(u8, field.name, '_') == null);
    return "<" ++ field.name ++ ">";
}

fn parse_flag_value_check_diagnostic(string: []const u8, diagnostic: ?[]const u8) !void {
    const message = diagnostic orelse {
        std.debug.print("expected a diagnostic: string='{s}'", .{string});
        return error.TestUnexpectedResult;
    };
    if (!(message.len > 0 and
        std.ascii.isLower(message[0]) and
        message[message.len - 1] == ':'))
    {
        std.debug.print("wrong diagnostic format: string='{s}' diagnostic='{s}'", .{
            string,
            message,
        });
        return error.TestUnexpectedResult;
    }
}

fn unique(sorted: []u8) []u8 {
    assert(sorted.len > 0);

    var count: usize = 1;
    for (1..sorted.len) |index| {
        assert(sorted[count - 1] <= sorted[index]);
        if (sorted[count - 1] == sorted[index]) {
            // Duplicate! Skip to the next index.
        } else {
            sorted[count] = sorted[index];
            count += 1;
        }
    }

    return sorted[0..count];
}
