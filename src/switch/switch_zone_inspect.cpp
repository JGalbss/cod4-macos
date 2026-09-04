// Inspeciona um fastfile (.ff) CoD4 no Switch port. Sem depender da
// pipeline cheia do db_load (que ainda esta cheia de pointers truncados
// em 64-bit), abrimos via stdio, inflate o stream com zlib, e logamos a
// asset list. E o primeiro tijolo de uma reconstrucao incremental: a
// proxima sessao adiciona load por tipo (RawFile -> StringTable ->
// MenuList -> Image -> TechniqueSet -> Material) sem precisar destravar
// o pipeline d3d9 inteiro de uma vez.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#ifdef __SWITCH__
#include <switch.h>
#endif

#include <zlib/zlib.h>

namespace {

void switch_log(const char *msg, size_t len)
{
#ifdef __SWITCH__
    svcOutputDebugString(msg, len);
#else
    std::fwrite(msg, 1, len, stderr);
    std::fputc('\n', stderr);
#endif
}

void switch_logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void switch_logf(const char *fmt, ...)
{
    char buf[512];
    std::va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) switch_log(buf, (size_t)n);
}

const char *asset_type_name(int t)
{
    switch (t) {
    case 0x00: return "XMODELPIECES";
    case 0x01: return "PHYSPRESET";
    case 0x02: return "XANIMPARTS";
    case 0x03: return "XMODEL";
    case 0x04: return "MATERIAL";
    case 0x05: return "TECHNIQUE_SET";
    case 0x06: return "IMAGE";
    case 0x07: return "SOUND";
    case 0x09: return "LOADED_SOUND";
    case 0x0A: return "CLIPMAP";
    case 0x0C: return "COMWORLD";
    case 0x0F: return "MAP_ENTS";
    case 0x10: return "GFXWORLD";
    case 0x11: return "LIGHT_DEF";
    case 0x12: return "UI_MAP";
    case 0x13: return "FONT";
    case 0x14: return "MENULIST";
    case 0x15: return "MENU";
    case 0x17: return "WEAPON";
    case 0x1A: return "IMPACT_FX";
    case 0x1F: return "RAWFILE";
    case 0x20: return "STRINGTABLE";
    default:   return "?";
    }
}

} // namespace

void switch_inspect_zone(const char *path)
{
    std::FILE *f = std::fopen(path, "rb");
    if (!f) {
        switch_logf("[zone] cannot open %s", path);
        return;
    }
    std::fseek(f, 0, SEEK_END);
    long size = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (size < 12) {
        switch_logf("[zone] %s too small (%ld bytes)", path, size);
        std::fclose(f);
        return;
    }
    std::vector<uint8_t> raw(size);
    if (std::fread(raw.data(), 1, size, f) != (size_t)size) {
        switch_logf("[zone] read short for %s", path);
        std::fclose(f);
        return;
    }
    std::fclose(f);

    // Header: 8 bytes magic + 4 bytes version.
    char magic[9] = {0};
    std::memcpy(magic, raw.data(), 8);
    uint32_t version = 0;
    std::memcpy(&version, raw.data() + 8, 4);
    if (std::memcmp(magic, "IWff0100", 8) != 0 && std::memcmp(magic, "IWffu100", 8) != 0) {
        switch_logf("[zone] %s: bad magic '%s'", path, magic);
        return;
    }
    if (version != 5) {
        switch_logf("[zone] %s: bad version %u (expected 5)", path, version);
        return;
    }
    switch_logf("[zone] %s: magic=%s version=%u size=%ld", path, magic, version, size);

    // Inflate just enough to cover XFile + XAssetList header + string
    // pool + asset table. For mission .ff's that can be 600 MB+ inflated
    // we cap the output at 256 KB so the inspector stays bounded.
    constexpr size_t kInspectInflateCap = 256u * 1024u;
    z_stream zs = {};
    if (inflateInit(&zs) != Z_OK) {
        switch_logf("[zone] inflateInit fail");
        return;
    }
    zs.next_in = raw.data() + 12;
    zs.avail_in = (uInt)(size - 12);
    std::vector<uint8_t> dec;
    dec.resize(kInspectInflateCap);
    int rc;
    size_t totalOut = 0;
    while (totalOut < kInspectInflateCap) {
        zs.next_out = dec.data() + totalOut;
        zs.avail_out = (uInt)(kInspectInflateCap - totalOut);
        rc = inflate(&zs, Z_NO_FLUSH);
        totalOut = zs.total_out;
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) {
            switch_logf("[zone] inflate err rc=%d at out=%zu", rc, totalOut);
            inflateEnd(&zs);
            return;
        }
    }
    inflateEnd(&zs);
    dec.resize(totalOut);
    switch_logf("[zone] inflated %zu bytes", totalOut);

    if (totalOut < 60) {
        switch_logf("[zone] inflated payload too small for XFile+XAssetList");
        return;
    }
    // XFile (44 bytes) then XAssetList (16 bytes).
    uint32_t xfile_size, xfile_extSize;
    std::memcpy(&xfile_size, dec.data() + 0, 4);
    std::memcpy(&xfile_extSize, dec.data() + 4, 4);
    // XAssetList: stringCount(4) + strings_ptr(4) + assetCount(4) + assets_ptr(4)
    uint32_t stringCount, stringsPtr, assetCount, assetsPtr;
    std::memcpy(&stringCount, dec.data() + 44, 4);
    std::memcpy(&stringsPtr,  dec.data() + 48, 4);
    std::memcpy(&assetCount,  dec.data() + 52, 4);
    std::memcpy(&assetsPtr,   dec.data() + 56, 4);
    switch_logf("[zone] xfile.size=%u extSize=%u", xfile_size, xfile_extSize);
    switch_logf("[zone] xal stringCount=%u stringsPtr=%#x assetCount=%u assetsPtr=%#x",
                stringCount, stringsPtr, assetCount, assetsPtr);

    // After XAssetList header, if stringCount > 0, there's a string pointer
    // array (4 bytes per entry, 0xFFFFFFFF means "inline next") followed by
    // the inline string data (null-terminated). Skip past both to reach
    // the asset table.
    size_t assetTableOff = 60;
    if (stringCount > 0) {
        // pointer array
        const size_t ptrArrEnd = 60 + stringCount * 4u;
        if (ptrArrEnd > totalOut) {
            switch_logf("[zone] string ptr array out of range");
            return;
        }
        size_t cursor = ptrArrEnd;
        for (uint32_t i = 0; i < stringCount; ++i) {
            uint32_t sp;
            std::memcpy(&sp, dec.data() + 60 + i * 4u, 4);
            if (sp == 0xFFFFFFFFu) {
                // inline string follows at `cursor`
                while (cursor < totalOut && dec[cursor] != 0) ++cursor;
                if (cursor >= totalOut) {
                    switch_logf("[zone] unterminated inline string at %zu", cursor);
                    return;
                }
                ++cursor; // skip null
            }
        }
        assetTableOff = cursor;
        switch_logf("[zone]   string pool ends at %#zx", assetTableOff);
    }

    if (assetCount > 65536 || assetTableOff + assetCount * 8 > totalOut) {
        switch_logf("[zone] asset table out of range (off=%#zx count=%u)",
                    assetTableOff, assetCount);
        return;
    }
    int counts[64] = {0};
    for (uint32_t i = 0; i < assetCount; ++i) {
        uint32_t type, ptr;
        std::memcpy(&type, dec.data() + assetTableOff + i * 8, 4);
        std::memcpy(&ptr,  dec.data() + assetTableOff + i * 8 + 4, 4);
        if (type < 64) ++counts[type];
    }
    for (int t = 0; t < 64; ++t) {
        if (counts[t] == 0) continue;
        switch_logf("[zone]   type %02x %-14s : %d", t, asset_type_name(t), counts[t]);
    }
}
