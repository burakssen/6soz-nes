const std = @import("std");
const cartridge = @import("cartridge.zig");

const Nrom = @import("nrom.zig");
const Mmc1 = @import("mmc1.zig");
const Cnrom = @import("cnrom.zig");
const Mmc3 = @import("mmc3.zig");
const Uxrom = @import("uxrom.zig");
const Axrom = @import("axrom.zig");
const State = @import("state_io.zig");

pub const Mapper = union(enum) {
    nrom: Nrom,
    mmc1: Mmc1,
    cnrom: Cnrom,
    mmc3: Mmc3,
    uxrom: Uxrom,
    axrom: Axrom,

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
        }
    }
};
