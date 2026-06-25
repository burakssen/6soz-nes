const cartridge = @import("cartridge.zig");

const Unrom512 = @This();

const prg_bank_size = 16 * 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
mirroring_mode: cartridge.Mirroring,

prg_bank: u8 = 0,

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
        },
        else => {},
    }
}

pub fn chrRead(self: *const Unrom512, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    return self.chr[addr % self.chr.len];
}

pub fn chrWrite(self: *Unrom512, addr: u16, val: u8) void {
    if (self.chr_is_ram and self.chr.len > 0) {
        self.chr[addr % self.chr.len] = val;
    }
}

pub fn mirroring(self: *const Unrom512) cartridge.Mirroring {
    return self.mirroring_mode;
}
