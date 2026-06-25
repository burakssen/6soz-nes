const cartridge = @import("cartridge.zig");
const std = @import("std");

const Unrom512 = @This();

const prg_bank_size = 16 * 1024;
const chr_bank_size = 8 * 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
mirroring_mode: cartridge.Mirroring,

prg_bank: u8 = 0,
chr_bank: u2 = 0,

pub fn prgRead(self: *const Unrom512, addr: u16) u8 {
    if (self.prg_rom.len == 0) return 0;

    const num_banks = self.prg_rom.len / prg_bank_size;
    if (num_banks == 0) return 0;

    const bank = switch (addr) {
        0x8000...0xbfff => @as(usize, self.prg_bank & 0x1f) % num_banks,
        0xc000...0xffff => num_banks - 1,
        else => return 0,
    };
    return self.prg_rom[bank * prg_bank_size + (addr & 0x3fff)];
}

pub fn prgWrite(self: *Unrom512, addr: u16, val: u8) void {
    switch (addr) {
        0x8000...0xffff => {
            self.prg_bank = val & 0x1f;
            self.mirroring_mode = if ((val & 0x20) != 0) .single_screen_upper else .single_screen_lower;
            self.chr_bank = @truncate((val >> 6) & 0x03);
        },
        else => {},
    }
}

pub fn chrRead(self: *const Unrom512, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    return self.chr[self.getChrAddr(addr)];
}

pub fn chrWrite(self: *Unrom512, addr: u16, val: u8) void {
    if (self.chr_is_ram and self.chr.len > 0) {
        self.chr[self.getChrAddr(addr)] = val;
    }
}

pub fn mirroring(self: *const Unrom512) cartridge.Mirroring {
    return self.mirroring_mode;
}

fn getChrAddr(self: *const Unrom512, addr: u16) usize {
    const bank_count = @max(self.chr.len / chr_bank_size, 1);
    const bank = @as(usize, self.chr_bank) % bank_count;
    return bank * chr_bank_size + @as(usize, addr & 0x1fff);
}

test "UNROM-512 switches CHR RAM banks with register bits 6 and 7" {
    var chr: [4 * chr_bank_size]u8 = [_]u8{0} ** (4 * chr_bank_size);
    var mapper = Unrom512{
        .prg_rom = &[_]u8{0} ** prg_bank_size,
        .chr = &chr,
        .chr_is_ram = true,
        .mirroring_mode = .single_screen_lower,
    };

    mapper.chrWrite(0x0010, 0x10);
    mapper.prgWrite(0x8000, 0x40);
    mapper.chrWrite(0x0010, 0x40);
    mapper.prgWrite(0x8000, 0x80);
    mapper.chrWrite(0x0010, 0x80);
    mapper.prgWrite(0x8000, 0xc0);
    mapper.chrWrite(0x0010, 0xc0);

    mapper.prgWrite(0x8000, 0x00);
    try std.testing.expectEqual(@as(u8, 0x10), mapper.chrRead(0x0010));
    mapper.prgWrite(0x8000, 0x40);
    try std.testing.expectEqual(@as(u8, 0x40), mapper.chrRead(0x0010));
    mapper.prgWrite(0x8000, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), mapper.chrRead(0x0010));
    mapper.prgWrite(0x8000, 0xc0);
    try std.testing.expectEqual(@as(u8, 0xc0), mapper.chrRead(0x0010));
}

test "UNROM-512 keeps PRG bank and mirroring bits independent from CHR bank" {
    var prg_rom: [32 * prg_bank_size]u8 = [_]u8{0} ** (32 * prg_bank_size);
    prg_rom[3 * prg_bank_size] = 0x33;
    prg_rom[31 * prg_bank_size] = 0xff;
    var chr: [4 * chr_bank_size]u8 = [_]u8{0} ** (4 * chr_bank_size);
    chr[2 * chr_bank_size] = 0x82;

    var mapper = Unrom512{
        .prg_rom = &prg_rom,
        .chr = &chr,
        .chr_is_ram = true,
        .mirroring_mode = .single_screen_lower,
    };

    mapper.prgWrite(0x8000, 0x83);

    try std.testing.expectEqual(@as(u8, 0x33), mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0xff), mapper.prgRead(0xc000));
    try std.testing.expectEqual(@as(u8, 0x82), mapper.chrRead(0x0000));
    try std.testing.expectEqual(cartridge.Mirroring.single_screen_lower, mapper.mirroring());

    mapper.prgWrite(0x8000, 0x63);
    try std.testing.expectEqual(cartridge.Mirroring.single_screen_upper, mapper.mirroring());
}
