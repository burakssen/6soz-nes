const std = @import("std");

const Ppu = @import("ppu");
const Apu = @import("apu");

const Cartridge = @import("cartridge");

const Bus = @This();

// NES RAM: 2KB mirrored
ram: [2048]u8 = [_]u8{0} ** 2048,

mapper: ?*Cartridge.Mapper = null,

ppu: *Ppu,
apu: ?*Apu = null,

controller_state: [2]u8 = [_]u8{ 0, 0 },
controller_shift: [2]u8 = [_]u8{ 0, 0 },
controller_reads: [2]u8 = [_]u8{ 0, 0 },
controller_strobe: bool = false,

dma_stall_cycles: u16 = 0,
cpu_cycle_is_odd: bool = false,

pub fn read(self: *Bus, addr: u16) u8 {
    return switch (addr) {
        // RAM (0x0000 - 0x1FFF, mirrored every 0x0800)
        0x0000...0x1fff => self.ram[addr & 0x07ff],

        // PPU Registers (0x2000 - 0x3FFF, mirrored every 8 bytes)
        0x2000...0x3fff => self.ppu.readRegister(addr),

        // APU & I/O
        0x4016 => blk: {
            const bit = self.readControllerBit(0);
            break :blk 0x40 | bit;
        },
        0x4017 => blk: {
            const bit = self.readControllerBit(1);
            break :blk 0x40 | bit;
        },
        0x4015 => if (self.apu) |apu| apu.readStatus() else 0,
        0x4000...0x4014 => 0,

        // Cartridge space ($4020 - $FFFF)
        0x4020...0xffff => if (self.mapper) |m| m.prgRead(addr) else 0,

        else => 0,
    };
}

pub fn write(self: *Bus, addr: u16, value: u8) void {
    switch (addr) {
        0x0000...0x1fff => self.ram[addr & 0x07ff] = value,
        0x2000...0x3fff => self.ppu.writeRegister(addr, value),
        0x4014 => {
            const base = @as(u16, value) << 8;
            var i: u16 = 0;
            while (i < 256) : (i += 1) {
                self.ppu.oam[(self.ppu.oam_addr +% @as(u8, @truncate(i)))] = self.read(base + i);
            }
            self.dma_stall_cycles += 513 + @as(u16, @intFromBool(self.cpu_cycle_is_odd));
        },
        0x4016 => {
            self.controller_strobe = (value & 1) != 0;
            if (self.controller_strobe) {
                self.controller_shift[0] = self.controller_state[0];
                self.controller_shift[1] = self.controller_state[1];
                self.controller_reads = .{ 0, 0 };
            }
        },
        0x4000...0x4013, 0x4015, 0x4017 => {
            if (self.apu) |apu| apu.writeRegister(addr, value);
        },
        0x4020...0xffff => if (self.mapper) |m| m.prgWrite(addr, value),
        else => {},
    }
}

pub fn load(self: *Bus, start: u16, bytes: []const u8) void {
    for (bytes, 0..) |b, i| {
        self.write(start +% @as(u16, @intCast(i)), b);
    }
}

pub fn setControllerState(self: *Bus, player: usize, state: u8) void {
    if (player < self.controller_state.len) {
        self.controller_state[player] = state;
        if (self.controller_strobe) self.controller_shift[player] = state;
    }
}

pub fn takeDmaStallCycles(self: *Bus) u16 {
    const cycles = self.dma_stall_cycles;
    self.dma_stall_cycles = 0;
    return cycles;
}

pub fn setCpuCycleParity(self: *Bus, cycles: u64) void {
    self.cpu_cycle_is_odd = (cycles & 1) != 0;
}

fn readControllerBit(self: *Bus, player: usize) u8 {
    if (self.controller_strobe) return self.controller_state[player] & 1;
    if (self.controller_reads[player] >= 8) return 1;

    const bit = self.controller_shift[player] & 1;
    self.controller_shift[player] >>= 1;
    self.controller_reads[player] += 1;
    return bit;
}

test "mirrors 2KB internal RAM" {
    var ppu = Ppu{};
    var bus = Bus{ .ppu = &ppu };

    bus.write(0x0002, 0x44);
    try std.testing.expectEqual(@as(u8, 0x44), bus.read(0x0802));
    try std.testing.expectEqual(@as(u8, 0x44), bus.read(0x1802));
}

test "mirrors 16KB NROM PRG ROM" {
    var ppu = Ppu{};
    var prg_rom: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    prg_rom[0] = 0xaa;
    prg_rom[0x3fff] = 0xbb;

    var nrom = Cartridge.Mapper{ .nrom = .{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = true,
        .mirroring_mode = .horizontal,
    } };

    var bus = Bus{
        .ppu = &ppu,
        .mapper = &nrom,
    };

    try std.testing.expectEqual(@as(u8, 0xaa), bus.read(0x8000));
    try std.testing.expectEqual(@as(u8, 0xaa), bus.read(0xc000));
    try std.testing.expectEqual(@as(u8, 0xbb), bus.read(0xbfff));
    try std.testing.expectEqual(@as(u8, 0xbb), bus.read(0xffff));
}

test "controller strobe latches and shifts button state" {
    var ppu = Ppu{};
    var bus = Bus{ .ppu = &ppu };
    bus.setControllerState(0, 0b1000_1001);

    bus.write(0x4016, 1);
    try std.testing.expectEqual(@as(u8, 0x41), bus.read(0x4016));
    try std.testing.expectEqual(@as(u8, 0x41), bus.read(0x4016));

    bus.write(0x4016, 0);
    const expected = [_]u8{ 1, 0, 0, 1, 0, 0, 0, 1 };
    for (expected) |bit| {
        try std.testing.expectEqual(@as(u8, 0x40 | bit), bus.read(0x4016));
    }
    try std.testing.expectEqual(@as(u8, 0x41), bus.read(0x4016));
    try std.testing.expectEqual(@as(u8, 0x41), bus.read(0x4016));
}

test "OAM DMA copies one CPU page and records stall cycles" {
    var ppu = Ppu{};
    var bus = Bus{ .ppu = &ppu };

    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        bus.write(0x0200 + i, @as(u8, @truncate(i)));
    }

    bus.write(0x4014, 0x02);

    try std.testing.expectEqual(@as(u8, 0x00), ppu.oam[0]);
    try std.testing.expectEqual(@as(u8, 0x7f), ppu.oam[0x7f]);
    try std.testing.expectEqual(@as(u8, 0xff), ppu.oam[0xff]);
    try std.testing.expectEqual(@as(u16, 513), bus.takeDmaStallCycles());
    try std.testing.expectEqual(@as(u16, 0), bus.takeDmaStallCycles());
}

test "OAM DMA records an extra stall cycle on odd CPU cycles" {
    var ppu = Ppu{};
    var bus = Bus{ .ppu = &ppu };
    bus.setCpuCycleParity(1);

    bus.write(0x4014, 0x02);

    try std.testing.expectEqual(@as(u16, 514), bus.takeDmaStallCycles());
}

test "APU status register is routed through NES bus" {
    var ppu = Ppu{};
    var apu = Apu{};
    var bus = Bus{
        .ppu = &ppu,
        .apu = &apu,
    };

    bus.write(0x4015, 0x05);
    bus.write(0x4003, 0x08);

    try std.testing.expectEqual(@as(u8, 0x01), bus.read(0x4015));
}
