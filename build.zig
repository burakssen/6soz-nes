const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mos6502_dep = b.dependency("mos6502", .{
        .target = target,
        .optimize = optimize,
    });

    const mos6502_mod = mos6502_dep.module("mos6502");

    const timing_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/timing.zig"),
    });

    const cartridge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/cartridge/cartridge.zig"),
    });

    const apu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/apu/apu.zig"),
        .imports = &.{
            .{ .name = "timing", .module = timing_mod },
        },
    });

    const ppu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ppu.zig"),
        .imports = &.{
            .{ .name = "cartridge", .module = cartridge_mod },
            .{ .name = "timing", .module = timing_mod },
        },
    });

    const nes_mod = b.addModule("nes", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/nes.zig"),
        .imports = &.{
            .{ .name = "mos6502", .module = mos6502_mod },
            .{ .name = "apu", .module = apu_mod },
            .{ .name = "ppu", .module = ppu_mod },
            .{ .name = "cartridge", .module = cartridge_mod },
            .{ .name = "timing", .module = timing_mod },
        },
    });

    const bus_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/bus.zig"),
        .imports = &.{
            .{ .name = "apu", .module = apu_mod },
            .{ .name = "ppu", .module = ppu_mod },
            .{ .name = "cartridge", .module = cartridge_mod },
        },
    });



    const test_step = b.step("test", "Run 6soz-nes tests");
    inline for (&.{ nes_mod, bus_mod, cartridge_mod, ppu_mod, apu_mod, timing_mod }) |test_mod| {
        const test_cmd = b.addTest(.{ .root_module = test_mod });
        const run_test = b.addRunArtifact(test_cmd);
        test_step.dependOn(&run_test.step);
    }

    const nes_lib = b.addLibrary(.{
        .name = "nes",
        .root_module = nes_mod,
    });

    b.installArtifact(nes_lib);
}
