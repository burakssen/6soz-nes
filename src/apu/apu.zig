const std = @import("std");

const Pulse = @import("pulse.zig");
const Triangle = @import("triangle.zig");
const Noise = @import("noise.zig");
const DcBlocker = @import("dc_blocker.zig");
const OnePoleLowPass = @import("one_pole_low_pass.zig");

const Apu = @This();

pub const sample_rate = 48_000;
pub const cpu_rate = 1_789_773;
const max_samples = 2048;
const frame_period = 7457;

pulse: [2]Pulse = .{ .{ .channel = 0 }, .{ .channel = 1 } },
triangle: Triangle = .{},
noise: Noise = .{},
status: u8 = 0,
sample_accum: u32 = 0,
frame_cycle_accum: u32 = 0,
frame_step: u3 = 0,
frame_mode_5_step: bool = false,
frame_irq_inhibit: bool = false,
frame_irq_pending: bool = false,
pulse_noise_clock: bool = false,
high_pass: DcBlocker = .{},
low_pass: OnePoleLowPass = .{},
samples: [max_samples]f32 = [_]f32{0} ** max_samples,
sample_count: usize = 0,

pub fn writeRegister(self: *Apu, addr: u16, value: u8) void {
    switch (addr) {
        0x4000...0x4003 => self.pulse[0].write(addr & 0x0003, value),
        0x4004...0x4007 => self.pulse[1].write(addr & 0x0003, value),
        0x4008...0x400b => self.triangle.write(addr & 0x0003, value),
        0x400c...0x400f => self.noise.write(addr & 0x0003, value),
        0x4010...0x4013 => {},
        0x4015 => self.writeStatus(value),
        0x4017 => {
            self.frame_mode_5_step = (value & 0x80) != 0;
            self.frame_irq_inhibit = (value & 0x40) != 0;
            if (self.frame_irq_inhibit) self.frame_irq_pending = false;
            self.frame_step = 0;
            self.frame_cycle_accum = 0;
            if (self.frame_mode_5_step) {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            }
        },
        else => {},
    }
}

pub fn readStatus(self: *Apu) u8 {
    const status = (if (self.pulse[0].length_counter != 0) @as(u8, 0x01) else 0) |
        (if (self.pulse[1].length_counter != 0) @as(u8, 0x02) else 0) |
        (if (self.triangle.length_counter != 0) @as(u8, 0x04) else 0) |
        (if (self.noise.length_counter != 0) @as(u8, 0x08) else 0) |
        (if (self.frame_irq_pending) @as(u8, 0x40) else 0);
    self.frame_irq_pending = false;
    return status;
}

pub fn tick(self: *Apu, cpu_cycles: u32) []const f32 {
    self.sample_count = 0;

    var i: u32 = 0;
    while (i < cpu_cycles) : (i += 1) {
        self.clockCpuCycle();
        self.sample_accum += sample_rate;
        if (self.sample_accum >= cpu_rate and self.sample_count < self.samples.len) {
            self.sample_accum -= cpu_rate;
            self.samples[self.sample_count] = self.outputSample();
            self.sample_count += 1;
        }
    }

    return self.samples[0..self.sample_count];
}

pub fn pollIrq(self: *const Apu) bool {
    return self.frame_irq_pending;
}

fn writeStatus(self: *Apu, value: u8) void {
    self.status = value & 0x1f;
    self.pulse[0].enabled = (self.status & 0x01) != 0;
    self.pulse[1].enabled = (self.status & 0x02) != 0;
    self.triangle.enabled = (self.status & 0x04) != 0;
    self.noise.enabled = (self.status & 0x08) != 0;

    if (!self.pulse[0].enabled) self.pulse[0].length_counter = 0;
    if (!self.pulse[1].enabled) self.pulse[1].length_counter = 0;
    if (!self.triangle.enabled) self.triangle.length_counter = 0;
    if (!self.noise.enabled) self.noise.length_counter = 0;
}

fn clockCpuCycle(self: *Apu) void {
    self.triangle.clockTimer();

    self.pulse_noise_clock = !self.pulse_noise_clock;
    if (self.pulse_noise_clock) {
        self.pulse[0].clockTimer();
        self.pulse[1].clockTimer();
        self.noise.clockTimer();
    }

    self.frame_cycle_accum += 1;
    if (self.frame_cycle_accum >= frame_period) {
        self.frame_cycle_accum -= frame_period;
        self.clockFrameSequencer();
    }
}

fn clockFrameSequencer(self: *Apu) void {
    self.clockQuarterFrame();
    if (self.frame_step == 1 or self.frame_step == 3) {
        self.clockHalfFrame();
    }
    if (!self.frame_mode_5_step and self.frame_step == 3 and !self.frame_irq_inhibit) {
        self.frame_irq_pending = true;
    }

    const modulo: u3 = if (self.frame_mode_5_step) 5 else 4;
    self.frame_step += 1;
    if (self.frame_step >= modulo) self.frame_step = 0;
}

fn clockQuarterFrame(self: *Apu) void {
    self.pulse[0].envelope.clock();
    self.pulse[1].envelope.clock();
    self.noise.envelope.clock();
    self.triangle.clockLinear();
}

fn clockHalfFrame(self: *Apu) void {
    self.pulse[0].clockLength();
    self.pulse[1].clockLength();
    self.pulse[0].clockSweep();
    self.pulse[1].clockSweep();
    self.triangle.clockLength();
    self.noise.clockLength();
}

fn outputSample(self: *Apu) f32 {
    const mixed = mixNes(
        self.pulse[0].output(),
        self.pulse[1].output(),
        self.triangle.output(),
        self.noise.output(),
    );
    const without_dc = self.high_pass.process(mixed);
    return std.math.clamp(self.low_pass.process(without_dc) * 1.6, -1.0, 1.0);
}

fn mixNes(pulse1: u4, pulse2: u4, triangle: u4, noise: u4) f32 {
    const pulse_sum = @as(f32, @floatFromInt(pulse1)) + @as(f32, @floatFromInt(pulse2));
    const tnd_sum = @as(f32, @floatFromInt(triangle)) / 8227.0 +
        @as(f32, @floatFromInt(noise)) / 12241.0;

    const pulse_out: f32 = if (pulse_sum == 0) 0 else 95.88 / ((8128.0 / pulse_sum) + 100.0);
    const tnd_out: f32 = if (tnd_sum == 0) 0 else 159.79 / ((1.0 / tnd_sum) + 100.0);
    return pulse_out + tnd_out;
}

test "4-step frame counter raises and status read clears frame IRQ" {
    var apu = Apu{};
    _ = apu.tick(frame_period * 4);

    try std.testing.expect(apu.pollIrq());
    try std.testing.expectEqual(@as(u8, 0x40), apu.readStatus() & 0x40);
    try std.testing.expect(!apu.pollIrq());
}

test "frame IRQ inhibit clears and suppresses frame IRQ" {
    var apu = Apu{};
    apu.writeRegister(0x4017, 0x40);
    _ = apu.tick(frame_period * 4);

    try std.testing.expect(!apu.pollIrq());
    try std.testing.expectEqual(@as(u8, 0), apu.readStatus() & 0x40);
}
