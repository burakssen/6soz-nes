# 6soz-nes

A minimal NES emulator core written in Zig.

## Status

Early work-in-progress. The project currently provides a Zig library module for loading and stepping NES state, with CPU integration through [`6soz-core`](https://github.com/burakssen/6soz-core), PPU/APU modules, controller input, framebuffer access, and cartridge-backed framebuffer/audio stepping.

Supported cartridge features:

- iNES and NES 2.0 header parsing
- Mapper 0 / NROM support
- Mapper 1 / MMC1 support
- Initial mapper 4 / MMC3 support
- CHR ROM and CHR RAM
- Horizontal, vertical, and single-screen nametable mirroring
- Save RAM import/export for host-managed battery saves

Host applications can persist battery-backed saves by reading `Nes.saveRam()` and restoring it with `Nes.loadSaveRam()`. Four-screen mirroring is not implemented yet and is rejected at load time.

Typical host loop: load ROM bytes with `Nes.load`, optionally restore save bytes with `Nes.loadSaveRam`, call `Nes.reset`, then repeatedly call `Nes.stepFrame`, read `Nes.framebuffer`, play the returned audio samples, and persist `Nes.saveRam` when needed.

## Requirements

- Zig 0.16.0 or newer

## Build

```sh
zig build
```

## Test

```sh
zig build test
```

## License

See [LICENCE](LICENCE).
