# 6soz-nes

A decoupled NES emulator core written in Zig.

## Features

The project provides a Zig library module for loading and stepping NES state, with CPU integration through [`6soz-mos6502`](https://github.com/burakssen/6soz-mos6502), PPU/APU modules, controller input, framebuffer access, and cartridge-backed framebuffer/audio stepping.

### Supported Mappers

- Mapper 0 (NROM)
- Mapper 1 (MMC1)
- Mapper 3 (CNROM)
- Mapper 4 (MMC3) - Initial support

### Other Features
- iNES and NES 2.0 header parsing
- CHR ROM and CHR RAM
- Horizontal, vertical, and single-screen nametable mirroring
- Save RAM import/export for host-managed battery saves
- NTSC and PAL timing profiles

## Usage

The core is designed to be host-agnostic. Host applications can persist battery-backed saves by reading `Nes.saveRam()` and restoring it with `Nes.loadSaveRam()`.

Typical host loop:

```zig
const Nes = @import("nes").Nes;

var nes = Nes.init(allocator);
defer nes.deinit();

try nes.load(rom_bytes);
nes.reset();

while (true) {
    const result = try nes.stepFrame();
    // Use nes.framebuffer() to get pixels
    // Use result.audio for the frame's audio samples
}
```

## Requirements

- Zig 0.16.0 or newer

## Build & Test

```sh
zig build
zig build test
```

## License

See [LICENCE](LICENCE).
