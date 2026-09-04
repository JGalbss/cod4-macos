#include <qcommon/qcommon.h>
#include <universal/q_shared.h>

#include <cstring>

#include "r_buffers.h"

#include "r_drawsurf.h"
#include "r_draw_method.h"

#include "r_meshdata.h"

#include "r_dvars.h"

#include "r_scene.h"
#include <universal/profile.h>

static bool g_processCodeMesh;
static bool g_processMarkMesh;

// OAT preserves cross-zone asset pointers by copying reference assets into stable
// stubs.  Material_Sort only indexes the canonical materials enumerated from the
// database, so a copied material can still carry its fastfile default index (zero).
// Resolve those stubs to the exact-name entry in the sorted table before encoding a
// draw surface; otherwise an unrelated material at index zero shades the FX.
static Material *R_GetSortedFxMaterial(Material *material)
{
    if (!material || !material->info.name)
        return nullptr;

    const unsigned int storedIndex = material->info.drawSurf.fields.materialSortedIndex;
    if (storedIndex < static_cast<unsigned int>(rgp.materialCount))
    {
        Material *const stored = rgp.sortedMaterials[storedIndex];
        if (stored == material
            || (stored && stored->info.name
                && std::strcmp(stored->info.name, material->info.name) == 0))
        {
            return stored;
        }
    }

#ifdef KISAK_OAT_ZONES
    // The native fastfile table is ordered by the same (sort key, name) pair in
    // Posix Material_Sort.  Reference stubs are immutable while frames render, so
    // a binary lookup avoids both a shared cache and an O(materialCount) scan for
    // every late-zone FX batch.
    int first = 0;
    int last = rgp.materialCount;
    while (first < last)
    {
        const int index = first + (last - first) / 2;
        Material *const candidate = rgp.sortedMaterials[index];
        const char *const candidateName = candidate && candidate->info.name
            ? candidate->info.name : "";
        const int nameOrder = std::strcmp(candidateName, material->info.name);
        if (candidate->info.sortKey < material->info.sortKey
            || (candidate->info.sortKey == material->info.sortKey && nameOrder < 0))
        {
            first = index + 1;
        }
        else
        {
            last = index;
        }
    }
    if (first < rgp.materialCount)
    {
        Material *const candidate = rgp.sortedMaterials[first];
        if (candidate && candidate->info.name
            && candidate->info.sortKey == material->info.sortKey
            && std::strcmp(candidate->info.name, material->info.name) == 0)
        {
            return candidate;
        }
    }
#else
    for (int index = 0; index < rgp.materialCount; ++index)
    {
        Material *const candidate = rgp.sortedMaterials[index];
        if (candidate && candidate->info.name
            && std::strcmp(candidate->info.name, material->info.name) == 0)
        {
            return candidate;
        }
    }
#endif

    static volatile LONG unresolvedWarningCount;
    if (InterlockedIncrement(&unresolvedWarningCount) <= 32)
    {
        Com_PrintError(8, "ERROR: FX material '%s' is absent from the sorted material table\n",
                       material->info.name);
    }
    return nullptr;
}

char __cdecl R_ReserveCodeMeshIndices(int indexCount, r_double_index_t** indicesOut)
{
    iassert( g_processCodeMesh );
    if (R_ReserveMeshIndices(&frontEndDataOut->codeMesh, indexCount, indicesOut))
        return 1;
    R_WarnOncePerFrame(R_WARN_MAX_CODE_INDS);
    return 0;
}

char __cdecl R_ReserveCodeMeshVerts(int vertCount, unsigned __int16* baseVertex)
{
    iassert( g_processCodeMesh );
    if (R_ReserveMeshVerts(&frontEndDataOut->codeMesh, vertCount, baseVertex))
        return 1;
    R_WarnOncePerFrame(R_WARN_MAX_CODE_VERTS);
    return 0;
}

char __cdecl R_ReserveCodeMeshArgs(int argCount, unsigned int* argOffsetOut)
{
    [[maybe_unused]] volatile int oldArgCount; // [esp+8h] [ebp-4h]

    iassert( g_processCodeMesh );
    iassert( (argCount >= 0) );
    iassert( argOffsetOut );
    oldArgCount = frontEndDataOut->codeMeshArgsCount;
    if ((unsigned int)(argCount + oldArgCount) < 0x100)
    {
        *argOffsetOut = oldArgCount;
        InterlockedExchange(&frontEndDataOut->codeMeshArgsCount, static_cast<LONG>(argCount + oldArgCount));
        return 1;
    }
    else
    {
        R_WarnOncePerFrame(R_WARN_MAX_CODE_ARGS);
        return 0;
    }
}

byte R_GetMaterialSortKey(const Material* material)
{
    return material->info.sortKey;
}

GfxDrawSurf R_GetMaterialInfoPacked(const Material* material)
{
    return material->info.drawSurf;
}

// KISAKTODO THIS MIGHT BE WRONG?? FIELD IS A RANDOM ASS GUESS, IDA IS NOT BEING HELPFUL
GfxDrawSurf* __cdecl R_AllocFxDrawSurf(unsigned int region)
{
    [[maybe_unused]] int drawSurfCount; // [esp+8h] [ebp-4h]

    drawSurfCount = InterlockedIncrement(&scene.drawSurfCount[region]) - 1;
    if (drawSurfCount < scene.maxDrawSurfCount[region])
        return &scene.drawSurfs[region][drawSurfCount];
    InterlockedDecrement(&scene.drawSurfCount[region]);
    R_WarnOncePerFrame(R_WARN_MAX_FX_DRAWSURFS);
    return 0;
}

void __cdecl R_AddCodeMeshDrawSurf(
    Material* material,
    r_double_index_t* indices,
    unsigned int indexCount,
    unsigned int argOffset,
    unsigned int argCount,
    const char* fxName)
{
    [[maybe_unused]] int packed_high; // ecx
    [[maybe_unused]] unsigned int v7; // edx
    [[maybe_unused]] int MaterialSortKey; // [esp+20h] [ebp-28h]
    [[maybe_unused]] FxCodeMeshData* localCodeMesh; // [esp+30h] [ebp-18h]
    [[maybe_unused]] GfxDrawSurf* drawSurf; // [esp+34h] [ebp-14h]
    [[maybe_unused]] int region; // [esp+3Ch] [ebp-Ch]
    [[maybe_unused]] unsigned int codeMeshIndex; // [esp+44h] [ebp-4h]

    iassert(indexCount);
    iassert(g_processCodeMesh);
    material = R_GetSortedFxMaterial(material);
    if (!material)
        return;
    iassert(rgp.sortedMaterials[material->info.drawSurf.fields.materialSortedIndex] == material);

#ifdef KISAK_METAL
    // The Metal backend consumes the material and generated code mesh directly;
    // it does not execute the legacy D3D9 technique bytecode.  Mod fastfiles can
    // legitimately omit the active-renderer emissive slot while still supplying
    // valid sprite geometry and a color texture.  Rejecting those meshes here was
    // why muzzle flashes, smoke, tracers and impact particles generated vertices
    // every frame but never reached the native renderer.
    const bool canDraw = material && (material->info.gameFlags & 2) == 0;
#else
    const bool canDraw = Material_GetTechnique(material, gfxDrawMethod.emissiveTechType)
        && (material->info.gameFlags & 2) == 0;
#endif
    if (canDraw)
    {
        codeMeshIndex = InterlockedExchangeAdd(&frontEndDataOut->codeMeshCount, static_cast<LONG>(1));
        if (codeMeshIndex < 0x800)
        {
            localCodeMesh = &frontEndDataOut->codeMeshes[codeMeshIndex];
            localCodeMesh->triCount = indexCount / 3;
            localCodeMesh->indices = (unsigned __int16*)indices;
            iassert(argCount != 0 || argOffset == 0);
            iassert(argOffset >= 0 && argOffset < 256);
            localCodeMesh->argCount = argCount;
            iassert(localCodeMesh->argCount == argCount);
            localCodeMesh->argOffset = argOffset;
            iassert(localCodeMesh->argOffset == argOffset);
            MaterialSortKey = R_GetMaterialSortKey(material);
            region = (MaterialSortKey == 48) + (MaterialSortKey != 24 ? 0 : 2) + 12;
            drawSurf = R_AllocFxDrawSurf(region);
            if (drawSurf)
            {
                drawSurf->packed = R_GetMaterialInfoPacked(material).packed;
                // packed_high = HIDWORD(drawSurf->packed);

                drawSurf->fields.objectId = codeMeshIndex;
                // LODWORD(drawSurf->packed) = (unsigned __int16)codeMeshIndex | *(_DWORD*)&drawSurf->fields & 0xFFFF0000; // set objectId
                // HIDWORD(drawSurf->packed) = packed_high;
                
                drawSurf->fields.surfType = SF_CODE_MESH;
                // v7 = HIDWORD(drawSurf->packed) & 0xFFC3FFFF | 0x280000; // set surfType to b(1010)
                // LODWORD(drawSurf->packed) = drawSurf->packed;
                // HIDWORD(drawSurf->packed) = v7;

                
                // LODWORD(drawSurf->packed) = drawSurf->packed;
                // HIDWORD(drawSurf->packed) = HIDWORD(drawSurf->packed);

                iassert(drawSurf->fields.prepass == MTL_PREPASS_NONE);
                iassert(((region == DRAW_SURF_FX_CAMERA_EMISSIVE) || (drawSurf == scene.drawSurfs[region]) || (drawSurf->fields.primarySortKey >= (drawSurf - 1)->fields.primarySortKey)));
            }
        }
        else
        {
            R_WarnOncePerFrame(R_WARN_GFX_CODE_MESH_LIMIT);
        }
    }
    else
    {
        iassert(r_fullbright);
        if (!r_fullbright->current.enabled)
            R_WarnOncePerFrame(R_WARN_NONEMISSIVE_FX_MATERIAL, material->info.name, fxName);
    }
}

float (*__cdecl R_GetCodeMeshArgs(unsigned int argOffset))[4]
{
    iassert( g_processCodeMesh );
    return (float (*)[4])frontEndDataOut->codeMeshArgs[argOffset];
}

GfxPackedVertex* __cdecl R_GetCodeMeshVerts(unsigned __int16 baseVertex)
{
    iassert( g_processCodeMesh );
    return (GfxPackedVertex*)R_GetMeshVerts(&frontEndDataOut->codeMesh, baseVertex);
}

void R_EndMeshVerts(GfxMeshData* mesh)
{
#ifdef KISAK_METAL
    mesh->vb.verts = nullptr;
#else
    if (mesh->vb.verts)
    {
        R_UnlockVertexBuffer(mesh->vb.buffer);
        mesh->vb.verts = 0;
    }
#endif
}

void R_EndCodeMeshVerts()
{
    g_processCodeMesh = 0;
    R_EndMeshVerts(&frontEndDataOut->codeMesh);
}

void R_BeginCodeMeshVerts()
{
    iassert( !g_processCodeMesh );
    g_processCodeMesh = 1;
    R_BeginMeshVerts(&frontEndDataOut->codeMesh);
}

void R_EndMarkMeshVerts()
{
    g_processMarkMesh = 0;
    R_EndMeshVerts(&frontEndDataOut->markMesh);
}

char __cdecl R_ReserveMarkMeshIndices(int indexCount, r_double_index_t** indicesOut)
{
    iassert( g_processMarkMesh );
    if (R_ReserveMeshIndices(&frontEndDataOut->markMesh, indexCount, indicesOut))
        return 1;
    R_WarnOncePerFrame(R_WARN_MAX_MARK_INDS);
    return 0;
}

char __cdecl R_ReserveMarkMeshVerts(int vertCount, unsigned __int16 *baseVertex)
{
    iassert( g_processMarkMesh );
    if (R_ReserveMeshVerts(&frontEndDataOut->markMesh, vertCount, baseVertex))
        return 1;
    R_WarnOncePerFrame(R_WARN_MAX_MARK_VERTS);
    return 0;
}

void __cdecl R_BeginMarkMeshVerts()
{
    iassert( !g_processMarkMesh );
    g_processMarkMesh = 1;
    R_BeginMeshVerts(&frontEndDataOut->markMesh);
}

void __cdecl R_AddMarkMeshDrawSurf(
    Material *material,
    const GfxMarkContext *context,
    unsigned __int16 *indices,
    unsigned int indexCount)
{
    [[maybe_unused]] int packed_high; // edx
    [[maybe_unused]] unsigned __int64 v5; // rax
    [[maybe_unused]] int v6; // ecx
    [[maybe_unused]] unsigned __int64 v7; // rax
    [[maybe_unused]] int v8; // ecx
    [[maybe_unused]] unsigned int v9; // ecx
    [[maybe_unused]] GfxDrawSurf *drawSurf; // [esp+40h] [ebp-14h]
    [[maybe_unused]] int region; // [esp+48h] [ebp-Ch]
    [[maybe_unused]] unsigned int markMeshIndex; // [esp+4Ch] [ebp-8h]
    [[maybe_unused]] FxMarkMeshData *markMesh; // [esp+50h] [ebp-4h]

    iassert(g_processMarkMesh);
    material = R_GetSortedFxMaterial(material);
    if (!material)
        return;
    iassert(rgp.sortedMaterials[material->info.drawSurf.fields.materialSortedIndex] == material);
#ifdef KISAK_METAL
    // Marks are shaded natively as well, so their D3D9 lightmap-technique slot is
    // not a prerequisite for submitting the already generated decal mesh.
    const bool canDraw = material != nullptr;
#else
    const bool canDraw = Material_GetTechnique(
        material, (MaterialTechniqueType)gfxDrawMethod.litTechType[11][0]);
#endif
    if (canDraw)
    {
        markMeshIndex = InterlockedExchangeAdd(&frontEndDataOut->markMeshCount, static_cast<LONG>(1));
        if (markMeshIndex < 0x600)
        {
            markMesh = &frontEndDataOut->markMeshes[markMeshIndex];
            markMesh->triCount = indexCount / 3;
            markMesh->indices = indices;
            markMesh->modelIndex = context->modelIndex;
            markMesh->modelTypeAndSurf = context->modelTypeAndSurf;
            iassert(material->info.sortKey >= 24);
            region = (material->info.sortKey == 48) + (material->info.sortKey != 24 ? 0 : 2) + 6;
            drawSurf = R_AllocFxDrawSurf(region);
            if (drawSurf)
            {
                drawSurf->packed = material->info.drawSurf.packed;

                //drawSurf->packed = (unsigned __int64)material->info.drawSurf;

                drawSurf->fields.objectId = markMeshIndex;
                //packed_high = HIDWORD(drawSurf->packed);
                //LODWORD(drawSurf->packed) = (unsigned __int16)markMeshIndex | drawSurf->packed & 0xFFFF0000; // set objectId
                //HIDWORD(drawSurf->packed) = packed_high;

                drawSurf->fields.customIndex = context->lmapIndex;
                //v5 = (unsigned __int64)(context->lmapIndex & 0x1F) << 24; // customIndex
                //v6 = HIDWORD(v5) | HIDWORD(drawSurf->packed);
                //LODWORD(drawSurf->packed) = v5 | drawSurf->packed & 0xE0FFFFFF;
                //HIDWORD(drawSurf->packed) = v6;

                //HIDWORD(v5) = HIDWORD(drawSurf->packed) & 0xFFC3FFFF | 0x2C0000;
                //LODWORD(drawSurf->packed) = drawSurf->packed;
                //HIDWORD(drawSurf->packed) = HIDWORD(v5);

                //HIDWORD(drawSurf->packed) |= 0x2C0000; // this sets surfType to b(1011)
                drawSurf->fields.surfType = SF_MARK_MESH;

                drawSurf->fields.reflectionProbeIndex = context->reflectionProbeIndex;
                //v7 = (unsigned __int64)context->reflectionProbeIndex << 16; // reflectionProbeIndex
                //v8 = HIDWORD(v7) | HIDWORD(drawSurf->packed);
                //LODWORD(drawSurf->packed) = v7 | drawSurf->packed & 0xFF00FFFF;
                //HIDWORD(drawSurf->packed) = v8;

                drawSurf->fields.primaryLightIndex = context->primaryLightIndex;
                //v9 = (context->primaryLightIndex << 10) | HIDWORD(drawSurf->packed) & 0xFFFC03FF; // PrimaryLightIndex
                //LODWORD(drawSurf->packed) = drawSurf->packed;
                //HIDWORD(drawSurf->packed) = v9;

                iassert(drawSurf->fields.prepass == MTL_PREPASS_NONE);
                iassert(drawSurf->fields.reflectionProbeIndex == context->reflectionProbeIndex);
                iassert(((region == DRAW_SURF_FX_CAMERA_LIT) || (drawSurf == scene.drawSurfs[region]) || (drawSurf->fields.primarySortKey >= (drawSurf - 1)->fields.primarySortKey)));
            }
        }
        else
        {
            R_WarnOncePerFrame(R_WARN_GFX_MARK_MESH_LIMIT);
        }
    }
    else
    {
        R_WarnOncePerFrame(R_WARN_NONLIGHTMAP_MARK_MATERIAL);
    }
}

struct GfxSortDrawSurfsInterface // sizeof=0x0
{
};

void __cdecl ShortSort /*ShortSortArray<GfxReverseSortDrawSurfsInterface, GfxDrawSurf>*/(GfxDrawSurf *lo, GfxDrawSurf *hi)
{
    [[maybe_unused]] int packed_high; // eax
    [[maybe_unused]] unsigned __int64 packed; // [esp+0h] [ebp-24h]
    [[maybe_unused]] GfxDrawSurf *maxx; // [esp+8h] [ebp-1Ch] // (max is a fkin macro!)
    [[maybe_unused]] unsigned __int64 maxKey; // [esp+Ch] [ebp-18h]
    [[maybe_unused]] unsigned __int64 walkKey; // [esp+14h] [ebp-10h]
    [[maybe_unused]] GfxDrawSurf *walk; // [esp+20h] [ebp-4h]

    while (hi > lo)
    {
        maxx = lo;
        maxKey = lo->packed;
        for (walk = lo + 1; walk <= hi; ++walk)
        {
            walkKey = walk->packed;
            if (HIDWORD(maxKey) <= HIDWORD(walk->packed)
                && (HIDWORD(maxKey) < HIDWORD(walkKey) || (unsigned int)maxKey < (unsigned int)walkKey))
            {
                maxKey = walk->packed;
                maxx = walk;
            }
        }
        packed = maxx->packed;
        //packed_high = HIDWORD(hi->packed);
        //*(_DWORD *)&max->fields = hi->fields;
        LODWORD(maxx->packed) = LODWORD(hi->packed);
        HIDWORD(maxx->packed) = HIDWORD(hi->packed);
        hi->packed = packed;
        --hi;
    }
}

void __cdecl SortMyShit /*qsortArray<GfxReverseSortDrawSurfsInterface, GfxDrawSurf>*/(GfxDrawSurf *elems, int count)
{
    [[maybe_unused]] int packed_high; // edx
    [[maybe_unused]] GfxDrawSurf *v3; // eax
    [[maybe_unused]] unsigned int v4; // eax
    [[maybe_unused]] unsigned int v5; // ecx
    [[maybe_unused]] GfxDrawSurf *v6; // edx
    [[maybe_unused]] GfxDrawSurf v7; // [esp+4h] [ebp-180h]
    [[maybe_unused]] unsigned int fields; // [esp+Ch] [ebp-178h]
    [[maybe_unused]] unsigned int v9; // [esp+10h] [ebp-174h]
    [[maybe_unused]] GfxDrawSurf v10; // [esp+14h] [ebp-170h]
    [[maybe_unused]] GfxDrawSurf v11; // [esp+1Ch] [ebp-168h]
    [[maybe_unused]] GfxDrawSurf v12; // [esp+2Ch] [ebp-158h]
    [[maybe_unused]] unsigned __int64 pivotKey; // [esp+64h] [ebp-120h]
    [[maybe_unused]] GfxDrawSurf *loWalk; // [esp+74h] [ebp-110h]
    [[maybe_unused]] int sortCount; // [esp+78h] [ebp-10Ch]
    [[maybe_unused]] GfxDrawSurf *hiEnd; // [esp+7Ch] [ebp-108h]
    [[maybe_unused]] GfxDrawSurf *hiWalk; // [esp+80h] [ebp-104h]
    [[maybe_unused]] GfxDrawSurf *loStack[30]; // [esp+84h] [ebp-100h]
    [[maybe_unused]] GfxDrawSurf *hiStack[30]; // [esp+FCh] [ebp-88h]
    [[maybe_unused]] int stackPos; // [esp+178h] [ebp-Ch]
    [[maybe_unused]] GfxDrawSurf *loEnd; // [esp+17Ch] [ebp-8h]
    [[maybe_unused]] GfxDrawSurf *mid; // [esp+180h] [ebp-4h]

    if (count < 2)
    {
        return;
    }

    stackPos = 0;
    loEnd = elems;
    hiEnd = &elems[count - 1];
    while (1)
    {
        while (1)
        {
            sortCount = hiEnd - loEnd + 1;
            if (sortCount <= 8)
            {
                ShortSort(loEnd, hiEnd);
                goto LABEL_22;
            }
            mid = &loEnd[sortCount / 2];
            v10.fields = mid->fields;
            packed_high = HIDWORD(loEnd->packed);
            v3 = mid;
            //*(_DWORD *)&mid->fields = loEnd->fields;
            LODWORD(mid->packed) = LODWORD(loEnd->packed);
            HIDWORD(v3->packed) = packed_high;
            loEnd->fields = v10.fields;
            loWalk = loEnd;
            hiWalk = hiEnd + 1;
            pivotKey = loEnd->packed;
            while (1)
            {
                do
                    ++loWalk;
                while (loWalk <= hiEnd && loWalk->packed <= pivotKey);
                do
                    --hiWalk;
                while (loEnd < hiWalk && pivotKey <= hiWalk->packed);
                if (hiWalk < loWalk)
                    break;
                //fields = (int)loWalk->fields;
                fields = LODWORD(loWalk->packed);
                v9 = HIDWORD(loWalk->packed);
                v4 = HIDWORD(hiWalk->packed);
                //*(_DWORD *)&loWalk->fields = hiWalk->fields;
                LODWORD(loWalk->packed) = LODWORD(hiWalk->packed);
                HIDWORD(loWalk->packed) = v4;
                //*(_DWORD *)&hiWalk->fields = fields;
                LODWORD(hiWalk->packed) = fields;
                HIDWORD(hiWalk->packed) = v9;
            }
            v7.fields = loEnd->fields;
            v5 = HIDWORD(hiWalk->packed);
            v6 = loEnd;
            //*(_DWORD *)&loEnd->fields = hiWalk->fields;
            LODWORD(loEnd->packed) = LODWORD(hiWalk->packed);
            HIDWORD(v6->packed) = v5;
            hiWalk->fields = v7.fields;
            if (&hiWalk[-1] - loEnd >= hiEnd - loWalk)
                break;
            if (loWalk < hiEnd)
            {
                loStack[stackPos] = loWalk;
                hiStack[stackPos++] = hiEnd;
            }
            if (loEnd >= &hiWalk[-1])
            {
            LABEL_22:
                if (--stackPos < 0)
                    return;
                loEnd = loStack[stackPos];
                hiEnd = hiStack[stackPos];
            }
            else
            {
                hiEnd = hiWalk - 1;
            }
        }
        if (loEnd <= hiWalk)
        {
            loStack[stackPos] = loEnd;
            hiStack[stackPos++] = hiWalk - 1;
        }
        if (loWalk >= hiEnd)
            goto LABEL_22;
        loEnd = loWalk;
    }
}

void __cdecl R_SortDrawSurfs(GfxDrawSurf *drawSurfList, int surfCount)
{
    PROF_SCOPED("R_SortDrawSurfs");
    //qsortArray<GfxSortDrawSurfsInterface, GfxDrawSurf>(drawSurfList, surfCount);
    SortMyShit(drawSurfList, surfCount);
}

GfxWorldVertex *__cdecl R_GetMarkMeshVerts(unsigned __int16 baseVertex)
{
    iassert( g_processMarkMesh );
    return (GfxWorldVertex*)R_GetMeshVerts(&frontEndDataOut->markMesh, baseVertex);
}

GfxDrawSurf __cdecl R_GetWorldDrawSurf(GfxSurface *worldSurf)
{
    GfxDrawSurf drawSurf = worldSurf->material->info.drawSurf;
    iassert( drawSurf.fields.primaryLightIndex == 0 );
    drawSurf.fields.primaryLightIndex = worldSurf->primaryLightIndex;
    iassert(drawSurf.fields.primaryLightIndex == worldSurf->primaryLightIndex);

    return drawSurf;
}

GfxWorld *R_SetPrimaryLightShadowSurfaces()
{
    [[maybe_unused]] GfxWorld *result; // eax
    [[maybe_unused]] unsigned int surfIndex; // [esp+8h] [ebp-14h]
    [[maybe_unused]] unsigned int primaryLightIndex; // [esp+18h] [ebp-4h]

    for (primaryLightIndex = 0; primaryLightIndex < rgp.world->primaryLightCount; ++primaryLightIndex)
        rgp.world->shadowGeom[primaryLightIndex].surfaceCount = 0;
    for (surfIndex = 0; ; ++surfIndex)
    {
        result = rgp.world;
        if (surfIndex >= rgp.world->models->surfaceCount)
            break;
        if (rgp.world->dpvs.surfaceMaterials[surfIndex].fields.customIndex != 0)
            R_ForEachPrimaryLightAffectingSurface(
                rgp.world,
                &rgp.world->dpvs.surfaces[surfIndex],
                surfIndex,
                R_AddShadowSurfaceToPrimaryLight);
    }
    return result;
}

void __cdecl R_SortWorldSurfaces()
{
    [[maybe_unused]] GfxDrawSurf v0; // [esp+Ch] [ebp-20h]
    [[maybe_unused]] unsigned int surfIndex; // [esp+18h] [ebp-14h]
    [[maybe_unused]] unsigned int worldSurfCount; // [esp+24h] [ebp-8h]
    [[maybe_unused]] GfxSurface *worldSurfArray; // [esp+28h] [ebp-4h]

    iassert( rgp.world );
    if (rgp.world->models->startSurfIndex)
        MyAssertHandler(
            ".\\r_drawsurf.cpp",
            337,
            0,
            "%s\n\t(rgp.world->models[0].startSurfIndex) = %i",
            "(rgp.world->models[0].startSurfIndex == 0)",
            rgp.world->models->startSurfIndex);
    worldSurfArray = rgp.world->dpvs.surfaces;
    worldSurfCount = rgp.world->models->surfaceCount;
    if (rgp.world->models->surfaceCount)
        memset(rgp.world->dpvs.surfaceCastsSunShadow, 0, 4 * ((worldSurfCount - 1) >> 5) + 4);
    iassert( worldSurfArray == rgp.world->dpvs.surfaces );
    iassert( worldSurfCount == rgp.world->models[0].surfaceCount );
    for (surfIndex = 0; surfIndex < worldSurfCount; ++surfIndex)
    {
        v0 = R_GetWorldDrawSurf(&worldSurfArray[surfIndex]);
        rgp.world->dpvs.surfaceMaterials[surfIndex] = v0;
        if (v0.fields.customIndex != 0 && (worldSurfArray[surfIndex].flags & 1) != 0)
            rgp.world->dpvs.surfaceCastsSunShadow[surfIndex >> 5] |= 1 << (surfIndex & 0x1F);
    }
    R_SetPrimaryLightShadowSurfaces();
}

char __cdecl R_AddParticleCloudDrawSurf(unsigned int cloudIndex, Material *material)
{
    [[maybe_unused]] int packed_high; // ecx
    [[maybe_unused]] unsigned int v4; // edx
    [[maybe_unused]] int MaterialSortKey; // [esp+20h] [ebp-18h]
    [[maybe_unused]] GfxDrawSurf *drawSurf; // [esp+2Ch] [ebp-Ch]
    [[maybe_unused]] int region; // [esp+30h] [ebp-8h]

    if (cloudIndex >= static_cast<unsigned int>(frontEndDataOut->cloudCount))
        MyAssertHandler(
            ".\\r_drawsurf.cpp",
            561,
            0,
            "cloudIndex doesn't index frontEndDataOut->cloudCount\n\t%i not in [0, %i)",
            cloudIndex,
            frontEndDataOut->cloudCount);

    material = R_GetSortedFxMaterial(material);
    if (!material)
        return 0;
    iassert(rgp.sortedMaterials[material->info.drawSurf.fields.materialSortedIndex] == material);

#ifdef KISAK_METAL
    const bool canDraw = material != nullptr;
#else
    const bool canDraw = Material_GetTechnique(material, gfxDrawMethod.emissiveTechType);
#endif
    if (canDraw)
    {
        MaterialSortKey = R_GetMaterialSortKey(material);
        region = (MaterialSortKey == 48) + (MaterialSortKey != 24 ? 0 : 2) + 12;
        drawSurf = R_AllocFxDrawSurf(region);
        if (drawSurf)
        {
            drawSurf->packed = R_GetMaterialInfoPacked(material).packed;

            drawSurf->fields.objectId = cloudIndex;
            drawSurf->fields.surfType = SF_PARTICLE_CLOUD;
            //packed_high = HIDWORD(drawSurf->packed);
            //*&drawSurf->packed = cloudIndex | *&drawSurf->packed & 0xFFFF0000; // objectID
            //HIDWORD(drawSurf->packed) = packed_high;
            //v4 = HIDWORD(drawSurf->packed) & 0xFFC3FFFF | 0x300000; // surfType = 12
            //*&drawSurf->fields = drawSurf->fields;
            //HIDWORD(drawSurf->packed) = v4;
            //*&drawSurf->fields = drawSurf->fields;
            //HIDWORD(drawSurf->packed) = HIDWORD(drawSurf->packed);

            iassert(drawSurf->fields.prepass == MTL_PREPASS_NONE);
            iassert(((region == DRAW_SURF_FX_CAMERA_EMISSIVE) || (drawSurf == scene.drawSurfs[region]) || (drawSurf->fields.primarySortKey >= (drawSurf - 1)->fields.primarySortKey)));

            return 1;
        }
        else
        {
            return 0;
        }
    }
    else
    {
        R_WarnOncePerFrame(R_WARN_NONEMISSIVE_FX_MATERIAL, material->info.name);
        return 0;
    }
}
