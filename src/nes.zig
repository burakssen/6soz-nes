const std = @import("std");
const core = @import("core");

pub const Ppu = @import("ppu");
pub const Apu = @import("apu");

pub const Bus = @import("bus.zig");
pub const Cartridge = @import("cartridge.zig");

const Nes = @This();

cpu: core.Cpu = .{},
bus: Bus,
ppu: Ppu = .{},
apu: Apu = .{},
input: Ppu.InputState = .{},
cart: ?Cartridge = null,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Nes {
    return .{
        .cpu = .{ .decimal_disabled = true },
        .ppu = .{},
        .bus = .{ .ppu = undefined },
        .apu = .{},
        .allocator = allocator,
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
    self.bus.prg_rom = &.{};
    self.ppu.chr = &.{};
    self.ppu.chr_is_ram = false;
}

pub fn load(self: *Nes, data: []const u8) !void {
    if (self.cart) |*c| c.deinit(self.allocator);
    self.cart = null;
    self.bus.prg_rom = &.{};
    self.ppu.chr = &.{};
    self.ppu.chr_is_ram = false;

    var cartridge = try Cartridge.load(self.allocator, data);
    errdefer cartridge.deinit(self.allocator);

    if (cartridge.mirroring == .four_screen) return error.UnsupportedMirroring;

    self.bus.prg_rom = cartridge.prg_rom;
    self.ppu.chr = cartridge.chr;
    self.ppu.chr_is_ram = cartridge.chr_is_ram;
    self.ppu.mirroring = switch (cartridge.mirroring) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .four_screen => unreachable,
    };
    self.cart = cartridge;
}

pub fn step(self: *Nes) !Ppu.StepResult {
    self.connectDevices();
    self.latchInput();
    var cpu_bus = core.Bus.init(&self.bus);
    const cpu_cycles = try self.cpu.step(&cpu_bus);
    const dma_cycles = self.bus.takeDmaStallCycles();
    const total_cpu_cycles = @as(u32, cpu_cycles) + dma_cycles;
    self.cpu.cycles += dma_cycles;

    var i: u32 = 0;
    while (i < total_cpu_cycles * 3) : (i += 1) {
        if (self.ppu.tick()) {
            self.cpu.nmi(&cpu_bus);
        }
    }

    return .{
        .cycles = total_cpu_cycles,
        .audio = self.apu.tick(total_cpu_cycles),
    };
}

pub fn setInput(self: *Nes, input: Ppu.InputState) void {
    self.input = input;
}

pub fn framebuffer(self: *const Nes) []const u32 {
    return &self.ppu.framebuffer;
}

fn latchInput(self: *Nes) void {
    self.bus.setControllerState(0, self.input.toNesControllerByte());
}

fn connectDevices(self: *Nes) void {
    self.bus.ppu = &self.ppu;
    self.bus.apu = &self.apu;
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
    try std.testing.expectEqual(@as(usize, Ppu.Video.width * Ppu.Video.height), nes.framebuffer().len);
}

test "NES loads CHR RAM cartridges" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 0);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    try std.testing.expect(nes.ppu.chr_is_ram);
    try std.testing.expectEqual(@as(usize, 8 * 1024), nes.ppu.chr.len);
}

test "NES rejects four-screen mirroring until implemented" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x08, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try std.testing.expectError(error.UnsupportedMirroring, nes.load(rom));
}
