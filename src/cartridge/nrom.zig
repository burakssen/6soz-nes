const cartridge = @import("cartridge.zig");

const Nrom = @This();

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
mirroring_mode: cartridge.Mirroring,

pub fn prgRead(self: *const Nrom, addr: u16) u8 {
    if (self.prg_rom.len == 0) return 0;
    const mask: u16 = if (self.prg_rom.len == 16384) 0x3fff else 0x7fff;
    return self.prg_rom[addr & mask];
}

pub fn prgWrite(_: *Nrom, _: u16, _: u8) void {}

pub fn chrRead(self: *const Nrom, addr: u16) u8 {
    if (self.chr.len > 0) return self.chr[addr % self.chr.len];
    return 0;
}

pub fn chrWrite(self: *Nrom, addr: u16, val: u8) void {
    if (self.chr_is_ram and self.chr.len > 0) {
        self.chr[addr % self.chr.len] = val;
    }
}

pub fn mirroring(self: *const Nrom) cartridge.Mirroring {
    return self.mirroring_mode;
}
