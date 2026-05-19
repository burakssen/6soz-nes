const std = @import("std");

pub const Mirroring = enum {
    horizontal,
    vertical,
    four_screen,
};

const Cartridge = @This();

const prg_bank_size = 16 * 1024;
const chr_bank_size = 8 * 1024;

prg_rom: []u8,
chr: []u8,
chr_is_ram: bool,
mapper_id: u8,
mirroring: Mirroring,

pub fn load(allocator: std.mem.Allocator, data: []const u8) !Cartridge {
    if (data.len < 16) return error.InvalidHeader;
    if (!std.mem.eql(u8, data[0..4], "NES\x1a")) return error.NotANesFile;

    const prg_size = @as(usize, data[4]) * prg_bank_size;
    const chr_rom_size = @as(usize, data[5]) * chr_bank_size;

    const flags6 = data[6];
    const flags7 = data[7];

    if ((flags7 & 0x0c) == 0x08) return error.UnsupportedNes2;

    const mapper_id = (flags7 & 0xf0) | (flags6 >> 4);
    if (mapper_id != 0) return error.UnsupportedMapper;

    const mirroring: Mirroring = if ((flags6 & 0x08) != 0)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    const prg_start = 16 + (if ((flags6 & 0x04) != 0) @as(usize, 512) else 0);
    const chr_start = prg_start + prg_size;

    if (prg_size != prg_bank_size and prg_size != prg_bank_size * 2) return error.UnsupportedPrgSize;
    if (data.len < chr_start + chr_rom_size) return error.IncompleteFile;

    const prg_rom = try allocator.alloc(u8, prg_size);
    errdefer allocator.free(prg_rom);
    std.mem.copyForwards(u8, prg_rom, data[prg_start..][0..prg_size]);

    const chr_size = if (chr_rom_size == 0) chr_bank_size else chr_rom_size;
    const chr = try allocator.alloc(u8, chr_size);
    errdefer allocator.free(chr);
    if (chr_rom_size == 0) {
        @memset(chr, 0);
    } else {
        std.mem.copyForwards(u8, chr, data[chr_start..][0..chr_rom_size]);
    }

    return .{
        .prg_rom = prg_rom,
        .chr = chr,
        .chr_is_ram = chr_rom_size == 0,
        .mapper_id = mapper_id,
        .mirroring = mirroring,
    };
}

pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
    allocator.free(self.prg_rom);
    allocator.free(self.chr);
}

test "loads iNES header and copies PRG and CHR ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[6] = 0x01;
    data[16] = 0xea;
    data[16 + prg_size] = 0x42;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, chr_size), cartridge.chr.len);
    try std.testing.expectEqual(@as(u8, 0xea), cartridge.prg_rom[0]);
    try std.testing.expectEqual(@as(u8, 0x42), cartridge.chr[0]);
    try std.testing.expect(!cartridge.chr_is_ram);
    try std.testing.expectEqual(Cartridge.Mirroring.vertical, cartridge.mirroring);
    try std.testing.expectEqual(@as(u8, 0), cartridge.mapper_id);
}

test "allocates CHR RAM when iNES file has no CHR ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 0;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(usize, chr_bank_size), cartridge.chr.len);
    try std.testing.expect(cartridge.chr_is_ram);
    try std.testing.expectEqual(@as(u8, 0), cartridge.chr[0]);
}

test "rejects unsupported mapper" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[6] = 0x10;

    try std.testing.expectError(error.UnsupportedMapper, Cartridge.load(allocator, data));
}

test "rejects NES 2.0 headers until parsed explicitly" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[7] = 0x08;

    try std.testing.expectError(error.UnsupportedNes2, Cartridge.load(allocator, data));
}

test "rejects mapper 0 PRG sizes other than 16KB or 32KB" {
    const allocator = std.testing.allocator;

    var data = try allocator.alloc(u8, 16 + 3 * prg_bank_size + chr_bank_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 3;
    data[5] = 1;

    try std.testing.expectError(error.UnsupportedPrgSize, Cartridge.load(allocator, data));
}
