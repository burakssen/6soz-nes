const cartridge = @import("cartridge.zig");
const std = @import("std");

const Uxrom = @This();

const prg_bank_size = 16 * 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
mirroring_mode: cartridge.Mirroring,

prg_bank: u8 = 0,

pub fn prgRead(self: *const Uxrom, addr: u16) u8 {
    if (self.prg_rom.len == 0) return 0;

    switch (addr) {
        0x8000...0xbfff => {
            const num_banks = self.prg_rom.len / prg_bank_size;
            if (num_banks == 0) return 0;
            const bank = @as(usize, self.prg_bank) % num_banks;
            const offset = bank * prg_bank_size + (addr - 0x8000);
            return self.prg_rom[offset];
        },
        0xc000...0xffff => {
            const num_banks = self.prg_rom.len / prg_bank_size;
            if (num_banks == 0) return 0;
            const bank = num_banks - 1;
            const offset = bank * prg_bank_size + (addr - 0xc000);
            return self.prg_rom[offset];
        },
        else => return 0,
    }
}

pub fn prgWrite(self: *Uxrom, addr: u16, val: u8) void {
    switch (addr) {
        0x8000...0xffff => {
            self.prg_bank = val;
        },
        else => {},
    }
}

pub fn chrRead(self: *const Uxrom, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    return self.chr[addr % self.chr.len];
}

pub fn chrWrite(self: *Uxrom, addr: u16, val: u8) void {
    if (self.chr_is_ram and self.chr.len > 0) {
        self.chr[addr % self.chr.len] = val;
    }
}

pub fn mirroring(self: *const Uxrom) cartridge.Mirroring {
    return self.mirroring_mode;
}
