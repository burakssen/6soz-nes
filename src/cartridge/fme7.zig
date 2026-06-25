const cartridge = @import("cartridge.zig");

const Fme7 = @This();

const prg_bank_size = 8 * 1024;
const chr_bank_size = 1024;

prg_rom: []const u8,
chr: []u8,
chr_is_ram: bool,
prg_ram: []u8,

command: u4 = 0,
chr_banks: [8]u8 = [_]u8{0} ** 8,
prg_ram_control: u8 = 0,
prg_banks: [3]u8 = [_]u8{ 0, 1, 2 },
mirroring_mode: cartridge.Mirroring,
irq_control: u8 = 0,
irq_counter: u16 = 0,

pub fn prgRead(self: *const Fme7, addr: u16) u8 {
    return switch (addr) {
        0x6000...0x7fff => blk: {
            if ((self.prg_ram_control & 0xc0) == 0xc0 and self.prg_ram.len > 0) {
                break :blk self.prg_ram[(addr - 0x6000) % self.prg_ram.len];
            }
            break :blk self.readPrgBank(self.prg_ram_control & 0x3f, addr);
        },
        0x8000...0x9fff => self.readPrgBank(self.prg_banks[0], addr),
        0xa000...0xbfff => self.readPrgBank(self.prg_banks[1], addr),
        0xc000...0xdfff => self.readPrgBank(self.prg_banks[2], addr),
        0xe000...0xffff => self.readPrgBank(0xff, addr),
        else => 0,
    };
}

pub fn prgWrite(self: *Fme7, addr: u16, val: u8) void {
    switch (addr) {
        0x6000...0x7fff => {
            if ((self.prg_ram_control & 0xc0) == 0xc0 and self.prg_ram.len > 0) {
                self.prg_ram[(addr - 0x6000) % self.prg_ram.len] = val;
            }
        },
        0x8000...0x9fff => self.command = @truncate(val & 0x0f),
        0xa000...0xbfff => self.writeCommandValue(val),
        else => {},
    }
}

pub fn chrRead(self: *const Fme7, addr: u16) u8 {
    if (self.chr.len == 0) return 0;
    const bank_index = (addr & 0x1fff) / chr_bank_size;
    const bank_count = self.chr.len / chr_bank_size;
    if (bank_count == 0) return 0;
    const bank = @as(usize, self.chr_banks[bank_index]) % bank_count;
    return self.chr[bank * chr_bank_size + (addr & 0x03ff)];
}

pub fn chrWrite(self: *Fme7, addr: u16, val: u8) void {
    if (!self.chr_is_ram or self.chr.len == 0) return;
    const bank_index = (addr & 0x1fff) / chr_bank_size;
    const bank_count = self.chr.len / chr_bank_size;
    if (bank_count == 0) return;
    const bank = @as(usize, self.chr_banks[bank_index]) % bank_count;
    self.chr[bank * chr_bank_size + (addr & 0x03ff)] = val;
}

pub fn mirroring(self: *const Fme7) cartridge.Mirroring {
    return self.mirroring_mode;
}

fn readPrgBank(self: *const Fme7, bank_value: u8, addr: u16) u8 {
    const bank_count = self.prg_rom.len / prg_bank_size;
    if (bank_count == 0) return 0;
    const bank = if (bank_value == 0xff)
        bank_count - 1
    else
        @as(usize, bank_value & 0x3f) % bank_count;
    return self.prg_rom[bank * prg_bank_size + (addr & 0x1fff)];
}

fn writeCommandValue(self: *Fme7, val: u8) void {
    switch (self.command) {
        0x0...0x7 => self.chr_banks[self.command] = val,
        0x8 => self.prg_ram_control = val,
        0x9 => self.prg_banks[0] = val & 0x3f,
        0xa => self.prg_banks[1] = val & 0x3f,
        0xb => self.prg_banks[2] = val & 0x3f,
        0xc => self.mirroring_mode = switch (val & 0x03) {
            0 => .vertical,
            1 => .horizontal,
            2 => .single_screen_lower,
            3 => .single_screen_upper,
            else => unreachable,
        },
        0xd => self.irq_control = val,
        0xe => self.irq_counter = (self.irq_counter & 0xff00) | val,
        0xf => self.irq_counter = (self.irq_counter & 0x00ff) | (@as(u16, val) << 8),
    }
}
