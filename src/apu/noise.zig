const std = @import("std");



// Inline definitions are placed at the end of the file.
const Timing = @import("timing");

const Noise = @This();

regs: [4]u8 = [_]u8{0} ** 4,
enabled: bool = false,
timer_period: u16 = 4,
timer_counter: u16 = 0,
shift_register: u15 = 1,
length_counter: u8 = 0,
envelope: Envelope = .{},
mode: bool = false,
timing: Timing = Timing.ntsc,

pub fn write(self: *Noise, reg: u16, value: u8) void {
    self.regs[reg] = value;
    switch (reg) {
        0 => self.envelope.write(value),
        2 => {
            self.mode = (value & 0x80) != 0;
            self.timer_period = self.timing.noisePeriod(value & 0x0f);
        },
        3 => {
            if (self.enabled) self.length_counter = lengthTable(value >> 3);
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
