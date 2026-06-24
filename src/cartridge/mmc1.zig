const cartridge = @import("cartridge.zig");
const std = @import("std");

const Mmc1 = @This();

const prg_bank_size = 16 * 1024;
const chr_bank_size = 4 * 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
prg_ram: []u8,

shift_value: u5 = 0,
shift_count: u3 = 0,

control: u5 = 0x0c,
chr_bank0: u5 = 0,
chr_bank1: u5 = 0,
prg_bank: u5 = 0,

pub fn prgRead(self: *const Mmc1, addr: u16) u8 {
    switch (addr) {
        0x6000...0x7fff => {
            if (self.prg_ram.len == 0) return 0;
            return self.prg_ram[(addr - 0x6000) % self.prg_ram.len];
        },
        0x8000...0xffff => {
            if (self.prg_rom.len == 0) return 0;
            return self.prg_rom[self.getPrgAddr(addr)];
        },
        else => return 0,
    }
}

pub fn prgWrite(self: *Mmc1, addr: u16, val: u8) void {
    switch (addr) {
        0x6000...0x7fff => {
            if (self.prg_ram.len > 0) {
                self.prg_ram[(addr - 0x6000) % self.prg_ram.len] = val;
            }
        },
        0x8000...0xffff => self.writeRegister(addr, val),
        else => {},
    }
}

pub fn chrRead(self: *const Mmc1, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    return self.chr[self.getChrAddr(addr) % self.chr.len];
}

pub fn chrWrite(self: *Mmc1, addr: u16, val: u8) void {
    if (!self.chr_is_ram or self.chr.len == 0) return;
    self.chr[self.getChrAddr(addr) % self.chr.len] = val;
}

pub fn mirroring(self: *const Mmc1) cartridge.Mirroring {
    return switch (self.control & 0x03) {
        0 => .single_screen_lower,
        1 => .single_screen_upper,
        2 => .vertical,
        3 => .horizontal,
        else => unreachable,
    };
}

fn writeRegister(self: *Mmc1, addr: u16, val: u8) void {
    if ((val & 0x80) != 0) {
        self.resetShift();
        self.control |= 0x0c;
        return;
    }

    self.shift_value |= @as(u5, @intCast(val & 1)) << self.shift_count;
    self.shift_count += 1;

    if (self.shift_count == 5) {
        self.commitRegister(addr, self.shift_value);
        self.resetShift();
    }
}

fn resetShift(self: *Mmc1) void {
    self.shift_value = 0;
    self.shift_count = 0;
}

fn commitRegister(self: *Mmc1, addr: u16, val: u5) void {
    switch (addr) {
        0x8000...0x9fff => self.control = val,
        0xa000...0xbfff => self.chr_bank0 = val,
        0xc000...0xdfff => self.chr_bank1 = val,
        0xe000...0xffff => self.prg_bank = val,
        else => {},
    }
}

fn getPrgAddr(self: *const Mmc1, addr: u16) usize {
    const bank_count = self.prg_rom.len / prg_bank_size;
    if (bank_count == 0) return 0;

    const offset = @as(usize, addr & 0x3fff);
    const prg_mode = (self.control >> 2) & 0x03;
    const bank = switch (prg_mode) {
        0, 1 => @as(usize, self.prg_bank & 0x0e) + @as(usize, (addr - 0x8000) / prg_bank_size),
        2 => if (addr < 0xc000) @as(usize, 0) else @as(usize, self.prg_bank),
        3 => if (addr < 0xc000) @as(usize, self.prg_bank) else bank_count - 1,
        else => unreachable,
    };

    return (bank % bank_count) * prg_bank_size + offset;
}

fn getChrAddr(self: *const Mmc1, addr: u16) usize {
    const chr_mode = (self.control >> 4) & 1;
    if (chr_mode == 0) {
        const bank = @as(usize, self.chr_bank0 & 0x1e);
        return bank * chr_bank_size + addr;
    }

    const bank = if (addr < 0x1000)
        @as(usize, self.chr_bank0)
    else
        @as(usize, self.chr_bank1);
    return bank * chr_bank_size + (addr & 0x0fff);
}

fn writeSerial(mapper: *Mmc1, addr: u16, val: u5) void {
    var i: u3 = 0;
    while (i < 5) : (i += 1) {
        mapper.prgWrite(addr, @as(u8, @intCast((val >> i) & 1)));
    }
}

test "MMC1 commits serial register after five writes" {
    var mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0x8000, 0x02);

    try std.testing.expectEqual(@as(u5, 0x02), mapper.control);
    try std.testing.expectEqual(cartridge.Mirroring.vertical, mapper.mirroring());
}

test "MMC1 reset clears shift register and forces PRG mode bits" {
    var mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
        .control = 0,
    };

    mapper.prgWrite(0x8000, 1);
    mapper.prgWrite(0x8000, 0x80);

    try std.testing.expectEqual(@as(u5, 0), mapper.shift_value);
    try std.testing.expectEqual(@as(u3, 0), mapper.shift_count);
    try std.testing.expectEqual(@as(u5, 0x0c), mapper.control);
}

test "MMC1 PRG mode 3 fixes last bank and switches low bank" {
    var prg_rom: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    for (0..8) |bank| {
        prg_rom[bank * prg_bank_size] = @as(u8, @intCast(0x20 + bank));
    }

    var mapper = Mmc1{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0xe000, 3);

    try std.testing.expectEqual(@as(u8, 0x23), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x27), mapper.prgRead(0xc000));
}

test "MMC1 PRG mode 2 fixes first bank and switches high bank" {
    var prg_rom: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    for (0..8) |bank| {
        prg_rom[bank * prg_bank_size] = @as(u8, @intCast(0x30 + bank));
    }

    var mapper = Mmc1{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0x8000, 0x08);
    writeSerial(&mapper, 0xe000, 4);

    try std.testing.expectEqual(@as(u8, 0x30), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x34), mapper.prgRead(0xc000));
}

test "MMC1 PRG 32KB mode switches paired banks" {
    var prg_rom: [128 * 1024]u8 = [_]u8{0} ** (128 * 1024);
    for (0..8) |bank| {
        prg_rom[bank * prg_bank_size] = @as(u8, @intCast(0x40 + bank));
    }

    var mapper = Mmc1{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0x8000, 0x00);
    writeSerial(&mapper, 0xe000, 5);

    try std.testing.expectEqual(@as(u8, 0x44), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x45), mapper.prgRead(0xc000));
}

test "MMC1 protects CHR ROM and writes CHR RAM" {
    var chr_rom: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var chr_ram: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);

    var rom_mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr_rom,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };
    rom_mapper.chrWrite(0x0010, 0xaa);
    try std.testing.expectEqual(@as(u8, 0), chr_rom[0x0010]);

    var ram_mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr_ram,
        .chr_is_ram = true,
        .prg_ram = &[_]u8{},
    };
    ram_mapper.chrWrite(0x0010, 0xbb);
    try std.testing.expectEqual(@as(u8, 0xbb), chr_ram[0x0010]);
}

test "MMC1 switches CHR banks in 4KB and 8KB modes" {
    var chr: [16 * 1024]u8 = [_]u8{0} ** (16 * 1024);
    for (0..4) |bank| {
        chr[bank * chr_bank_size] = @as(u8, @intCast(0x50 + bank));
    }

    var mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0x8000, 0x10);
    writeSerial(&mapper, 0xa000, 1);
    writeSerial(&mapper, 0xc000, 3);

    try std.testing.expectEqual(@as(u8, 0x51), mapper.chrRead(0x0000));
    try std.testing.expectEqual(@as(u8, 0x53), mapper.chrRead(0x1000));

    writeSerial(&mapper, 0x8000, 0x00);
    writeSerial(&mapper, 0xa000, 2);

    try std.testing.expectEqual(@as(u8, 0x52), mapper.chrRead(0x0000));
    try std.testing.expectEqual(@as(u8, 0x53), mapper.chrRead(0x1000));
}

test "MMC1 reports all mirroring modes" {
    var mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    };

    writeSerial(&mapper, 0x8000, 0x00);
    try std.testing.expectEqual(cartridge.Mirroring.single_screen_lower, mapper.mirroring());

    writeSerial(&mapper, 0x8000, 0x01);
    try std.testing.expectEqual(cartridge.Mirroring.single_screen_upper, mapper.mirroring());

    writeSerial(&mapper, 0x8000, 0x02);
    try std.testing.expectEqual(cartridge.Mirroring.vertical, mapper.mirroring());

    writeSerial(&mapper, 0x8000, 0x03);
    try std.testing.expectEqual(cartridge.Mirroring.horizontal, mapper.mirroring());
}

test "MMC1 PRG RAM reads and writes" {
    var prg_ram: [8192]u8 = [_]u8{0} ** 8192;
    var mapper = Mmc1{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .prg_ram = &prg_ram,
    };

    mapper.prgWrite(0x6000, 0xab);
    mapper.prgWrite(0x7fff, 0xcd);

    try std.testing.expectEqual(@as(u8, 0xab), mapper.prgRead(0x6000));
    try std.testing.expectEqual(@as(u8, 0xcd), mapper.prgRead(0x7fff));
}
