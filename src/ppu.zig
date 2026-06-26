const std = @import("std");

pub const Video = struct {
    pub const width = 256;
    pub const height = 240;
    pub const Pixel = u32;
    pub const Framebuffer = [width * height]Pixel;
};

pub const InputState = struct {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn toNesControllerByte(self: InputState) u8 {
        return (if (self.a) @as(u8, 1) else 0) |
            (if (self.b) @as(u8, 2) else 0) |
            (if (self.select) @as(u8, 4) else 0) |
            (if (self.start) @as(u8, 8) else 0) |
            (if (self.up) @as(u8, 16) else 0) |
            (if (self.down) @as(u8, 32) else 0) |
            (if (self.left) @as(u8, 64) else 0) |
            (if (self.right) @as(u8, 128) else 0);
    }
};
pub const StepResult = struct {
    cycles: u32,
    audio: []const f32 = &.{},
    frame_complete: bool = false,
};

const Cartridge = @import("cartridge");

const Ppu = @This();
const Timing = @import("timing");

pub const Mirroring = enum {
    horizontal,
    vertical,
};

// 2KB VRAM for Nametables
vram: [2048]u8 = [_]u8{0} ** 2048,
// 256 bytes for Sprites (OAM)
oam: [256]u8 = [_]u8{0} ** 256,
// 32 bytes for Palettes
palette: [32]u8 = [_]u8{0} ** 32,

mapper: ?*Cartridge.Mapper = null,

// Registers
ctrl: u8 = 0, // $2000
mask: u8 = 0, // $2001
status: u8 = 0, // $2002
oam_addr: u8 = 0, // $2003

// Internal state for $2005/$2006 access
v: u16 = 0, // Current VRAM address (15 bits)
t: u16 = 0, // Temporary VRAM address (15 bits)
x: u3 = 0, // Fine X scroll (3 bits)
w: bool = false, // First or second write toggle (1 bit)

// Data buffer for $2007 reads
data_buffer: u8 = 0,

cycles: u32 = 0,
scanline: i16 = 0,
nmi_occurred: bool = false,
frame_complete: bool = false,
timing: Timing = Timing.ntsc,

// Background fetch buffers
bg_next_nametable: u8 = 0,
bg_next_attribute: u8 = 0,
bg_next_low_tile: u8 = 0,
bg_next_high_tile: u8 = 0,

// Background shift registers
bg_shifter_tile_lo: u16 = 0,
bg_shifter_tile_hi: u16 = 0,
bg_shifter_attrib_lo: u16 = 0,
bg_shifter_attrib_hi: u16 = 0,

framebuffer: Video.Framebuffer = [_]u32{0} ** (Video.width * Video.height),
display_buffer: Video.Framebuffer = [_]u32{0} ** (Video.width * Video.height),

scanline_sprites: [8]usize = [_]usize{0} ** 8,
scanline_sprite_count: u4 = 0,
scanline_sprite_patterns_lo: [8]u8 = [_]u8{0} ** 8,
scanline_sprite_patterns_hi: [8]u8 = [_]u8{0} ** 8,

pub fn displayFramebuffer(self: *Ppu) []const u32 {
    const src = &self.framebuffer;
    const dst = &self.display_buffer;
    const row_width: usize = Video.width;
    const crop: usize = 8;
    const display_width: usize = row_width - crop * 2;
    for (0..Video.height) |row| {
        const src_row = src[row * row_width + crop ..];
        const dst_row = dst[row * display_width ..];
        @memcpy(dst_row[0..display_width], src_row[0..display_width]);
    }
    return dst[0 .. display_width * Video.height];
}

pub fn readRegister(self: *Ppu, addr: u16) u8 {
    return switch (registerAddr(addr)) {
        0x2002 => {
            const res = self.status;
            self.status &= 0x7F; // Clear VBlank flag on read
            self.w = false; // Reset toggle
            return res;
        },
        0x2004 => self.oam[self.oam_addr],
        0x2007 => {
            var res = self.data_buffer;
            self.data_buffer = self.vramRead(self.v);
            if ((self.v & 0x3FFF) >= 0x3F00) {
                res = self.data_buffer;
                self.data_buffer = self.vramRead(0x2000 | (self.v & 0x0FFF));
            }
            self.v +%= if ((self.ctrl & 0x04) != 0) @as(u16, 32) else @as(u16, 1);
            return res;
        },
        else => 0,
    };
}

pub fn writeRegister(self: *Ppu, addr: u16, val: u8) void {
    switch (registerAddr(addr)) {
        0x2000 => {
            const was_nmi_enabled = (self.ctrl & 0x80) != 0;
            self.ctrl = val;
            self.t = (self.t & 0xF3FF) | (@as(u16, val & 0x03) << 10);
            if (!was_nmi_enabled and (val & 0x80) != 0 and (self.status & 0x80) != 0) {
                self.nmi_occurred = true;
            }
        },
        0x2001 => {
            self.mask = val;
        },
        0x2003 => self.oam_addr = val,
        0x2004 => {
            self.oam[self.oam_addr] = val;
            self.oam_addr +%= 1;
        },
        0x2005 => {
            if (!self.w) {
                self.t = (self.t & 0x7FE0) | (val >> 3);
                self.x = @as(u3, @truncate(val & 0x07));
                self.w = true;
            } else {
                self.t = (self.t & 0x0C1F) | (@as(u16, val & 0x07) << 12) | (@as(u16, val & 0xF8) << 2);
                self.w = false;
            }
        },
        0x2006 => {
            if (!self.w) {
                self.t = (self.t & 0x00FF) | (@as(u16, val & 0x3F) << 8);
                self.w = true;
            } else {
                self.t = (self.t & 0xFF00) | val;
                self.v = self.t;
                self.w = false;
            }
        },
        0x2007 => {
            self.vramWrite(self.v, val);
            self.v +%= if ((self.ctrl & 0x04) != 0) @as(u16, 32) else @as(u16, 1);
        },
        else => {},
    }
}

fn mirrorAddr(self: *const Ppu, addr: u16) u16 {
    const a = addr & 0x0FFF;
    const mirroring_mode = if (self.mapper) |m| m.mirroring() else .horizontal;
    return switch (mirroring_mode) {
        .single_screen_lower => a & 0x03FF,
        .single_screen_upper => 0x0400 | (a & 0x03FF),
        .horizontal => if (a < 0x0800) a & 0x03FF else 0x0400 | (a & 0x03FF),
        .vertical => a & 0x07FF,
        .four_screen => unreachable,
    };
}

fn vramRead(self: *Ppu, addr: u16) u8 {
    const a = addr & 0x3FFF;
    if (a < 0x2000) {
        if (self.mapper) |m| return m.chrRead(a);
        return 0;
    }
    if (a < 0x3F00) return self.vram[self.mirrorAddr(a)];
    if (a < 0x4000) {
        return self.palette[paletteIndex(a)];
    }
    return 0;
}

fn fetchPattern(self: *Ppu, addr: u16) u8 {
    self.notifyPatternAddress(addr);
    return self.vramRead(addr);
}

fn notifyPatternAddress(self: *Ppu, addr: u16) void {
    if (self.mapper) |m| m.ppuA12(addr & 0x3FFF);
}

fn vramWrite(self: *Ppu, addr: u16, val: u8) void {
    const a = addr & 0x3FFF;
    if (a < 0x2000) {
        if (self.mapper) |m| m.chrWrite(a, val);
    } else if (a < 0x3F00) {
        self.vram[self.mirrorAddr(a)] = val;
    } else if (a < 0x4000) {
        self.palette[paletteIndex(a)] = val;
    }
}

fn paletteIndex(addr: u16) u16 {
    var idx = addr & 0x1F;
    if (idx == 0x10 or idx == 0x14 or idx == 0x18 or idx == 0x1C) idx -= 0x10;
    return idx;
}

fn registerAddr(addr: u16) u16 {
    return 0x2000 + (addr & 0x0007);
}

pub fn tick(self: *Ppu) bool {
    return self.tickWithOddFrameSkip(false);
}

pub fn tickWithOddFrameSkip(self: *Ppu, skip_odd_frame_dot: bool) bool {
    if (self.scanline >= -1 and self.scanline < 240) {
        if (self.scanline == -1 and self.cycles == 1) {
            self.status &= 0x1F; // Clear flags
        }

        if (self.cycles == 257) {
            const next_scanline = self.scanline + 1;
            if (next_scanline >= 0 and next_scanline < 240) {
                self.evaluateSpriteOverflow(@as(u16, @intCast(next_scanline)));
            } else {
                self.scanline_sprite_count = 0;
            }
        }

        if ((self.cycles >= 2 and self.cycles < 258) or (self.cycles >= 321 and self.cycles < 338)) {
            self.updateShifters();

            switch ((self.cycles - 1) % 8) {
                0 => {
                    self.loadShifters();
                    self.bg_next_nametable = self.vramRead(0x2000 | (self.v & 0x0FFF));
                },
                2 => {
                    self.bg_next_attribute = self.vramRead(0x23C0 | (self.v & 0x0C00) | ((self.v >> 4) & 0x38) | ((self.v >> 2) & 0x07));
                    if ((self.v & 0x40) != 0) self.bg_next_attribute >>= 4;
                    if ((self.v & 0x02) != 0) self.bg_next_attribute >>= 2;
                    self.bg_next_attribute &= 0x03;
                },
                4 => {
                    const bank: u16 = if ((self.ctrl & 0x10) != 0) 0x1000 else 0;
                    self.bg_next_low_tile = self.fetchPattern(bank + (@as(u16, self.bg_next_nametable) << 4) + ((self.v >> 12) & 0x07));
                },
                6 => {
                    const bank: u16 = if ((self.ctrl & 0x10) != 0) 0x1000 else 0;
                    self.bg_next_high_tile = self.fetchPattern(bank + (@as(u16, self.bg_next_nametable) << 4) + ((self.v >> 12) & 0x07) + 8);
                },
                7 => {
                    self.incrementScrollX();
                },
                else => {},
            }
        }

        if (self.cycles == 256) self.incrementScrollY();
        if (self.cycles == 257) self.transferAddressX();
        if (self.scanline == -1 and self.cycles >= 280 and self.cycles < 305) self.transferAddressY();
        self.notifySpritePatternFetch();
    }

    if (self.scanline == 241 and self.cycles == 1) {
        self.status |= 0x80;
        if ((self.ctrl & 0x80) != 0) self.nmi_occurred = true;
    }

    if (self.scanline >= 0 and self.scanline < 240 and self.cycles >= 1 and self.cycles <= 256) {
        self.drawPixel();
    }

    self.cycles += 1;
    if (skip_odd_frame_dot and self.scanline == -1 and self.cycles == 340 and self.timing.region == .ntsc and (self.mask & 0x18) != 0) {
        self.cycles = 0;
        self.scanline = 0;
    }
    if (self.cycles >= 341) {
        self.cycles = 0;
        self.scanline += 1;
        if (self.scanline >= @as(i16, @intCast(self.timing.ppu_scanlines - 1))) {
            self.scanline = -1;
            self.frame_complete = true;
        }
    }

    const nmi = self.nmi_occurred;
    self.nmi_occurred = false;
    return nmi;
}

pub fn takeFrameComplete(self: *Ppu) bool {
    const completed = self.frame_complete;
    self.frame_complete = false;
    return completed;
}

fn updateShifters(self: *Ppu) void {
    if ((self.mask & 0x08) != 0) {
        self.bg_shifter_tile_lo <<= 1;
        self.bg_shifter_tile_hi <<= 1;
        self.bg_shifter_attrib_lo <<= 1;
        self.bg_shifter_attrib_hi <<= 1;
    }
}

fn loadShifters(self: *Ppu) void {
    self.bg_shifter_tile_lo = (self.bg_shifter_tile_lo & 0xFF00) | self.bg_next_low_tile;
    self.bg_shifter_tile_hi = (self.bg_shifter_tile_hi & 0xFF00) | self.bg_next_high_tile;
    self.bg_shifter_attrib_lo = (self.bg_shifter_attrib_lo & 0xFF00) | (if ((self.bg_next_attribute & 0x01) != 0) @as(u16, 0xFF) else @as(u16, 0));
    self.bg_shifter_attrib_hi = (self.bg_shifter_attrib_hi & 0xFF00) | (if ((self.bg_next_attribute & 0x02) != 0) @as(u16, 0xFF) else @as(u16, 0));
}

fn incrementScrollX(self: *Ppu) void {
    if ((self.mask & 0x18) == 0) return;
    if ((self.v & 0x001F) == 31) {
        self.v &= ~@as(u16, 0x001F);
        self.v ^= 0x0400;
    } else {
        self.v += 1;
    }
}

fn incrementScrollY(self: *Ppu) void {
    if ((self.mask & 0x18) == 0) return;
    if ((self.v & 0x7000) != 0x7000) {
        self.v += 0x1000;
    } else {
        self.v &= ~@as(u16, 0x7000);
        var y = (self.v & 0x03E0) >> 5;
        if (y == 29) {
            y = 0;
            self.v ^= 0x0800;
        } else if (y == 31) {
            y = 0;
        } else {
            y += 1;
        }
        self.v = (self.v & ~@as(u16, 0x03E0)) | (y << 5);
    }
}

fn transferAddressX(self: *Ppu) void {
    if ((self.mask & 0x18) == 0) return;
    self.v = (self.v & 0xFBE0) | (self.t & 0x041F);
}

fn transferAddressY(self: *Ppu) void {
    if ((self.mask & 0x18) == 0) return;
    self.v = (self.v & 0x041F) | (self.t & 0x7BE0);
}

fn drawPixel(self: *Ppu) void {
    const x_pos = @as(u16, @intCast(self.cycles - 1));
    const y_pos = @as(u16, @intCast(self.scanline));
    self.framebuffer[@as(usize, y_pos) * Video.width + x_pos] = self.renderPixel(x_pos, y_pos);
}

fn renderPixel(self: *Ppu, x_pos: u16, y_pos: u16) u32 {
    var bg_pixel: u8 = 0;
    var bg_palette: u8 = 0;
    if ((self.mask & 0x08) != 0 and (x_pos >= 8 or (self.mask & 0x02) != 0)) {
        const bit_mux = @as(u16, 0x8000) >> self.x;
        const p0 = if ((self.bg_shifter_tile_lo & bit_mux) != 0) @as(u8, 1) else @as(u8, 0);
        const p1 = if ((self.bg_shifter_tile_hi & bit_mux) != 0) @as(u8, 1) else @as(u8, 0);
        bg_pixel = (p1 << 1) | p0;

        const a0 = if ((self.bg_shifter_attrib_lo & bit_mux) != 0) @as(u8, 1) else @as(u8, 0);
        const a1 = if ((self.bg_shifter_attrib_hi & bit_mux) != 0) @as(u8, 1) else @as(u8, 0);
        bg_palette = (a1 << 1) | a0;
    }

    const sprite = if (self.scanline_sprite_count > 0) self.spritePixel(x_pos, y_pos) else SpritePixel{};
    if (sprite.zero_hit and bg_pixel != 0 and sprite.pixel != 0 and x_pos < 255) {
        self.status |= 0x40;
    }

    const use_sprite = sprite.pixel != 0 and (bg_pixel == 0 or sprite.in_front);
    const palette_addr = if (use_sprite)
        0x3F10 + (@as(u16, sprite.palette) << 2) + sprite.pixel
    else if (bg_pixel == 0)
        0x3F00
    else
        0x3F00 + (@as(u16, bg_palette) << 2) + bg_pixel;
    const color = self.vramRead(palette_addr);
    return palette_table[color & 0x3F];
}

fn notifySpritePatternFetch(self: *Ppu) void {
    if ((self.mask & 0x18) == 0) return;
    if (self.cycles < 257 or self.cycles > 320) return;

    const fetch_cycle = (self.cycles - 257) % 8;
    if (fetch_cycle != 3 and fetch_cycle != 5) return;

    const slot = @as(usize, (self.cycles - 257) / 8);
    const base_addr = self.spriteFetchPatternAddress(slot);
    const addr = base_addr + if (fetch_cycle == 5) @as(u16, 8) else @as(u16, 0);
    self.notifyPatternAddress(addr);
}

const SpritePixel = struct {
    pixel: u8 = 0,
    palette: u8 = 0,
    in_front: bool = true,
    zero_hit: bool = false,
};

fn spritePixel(self: *Ppu, x_pos: u16, y_pos: u16) SpritePixel {
    _ = y_pos;
    if ((self.mask & 0x10) == 0) return .{};
    if (x_pos < 8 and (self.mask & 0x04) == 0) return .{};

    var slot: usize = 0;
    while (slot < self.scanline_sprite_count) : (slot += 1) {
        const i = self.scanline_sprites[slot];
        const base = i * 4;

        const sprite_x = self.oam[base + 3];
        if (x_pos < sprite_x or x_pos >= @as(u16, sprite_x) + 8) continue;

        const attr = self.oam[base + 2];
        var tile_col = @as(u8, @intCast(x_pos - sprite_x));
        if ((attr & 0x40) != 0) tile_col = 7 - tile_col;

        const lo = self.scanline_sprite_patterns_lo[slot];
        const hi = self.scanline_sprite_patterns_hi[slot];
        const shift = @as(u3, @intCast(7 - tile_col));
        const pixel = ((hi >> shift) & 1) << 1 | ((lo >> shift) & 1);
        if (pixel == 0) continue;

        return .{
            .pixel = pixel,
            .palette = attr & 0x03,
            .in_front = (attr & 0x20) == 0,
            .zero_hit = i == 0,
        };
    }

    return .{};
}

fn spritePatternAddress(self: *const Ppu, tile: u8, row: u8) u16 {
    if ((self.ctrl & 0x20) == 0) {
        const bank: u16 = if ((self.ctrl & 0x08) != 0) 0x1000 else 0;
        return bank + (@as(u16, tile) << 4) + row;
    }

    const bank: u16 = @as(u16, tile & 1) * 0x1000;
    const tile_base = @as(u16, tile & 0xfe) << 4;
    const tile_offset: u16 = if (row >= 8) 16 else 0;
    return bank + tile_base + tile_offset + (row & 0x07);
}

fn spriteFetchPatternAddress(self: *const Ppu, slot: usize) u16 {
    if (self.scanline < 0) return self.dummySpritePatternAddress();
    if (slot >= self.scanline_sprite_count) return self.dummySpritePatternAddress();

    const i = self.scanline_sprites[slot];
    const base = i * 4;
    const sprite_height: i16 = if ((self.ctrl & 0x20) != 0) 16 else 8;
    const sprite_y = @as(i16, self.oam[base]) + 1;
    const row = self.scanline - sprite_y;
    if (row < 0 or row >= sprite_height) return self.dummySpritePatternAddress();

    const attr = self.oam[base + 2];
    var tile_row = @as(u8, @intCast(row));
    if ((attr & 0x80) != 0) tile_row = @as(u8, @intCast(sprite_height - 1)) - tile_row;
    return self.spritePatternAddress(self.oam[base + 1], tile_row);
}

fn dummySpritePatternAddress(self: *const Ppu) u16 {
    if ((self.ctrl & 0x20) != 0) return 0x1FE0;
    const bank: u16 = if ((self.ctrl & 0x08) != 0) 0x1000 else 0;
    return bank + 0x0FF0;
}

fn evaluateSpriteOverflow(self: *Ppu, y_pos: u16) void {
    const sprite_height: i16 = if ((self.ctrl & 0x20) != 0) 16 else 8;
    var visible: u8 = 0;
    self.scanline_sprite_count = 0;

    for (0..64) |i| {
        const sprite_y = @as(i16, self.oam[i * 4]) + 1;
        const row = @as(i16, @intCast(y_pos)) - sprite_y;
        if (row >= 0 and row < sprite_height) {
            visible += 1;
            if (self.scanline_sprite_count < self.scanline_sprites.len) {
                const slot = @as(usize, self.scanline_sprite_count);
                self.scanline_sprites[slot] = i;

                // Prefetch pattern bytes for this sprite
                const base = i * 4;
                const attr = self.oam[base + 2];
                var tile_row = @as(u8, @intCast(row));
                if ((attr & 0x80) != 0) tile_row = @as(u8, @intCast(sprite_height - 1)) - tile_row;

                const tile_addr = self.spritePatternAddress(self.oam[base + 1], tile_row);
                self.scanline_sprite_patterns_lo[slot] = self.vramRead(tile_addr);
                self.scanline_sprite_patterns_hi[slot] = self.vramRead(tile_addr + 8);

                self.scanline_sprite_count += 1;
            }
            if (visible > 8) {
                self.status |= 0x20;
            }
        }
    }
}

const palette_table = [64]u32{
    0x545454, 0x001e74, 0x081090, 0x300088, 0x440064, 0x5c0030, 0x540400, 0x3c1800, 0x202a00, 0x083a00, 0x004000, 0x003c00, 0x00323c, 0x000000, 0x000000, 0x000000,
    0x989698, 0x084cc4, 0x3032ec, 0x5c1ee4, 0x8814b0, 0xa01464, 0x982220, 0x783c00, 0x545a00, 0x287200, 0x087c00, 0x007628, 0x006678, 0x000000, 0x000000, 0x000000,
    0xeceeee, 0x4c9aec, 0x787cec, 0xb062ec, 0xe454ec, 0xec58b4, 0xec6a64, 0xd48820, 0xa0aa00, 0x74c400, 0x4cd020, 0x38cc6c, 0x38b4cc, 0x3c3c3c, 0x000000, 0x000000,
    0xeff0f0, 0xa8c9f0, 0xc0c1f0, 0xd8b5f0, 0xefb1f0, 0xefb5de, 0xefbdc0, 0xe7d1a0, 0xd8d9a0, 0xc8e1a0, 0xb8e9b0, 0xafefc8, 0xafe5f0, 0xb2b2b2, 0x000000, 0x000000,
};

test "PPU register addresses mirror every 8 bytes" {
    var ppu = Ppu{};

    ppu.writeRegister(0x2008, 0x80);
    try std.testing.expectEqual(@as(u8, 0x80), ppu.ctrl);

    ppu.status = 0xff;
    try std.testing.expectEqual(@as(u8, 0xff), ppu.readRegister(0x3ffa));
    try std.testing.expectEqual(@as(u8, 0x7f), ppu.status);
}

test "CHR RAM is writable through PPU pattern memory" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var nrom = Cartridge.Mapper{ .nrom = .{
        .prg_rom = &[_]u8{},
        .chr = &chr,
        .chr_is_ram = true,
        .mirroring_mode = .horizontal,
    } };
    var ppu = Ppu{
        .mapper = &nrom,
    };

    ppu.writeRegister(0x2006, 0x00);
    ppu.writeRegister(0x2006, 0x10);
    ppu.writeRegister(0x2007, 0xab);

    try std.testing.expectEqual(@as(u8, 0xab), chr[0x0010]);
}

test "CHR ROM ignores writes through PPU pattern memory" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var nrom = Cartridge.Mapper{ .nrom = .{
        .prg_rom = &[_]u8{},
        .chr = &chr,
        .chr_is_ram = false,
        .mirroring_mode = .horizontal,
    } };
    var ppu = Ppu{
        .mapper = &nrom,
    };

    ppu.writeRegister(0x2006, 0x00);
    ppu.writeRegister(0x2006, 0x10);
    ppu.writeRegister(0x2007, 0xab);

    try std.testing.expectEqual(@as(u8, 0), chr[0x0010]);
}

test "palette background entries mirror to universal background color" {
    var ppu = Ppu{};

    ppu.writeRegister(0x2006, 0x3f);
    ppu.writeRegister(0x2006, 0x10);
    ppu.writeRegister(0x2007, 0x22);

    ppu.writeRegister(0x2006, 0x3f);
    ppu.writeRegister(0x2006, 0x00);
    try std.testing.expectEqual(@as(u8, 0x22), ppu.readRegister(0x2007));
}

test "PPU reports frame completion when scanline wraps" {
    var ppu = Ppu{
        .scanline = 260,
        .cycles = 340,
    };

    try std.testing.expect(!ppu.tick());
    try std.testing.expectEqual(@as(i16, -1), ppu.scanline);
    try std.testing.expectEqual(@as(u32, 0), ppu.cycles);
    try std.testing.expect(ppu.takeFrameComplete());
    try std.testing.expect(!ppu.takeFrameComplete());
}

test "NTSC PPU can skip odd frame prerender dot when rendering is enabled" {
    var ppu = Ppu{
        .mask = 0x08,
        .scanline = -1,
        .cycles = 339,
    };

    try std.testing.expect(!ppu.tickWithOddFrameSkip(true));
    try std.testing.expectEqual(@as(i16, 0), ppu.scanline);
    try std.testing.expectEqual(@as(u32, 0), ppu.cycles);
}

test "PPU does not skip prerender dot when rendering is disabled" {
    var ppu = Ppu{
        .scanline = -1,
        .cycles = 339,
    };

    try std.testing.expect(!ppu.tickWithOddFrameSkip(true));
    try std.testing.expectEqual(@as(i16, -1), ppu.scanline);
    try std.testing.expectEqual(@as(u32, 340), ppu.cycles);
}

test "PAL PPU does not skip odd frame prerender dot" {
    var ppu = Ppu{
        .mask = 0x08,
        .scanline = -1,
        .cycles = 339,
        .timing = Timing.pal,
    };

    try std.testing.expect(!ppu.tickWithOddFrameSkip(true));
    try std.testing.expectEqual(@as(i16, -1), ppu.scanline);
    try std.testing.expectEqual(@as(u32, 340), ppu.cycles);
}

test "PAL PPU wraps after 312 scanlines" {
    var ppu = Ppu{
        .scanline = 310,
        .cycles = 340,
        .timing = Timing.pal,
    };

    try std.testing.expect(!ppu.tick());
    try std.testing.expectEqual(@as(i16, -1), ppu.scanline);
    try std.testing.expect(ppu.takeFrameComplete());
}

test "PPU NMI and frame completion are separate signals" {
    var ppu = Ppu{
        .ctrl = 0x80,
        .scanline = 241,
        .cycles = 1,
    };

    try std.testing.expect(ppu.tick());
    try std.testing.expect(!ppu.takeFrameComplete());
}

test "PPU enables NMI during active vblank" {
    var ppu = Ppu{ .status = 0x80 };

    ppu.writeRegister(0x2000, 0x80);

    try std.testing.expect(ppu.tick());
}

test "palette reads fill buffer from mirrored nametable" {
    var ppu = Ppu{};
    ppu.vram[0x700] = 0x55;
    ppu.palette[0] = 0x22;

    ppu.writeRegister(0x2006, 0x3f);
    ppu.writeRegister(0x2006, 0x00);
    try std.testing.expectEqual(@as(u8, 0x22), ppu.readRegister(0x2007));

    ppu.writeRegister(0x2006, 0x20);
    ppu.writeRegister(0x2006, 0x01);
    try std.testing.expectEqual(@as(u8, 0x55), ppu.readRegister(0x2007));
}

test "sprite overflow flag is set when more than eight sprites cover a scanline" {
    var ppu = Ppu{};

    for (0..9) |i| {
        ppu.oam[i * 4] = 9;
        ppu.oam[i * 4 + 3] = @as(u8, @intCast(i * 8));
    }

    ppu.evaluateSpriteOverflow(10);

    try std.testing.expect((ppu.status & 0x20) != 0);
}

test "sprite renderer only considers first eight visible sprites" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    chr[0x10] = 0x80;
    var nrom = Cartridge.Mapper{ .nrom = .{
        .prg_rom = &[_]u8{},
        .chr = &chr,
        .chr_is_ram = false,
        .mirroring_mode = .horizontal,
    } };
    var ppu = Ppu{
        .mapper = &nrom,
        .mask = 0x10,
    };
    ppu.palette[0x11] = 0x01;

    for (0..9) |i| {
        ppu.oam[i * 4] = 9;
        ppu.oam[i * 4 + 1] = if (i == 8) 1 else 0;
        ppu.oam[i * 4 + 3] = 0;
    }

    ppu.evaluateSpriteOverflow(10);

    try std.testing.expectEqual(@as(u4, 8), ppu.scanline_sprite_count);
    try std.testing.expectEqual(palette_table[0], ppu.renderPixel(0, 10));
}

test "8x16 sprite pattern address uses tile bit zero as pattern table select" {
    var ppu = Ppu{ .ctrl = 0x20 };

    try std.testing.expectEqual(@as(u16, 0x0020), ppu.spritePatternAddress(0x02, 0));
    try std.testing.expectEqual(@as(u16, 0x0030), ppu.spritePatternAddress(0x02, 8));
    try std.testing.expectEqual(@as(u16, 0x1020), ppu.spritePatternAddress(0x03, 0));
    try std.testing.expectEqual(@as(u16, 0x1030), ppu.spritePatternAddress(0x03, 8));
}

test "sprite pattern fetches notify MMC3 A12 tracking" {
    var chr: [8 * 1024]u8 = [_]u8{0} ** (8 * 1024);
    var mapper = Cartridge.Mapper{ .mmc3 = .{
        .prg_rom = &[_]u8{0} ** (32 * 1024),
        .chr = &chr,
        .chr_is_ram = false,
        .prg_ram = &[_]u8{},
    } };
    var ppu = Ppu{
        .mapper = &mapper,
        .mask = 0x18,
        .ctrl = 0x08,
        .scanline = 0,
        .cycles = 260,
    };

    ppu.notifyPatternAddress(0x0000);
    ppu.notifyPatternAddress(0x0000);
    ppu.notifySpritePatternFetch();

    try std.testing.expect(mapper.mmc3.last_a12);
}

test "input state converts to NES controller byte order" {
    const input = InputState{
        .a = true,
        .start = true,
        .up = true,
        .right = true,
    };

    try std.testing.expectEqual(@as(u8, 0b1001_1001), input.toNesControllerByte());
}
