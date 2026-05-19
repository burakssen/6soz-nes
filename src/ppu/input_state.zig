const InputState = @This();

a: bool = false,
b: bool = false,
select: bool = false,
start: bool = false,
up: bool = false,
down: bool = false,
left: bool = false,
right: bool = false,

pub fn toNesControllerByte(self: InputState) u8 {
    return (if (self.a) @as(u8, 1) else 0) |
        (if (self.b) @as(u8, 2) else 0) |
        (if (self.select) @as(u8, 4) else 0) |
        (if (self.start) @as(u8, 8) else 0) |
        (if (self.up) @as(u8, 16) else 0) |
        (if (self.down) @as(u8, 32) else 0) |
        (if (self.left) @as(u8, 64) else 0) |
        (if (self.right) @as(u8, 128) else 0);
}

test "input state converts to NES controller byte order" {
    const std = @import("std");

    const input = InputState{
        .a = true,
        .start = true,
        .up = true,
        .right = true,
    };

    try std.testing.expectEqual(@as(u8, 0b1001_1001), input.toNesControllerByte());
}
