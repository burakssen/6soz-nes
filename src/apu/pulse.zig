const std = @import("std");

const utils = @import("utils.zig");

const Envelope = @import("envelope.zig");
const Sweep = @import("sweep.zig");

const Pulse = @This();

channel: u1 = 0,
regs: [4]u8 = [_]u8{0} ** 4,
enabled: bool = false,
timer_period: u16 = 0,
timer_counter: u16 = 0,
duty_step: u3 = 0,
length_counter: u8 = 0,
envelope: Envelope = .{},
sweep: Sweep = .{},

pub fn write(self: *Pulse, reg: u16, value: u8) void {
    self.regs[reg] = value;
    switch (reg) {
        0 => self.envelope.write(value),
        1 => self.sweep.write(value),
        2 => self.timer_period = (self.timer_period & 0x0700) | value,
        3 => {
            self.timer_period = (self.timer_period & 0x00ff) | (@as(u16, value & 0x07) << 8);
            if (self.enabled) self.length_counter = utils.lengthTable(value >> 3);
            self.duty_step = 0;
            self.envelope.restart();
        },
        else => {},
    }
}

pub fn clockTimer(self: *Pulse) void {
    if (self.timer_counter == 0) {
        self.timer_counter = self.timer_period;
        self.duty_step +%= 1;
    } else {
        self.timer_counter -= 1;
    }
}

pub fn clockLength(self: *Pulse) void {
    if (!self.envelope.length_halt() and self.length_counter != 0) {
        self.length_counter -= 1;
    }
}

pub fn clockSweep(self: *Pulse) void {
    if (self.sweep.divider == 0) {
        if (self.sweep.enabled and self.sweep.shift != 0 and !self.sweepMuted()) {
            self.timer_period = self.sweepTarget();
        }
        self.sweep.divider = self.sweep.period;
    } else {
        self.sweep.divider -= 1;
    }

    if (self.sweep.reload) {
        self.sweep.reload = false;
        self.sweep.divider = self.sweep.period;
    }
}

pub fn output(self: *const Pulse) u4 {
    if (!self.enabled or self.length_counter == 0 or self.timer_period < 8 or self.sweepMuted()) return 0;
    const duty: u2 = @truncate((self.regs[0] >> 6) & 0x03);
    if (pulseDuty(duty, self.duty_step) == 0) return 0;
    return self.envelope.volume();
}

fn sweepMuted(self: *const Pulse) bool {
    return self.timer_period > 0x7ff or self.sweepTarget() > 0x7ff;
}

fn sweepTarget(self: *const Pulse) u16 {
    const change = self.timer_period >> self.sweep.shift;
    if (!self.sweep.negate) return self.timer_period + change;
    return if (self.channel == 0)
        self.timer_period -| change -| 1
    else
        self.timer_period -| change;
}

fn pulseDuty(duty: u2, step: u3) u1 {
    const table = [_]u8{
        0b0100_0000,
        0b0110_0000,
        0b0111_1000,
        0b1001_1111,
    };
    return @truncate((table[duty] >> (7 - step)) & 1);
}
