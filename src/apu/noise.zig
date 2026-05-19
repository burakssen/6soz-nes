const std = @import("std");

const utils = @import("utils.zig");

const Envelope = @import("envelope.zig");

const Noise = @This();

regs: [4]u8 = [_]u8{0} ** 4,
enabled: bool = false,
timer_period: u16 = 4,
timer_counter: u16 = 0,
shift_register: u15 = 1,
length_counter: u8 = 0,
envelope: Envelope = .{},
mode: bool = false,

pub fn write(self: *Noise, reg: u16, value: u8) void {
    self.regs[reg] = value;
    switch (reg) {
        0 => self.envelope.write(value),
        2 => {
            self.mode = (value & 0x80) != 0;
            self.timer_period = noisePeriod(value & 0x0f);
        },
        3 => {
            if (self.enabled) self.length_counter = utils.lengthTable(value >> 3);
            self.envelope.restart();
        },
        else => {},
    }
}

pub fn clockTimer(self: *Noise) void {
    if (self.timer_counter == 0) {
        self.timer_counter = self.timer_period;
        const tap: u4 = if (self.mode) 6 else 1;
        const feedback = (self.shift_register & 1) ^ ((self.shift_register >> tap) & 1);
        self.shift_register = (self.shift_register >> 1) | (@as(u15, feedback) << 14);
    } else {
        self.timer_counter -= 1;
    }
}

pub fn clockLength(self: *Noise) void {
    if (!self.envelope.length_halt() and self.length_counter != 0) {
        self.length_counter -= 1;
    }
}

pub fn output(self: *const Noise) u4 {
    if (!self.enabled or self.length_counter == 0 or (self.shift_register & 1) != 0) return 0;
    return self.envelope.volume();
}

fn noisePeriod(index: u8) u16 {
    const table = [_]u16{
        4,   8,   16,  32,  64,  96,   128,  160,
        202, 254, 380, 508, 762, 1016, 2034, 4068,
    };
    return table[index & 0x0f];
}
