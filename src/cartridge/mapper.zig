const std = @import("std");
const cartridge = @import("cartridge.zig");

const Nrom = @import("nrom.zig");
const Mmc1 = @import("mmc1.zig");
const Cnrom = @import("cnrom.zig");
const Mmc3 = @import("mmc3.zig");
const Uxrom = @import("uxrom.zig");
const Unrom512 = @import("unrom512.zig");
const Axrom = @import("axrom.zig");
const Fme7 = @import("fme7.zig");
const State = @import("state_io.zig");

pub const Mapper = union(enum) {
    nrom: Nrom,
    mmc1: Mmc1,
    cnrom: Cnrom,
    mmc3: Mmc3,
    uxrom: Uxrom,
    unrom512: Unrom512,
    axrom: Axrom,
    fme7: Fme7,

    pub fn prgRead(self: *Mapper, addr: u16) u8 {
        return switch (self.*) {
            inline else => |*m| m.prgRead(addr),
        };
    }

    pub fn prgWrite(self: *Mapper, addr: u16, val: u8) void {
        switch (self.*) {
            inline else => |*m| m.prgWrite(addr, val),
        }
    }

    pub fn chrRead(self: *Mapper, addr: u16) u8 {
        return switch (self.*) {
            inline else => |*m| m.chrRead(addr),
        };
    }

    pub fn chrWrite(self: *Mapper, addr: u16, val: u8) void {
        switch (self.*) {
            inline else => |*m| m.chrWrite(addr, val),
        }
    }

    pub fn ppuA12(self: *Mapper, addr: u16) void {
        switch (self.*) {
            .mmc3 => |*m| m.ppuA12(addr),
            else => {},
        }
    }

    pub fn irqActive(self: *const Mapper) bool {
        return switch (self.*) {
            .mmc3 => |*m| m.irq_active,
            else => false,
        };
    }

    pub fn mirroring(self: *const Mapper) cartridge.Mirroring {
        return switch (self.*) {
            inline else => |*m| m.mirroring(),
        };
    }

    pub fn saveState(self: *const Mapper, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .nrom => try State.writeValue(writer, @as(u8, 0)),
            .mmc1 => |m| {
                try State.writeValue(writer, @as(u8, 1));
                try State.writeValue(writer, m.shift_value);
                try State.writeValue(writer, m.shift_count);
                try State.writeValue(writer, m.control);
                try State.writeValue(writer, m.chr_bank0);
                try State.writeValue(writer, m.chr_bank1);
                try State.writeValue(writer, m.prg_bank);
            },
            .uxrom => |m| {
                try State.writeValue(writer, @as(u8, 2));
                try State.writeValue(writer, m.prg_bank);
            },
            .cnrom => |m| {
                try State.writeValue(writer, @as(u8, 3));
                try State.writeValue(writer, m.chr_bank);
            },
            .mmc3 => |m| {
                try State.writeValue(writer, @as(u8, 4));
                try State.writeValue(writer, m.bank_select);
                try State.writeValue(writer, m.bank_registers);
                try State.writeValue(writer, m.mirroring_mode);
                try State.writeValue(writer, m.prg_ram_protect);
                try State.writeValue(writer, m.irq_latch);
                try State.writeValue(writer, m.irq_counter);
                try State.writeValue(writer, m.irq_reload);
                try State.writeValue(writer, m.irq_enabled);
                try State.writeValue(writer, m.irq_active);
                try State.writeValue(writer, m.last_a12);
            },
            .axrom => |m| {
                try State.writeValue(writer, @as(u8, 7));
                try State.writeValue(writer, m.prg_bank);
                try State.writeValue(writer, m.mirroring_select);
            },
            .unrom512 => |m| {
                try State.writeValue(writer, @as(u8, 30));
                try State.writeValue(writer, m.prg_bank);
                try State.writeValue(writer, m.chr_bank);
                try State.writeValue(writer, m.mirroring_mode);
            },
            .fme7 => |m| {
                try State.writeValue(writer, @as(u8, 69));
                try State.writeValue(writer, m.command);
                try State.writeValue(writer, m.chr_banks);
                try State.writeValue(writer, m.prg_ram_control);
                try State.writeValue(writer, m.prg_banks);
                try State.writeValue(writer, m.mirroring_mode);
                try State.writeValue(writer, m.irq_control);
                try State.writeValue(writer, m.irq_counter);
            },
        }
    }

    pub fn loadState(self: *Mapper, reader: *std.Io.Reader) !void {
        const tag = try State.readValue(reader, u8);
        switch (self.*) {
            .nrom => if (tag != 0) return State.Error.StateKindMismatch,
            .mmc1 => |*m| {
                if (tag != 1) return State.Error.StateKindMismatch;
                m.shift_value = try State.readValue(reader, u5);
                m.shift_count = try State.readValue(reader, u3);
                m.control = try State.readValue(reader, u5);
                m.chr_bank0 = try State.readValue(reader, u5);
                m.chr_bank1 = try State.readValue(reader, u5);
                m.prg_bank = try State.readValue(reader, u5);
            },
            .uxrom => |*m| {
                if (tag != 2) return State.Error.StateKindMismatch;
                m.prg_bank = try State.readValue(reader, u8);
            },
            .cnrom => |*m| {
                if (tag != 3) return State.Error.StateKindMismatch;
                m.chr_bank = try State.readValue(reader, u8);
            },
            .mmc3 => |*m| {
                if (tag != 4) return State.Error.StateKindMismatch;
                m.bank_select = try State.readValue(reader, u8);
                m.bank_registers = try State.readValue(reader, [8]u8);
                m.mirroring_mode = try State.readValue(reader, cartridge.Mirroring);
                m.prg_ram_protect = try State.readValue(reader, u8);
                m.irq_latch = try State.readValue(reader, u8);
                m.irq_counter = try State.readValue(reader, u8);
                m.irq_reload = try State.readValue(reader, bool);
                m.irq_enabled = try State.readValue(reader, bool);
                m.irq_active = try State.readValue(reader, bool);
                m.last_a12 = try State.readValue(reader, bool);
            },
            .axrom => |*m| {
                if (tag != 7) return State.Error.StateKindMismatch;
                m.prg_bank = try State.readValue(reader, u3);
                m.mirroring_select = try State.readValue(reader, u1);
            },
            .unrom512 => |*m| {
                if (tag != 30) return State.Error.StateKindMismatch;
                m.prg_bank = try State.readValue(reader, u8);
                m.chr_bank = try State.readValue(reader, u2);
                m.mirroring_mode = try State.readValue(reader, cartridge.Mirroring);
            },
            .fme7 => |*m| {
                if (tag != 69) return State.Error.StateKindMismatch;
                m.command = try State.readValue(reader, u4);
                m.chr_banks = try State.readValue(reader, [8]u8);
                m.prg_ram_control = try State.readValue(reader, u8);
                m.prg_banks = try State.readValue(reader, [3]u8);
                m.mirroring_mode = try State.readValue(reader, cartridge.Mirroring);
                m.irq_control = try State.readValue(reader, u8);
                m.irq_counter = try State.readValue(reader, u16);
            },
        }
    }
};

test "UNROM-512 mapper state round-trips CHR bank" {
    var prg_rom: [32 * 16 * 1024]u8 = [_]u8{0} ** (32 * 16 * 1024);
    var chr: [4 * 8 * 1024]u8 = [_]u8{0} ** (4 * 8 * 1024);
    var mapper = Mapper{ .unrom512 = .{
        .prg_rom = &prg_rom,
        .chr = &chr,
        .chr_is_ram = true,
        .mirroring_mode = .single_screen_lower,
    } };

    mapper.prgWrite(0x8000, 0xe7);

    var state = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer state.deinit();
    try mapper.saveState(&state.writer);
    const bytes = try state.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    var restored = Mapper{ .unrom512 = .{
        .prg_rom = &prg_rom,
        .chr = &chr,
        .chr_is_ram = true,
        .mirroring_mode = .single_screen_lower,
    } };
    var reader = std.Io.Reader.fixed(bytes);
    try restored.loadState(&reader);

    try std.testing.expectEqual(@as(u8, 0x07), restored.unrom512.prg_bank);
    try std.testing.expectEqual(@as(u2, 0x03), restored.unrom512.chr_bank);
    try std.testing.expectEqual(cartridge.Mirroring.single_screen_upper, restored.unrom512.mirroring());
}
