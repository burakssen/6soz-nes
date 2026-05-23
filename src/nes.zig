const std = @import("std");
const core = @import("core");

pub const Ppu = @import("ppu");
pub const Apu = @import("apu");

pub const Bus = @import("bus.zig");
pub const Cartridge = @import("cartridge");

const Nes = @This();

const max_frame_audio_samples = 4096;
const max_step_audio_samples = 256;

cpu: core.Cpu = .{},
bus: Bus,
ppu: Ppu = .{},
apu: Apu = .{},
input: Ppu.InputState = .{},
cart: ?Cartridge = null,
allocator: std.mem.Allocator,
frame_audio: [max_frame_audio_samples]f32 = [_]f32{0} ** max_frame_audio_samples,
frame_audio_count: usize = 0,
step_audio: [max_step_audio_samples]f32 = [_]f32{0} ** max_step_audio_samples,
step_audio_count: usize = 0,

pub fn init(allocator: std.mem.Allocator) Nes {
    return .{
        .cpu = .{ .decimal_disabled = true },
        .ppu = .{},
        .bus = .{ .ppu = undefined },
        .apu = .{},
        .allocator = allocator,
        .frame_audio = [_]f32{0} ** max_frame_audio_samples,
        .frame_audio_count = 0,
        .step_audio = [_]f32{0} ** max_step_audio_samples,
        .step_audio_count = 0,
    };
}

pub fn reset(self: *Nes) void {
    self.connectDevices();
    var cpu_bus = core.Bus.init(&self.bus);
    self.cpu.reset(&cpu_bus);
}

pub fn deinit(self: *Nes) void {
    if (self.cart) |*c| c.deinit(self.allocator);
    self.cart = null;
    self.bus.mapper = null;
    self.ppu.mapper = null;
}

pub fn load(self: *Nes, data: []const u8) !void {
    if (self.cart) |*c| c.deinit(self.allocator);
    self.cart = null;
    self.bus.mapper = null;
    self.ppu.mapper = null;

    var cartridge = try Cartridge.load(self.allocator, data);
    errdefer cartridge.deinit(self.allocator);

    self.cart = cartridge;
    self.connectDevices();
}

pub fn step(self: *Nes) !Ppu.StepResult {
    self.connectDevices();
    self.latchInput();
    self.step_audio_count = 0;
    var cpu_bus = core.Bus.init(&self.bus);
    self.bus.setCpuCycleParity(self.cpu.cycles);
    const cpu_cycles = try self.cpu.step(&cpu_bus);
    const dma_cycles = self.bus.takeDmaStallCycles();
    var total_cpu_cycles = @as(u32, cpu_cycles);
    total_cpu_cycles += dma_cycles;
    self.cpu.cycles += dma_cycles;

    total_cpu_cycles += self.advanceDevices(@as(u32, cpu_cycles), &cpu_bus);
    if (dma_cycles > 0) total_cpu_cycles += self.advanceDevices(dma_cycles, &cpu_bus);

    const mapper_irq = if (self.cart) |*c| c.mapper.irqActive() else false;
    if (self.apu.pollIrq() or mapper_irq) {
        const irq_cycles = self.cpu.irq(&cpu_bus);
        if (irq_cycles > 0) {
            total_cpu_cycles += irq_cycles;
            if (mapper_irq) self.cart.?.mapper.acknowledgeIrq();
            total_cpu_cycles += self.advanceDevices(irq_cycles, &cpu_bus);
        }
    }
    const frame_complete = self.ppu.takeFrameComplete();

    return .{
        .cycles = total_cpu_cycles,
        .audio = self.step_audio[0..self.step_audio_count],
        .frame_complete = frame_complete,
    };
}

pub fn stepFrame(self: *Nes) !Ppu.StepResult {
    self.frame_audio_count = 0;
    var frame_cycles: u32 = 0;

    while (true) {
        const result = try self.step();
        frame_cycles += result.cycles;
        self.appendFrameAudio(result.audio);

        if (result.frame_complete) {
            return .{
                .cycles = frame_cycles,
                .audio = self.frame_audio[0..self.frame_audio_count],
                .frame_complete = true,
            };
        }
    }
}

pub fn setInput(self: *Nes, input: Ppu.InputState) void {
    self.input = input;
}

pub fn framebuffer(self: *const Nes) []const u32 {
    return &self.ppu.framebuffer;
}

pub fn saveRam(self: *const Nes) ?[]const u8 {
    if (self.cart) |*c| return c.saveRam();
    return null;
}

pub fn loadSaveRam(self: *Nes, data: []const u8) !void {
    if (self.cart) |*c| return c.loadSaveRam(data);
    return error.NoCartridgeLoaded;
}

fn latchInput(self: *Nes) void {
    self.bus.setControllerState(0, self.input.toNesControllerByte());
}

fn appendFrameAudio(self: *Nes, audio: []const f32) void {
    const available = self.frame_audio.len - self.frame_audio_count;
    const count = @min(available, audio.len);
    @memcpy(self.frame_audio[self.frame_audio_count..][0..count], audio[0..count]);
    self.frame_audio_count += count;
}

fn appendStepAudio(self: *Nes, audio: []const f32) void {
    const available = self.step_audio.len - self.step_audio_count;
    const count = @min(available, audio.len);
    @memcpy(self.step_audio[self.step_audio_count..][0..count], audio[0..count]);
    self.step_audio_count += count;
}

fn advanceDevices(self: *Nes, cycles: u32, cpu_bus: *core.Bus) u32 {
    var extra_cycles: u32 = 0;
    var pending = cycles;

    while (pending > 0) {
        var i: u32 = 0;
        while (i < pending * 3) : (i += 1) {
            if (self.ppu.tick()) {
                const nmi_cycles = self.cpu.nmi(cpu_bus);
                extra_cycles += nmi_cycles;
                pending += nmi_cycles;
            }
        }

        const reader = Apu.MemoryReader.init(&self.bus);
        const apu_result = self.apu.tickWithMemory(pending, reader);
        self.appendStepAudio(apu_result.audio);

        pending = apu_result.dmc_stall_cycles;
        if (pending > 0) {
            self.cpu.cycles += pending;
            extra_cycles += pending;
        }
    }

    return extra_cycles;
}

fn connectDevices(self: *Nes) void {
    self.bus.ppu = &self.ppu;
    self.bus.apu = &self.apu;
    if (self.cart) |*c| {
        self.bus.mapper = &c.mapper;
        self.ppu.mapper = &c.mapper;
    }
}

fn makeTestRom(allocator: std.mem.Allocator, flags6: u8, chr_banks: u8) ![]u8 {
    const prg_size = 16 * 1024;
    const chr_size = @as(usize, chr_banks) * 8 * 1024;
    const trainer_size: usize = if ((flags6 & 0x04) != 0) 512 else 0;
    const prg_start = 16 + trainer_size;
    const chr_start = prg_start + prg_size;

    const data = try allocator.alloc(u8, chr_start + chr_size);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = chr_banks;
    data[6] = flags6;

    data[prg_start] = 0xea;
    data[prg_start + 0x3ffc] = 0x00;
    data[prg_start + 0x3ffd] = 0x80;
    return data;
}

fn makeMapper1TestRom(allocator: std.mem.Allocator) ![]u8 {
    const prg_size = 128 * 1024;
    const data = try allocator.alloc(u8, 16 + prg_size);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x12;
    data[16 + 0x3ffc] = 0x00;
    data[16 + 0x3ffd] = 0x80;
    return data;
}

test "NES loads, resets, steps, and exposes framebuffer" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();
    const result = try nes.step();

    try std.testing.expect(result.cycles > 0);
    try std.testing.expect(!result.frame_complete);
    try std.testing.expectEqual(@as(usize, Ppu.Video.width * Ppu.Video.height), nes.framebuffer().len);
}

test "NES steps a complete frame" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();

    const result = try nes.stepFrame();

    try std.testing.expect(result.frame_complete);
    try std.testing.expect(result.cycles > 0);
    try std.testing.expect(result.audio.len > 0);
    try std.testing.expectEqual(@as(usize, Ppu.Video.width * Ppu.Video.height), nes.framebuffer().len);
}

test "NES stepFrame resets frame audio between frames" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();

    const first = try nes.stepFrame();
    const first_audio_len = first.audio.len;
    const second = try nes.stepFrame();

    try std.testing.expect(first.frame_complete);
    try std.testing.expect(second.frame_complete);
    try std.testing.expect(first_audio_len > 0);
    try std.testing.expect(second.audio.len > 0);
    try std.testing.expect(second.audio.len < max_frame_audio_samples);
}

test "NES loads CHR RAM cartridges" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 0);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    try std.testing.expect(nes.cart.?.mapper.nrom.chr_is_ram);
    try std.testing.expectEqual(@as(usize, 8 * 1024), nes.cart.?.chr.len);
}

test "NES rejects four-screen mirroring until implemented" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x08, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try std.testing.expectError(error.UnsupportedMirroring, nes.load(rom));
}

test "NES exposes save RAM written through cartridge space" {
    const allocator = std.testing.allocator;
    const rom = try makeMapper1TestRom(allocator);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.bus.write(0x6000, 0x5a);
    nes.bus.write(0x7fff, 0xa5);

    const save = nes.saveRam().?;
    try std.testing.expectEqual(@as(usize, 8192), save.len);
    try std.testing.expectEqual(@as(u8, 0x5a), save[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), save[0x1fff]);
}

test "NES imports save RAM into loaded cartridge" {
    const allocator = std.testing.allocator;
    const rom = try makeMapper1TestRom(allocator);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);

    var save: [8192]u8 = [_]u8{0} ** 8192;
    save[0] = 0x44;
    save[0x1fff] = 0x88;

    try nes.loadSaveRam(&save);

    try std.testing.expectEqual(@as(u8, 0x44), nes.bus.read(0x6000));
    try std.testing.expectEqual(@as(u8, 0x88), nes.bus.read(0x7fff));
}

test "NES save RAM API handles missing cartridge and missing RAM" {
    const allocator = std.testing.allocator;
    var nes = Nes.init(allocator);
    defer nes.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), nes.saveRam());
    try std.testing.expectError(error.NoCartridgeLoaded, nes.loadSaveRam(&[_]u8{}));

    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    try nes.load(rom);
    try std.testing.expectEqual(@as(?[]const u8, null), nes.saveRam());
    try std.testing.expectError(error.NoSaveRam, nes.loadSaveRam(&[_]u8{}));
}
