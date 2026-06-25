const std = @import("std");

pub const Mapper = @import("mapper.zig").Mapper;
const State = @import("state_io.zig");

pub const Mirroring = enum {
    single_screen_lower,
    single_screen_upper,
    horizontal,
    vertical,
    four_screen,
};

pub const TimingMode = enum {
    ntsc,
    pal,
    multiple,
    dendy,
};

const Cartridge = @This();

const prg_bank_size = 16 * 1024;
const chr_bank_size = 8 * 1024;
const unrom512_chr_ram_size = 4 * chr_bank_size;

prg_rom: []u8,
chr: []u8,
prg_ram: []u8,
mapper: Mapper,
mapper_id: u16,
submapper_id: u8,
timing_mode: TimingMode,
has_battery: bool,
save_ram_start: usize,
save_ram_len: usize,

const Header = struct {
    prg_size: usize,
    chr_rom_size: usize,
    mapper_id: u16,
    submapper_id: u8 = 0,
    mirroring: Mirroring,
    prg_ram_size: usize = 0,
    prg_nvram_size: usize = 0,
    chr_ram_size: usize = 0,
    chr_nvram_size: usize = 0,
    timing_mode: TimingMode = .ntsc,
    has_trainer: bool,
    has_battery: bool = false,
};

fn parseInes(data: *const [16]u8) Header {
    const flags6 = data[6];
    const flags7: u8 = if (std.mem.eql(u8, data[7..16], "DiskDude!")) 0 else data[7];

    const prg_size = @as(usize, data[4]) * prg_bank_size;
    const chr_rom_size = @as(usize, data[5]) * chr_bank_size;

    const mapper_id = @as(u16, (flags7 & 0xf0) | (flags6 >> 4));

    const mirroring: Mirroring = if ((flags6 & 0x08) != 0)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    return .{
        .prg_size = prg_size,
        .chr_rom_size = chr_rom_size,
        .mapper_id = mapper_id,
        .mirroring = mirroring,
        .has_trainer = (flags6 & 0x04) != 0,
        .has_battery = (flags6 & 0x02) != 0,
        .timing_mode = if ((data[9] & 0x01) != 0) .pal else .ntsc,
    };
}

fn exponentSize(encoded: u8) !usize {
    const multiplier = @as(usize, encoded & 0x03) * 2 + 1;
    const exponent = (encoded >> 2) & 0x3f;
    if (exponent >= @bitSizeOf(usize)) return error.InvalidHeader;
    const shift: std.math.Log2Int(usize) = @intCast(exponent);
    return std.math.shlExact(usize, multiplier, shift) catch error.InvalidHeader;
}

fn parseNes2(data: *const [16]u8) !Header {
    const prg_lsb = data[4];
    const chr_lsb = data[5];
    const flags6 = data[6];
    const flags7 = data[7];
    const msb = data[9];

    var prg_size: usize = 0;
    const prg_msb = msb & 0x0f;
    if (prg_msb != 0x0f) {
        prg_size = ((@as(usize, prg_msb) << 8) | prg_lsb) * prg_bank_size;
    } else {
        prg_size = try exponentSize(prg_lsb);
    }

    var chr_rom_size: usize = 0;
    const chr_msb = (msb >> 4) & 0x0f;
    if (chr_msb != 0x0f) {
        chr_rom_size = ((@as(usize, chr_msb) << 8) | chr_lsb) * chr_bank_size;
    } else {
        chr_rom_size = try exponentSize(chr_lsb);
    }

    const mapper_low = (flags7 & 0xf0) | (flags6 >> 4);
    const mapper_id = @as(u16, mapper_low) | (@as(u16, data[8] & 0x0f) << 8);
    const submapper_id = (data[8] >> 4) & 0x0f;

    var prg_ram_size: usize = 0;
    var prg_nvram_size: usize = 0;
    const prg_ram_byte = data[10];
    const prg_ram_shift = prg_ram_byte & 0x0f;
    const prg_nvram_shift = (prg_ram_byte >> 4) & 0x0f;
    if (prg_ram_shift > 0) prg_ram_size = @as(usize, 64) << @intCast(prg_ram_shift);
    if (prg_nvram_shift > 0) prg_nvram_size = @as(usize, 64) << @intCast(prg_nvram_shift);

    var chr_ram_size: usize = 0;
    var chr_nvram_size: usize = 0;
    const chr_ram_byte = data[11];
    const chr_ram_shift = chr_ram_byte & 0x0f;
    const chr_nvram_shift = (chr_ram_byte >> 4) & 0x0f;
    if (chr_ram_shift > 0) chr_ram_size = @as(usize, 64) << @intCast(chr_ram_shift);
    if (chr_nvram_shift > 0) chr_nvram_size = @as(usize, 64) << @intCast(chr_nvram_shift);

    const timing_mode: TimingMode = switch (data[12] & 0x03) {
        0 => .ntsc,
        1 => .pal,
        2 => .multiple,
        3 => .dendy,
        else => unreachable,
    };

    const mirroring: Mirroring = if ((flags6 & 0x08) != 0)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    return .{
        .prg_size = prg_size,
        .chr_rom_size = chr_rom_size,
        .mapper_id = mapper_id,
        .submapper_id = submapper_id,
        .mirroring = mirroring,
        .prg_ram_size = prg_ram_size,
        .prg_nvram_size = prg_nvram_size,
        .chr_ram_size = chr_ram_size,
        .chr_nvram_size = chr_nvram_size,
        .timing_mode = timing_mode,
        .has_trainer = (flags6 & 0x04) != 0,
        .has_battery = headerHasBattery(data),
    };
}

fn headerHasBattery(data: *const [16]u8) bool {
    return (data[6] & 0x02) != 0 or ((data[10] >> 4) & 0x0f) != 0;
}

pub fn load(allocator: std.mem.Allocator, data: []const u8) !Cartridge {
    if (data.len < 16) return error.InvalidHeader;
    if (!std.mem.eql(u8, data[0..4], "NES\x1a"))
        return error.NotANesFile;

    const is_nes2 = (data[7] & 0x0c) == 0x08;
    const header = if (is_nes2)
        try parseNes2(data[0..16])
    else
        parseInes(data[0..16]);

    if (header.mirroring == .four_screen) return error.UnsupportedMirroring;
    if (header.timing_mode == .dendy) return error.UnsupportedTimingMode;
    const timing_mode: TimingMode = switch (header.timing_mode) {
        .multiple => .ntsc,
        else => header.timing_mode,
    };
    if (header.mapper_id == 0 and header.prg_size != prg_bank_size and header.prg_size != 2 * prg_bank_size)
        return error.InvalidPrgSize;

    const prg_start = 16 + (if (header.has_trainer) @as(usize, 512) else 0);
    const chr_start = std.math.add(usize, prg_start, header.prg_size) catch
        return error.InvalidHeader;
    const file_size = std.math.add(usize, chr_start, header.chr_rom_size) catch
        return error.InvalidHeader;

    if (data.len < file_size)
        return error.IncompleteFile;

    const prg_rom = try allocator.alloc(u8, header.prg_size);
    errdefer allocator.free(prg_rom);

    std.mem.copyForwards(
        u8,
        prg_rom,
        data[prg_start..][0..header.prg_size],
    );

    const chr_size = if (header.chr_rom_size > 0)
        header.chr_rom_size
    else if (header.mapper_id == 30 and (!is_nes2 or header.chr_ram_size + header.chr_nvram_size == 0))
        unrom512_chr_ram_size
    else if (is_nes2)
        std.math.add(usize, header.chr_ram_size, header.chr_nvram_size) catch
            return error.InvalidHeader
    else
        chr_bank_size;
    if (chr_size == 0) return error.InvalidChrSize;

    const chr = try allocator.alloc(u8, chr_size);
    errdefer allocator.free(chr);

    if (header.chr_rom_size == 0) {
        @memset(chr, 0);
    } else {
        std.mem.copyForwards(
            u8,
            chr,
            data[chr_start..][0..header.chr_rom_size],
        );
    }

    const prg_ram_size = if (header.prg_ram_size > 0 or header.prg_nvram_size > 0)
        std.math.add(usize, header.prg_ram_size, header.prg_nvram_size) catch
            return error.InvalidHeader
    else if (header.mapper_id == 1 or header.mapper_id == 4 or header.has_battery)
        @as(usize, 8192)
    else
        0;

    var prg_ram: []u8 = &[_]u8{};
    if (prg_ram_size > 0) {
        prg_ram = try allocator.alloc(u8, prg_ram_size);
        @memset(prg_ram, 0);
    }
    errdefer if (prg_ram.len > 0) allocator.free(prg_ram);

    const save_ram_start: usize = if (header.prg_nvram_size > 0) header.prg_ram_size else 0;
    const save_ram_len: usize = if (header.prg_nvram_size > 0)
        header.prg_nvram_size
    else if (header.has_battery)
        prg_ram.len
    else
        0;

    const mapper: Mapper = switch (header.mapper_id) {
        0 => Mapper{ .nrom = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .mirroring_mode = header.mirroring,
        } },
        1 => Mapper{ .mmc1 = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .prg_ram = prg_ram,
        } },
        2 => Mapper{ .uxrom = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .mirroring_mode = header.mirroring,
        } },
        3 => Mapper{ .cnrom = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .mirroring_mode = header.mirroring,
        } },
        4 => Mapper{ .mmc3 = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .prg_ram = prg_ram,
            .mirroring_mode = header.mirroring,
        } },
        7 => Mapper{ .axrom = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
        } },
        30 => Mapper{ .unrom512 = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .mirroring_mode = .single_screen_lower,
        } },
        69 => Mapper{ .fme7 = .{
            .prg_rom = prg_rom,
            .chr = chr,
            .chr_is_ram = header.chr_rom_size == 0,
            .prg_ram = prg_ram,
            .mirroring_mode = header.mirroring,
        } },
        else => return error.UnsupportedMapper,
    };

    return .{
        .prg_rom = prg_rom,
        .chr = chr,
        .prg_ram = prg_ram,
        .mapper = mapper,
        .mapper_id = header.mapper_id,
        .submapper_id = header.submapper_id,
        .timing_mode = timing_mode,
        .has_battery = save_ram_len > 0,
        .save_ram_start = save_ram_start,
        .save_ram_len = save_ram_len,
    };
}

pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
    allocator.free(self.prg_rom);
    allocator.free(self.chr);
    if (self.prg_ram.len > 0) allocator.free(self.prg_ram);
}

pub fn saveRam(self: *const Cartridge) ?[]const u8 {
    if (!self.has_battery) return null;
    if (self.save_ram_len == 0) return null;
    return self.prg_ram[self.save_ram_start..][0..self.save_ram_len];
}

pub fn loadSaveRam(self: *Cartridge, data: []const u8) !void {
    if (!self.has_battery) return error.NoSaveRam;
    if (self.save_ram_len == 0) return error.NoSaveRam;
    if (data.len != self.save_ram_len) return error.InvalidSaveRamSize;
    @memcpy(self.prg_ram[self.save_ram_start..][0..self.save_ram_len], data);
}

pub fn romHash(self: *const Cartridge) u64 {
    var hash = std.hash.Wyhash.init(0x6e6573526f6d4861);
    hash.update(self.prg_rom);
    switch (self.mapper) {
        inline else => |m| if (!m.chr_is_ram) hash.update(self.chr),
    }
    var meta: [4]u8 = undefined;
    std.mem.writeInt(u16, meta[0..2], self.mapper_id, .little);
    meta[2] = self.submapper_id;
    meta[3] = @intFromEnum(self.timing_mode);
    hash.update(&meta);
    return hash.final();
}

pub fn saveState(self: *const Cartridge, allocator: std.mem.Allocator) ![]u8 {
    var state = std.Io.Writer.Allocating.init(allocator);
    defer state.deinit();
    const writer = &state.writer;

    try State.writeValue(writer, self.romHash());
    try State.writeValue(writer, @as(u32, @intCast(self.chr.len)));
    try writer.writeAll(self.chr);
    try State.writeValue(writer, @as(u32, @intCast(self.prg_ram.len)));
    try writer.writeAll(self.prg_ram);
    try self.mapper.saveState(writer);

    return state.toOwnedSlice();
}

pub fn loadState(self: *Cartridge, data: []const u8) !void {
    var state = std.Io.Reader.fixed(data);
    const reader = &state;

    if ((try State.readValue(reader, u64)) != self.romHash()) return State.Error.StateKindMismatch;

    const chr_len = try State.readValue(reader, u32);
    if (chr_len != self.chr.len) return State.Error.InvalidState;
    @memcpy(self.chr, try State.readBytes(reader, self.chr.len));

    const prg_ram_len = try State.readValue(reader, u32);
    if (prg_ram_len != self.prg_ram.len) return State.Error.InvalidState;
    @memcpy(self.prg_ram, try State.readBytes(reader, self.prg_ram.len));

    try self.mapper.loadState(reader);
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
    try std.testing.expect(!cartridge.mapper.nrom.chr_is_ram);
    try std.testing.expectEqual(Cartridge.Mirroring.vertical, cartridge.mapper.mirroring());
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
    try std.testing.expect(cartridge.mapper.nrom.chr_is_ram);
    try std.testing.expectEqual(@as(u8, 0), cartridge.chr[0]);
}

test "loads iNES ROM with DiskDude header junk as mapper 0" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    @memcpy(data[7..16], "DiskDude!");

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 0), cartridge.mapper_id);
    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, chr_size), cartridge.chr.len);
}

test "loads mapper 3 CNROM ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 32 * 1024;
    const chr_size = 16 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 2;
    data[5] = 2;
    data[6] = 0x31;
    data[16] = 0xea;
    data[16 + prg_size] = 0x42;
    data[16 + prg_size + chr_bank_size] = 0x84;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 3), cartridge.mapper_id);
    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, chr_size), cartridge.chr.len);
    try std.testing.expectEqual(Cartridge.Mirroring.vertical, cartridge.mapper.mirroring());
    try std.testing.expectEqual(@as(u8, 0xea), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x42), cartridge.mapper.chrRead(0x0000));

    cartridge.mapper.prgWrite(0x8000, 1);
    try std.testing.expectEqual(@as(u8, 0x84), cartridge.mapper.chrRead(0x0000));
}

test "loads mapper 30 UNROM-512 ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 512 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 32;
    data[5] = 0;
    data[6] = 0xe2;
    data[7] = 0x10;
    data[16] = 0x30;
    data[16 + prg_bank_size] = 0x31;
    data[16 + prg_size - prg_bank_size] = 0xfe;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 30), cartridge.mapper_id);
    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, unrom512_chr_ram_size), cartridge.chr.len);
    try std.testing.expect(cartridge.mapper.unrom512.chr_is_ram);
    try std.testing.expectEqual(@as(u8, 0x30), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0xfe), cartridge.mapper.prgRead(0xc000));

    cartridge.mapper.unrom512.chrWrite(0x0000, 0x10);
    cartridge.mapper.prgWrite(0x8000, 0x40);
    cartridge.mapper.unrom512.chrWrite(0x0000, 0x40);
    try std.testing.expectEqual(@as(u8, 0x40), cartridge.mapper.chrRead(0x0000));

    cartridge.mapper.prgWrite(0x8000, 0x21);
    try std.testing.expectEqual(@as(u8, 0x31), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0x10), cartridge.mapper.chrRead(0x0000));
    try std.testing.expectEqual(Mirroring.single_screen_upper, cartridge.mapper.mirroring());
}

test "loads mapper 69 FME-7 ROM with PRG and CHR banking" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x53;
    data[7] = 0x48;
    data[10] = 0x90;
    data[11] = 0x07;
    data[16] = 0x40;
    data[16 + 3 * 8 * 1024] = 0x43;
    data[16 + prg_size - 8 * 1024] = 0xff;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 69), cartridge.mapper_id);
    try std.testing.expectEqual(@as(usize, 32 * 1024), cartridge.prg_ram.len);
    try std.testing.expectEqual(@as(usize, chr_bank_size), cartridge.chr.len);
    try std.testing.expectEqual(@as(u8, 0x40), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 0xff), cartridge.mapper.prgRead(0xe000));

    cartridge.mapper.prgWrite(0x8000, 0x09);
    cartridge.mapper.prgWrite(0xa000, 0x03);
    try std.testing.expectEqual(@as(u8, 0x43), cartridge.mapper.prgRead(0x8000));

    cartridge.mapper.prgWrite(0x8000, 0x0c);
    cartridge.mapper.prgWrite(0xa000, 0x03);
    try std.testing.expectEqual(Mirroring.single_screen_upper, cartridge.mapper.mirroring());

    cartridge.mapper.prgWrite(0x8000, 0x00);
    cartridge.mapper.prgWrite(0xa000, 0x01);
    cartridge.mapper.chrWrite(0, 0x5a);
    try std.testing.expectEqual(@as(u8, 0x5a), cartridge.chr[1024]);
    try std.testing.expectEqual(@as(u8, 0x5a), cartridge.mapper.chrRead(0));
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
    data[6] = 0x50;

    try std.testing.expectError(error.UnsupportedMapper, Cartridge.load(allocator, data));
}

test "loads NES 2.0 multi-region ROM as NTSC" {
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
    data[12] = 0x02;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(TimingMode.ntsc, cartridge.timing_mode);
}

test "loads mapper 1 MMC1 ROM with default PRG RAM and CHR RAM" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x12;
    data[16] = 0xea;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 1), cartridge.mapper_id);
    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, chr_bank_size), cartridge.chr.len);
    try std.testing.expectEqual(@as(usize, 8192), cartridge.prg_ram.len);
    try std.testing.expect(cartridge.mapper.mmc1.chr_is_ram);
    try std.testing.expectEqual(@as(u8, 0xea), cartridge.mapper.prgRead(0x8000));
}

test "mapper 1 exposes and imports save RAM" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x12;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    var save: [8192]u8 = [_]u8{0} ** 8192;
    save[0] = 0x12;
    save[0x1fff] = 0x34;

    try cartridge.loadSaveRam(&save);
    const exported = cartridge.saveRam().?;

    try std.testing.expectEqual(@as(usize, 8192), exported.len);
    try std.testing.expectEqual(@as(u8, 0x12), exported[0]);
    try std.testing.expectEqual(@as(u8, 0x34), exported[0x1fff]);
    try std.testing.expectEqual(@as(u8, 0x12), cartridge.mapper.prgRead(0x6000));
    try std.testing.expectEqual(@as(u8, 0x34), cartridge.mapper.prgRead(0x7fff));
}

test "volatile mapper 1 PRG RAM is not exported as save RAM" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x10;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8192), cartridge.prg_ram.len);
    try std.testing.expectEqual(@as(?[]const u8, null), cartridge.saveRam());
    try std.testing.expectError(error.NoSaveRam, cartridge.loadSaveRam(&[_]u8{}));
}

test "battery NROM exposes save RAM" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[6] = 0x02;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8192), cartridge.saveRam().?.len);
}

test "save RAM import rejects size mismatch" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x12;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectError(error.InvalidSaveRamSize, cartridge.loadSaveRam(&[_]u8{0}));
}

test "NROM without PRG RAM has no save RAM" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), cartridge.saveRam());
    try std.testing.expectError(error.NoSaveRam, cartridge.loadSaveRam(&[_]u8{}));
}

test "rejects mapper 0 PRG sizes other than 16KB or 32KB" {
    const allocator = std.testing.allocator;

    var data = try allocator.alloc(u8, 16 + 3 * prg_bank_size + chr_bank_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 3;
    data[5] = 1;

    try std.testing.expectError(error.InvalidPrgSize, Cartridge.load(allocator, data));
}

test "rejects four-screen mirroring" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[6] = 0x08;

    try std.testing.expectError(error.UnsupportedMirroring, Cartridge.load(allocator, data));
}

test "loads NES 2.0 NROM ROM" {
    const allocator = std.testing.allocator;

    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);

    @memset(data, 0);

    @memcpy(data[0..4], "NES\x1a");

    data[4] = 1;
    data[5] = 1;

    // NES 2.0 identifier
    data[7] = 0x08;

    data[16] = 0xaa;
    data[16 + prg_size] = 0xbb;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(
        @as(usize, prg_size),
        cartridge.prg_rom.len,
    );

    try std.testing.expectEqual(
        @as(usize, chr_size),
        cartridge.chr.len,
    );

    try std.testing.expectEqual(
        @as(u8, 0xaa),
        cartridge.prg_rom[0],
    );

    try std.testing.expectEqual(
        @as(u8, 0xbb),
        cartridge.chr[0],
    );
    try std.testing.expectEqual(@as(u16, 0), cartridge.mapper_id);
    try std.testing.expectEqual(@as(u8, 0), cartridge.submapper_id);
}

test "loads NES 2.0 with exponent sizes, submapper, RAM and timing" {
    const allocator = std.testing.allocator;

    const prg_size = 16384;
    const chr_size = 8192;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 56; // multiplier 0, exponent 14 -> 16384
    data[5] = 52; // multiplier 0, exponent 13 -> 8192
    data[7] = 0x08; // NES 2.0
    data[8] = 0x10; // Mapper 0, Submapper 1
    data[9] = 0xff; // PRG & CHR MSB 0xF (exponent)
    data[10] = 0x11; // 128B volatile, 128B non-volatile PRG RAM
    data[11] = 0x22; // 256B volatile, 256B non-volatile CHR RAM
    data[12] = 0x01; // PAL

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(usize, prg_size), cartridge.prg_rom.len);
    try std.testing.expectEqual(@as(usize, chr_size), cartridge.chr.len);
    try std.testing.expectEqual(@as(u16, 0), cartridge.mapper_id);
    try std.testing.expectEqual(@as(u8, 1), cartridge.submapper_id);
    try std.testing.expectEqual(@as(usize, 256), cartridge.prg_ram.len); // 128 + 128
    try std.testing.expectEqual(@as(usize, 128), cartridge.saveRam().?.len);
    try std.testing.expectEqual(TimingMode.pal, cartridge.timing_mode);
}

test "legacy iNES TV flag selects PAL timing" {
    const allocator = std.testing.allocator;
    const prg_size = 16 * 1024;
    const chr_size = 8 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = 1;
    data[9] = 1;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(TimingMode.pal, cartridge.timing_mode);
}

test "rejects Dendy NES 2.0 timing mode" {
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
    data[12] = 3;

    try std.testing.expectError(error.UnsupportedTimingMode, Cartridge.load(allocator, data));
}

test "rejects overflowing NES 2.0 exponent sizes" {
    var data = [_]u8{0} ** 16;
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 0xff;
    data[7] = 0x08;
    data[9] = 0x0f;

    try std.testing.expectError(
        error.InvalidHeader,
        Cartridge.load(std.testing.allocator, &data),
    );
}

test "rejects NES 2.0 cartridges without CHR ROM or RAM" {
    var data = [_]u8{0} ** (16 + prg_bank_size);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[7] = 0x08;

    try std.testing.expectError(
        error.InvalidChrSize,
        Cartridge.load(std.testing.allocator, &data),
    );
}

test "loads mapper 2 UxROM ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;
    const chr_size = 0;

    var data = try allocator.alloc(u8, 16 + prg_size + chr_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x21;

    for (0..8) |i| {
        data[16 + i * prg_bank_size] = @as(u8, @intCast(i));
    }

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 2), cartridge.mapper_id);
    try std.testing.expectEqual(Cartridge.Mirroring.vertical, cartridge.mapper.mirroring());

    try std.testing.expectEqual(@as(u8, 0), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 7), cartridge.mapper.prgRead(0xc000));

    cartridge.mapper.prgWrite(0x8000, 3);

    try std.testing.expectEqual(@as(u8, 3), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(@as(u8, 7), cartridge.mapper.prgRead(0xc000));
}

test "loads mapper 7 AxROM ROM" {
    const allocator = std.testing.allocator;
    const prg_size = 128 * 1024;

    var data = try allocator.alloc(u8, 16 + prg_size);
    defer allocator.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8; // 8 * 16KB = 128KB PRG ROM
    data[5] = 0; // 0 CHR ROM
    data[6] = 0x70; // mapper 7 lower nibble (flags6 >> 4)
    data[7] = 0x00; // mapper 7 upper nibble (flags7 & 0xf0)

    const axrom_bank_size = 32 * 1024;
    for (0..4) |i| {
        data[16 + i * axrom_bank_size] = @as(u8, @intCast(i));
    }

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 7), cartridge.mapper_id);
    try std.testing.expectEqual(Cartridge.Mirroring.single_screen_lower, cartridge.mapper.mirroring());

    try std.testing.expectEqual(@as(u8, 0), cartridge.mapper.prgRead(0x8000));

    // Write to switch to bank 2 and set upper single-screen mirroring
    // (1 << 4) | 2 = 18 (0x12)
    cartridge.mapper.prgWrite(0x8000, 0x12);

    try std.testing.expectEqual(@as(u8, 2), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(Cartridge.Mirroring.single_screen_upper, cartridge.mapper.mirroring());

    // Write to switch to bank 3 and set lower single-screen mirroring
    cartridge.mapper.prgWrite(0x8000, 3);

    try std.testing.expectEqual(@as(u8, 3), cartridge.mapper.prgRead(0x8000));
    try std.testing.expectEqual(Cartridge.Mirroring.single_screen_lower, cartridge.mapper.mirroring());
}
