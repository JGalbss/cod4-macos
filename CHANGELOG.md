# Changelog

All notable changes to this fork are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

This fork is a porting effort of [KisakCOD](https://github.com/SwagSoftware/KisakCOD)
to the Nintendo Switch (homebrew via devkitPro/libnx). Versions `0.x.y` indicate
pre-playable work; `1.0.0` will be tagged when a single-player session runs on
real hardware.

## [Unreleased]

### Added
- **Mass-port session: ~113 upstream files in build**. Subdirectories
  now contributing real CoD4 code (not just shims): `universal` (11),
  `qcommon` (16), `script` (4), `EffectsCore` (4), `ragdoll` (4),
  `DynEntity` (1), `xanim` (4), `bgame` (7), `common` (1),
  `database` (6), `devgui` (2), `aim_assist` (1), `sound` (1),
  `cgame` (8 + cg_event), `cgame_mp` (6), `client` (3),
  `client_mp` (5), `server` (1), `server_mp` (5), `game` (6),
  `physics` (4), `stringed` (1), `ui` (2), `ui_mp` (1).
  All compile with `-Werror`, zero warnings. The kisak_posix executable
  links clean every commit. Switch CMakeLists mirrored (env-blocked
  verification but identical file set except `brush_edges` deferred
  for GCC).

  Each landed file required some combination of:
  - `[[maybe_unused]]` tags on hex-rays scratch locals (the common case);
  - precedence-parenthesization fixes for `&&` within `||`;
  - explicit `(int)` / `(uintptr_t)` casts where a 32-bit literal or
    pointer round-trips through a smaller-than-pointer integer cell
    (KISAKHACK pattern, documented per-site in source comments);
  - `sizeof(arr[i++])` → `sizeof(arr[0])` to drop the unevaluated
    side-effect warning hex-rays generates;
  - return-type alignment with the declared upstream signature
    (many `bool`/`int`/`char`/`unsigned char`/`double` confusions).

  Compile-clean source files prepared during the session but
  deliberately deferred from the build because each drags a large
  cascade of stubs in subsystems we haven't built yet:
  - `cgame_mp/cg_servercmds_mp` (50+ CG_/CL_/FX_/SND_/UI_ message stubs)
  - `cgame_mp/cg_predict_mp/snapshot_mp/view_mp/players_mp` (30-60 each)
  - `client_mp/cl_input` + `cl_parse_mp` (cl_* dvars + MSG_Write*)
  - `server_mp/sv_init_mp/sv_snapshot_mp/sv_voice_mp` (sv_* dvars)
  - `game/g_helicopter/g_hudelem/g_items` (vehHelicopter dvars)
  - `cgame/cg_ammocounter/cg_effects_load_obj/cg_laser/cg_shellshock`
    (bgame Ammo/Clip/Shellshock/Hud helpers)
  - `xanim/xmodel_load_phys_collmap` (ODE)

- `src/posix/posix_backbone_stubs.cpp` grew from the initial ~180 entry
  points to ~600+ stubs, all bucketed by subsystem cascade. Real
  implementations for libc-flavored helpers; safe-default stubs for
  Sys/FS/Con; opaque-storage globals for the larger structs (sv,
  svsHeader, cgsArray, cgMedia, level, g_entities, etc.).

- `src/posix/kisak_compat.h` additions:
  - `_BitScanReverse` / `_BitScanForward` (POSIX shims via
    `__builtin_clz`/`__builtin_ctz`).
  - `EnterCriticalSection` / `LeaveCriticalSection` /
    `InitializeCriticalSection` / `DeleteCriticalSection` no-op shims.
  - `OVERLAPPED` struct (Win32 async I/O placeholder).
  - `InterlockedExchangeAdd` template (atomic-fetch-add).

- **qcommon backbone batch lands**: `cmd.cpp`, `common.cpp`, `files.cpp`,
  `universal/dvar.cpp`, `universal/dvar_cmds.cpp` now all compile clean
  with `-Werror` and link into the `kisak_posix` / `kisak_switch`
  executables. This is the load-bearing layer the rest of the engine
  hangs off — cvar registration, command parsing, file system, the
  main Com_Init / Com_Frame loop. Six of the deepest 32-bit-pointer
  truncation sites were bridged with the KISAKHACK pattern
  (`(int)(uintptr_t)`) and tracked in `docs/RISKS.md`.
- `src/posix/posix_backbone_stubs.cpp` — ~180 entry points across
  CL_/SV_/DB_/SND_/UI_/R_/Scr_/NET_/FS_/Hunk_/PMem_/Sys_/Info_/MSG_/...
  plus 14 globals (`sv`, `bgs`, `clientUIActives`, fs_*, loc_language,
  com_fileAccessed, updateScreenCalled). Real impls for libc-flavored
  helpers (Z_Malloc/Free, CopyString/FreeString, Com_sprintf,
  Com_DefaultExtension, I_strncmp/strncat/strlwr, FS_FilenameCompare);
  safe-default stubs for FS/Sys/Con (force callers down early-out
  paths); hard stubs for CL_/SV_/DB_/SND_/UI_/R_/Scr_ silently drop
  calls. Each block deletes itself when its real source file lands.
- `src/buildnumber.h` — static `BUILD_NUMBER 0` + `getBuildNumber()`
  decl. Upstream auto-generates this on Windows; we ship a static 0.
- `__rdtsc()` (steady_clock-backed), `PF_NON_TEMPORAL_LEVEL_ALL`,
  `PreFetchCacheLine`, `_snprintf` added to `kisak_compat.h`.
- `src/qcommon/thread_context.h` — `ThreadContext_t` enum extracted
  from `gfx_d3d/rb_backend.h` so POSIX/Switch can include it without
  pulling `<d3d9.h>`. `KISAK_THREAD_CONTEXT_T_DEFINED` guard prevents
  redefinition when `common.cpp` includes both headers transitively.

### Changed
- `qcommon/threads.cpp` is **deliberately not in the build**. It's
  934 lines of Win32-only threading (CreateThread / CreateEvent /
  WaitForSingleObject everywhere). Replaced wholesale by pthread-
  backed `Sys_*` stubs in `posix_stubs.cpp` + `posix_backbone_stubs.cpp`.
  The single-threaded port doesn't need the real renderer/database/
  worker thread split yet. Documented in `docs/RISKS.md`.
- `posix_stubs.cpp` cleanup: removed the temporary Com_Printf/
  Com_PrintError/Com_Error stubs and the placeholders for
  `useFastFile`/`com_statmon`/`_copyDWord` — the real upstream
  `qcommon/common.cpp` now provides them.
- `scripts/switch/CMakeLists.txt` comments translated to English to
  match the project-wide English policy.

### Added

- Fork initialized from `SwagSoftware/KisakCOD@master`.
- `port/switch` branch created for porting work.
- Scaffolding: `CHANGELOG.md`, `CONTRIBUTING.md`, `.editorconfig`,
  `.github/workflows/ci.yml`, issue/PR templates.
- `docs/SWITCH_PORT.md` with subsystem map and port phases.
- `KISAK_TARGET` CMake cache variable (`windows|posix|switch`) with
  auto-detection based on the host system / toolchain.
- POSIX skeleton under `src/posix/` with `posix_main.cpp` (placeholder entry
  point) and `README.md` mapping the upstream `src/win32/*.cpp` files that
  will be ported into that folder.
- `scripts/posix/CMakeLists.txt` producing the `bin/posix/kisak_posix`
  executable when `KISAK_TARGET=posix`. First binary of the port that builds
  end-to-end off Windows.
- First upstream source integrated into the POSIX build:
  `src/universal/base64.cpp` (MIT-derived encoder/decoder, no Win32
  dependencies). `posix_main.cpp` calls `b64_encode` as a linkage smoke test.
- `src/posix/kisak_compat.h`: MSVC compatibility shim providing `__cdecl`,
  `__stdcall`, `__fastcall`, `__forceinline`, `__declspec`,
  `__int8/16/32/64`, and `__pragma`. Force-included by the build before every
  source file. Covers the ~3.7k MSVC keyword usages in upstream without
  invasive patches.
- `src/posix/posix_assert.cpp`: stub implementation of `MyAssertHandler`
  (prints to stderr and aborts). Allows linking upstream files that call
  `MyAssertHandler` directly (not via the `iassert` macro).
- `src/posix/posix_stubs.cpp`: provisional stubs for `I_stricmp` (maps to
  POSIX `strcasecmp`), `AxisToQuat` (returns identity quaternion), and
  `Vec2Normalize` (portable implementation). Removable once their owning
  files are properly ported.
- Three new upstream files integrated into the POSIX build:
  `src/universal/com_math_anglevectors.cpp`, `com_convexhull.cpp`,
  `com_constantconfigstrings.cpp`. They compile and link on macOS arm64.
- **First homebrew `.nro` generated**: `scripts/switch/CMakeLists.txt`
  cross-compiles the same skeleton (`posix_main` + stubs + 4 upstream files)
  with devkitA64+libnx, producing `bin/switch/kisak_switch.elf` (2.6 MB,
  ARM64 static-pie) and `bin/switch/kisak_switch.nro` (166 KB,
  `HOMEBREWNRO0` magic). Loadable in Atmosphere CFW or Ryujinx.
- **First rendered pixel**: `src/switch/switch_main.cpp` replaces the
  `consoleInit`-based entry point with a full GLES2 pipeline (EGL +
  mesa-nouveau via libnx). Renders an RGB triangle into the screen
  framebuffer using our own vertex/fragment shaders. NRO grows to ~5.8 MB
  (mesa-nouveau is statically linked). Press `+` to exit.
- **Animated triangle**: vertex shader gains `uniform float u_time` and
  applies a Z-axis 2D rotation; monotonic time via libnx's
  `armGetSystemTick` + `armTicksToNs`. Proves uniforms + transforms + time
  on the graphics pipeline.
- **`src/gfx_gl/`** (new): GLES2 renderer extracted from `switch_main.cpp`
  with `init()` / `set_viewport()` / `render_frame(time)` / `shutdown()`
  API, agnostic to windowing. `switch_main.cpp` now handles only the libnx
  + EGL bootstrap and the main loop.
- **POSIX desktop parity**: `src/posix/posix_gl_main.cpp` (new) uses SDL2
  to create a window + GL 2.1 Compat context and calls the same `gfx_gl`
  module the Switch build uses. `kisak_posix` on macOS arm64 now opens a
  window with the same rotating triangle. Lets us iterate on shaders /
  geometry without round-tripping through Ryujinx. Esc closes the window.
- 3D upgrade: cube with perspective projection, depth test, MVP via GLM.
  Replaces the 2D triangle. Shader uses `uniform mat4 u_mvp`; vertices are
  now `vec3`. Camera at (0,0,3) looking at origin; cube rotates on Y and X.
- `src/qcommon/thread_context.h`: `ThreadContext_t` enum extracted from
  `gfx_d3d/rb_backend.h` so it can be included on POSIX/Switch targets
  without pulling `<d3d9.h>`. `qcommon/threads.h` now uses this header on
  non-Windows code paths.
- `src/universal/q_parse.cpp` brought into the POSIX build — the upstream
  Quake3-derived text parser. Compiles after fixing `qcommon/threads.h` to
  guard `<gfx_d3d/rb_backend.h>` behind `#ifdef _WIN32`. Links against new
  stubs (`Com_Printf`, `Com_PrintError`, `Com_Error`, `Sys_IsMainThread` /
  `IsRenderThread` / `IsDatabaseThread`) in `src/posix/posix_stubs.cpp`.
  Real implementations come when `qcommon/common.cpp` and
  `qcommon/threads.cpp` are ported.
- `_vsnprintf` → `vsnprintf` macro shim in `kisak_compat.h` (MSVC CRT
  underscore prefix not present on POSIX/newlib).
- `src/universal/com_shared.cpp` brought into POSIX + Switch builds — the
  upstream's central shared utilities (Com_Memset/Memcpy, Com_Milliseconds,
  Com_RealTime, Com_Filter, etc.). Required new stubs `_copyDWord` (loop
  replacing the x86 `rep stosd` inline asm upstream uses) and `I_stristr`
  (case-insensitive substring search). Also added `_time64`/`_localtime64`
  inline bridges in `kisak_compat.h` to handle the `__int64` vs `time_t`
  type difference between MSVC and POSIX.
- `src/universal/aabbtree.cpp` brought into POSIX + Switch builds — AABB
  tree spatial partitioning used by collision and ray-cast subsystems.
  Required adding underlying type to `enum team_t` forward declaration in
  `bg_public.h` (ISO C++ rejects forward enum decls without explicit
  underlying type), guarding the `sizeof(FxEffectDef) == 32` and
  `sizeof(FxImpactTable) == 8` static_asserts in `gfx_d3d/fxprimitives.h`
  with `UINTPTR_MAX == 0xFFFFFFFFu`, and adding portable `ClearBounds` /
  `ExpandBounds` stubs in `posix_stubs.cpp`.
- `src/universal/profile.cpp` brought into POSIX + Switch builds — the
  upstream profiler (used by both engine + game code). Required guarding
  `<Windows.h>` in the .cpp behind `_WIN32`, adding `LARGE_INTEGER` type
  and `QueryPerformanceCounter` / `QueryPerformanceFrequency` declarations
  to `kisak_compat.h`, providing portable `std::chrono::steady_clock`-
  backed implementations in `posix_stubs.cpp`, plus stubs for `va`,
  `Sys_GetValue`, `I_strncpyz`, `I_strnicmp`. Also removed `volatile` from
  the `ProfileReadable` struct definition (GCC rejects `volatile struct
  X { ... };` syntax; objects can still be declared volatile at use site).
- `src/win32/win_local.h` made portable: the `<dinput.h>`, `<winsock.h>`,
  `<wsipx.h>` includes are now also guarded by `_WIN32` (not only
  `!_XBOX`). Files that include `win_local.h` on POSIX get a header that
  parses but offers no Win32-specific function bodies.
- More Win32 types added to `kisak_compat.h` to allow `win_local.h` to
  parse cleanly on POSIX/Switch: `LRESULT`, `WPARAM`, `LPARAM`, `WINAPI`
  (no-op), `OSVERSIONINFO` (struct), `_RTL_CRITICAL_SECTION` /
  `CRITICAL_SECTION` (struct). These are declarations only — call sites
  using them never execute on non-Windows.
- `src/posix/include_shims/zlib/zlib.h`: tiny forwarder so upstream code
  using `#include <zlib/zlib.h>` resolves to **system zlib** (macOS SDK
  on POSIX, `switch-zlib` on Switch). The bundled `deps/zlib/` headers
  are pre-1.2 era and fail to define `Byte` on Apple platforms.
- `src/universal/memfile.cpp` brought into POSIX + Switch builds — the
  upstream's in-memory file abstraction (`MemoryFile` with segments,
  used by save/load and asset streaming). Required fixing a hex-rays
  decompilation bug in `MemFile_CopySegments` where a pointer was cast to
  `_DWORD` and subtracted from `bufferSize`, losing the upper 32 bits on
  64-bit. Reconstructed using proper pointer arithmetic
  (`segmentStart - buffer`). Function had only a commented-out caller,
  so behaviour validated by inspection.

### Fixed
- Dead `va_copy(ap, va); ap = 0;` lines in `Com_ScriptError` and
  `Com_ScriptErrorDrop` of `q_parse.cpp` — hex-rays decompilation artifacts
  where `ap` was declared as `char *` (matching MSVC `va_list = char*`) but
  never read. The `va_copy` broke GCC builds on Switch (devkitA64) where
  `va_list` is a struct, not a `char *`. Removed; no functional change.
- `AxisToQuat` stub replaced with a real Shepperd's-method implementation
  in `posix_stubs.cpp`. The placeholder identity-quaternion version was
  producing wrong rotations for any bone/animation/ragdoll math that called
  it; this version is numerically stable and correct.
- `Sys_GetValue` stub replaced with a real `pthread_key_create`-backed TLS
  implementation. 16 slots, lazily initialized via `std::call_once`. Added
  `Sys_SetValue` companion. Multi-threaded subsystems coming online before
  `qcommon/threads.cpp` is properly ported now have working per-thread
  context storage.
- `va` rotating buffer enlarged from 8 to 32 slots to match upstream. Call
  chains like `Com_Printf("%s %s %s", va(...), va(...), va(...))` with up
  to 32 outstanding strings now work without earlier slots being
  overwritten.

### Changed
- **Zero-warnings policy** enforced. Both POSIX and Switch builds now
  pass `-Werror` and have **all sign-compare warnings fixed at the site**
  with explicit casts (no more `-Wno-sign-compare` suppression). Sites
  audited and fixed: `base64.cpp`, `aabbtree.cpp`, `com_constantconfigstrings.cpp`,
  `com_convexhull.cpp`, `q_parse.cpp` (also added missing parentheses on 9
  `&&`-within-`||` precedence warnings), `com_shared.cpp` (Com_Prefetch
  wrapped in same `#if 0` as its only call site; unused vars cast to void).
  Headers with unused `static const char *` name tables (`bg_public.h`
  `entityTypeNames`/`eventnames`, `qcommon.h` `WeaponStateNames`) marked
  with `[[maybe_unused]]`.

### Fixed
- Strict-aliasing UB in the `BYTEn`/`WORDn`/`DWORDn` (and signed variants)
  macros in `q_shared.h`. Added typedefs with
  `__attribute__((__may_alias__))` on GCC/clang, eliminating the
  `-Wstrict-aliasing` warning that showed up on the Switch (GCC) build and
  the latent UB that could manifest under aggressive optimization.

### Changed
- CI workflow is now **manual-only** (`workflow_dispatch`). Push/PR triggers
  removed while the port is in rapid iteration to avoid email spam.
  Reinstate once the pipeline stabilizes.
- POSIX and Switch builds now use `-Wno-sign-compare`. Upstream source is
  reverse-engineered (hex-rays never propagates signedness), with dozens of
  `int` vs `unsigned int` comparison sites that are cosmetic noise. Will be
  re-enabled per subsystem during signedness audit.
- `src/posix/kisak_compat.h`: also includes `<climits>` (for
  `INT_MIN`/`INT_MAX` used in `DvarLimits`) and `<cstdlib>` plus macros
  `random` → `kisak_random` and `crandom` → `kisak_crandom` (avoids
  collision with POSIX `<stdlib.h>`). `__int8/16/32/64` are now `#define`
  instead of `typedef` — preserves the use of `unsigned __int8` in upstream.
- `src/universal/q_shared.h`: added an `#else` block to the `#ifdef WIN32`
  with POSIX equivalents for `MAC_STATIC`, `CPUSTRING` (detects
  Switch/macOS/Linux), `ID_INLINE`, `BigShort`/`BigLong` (via
  `__builtin_bswap*`), `LittleShort`/`LittleLong`/`LittleFloat` (no-ops on
  little-endian), `PATH_SEP = '/'`.
- `src/qcommon/qcommon.h`: `<xmmintrin.h>` and `<intrin.h>` includes are
  now guarded by architecture (x86 only); `SnapFloatToInt(float/double)`
  gains an ARM64 fallback using `std::lrintf` / `std::lrint` — same
  round-to-nearest-even rounding as `_mm_cvtss_si32`.
- `static_assert(sizeof(X) == N)` in `q_shared.h`, `qcommon.h`, and
  `msg_mp.h` now gated by `UINTPTR_MAX == 0xFFFFFFFFu` (i.e., active only
  on 32-bit builds). On 64-bit the layouts change due to wider pointers —
  the 64-bit port will get its own dedicated phase.
- Root `CMakeLists.txt` refactored to support configuration on non-MSVC
  hosts. MSVC flags (`/MT /O2 /Ot /MP /W3 /Zi /permissive-`) are now
  wrapped in `if(MSVC)`. On `KISAK_TARGET ∈ {posix,switch}` the Windows
  subdirs (`mp/sp/dedi`) are skipped. Upstream Windows build behavior is
  unchanged.

### Notes
- Target toolchain: devkitPro/devkitA64 + libnx + mesa-nouveau (with
  potential migration to deko3d once the game runs and we need more
  performance).
- Intermediate work on macOS/Linux ARM64 before cross-compiling for Switch.
- `cmake -B build-posix -S .` now configures cleanly on macOS arm64
  (`target=posix`), ready for the next Phase 1 steps.

[Unreleased]: https://github.com/HenryKun55/KisakCOD-Switch/compare/v0.0.0...HEAD
