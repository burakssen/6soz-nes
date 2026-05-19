const std = @import("std");

const utils = @import("utils.zig");

const Triangle = @This();

regs: [4]u8 = [_]u8{0} ** 4,
enabled: bool = false,
timer_period: u16 = 0,
timer_counter: u16 = 0,
sequence_step: u5 = 0,
length_counter: u8 = 0,
linear_counter: u8 = 0,
linear_reload: bool = false,

pub fn write(self: *Triangle, reg: u16, value: u8) void {
    self.regs[reg] = value;
    switch (reg) {
        2 => self.timer_period = (self.timer_period & 0x0700) | value,
        3 => {
            self.timer_period = (self.timer_period & 0x00ff) | (@as(u16, value & 0x07) << 8);
            if (self.enabled) self.length_counter = utils.lengthTable(value >> 3);
            self.linear_reload = true;
        },
        else => {},
    }
}

pub fn clockTimer(self: *Triangle) void {
    if (self.timer_counter == 0) {
        self.timer_counter = self.timer_period;
        if (self.length_counter != 0 and self.linear_counter != 0 and self.timer_period >= 2) {
            self.sequence_step +%= 1;
        }
    } else {
        self.timer_counter -= 1;
    }
}

pub fn clockLinear(self: *Triangle) void {
    if (self.linear_reload) {
        self.linear_counter = self.regs[0] & 0x7f;
    } else if (self.linear_counter != 0) {
        self.linear_counter -= 1;
    }
    if (!self.control()) self.linear_reload = false;
}

pub fn clockLength(self: *Triangle) void {
    if (!self.control() and self.length_counter != 0) {
        self.length_counter -= 1;
    }
}

pub fn output(self: *const Triangle) u4 {
    if (!self.enabled or self.length_counter == 0 or self.linear_counter == 0 or self.timer_period < 2) return 0;
    return triangleValue(self.sequence_step);
}

fn control(self: *const Triangle) bool {
    return (self.regs[0] & 0x80) != 0;
}

fn triangleValue(step: u5) u4 {
    return if (step < 16) 15 - @as(u4, @truncate(step)) else @as(u4, @truncate(step - 16));
}
