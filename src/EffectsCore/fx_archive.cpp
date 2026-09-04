#include "fx_system.h"

#include <database/database.h>

#include <physics/phys_local.h>

#include <cstddef>
#include <cstdint>
#include <limits>

namespace
{
constexpr int kFxSystemArchiveSize = static_cast<int>(sizeof(FxSystem));
constexpr int kFxSystemBuffersArchiveSize = static_cast<int>(sizeof(FxSystemBuffers));

static_assert(sizeof(FxSystem) <= static_cast<size_t>(std::numeric_limits<int>::max()));
static_assert(sizeof(FxSystemBuffers) <= static_cast<size_t>(std::numeric_limits<int>::max()));
static_assert(offsetof(FxSystem, needsGarbageCollection) < sizeof(FxSystem));
static_assert(offsetof(FxSystem, isArchiving) < sizeof(FxSystem));

struct FxArchivePointerBases
{
    uintptr_t system;
    uintptr_t systemBuffers;
};

uint32_t FX_ArchivePointerKey(uintptr_t address)
{
#if UINTPTR_MAX > UINT32_MAX
    address ^= address >> 32;
#endif
    return static_cast<uint32_t>(address);
}

uintptr_t FX_RelocateArchivedAddress(uintptr_t address, uintptr_t archivedBase, uintptr_t currentBase)
{
    if (!address || archivedBase == currentBase)
        return address;

    if (currentBase > archivedBase)
    {
        const uintptr_t relocationDistance = currentBase - archivedBase;
        if (address > std::numeric_limits<uintptr_t>::max() - relocationDistance)
        {
            Com_Error(ERR_DROP, "Invalid FX archive pointer relocation");
            return 0;
        }
        return address + relocationDistance;
    }

    const uintptr_t relocationDistance = archivedBase - currentBase;
    if (address < relocationDistance)
    {
        Com_Error(ERR_DROP, "Invalid FX archive pointer relocation");
        return 0;
    }
    return address - relocationDistance;
}

void FX_RelocateArchivedSystem(
    FxSystem *system,
    uintptr_t archivedSystemBuffers,
    const FxSystemBuffers *currentSystemBuffers)
{
    const uintptr_t currentSystemBuffersAddress = reinterpret_cast<uintptr_t>(currentSystemBuffers);

    system->visStateBufferRead = reinterpret_cast<const FxVisState *>(FX_RelocateArchivedAddress(
        reinterpret_cast<uintptr_t>(system->visStateBufferRead), archivedSystemBuffers, currentSystemBuffersAddress));
    system->visStateBufferWrite = reinterpret_cast<FxVisState *>(FX_RelocateArchivedAddress(
        reinterpret_cast<uintptr_t>(system->visStateBufferWrite), archivedSystemBuffers, currentSystemBuffersAddress));
}
}

void __cdecl FX_Restore(int32_t clientIndex, MemoryFile *memFile)
{
    FxEffectDefTable table; // [esp+4h] [ebp-2018h] BYREF
    FxSystem *system;
    FxSystemBuffers *systemBuffers; // [esp+2018h] [ebp-4h]
    FxArchivePointerBases archivedBases;

    system = FX_GetSystem(clientIndex);
    if (!system)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 220, 0, "%s", "system");
    systemBuffers = FX_GetSystemBuffers(clientIndex);
    if (!systemBuffers)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 223, 0, "%s", "systemBuffers");
    FX_RestoreEffectDefTable(memFile, &table);
    MemFile_ReadData(memFile, kFxSystemArchiveSize, reinterpret_cast<uint8_t *>(system));
    if (!*reinterpret_cast<const bool *>(reinterpret_cast<const uint8_t *>(system) + offsetof(FxSystem, isArchiving))
        || *reinterpret_cast<const bool *>(reinterpret_cast<const uint8_t *>(system) + offsetof(FxSystem, needsGarbageCollection)))
        Com_Error(ERR_DROP, "Invalid save file");
    FX_LinkSystemBuffers(system, systemBuffers);
    MemFile_ReadData(memFile, kFxSystemBuffersArchiveSize, reinterpret_cast<uint8_t *>(systemBuffers));
    FX_FixupEffectDefHandles(system, &table);
    MemFile_ReadData(memFile, static_cast<int>(sizeof(archivedBases)), reinterpret_cast<uint8_t *>(&archivedBases));
    if (!archivedBases.system || !archivedBases.systemBuffers)
        Com_Error(ERR_DROP, "Invalid FX archive pointer bases");
    FX_RelocateArchivedSystem(system, archivedBases.systemBuffers, systemBuffers);
    FX_RestorePhysicsData(system, memFile);
    *reinterpret_cast<bool *>(reinterpret_cast<uint8_t *>(system) + offsetof(FxSystem, isArchiving)) = false;
}

void __cdecl FX_RestoreEffectDefTable(MemoryFile *memFile, FxEffectDefTable *table)
{
    uintptr_t archivedEffectDef;
    const FxEffectDef *effectDef; // [esp+4h] [ebp-Ch]
    uint32_t key; // [esp+8h] [ebp-8h]
    const char *effectDefName;

    table->count = 0;
    while (1)
    {
        effectDefName = MemFile_ReadCString(memFile);
        if (!*effectDefName)
            break;
        MemFile_ReadData(
            memFile, static_cast<int>(sizeof(archivedEffectDef)), reinterpret_cast<uint8_t *>(&archivedEffectDef));
        key = FX_ArchivePointerKey(archivedEffectDef);
        effectDef = FX_Register(effectDefName);
        FX_AddEffectDefTableEntry(table, key, effectDef);
    }
}

void __cdecl FX_AddEffectDefTableEntry(FxEffectDefTable *table, uint32_t key, const FxEffectDef *effectDef)
{
    if (!table)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 47, 0, "%s", "table");
    if (static_cast<unsigned int>(table->count) >= 0x400u)
        MyAssertHandler(
            ".\\EffectsCore\\fx_archive.cpp",
            48,
            0,
            "table->count doesn't index ARRAY_COUNT( table->entries )\n\t%i not in [0, %i)",
            table->count,
            1024);
    if (!effectDef)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 49, 0, "%s", "effectDef");
    for (int32_t index = 0; index < table->count; ++index)
    {
        if (table->entries[index].key != key)
            continue;
        if (table->entries[index].effectDef != effectDef)
            Com_Error(ERR_DROP, "FX archive effect pointer key collision");
        return;
    }
    table->entries[table->count].key = key;
    table->entries[table->count++].effectDef = effectDef;
}

void __cdecl FX_FixupEffectDefHandles(FxSystem *system, FxEffectDefTable *table)
{
    const FxEffectDef *effectDef; // [esp+Ch] [ebp-10h]
    FxEffect *effect; // [esp+10h] [ebp-Ch]
    int32_t activeIndex; // [esp+18h] [ebp-4h]

    if (!system)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 131, 0, "%s", "system");
    if (!system->isArchiving)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 132, 0, "%s", "system->isArchiving");
    for (activeIndex = system->firstActiveEffect; activeIndex != system->firstNewEffect; ++activeIndex)
    {
        effect = FX_EffectFromHandle(system, system->allEffectHandles[activeIndex & 0x3FF]);
        effectDef = FX_FindEffectDefInTable(table, FX_ArchivePointerKey(reinterpret_cast<uintptr_t>(effect->def)));
        if (!effectDef)
            MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 139, 0, "%s", "effectDef");
        effect->def = effectDef;
    }
}

FxEffect *__cdecl FX_EffectFromHandle(FxSystem *system, uint16_t handle)
{
    // The decompile inlined the x86 numbers: 0x20 for one effect's worth of handle
    // units and 0x8000 for the whole pool. FxEffect holds a pointer, so at LP64 it is
    // 0x88 rather than 0x80 and the stride is 34 - which FX_EffectToHandle already
    // produces, since it divides by the real element size.
    constexpr size_t handlesPerEffect = sizeof(FxEffect) / FxEffect::HANDLE_SCALE;
    const char *v2; // eax

    if (!system)
        MyAssertHandler("c:\\trees\\cod3\\src\\effectscore\\fx_system.h", 256, 0, "%s", "system");
    if (handle >= FX_EFFECT_LIMIT * handlesPerEffect || handle % handlesPerEffect)
    {
        v2 = va("%p %i", system->effects, handle);
        MyAssertHandler(
            "c:\\trees\\cod3\\src\\effectscore\\fx_system.h",
            257,
            0,
            "%s\n\t%s",
            "handle < FX_EFFECT_LIMIT * sizeof( FxEffect ) / FxEffect::HANDLE_SCALE && handle % (sizeof( FxEffect ) / FxEffect:"
            ":HANDLE_SCALE) == 0",
            v2);
    }
    return (FxEffect *)((char *)system->effects + FxEffect::HANDLE_SCALE * handle);
}

const FxEffectDef *__cdecl FX_FindEffectDefInTable(const FxEffectDefTable *table, uint32_t key)
{
    int32_t index; // [esp+0h] [ebp-4h]

    for (index = 0; index < table->count; ++index)
    {
        if (table->entries[index].key == key)
            return table->entries[index].effectDef;
    }
    return 0;
}

void __cdecl FX_RestorePhysicsData(FxSystem *system, MemoryFile *memFile)
{
    const XModel *visuals; // [esp+18h] [ebp-20h]
    uint16_t elemHandle; // [esp+1Ch] [ebp-1Ch]
    const FxElemDef *elemDef; // [esp+20h] [ebp-18h]
    const FxEffect *effect; // [esp+24h] [ebp-14h]
    uint16_t elemHandleNext; // [esp+2Ch] [ebp-Ch]
    FxPool<FxElem> *elem; // [esp+30h] [ebp-8h]
    int32_t activeIndex; // [esp+34h] [ebp-4h]

    if (!system)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 185, 0, "%s", "system");
    if (!system->isArchiving)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 186, 0, "%s", "system->isArchiving");
    for (activeIndex = system->firstActiveEffect; activeIndex != system->firstNewEffect; ++activeIndex)
    {
        effect = FX_EffectFromHandle(system, system->allEffectHandles[activeIndex & 0x3FF]);
        for (elemHandle = effect->firstElemHandle[1]; elemHandle != 0xFFFF; elemHandle = elemHandleNext)
        {
            if (!system)
                MyAssertHandler("c:\\trees\\cod3\\src\\effectscore\\fx_system.h", 334, 0, "%s", "system");
            elem = FX_PoolFromHandle_Generic<FxElem, 2048>(system->elems, elemHandle);
            elemDef = &effect->def->elemDefs[elem->item.defIndex];
            elemHandleNext = elem->item.nextElemHandleInEffect;
            if (elemDef->elemType == 5 && (elemDef->flags & 0x8000000) != 0)
            {
                elem->item.physObjId = Phys_ObjToId(Phys_ObjLoad(PHYS_WORLD_FX, memFile));
                visuals = FX_GetElemVisuals(
                    elemDef,
                    (296 * elem->item.sequence + elem->item.msecBegin + effect->randomSeed) % 0x1DF).model;
                Phys_ObjSetCollisionFromXModel(visuals, PHYS_WORLD_FX, Phys_ObjFromId(elem->item.physObjId));
            }
        }
    }
}

FxElemVisuals __cdecl FX_GetElemVisuals(const FxElemDef *elemDef, int32_t randomSeed)
{
    if (!elemDef->visualCount)
        MyAssertHandler(
            "c:\\trees\\cod3\\src\\effectscore\\fx_draw.h",
            79,
            0,
            "%s\n\t(elemDef->visualCount) = %i",
            "(elemDef->visualCount > 0)",
            elemDef->visualCount);
    if (elemDef->visualCount == 1)
        return elemDef->visuals.instance;
    else
        return (FxElemVisuals)elemDef->visuals.markArray->materials[(elemDef->visualCount
            * LOWORD(fx_randomTable[randomSeed + 21])) >> 16];
}

void __cdecl FX_Save(int32_t clientIndex, MemoryFile *memFile)
{
    [[maybe_unused]] uint32_t UsedSize; // eax
    [[maybe_unused]] uint32_t v3; // eax
    FxSystem *system; // [esp+4h] [ebp-8h]
    FxSystemBuffers *systemBuffers; // [esp+8h] [ebp-4h]
    FxArchivePointerBases archivedBases;

    system = FX_GetSystem(clientIndex);
    if (!system)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 265, 0, "%s", "system");
    systemBuffers = FX_GetSystemBuffers(clientIndex);
    if (!systemBuffers)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 267, 0, "%s", "systemBuffers");
    if (system->isArchiving)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 270, 0, "%s", "!system->isArchiving");
    system->isArchiving = 1;
    FX_SaveEffectDefTable(system, memFile);
    MemFile_WriteData(memFile, kFxSystemArchiveSize, system);
    UsedSize = MemFile_GetUsedSize(memFile);
    // ProfMem_Begin("systemBuffers", UsedSize);
    MemFile_WriteData(memFile, kFxSystemBuffersArchiveSize, systemBuffers);
    v3 = MemFile_GetUsedSize(memFile);
    // ProfMem_End(v3);
    archivedBases.system = reinterpret_cast<uintptr_t>(system);
    archivedBases.systemBuffers = reinterpret_cast<uintptr_t>(systemBuffers);
    MemFile_WriteData(memFile, static_cast<int>(sizeof(archivedBases)), &archivedBases);
    FX_SavePhysicsData(system, memFile);
    system->isArchiving = 0;
}

void __cdecl FX_SaveEffectDefTable(FxSystem *system, MemoryFile *memFile)
{
    if (IsFastFileLoad())
        FX_SaveEffectDefTable_FastFile(memFile);
    else
        FX_SaveEffectDefTable_LoadObj(memFile);
    MemFile_WriteCString(memFile, "");
}

void __cdecl FX_SaveEffectDefTableEntry_FileLoadObj(const FxEffectDef* effectDef, MemoryFile* data)
{
    const uintptr_t archivedEffectDef = reinterpret_cast<uintptr_t>(effectDef);

    MemFile_WriteCString(data, (char*)effectDef->name);
    MemFile_WriteData(data, static_cast<int>(sizeof(archivedEffectDef)), &archivedEffectDef);
}

void __cdecl FX_SaveEffectDefTable_LoadObj(MemoryFile* memFile)
{
    FX_ForEachEffectDef((void(__cdecl*)(const FxEffectDef*, void*))FX_SaveEffectDefTableEntry_FileLoadObj, memFile);
}

void __cdecl FX_SaveEffectDefTable_FastFile(MemoryFile *memFile)
{
    DB_EnumXAssets(
        ASSET_TYPE_FX,
        (void(__cdecl *)(XAssetHeader, void *))FX_SaveEffectDefTableEntry_FileLoadObj,
        memFile,
        0);
}

void __cdecl FX_SavePhysicsData(FxSystem *system, MemoryFile *memFile)
{
    uint16_t elemHandle; // [esp+Ch] [ebp-18h]
    const FxElemDef *elemDef; // [esp+10h] [ebp-14h]
    const FxEffect *effect; // [esp+14h] [ebp-10h]
    uint16_t elemHandleNext; // [esp+18h] [ebp-Ch]
    FxPool<FxElem> *elem; // [esp+1Ch] [ebp-8h]
    int32_t activeIndex; // [esp+20h] [ebp-4h]

    if (!system)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 155, 0, "%s", "system");
    if (!system->isArchiving)
        MyAssertHandler(".\\EffectsCore\\fx_archive.cpp", 156, 0, "%s", "system->isArchiving");
    for (activeIndex = system->firstActiveEffect; activeIndex != system->firstNewEffect; ++activeIndex)
    {
        effect = FX_EffectFromHandle(system, system->allEffectHandles[activeIndex & 0x3FF]);
        for (elemHandle = effect->firstElemHandle[1]; elemHandle != 0xFFFF; elemHandle = elemHandleNext)
        {
            if (!system)
                MyAssertHandler("c:\\trees\\cod3\\src\\effectscore\\fx_system.h", 334, 0, "%s", "system");
            elem = FX_PoolFromHandle_Generic<FxElem, 2048>(system->elems, elemHandle);
            elemDef = &effect->def->elemDefs[elem->item.defIndex];
            elemHandleNext = elem->item.nextElemHandleInEffect;
            if (elemDef->elemType == 5 && (elemDef->flags & 0x8000000) != 0)
                Phys_ObjSave(Phys_ObjFromId(elem->item.physObjId), memFile);
        }
    }
}

void __cdecl FX_Archive(int32_t clientIndex, MemoryFile *memFile)
{
    if (MemFile_IsWriting(memFile))
        FX_Save(clientIndex, memFile);
    else
        FX_Restore(clientIndex, memFile);
}
