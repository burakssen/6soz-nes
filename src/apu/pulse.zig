const std = @import("std");



// Inline definitions are placed at the end of the file.

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
            if (self.enabled) self.length_counter = lengthTable(value >> 3);
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

fn lengthTable(index: u8) u8 {
    const table = [_]u8{
        10,  254, 20, 2,  40, 4,  80, 6,
        160, 8,   60, 10, 14, 12, 26, 14,
        12,  16,  24, 18, 48, 20, 96, 22,
        192, 24,  72, 26, 16, 28, 32, 30,
    };
    return table[index & 0x1f];
}

const Envelope = struct {
    reg: u8 = 0,
    divider: u8 = 0,
    decay: u4 = 0,
    start: bool = false,

    pub fn write(self: *Envelope, value: u8) void {
        self.reg = value;
    }

    pub fn restart(self: *Envelope) void {
        self.start = true;
    }

    pub fn clock(self: *Envelope) void {
        if (self.start) {
            self.start = false;
            self.decay = 15;
            self.divider = self.period();
            return;
        }

        if (self.divider != 0) {
            self.divider -= 1;
            return;
        }

        self.divider = self.period();
        if (self.decay != 0) {
            self.decay -= 1;
        } else if (self.length_halt()) {
            self.decay = 15;
        }
    }

    pub fn volume(self: *const Envelope) u4 {
        if ((self.reg & 0x10) != 0) return @truncate(self.reg & 0x0f);
        return self.decay;
    }

    fn period(self: *const Envelope) u8 {
        return self.reg & 0x0f;
    }

    pub fn length_halt(self: *const Envelope) bool {
        return (self.reg & 0x20) != 0;
    }
};

const Sweep = struct {
    enabled: bool = false,
    period: u3 = 0,
    negate: bool = false,
    shift: u3 = 0,
    divider: u3 = 0,
    reload: bool = false,

    pub fn write(self: *Sweep, value: u8) void {
        self.enabled = (value & 0x80) != 0;
        self.period = @truncate((value >> 4) & 0x07);
        self.negate = (value & 0x08) != 0;
        self.shift = @truncate(value & 0x07);
        self.reload = true;
    }
};
