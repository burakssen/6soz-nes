const Timing = @This();

pub const Region = enum {
    ntsc,
    pal,
};

region: Region,
cpu_rate: u32,
frame_rate: u16,
ppu_clock_numerator: u8,
ppu_clock_denominator: u8,
ppu_scanlines: u16,
apu_frame_period: u16,

pub const ntsc = Timing{
    .region = .ntsc,
    .cpu_rate = 1_789_773,
    .frame_rate = 60,
    .ppu_clock_numerator = 3,
    .ppu_clock_denominator = 1,
    .ppu_scanlines = 262,
    .apu_frame_period = 7457,
};

pub const pal = Timing{
    .region = .pal,
    .cpu_rate = 1_662_607,
    .frame_rate = 50,
    .ppu_clock_numerator = 16,
    .ppu_clock_denominator = 5,
    .ppu_scanlines = 312,
    .apu_frame_period = 8313,
};

pub fn noisePeriod(self: Timing, index: u8) u16 {
    const ntsc_table = [_]u16{
        4,   8,   16,  32,  64,  96,   128,  160,
        202, 254, 380, 508, 762, 1016, 2034, 4068,
    };
    const pal_table = [_]u16{
        4,   8,   14,  30,  60,  88,  118,  148,
        188, 236, 354, 472, 708, 944, 1890, 3778,
    };
    return switch (self.region) {
        .ntsc => ntsc_table[index & 0x0f],
        .pal => pal_table[index & 0x0f],
    };
}

pub fn dmcPeriod(self: Timing, index: u8) u16 {
    const ntsc_table = [_]u16{
        428, 380, 340, 320, 286, 254, 226, 214,
        190, 160, 142, 128, 106, 84,  72,  54,
    };
    const pal_table = [_]u16{
        398, 354, 316, 298, 276, 236, 210, 198,
        176, 148, 132, 118, 98,  78,  66,  50,
    };
    return switch (self.region) {
        .ntsc => ntsc_table[index & 0x0f],
        .pal => pal_table[index & 0x0f],
    };
}

test "PAL timing uses fractional PPU clock ratio and PAL APU periods" {
    const std = @import("std");

    try std.testing.expectEqual(@as(u8, 16), pal.ppu_clock_numerator);
    try std.testing.expectEqual(@as(u8, 5), pal.ppu_clock_denominator);
    try std.testing.expectEqual(@as(u16, 312), pal.ppu_scanlines);
    try std.testing.expectEqual(@as(u16, 14), pal.noisePeriod(2));
    try std.testing.expectEqual(@as(u16, 398), pal.dmcPeriod(0));
}
