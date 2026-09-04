// Switch port fastfile loader entry point. The upstream pipeline
// (db_file_load.cpp) depends on Win32 async I/O (ReadFileEx +
// OVERLAPPED), so instead of porting that we pre-inflate the entire
// .ff into a memory buffer and back the existing Load_* hot path with
// a cursor-based DB_LoadXFileData. The rest of db_load.cpp can then
// drive the asset stream as-is.
//
// Status: foundation stone. Today we open, inflate, read XFile +
// XAssetList header, and log the asset counts. Per-asset loaders
// (Load_MenuList etc.) are next session's work — each one has 32->64
// pointer fixes to audit before it can deserialize correctly.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifdef __SWITCH__
#include <switch.h>
#endif

#include <zlib/zlib.h>

#include "xanim/xanim.h"  // XFile, XAssetList, XAsset

extern XAsset *varXAsset;
extern XAssetList *varXAssetList;

// db_file_load.cpp owns this in the Win32 build; we provide it here so
// the rest of the database pipeline links.
XAssetList g_varXAssetList;

namespace {

std::vector<uint8_t> g_inflated;
size_t g_cursor = 0;

void switch_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void switch_log(const char *fmt, ...)
{
    char buf[512];
    std::va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
#ifdef __SWITCH__
    if (n > 0) svcOutputDebugString(buf, (size_t)n);
#else
    std::fwrite(buf, 1, n, stderr);
    std::fputc('\n', stderr);
#endif
}

bool inflate_ff(const char *path)
{
    std::FILE *f = std::fopen(path, "rb");
    if (!f) { switch_log("[ff] cannot open %s", path); return false; }
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz < 12) { std::fclose(f); return false; }
    std::vector<uint8_t> raw(sz);
    if (std::fread(raw.data(), 1, sz, f) != (size_t)sz) {
        std::fclose(f); return false;
    }
    std::fclose(f);

    // Verify magic + version.
    if (std::memcmp(raw.data(), "IWff0100", 8) != 0 &&
        std::memcmp(raw.data(), "IWffu100", 8) != 0) {
        switch_log("[ff] bad magic in %s", path);
        return false;
    }
    uint32_t version = 0;
    std::memcpy(&version, raw.data() + 8, 4);
    if (version != 5) {
        switch_log("[ff] bad version %u in %s", version, path);
        return false;
    }

    // Inflate the rest. Reset state.
    g_inflated.clear();
    g_inflated.reserve(sz * 32);
    z_stream zs = {};
    if (inflateInit(&zs) != Z_OK) return false;
    zs.next_in  = raw.data() + 12;
    zs.avail_in = (uInt)(sz - 12);
    uint8_t out[64*1024];
    int rc;
    do {
        zs.next_out  = out;
        zs.avail_out = sizeof(out);
        rc = inflate(&zs, Z_NO_FLUSH);
        const size_t got = sizeof(out) - zs.avail_out;
        if (got) g_inflated.insert(g_inflated.end(), out, out + got);
    } while (rc == Z_OK);
    inflateEnd(&zs);
    if (rc != Z_STREAM_END) {
        switch_log("[ff] inflate err rc=%d (got %zu bytes)", rc, g_inflated.size());
        return false;
    }
    switch_log("[ff] inflated %s -> %zu bytes", path, g_inflated.size());
    return true;
}

} // namespace

// Replace the no-op stub: read sequentially from the pre-inflated buffer.
extern "C" void __cdecl DB_LoadXFileData(uint8_t *pos, uint32_t size)
{
    if (!pos || size == 0) return;
    if (g_cursor + size > g_inflated.size()) {
        switch_log("[ff] DB_LoadXFileData overflow: cursor=%zu size=%u total=%zu",
                   g_cursor, (unsigned)size, g_inflated.size());
        std::memset(pos, 0, size);
        return;
    }
    std::memcpy(pos, g_inflated.data() + g_cursor, size);
    g_cursor += size;
}

// Equivalent of db_file_load.cpp's DB_LoadXFile entry point. Kept as a
// no-op for now because the Switch path calls switch_load_zone directly
// — keeping the symbol prevents link breakage from the old call sites
// (cl_main_mp uses it conditionally on KISAK_NO_FASTFILES).
extern "C" void __cdecl DB_LoadXFile(const char * /*path*/, void * /*f*/,
                                     const char * /*filename*/,
                                     XZoneMemory * /*zoneMem*/,
                                     void (* /*interrupt*/)(),
                                     unsigned char * /*buf*/,
                                     int /*allocType*/) {}

// Public foundation entry: open + inflate + log XFile + XAssetList header.
// Returns count of assets parsed (or -1 on failure).
int switch_load_zone(const char *zone_name, const char *path)
{
    if (!inflate_ff(path)) return -1;
    g_cursor = 0;

    // XFile struct (44 bytes 32-bit) lives at the start. Note: on 64-bit
    // host we can't just memcpy a sizeof(XFile) into our struct since the
    // engine's struct is laid out 32-bit-style on disk. XFile is purely
    // ints so this is fine.
    if (g_inflated.size() < 60) {
        switch_log("[ff] %s: buffer too small", path);
        return -1;
    }
    uint32_t xfile_size, xfile_extSize;
    std::memcpy(&xfile_size,    g_inflated.data() + 0, 4);
    std::memcpy(&xfile_extSize, g_inflated.data() + 4, 4);
    switch_log("[ff] %s: XFile.size=%u extSize=%u", zone_name, xfile_size, xfile_extSize);
    g_cursor += 44; // skip XFile

    // XAssetList on disk = 4 (stringCount) + 4 (strings ptr32) + 4 (count)
    // + 4 (assets ptr32) = 16 bytes. On our 64-bit struct this needs
    // manual unpacking, but for inspection-only purposes we just read the
    // 4 raw uint32_t values straight out of the cursor.
    uint32_t stringCount, stringsPtr32, assetCount, assetsPtr32;
    std::memcpy(&stringCount,  g_inflated.data() + g_cursor + 0,  4);
    std::memcpy(&stringsPtr32, g_inflated.data() + g_cursor + 4,  4);
    std::memcpy(&assetCount,   g_inflated.data() + g_cursor + 8,  4);
    std::memcpy(&assetsPtr32,  g_inflated.data() + g_cursor + 12, 4);
    g_cursor += 16;
    switch_log("[ff] %s: stringCount=%u stringsPtr=%#x assetCount=%u assetsPtr=%#x",
               zone_name, stringCount, stringsPtr32, assetCount, assetsPtr32);

    // Skip inline string pool if any (each ptr=0xFFFFFFFF triggers an
    // inline null-terminated string deserialized in-place).
    if (stringCount > 0) {
        g_cursor += stringCount * 4u; // pointer array
        for (uint32_t i = 0; i < stringCount; ++i) {
            while (g_cursor < g_inflated.size() && g_inflated[g_cursor] != 0) ++g_cursor;
            if (g_cursor < g_inflated.size()) ++g_cursor;
        }
        switch_log("[ff]   string pool ends at cursor=%#zx", g_cursor);
    }

    // Read raw asset table: 8 bytes per entry (type:4 + ptr:4). On a
    // 64-bit build our `XAsset` is 16 bytes, but we want the on-disk
    // table here, so just iterate the raw bytes.
    if (g_cursor + (size_t)assetCount * 8u > g_inflated.size()) {
        switch_log("[ff] asset table OOB");
        return -1;
    }
    // Capture types into a parallel array so we can iterate later when
    // we walk the inline asset bodies and print names.
    std::vector<uint32_t> types(assetCount);
    int histogram[64] = {0};
    for (uint32_t i = 0; i < assetCount; ++i) {
        std::memcpy(&types[i], g_inflated.data() + g_cursor + i * 8u, 4);
        if (types[i] < 64) ++histogram[types[i]];
    }
    for (int t = 0; t < 64; ++t) {
        if (histogram[t] > 0) switch_log("[ff]   type %#04x : %d", t, histogram[t]);
    }
    // Advance the cursor past the asset table (DB_PushStreamPos(4) +
    // Load_Stream of 8*count bytes in db_file_load.cpp).
    g_cursor += (size_t)assetCount * 8u;

    // For each asset the engine then calls Load_XAsset which reads the
    // type+ptr (already consumed via the table above) and dispatches to
    // a type-specific loader. The first inline pointer is almost always
    // the asset's NAME string. RawFile/MenuList/Font etc. all begin
    // with `const char *name`. So as a sanity check we sniff the next
    // null-terminated string at each asset's position to see what names
    // the fastfile carries.
    //
    // We can't actually skip over a full asset body without per-type
    // structural knowledge (Materials have nested image / shader / arg
    // references that all live inline). So we only "successfully" name
    // the first few assets where the binary layout starts with a name
    // ptr + name string immediately. Anything past that becomes
    // unreliable. That's the moment we'll need real per-type loaders.
    // Locate the MenuList asset by scanning the inflated stream for the
    // canonical key "ui_mp/menus.txt". Before that string sit the 12
    // bytes of the MenuList struct (name_ptr=FFFFFFFF, menuCount, menus_ptr=FFFFFFFF).
    static const uint8_t kSentinelStart[] = {
        0xff, 0xff, 0xff, 0xff,                          // name ptr inline
    };
    static const char kMenuListKey[] = "ui_mp/menus.txt";
    size_t found = std::string::npos;
    for (size_t i = 12; i + sizeof(kMenuListKey) < g_inflated.size(); ++i) {
        if (g_inflated[i] == 'u' &&
            std::memcmp(g_inflated.data() + i, kMenuListKey, sizeof(kMenuListKey)-1) == 0)
        {
            // verify the 12 bytes BEFORE this string match the MenuList
            // header signature (FFFFFFFF + menuCount + FFFFFFFF).
            uint32_t markerName, markerMenus;
            std::memcpy(&markerName, g_inflated.data() + i - 12, 4);
            std::memcpy(&markerMenus, g_inflated.data() + i - 4, 4);
            if (markerName == 0xFFFFFFFFu && markerMenus == 0xFFFFFFFFu) {
                found = i - 12;
                break;
            }
        }
    }
    (void)kSentinelStart;
    if (found == std::string::npos) {
        switch_log("[ff] could not locate MenuList header");
        return (int)assetCount;
    }
    uint32_t menuCount;
    std::memcpy(&menuCount, g_inflated.data() + found + 4, 4);
    switch_log("[ff] MenuList header @%#zx: name='%s' menuCount=%u menus=inline",
               found, (const char *)(g_inflated.data() + found + 12), menuCount);

    // The 290 menuDef pointers (each 4 bytes, all 0xFFFFFFFF) follow the
    // inline name. After that, each menuDef_t is serialized as:
    //   - 284 bytes of fixed struct (windowDef_t + menuDef_t fields,
    //     with all pointer fields stored as 0xFFFFFFFF markers when
    //     they reference inline data)
    //   - inline name string (null-terminated, follows the struct)
    //   - more inline data (onOpen script, items array, expressions,
    //     ...) the size of which depends on the struct's marker bits
    //
    // For the FIRST menuDef the name lives at exactly +284. Read it
    // straight off so we prove the layout matches the engine's
    // Load_menuDef_t expectations. Subsequent menus need full binary
    // walking — that's the next session's deliverable.
    const size_t firstMenuOff = found + 12 + 16 + 290u * 4u;
    if (firstMenuOff + 284 + 1 < g_inflated.size()) {
        // Within the 284-byte struct head, a few fields we can already
        // read straight off the 32-bit binary layout. See ui_shared.h
        // menuDef_t comments.
        float rectW, rectH, focusR, focusG, focusB, focusA;
        uint32_t itemCount, fullScreen, items_marker;
        std::memcpy(&rectW,        g_inflated.data() + firstMenuOff +  12, 4);
        std::memcpy(&rectH,        g_inflated.data() + firstMenuOff +  16, 4);
        std::memcpy(&fullScreen,   g_inflated.data() + firstMenuOff + 160, 4);
        std::memcpy(&itemCount,    g_inflated.data() + firstMenuOff + 164, 4);
        std::memcpy(&focusR,       g_inflated.data() + firstMenuOff + 232, 4);
        std::memcpy(&focusG,       g_inflated.data() + firstMenuOff + 236, 4);
        std::memcpy(&focusB,       g_inflated.data() + firstMenuOff + 240, 4);
        std::memcpy(&focusA,       g_inflated.data() + firstMenuOff + 244, 4);
        std::memcpy(&items_marker, g_inflated.data() + firstMenuOff + 280, 4);
        const char *firstName = (const char *)(g_inflated.data() + firstMenuOff + 284);
        switch_log("[ff] menuDef[0] @%#zx: name='%s' rect=%.0fx%.0f fullScreen=%u itemCount=%u focus=(%.2f,%.2f,%.2f,%.2f) items_ptr=%#x",
                   firstMenuOff, firstName, rectW, rectH, fullScreen, itemCount,
                   focusR, focusG, focusB, focusA, items_marker);
    }

    // Continue with the heuristic scan so we still get a flavour of the
    // remaining 289 menus — even if some matches are action handlers
    // that share the FFFFFFFF + identifier pattern.
    const size_t menuArea = found + 12 + 16 + 290u * 4u;
    int logged = 0;
    for (size_t i = menuArea; i + 8 < g_inflated.size() && logged < 60; ++i) {
        // Looking for: FFFFFFFF marker + lowercase letter start
        uint32_t m;
        std::memcpy(&m, g_inflated.data() + i, 4);
        if (m != 0xFFFFFFFFu) continue;
        const uint8_t *p = g_inflated.data() + i + 4;
        // Must look like an identifier: starts with letter, only
        // printable alphanumeric / underscore, null-terminated, length
        // 3-40 chars.
        const uint8_t *p0 = p;
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || *p == '_'))
            continue;
        int len = 0;
        while (len < 41) {
            uint8_t c = p[len];
            if (c == 0) break;
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '/' || c == '.'))
                { len = 0; break; }
            ++len;
        }
        if (len < 3 || len > 40 || p[len] != 0) continue;
        // Avoid common action-handler strings.
        if (std::strncmp((const char *)p0, "scr_", 4) == 0) continue;
        if (std::strncmp((const char *)p0, "ui_", 3) == 0) continue;
        if (std::strncmp((const char *)p0, "specialty_", 10) == 0) continue;
        switch_log("[ff]   menu? @%#zx '%s'", i, (const char *)p0);
        ++logged;
        i += 4 + len; // skip past the string
    }
    return (int)assetCount;
}
