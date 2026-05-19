const std = @import("std");

const Envelope = @This();

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
