const std = @import("std");

pub const Error = error{
    InvalidState,
    StateKindMismatch,
    UnsupportedStateVersion,
} || std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Reader.Error;

pub fn hashBytes(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

pub fn writeValue(writer: *std.Io.Writer, value: anytype) Error!void {
    try writeTypedValue(writer, @TypeOf(value), value);
}

pub fn readValue(reader: *std.Io.Reader, comptime T: type) Error!T {
    return readTypedValue(reader, T);
}

pub fn readInto(reader: *std.Io.Reader, ptr: anytype) Error!void {
    try readTypedValueInto(reader, @TypeOf(ptr.*), ptr);
}

pub fn readBytes(reader: *std.Io.Reader, len: usize) Error![]const u8 {
    return reader.take(len) catch error.InvalidState;
}

pub fn expectBytes(reader: *std.Io.Reader, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, try readBytes(reader, expected.len), expected))
        return error.InvalidState;
}

pub fn done(reader: *const std.Io.Reader) Error!void {
    if (reader.bufferedLen() != 0) return error.InvalidState;
}

/// Returns the storage integer type for a given Int typeinfo,
/// rounded up to the nearest power-of-two byte width (8/16/32/64 bits).
fn storageInt(comptime info: std.builtin.Type.Int) type {
    const width: u16 = if (info.bits <= 8) 8 else if (info.bits <= 16) 16 else if (info.bits <= 32) 32 else if (info.bits <= 64) 64 else @compileError("unsupported integer size");
    return std.meta.Int(info.signedness, width);
}

fn writeTypedValue(writer: *std.Io.Writer, comptime T: type, value: T) Error!void {
    switch (@typeInfo(T)) {
        .bool => try writer.writeByte(if (value) 1 else 0),
        .int => |info| try writeIntAs(writer, storageInt(info), @intCast(value)),
        .float => |info| switch (info.bits) {
            32 => try writeIntAs(writer, u32, @bitCast(value)),
            64 => try writeIntAs(writer, u64, @bitCast(value)),
            else => @compileError("unsupported float size"),
        },
        .@"enum" => |info| try writeTypedValue(writer, info.tag_type, @intFromEnum(value)),
        .array => |info| for (value) |item| try writeTypedValue(writer, info.child, item),
        .@"struct" => |info| inline for (info.fields) |f|
            try writeTypedValue(writer, f.type, @field(value, f.name)),
        .optional => |info| {
            if (comptime @typeInfo(info.child) == .pointer) {
                // Pointer optionals are always null at serialization time
                if (value != null) return error.InvalidState;
                try writeTypedValue(writer, bool, false);
            } else if (value) |child| {
                try writeTypedValue(writer, bool, true);
                try writeTypedValue(writer, info.child, child);
            } else {
                try writeTypedValue(writer, bool, false);
            }
        },
        .pointer => @compileError("pointers are not valid state fields"),
        else => @compileError("unsupported state field: " ++ @typeName(T)),
    }
}

// Thin wrapper so callers can get a return value instead of writing into a pointer.
fn readTypedValue(reader: *std.Io.Reader, comptime T: type) Error!T {
    var result: T = undefined;
    try readTypedValueInto(reader, T, &result);
    return result;
}

fn readTypedValueInto(reader: *std.Io.Reader, comptime T: type, out: *T) Error!void {
    switch (@typeInfo(T)) {
        .bool => {
            const b = reader.takeByte() catch return error.InvalidState;
            if (b > 1) return error.InvalidState;
            out.* = b != 0;
        },
        .int => |info| {
            out.* = std.math.cast(T, try readIntAs(reader, storageInt(info))) orelse
                return error.InvalidState;
        },
        .float => |info| switch (info.bits) {
            32 => out.* = @bitCast(try readIntAs(reader, u32)),
            64 => out.* = @bitCast(try readIntAs(reader, u64)),
            else => @compileError("unsupported float size"),
        },
        .@"enum" => |info| {
            const tag = try readTypedValue(reader, info.tag_type);
            inline for (info.fields) |f| {
                if (tag == f.value) {
                    out.* = @enumFromInt(tag);
                    return;
                }
            }
            return error.InvalidState;
        },
        .array => |info| for (out) |*item| try readTypedValueInto(reader, info.child, item),
        .@"struct" => |info| inline for (info.fields) |f|
            try readTypedValueInto(reader, f.type, &@field(out.*, f.name)),
        .optional => |info| {
            const present = try readTypedValue(reader, bool);
            if (comptime @typeInfo(info.child) == .pointer) {
                // Pointer optionals are always null at serialization time
                if (present) return error.InvalidState;
                out.* = null;
                return;
            }
            if (!present) {
                out.* = null;
                return;
            }
            var child: info.child = undefined;
            try readTypedValueInto(reader, info.child, &child);
            out.* = child;
        },
        .pointer => @compileError("pointers are not valid state fields"),
        else => @compileError("unsupported state field: " ++ @typeName(T)),
    }
}

fn writeIntAs(writer: *std.Io.Writer, comptime T: type, value: T) Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readIntAs(reader: *std.Io.Reader, comptime T: type) Error!T {
    const bytes = try readBytes(reader, @sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
