// C boundary over OpenAssetTools' ZoneLoading.
//
// OAT reads retail CoD4 fastfiles - which store 32-bit pointers and x86 struct
// layouts - and produces the same asset structs this engine declares, already in
// LP64 form. mac/tools/structdiff.py shows 23 of 25 asset types match field for
// field, so the engine can take these pointers directly instead of transcoding.
//
// The zone owns every asset pointer it returns. Do not free an asset, and do not
// use one after OAT_FreeZone.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OatZone OatZone;

typedef struct
{
    int type;          // IW3 asset_type_t, matches the engine's XAssetType
    const char *name;  // a leading ',' marks a reference to another zone's asset
    void *data;        // points at the engine's struct for `type`
    int isReference;
} OatAsset;

// Returns null on failure and writes the reason into errOut.
OatZone *OAT_LoadZone(const char *path, char *errOut, int errCap);

int OAT_AssetCount(const OatZone *zone);

// Fills `out` for 0 <= index < OAT_AssetCount. Returns 0 if index is out of range.
int OAT_AssetAt(const OatZone *zone, int index, OatAsset *out);

const char *OAT_ZoneName(const OatZone *zone);

// A zone stores its script strings as indices into its own table, so every
// scr_string_t inside an asset is meaningless until it is translated through
// this list into the runtime's string interner. Index 0 is the null string.
int OAT_ScriptStringCount(const OatZone *zone);

// Null when index is out of range, and may be null for an entry the zone left
// empty; both mean "no string".
const char *OAT_ScriptStringAt(const OatZone *zone, int index);

void OAT_FreeZone(OatZone *zone);

// Sizes of the structs OAT hands back, measured on OAT's side of the boundary.
// structdiff.py compares field names; this compares layout, which is what actually
// has to agree for a pointer handed over to be readable. Indexed by OatStructId.
typedef enum
{
    OAT_STRUCT_MATERIAL = 0,
    OAT_STRUCT_MATERIAL_TECHNIQUE_SET,
    OAT_STRUCT_GFX_IMAGE,
    OAT_STRUCT_MENU_DEF,
    OAT_STRUCT_ITEM_DEF,
    OAT_STRUCT_OPERAND,
    OAT_STRUCT_EXPRESSION_ENTRY,
    OAT_STRUCT_STATEMENT,
    OAT_STRUCT_XANIM_PARTS,
    OAT_STRUCT_XMODEL,
    OAT_STRUCT_GFX_WORLD,
    OAT_STRUCT_CLIPMAP,
    OAT_STRUCT_SND_ALIAS,
    OAT_STRUCT_SND_ALIAS_LIST,
    OAT_STRUCT_WEAPON_DEF,
    OAT_STRUCT_COUNT
} OatStructId;

const char *OAT_StructName(int id);
unsigned long OAT_StructSize(int id);

#ifdef __cplusplus
}
#endif
