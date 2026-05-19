# 6soz-nes

A minimal NES emulator core written in Zig.

## Status

Early work-in-progress. The project currently provides a Zig library module for loading and stepping NES state, with CPU integration through [`6soz-core`](https://github.com/burakssen/6soz-core), PPU/APU modules, controller input, framebuffer access, and basic iNES mapper 0 cartridge support.

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
