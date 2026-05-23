const common = @import("common.zig");

const Nrom = @import("nrom.zig");
const Mmc1 = @import("mmc1.zig");
const Cnrom = @import("cnrom.zig");
const Mmc3 = @import("mmc3.zig");

pub const Mapper = union(enum) {
    nrom: Nrom,
    mmc1: Mmc1,
    cnrom: Cnrom,
    mmc3: Mmc3,

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

    pub fn acknowledgeIrq(self: *Mapper) void {
        switch (self.*) {
            .mmc3 => |*m| m.irq_active = false,
            else => {},
        }
    }

    pub fn mirroring(self: *const Mapper) common.Mirroring {
        return switch (self.*) {
            inline else => |*m| m.mirroring(),
        };
    }
};
