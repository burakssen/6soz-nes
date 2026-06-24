const cartridge = @import("cartridge.zig");
const std = @import("std");

const Cnrom = @This();

const prg_bank_size = 16 * 1024;
const chr_bank_size = 8 * 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
mirroring_mode: cartridge.Mirroring,

chr_bank: u8 = 0,

pub fn prgRead(self: *const Cnrom, addr: u16) u8 {
    if (self.prg_rom.len == 0) return 0;

    const offset = switch (addr) {
        0x8000...0xffff => addr - 0x8000,
        else => return 0,
    };

    return self.prg_rom[offset % self.prg_rom.len];
}

pub fn prgWrite(self: *Cnrom, addr: u16, val: u8) void {
    switch (addr) {
        0x8000...0xffff => self.chr_bank = val,
        else => {},
    }
}

pub fn chrRead(self: *const Cnrom, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    return self.chr[self.getChrAddr(addr)];
}

pub fn chrWrite(self: *Cnrom, addr: u16, val: u8) void {
    if (!self.chr_is_ram or self.chr.len == 0) return;
    self.chr[self.getChrAddr(addr)] = val;
}

pub fn mirroring(self: *const Cnrom) cartridge.Mirroring {
    return self.mirroring_mode;
}

fn getChrAddr(self: *const Cnrom, addr: u16) usize {
    const bank_count = @max(self.chr.len / chr_bank_size, 1);
    const bank = @as(usize, self.chr_bank) % bank_count;
    return bank * chr_bank_size + @as(usize, addr & 0x1fff);
}

test "CNROM reads fixed PRG ROM" {
    var prg_rom: [2 * prg_bank_size]u8 = [_]u8{0} ** (2 * prg_bank_size);
    prg_rom[0] = 0x12;
    prg_rom[prg_bank_size] = 0x34;

    var mapper = Cnrom{
        .prg_rom = &prg_rom,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .mirroring_mode = .vertical,
    };

    try std.testing.expectEqual(@as(u8, 0x12), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x34), mapper.prgRead(0xc000));
}

test "CNROM switches 8KB CHR banks" {
    var chr: [2 * chr_bank_size]u8 = [_]u8{0} ** (2 * chr_bank_size);
    chr[0] = 0x45;
    chr[chr_bank_size] = 0x67;

    var mapper = Cnrom{
        .prg_rom = &[_]u8{0} ** prg_bank_size,
        .chr = &chr,
        .chr_is_ram = false,
        .mirroring_mode = .horizontal,
    };

    try std.testing.expectEqual(@as(u8, 0x45), mapper.chrRead(0x0000));

    mapper.prgWrite(0x8000, 1);

    try std.testing.expectEqual(@as(u8, 0x67), mapper.chrRead(0x0000));
}

test "CNROM protects CHR ROM and writes CHR RAM" {
    var chr_rom: [chr_bank_size]u8 = [_]u8{0} ** chr_bank_size;
    var chr_ram: [chr_bank_size]u8 = [_]u8{0} ** chr_bank_size;

    var rom_mapper = Cnrom{
        .prg_rom = &[_]u8{0} ** prg_bank_size,
        .chr = &chr_rom,
        .chr_is_ram = false,
        .mirroring_mode = .horizontal,
    };
    rom_mapper.chrWrite(0x0010, 0xaa);
    try std.testing.expectEqual(@as(u8, 0), chr_rom[0x0010]);

    var ram_mapper = Cnrom{
        .prg_rom = &[_]u8{0} ** prg_bank_size,
        .chr = &chr_ram,
        .chr_is_ram = true,
        .mirroring_mode = .horizontal,
    };
    ram_mapper.chrWrite(0x0010, 0xbb);
    try std.testing.expectEqual(@as(u8, 0xbb), chr_ram[0x0010]);
}

test "CNROM reports header mirroring" {
    var mapper = Cnrom{
        .prg_rom = &[_]u8{0} ** prg_bank_size,
        .chr = &[_]u8{},
        .chr_is_ram = false,
        .mirroring_mode = .vertical,
    };

    try std.testing.expectEqual(cartridge.Mirroring.vertical, mapper.mirroring());
}
