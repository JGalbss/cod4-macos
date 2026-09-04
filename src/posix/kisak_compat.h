// MSVC compatibility shims for POSIX/Switch builds.
//
// Force-included before every .cpp/.h via the compiler's -include flag (see
// scripts/posix/CMakeLists.txt). Lets upstream code that uses MSVC keywords
// and types (__cdecl, __declspec, __int16, etc.) compile on clang/gcc
// without invasive changes to the source.
//
// Kept minimal: only what actually appears in upstream KisakCOD code. When a
// new shim is needed, add it here instead of ifdef'ing the use site.

#pragma once

// This header is C++ only. .c TUs (e.g. ODE physics) pull it via the build's
// force-include but don't need (and can't compile) any of the shims below.
#ifdef __cplusplus

#if !defined(_MSC_VER)

// === Calling conventions ====================================================
// MSVC uses __cdecl/__stdcall/__fastcall to control argument-passing
// conventions. On non-Windows ARM64 and x86_64, AAPCS/SysV ABI is imposed
// by the compiler regardless of these keywords — they become no-ops.
#ifndef __cdecl
#define __cdecl
#endif
#ifndef __stdcall
#define __stdcall
#endif
#ifndef __fastcall
#define __fastcall
#endif
#ifndef __thiscall
#define __thiscall
#endif

// === Forced inline ==========================================================
#ifndef __forceinline
#define __forceinline inline __attribute__((always_inline))
#endif

// === __declspec(...) ========================================================
// Used in MSVC for DLL visibility, alignment, thread-local storage, etc. In
// KisakCOD upstream it shows up as __declspec(noreturn) and
// __declspec(align). A generic no-op covers current usage; refine if any
// site breaks.
#ifndef __declspec
#define __declspec(x)
#endif

// === Standard headers upstream assumes without including explicitly ========
// q_shared.h uses INT_MIN/INT_MAX in DvarLimits without including <limits.h>.
// The MSVC build picks those up transitively from some other MS CRT header;
// force availability here.
#include <climits>
#include <cstdint>
#ifdef __OBJC__
// The shim is force-included before the translation unit, so native Objective-C
// types needed by declarations below must be made visible here.
#include <objc/objc.h>
#endif

// === MSVC underscore-prefixed CRT functions =================================
// MSVC CRT prefixes various functions with `_` (_vsnprintf, _snprintf,
// _stricmp, etc.) to avoid clashing with user namespaces. POSIX/glibc/newlib
// use the unprefixed names. Map the ones upstream uses.
#define _vsnprintf vsnprintf
#define _snprintf  snprintf
#define _stricmp   strcasecmp
#define _strnicmp  strncasecmp
#define _isnan     isnan
// MSVC "secure" CRT variants: signature is (dst, dstSize, _TRUNCATE, fmt, va).
// On POSIX vsnprintf already truncates safely; _TRUNCATE is a no-op sentinel.
#ifndef _TRUNCATE
#define _TRUNCATE ((size_t)-1)
#endif
#define _vsnprintf_s(dst, dstSize, count, fmt, va) vsnprintf((dst), (dstSize), (fmt), (va))
#define _snprintf_s(dst, dstSize, count, ...)      snprintf((dst), (dstSize), __VA_ARGS__)
// MSVC: sprintf_s(buf, sizeOfBuf, fmt, ...) — POSIX equivalent is snprintf
// with the same destination size; truncation behavior matches our needs.
#define sprintf_s(dst, dstSize, ...)               snprintf((dst), (dstSize), __VA_ARGS__)
// MSVC: sscanf_s(buf, fmt, ...) — POSIX sscanf has the same contract for
// the format specifiers KisakCOD uses (no %s/%c width pairs). Aliasing is
// safe.
#define sscanf_s(src, ...)                         sscanf((src), __VA_ARGS__)
// Win32 BYTE/WORD/DWORD typedefs — referenced by hex-rays decompiled bit-field
// accessors. POSIX/clang has no <windows.h> so define them as plain integer
// aliases here.
#ifndef BYTE
typedef unsigned char  BYTE;
#endif
#ifndef WORD
typedef unsigned short WORD;
#endif
// Win32 HIWORD / LOWORD / HIBYTE / LOBYTE macros.
#ifndef HIWORD
#define HIWORD(x) (static_cast<WORD>((static_cast<DWORD>(x) >> 16) & 0xFFFF))
#endif
#ifndef LOWORD
#define LOWORD(x) (static_cast<WORD>(static_cast<DWORD>(x) & 0xFFFF))
#endif
#ifndef HIBYTE
#define HIBYTE(x) (static_cast<BYTE>((static_cast<WORD>(x) >> 8) & 0xFF))
#endif
#ifndef LOBYTE
#define LOBYTE(x) (static_cast<BYTE>(static_cast<WORD>(x) & 0xFF))
#endif
// DWORD typedef defined later in this header as `unsigned long`.
// _ctime64: MSVC's 64-bit time formatter. On POSIX time_t is already 64-bit;
// the upstream caller pairs the result with free(), so return a strdup'd
// copy instead of ctime's static buffer.
#include <ctime>
#include <cstring>
#include <cstdlib>
static inline char *_ctime64(const long long *t)
{
    if (!t) return nullptr;
    ::time_t tt = (::time_t)(*t);
    char *s = std::ctime(&tt);
    return s ? strdup(s) : nullptr;
}
// __debugbreak: MSVC intrinsic that triggers a debugger breakpoint.
// On clang/gcc the equivalent is __builtin_trap (or __builtin_debugtrap
// on clang specifically, but trap works everywhere as a fallback).
#define __debugbreak() __builtin_trap()

// Win32 critical-section API as no-op shims. The CRITICAL_SECTION type
// itself is already defined as a small struct above; callers just need
// these four entry points to exist. The single-threaded port has no real
// contention; once the engine actually spawns worker threads, these get
// replaced by pthread_mutex-backed Sys_EnterCriticalSection variants
// already in posix_stubs.cpp.
#ifndef _WIN32
struct _RTL_CRITICAL_SECTION;
static inline void EnterCriticalSection(_RTL_CRITICAL_SECTION * /*cs*/) {}
static inline void LeaveCriticalSection(_RTL_CRITICAL_SECTION * /*cs*/) {}
static inline void InitializeCriticalSection(_RTL_CRITICAL_SECTION * /*cs*/) {}
static inline void DeleteCriticalSection(_RTL_CRITICAL_SECTION * /*cs*/) {}
#endif

// _BitScanReverse: MSVC intrinsic that finds the index of the most
// significant set bit. Returns 0 if mask is 0, else sets *index and
// returns nonzero. Implemented via __builtin_clz on clang/gcc.
#ifndef _WIN32
static inline unsigned char _BitScanReverse(unsigned long *index, unsigned long mask)
{
    if (!mask) return 0;
    *index = 31u - (unsigned long)__builtin_clz((unsigned int)mask);
    return 1;
}
static inline unsigned char _BitScanForward(unsigned long *index, unsigned long mask)
{
    if (!mask) return 0;
    *index = (unsigned long)__builtin_ctz((unsigned int)mask);
    return 1;
}
#endif

// __rdtsc: x86/x64 cycle counter intrinsic. On ARM64 we don't have a
// user-space cycle counter readily exposed; approximate with steady_clock
// nanoseconds. Off by a constant factor vs real cycles but adequate for
// frame-time stats.
#ifndef __rdtsc
#include <chrono>
static inline unsigned long long __rdtsc()
{
    using namespace std::chrono;
    return (unsigned long long)duration_cast<nanoseconds>(
        steady_clock::now().time_since_epoch()).count();
}
#endif

// PF_NON_TEMPORAL_LEVEL_ALL + PreFetchCacheLine: Xbox 360-style prefetch
// hint. No-op outside Win32; the constant just needs to exist for parse.
#ifndef PF_NON_TEMPORAL_LEVEL_ALL
#define PF_NON_TEMPORAL_LEVEL_ALL 4
#endif
#ifndef PreFetchCacheLine
#define PreFetchCacheLine(level, addr) ((void)(level), (void)(addr))
#endif


// Upstream's basic byte typedef lives in q_shared.h; expose it
// project-wide so headers that use 'byte' before q_shared.h is included
// (e.g. r_gfx.h reached through scr_const.h's chain) still parse. Mirror
// the upstream typedef exactly to avoid ODR issues.
typedef unsigned char byte;

// ARRAYSIZE: Win32 macro for compile-time array element count.
#ifndef ARRAYSIZE
#ifndef ARRAYSIZE
#define ARRAYSIZE(a) (sizeof(a) / sizeof((a)[0]))
#endif
#endif

// Win32 InterlockedIncrement / InterlockedDecrement / InterlockedCompareExchange:
// atomic primitives. Map to GCC/clang __atomic_* builtins with seq-cst.
// Templated so int*/long*/etc. call sites match without overload juggling.
template <typename T>
static inline T InterlockedIncrement(T volatile *p)
{
    return __atomic_add_fetch(p, T{1}, __ATOMIC_SEQ_CST);
}
template <typename T>
static inline T InterlockedDecrement(T volatile *p)
{
    return __atomic_sub_fetch(p, T{1}, __ATOMIC_SEQ_CST);
}
template <typename T>
static inline T InterlockedCompareExchange(T volatile *p, T newval, T expected)
{
    T e = expected;
    __atomic_compare_exchange_n(p, &e, newval, false,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return e; // returns the value that was in *p before the call
}
// InterlockedExchangeAdd: returns the *previous* value at *p, then adds.
template <typename T>
static inline T InterlockedExchangeAdd(T volatile *p, T addend)
{
    return __atomic_fetch_add(p, addend, __ATOMIC_SEQ_CST);
}
// InterlockedExchange: atomically writes a new value and returns the
// previous value.
template <typename T>
static inline T InterlockedExchange(T volatile *p, T newval)
{
    return __atomic_exchange_n(p, newval, __ATOMIC_SEQ_CST);
}
// fopen_s: MSVC's "secure" fopen variant. Returns 0 on success and stores
// the FILE* in *out; POSIX has plain fopen that returns FILE* or NULL.
// Bridge: do the plain fopen and map to fopen_s's contract.
#include <cstdio>
#include <cerrno>
static inline int fopen_s(::FILE **out, const char *path, const char *mode)
{
    if (!out) return EINVAL;
    *out = std::fopen(path, mode);
    return *out ? 0 : errno;
}
// MSVC: _itoa(value, buffer, radix) — converts an integer to a string in
// the given radix and writes it into the caller's buffer (the buffer must
// be large enough; the MSVC contract has no size param). Map onto a
// portable inline that uses snprintf for radix 10 and a manual loop for
// other radices.
static inline char *_itoa(int value, char *buffer, int radix)
{
    if (!buffer) return nullptr;
    if (radix == 10) { std::snprintf(buffer, 16, "%d", value); return buffer; }
    char *p = buffer;
    unsigned int u = (unsigned int)value;
    char *digits = (char *)"0123456789abcdefghijklmnopqrstuvwxyz";
    char tmp[33]; int n = 0;
    if (u == 0) tmp[n++] = '0';
    else while (u) { tmp[n++] = digits[u % (unsigned)radix]; u /= (unsigned)radix; }
    while (n) *p++ = tmp[--n];
    *p = 0;
    return buffer;
}

// _time64/_localtime64: MSVC's explicit 64-bit time_t variants. POSIX
// time_t is already 64-bit on every platform we target (macOS arm64, Linux
// x86_64/arm64, Switch arm64), but isn't the same type as `long long`
// (typically `long`). Inline bridges convert.
#include <ctime>
inline long long _time64(long long *out)
{
    ::time_t now = ::time(nullptr);
    if (out) *out = (long long)now;
    return (long long)now;
}
inline ::tm *_localtime64(const long long *in)
{
    if (!in) return nullptr;
    ::time_t t = (::time_t)(*in);
    return ::localtime(&t);
}

// === POSIX libc collision: random()/srandom() ===============================
// POSIX <stdlib.h> declares `long random(void)` (BSD-derived). CoD4 has its
// own `float random()` in com_math.h, which clang treats as "functions that
// differ only in return type" and refuses to compile. Solution: rename
// CoD4's `random`/`crandom` via macros applied after <cstdlib> has been
// processed. The libc function remains accessible by the `random` symbol;
// CoD4 code becomes `kisak_random`.
#include <cstdlib>

// The retail Win32 game was built against MSVCRT, whose rand() returns a
// 15-bit value (RAND_MAX == 32767). Several engine paths deliberately divide
// by 32768 or multiply by 1/32768. Darwin's libc rand() is 31-bit, which makes
// those values up to 65536 times too large and breaks FX spacing, recoil,
// tracer probability, dynamic-entity force and renderer jitter. Route C++
// engine code through an exact MSVCRT-compatible generator; bundled C audio
// libraries are not force-included with this shim and keep their native rand.
extern "C" int kisak_msvcrt_rand();
extern "C" void kisak_msvcrt_srand(unsigned int seed);
#define rand  kisak_msvcrt_rand
#define srand kisak_msvcrt_srand

#define random  kisak_random
#define crandom kisak_crandom

// === Fixed-size integer types ===============================================
// MSVC has __int8/16/32/64 as builtins, which allows `unsigned __int8`,
// `signed __int8`, etc. On POSIX we use #define (not typedef!) to preserve
// that property — the preprocessor swaps the token early, leaving `unsigned`
// to combine with the underlying type. A typedef would break
// `unsigned __int8 x`.
//
// Note: mapping __int8 to plain `char` means implementation-defined
// signedness on this token by itself, whereas MSVC guarantees signed. The
// upstream usage is almost entirely via `unsigned __int8` (bytes), so the
// difference rarely matters.
#define __int8  char
#define __int16 short
#define __int32 int
#define __int64 long long

// === __pragma ===============================================================
// Function-like #pragma used in MSVC to embed pragmas inside macros. The
// clang/gcc equivalent would be _Pragma() — for now a no-op, since the
// upstream usages are almost all warning-disables already covered by the
// POSIX build flags.
#ifndef __pragma
#define __pragma(x)
#endif

// === Basic Win32 types ======================================================
// Some upstream headers (qcommon/threads.h and friends) use DWORD/HANDLE/
// BOOL/HWND/LPCSTR in extern declarations instead of standard types. Rather
// than force-including <Windows.h> (only available in the MS SDK), we
// provide opaque equivalents. HANDLE = void* works as a generic pointer-
// shaped handle; the linker resolves at the right moment when the owning
// subsystem is ported.
#ifdef KISAK_DXVK
// DXVK Native ships both the real D3D9 API and the MinGW-derived Windows types
// it is declared in terms of, so it has to be the one defining them - a second
// definition of ULONG or HRESULT here is a hard error, not a duplicate. This
// include therefore comes before anything else in this section, and everything
// below that DXVK already provides is skipped.
//
// Its ARRAYSIZE is spelled identically but is not itself guarded, so the one
// defined further up has to get out of the way first.
#undef ARRAYSIZE
#include <d3d9.h>
#else
typedef uint32_t DWORD;
// KISAKHACK-AUDIT: Win32 LONG is 32-bit. On POSIX/aarch64 `long` is 64-bit, so using
// `typedef long LONG` causes InterlockedXXX templates to deduce 8-byte atomic ops on
// the 4-byte int fields the upstream code stores values in. Match Win32 LONG width.
typedef int32_t       LONG;
typedef long long     LONGLONG;
typedef unsigned long long ULONGLONG;
typedef void         *HANDLE;
typedef void         *HWND;
typedef void         *HINSTANCE;
#ifndef __OBJC__
// Objective-C translation units get BOOL from objc/objc.h. Defining the Win32
// spelling here first would collide when a native framework is imported.
typedef int           BOOL;
#endif
typedef const char   *LPCSTR;
typedef char         *LPSTR;
typedef unsigned int  UINT;
typedef unsigned long ULONG;
typedef wchar_t       WCHAR;
typedef WCHAR        *LPWSTR;
typedef const WCHAR  *LPCWSTR;
typedef void         *LPVOID;
typedef const void   *LPCVOID;

// LARGE_INTEGER: Win32 union for 64-bit values. Upstream uses only
// .QuadPart (for QueryPerformanceCounter), so the anonymous-struct
// alternative form is enough.
typedef union {
    struct {
        DWORD LowPart;
        long  HighPart;
    };
    long long QuadPart;
} LARGE_INTEGER;
#endif // !KISAK_DXVK

// Miles Sound System and the MSVC bounds-checked string functions. Neither has
// anything to do with D3D9; they only lived among the DX9 stubs and went away
// with them.
// Miles _AILSOUNDINFO + AIL_WAV_info: stubbed, returns 0 (failure).
struct _AILSOUNDINFO {
    int format;
    const void *data_ptr;
    unsigned int data_len;
    unsigned int rate;
    int bits;
    int channels;
    unsigned int channel_mask;
    unsigned int samples;
    unsigned int block_size;
    const void *initial_ptr;
};
static inline int AIL_WAV_info(const void * /*buffer*/, _AILSOUNDINFO *info) {
    if (info) *info = {};
    return 0;
}
struct _AILMIXINFO {
    _AILSOUNDINFO Info;
    unsigned long channel_mask;
};
struct _AIL_DRIVER;
struct _DIG_DRIVER;
struct _SAMPLE;
struct _STREAM;
static inline void AIL_set_DirectSound_HWND(_DIG_DRIVER * /*drv*/, void * /*hwnd*/) {}
static inline unsigned int AIL_size_processed_digital_audio(unsigned int /*rate*/, int /*format*/, int /*channels*/, _AILMIXINFO * /*info*/) { return 0; }
static inline int AIL_process_digital_audio(void * /*dst*/, unsigned int /*dstSize*/, unsigned int /*rate*/, int /*format*/, int /*channels*/, _AILMIXINFO * /*info*/) { return 0; }

template <unsigned long N>
static inline int strcpy_s(char (&dst)[N], const char *src) {
    if (!src) { dst[0] = '\0'; return 0; }
    unsigned long i = 0;
    while (i + 1 < N && src[i]) { dst[i] = src[i]; ++i; }
    dst[i] = '\0';
    return 0;
}
static inline int strcpy_s(char *dst, unsigned long n, const char *src) {
    if (!dst || n == 0) return 0;
    if (!src) { dst[0] = '\0'; return 0; }
    unsigned long i = 0;
    while (i + 1 < n && src[i]) { dst[i] = src[i]; ++i; }
    dst[i] = '\0';
    return 0;
}

// Win32 Sleep. Nothing to do with D3D9, but it used to sit inside the block of
// stubs below and disappeared with them.
inline void Sleep(unsigned long ms) {
    if (ms == 0) return;
    timespec ts{static_cast<time_t>(ms / 1000), static_cast<long>((ms % 1000) * 1000000L)};
    nanosleep(&ts, nullptr);
}

// Neither the DX9 headers nor DXVK's Windows subset declare these, so they are
// needed either way. The tag names are what the decompile spells POINT and RECT
// as, and DXVK only declares the modern spellings.
#ifdef KISAK_DXVK
typedef const char *LPCSTR;
typedef WCHAR      *LPWSTR;
typedef POINT       tagPOINT;
typedef RECT        tagRECT;
#endif

// OVERLAPPED: Win32 async I/O state. Only stored in upstream structs
// (database file-loader, etc.); never actually used on POSIX. Placeholder
// definition matches Win32's nominal size.
// D3DFORMAT subset upstream codes use. Defined as an enum so they're usable
// as switch labels and direct integer constants. Values match the Win32 DX9
// FOURCC encoding so persisted data and hex-rays artifacts stay valid.
#if !defined(D3DFMT_L8) && !defined(KISAK_DXVK)
enum D3DFormatShim : unsigned int {
    D3DFMT_UNKNOWN  = 0,
    D3DFMT_A8       = 28,
    D3DFMT_L8       = 50,
    D3DFMT_A8L8     = 51,
    D3DFMT_R32F     = 114,
};
#endif

// D3DCUBEMAP_FACES — Win32 DX9 cubemap face enum. Upstream code only uses
// it as an opaque int-typed parameter to Image_UploadData. We declare it
// here as an enum alias so the parse succeeds; values match DX9 ordering.
#if !defined(D3DCUBEMAP_FACE_POSITIVE_X) && !defined(KISAK_DXVK)
enum D3DCUBEMAP_FACES : int {
    D3DCUBEMAP_FACE_POSITIVE_X = 0,
    D3DCUBEMAP_FACE_NEGATIVE_X = 1,
    D3DCUBEMAP_FACE_POSITIVE_Y = 2,
    D3DCUBEMAP_FACE_NEGATIVE_Y = 3,
    D3DCUBEMAP_FACE_POSITIVE_Z = 4,
    D3DCUBEMAP_FACE_NEGATIVE_Z = 5,
};
#endif

typedef struct _OVERLAPPED {
    unsigned long long Internal;
    unsigned long long InternalHigh;
    union {
        struct { DWORD Offset; DWORD OffsetHigh; };
        void *Pointer;
    };
    void *hEvent;
} OVERLAPPED;

// QueryPerformanceCounter / QueryPerformanceFrequency: Win32 high-resolution
// timer API. Stubs are in src/posix/posix_stubs.cpp.
BOOL QueryPerformanceCounter(LARGE_INTEGER *count);
BOOL QueryPerformanceFrequency(LARGE_INTEGER *freq);

// === VirtualAlloc / VirtualFree shim ========================================
// Win32 separates address-space reservation from page commit:
//   VirtualAlloc(addr, size, MEM_RESERVE,             PAGE_READWRITE)
//   VirtualAlloc(addr, size, MEM_COMMIT,              PAGE_READWRITE)
//   VirtualAlloc(addr, size, MEM_RESERVE|MEM_COMMIT,  PAGE_READWRITE)
//   VirtualFree (addr, size, MEM_DECOMMIT)
//   VirtualFree (addr, 0,    MEM_RELEASE)
//
// POSIX has no reserve/commit split. We back the shim with anonymous mmap
// for RESERVE (and the combined RESERVE|COMMIT path) and munmap for
// RELEASE. COMMIT on an existing mapping becomes a no-op; DECOMMIT becomes
// madvise(MADV_DONTNEED) so the kernel can drop the backing pages without
// invalidating the address range. Sizes are page-rounded by mmap itself.
#ifndef MEM_RESERVE
#define MEM_RESERVE  0x2000u
#define MEM_COMMIT   0x1000u
#define MEM_DECOMMIT 0x4000u
#define MEM_RELEASE  0x8000u
#define PAGE_READWRITE 4u
#endif
void *VirtualAlloc(void *addr, size_t size, unsigned int flags, unsigned int prot);
BOOL  VirtualFree(void *addr, size_t size, unsigned int flags);

// Win32 UI helpers that show up in dialog-style error paths. On POSIX/
// Switch we have no native message-box; stubs return MB_YES (6) so the
// upstream code's "user accepted the change" branches keep working.
// MB_OK = 0, MB_OKCANCEL = 1, MB_YESNO = 4, MB_YESNOCANCEL = 3, MB_YES = 6.
HWND GetActiveWindow();
int  MessageBoxA(HWND hWnd, const char *text, const char *caption, unsigned int type);

// More Win32 types used in win_local.h declarations. Most exist only to
// allow the header to parse on POSIX — call sites should never execute on
// non-Windows.
typedef long          LRESULT;
typedef unsigned long long WPARAM;  // UINT_PTR equivalent
typedef long long          LPARAM;  // LONG_PTR equivalent
#define WINAPI

typedef struct tagOSVERSIONINFO {
    DWORD dwOSVersionInfoSize;
    DWORD dwMajorVersion;
    DWORD dwMinorVersion;
    DWORD dwBuildNumber;
    DWORD dwPlatformId;
    char  szCSDVersion[128];
} OSVERSIONINFO;

typedef struct _RTL_CRITICAL_SECTION {
    void        *DebugInfo;
    long         LockCount;
    long         RecursionCount;
    HANDLE       OwningThread;
    HANDLE       LockSemaphore;
    unsigned long SpinCount;
} _RTL_CRITICAL_SECTION, RTL_CRITICAL_SECTION, CRITICAL_SECTION;

#ifndef KISAK_DXVK
// === DX9 opaque forward declarations ========================================
// Renderer headers (gfx_d3d/r_*.h) declare structs/globals of DX9 types
// (IDirect3DDevice9, vertex/index buffers, textures, _D3DFORMAT enum).
// On POSIX/Switch those interfaces have no implementation — the renderer
// is replaced by gfx_gl/. We forward-declare the types as opaque structs
// so headers parse; functions that take them are never called off Windows.
struct IDirect3DDevice9;
struct IDirect3D9 {
    long CheckDeviceFormat(unsigned int, int, int, unsigned long, int, int) { return 0; }
    long CheckDepthStencilMatch(unsigned int, int, int, int, int) { return 0; }
    long CreateDevice(unsigned int, int, void *, unsigned long, void *, IDirect3DDevice9 **out) { if (out) *out = nullptr; return 0; }
    long EnumAdapterModes(unsigned int, int, unsigned int, void *) { return 0; }
    long GetAdapterDisplayMode(unsigned int, void *) { return 0; }
    long GetAdapterIdentifier(unsigned int, unsigned long, void *) { return 0; }
    unsigned int GetAdapterModeCount(unsigned int, int) { return 0; }
    long GetDeviceCaps(unsigned int, int, void *) { return 0; }
    long CheckDeviceMultiSampleType(unsigned int, int, int, int, int, unsigned long *) { return 0; }
    unsigned int GetAdapterCount() { return 0; }
    void *GetAdapterMonitor(unsigned int) { return nullptr; }
};
struct IDirect3DVertexBuffer9 {
    long Lock(unsigned int, unsigned int, void **out, unsigned long) { if (out) *out = nullptr; return 0; }
    long Unlock() { return 0; }
    unsigned long Release() { return 0; }
};
struct IDirect3DIndexBuffer9 {
    long Lock(unsigned int, unsigned int, void **out, unsigned long) { if (out) *out = nullptr; return 0; }
    long Unlock() { return 0; }
    unsigned long Release() { return 0; }
};
struct IDirect3DBaseTexture9 {
    unsigned long Release() { return 0; }
    unsigned long AddRef() { return 1; }
};
struct IDirect3DTexture9;
struct IDirect3DVolumeTexture9;
struct IDirect3DCubeTexture9;
struct IDirect3DSurface9;  // defined after _D3DSURFACE_DESC below

struct IDirect3DStateBlock9;
struct IDirect3DVertexDeclaration9;
struct IDirect3DVertexShader9;
struct IDirect3DPixelShader9;
struct tagRECT;
struct IDirect3DSwapChain9 {
    long Present(const tagRECT *, const tagRECT *, void *, const void *, unsigned long) { return 0; }
    unsigned long Release() { return 0; }
};
struct IDirect3DQuery9 {
    long Issue(unsigned long) { return 0; }
    long GetData(void *, unsigned int, unsigned long) { return 0; }
    unsigned long Release() { return 0; }
};
#ifndef D3DISSUE_BEGIN
#define D3DISSUE_BEGIN 2
#endif
#ifndef D3DISSUE_END
#define D3DISSUE_END 1
#endif
#ifndef D3DGETDATA_FLUSH
#define D3DGETDATA_FLUSH 1
#endif

// IDirect3DDevice9 stub: provides the most-called methods so renderer
// files compile against the abstraction. None of these run on POSIX —
// the real renderer lives in gfx_gl/ once it lands.
// strcpy_s/_n: MSVC bounds-checked variants. Implemented over POSIX
// strncpy/strlcpy. The size arg is dropped (no enforcement) — callers
// expect "fails on overflow" but on POSIX we trust callers and copy
// best-effort.

struct tagRECT {
    long left;
    long top;
    long right;
    long bottom;
};
typedef tagRECT RECT;
struct _D3DLOCKED_RECT {
    int Pitch;
    void *pBits;
};
struct _D3DBOX {
    unsigned int Left;
    unsigned int Top;
    unsigned int Right;
    unsigned int Bottom;
    unsigned int Front;
    unsigned int Back;
};
struct _D3DLOCKED_BOX {
    int RowPitch;
    int SlicePitch;
    void *pBits;
};
struct _D3DGAMMARAMP {
    unsigned short red[256];
    unsigned short green[256];
    unsigned short blue[256];
};
struct _D3DCAPS9 {
    int DeviceType;
    unsigned long AdapterOrdinal;
    unsigned long Caps;
    unsigned long Caps2;
    unsigned long Caps3;
    unsigned long PresentationIntervals;
    unsigned long CursorCaps;
    unsigned long DevCaps;
    unsigned long PrimitiveMiscCaps;
    unsigned long RasterCaps;
    unsigned long ZCmpCaps;
    unsigned long SrcBlendCaps;
    unsigned long DestBlendCaps;
    unsigned long AlphaCmpCaps;
    unsigned long ShadeCaps;
    unsigned long TextureCaps;
    unsigned long TextureFilterCaps;
    unsigned long CubeTextureFilterCaps;
    unsigned long VolumeTextureFilterCaps;
    unsigned long TextureAddressCaps;
    unsigned long VolumeTextureAddressCaps;
    unsigned long LineCaps;
    unsigned long MaxTextureWidth;
    unsigned long MaxTextureHeight;
    unsigned long MaxVolumeExtent;
    unsigned long MaxTextureRepeat;
    unsigned long MaxTextureAspectRatio;
    unsigned long MaxAnisotropy;
    unsigned long PixelShaderVersion;
    unsigned long VertexShaderVersion;
    unsigned long MaxVertexShaderConst;
    unsigned long MaxPixelShader30InstructionSlots;
    unsigned long MaxVertexShader30InstructionSlots;
};
static inline IDirect3D9 *Direct3DCreate9(unsigned int /*sdkVersion*/) { return nullptr; }
static inline int IsWindow(void * /*hwnd*/) { return 0; }
static inline int DestroyWindow(void * /*hwnd*/) { return 0; }
static inline void *ShellExecuteA(void *, const char *, const char *, const char *, const char *, int) { return nullptr; }
static inline int SetForegroundWindow(void * /*hwnd*/) { return 0; }
struct _D3DVERTEXELEMENT9 {
    unsigned short Stream;
    unsigned short Offset;
    unsigned char Type;
    unsigned char Method;
    unsigned char Usage;
    unsigned char UsageIndex;
};
struct _D3DSURFACE_DESC {
    int Format;
    int Type;
    unsigned long Usage;
    int Pool;
    int MultiSampleType;
    unsigned long MultiSampleQuality;
    unsigned int Width;
    unsigned int Height;
};
struct _D3DVOLUME_DESC {
    int Format;
    int Type;
    unsigned long Usage;
    int Pool;
    unsigned int Width;
    unsigned int Height;
    unsigned int Depth;
};
struct IDirect3DTexture9 : IDirect3DBaseTexture9 {
    long LockRect(unsigned int, _D3DLOCKED_RECT *out, const tagRECT *, unsigned long) { if (out) *out = {}; return 0; }
    long UnlockRect(unsigned int) { return 0; }
    long AddDirtyRect(const tagRECT *) { return 0; }
    long GetLevelDesc(unsigned int, _D3DSURFACE_DESC *out) { if (out) *out = {}; return 0; }
    long GetSurfaceLevel(unsigned int, IDirect3DSurface9 **out) { if (out) *out = nullptr; return 0; }
};
struct IDirect3DSurface9_Defined {
    long GetDesc(_D3DSURFACE_DESC *out) { if (out) *out = {}; return 0; }
    long LockRect(_D3DLOCKED_RECT *out, const tagRECT *, unsigned long) { if (out) *out = {}; return 0; }
    long UnlockRect() { return 0; }
    unsigned long AddRef() { return 1; }
    unsigned long Release() { return 0; }
};
struct IDirect3DSurface9 : IDirect3DSurface9_Defined {};
struct IDirect3DCubeTexture9 : IDirect3DBaseTexture9 {
    long LockRect(unsigned int, unsigned int, _D3DLOCKED_RECT *out, const tagRECT *, unsigned long) { if (out) *out = {}; return 0; }
    long UnlockRect(unsigned int, unsigned int) { return 0; }
    long AddDirtyRect(unsigned int, const tagRECT *) { return 0; }
    long GetLevelDesc(unsigned int, _D3DSURFACE_DESC *out) { if (out) *out = {}; return 0; }
    long GetCubeMapSurface(unsigned int, unsigned int, IDirect3DSurface9 **out) { if (out) *out = nullptr; return 0; }
};
struct IDirect3DVolumeTexture9 : IDirect3DBaseTexture9 {
    long LockBox(unsigned int, _D3DLOCKED_BOX *out, const _D3DBOX *, unsigned long) { if (out) *out = {}; return 0; }
    long UnlockBox(unsigned int) { return 0; }
    long AddDirtyBox(const _D3DBOX *) { return 0; }
    long GetLevelDesc(unsigned int, _D3DVOLUME_DESC *out) { if (out) *out = {}; return 0; }
};
struct IDirect3DDevice9 {
    long BeginScene() { return 0; }
    long EndScene() { return 0; }
    long Clear(unsigned long, const void *, unsigned long, unsigned long, float, unsigned long) { return 0; }
    long TestCooperativeLevel() { return 0; }
    unsigned long Release() { return 0; }
    long Reset(void *) { return 0; }
    long SetRenderState(unsigned long, unsigned long) { return 0; }
    long SetScissorRect(const tagRECT *) { return 0; }
    long DrawPrimitiveUP(unsigned long, unsigned int, const void *, unsigned int) { return 0; }
    long SetVertexDeclaration(IDirect3DVertexDeclaration9 *) { return 0; }
    long SetPixelShader(IDirect3DPixelShader9 *) { return 0; }
    long SetVertexShader(IDirect3DVertexShader9 *) { return 0; }
    long CreateOffscreenPlainSurface(unsigned int, unsigned int, int, unsigned long, IDirect3DSurface9 **out, void *) { if (out) *out = nullptr; return 0; }
    void SetGammaRamp(unsigned int, unsigned long, const void *) {}
    long StretchRect(IDirect3DSurface9 *, const tagRECT *, IDirect3DSurface9 *, const tagRECT *, int) { return 0; }
    long DrawIndexedPrimitive(unsigned long, int, unsigned int, unsigned int, unsigned int, unsigned int) { return 0; }
    long SetDepthStencilSurface(IDirect3DSurface9 *) { return 0; }
    long SetIndices(IDirect3DIndexBuffer9 *) { return 0; }
    long SetRenderTarget(unsigned long, IDirect3DSurface9 *) { return 0; }
    long SetSamplerState(unsigned long, unsigned long, unsigned long) { return 0; }
    long SetStreamSource(unsigned int, IDirect3DVertexBuffer9 *, unsigned int, unsigned int) { return 0; }
    long SetTexture(unsigned long, IDirect3DBaseTexture9 *) { return 0; }
    long SetViewport(const void *) { return 0; }
    long CreateVertexBuffer(unsigned int, unsigned long, unsigned long, unsigned long, IDirect3DVertexBuffer9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateIndexBuffer(unsigned int, unsigned long, int, unsigned long, IDirect3DIndexBuffer9 **out, void *) { if (out) *out = nullptr; return 0; }
    long UpdateTexture(IDirect3DBaseTexture9 *, IDirect3DBaseTexture9 *) { return 0; }
    long CreateCubeTexture(unsigned int, unsigned int, unsigned long, int, unsigned long, IDirect3DCubeTexture9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateVolumeTexture(unsigned int, unsigned int, unsigned int, unsigned int, unsigned long, int, unsigned long, IDirect3DVolumeTexture9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateTexture(unsigned int, unsigned int, unsigned int, unsigned long, int, unsigned long, IDirect3DTexture9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateRenderTarget(unsigned int, unsigned int, int, unsigned long, unsigned long, int, IDirect3DSurface9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateDepthStencilSurface(unsigned int, unsigned int, int, unsigned long, unsigned long, int, IDirect3DSurface9 **out, void *) { if (out) *out = nullptr; return 0; }
    long CreateVertexDeclaration(const void *, IDirect3DVertexDeclaration9 **out) { if (out) *out = nullptr; return 0; }
    long CreateVertexShader(const DWORD *, IDirect3DVertexShader9 **out) { if (out) *out = nullptr; return 0; }
    long CreatePixelShader(const DWORD *, IDirect3DPixelShader9 **out) { if (out) *out = nullptr; return 0; }
    long CreateQuery(unsigned long, IDirect3DQuery9 **out) { if (out) *out = nullptr; return 0; }
    long SetPixelShaderConstantF(unsigned int, const float *, unsigned int) { return 0; }
    long SetVertexShaderConstantF(unsigned int, const float *, unsigned int) { return 0; }
    long GetAvailableTextureMem() { return 0; }
    long GetBackBuffer(unsigned int, unsigned int, int, IDirect3DSurface9 **out) { if (out) *out = nullptr; return 0; }
    long GetSwapChain(unsigned int, IDirect3DSwapChain9 **out) { if (out) *out = nullptr; return 0; }
    long GetRenderTargetData(IDirect3DSurface9 *, IDirect3DSurface9 *) { return 0; }
};
typedef int _D3DPOOL;
#ifndef D3DRS_SCISSORTESTENABLE
#define D3DRS_SCISSORTESTENABLE 174
#endif
#ifndef D3DPT_TRIANGLELIST
#define D3DPT_TRIANGLELIST 4
#endif
#ifndef D3DPOOL_DEFAULT
#define D3DPOOL_DEFAULT 0
#endif
#ifndef D3DPOOL_MANAGED
#define D3DPOOL_MANAGED 1
#endif
#ifndef D3DPOOL_SCRATCH
#define D3DPOOL_SCRATCH 2
#endif
#ifndef D3DPOOL_SYSTEMMEM
#define D3DPOOL_SYSTEMMEM 3
#endif
#ifndef D3DLOCK_NOOVERWRITE
#define D3DLOCK_NOOVERWRITE 0x00001000
#endif
#ifndef D3DLOCK_DISCARD
#define D3DLOCK_DISCARD 0x00002000
#endif
#ifndef D3DLOCK_READONLY
#define D3DLOCK_READONLY 0x00000010
#endif
#ifndef D3DRS_ALPHAREF
#define D3DRS_ALPHAREF 24
#endif
#ifndef D3DSAMP_MINFILTER
#define D3DSAMP_MINFILTER 6
#endif
#ifndef D3DSAMP_MAGFILTER
#define D3DSAMP_MAGFILTER 5
#endif
#ifndef D3DSAMP_MIPFILTER
#define D3DSAMP_MIPFILTER 7
#endif
#ifndef D3DSAMP_MAXANISOTROPY
#define D3DSAMP_MAXANISOTROPY 10
#endif
#ifndef D3DSAMP_MIPMAPLODBIAS
#define D3DSAMP_MIPMAPLODBIAS 8
#endif
#ifndef D3DSAMP_ADDRESSU
#define D3DSAMP_ADDRESSU 1
#endif
#ifndef D3DSAMP_ADDRESSV
#define D3DSAMP_ADDRESSV 2
#endif
#ifndef D3DSAMP_ADDRESSW
#define D3DSAMP_ADDRESSW 3
#endif
#ifndef D3DDEVTYPE_HAL
#define D3DDEVTYPE_HAL 1
#endif
#ifndef D3DRTYPE_SURFACE
#define D3DRTYPE_SURFACE 1
#endif
#ifndef D3DRTYPE_TEXTURE
#define D3DRTYPE_TEXTURE 3
#endif
#ifndef D3DFMT_D24FS8
#define D3DFMT_D24FS8 82
#endif
#ifndef D3DMULTISAMPLE_NONE
#define D3DMULTISAMPLE_NONE 0
#endif
#ifndef D3DBACKBUFFER_TYPE_MONO
#define D3DBACKBUFFER_TYPE_MONO 0
#endif
#ifndef D3DQUERYTYPE_EVENT
#define D3DQUERYTYPE_EVENT 8
#endif
#ifndef D3DQUERYTYPE_OCCLUSION
#define D3DQUERYTYPE_OCCLUSION 9
#endif
struct _D3DVIEWPORT9 {
    unsigned long X, Y, Width, Height;
    float MinZ, MaxZ;
};
#ifndef D3DRS_ALPHATESTENABLE
#define D3DRS_ALPHATESTENABLE 15
#endif
#ifndef D3DRS_COLORWRITEENABLE
#define D3DRS_COLORWRITEENABLE 168
#endif
#ifndef D3DRS_CULLMODE
#define D3DRS_CULLMODE 22
#endif
#ifndef D3DRS_FILLMODE
#define D3DRS_FILLMODE 8
#endif
#ifndef D3DRS_ALPHABLENDENABLE
#define D3DRS_ALPHABLENDENABLE 27
#endif
#ifndef D3DRS_BLENDOP
#define D3DRS_BLENDOP 171
#endif
#ifndef D3DRS_BLENDOPALPHA
#define D3DRS_BLENDOPALPHA 209
#endif
#ifndef D3DRS_SRCBLEND
#define D3DRS_SRCBLEND 19
#endif
#ifndef D3DRS_DESTBLEND
#define D3DRS_DESTBLEND 20
#endif
#ifndef D3DRS_SRCBLENDALPHA
#define D3DRS_SRCBLENDALPHA 207
#endif
#ifndef D3DRS_DESTBLENDALPHA
#define D3DRS_DESTBLENDALPHA 208
#endif
#ifndef D3DRS_DEPTHBIAS
#define D3DRS_DEPTHBIAS 195
#endif
#ifndef D3DRS_SLOPESCALEDEPTHBIAS
#define D3DRS_SLOPESCALEDEPTHBIAS 175
#endif
#ifndef D3DRS_ZWRITEENABLE
#define D3DRS_ZWRITEENABLE 14
#endif
#ifndef D3DRS_ZFUNC
#define D3DRS_ZFUNC 23
#endif
#ifndef D3DRS_ALPHAFUNC
#define D3DRS_ALPHAFUNC 25
#endif
#ifndef D3DRS_STENCILENABLE
#define D3DRS_STENCILENABLE 52
#endif
#ifndef D3DRS_STENCILFAIL
#define D3DRS_STENCILFAIL 53
#endif
#ifndef D3DRS_STENCILZFAIL
#define D3DRS_STENCILZFAIL 54
#endif
#ifndef D3DRS_STENCILPASS
#define D3DRS_STENCILPASS 55
#endif
#ifndef D3DRS_STENCILFUNC
#define D3DRS_STENCILFUNC 56
#endif
#ifndef D3DRS_STENCILREF
#define D3DRS_STENCILREF 57
#endif
#ifndef D3DRS_STENCILMASK
#define D3DRS_STENCILMASK 58
#endif
#ifndef D3DRS_STENCILWRITEMASK
#define D3DRS_STENCILWRITEMASK 59
#endif
#ifndef D3DRS_CCW_STENCILFAIL
#define D3DRS_CCW_STENCILFAIL 186
#endif
#ifndef D3DRS_CCW_STENCILZFAIL
#define D3DRS_CCW_STENCILZFAIL 187
#endif
#ifndef D3DRS_CCW_STENCILPASS
#define D3DRS_CCW_STENCILPASS 188
#endif
#ifndef D3DRS_CCW_STENCILFUNC
#define D3DRS_CCW_STENCILFUNC 189
#endif
#ifndef D3DRS_ADAPTIVETESS_Y
#define D3DRS_ADAPTIVETESS_Y 181
#endif
#ifndef D3DRS_POINTSIZE
#define D3DRS_POINTSIZE 154
#endif
#ifndef D3DRS_POINTSPRITEENABLE
#define D3DRS_POINTSPRITEENABLE 156
#endif
#ifndef D3DTEXF_NONE
#define D3DTEXF_NONE 0
#endif
#ifndef D3DTEXF_POINT
#define D3DTEXF_POINT 1
#endif
#ifndef D3DTEXF_LINEAR
#define D3DTEXF_LINEAR 2
#endif
#ifndef D3DRS_ZENABLE
#define D3DRS_ZENABLE 7
#endif
#ifndef D3DRS_SEPARATEALPHABLENDENABLE
#define D3DRS_SEPARATEALPHABLENDENABLE 206
#endif
#ifndef D3DRS_TWOSIDEDSTENCILMODE
#define D3DRS_TWOSIDEDSTENCILMODE 185
#endif
#ifndef D3DCLEAR_TARGET
#define D3DCLEAR_TARGET 1
#endif
#ifndef D3DCLEAR_ZBUFFER
#define D3DCLEAR_ZBUFFER 2
#endif
#ifndef D3DCLEAR_STENCIL
#define D3DCLEAR_STENCIL 4
#endif
typedef int  _D3DFORMAT;  // enum in DX9 SDK; opaque int here
typedef int  D3DFORMAT;
typedef int  _D3DCUBEMAP_FACES;
typedef int  _D3DDISPLAYMODE;        // struct in DX9 SDK; opaque int here
typedef int  _D3DMULTISAMPLE_TYPE;   // enum
typedef int  _D3DTEXTUREFILTERTYPE;  // enum
struct _D3DCAPS9;             // big struct in DX9 SDK; opaque here
struct _D3DPRESENT_PARAMETERS_;
struct _D3DSURFACE_DESC;
struct _D3DVIEWPORT9;
#endif // !KISAK_DXVK

// === Miles Sound System opaque types =======================================
// snd_local.h declares members/functions of these MSS types. On POSIX/
// Switch Miles is unavailable (proprietary) and the audio path is
// replaced; forward-declare so headers parse.
struct _SAMPLE;
struct _3DSAMPLE;
struct _DIG_DRIVER;
struct _REDBOOK;
struct _STREAM;
struct _DLSDEVICE;
struct _DLSFILEID;
struct _ASISTREAM;
typedef char MSS_FILE;           // upstream uses `const MSS_FILE *` as a path
#ifndef FAR
#define FAR                       // Win16 segment-attribute relic; no-op here
#endif
typedef int           S32;        // signed 32-bit
typedef unsigned int  U32;
typedef unsigned int  UINTa;      // Miles' uintptr_t-equivalent on 32-bit
typedef short         S16;
typedef unsigned short U16;
typedef signed char   S8;
typedef unsigned char U8;
typedef float         F32;
struct HWND__;        // Win32 HWND is `struct HWND__ *`
struct HINSTANCE__;   // Win32 HINSTANCE is `struct HINSTANCE__ *`
#ifndef KISAK_DXVK
typedef long HRESULT;
#endif

// D3DFORMAT constants used in renderer headers. Values match the real
// D3D9 enum (fourcc-packed) so switch cases on D3DFMT_* don't collide
// even though the code paths that consume them never run. Under DXVK the real
// enum is in scope, and a macro expanding to a bare int would not convert to it.
#ifndef KISAK_DXVK
#ifndef D3DFMT_UNKNOWN
#define D3DFMT_UNKNOWN 0
#endif
#ifndef D3DFMT_D24S8
#define D3DFMT_D24S8 75
#endif
#ifndef D3DFMT_D24X8
#define D3DFMT_D24X8 77
#endif
#ifndef D3DFMT_D16
#define D3DFMT_D16 80
#endif
#ifndef D3DFMT_A8R8G8B8
#define D3DFMT_A8R8G8B8 21
#endif
#ifndef D3DFMT_X8R8G8B8
#define D3DFMT_X8R8G8B8 22
#endif
#ifndef D3DFMT_DXT1
#define D3DFMT_DXT1 ((int)(('1' << 24) | ('T' << 16) | ('X' << 8) | 'D'))
#endif
#ifndef D3DFMT_DXT3
#define D3DFMT_DXT3 ((int)(('3' << 24) | ('T' << 16) | ('X' << 8) | 'D'))
#endif
#ifndef D3DFMT_DXT5
#define D3DFMT_DXT5 ((int)(('5' << 24) | ('T' << 16) | ('X' << 8) | 'D'))
#endif
#ifndef D3DFMT_INDEX16
#define D3DFMT_INDEX16 101
#endif
#ifndef D3DFMT_INDEX32
#define D3DFMT_INDEX32 102
#endif
#ifndef D3DFMT_G16R16F
#define D3DFMT_G16R16F 112
#endif
#ifndef D3DFMT_A16B16G16R16F
#define D3DFMT_A16B16G16R16F 113
#endif
#ifndef D3DFMT_G16R16
#define D3DFMT_G16R16 34
#endif
#ifndef D3DFMT_A16B16G16R16
#define D3DFMT_A16B16G16R16 36
#endif
#ifndef D3DFMT_A2B10G10R10
#define D3DFMT_A2B10G10R10 31
#endif
#ifndef D3DFMT_X1R5G5B5
#define D3DFMT_X1R5G5B5 24
#endif
#ifndef D3DFMT_A8B8G8R8
#define D3DFMT_A8B8G8R8 32
#endif
#ifndef D3DFMT_R5G6B5
#define D3DFMT_R5G6B5 23
#endif
#ifndef D3DFMT_A1R5G5B5
#define D3DFMT_A1R5G5B5 25
#endif
#ifndef D3DFMT_D16_LOCKABLE
#define D3DFMT_D16_LOCKABLE 70
#endif
#ifndef D3DFMT_D15S1
#define D3DFMT_D15S1 73
#endif
#ifndef D3DFMT_D32
#define D3DFMT_D32 71
#endif
#ifndef D3DFMT_D32F_LOCKABLE
#define D3DFMT_D32F_LOCKABLE 84
#endif

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

// Windows GDI POINT — minimal shim so cursor-position helpers compile.
// The POSIX/Switch input path is a stub; nothing reads x/y for real yet.
#ifndef KISAK_DXVK
typedef struct tagPOINT { long x, y; } tagPOINT, POINT;
#endif


#endif // !KISAK_DXVK

// === Win32 file, module and thread APIs =====================================
// The blocked-file list in scripts/posix/CMakeLists.txt is dominated by these:
// db_registry.cpp wants CreateFileA/CloseHandle, assertive.cpp wants
// GetModuleHandleA/ExitProcess/FindFirstFile, threads.cpp wants the thread and
// event family. Every one maps onto POSIX directly, so they go here rather than
// each use site growing an ifdef.

#include <dirent.h>
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#define GENERIC_READ         0x80000000u
#define GENERIC_WRITE        0x40000000u
#define FILE_SHARE_READ      1u
#define FILE_SHARE_WRITE     2u
#define CREATE_NEW           1u
#define CREATE_ALWAYS        2u
#define OPEN_EXISTING        3u
#define OPEN_ALWAYS          4u
#define TRUNCATE_EXISTING    5u
#define FILE_ATTRIBUTE_NORMAL     0x00000080u
#define FILE_ATTRIBUTE_DIRECTORY  0x00000010u
#define INVALID_FILE_ATTRIBUTES   0xFFFFFFFFu
#define FILE_BEGIN   0u
#define FILE_CURRENT 1u
#define FILE_END     2u
#define INVALID_SET_FILE_POINTER  0xFFFFFFFFu
#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#endif
#ifndef MAX_PATH
#define MAX_PATH 260
#endif
#define INFINITE      0xFFFFFFFFu
#ifndef WAIT_OBJECT_0
#define WAIT_OBJECT_0 0u
#endif
#ifndef WAIT_TIMEOUT
#define WAIT_TIMEOUT  0x102u
#endif

// A HANDLE from CreateFileA is a POSIX fd + 1, so that fd 0 never collides with
// NULL and the (HANDLE)-1 sentinel stays distinct.
// Upstream builds paths with Windows separators throughout (FS_BuildOSPath and friends),
// e.g. ".\\zone\\english\\code_post_gfx_mp.ff". POSIX open() treats a backslash as an
// ordinary filename character, so every fastfile lookup failed with "Could not find zone".
// Normalise here rather than at ~200 call sites.
static inline const char *kb_normpath(const char *in, char *buf, size_t n) {
    if (!in) return in;
    size_t i = 0;
    for (; in[i] && i + 1 < n; ++i) buf[i] = in[i] == '\\' ? '/' : in[i];
    buf[i] = 0;
    return buf;
}

static inline HANDLE CreateFileA(const char *name, DWORD access, DWORD share, void *sa,
                                 DWORD disposition, DWORD flags, HANDLE tmpl) {
    (void)share; (void)sa; (void)flags; (void)tmpl;
    char pathbuf[1024];
    name = kb_normpath(name, pathbuf, sizeof(pathbuf));
    int f = 0;
    const bool wr = (access & GENERIC_WRITE) != 0, rd = (access & GENERIC_READ) != 0;
    f = wr && rd ? O_RDWR : (wr ? O_WRONLY : O_RDONLY);
    if (disposition == CREATE_ALWAYS)          f |= O_CREAT | O_TRUNC;
    else if (disposition == CREATE_NEW)        f |= O_CREAT | O_EXCL;
    else if (disposition == OPEN_ALWAYS)       f |= O_CREAT;
    else if (disposition == TRUNCATE_EXISTING) f |= O_TRUNC;
    int fd = ::open(name, f, 0644);
    return fd < 0 ? INVALID_HANDLE_VALUE : (HANDLE)(intptr_t)(fd + 1);
}
// Two kinds of HANDLE reach these shims. CreateFileA hands back fd+1 - a small integer,
// biased so fd 0 is not NULL. But db_registry.cpp's try_open was changed upstream to
// std::fopen, so the fastfile path carries a real FILE* instead, and that pointer is a
// genuine address. Discriminate on magnitude: no fd is anywhere near 1<<16, and no heap
// pointer is that low on macOS (__PAGEZERO alone reserves the first 4 GB).
static inline bool kb_is_stdio(HANDLE h) { return (uintptr_t)h > 0x10000u; }
static inline int  kb_fd(HANDLE h) {
    return kb_is_stdio(h) ? fileno((FILE *)h) : (int)(intptr_t)h - 1;
}
static inline int CloseHandle(HANDLE h) {
    if (!h || h == INVALID_HANDLE_VALUE) return 0;
    if (kb_is_stdio(h)) return fclose((FILE *)h) == 0;   // opened by std::fopen
    return ::close(kb_fd(h)) == 0;
}
// NB: the out-parameter must not be called `read` - it shadows the POSIX read()
// syscall for every translation unit that includes this header.
static inline int ReadFile(HANDLE h, void *buf, DWORD n, DWORD *outRead, void *ov) {
    (void)ov;
    ssize_t g = ::read(kb_fd(h), buf, n);
    if (g < 0) { if (outRead) *outRead = 0; return 0; }
    if (outRead) *outRead = (DWORD)g;
    return 1;
}
static inline int WriteFile(HANDLE h, const void *buf, DWORD n, DWORD *wrote, void *ov) {
    (void)ov;
    ssize_t g = ::write(kb_fd(h), buf, n);
    if (g < 0) { if (wrote) *wrote = 0; return 0; }
    if (wrote) *wrote = (DWORD)g;
    return 1;
}
static inline DWORD SetFilePointer(HANDLE h, long lo, long *hi, DWORD from) {
    (void)hi;
    int wh = from == FILE_BEGIN ? SEEK_SET : (from == FILE_END ? SEEK_END : SEEK_CUR);
    off_t r = ::lseek(kb_fd(h), lo, wh);
    return r < 0 ? INVALID_SET_FILE_POINTER : (DWORD)r;
}
static inline DWORD GetFileSize(HANDLE h, DWORD *hi) {
    struct stat st;
    if (fstat(kb_fd(h), &st) != 0) return 0xFFFFFFFFu;
    if (hi) *hi = (DWORD)((uint64_t)st.st_size >> 32);
    return (DWORD)st.st_size;
}
static inline DWORD GetFileAttributesA(const char *p) {
    char pb[1024]; p = kb_normpath(p, pb, sizeof(pb));
    struct stat st;
    if (stat(p, &st) != 0) return INVALID_FILE_ATTRIBUTES;
    return S_ISDIR(st.st_mode) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
}
static inline int DeleteFileA(const char *p) { char pb[1024]; return unlink(kb_normpath(p, pb, sizeof(pb))) == 0; }
static inline int CreateDirectoryA(const char *p, void *sa) { (void)sa; char pb[1024]; return mkdir(kb_normpath(p, pb, sizeof(pb)), 0755) == 0; }

// --- module / process -------------------------------------------------------
// The engine only uses these to probe optional DLLs and to bail out; dlopen and
// _exit answer the same shapes, and a NULL result is already handled upstream.
static inline HANDLE GetModuleHandleA(const char *n) { return n ? (HANDLE)dlopen(n, RTLD_LAZY | RTLD_NOLOAD) : (HANDLE)RTLD_DEFAULT; }
static inline HANDLE LoadLibraryA(const char *n) { return (HANDLE)dlopen(n, RTLD_LAZY | RTLD_LOCAL); }
static inline void  *GetProcAddress(HANDLE m, const char *s) { return dlsym(m ? m : RTLD_DEFAULT, s); }
static inline int    FreeLibrary(HANDLE m) { return dlclose(m) == 0; }
static inline void   ExitProcess(unsigned code) { _exit((int)code); }
static inline HANDLE GetCurrentProcess(void) { return (HANDLE)(intptr_t)-1; }

// --- overlapped (async) file I/O --------------------------------------------
// db_file_load.cpp streams fastfiles with ReadFileEx + an OVERLAPPED offset.
// Its completion routine (DB_FileReadCompletion, db_file_load.cpp:170) is EMPTY,
// so the asynchrony carries no meaning here: a synchronous pread at the same
// offset followed by an inline call to the routine is exactly equivalent. Zone
// loads become blocking, which costs a little load time and nothing else.
typedef void (*LPOVERLAPPED_COMPLETION_ROUTINE)(unsigned long, unsigned long, struct _OVERLAPPED *);

static inline DWORD GetLastError(void) { return (DWORD)errno; }
static inline void  SetLastError(DWORD e) { errno = (int)e; }

#ifndef WAIT_IO_COMPLETION
#define WAIT_IO_COMPLETION 192u
#endif

// An alertable SleepEx blocks until a queued I/O completion routine runs, then returns
// WAIT_IO_COMPLETION. db_file_load.cpp:60 calls SleepEx(INFINITE, TRUE) after each
// ReadFileEx to wait for that read to land.
//
// Our ReadFileEx preads and invokes the completion routine INLINE before returning, so by
// the time we get here the I/O has already completed and there is nothing to wait for.
// Sleeping would hang forever - taking INFINITE literally meant usleep(0xFFFFFFFF * 1000),
// about 49 days, which is exactly where zone loading stalled.
static inline DWORD SleepEx(DWORD ms, int alertable) {
    if (alertable) return WAIT_IO_COMPLETION;
    if (ms && ms != 0xFFFFFFFFu) usleep((useconds_t)ms * 1000u);
    return 0;
}

#ifndef ERROR_HANDLE_EOF
#define ERROR_HANDLE_EOF 38u        // db_file_load.cpp:146 tests GetLastError() != 38
#endif

// Bytes the last ReadFileEx actually delivered. db_file_load.cpp's DB_WaitXFileStage adds a
// hard-coded 0x40000 to zlib's avail_in, which is only right when the read filled the whole
// chunk. Zones are routinely smaller than one chunk, so it must add the real count instead.
extern unsigned long kb_last_read_bytes;

static inline int ReadFileEx(HANDLE h, void *buf, DWORD n, struct _OVERLAPPED *ov,
                             LPOVERLAPPED_COMPLETION_ROUTINE done) {
    if (!ov) return 0;
    off_t off = (off_t)ov->Offset | ((off_t)ov->OffsetHigh << 32);
    ssize_t got = ::pread(kb_fd(h), buf, n, off);
    if (got < 0) return 0;

    // Zones are read in fixed 0x40000 chunks, but a zone is usually far smaller than one
    // chunk (code_post_gfx_mp.ff is 87 KB). Windows signals the end of file by FAILING the
    // read with ERROR_HANDLE_EOF, which is exactly what db_file_load.cpp:146 checks for; a
    // short read must therefore not look like a success, or the caller adds a full 0x40000
    // to zlib's avail_in and inflate chews through uninitialised buffer.
    if (got == 0) {
        errno = (int)ERROR_HANDLE_EOF;
        return 0;
    }

    // Partial read: give zlib deterministic bytes past the end rather than whatever was in
    // the buffer. inflate reaches Z_STREAM_END inside the real data and never reads them.
    if ((DWORD)got < n) std::memset((unsigned char *)buf + got, 0, n - (size_t)got);

    ov->InternalHigh = (unsigned long long)got;
    kb_last_read_bytes = (unsigned long)got;
    if (done) done(0, (unsigned long)got, ov);
    return 1;
}

// --- clipboard --------------------------------------------------------------
// Only the assert dialog uses this, to offer "copy the callstack". Accept and
// discard rather than pulling in AppKit for a debug convenience.
static inline int   OpenClipboard(void *w) { (void)w; return 1; }
static inline int   EmptyClipboard(void) { return 1; }
static inline int   CloseClipboard(void) { return 1; }
static inline void *SetClipboardData(unsigned fmt, void *h) { (void)fmt; return h; }

#endif // !_MSC_VER

#endif // __cplusplus
