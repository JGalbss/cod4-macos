// Stubs for upstream symbols referenced by the first ported files, whose
// definitions live in sources that do not yet compile on POSIX (xanim/ode,
// qcommon/threads.cpp using Windows.h, etc.).
//
// Each stub here is provisional: it prints a [stub] marker on stderr when
// called at runtime, returns a neutral value, and *must be removed* as soon
// as its owning file is properly ported. See docs/SWITCH_PORT.md.

#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h> // strcasecmp

#include <qcommon/threads.h>
#include <universal/q_shared.h>
#include <win32/win_local.h>

// Forward-decl to avoid pulling all of qcommon.h into the stubs file. Must
// match the definition in src/qcommon/qcommon.h:154.
enum errorParm_t : int;

// I_stricmp: declared in universal/q_shared.h, defined in q_shared.cpp.
// Direct POSIX equivalent.
// I_stricmp, I_strnicmp, I_strncpyz provided by src/universal/q_shared.cpp now.

// AxisToQuat: build a quaternion (x, y, z, w) from a 3x3 rotation matrix
// `mat` stored as row-major. Declared in universal/com_math.h; full
// upstream impl lives in com_math.cpp (not yet portable). Standard
// Shepperd's method — numerically stable variant that picks the largest
// diagonal magnitude to avoid division by small numbers.
//
// When com_math.cpp is brought into the build this definition collides
// with upstream's; remove it then.
#include <cmath>
// AxisToQuat provided by src/universal/com_math.cpp now.

// Vec2Normalize: declared in universal/com_math.h (line 230), defined in
// com_math.cpp line 559. Stub computes the normalize manually (without
// using vec2r to avoid dragging in the whole header) — should be correct
// enough that removing it when com_math.cpp ports causes no behavior diff.
// Vec2Normalize provided by src/universal/com_math.cpp now.

// Com_Printf / Com_PrintError / Com_Error now live in qcommon/common.cpp
// (the real implementations from upstream) once it joined the build.

// Preserve the engine's logical thread context independently of the Cocoa
// main thread.  The game loop itself runs on a secondary pthread on macOS,
// and renderer workers install their own context with Sys_InitThread.
namespace {
thread_local ThreadContext_t g_posixThreadContext = THREAD_CONTEXT_MAIN;
}

bool Sys_IsMainThread()     { return g_posixThreadContext == THREAD_CONTEXT_MAIN; }
bool Sys_IsRenderThread()   { return g_posixThreadContext == THREAD_CONTEXT_BACKEND; }
bool Sys_IsDatabaseThread() { return g_posixThreadContext == THREAD_CONTEXT_DATABASE; }

void Sys_InitThread(ThreadContext_t threadContext)
{
    g_posixThreadContext = threadContext;
    Com_InitThreadData(static_cast<int>(threadContext));
}

// Sys_WaitDatabaseThread: on Windows the loader hands a read to a worker thread and
// blocks here until it drains. This port reads fastfiles synchronously - ReadFileEx in
// kisak_compat.h preads and calls the (empty) completion routine inline - so by the time
// anyone can call this, the read has already finished and there is nothing to wait for.
// Becomes a real join when threads.cpp lands.
void Sys_WaitDatabaseThread() {}

// Sys_GetValue / Sys_SetValue: thread-local slot accessor. Upstream uses
// TLS to stash per-thread context (current parse session, render queue,
// etc.). Real impl uses pthread_key_create-allocated keys, lazily on
// first access. 16 slots ought to cover upstream's needs (the original
// uses no more than ~8).
#include <pthread.h>
#include <mutex>
namespace {
constexpr int KISAK_TLS_SLOTS = 16;
pthread_key_t  g_tls_keys[KISAK_TLS_SLOTS];
std::once_flag g_tls_init_flag;
void g_tls_init()
{
    for (int i = 0; i < KISAK_TLS_SLOTS; ++i) {
        pthread_key_create(&g_tls_keys[i], nullptr);
    }
}
} // namespace

void *Sys_GetValue(int valueIndex)
{
    std::call_once(g_tls_init_flag, g_tls_init);
    if (valueIndex < 0 || valueIndex >= KISAK_TLS_SLOTS) return nullptr;
    return pthread_getspecific(g_tls_keys[valueIndex]);
}

void Sys_SetValue(int valueIndex, void *value)
{
    std::call_once(g_tls_init_flag, g_tls_init);
    if (valueIndex < 0 || valueIndex >= KISAK_TLS_SLOTS) return;
    pthread_setspecific(g_tls_keys[valueIndex], value);
}

// va: Quake3's classic "vsprintf into rotating static buffer" utility.
// Defined in q_shared.cpp upstream, which we can't compile yet (drags in
// gfx_d3d/r_model.h). 32-slot rotation matches upstream's MAX_VA_STRING /
// "rotating buffer" count so call chains like
//   Com_Printf("%s %s %s", va("..."), va("..."), va("..."))
// never overwrite an earlier slot before it's consumed.
// va provided by src/universal/q_shared.cpp now.

// _copyDWord now lives in qcommon/common.cpp.

// QueryPerformanceCounter / Frequency: portable POSIX implementations
// using std::chrono's steady_clock. Granularity is nanoseconds → matches
// or exceeds Win32 QPC on most hardware. Declarations live in
// src/posix/kisak_compat.h.
#include <chrono>
BOOL QueryPerformanceCounter(LARGE_INTEGER *count)
{
    if (!count) return 0;
    using namespace std::chrono;
    const auto ns = duration_cast<nanoseconds>(
        steady_clock::now().time_since_epoch()).count();
    count->QuadPart = static_cast<long long>(ns);
    return 1;
}
BOOL QueryPerformanceFrequency(LARGE_INTEGER *freq)
{
    if (!freq) return 0;
    freq->QuadPart = 1000000000LL; // ticks per second (we report in ns)
    return 1;
}

// VirtualAlloc / VirtualFree shim — see kisak_compat.h comment.
#if defined(__SWITCH__)
// libnx has no sys/mman.h: fall back to plain malloc/free. Code paths that
// asked for RESERVE-only mappings will still get a contiguous backed buffer.
#include <atomic>
#include <cstdlib>
#include <malloc.h>
#include <switch.h>
constexpr size_t g_kisakArenaSize = 96u * 1024u * 1024u;
alignas(4096) unsigned char g_kisakArena[g_kisakArenaSize];
std::atomic<size_t> g_kisakArenaPos{0};

void *VirtualAlloc(void *addr, size_t size, unsigned int flags, unsigned int /*prot*/)
{
    if ((flags & MEM_RESERVE) == 0 && (flags & MEM_COMMIT) != 0 && addr != nullptr) {
        return addr;
    }
    // Engine hunks are big and long-lived; routing them through libnx
    // malloc fragments the C heap so badly that subsequent malloc(4 KiB)
    // calls fail. Carve them out of a dedicated static arena instead so
    // the newlib allocator stays clean.
    const size_t align = 32;
    const size_t alignedSize = (size + align - 1) & ~(align - 1);
    size_t pos = g_kisakArenaPos.fetch_add(alignedSize, std::memory_order_relaxed);
    if (pos + alignedSize > g_kisakArenaSize) {
        // Fall back to libnx malloc when the arena is exhausted —
        // shouldn't happen during boot but keeps later runtime allocs
        // from instantly fatal'ing.
        void *p = memalign(32, size);
        if (!p) return nullptr;
        std::memset(p, 0, size);
        return p;
    }
    return g_kisakArena + pos;
}
BOOL VirtualFree(void *addr, size_t /*size*/, unsigned int flags)
{
    if (!addr) return 0;
    if (flags & MEM_RELEASE) {
        // Arena allocations are never freed — they live until process
        // exit. The arena pointer compare can't be exact (we returned
        // mid-arena pointers) but the bounds check is fine, because the
        // static array is at a known compile-time address range.
        if (reinterpret_cast<unsigned char *>(addr) >= g_kisakArena &&
            reinterpret_cast<unsigned char *>(addr) <  g_kisakArena + g_kisakArenaSize) {
            return 1;
        }
        std::free(addr);
        return 1;
    }
    if (flags & MEM_DECOMMIT) { return 1; }
    return 0;
}
#else
#include <sys/mman.h>
void *VirtualAlloc(void *addr, size_t size, unsigned int flags, unsigned int /*prot*/)
{
    // COMMIT on an already-mapped region is a no-op for us — return the
    // address the caller asked us to commit (POSIX has no separate
    // commit step; the pages get backed lazily on first touch).
    if ((flags & MEM_RESERVE) == 0 && (flags & MEM_COMMIT) != 0 && addr != nullptr) {
        return addr;
    }
    // RESERVE or RESERVE|COMMIT — fresh anonymous mapping.
    void *p = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return nullptr;
    return p;
}
BOOL VirtualFree(void *addr, size_t size, unsigned int flags)
{
    if (!addr) return 0;
    if (flags & MEM_RELEASE) {
        // Win32 RELEASE requires size==0 and frees the whole reservation;
        // we don't track sizes, so the caller passes the original size via
        // a separate decommit (see Z_VirtualDecommitInternal) and we just
        // ignore the size here. If we ever leak, switch to a sidecar map.
        // Best-effort: no-op when size unknown.
        return 1;
    }
    if (flags & MEM_DECOMMIT) {
        if (size > 0) madvise(addr, size, MADV_DONTNEED);
        return 1;
    }
    return 0;
}
#endif

// Win32 UI stubs — see kisak_compat.h comment.
HWND GetActiveWindow() { return nullptr; }
int  MessageBoxA(HWND /*hWnd*/, const char *text, const char *caption,
                 unsigned int /*type*/)
{
    std::fprintf(stderr, "[messagebox] %s: %s\n",
                 caption ? caption : "(no caption)",
                 text ? text : "(no text)");
    return 6; // IDYES — assume user accepts. Upstream call sites use this
              // for config-change confirmation dialogs that block on Windows.
}

// Vec3Dot, Vec3NormalizeTo, Vec3Normalize, Vec3LengthSq provided by
// src/universal/com_math.cpp now.

// Vec3Sub, Vec3Mad provided by src/universal/com_math.cpp now.

// ProfLoad tracking: map-profile timing instrumentation. Stub no-ops
// until the profile-load subsystem is properly wired up. Forward-decl
// the enum so the mangled signature matches the upstream callers.
enum MapProfileTrackedValue : int;
// ProfLoad_BeginTrackedValue now in qcommon/com_profilemapload.cpp.
// ProfLoad_EndTrackedValue now in qcommon/com_profilemapload.cpp.

// === Vec3 / matrix math required by the cm_*.cpp collision files =========
// All real implementations (not placeholder stubs). When com_math.cpp
// finally ports, these collide with upstream's versions — remove then.

// Q_fabs, Vec3Length, Vec3DistanceSq, Vec3Distance, Vec3IsNormalized, Vec3Add,
// Vec3Cross, Vec3Scale, Vec3Lerp, Vec3MadMad, VecNCompareCustomEpsilon,
// MatrixTransformVector, MatrixTransposeTransformVector all provided by
// src/universal/com_math.cpp now.

// G_TransposeMatrix, G_RotatePoint provided by src/game/g_mover.cpp now.

// PlaneFromPoints, IntersectPlanes, SnapPointToIntersectingPlanes provided
// by src/universal/com_math.cpp now.

#include <new>

// Hunk_Alloc / Hunk_AllocAlign — provided by com_memory.cpp now.

// Sys_Error: fatal engine error. Same behaviour as Com_Error for now.
// On Switch, stderr is swallowed (no consoleInit when GL is up), so we also
// route the message through svcOutputDebugString so it lands in the Ryujinx
// log before abort()ing.
#ifdef __SWITCH__
#include <switch.h>
#endif
void Sys_Error(const char *fmt, ...)
{
    char buf[1024];
    int prefix = std::snprintf(buf, sizeof(buf), "[sys-fatal] fmt=<%s> ",
                               fmt ? fmt : "(null)");
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        std::vsnprintf(buf + prefix, sizeof(buf) - prefix, fmt, ap);
        va_end(ap);
    }
    std::fputs(buf, stderr);
    std::fputc('\n', stderr);
#ifdef __SWITCH__
    // svcOutputDebugString stops at the first NUL but accepts embedded \n,
    // so collapse newlines to ` | ` so the whole message survives the log.
    for (char *p = buf; *p; ++p) if (*p == '\n') *p = '|';
    svcOutputDebugString(buf, std::strlen(buf));
#endif
    std::abort();
}

// track_static_alloc_internal now provided by qcommon/mem_track.cpp.

// DB_FindXAssetHeader: asset lookup. Returns a default-constructed
// XAssetHeader (data=nullptr) so callers can fail gracefully. Real impl
// DB_FindXAssetHeader now provided by src/database/db_registry.cpp.

// XModelTraceLine now provided by xanim/xmodel.cpp.

// CM_LoadMapData_LoadObj: collision-model loader entry. Real impl lands
// with cm_load_obj.cpp (which depends on more renderer state). Until
// then, map data simply isn't loaded.
// void CM_LoadMapData_LoadObj(const char * /*name*/) {}  // provided by cm_load_obj.cpp now

// === Globals required by cm_load and friends ==============================
// Definitions of upstream globals so the linker resolves the externs.
// Sizes match upstream layouts on 32-bit; on 64-bit they may be slightly
// larger due to pointer growth in member structs but the storage is
// allocated dynamically and field accesses go through the upstream types
// (no runtime impact for what we currently exercise).

// THREAD_CONTEXT_COUNT comes from qcommon/thread_context.h on POSIX.
// TraceThreadInfo is a substantial struct; allocate a generous buffer that
// covers its size (~16 KB per slot). The collision code only writes to
// thread-local copies, never reads the array directly in the cm_* set we
// link today, so the storage is effectively dead.
// g_traceThreadInfo storage provided by src/universal/q_shared.cpp now.
// `g_traceThreadInfo` is declared `extern TraceThreadInfo array[N]` in
// upstream — we define the storage as an array via reinterpret_cast so
// the linker resolves both decl forms. Use `extern` linkage explicitly
// to avoid the const-pointer-treated-as-internal warning.
// g_traceThreadInfo provided by src/universal/q_shared.cpp now.

// useFastFile is now defined in qcommon/common.cpp (real upstream).

// === statmonitor.cpp deps ================================================

// Sys_Milliseconds: monotonic ms since process start. Real impl via
// std::chrono::steady_clock — collides with q_shared.cpp when it ports.
unsigned int Sys_Milliseconds()
{
    using namespace std::chrono;
    static const auto start = steady_clock::now();
    return static_cast<unsigned int>(
        duration_cast<milliseconds>(steady_clock::now() - start).count());
}

// Sys_EnterCriticalSection / LeaveCriticalSection: upstream uses Win32
// CRITICAL_SECTION indexed by thread-domain enum. Win32 CRITICAL_SECTION is
// natively re-entrant for the owning thread — and CoD4 relies on that (e.g.
// Com_LogPrintMessage takes CRITSECT_CONSOLE and then calls Com_OpenLogFile
// which calls Com_Printf which re-enters CRITSECT_CONSOLE).
//
// pthread_mutex defaults to NORMAL mutexes which deadlock on re-entry, so
// we lazy-init each slot as PTHREAD_MUTEX_RECURSIVE.
namespace {
// MP currently defines 22 engine critical sections and SP defines 35.  The
// old 16-slot shim silently skipped every lock above CRITSECT_PHYSICS, leaving
// the FX allocator, audio, cinematics, and command buffer unsynchronized.
// Keep headroom for both engines and fail loudly if a corrupt slot is passed.
constexpr int KISAK_CRIT_SLOTS = 64;
static_assert(CRITSECT_COUNT <= KISAK_CRIT_SLOTS);
pthread_mutex_t g_crit_mutexes[KISAK_CRIT_SLOTS];
std::once_flag g_crit_init_flag;
void g_crit_init()
{
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    for (int i = 0; i < KISAK_CRIT_SLOTS; ++i) {
        pthread_mutex_init(&g_crit_mutexes[i], &attr);
    }
    pthread_mutexattr_destroy(&attr);
}
} // namespace

void Sys_EnterCriticalSection(int slot)
{
    if (slot < 0 || slot >= KISAK_CRIT_SLOTS) {
        std::fprintf(stderr, "[posix] invalid critical-section slot %d\n", slot);
        std::abort();
    }
    std::call_once(g_crit_init_flag, g_crit_init);
    pthread_mutex_lock(&g_crit_mutexes[slot]);
}

void Sys_LeaveCriticalSection(int slot)
{
    if (slot < 0 || slot >= KISAK_CRIT_SLOTS) {
        std::fprintf(stderr, "[posix] invalid critical-section slot %d\n", slot);
        std::abort();
    }
    std::call_once(g_crit_init_flag, g_crit_init);
    pthread_mutex_unlock(&g_crit_mutexes[slot]);
}

// Material_RegisterHandle provided by src/gfx_d3d/r_material.cpp now.

// cls global is now provided by src/client_mp/cl_main_mp.cpp.

// com_statmon now defined in qcommon/common.cpp (real upstream).

// GScr_AllocString provided by src/game_mp/g_scr_main_mp.cpp now.

// ClearBounds / ExpandBounds: declared in com_math.h, defined in
// com_math.cpp. Trivial math we can implement portably; will collide with
// com_math.cpp's versions when that file ports, at which point these stubs
// get removed.
#include <cfloat>
// ClearBounds, ExpandBounds provided by src/universal/com_math.cpp now.

// I_stristr: case-insensitive substring search. Manual implementation
// because strcasestr is a non-standard extension (BSD/GNU) and may not be
// in Switch newlib.
// I_stristr provided by src/universal/q_shared.cpp now.

// sys_info: win_local.h:276 declares this as `extern SysInfo sys_info` - an OBJECT, not a
// pointer. Defining it as `void *` here meant Sys_GetInfo (com_playerprofile.cpp:244) did
// qmemcpy(info, &sys_info, sizeof(SysInfo)) from the address of the POINTER VARIABLE, so
// every field was garbage. That is where the "KISAK GHZ nan, 1280" fatal came from: the
// autoconfigure step reads info.configureGHz and gets a nan.
//
// Define the real object and fill it from sysctl. Sys_FindInfo() does this on Windows via
// CPUID and GlobalMemoryStatus; that file is not ported, so the values come from here.
#include <sys/sysctl.h>
#include "win32/win_local.h"

SysInfo sys_info{};

// Runs before Com_Init (posix_gl_main.cpp) so autoconfigure sees real numbers.
extern "C" void Posix_FindSysInfo()
{
    size_t sz;

    int logical = 0, physical = 0;
    sz = sizeof(logical);  sysctlbyname("hw.logicalcpu",  &logical,  &sz, nullptr, 0);
    sz = sizeof(physical); sysctlbyname("hw.physicalcpu", &physical, &sz, nullptr, 0);
    sys_info.logicalCpuCount  = logical  > 0 ? logical  : 8;
    sys_info.physicalCpuCount = physical > 0 ? physical : 8;

    uint64_t mem = 0;
    sz = sizeof(mem); sysctlbyname("hw.memsize", &mem, &sz, nullptr, 0);
    sys_info.sysMB = mem ? (int)(mem / (1024ull * 1024ull)) : 8192;

    // Apple Silicon does not publish a clock through sysctl (hw.cpufrequency is Intel-only).
    // The value is only used to pick a quality preset from configure_mp.csv, and every
    // M-series part is far past the top row, so report the highest sensible figure rather
    // than leaving it uninitialised.
    double ghz = 0.0;
    uint64_t hz = 0;
    sz = sizeof(hz);
    if (sysctlbyname("hw.cpufrequency_max", &hz, &sz, nullptr, 0) == 0 && hz)
        ghz = (double)hz / 1.0e9;
    if (ghz <= 0.0) ghz = 3.5;
    sys_info.cpuGHz = ghz;
    sys_info.configureGHz = ghz;

    char brand[128] = {0};
    sz = sizeof(brand);
    if (sysctlbyname("machdep.cpu.brand_string", brand, &sz, nullptr, 0) != 0)
        std::snprintf(brand, sizeof(brand), "Apple Silicon");
    std::snprintf(sys_info.cpuName, sizeof(sys_info.cpuName), "%s", brand);
    std::snprintf(sys_info.cpuVendor, sizeof(sys_info.cpuVendor), "%s", "Apple");
    std::snprintf(sys_info.gpuDescription, sizeof(sys_info.gpuDescription),
                  "Apple Silicon GPU (OpenGL)");

    // The engine gates SIMD paths on this. We build with sse2neon, so the paths are valid.
    sys_info.SSE = true;

    std::printf("sysinfo: %s, %d cores (%d physical), %d MB, %.2f GHz\n",
                sys_info.cpuName, sys_info.logicalCpuCount, sys_info.physicalCpuCount,
                sys_info.sysMB, (double)sys_info.configureGHz);
}

unsigned long kb_last_read_bytes = 0;   // see kisak_compat.h ReadFileEx
