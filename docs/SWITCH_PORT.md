# Nintendo Switch port — overview

This document describes the KisakCOD porting effort to the Nintendo Switch
via homebrew (devkitPro + libnx + Atmosphere CFW).

## Current state

**Phase 0 — Setup** ✅
- Fork created, `port/switch` branch active
- devkitA64/libnx toolchain installed
- Subsystem map completed

**Phase 1 — Intermediate macOS/Linux ARM64 port** ⏳ (in progress)
**Phase 2 — Switch cross-compile** (future)
**Phase 3 — Switch optimization** (future)

## Subsystems and strategy

| Subsystem | Upstream folder | Switch strategy |
|---|---|---|
| DX9 renderer | `src/gfx_d3d/` | Replace with GL/Vulkan backend (deko3d). Implement desktop GL first in `src/gfx_gl/`, then a Switch variant. |
| Win32 | `src/win32/` | POSIX stubs under `src/posix/`; a libnx layer in `src/switch/` for HID/socket/storage specifics. |
| Sound (Miles) | `src/sound/` | Replace the Miles wrapper with OpenAL-soft (already in devkitPro as `switch-openal-soft`). |
| Video (Bink) | `deps/binklib/` (headers) | Skip cinematics initially. FFmpeg available as a future fallback. |
| Steam SDK | `deps/steamsdk/` | Full no-op stub. Switch homebrew has no Steamworks. |
| ODE physics | `src/physics/ode/` + `deps/ode/` | Portable; recompile for ARM64. No source changes expected. |
| Voice audio (Speex) | `src/groupvoice/speex` | Portable; recompile. |
| Engine common | `src/qcommon`, `src/common`, `src/universal` | Audit inline x86 assembly and SSE intrinsics. Mostly portable. |
| GSC scripting | `src/script` | Portable; reference: [CoD2rev_Server](https://github.com/voron00/CoD2rev_Server). |
| Game logic | `src/game*`, `src/bgame`, `src/cgame*` | Portable; audit endianness and ARM64 alignment. CoD4 is 32-bit, audit `ptr↔int` casts. |
| Animation | `src/xanim` | Audit SIMD. |
| UI | `src/ui*` | Depends on the renderer; port after GL/Vulkan works. |
| DevGUI | `src/devgui` | Windows-only (dev tooling). Skip. |

## Platform constraints

- **CPU**: ARM Cortex-A57 quad-core (Tegra X1), AArch64. No SSE/AVX —
  replace with NEON or portable C.
- **GPU**: Nvidia Maxwell GM20B (~1 TFLOPS docked). APIs available: deko3d
  (low-level), Vulkan via deko3d-vk, or GLES 3.x via mesa-nouveau.
- **RAM**: 4 GB total, ~3.2 GB usable. CoD4 PC uses ~1.5 GB → fits, but with
  tight margins.
- **Storage**: microSD with high random-I/O latency — asset streaming needs
  care.
- **Endianness**: little-endian (compatible with x86).
- **Pointer width**: 64-bit (upstream is 32-bit) — audit all pointer↔int
  casts and structs with sizeof-dependent layouts.

## Legal constraints

- **Decompilation** (upstream): public reverse engineering work under
  GPL-3.0. Activision/IW have not pursued action.
- **CoD4 assets**: each user must own a copy. **Never commit** `.iwd`/`.ff`
  files.
- **Switch homebrew**: legal, but requires hardware modification (Atmosphere
  CFW). Distributing the `.nro` (assets excluded) is OK.
- **GPL-3.0**: forks/distributions must publish modified source.

## How to contribute

See [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Reference: Windows upstream build

To validate parity with upstream before/after each change, the original
Windows build still works following the [upstream README](../README.md).
macOS/Linux-only contributors can use a Windows VM + DirectX SDK 2010 +
VS 2022.
