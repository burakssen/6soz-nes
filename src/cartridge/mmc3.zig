const common = @import("common.zig");
const std = @import("std");

const Mmc3 = @This();

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
prg_ram: []u8,

bank_select: u8 = 0,
bank_registers: [8]u8 = [_]u8{0} ** 8,
mirroring_mode: common.Mirroring = .horizontal,
prg_ram_protect: u8 = 0,

irq_latch: u8 = 0,
irq_counter: u8 = 0,
irq_reload: bool = false,
irq_enabled: bool = false,
irq_active: bool = false,

last_a12: bool = false,

pub fn prgRead(self: *const Mmc3, addr: u16) u8 {
    switch (addr) {
        0x6000...0x7fff => {
            if (self.prg_ram.len > 0 and (self.prg_ram_protect & 0x80) != 0) {
                return self.prg_ram[addr - 0x6000];
            }
            return 0;
        },
        0x8000...0x9fff => return self.prg_rom[self.getPrgAddr(0, addr)],
        0xa000...0xbfff => return self.prg_rom[self.getPrgAddr(1, addr)],
        0xc000...0xdfff => return self.prg_rom[self.getPrgAddr(2, addr)],
        0xe000...0xffff => return self.prg_rom[self.getPrgAddr(3, addr)],
        else => return 0,
    }
}

pub fn prgWrite(self: *Mmc3, addr: u16, val: u8) void {
    switch (addr) {
        0x6000...0x7fff => {
            if (self.prg_ram.len > 0 and (self.prg_ram_protect & 0x80) != 0 and (self.prg_ram_protect & 0x40) == 0) {
                self.prg_ram[addr - 0x6000] = val;
            }
        },
        0x8000...0x9fff => {
            if (addr & 1 == 0) {
                self.bank_select = val;
            } else {
                const bank = self.bank_select & 0x07;
                self.bank_registers[bank] = val;
            }
        },
        0xa000...0xbfff => {
            if (addr & 1 == 0) {
                self.mirroring_mode = if (val & 1 == 0) .vertical else .horizontal;
            } else {
                self.prg_ram_protect = val;
            }
        },
        0xc000...0xdfff => {
            if (addr & 1 == 0) {
                self.irq_latch = val;
            } else {
                self.irq_reload = true;
            }
        },
        0xe000...0xffff => {
            if (addr & 1 == 0) {
                self.irq_enabled = false;
                self.irq_active = false;
            } else {
                self.irq_enabled = true;
            }
        },
        else => {},
    }
}

pub fn chrRead(self: *Mmc3, addr: u16) u8 {
    self.updateIrq(addr);
    if (self.chr.len == 0) return 0;
    const bank_addr = self.getChrAddr(addr);
    return self.chr[bank_addr % self.chr.len];
}

pub fn chrWrite(self: *Mmc3, addr: u16, val: u8) void {
    self.updateIrq(addr);
    if (!self.chr_is_ram or self.chr.len == 0) return;
    const bank_addr = self.getChrAddr(addr);
    self.chr[bank_addr % self.chr.len] = val;
}

pub fn mirroring(self: *const Mmc3) common.Mirroring {
    return self.mirroring_mode;
}

fn getPrgAddr(self: *const Mmc3, slot: u2, addr: u16) usize {
    const num_banks = self.prg_rom.len / 8192;
    const bank: usize = switch (slot) {
        0 => if (self.bank_select & 0x40 == 0) self.bank_registers[6] else num_banks - 2,
        1 => self.bank_registers[7],
        2 => if (self.bank_select & 0x40 == 0) num_banks - 2 else self.bank_registers[6],
        3 => num_banks - 1,
    };
    return (bank % num_banks) * 8192 + (addr & 0x1fff);
}

fn getChrAddr(self: *const Mmc3, addr: u16) usize {
    const bank: usize = if (self.bank_select & 0x80 == 0) switch (addr) {
        0x0000...0x07ff => self.bank_registers[0] & 0xfe,
        0x0800...0x0fff => self.bank_registers[1] & 0xfe,
        0x1000...0x13ff => self.bank_registers[2],
        0x1400...0x17ff => self.bank_registers[3],
        0x1800...0x1bff => self.bank_registers[4],
        0x1c00...0x1fff => self.bank_registers[5],
        else => unreachable,
    } else switch (addr) {
        0x0000...0x03ff => self.bank_registers[2],
        0x0400...0x07ff => self.bank_registers[3],
        0x0800...0x0bff => self.bank_registers[4],
        0x0c00...0x0fff => self.bank_registers[5],
        0x1000...0x17ff => self.bank_registers[0] & 0xfe,
        0x1800...0x1fff => self.bank_registers[1] & 0xfe,
        else => unreachable,
    };

    const page_size: usize = if (self.bank_select & 0x80 == 0)
        if (addr < 0x1000) @as(usize, 2048) else 1024
    else if (addr < 0x1000) @as(usize, 1024) else 2048;

    const offset = addr % page_size;
    return bank * 1024 + offset;
}

fn updateIrq(self: *Mmc3, addr: u16) void {
    const a12 = (addr & 0x1000) != 0;
    if (a12 and !self.last_a12) {
        if (self.irq_counter == 0 or self.irq_reload) {
            self.irq_counter = self.irq_latch;
            self.irq_reload = false;
        } else {
            self.irq_counter -= 1;
        }

        if (self.irq_counter == 0 and self.irq_enabled) {
            self.irq_active = true;
        }
    }
    self.last_a12 = a12;
}

test "MMC3 switches PRG banks" {
    var prg_rom: [32 * 1024]u8 = [_]u8{0} ** (32 * 1024);
    for (0..4) |bank| {
        prg_rom[bank * 8192] = @as(u8, @intCast(0x10 + bank));
    }

    var mapper = Mmc3{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    mapper.prgWrite(0x8000, 6);
    mapper.prgWrite(0x8001, 1);

    try std.testing.expectEqual(@as(u8, 0x11), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x12), mapper.prgRead(0xc000));
    try std.testing.expectEqual(@as(u8, 0x13), mapper.prgRead(0xe000));

    mapper.prgWrite(0x8000, 0x46);

    try std.testing.expectEqual(@as(u8, 0x12), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x11), mapper.prgRead(0xc000));
}

test "MMC3 switches CHR banks" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    chr[3 * 1024] = 0x33;

    var mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    mapper.prgWrite(0x8000, 2);
    mapper.prgWrite(0x8001, 3);

    try std.testing.expectEqual(@as(u8, 0x33), mapper.chrRead(0x1000));
}

test "MMC3 updates mirroring from register writes" {
    var mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    mapper.prgWrite(0xa000, 0);
    try std.testing.expectEqual(common.Mirroring.vertical, mapper.mirroring());

    mapper.prgWrite(0xa000, 1);
    try std.testing.expectEqual(common.Mirroring.horizontal, mapper.mirroring());
}

test "MMC3 gates PRG RAM reads and writes" {
    var prg_ram: [8192]u8 = [_]u8{0} ** 8192;
    var mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &prg_ram,
    };

    mapper.prgWrite(0x6000, 0xaa);
    try std.testing.expectEqual(@as(u8, 0), mapper.prgRead(0x6000));

    mapper.prgWrite(0xa001, 0x80);
    mapper.prgWrite(0x6000, 0xaa);
    try std.testing.expectEqual(@as(u8, 0xaa), mapper.prgRead(0x6000));

    mapper.prgWrite(0xa001, 0xc0);
    mapper.prgWrite(0x6000, 0xbb);
    try std.testing.expectEqual(@as(u8, 0xaa), mapper.prgRead(0x6000));
}

test "MMC3 protects CHR ROM and writes CHR RAM" {
    var chr_rom: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);

    var rom_mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr_rom,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };
    rom_mapper.chrWrite(0x0010, 0xaa);
    try std.testing.expectEqual(@as(u8, 0), chr_rom[0x0010]);

    var ram_mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr_ram,
        .chr_is_ram = true,
        .prg_ram = &[_]u8{},
    };
    ram_mapper.chrWrite(0x0010, 0xbb);
    try std.testing.expectEqual(@as(u8, 0xbb), chr_ram[0x0010]);
}

test "MMC3 raises and clears IRQ on A12 edges" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var mapper = Mmc3{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    mapper.prgWrite(0xc000, 1);
    mapper.prgWrite(0xe001, 0);

    _ = mapper.chrRead(0x1000);
    try std.testing.expect(!mapper.irq_active);

    _ = mapper.chrRead(0x0000);
    _ = mapper.chrRead(0x1000);
    try std.testing.expect(mapper.irq_active);

    mapper.prgWrite(0xe000, 0);
    try std.testing.expect(!mapper.irq_active);
}
