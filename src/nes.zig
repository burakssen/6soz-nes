const std = @import("std");
const mos6502 = @import("mos6502");
const Timing = @import("timing");
const State = @import("state_io.zig");

pub const Ppu = @import("ppu");
pub const Apu = @import("apu");

pub const Bus = @import("bus.zig");
pub const Cartridge = @import("cartridge");

const Nes = @This();

const max_frame_audio_samples = 4096;
const max_step_audio_samples = 256;
const state_magic = "6SOZNES1";
const state_version: u8 = 1;

cpu: mos6502.Cpu = .{ .variant = .ricoh_2a03 },
bus: Bus,
ppu: Ppu = .{},
apu: Apu = .{},
input: Ppu.InputState = .{},
cart: ?Cartridge = null,
allocator: std.mem.Allocator,
frame_audio: [max_frame_audio_samples]f32 = [_]f32{0} ** max_frame_audio_samples,
frame_audio_count: usize = 0,
step_audio: [max_step_audio_samples]f32 = [_]f32{0} ** max_step_audio_samples,
step_audio_count: usize = 0,
timing: Timing = Timing.ntsc,
ppu_clock_accumulator: u64 = 0,
ppu_odd_frame: bool = false,

pub fn init(allocator: std.mem.Allocator) Nes {
    return .{
        .cpu = .{ .variant = .ricoh_2a03 },
        .ppu = .{},
        .bus = .{ .ppu = undefined },
        .apu = .{},
        .allocator = allocator,
        .frame_audio = [_]f32{0} ** max_frame_audio_samples,
        .frame_audio_count = 0,
        .step_audio = [_]f32{0} ** max_step_audio_samples,
        .step_audio_count = 0,
        .timing = Timing.ntsc,
        .ppu_clock_accumulator = 0,
        .ppu_odd_frame = false,
    };
}

pub fn reset(self: *Nes) void {
    self.connectDevices();
    self.ppu_clock_accumulator = 0;
    self.ppu_odd_frame = false;
    self.cpu.reset(&self.bus);
}

pub fn deinit(self: *Nes) void {
    if (self.cart) |*c| c.deinit(self.allocator);
    self.cart = null;
    self.bus.mapper = null;
    self.ppu.mapper = null;
}

pub fn load(self: *Nes, data: []const u8) !void {
    var replacement = try Cartridge.load(self.allocator, data);
    errdefer replacement.deinit(self.allocator);

    if (self.cart) |*c| c.deinit(self.allocator);
    self.cart = replacement;
    self.setTiming(switch (self.cart.?.timing_mode) {
        .ntsc => Timing.ntsc,
        .pal => Timing.pal,
        .multiple, .dendy => unreachable,
    });
    self.connectDevices();
}

pub fn step(self: *Nes) !Ppu.StepResult {
    self.connectDevices();
    self.latchInput();
    self.step_audio_count = 0;
    self.bus.setCpuCycleParity(self.cpu.cycles);
    const cpu_result = try self.cpu.step(&self.bus);
    const dma_cycles = self.bus.takeDmaStallCycles();
    var total_cpu_cycles = @as(u32, cpu_result.cycles);
    total_cpu_cycles += dma_cycles;
    self.cpu.cycles += dma_cycles;

    total_cpu_cycles += try self.advanceDevices(@as(u32, cpu_result.cycles), &self.bus);
    if (dma_cycles > 0) total_cpu_cycles += try self.advanceDevices(dma_cycles, &self.bus);

    const mapper_irq = if (self.cart) |*c| c.mapper.irqActive() else false;
    if (self.apu.pollIrq() or mapper_irq) {
        const irq_cycles = self.cpu.irq(&self.bus);
        if (irq_cycles > 0) {
            total_cpu_cycles += irq_cycles;
            total_cpu_cycles += try self.advanceDevices(irq_cycles, &self.bus);
        }
    }
    const frame_complete = self.ppu.takeFrameComplete();

    return .{
        .cycles = total_cpu_cycles,
        .audio = self.step_audio[0..self.step_audio_count],
        .frame_complete = frame_complete,
    };
}

pub fn stepFrame(self: *Nes) !Ppu.StepResult {
    self.frame_audio_count = 0;
    var frame_cycles: u32 = 0;

    while (true) {
        const result = try self.step();
        frame_cycles += result.cycles;
        try self.appendFrameAudio(result.audio);

        if (result.frame_complete) {
            return .{
                .cycles = frame_cycles,
                .audio = self.frame_audio[0..self.frame_audio_count],
                .frame_complete = true,
            };
        }
    }
}

pub fn setInput(self: *Nes, input: Ppu.InputState) void {
    self.input = input;
}

pub fn framebuffer(self: *Nes) []const u32 {
    return self.ppu.displayFramebuffer();
}

pub fn frameRate(self: *const Nes) u16 {
    return self.timing.frame_rate;
}

pub fn audioSampleRate(_: *const Nes) u32 {
    return Apu.sample_rate;
}

pub fn saveRam(self: *const Nes) ?[]const u8 {
    if (self.cart) |*c| return c.saveRam();
    return null;
}

pub fn loadSaveRam(self: *Nes, data: []const u8) !void {
    if (self.cart) |*c| return c.loadSaveRam(data);
    return error.NoCartridgeLoaded;
}

pub fn saveState(self: *const Nes, allocator: std.mem.Allocator) ![]u8 {
    var state = std.Io.Writer.Allocating.init(allocator);
    defer state.deinit();
    const writer = &state.writer;

    try writer.writeAll(state_magic);
    try State.writeValue(writer, state_version);
    try State.writeValue(writer, self.cpu);
    try saveBusState(writer, &self.bus);

    var ppu = self.ppu;
    ppu.mapper = null;
    try State.writeValue(writer, ppu);

    try State.writeValue(writer, self.apu);
    try State.writeValue(writer, self.input);
    try State.writeValue(writer, self.timing);
    try State.writeValue(writer, self.ppu_clock_accumulator);

    if (self.cart) |*cart| {
        try State.writeValue(writer, true);
        const cart_state = try cart.saveState(self.allocator);
        defer self.allocator.free(cart_state);
        try State.writeValue(writer, @as(u32, @intCast(cart_state.len)));
        try writer.writeAll(cart_state);
    } else {
        try State.writeValue(writer, false);
    }

    return state.toOwnedSlice();
}

pub fn loadState(self: *Nes, data: []const u8) !void {
    var state = std.Io.Reader.fixed(data);
    const reader = &state;
    try State.expectBytes(reader, state_magic);
    if ((try State.readValue(reader, u8)) != state_version) return State.Error.UnsupportedStateVersion;

    const cpu = try State.readValue(reader, mos6502.Cpu);
    const bus_state = try loadBusState(reader);
    var ppu: Ppu = undefined;
    try State.readInto(reader, &ppu);
    const apu = try State.readValue(reader, Apu);
    const input = try State.readValue(reader, Ppu.InputState);
    const timing = try State.readValue(reader, Timing);
    const ppu_clock_accumulator = try State.readValue(reader, u64);
    const has_cart = try State.readValue(reader, bool);

    if (has_cart) {
        if (self.cart) |*cart| {
            const cart_state_len = try State.readValue(reader, u32);
            const cart_state = try State.readBytes(reader, cart_state_len);
            try cart.loadState(cart_state);
        } else {
            return error.NoCartridgeLoaded;
        }
    } else if (self.cart != null) {
        return State.Error.StateKindMismatch;
    }
    try State.done(reader);

    ppu.mapper = null;
    self.cpu = cpu;
    restoreBusState(&self.bus, bus_state);
    self.ppu = ppu;
    self.apu = apu;
    self.input = input;
    self.timing = timing;
    self.ppu_clock_accumulator = ppu_clock_accumulator;
    self.ppu_odd_frame = false;
    self.frame_audio_count = 0;
    self.step_audio_count = 0;
    self.connectDevices();
}

fn latchInput(self: *Nes) void {
    self.bus.setControllerState(0, self.input.toNesControllerByte());
}

fn appendFrameAudio(self: *Nes, audio: []const f32) !void {
    if (audio.len > self.frame_audio.len - self.frame_audio_count) return error.AudioBufferOverflow;
    @memcpy(self.frame_audio[self.frame_audio_count..][0..audio.len], audio);
    self.frame_audio_count += audio.len;
}

fn appendStepAudio(self: *Nes, audio: []const f32) !void {
    if (audio.len > self.step_audio.len - self.step_audio_count) return error.AudioBufferOverflow;
    @memcpy(self.step_audio[self.step_audio_count..][0..audio.len], audio);
    self.step_audio_count += audio.len;
}

fn advanceDevices(self: *Nes, cycles: u32, cpu_bus: anytype) !u32 {
    var extra_cycles: u32 = 0;
    var pending = cycles;

    while (pending > 0) {
        const current = pending;
        pending = 0;
        self.ppu_clock_accumulator += @as(u64, current) * self.timing.ppu_clock_numerator;
        const ppu_ticks = self.ppu_clock_accumulator / self.timing.ppu_clock_denominator;
        self.ppu_clock_accumulator %= self.timing.ppu_clock_denominator;

        var i: u64 = 0;
        while (i < ppu_ticks) : (i += 1) {
            const was_frame_complete = self.ppu.frame_complete;
            if (self.ppu.tickWithOddFrameSkip(self.ppu_odd_frame)) {
                const nmi_cycles = self.cpu.nmi(cpu_bus);
                extra_cycles += nmi_cycles;
                pending += nmi_cycles;
            }
            if (!was_frame_complete and self.ppu.frame_complete) {
                self.ppu_odd_frame = !self.ppu_odd_frame;
            }
        }

        const reader = Apu.MemoryReader.init(&self.bus);
        const apu_result = self.apu.tickWithMemory(current, reader);
        try self.appendStepAudio(apu_result.audio);

        if (apu_result.dmc_stall_cycles > 0) {
            self.cpu.cycles += apu_result.dmc_stall_cycles;
            extra_cycles += apu_result.dmc_stall_cycles;
            pending += apu_result.dmc_stall_cycles;
        }
    }

    return extra_cycles;
}

fn setTiming(self: *Nes, timing: Timing) void {
    self.timing = timing;
    self.ppu.timing = timing;
    self.apu.setTiming(timing);
    self.ppu_clock_accumulator = 0;
    self.ppu_odd_frame = false;
}

fn connectDevices(self: *Nes) void {
    self.bus.ppu = &self.ppu;
    self.bus.apu = &self.apu;
    if (self.cart) |*c| {
        self.bus.mapper = &c.mapper;
        self.ppu.mapper = &c.mapper;
    }
}

const BusState = struct {
    ram: [2048]u8,
    controller_state: [2]u8,
    controller_shift: [2]u8,
    controller_reads: [2]u8,
    controller_strobe: bool,
    dma_stall_cycles: u16,
    cpu_cycle_is_odd: bool,
};

fn saveBusState(writer: *std.Io.Writer, bus: *const Bus) !void {
    try State.writeValue(writer, BusState{
        .ram = bus.ram,
        .controller_state = bus.controller_state,
        .controller_shift = bus.controller_shift,
        .controller_reads = bus.controller_reads,
        .controller_strobe = bus.controller_strobe,
        .dma_stall_cycles = bus.dma_stall_cycles,
        .cpu_cycle_is_odd = bus.cpu_cycle_is_odd,
    });
}

fn loadBusState(reader: *std.Io.Reader) !BusState {
    return State.readValue(reader, BusState);
}

fn restoreBusState(bus: *Bus, state: BusState) void {
    bus.ram = state.ram;
    bus.controller_state = state.controller_state;
    bus.controller_shift = state.controller_shift;
    bus.controller_reads = state.controller_reads;
    bus.controller_strobe = state.controller_strobe;
    bus.dma_stall_cycles = state.dma_stall_cycles;
    bus.cpu_cycle_is_odd = state.cpu_cycle_is_odd;
}

fn makeTestRom(allocator: std.mem.Allocator, flags6: u8, chr_banks: u8) ![]u8 {
    const prg_size = 16 * 1024;
    const chr_size = @as(usize, chr_banks) * 8 * 1024;
    const trainer_size: usize = if ((flags6 & 0x04) != 0) 512 else 0;
    const prg_start = 16 + trainer_size;
    const chr_start = prg_start + prg_size;

    const data = try allocator.alloc(u8, chr_start + chr_size);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 1;
    data[5] = chr_banks;
    data[6] = flags6;

    data[prg_start] = 0xea;
    data[prg_start + 0x3ffc] = 0x00;
    data[prg_start + 0x3ffd] = 0x80;
    return data;
}

fn makeMapper1TestRom(allocator: std.mem.Allocator) ![]u8 {
    const prg_size = 128 * 1024;
    const data = try allocator.alloc(u8, 16 + prg_size);
    @memset(data, 0);
    @memcpy(data[0..4], "NES\x1a");
    data[4] = 8;
    data[5] = 0;
    data[6] = 0x12;
    data[16] = 0xea;
    data[16 + 0x3ffc] = 0x00;
    data[16 + 0x3ffd] = 0x80;
    return data;
}

test "NES loads, resets, steps, and exposes framebuffer" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();
    const result = try nes.step();

    try std.testing.expect(result.cycles > 0);
    try std.testing.expect(!result.frame_complete);
    try std.testing.expectEqual(@as(usize, (Ppu.Video.width - 16) * Ppu.Video.height), nes.framebuffer().len);
}

test "PAL ROM selects PAL metadata and fractional PPU clocking" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);
    rom[9] = 1;

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();
    _ = try nes.step();

    try std.testing.expectEqual(@as(u16, 50), nes.frameRate());
    try std.testing.expectEqual(Timing.Region.pal, nes.timing.region);
    try std.testing.expectEqual(@as(u64, 2), nes.ppu_clock_accumulator);
    try std.testing.expectEqual(@as(u32, 6), nes.ppu.cycles);
}

test "NES steps a complete frame" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();

    const result = try nes.stepFrame();

    try std.testing.expect(result.frame_complete);
    try std.testing.expect(result.cycles > 0);
    try std.testing.expect(result.audio.len > 0);
    try std.testing.expectEqual(@as(usize, (Ppu.Video.width - 16) * Ppu.Video.height), nes.framebuffer().len);
}

test "NES stepFrame resets frame audio between frames" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();

    const first = try nes.stepFrame();
    const first_audio_len = first.audio.len;
    const second = try nes.stepFrame();

    try std.testing.expect(first.frame_complete);
    try std.testing.expect(second.frame_complete);
    try std.testing.expect(first_audio_len > 0);
    try std.testing.expect(second.audio.len > 0);
    try std.testing.expect(second.audio.len < max_frame_audio_samples);
}

test "NES state round trips after frame with device and mapper state" {
    const allocator = std.testing.allocator;
    const rom = try makeMapper1TestRom(allocator);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.reset();
    _ = try nes.stepFrame();

    nes.cpu.a = 0x34;
    nes.bus.ram[0x10] = 0x56;
    nes.ppu.vram[0x20] = 0x78;
    nes.apu.status = 0x0f;
    nes.input = .{ .a = true, .start = true };
    nes.bus.write(0x6000, 0x9a);
    nes.bus.write(0x8000, 0x80);
    nes.bus.write(0xe000, 1);
    nes.bus.write(0xe000, 0);
    nes.bus.write(0xe000, 1);
    nes.bus.write(0xe000, 0);
    nes.bus.write(0xe000, 0);

    const state = try nes.saveState(allocator);
    defer allocator.free(state);

    nes.cpu.a = 0;
    nes.bus.ram[0x10] = 0;
    nes.ppu.vram[0x20] = 0;
    nes.apu.status = 0;
    nes.input = .{};
    nes.bus.write(0x6000, 0);
    nes.bus.write(0x8000, 0x80);

    try nes.loadState(state);

    try std.testing.expectEqual(@as(u8, 0x34), nes.cpu.a);
    try std.testing.expectEqual(@as(u8, 0x56), nes.bus.ram[0x10]);
    try std.testing.expectEqual(@as(u8, 0x78), nes.ppu.vram[0x20]);
    try std.testing.expectEqual(@as(u8, 0x0f), nes.apu.status);
    try std.testing.expect(nes.input.a);
    try std.testing.expect(nes.input.start);
    try std.testing.expectEqual(@as(u8, 0x9a), nes.bus.read(0x6000));
    try std.testing.expectEqual(@as(u5, 0x05), nes.cart.?.mapper.mmc1.prg_bank);
    try std.testing.expectEqual(@as(usize, 0), nes.frame_audio_count);
    try std.testing.expectEqual(@as(usize, 0), nes.step_audio_count);
    try std.testing.expect(nes.bus.mapper != null);
    try std.testing.expect(nes.ppu.mapper != null);
}

test "NES state loading rejects malformed payloads" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();
    try nes.load(rom);
    nes.reset();

    const state = try nes.saveState(allocator);
    defer allocator.free(state);

    try std.testing.expectError(State.Error.InvalidState, nes.loadState(state[0 .. state.len - 1]));

    const wrong_version = try allocator.dupe(u8, state);
    defer allocator.free(wrong_version);
    wrong_version[state_magic.len] = state_version + 1;
    try std.testing.expectError(State.Error.UnsupportedStateVersion, nes.loadState(wrong_version));
}

test "NES loads CHR RAM cartridges" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 0);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    try std.testing.expect(nes.cart.?.mapper.nrom.chr_is_ram);
    try std.testing.expectEqual(@as(usize, 8 * 1024), nes.cart.?.chr.len);
}

test "NES rejects four-screen mirroring until implemented" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x08, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try std.testing.expectError(error.UnsupportedMirroring, nes.load(rom));
}

test "NES exposes save RAM written through cartridge space" {
    const allocator = std.testing.allocator;
    const rom = try makeMapper1TestRom(allocator);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);
    nes.bus.write(0x6000, 0x5a);
    nes.bus.write(0x7fff, 0xa5);

    const save = nes.saveRam().?;
    try std.testing.expectEqual(@as(usize, 8192), save.len);
    try std.testing.expectEqual(@as(u8, 0x5a), save[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), save[0x1fff]);
}

test "NES imports save RAM into loaded cartridge" {
    const allocator = std.testing.allocator;
    const rom = try makeMapper1TestRom(allocator);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();

    try nes.load(rom);

    var save: [8192]u8 = [_]u8{0} ** 8192;
    save[0] = 0x44;
    save[0x1fff] = 0x88;

    try nes.loadSaveRam(&save);

    try std.testing.expectEqual(@as(u8, 0x44), nes.bus.read(0x6000));
    try std.testing.expectEqual(@as(u8, 0x88), nes.bus.read(0x7fff));
}

test "NES save RAM API handles missing cartridge and missing RAM" {
    const allocator = std.testing.allocator;
    var nes = Nes.init(allocator);
    defer nes.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), nes.saveRam());
    try std.testing.expectError(error.NoCartridgeLoaded, nes.loadSaveRam(&[_]u8{}));

    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    try nes.load(rom);
    try std.testing.expectEqual(@as(?[]const u8, null), nes.saveRam());
    try std.testing.expectError(error.NoSaveRam, nes.loadSaveRam(&[_]u8{}));
}

test "interrupt cycles advance every device" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0x00, 1);
    defer allocator.free(rom);

    var nes = Nes.init(allocator);
    defer nes.deinit();
    try nes.load(rom);
    nes.reset();
    nes.ppu.ctrl = 0x80;
    nes.ppu.scanline = 241;
    nes.ppu.cycles = 0;

    const extra = try nes.advanceDevices(1, &nes.bus);

    try std.testing.expectEqual(@as(u32, 7), extra);
    try std.testing.expectEqual(@as(u32, 24), nes.ppu.cycles);
}

test "frame audio overflow is reported" {
    var nes = Nes.init(std.testing.allocator);
    nes.frame_audio_count = nes.frame_audio.len;

    try std.testing.expectError(
        error.AudioBufferOverflow,
        nes.appendFrameAudio(&[_]f32{0}),
    );
}
