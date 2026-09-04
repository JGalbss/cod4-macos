# `src/posix/`

POSIX stubs and adapters that replace the Win32 APIs used by upstream
`src/win32/`. Compiled when `KISAK_TARGET ∈ {posix, switch}` (the Switch
target adds a `src/switch/` layer on top of this).

## Current state

Minimal skeleton — only the entry point and stubs needed to link the
upstream files we have brought into the build so far.

Win32 subsystems to be ported here, in expected order:

| Upstream (`src/win32/`) | Here | Status |
|---|---|---|
| `win_main.cpp` | `posix_gl_main.cpp` / `switch_main.cpp` | bootstrap done (SDL2 / libnx+EGL) |
| `win_input.cpp` | `posix_input.cpp` | pending (SDL2/HID) |
| `win_net.cpp` | `posix_net.cpp` | pending (BSD sockets) |
| `win_storage.cpp` | `posix_storage.cpp` | pending (XDG / SD card) |
| `win_syscon.cpp` | `posix_syscon.cpp` | pending (termios) |
| `win_wndproc.cpp` | `posix_wndproc.cpp` | pending (SDL2 events) |
| `win_voice.cpp` | `posix_voice.cpp` | pending (OpenAL capture) |
| `win_steam.cpp` | `posix_steam.cpp` | no-op stub (no Steamworks) |
| `win_localize.cpp` | `posix_localize.cpp` | pending |
| `win_configure.cpp` | `posix_configure.cpp` | pending |
| `win_net_debug.cpp` | `posix_net_debug.cpp` | pending |

Each port lands as a separate commit following the conventions in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md).
