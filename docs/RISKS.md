# Deferred risks and skipped work

Things the port is intentionally papering over, or files we tried to bring
in but had to defer. Each entry documents **what** was skipped, **why**,
and **when** it must be addressed.

Living document — append when something gets deferred; remove when it gets
fixed.

---

## 🔴 Will break before the game can run

### 1. 64-bit struct layout drift

**What:** The upstream binary is 32-bit. Many `static_assert(sizeof(X) == N)`
checks hard-code layouts that contain pointers (`void*`, `char*`, function
pointers). On a 64-bit port (macOS arm64, Switch arm64, Linux x86_64) those
pointers expand from 4 to 8 bytes and the struct grows. We guard these
asserts with `UINTPTR_MAX == 0xFFFFFFFFu` so the build continues.

**Why deferred:** Fixing requires either reformatting structs with
`#pragma pack` + placeholder slots, or implementing a pointer-translation
layer in the asset loader. Both are multi-day efforts that block all
incremental progress if attempted now.

**When this bites:** The moment we read serialized assets:
- `.d3dbsp` (BSP map files)
- `.ff` (FastFile asset bundles)
- `.iwd` (IWD asset packs — ZIP containers of binary blobs)
- XModel / XAnim / ImagePack

**Sites currently guarded** (grep `UINTPTR_MAX == 0xFFFFFFFFu` in repo):
- `src/universal/q_shared.h` — `StringTable`
- `src/qcommon/qcommon.h` — `SpawnVar`
- `src/qcommon/msg_mp.h` — `usercmd_s`
- `src/game/enthandle.h` — `EntHandleInfo`
- `src/gfx_d3d/fxprimitives.h` — `FxEffectDef`, `FxImpactTable`
- `src/bgame/bg_local.h` — `scr_anim_s`

**Recommended fix:** loader-side translation. Reads 32-bit on-disk offsets,
dereferences to 64-bit pointers, rewrites in place. Preserves on-disk asset
format compatibility — needed anyway to read CoD4 assets shipped on Steam.

### ~~2. `Com_Error` aborts instead of `longjmp`~~ ✅ PARTIAL

`qcommon/common.cpp` now lands in the build with its real upstream
`Com_Error` / `Com_Errorln` implementation, which does call into the
`setjmp` recovery path (`com_errorEntered` + `abortframe`). The
single-threaded port's `setjmp` jump target gets installed by the main
loop. Confirm under stress once the engine reaches a state where a
non-fatal error actually fires; until then this is "present and
plausibly correct" rather than "verified".

### 2.5 `qcommon/threads.cpp` skipped wholesale

**What:** The upstream is 934 lines of pure Win32 threading
(`CreateThread`, `CreateEvent`, `WaitForSingleObject`, `SuspendThread`,
`SetEvent`, `InterlockedIncrement`, ...) — none of it portable. Replaced
in our build by a thin pthread-backed `Sys_*` layer in
`src/posix/posix_stubs.cpp` + `src/posix/posix_backbone_stubs.cpp`.

**What we have:**
- Real pthread-key TLS for `Sys_GetValue`/`Sys_SetValue`.
- pthread mutex-backed `Sys_EnterCriticalSection`/`LeaveCriticalSection`.
- No-op `Sys_LockWrite`/`UnlockWrite` (FastCriticalSection RW lock).
- `Sys_IsMainThread`=true, `Sys_IsRenderThread`/`IsDatabaseThread`=false.
- `Sys_CreateThread` / `Sys_CreateEvent` / `Sys_WaitForSingleObject`:
  **not present** — engine calls into them will fail to link.

**Why deferred:** The renderer split, database thread, and worker
threads all need real implementations of these. Porting threads.cpp
literally means rewriting half the Win32 threading API in pthread.
Not blocking single-threaded bootstrap.

**When this bites:** First time the engine spawns the render thread
(`Sys_SpawnRenderThread` from common.cpp's init path). Right now
common.cpp **does** call `Sys_SpawnRenderThread`, so the engine **will**
hit unresolved Sys_Create* calls if it reaches that line. Either:
  (a) gate the call with `#ifdef KISAK_HEADLESS`, or
  (b) provide single-threaded pthread-backed Sys_Create* that just
      runs the render loop on the main thread (synchronous mode).

**Recommended fix:** option (b). Add to `posix_backbone_stubs.cpp`
once the engine actually reaches the threading init line.

### 2.6 ~180 hard stubs in `posix_backbone_stubs.cpp`

**What:** Roughly 180 CL_/SV_/DB_/SND_/UI_/R_/Scr_/NET_/FS_/Hunk_/PMem_
entry points return zero/null/empty. Backbone landing brought these in
without their real implementations.

**Why deferred:** Each subsystem (`client_mp/`, `server_mp/`,
`sound/`, `gfx_d3d/`, `ui/`, `script/`, `database/`, `network/`) is a
separate landing operation of comparable scope to the qcommon backbone.

**When this bites:**
- The moment the engine tries to do any real work post-init. With these
  stubs, `Com_Init` may complete but `Com_Frame` will silently no-op
  on rendering, input, sound, networking.
- `Z_Malloc`/`Z_Free` allocate via libc malloc but **lose** the
  per-pool/type tracking upstream relies on — leaks aren't tracked,
  cross-pool errors aren't caught.
- `FS_Initialized()=false` causes a few code paths to skip logging or
  file writes. Confirmed safe.

**Recommended fix:** Each stub block in `posix_backbone_stubs.cpp` is
meant to be deleted when its real source files land. The compile
errors that result are the desired signal that the wiring is now real.

### ~~3. `Sys_GetValue` returns null~~ ✅ RESOLVED

Replaced with a real `pthread_key_create`-backed implementation in
`src/posix/posix_stubs.cpp`. 16 TLS slots, lazily initialized via
`std::call_once`. `Sys_SetValue` companion also added. Will be superseded
when `qcommon/threads.cpp` is properly ported, but functionally correct
for the multi-threaded subsystems that come online before that.

### ~~4. `AxisToQuat` returns identity quaternion~~ ✅ RESOLVED

Replaced with the standard Shepperd's method axis-matrix → quaternion
conversion in `src/posix/posix_stubs.cpp`. Numerically stable variant
that picks the largest diagonal magnitude. Will be superseded when
`com_math.cpp` ports; until then, math is correct.

---

## 🟡 Likely to bite, manageable

### ~~5. `-Wno-sign-compare`~~ ✅ RESOLVED

Both POSIX and Switch builds now use `-Werror` with all warnings enabled.
All sign-compare warnings in our compiled files have been fixed at the
site with explicit casts. New files brought into the build must be
sign-compare clean; the compiler enforces it.

### 6. `volatile struct ProfileReadable` → `struct ProfileReadable`

**What:** Dropped `volatile` qualifier from the struct definition in
`src/universal/profile.h` (GCC rejects `volatile struct X { ... };`).

**Why deferred:** Clang/MSVC accept the upstream form; GCC doesn't. The
quick fix preserves single-threaded behavior.

**When this bites:** If profiling becomes multi-threaded with shared
`ProfileReadable` objects, the compiler could reorder reads/writes.

**Recommended fix:** declare individual instances `volatile` at the use
site when threaded profiling lands.

### 7. `va_copy(ap, va); ap = 0;` removed in `q_parse.cpp`

**What:** Two pairs of dead lines in `Com_ScriptError` /
`Com_ScriptErrorDrop` (`ap` was declared `char*` matching MSVC `va_list`,
never read).

**Why deferred:** The lines were truly dead — the compiler would optimize
them away regardless. Removed only because GCC fails to type-check
`va_copy(char*, struct va_list)`.

**When this bites:** Should not bite. Listed for transparency.

---

## 🟢 Low risk

### 8. 32-bit pointer cast in `pool_allocator.cpp`

**What:** `(unsigned int)&pool[itemSize * (itemIndex + 1)]` truncates a
64-bit pointer to 32 bits.

**Why deferred:** `pool_allocator.cpp` is not yet in the build. We don't
hit the bug.

**When this bites:** Only if a pool's backing buffer lives above the 4 GB
mark, which is unlikely for a 2007 game's data structures.

**Recommended fix:** when we bring `pool_allocator.cpp` in, change the
cast to `(uintptr_t)`.

### 9. Win32 type stubs in `kisak_compat.h`

**What:** `LRESULT`, `WPARAM`, `LPARAM`, `OSVERSIONINFO`,
`CRITICAL_SECTION`, etc. are declared so headers parse on non-Windows.

**Why:** Headers like `win_local.h` declare functions that take these
types. Without the typedefs, the headers wouldn't parse.

**When this bites:** Functions that *take* these types are never called
on POSIX — the call sites live in Win32-only code paths. Inert.

---

## Files attempted but currently deferred

Each row: we tried to compile this file into the POSIX build, hit a
blocker we chose not to resolve immediately, deferred to a focused
session.

| File | Blocker | Reason for deferring | Unblocks |
|---|---|---|---|
| `src/universal/com_memory.cpp` | `<zlib/zlib.h>` via `database.h` (header chain pulls `xanim`, `d3d9.h`) | zlib wiring is straightforward but `database.h` then pulls `r_gfx.h` which needs the full renderer. Memory allocator alone needs many more shims. | central memory tracking |
| `src/universal/com_files.cpp` | Same `database.h` chain → `d3d9.h` | File I/O entangled with asset DB headers; needs renderer stubs first. | filesystem |
| `src/universal/com_loadutils.cpp` | `<zlib/zlib.h>` not in include path | Simplest fix; could land soon by adding `-I deps` and stubbing zlib symbols. | asset load utilities |
| `src/universal/com_stringtable.cpp` | Same as above | Same fix path. | string table parser |
| `src/universal/com_math.cpp` | `<ode/ode.h>` via `xanim/dobj.h` | ODE physics not yet built for POSIX/Switch (deps/ode/ has the source but isn't compiled). | most math helpers; would let us remove `AxisToQuat`, `ClearBounds`, `ExpandBounds`, `Vec2Normalize` stubs. |
| `src/universal/q_shared.cpp` | `<d3d9.h>` via `gfx_d3d/r_model.h` | Pulls renderer code that depends on DX9. Needs renderer abstraction first. | core string utilities; would let us remove `va`, `I_stricmp`, `I_strnicmp`, `I_strncpyz`, `I_stristr` stubs. |
| `src/universal/fft.cpp` | `<d3d9.h>` via `fft.h → r_material.h` | Same renderer entanglement. | audio FFT processing. |
| `src/universal/com_sndalias.cpp` | `<msslib/mss.h>` (Miles Sound System) | Miles is proprietary; needs OpenAL-soft replacement layer. | sound alias system. |
| `src/universal/dvar.cpp` | `<Windows.h>` + win32/win_local + gfx_d3d/r_dvars + win32/win_net + devgui | Cvar system touches everything. Centralized; tackle after common.cpp / cmd.cpp port. | **the cvar registration / lookup system — central to engine init.** |
| `src/universal/physicalmemory.cpp` | `VirtualAlloc` (Win32 page allocator) | Needs POSIX `mmap` / Switch `svcMapMemory` replacement. Limited usage so not urgent. | physical memory pool. |
| ~~`src/universal/memfile.cpp`~~ ✅ in build (zlib shim wired, MemFile_CopySegments 64-bit pointer cast fixed). | | | |
| `src/universal/dvar_cmds.cpp` | `static_assert(sizeof(scr_anim_s) == 4)` (guarded but file not yet in build) | Static_assert now guarded; remaining blockers TBD on next attempt. | dvar registration commands. |

---

## Internal helper functions stubbed

Living in `src/posix/posix_stubs.cpp`. Each is provisional; should be
removed when the owning upstream file ports cleanly.

| Stub | Real owner | Behavior gap |
|---|---|---|
| `Com_Printf(channel, ...)` | `qcommon/common.cpp` | Ignores channel; everything to stdout. No log channel filtering. |
| `Com_PrintError(channel, ...)` | `qcommon/common.cpp` | Same as above, prefixed `[error]`, to stderr. |
| `Com_Error(code, ...)` | `qcommon/common.cpp` | Aborts. No `ERR_DROP` recovery. **High impact** — see entry 2. |
| `Sys_IsMainThread()` | `qcommon/threads.cpp` | Returns true unconditionally. Safe single-threaded. |
| `Sys_IsRenderThread()` | `qcommon/threads.cpp` | Returns false. Misleading once render thread spins up. |
| `Sys_IsDatabaseThread()` | `qcommon/threads.cpp` | Returns false. Same. |
| `Sys_GetValue(slot) / Sys_SetValue(slot, val)` | `qcommon/threads.cpp` | Real pthread_key TLS impl, 16 slots. Functional. |
| `MyAssertHandler` | `universal/assertive.cpp` | Prints + aborts. Loses upstream's clipboard / dialog UX, but that's Win32-only anyway. |
| `_copyDWord` | `qcommon/common.cpp` (inline asm) | Plain loop, auto-vectorizes to NEON. Functionally identical. |
| `I_stricmp / I_strnicmp / I_strncpyz / I_stristr` | `universal/q_shared.cpp` | Correct portable impls. No semantic gap. |
| `va` | `universal/q_shared.cpp` | 32-slot rotating buffer (matches upstream). Functional. |
| `Vec2Normalize` | `universal/com_math.cpp` | Correct portable impl. No semantic gap. |
| `ClearBounds / ExpandBounds` | `universal/com_math.cpp` | Correct portable impls. No semantic gap. |
| `AxisToQuat` | `universal/com_math.cpp` | Real Shepperd's-method impl. Mathematically correct. |
| `QueryPerformanceCounter / QueryPerformanceFrequency` | Native Win32 | `std::chrono::steady_clock`-backed; resolution is ns. Functionally equivalent. |
| `_time64 / _localtime64` (in `kisak_compat.h`) | Win32 CRT | POSIX `time` / `localtime` bridges. Functionally equivalent for years 1970-2038+ on 64-bit time_t. |
