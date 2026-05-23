const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("core", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = core_dep.module("core");

    const cartridge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/cartridge/cartridge.zig"),
    });

    const apu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/apu/apu.zig"),
    });

    const ppu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ppu/ppu.zig"),
        .imports = &.{
            .{ .name = "cartridge", .module = cartridge_mod },
        },
    });

    const nes_mod = b.addModule("nes", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/nes.zig"),
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "apu", .module = apu_mod },
            .{ .name = "ppu", .module = ppu_mod },
            .{ .name = "cartridge", .module = cartridge_mod },
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

    const ppu_input_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ppu/input_state.zig"),
    });

    const test_step = b.step("test", "Run 6soz-nes tests");
    inline for (&.{ nes_mod, bus_mod, cartridge_mod, ppu_mod, ppu_input_mod, apu_mod }) |test_mod| {
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
