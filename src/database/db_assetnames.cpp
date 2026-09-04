#include "database.h"
#include <game/g_bsp.h>

//int32_t marker_db_assetnames 828ddeec     db_assetnames.obj

const char *(__cdecl *DB_XAssetGetNameHandler[33])(const XAssetHeader *) =
{
    // KISAKTODO: these got Identical COMDAT folded into 1 function because name is usually the 1st field.
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_ImageGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    0,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_StringTableGetName,
    DB_LocalizeEntryGetName,
    DB_StringTableGetName,
    0,
    DB_StringTableGetName,
    DB_StringTableGetName,
    0,
    0,
    0,
    0,
    DB_StringTableGetName,
    DB_StringTableGetName
};

void(__cdecl *DB_XAssetSetNameHandler[33])(XAssetHeader *, const char *) =
{
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_ImageSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    0,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_StringTableSetName,
    DB_LocalizeEntrySetName,
    DB_StringTableSetName,
    0,
    DB_StringTableSetName,
    DB_StringTableSetName,
    0,
    0,
    0,
    0,
    DB_StringTableSetName,
    DB_StringTableSetName
};

// KISAKTODO: make these non-fixed
int32_t __cdecl DB_SizeofXAsset_RawFile_()
{
    return sizeof(RawFile);
}
int32_t __cdecl DB_SizeofXAsset_GameWorldSp_()
{
    return sizeof(GameWorldSp);
}
int32_t __cdecl DB_SizeofXAsset_XAnimParts_()
{
    return sizeof(XAnimParts);
}
int32_t __cdecl DB_SizeofXAsset_XModel_()
{
    return sizeof(XModel);
}
int32_t __cdecl DB_SizeofXAsset_Material_()
{
    return sizeof(Material);
}
int32_t __cdecl DB_SizeofXAsset_MaterialTechniqueSet_()
{
    return sizeof(MaterialTechniqueSet);
}
int32_t __cdecl DB_SizeofXAsset_GfxImage_()
{
    return sizeof(GfxImage);
}
int32_t __cdecl DB_SizeofXAsset_SndCurve_()
{
    return sizeof(SndCurve);
}
int32_t __cdecl DB_SizeofXAsset_menuDef_t_()
{
    return sizeof(menuDef_t);
}
int32_t __cdecl DB_SizeofXAsset_StringTable_()
{
    return sizeof(StringTable);
}
int32_t __cdecl DB_SizeofXAsset_GameWorldMp_()
{
    return sizeof(GameWorldMp);
}
int32_t __cdecl DB_SizeofXAsset_GfxWorld_()
{
    return sizeof(GfxWorld);
}
int32_t __cdecl DB_SizeofXAsset_Font_s_()
{
    return sizeof(Font_s);
}
int32_t __cdecl DB_SizeofXAsset_FxImpactTable_()
{
    return sizeof(FxImpactTable);
}
int32_t __cdecl DB_SizeofXAsset_WeaponDef_()
{
    return sizeof(WeaponDef);
}
int32_t __cdecl DB_SizeofXAsset_FxEffectDef_()
{
    return sizeof(FxEffectDef);
}
// The size of an asset is what DB_CloneXAssetInternal memcpys into a pool slot, so
// a wrong entry here silently overruns the slot and clobbers the next free-list link.
//
// The decompiled table could not be trusted: IDA folds functions with identical
// bodies, and on x86 many of these returned the same constant, so one symbol stood in
// for several unrelated types - index 9 (LOADED_SOUND) resolved to sizeof(GameWorldSp).
// Those sizes are equal at 32 bits and different at LP64. Naming the type per slot
// makes the table say what it means and lets the compiler compute each size.
template <typename T> static int32_t __cdecl DB_SizeofXAsset()
{
    return static_cast<int32_t>(sizeof(T));
}

int(__cdecl *DB_GetXAssetSizeHandler[ASSET_TYPE_COUNT])() =
{
    DB_SizeofXAsset<XModelPieces>,              //  0 XMODELPIECES
    DB_SizeofXAsset<PhysPreset>,                //  1 PHYSPRESET
    DB_SizeofXAsset<XAnimParts>,                //  2 XANIMPARTS
    DB_SizeofXAsset<XModel>,                    //  3 XMODEL
    DB_SizeofXAsset<Material>,                  //  4 MATERIAL
    DB_SizeofXAsset<MaterialTechniqueSet>,      //  5 TECHNIQUE_SET
    DB_SizeofXAsset<GfxImage>,                  //  6 IMAGE
    DB_SizeofXAsset<snd_alias_list_t>,          //  7 SOUND
    DB_SizeofXAsset<SndCurve>,                  //  8 SOUND_CURVE
    DB_SizeofXAsset<LoadedSound>,               //  9 LOADED_SOUND
    DB_SizeofXAsset<clipMap_t>,                 // 10 CLIPMAP
    DB_SizeofXAsset<clipMap_t>,                 // 11 CLIPMAP_PVS
    DB_SizeofXAsset<ComWorld>,                  // 12 COMWORLD
    DB_SizeofXAsset<GameWorldSp>,               // 13 GAMEWORLD_SP
    DB_SizeofXAsset<GameWorldMp>,               // 14 GAMEWORLD_MP
    DB_SizeofXAsset<MapEnts>,                   // 15 MAP_ENTS
    DB_SizeofXAsset<GfxWorld>,                  // 16 GFXWORLD
    DB_SizeofXAsset<GfxLightDef>,               // 17 LIGHT_DEF
    0,                                          // 18 UI_MAP
    DB_SizeofXAsset<Font_s>,                    // 19 FONT
    DB_SizeofXAsset<MenuList>,                  // 20 MENULIST
    DB_SizeofXAsset<menuDef_t>,                 // 21 MENU
    DB_SizeofXAsset<LocalizeEntry>,             // 22 LOCALIZE_ENTRY
    DB_SizeofXAsset<WeaponDef>,                 // 23 WEAPON
    0,                                          // 24 SNDDRIVER_GLOBALS
    DB_SizeofXAsset<FxEffectDef>,               // 25 FX
    DB_SizeofXAsset<FxImpactTable>,             // 26 IMPACT_FX
    0,                                          // 27 AITYPE
    0,                                          // 28 MPTYPE
    0,                                          // 29 CHARACTER
    0,                                          // 30 XMODELALIAS
    DB_SizeofXAsset<RawFile>,                   // 31 RAWFILE
    DB_SizeofXAsset<StringTable>,               // 32 STRINGTABLE
};

void __cdecl DB_StringTableSetName(XAssetHeader *header, const char *name)
{
    header->xmodelPieces->name = name;
}

const char *__cdecl DB_ImageGetName(const XAssetHeader *header)
{
    return header->image->name;
}

void __cdecl DB_ImageSetName(XAssetHeader *header, const char *name)
{
    //header->xmodelPieces[2].pieces = name;
    //header->xmodelPieces[2].name = name;
    header->image->name = name;
}

const char *__cdecl DB_StringTableGetName(const XAssetHeader *header)
{
    return header->stringTable->name;
}

const char *__cdecl DB_LocalizeEntryGetName(const XAssetHeader *header)
{
    return header->localize->name;
}

void __cdecl DB_LocalizeEntrySetName(XAssetHeader *header, const char *name)
{
    header->localize->name = name;
}

const char *__cdecl DB_GetXAssetHeaderName(int32_t type, const XAssetHeader *header)
{
    const char *name; // [esp+0h] [ebp-4h]

    iassert(header);
    iassert(DB_XAssetGetNameHandler[type]);
    iassert(header->data);

    name = DB_XAssetGetNameHandler[type](header);

    iassert(name);
    //if (!name)
    //{
    //    MyAssertHandler(".\\database\\db_assetnames.cpp", 594, 0, "%s\n\t%s", "name", 
    //      va("Name not found for asset type %s\n", g_assetNames[type]));
    //}
    return name;
}

const char *__cdecl DB_GetXAssetName(const XAsset *asset)
{
    iassert(asset);
    return DB_GetXAssetHeaderName(asset->type, &asset->header);
}

void __cdecl DB_SetXAssetName(XAsset *asset, const char *name)
{
    if (!DB_XAssetSetNameHandler[asset->type])
        MyAssertHandler(".\\database\\db_assetnames.cpp", 608, 0, "%s", "DB_XAssetSetNameHandler[asset->type]");
    DB_XAssetSetNameHandler[asset->type](&asset->header, name);
}

int32_t __cdecl DB_GetXAssetTypeSize(int32_t type)
{
    if (!DB_GetXAssetSizeHandler[type])
        MyAssertHandler(".\\database\\db_assetnames.cpp", 615, 0, "%s", "DB_GetXAssetSizeHandler[type]");
    return DB_GetXAssetSizeHandler[type]();
}

const char *__cdecl DB_GetXAssetTypeName(uint32_t type)
{
    if (type > 0x20)
        MyAssertHandler(".\\database\\db_assetnames.cpp", 621, 0, "%s", "type >= 0 && type < ASSET_TYPE_COUNT");
    return g_assetNames[type];
}

