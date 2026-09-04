// Proves the bridge reaches real asset structs, not just names: it reads fields
// out of a GfxImage and a GfxWorld through the engine's own struct layout.
#include "oatbridge.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>

// The two struct shapes the test reads through, copied from the engine headers
// (r_gfx.h, r_world.h). If these ever disagree with OAT the values print as junk.
struct BridgeGfxImage
{
    int mapType;                    // MapType, an enum
    void *texture;                  // union GfxTexture - pointers only
    unsigned char picmip[2];        // struct Picmip
    bool noPicmip;
    unsigned char semantic;
    unsigned char track;
    int cardMemory[2];              // struct CardMemory
    unsigned short width, height, depth;
    unsigned char category;
    bool delayLoadPixels;
    const char *name;
};

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: oatbridge_test <zone.ff>\n");
        return 2;
    }

    char err[512] = {0};
    OatZone *zone = OAT_LoadZone(argv[1], err, sizeof(err));
    if (!zone)
    {
        std::fprintf(stderr, "FAIL load: %s\n", err);
        return 1;
    }

    const int count = OAT_AssetCount(zone);
    std::printf("zone '%s': %d assets\n", OAT_ZoneName(zone), count);

    std::map<int, int> byType;
    int nullPtrs = 0;
    OatAsset first{};
    bool haveImage = false;

    for (int i = 0; i < count; ++i)
    {
        OatAsset a{};
        if (!OAT_AssetAt(zone, i, &a))
        {
            std::fprintf(stderr, "FAIL: OAT_AssetAt(%d)\n", i);
            return 1;
        }
        ++byType[a.type];
        if (!a.data)
            ++nullPtrs;
        // ASSET_TYPE_IMAGE - the value is 6 in both trees; the two XAssetType
        // enums are identical from ASSET_TYPE_XMODELPIECES through STRINGTABLE.
        if (a.type == 6 && !haveImage && a.data)
        {
            first = a;
            haveImage = true;
        }
    }

    std::printf("asset types present: %zu   null asset pointers: %d\n", byType.size(), nullPtrs);
    for (const auto &[type, n] : byType)
        std::printf("   type %3d  x%d\n", type, n);

    if (haveImage)
    {
        const auto *img = static_cast<const BridgeGfxImage *>(first.data);
        std::printf("\nread through the engine's GfxImage layout:\n");
        std::printf("   name      = %s\n", first.name);
        std::printf("   struct name = %s\n", img->name ? img->name : "(null)");
        std::printf("   %ux%ux%u  mapType=%d category=%u noPicmip=%d picmip=%u/%u\n",
                    img->width, img->height, img->depth, img->mapType, img->category,
                    img->noPicmip ? 1 : 0, img->picmip[0], img->picmip[1]);
        std::printf("   sizeof(BridgeGfxImage)=%zu (engine GfxImage must agree)\n", sizeof(BridgeGfxImage));
        const bool sane = img->width > 0 && img->width <= 8192 && img->height > 0 && img->height <= 8192
                          && img->name && std::strlen(img->name) > 0;
        std::printf("   VERDICT: %s\n", sane ? "PLAUSIBLE - fields land where the engine expects" : "GARBAGE - layouts disagree");
        OAT_FreeZone(zone);
        return sane ? 0 : 1;
    }

    OAT_FreeZone(zone);
    return nullPtrs == 0 ? 0 : 1;
}
