// Load a retail CoD4 zone through OpenAssetTools rather than the engine's own
// fastfile reader.
//
// A .ff stores 4-byte pointers and x86 struct layouts. db_load.cpp walks it with
// 171 literal x86 sizes, and db_stream_load.cpp:56 says outright that it needs the
// zone blocks to live in the low 4 GB - which is impossible on macOS arm64, where
// __PAGEZERO is 4 GB and every MAP_FIXED below it fails. So that reader cannot be
// made to work here at any price.
//
// OpenAssetTools already solves this: its ZoneInputStream is pointer-width
// agnostic, and the structs it produces are the ones declared in this tree.
// mac/tools/structdiff.py shows 23 of 25 asset types agree field for field, and
// the two XAssetType enums are byte for byte identical, so nothing is translated
// here - the loaded pointers go straight into the asset pools.

#include "oatbridge/oatbridge.h"

#include "database/database.h"
#include "game/g_bsp.h"
#include "gfx_d3d/r_gfx.h"
#include "gfx_d3d/r_image.h"
#include "gfx_d3d/r_material.h"
#include "ui/ui_shared.h"
#include "qcommon/qcommon.h"
#include "qcommon/com_bsp.h"

extern void *DB_XAssetPool[];

#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace
{
    std::atomic<double> g_oatLoadFraction{0.0};
    double g_lastLoadScreenUpdate = -1.0;

    void SetOatLoadFraction(double fraction, bool redraw)
    {
        fraction = std::clamp(fraction, 0.0, 1.0);
        g_oatLoadFraction.store(fraction, std::memory_order_relaxed);

        // OAT is synchronous in this port, so the normal game loop cannot repaint
        // while a fastfile is decoded.  One redraw per percentage point keeps the
        // loading bar responsive without turning rendering into the bottleneck.
        if (redraw && (g_lastLoadScreenUpdate < 0.0 || fraction - g_lastLoadScreenUpdate >= 0.01 || fraction == 1.0))
        {
            g_lastLoadScreenUpdate = fraction;
            SCR_UpdateLoadScreen();
        }
    }

    void OatLoadProgress(size_t current, size_t total, void *)
    {
        const double decoded = total ? static_cast<double>(current) / static_cast<double>(total) : 0.0;
        // Decoding owns most of the work; registration and reference repair make
        // up the final fifth and are measured separately below.
        SetOatLoadFraction(decoded * 0.8, true);
    }

    struct ZoneDeleter
    {
        void operator()(OatZone *zone) const
        {
            OAT_FreeZone(zone);
        }
    };

    // The engine holds raw pointers into zone memory for as long as the zone is
    // loaded, so every zone stays alive here until the process exits.
    struct LoadedZone
    {
        std::string name;
        std::unique_ptr<OatZone, ZoneDeleter> zone;
        // Zone storage has to remain alive after an engine unload because other
        // long-lived engine objects retain pointers into it.  Registration is a
        // separate lifetime: DB_UnloadXZone removes the hash entries, and a later
        // load of the same map must put those exact payload pointers back.
        bool registered;
    };

    std::vector<LoadedZone> g_oatZones;

    struct PendingReference
    {
        int type;
        std::string name;
        void *stub;
    };

    std::vector<PendingReference> g_pendingReferences;

    void QueuePendingReference(int type, const char *name, void *stub)
    {
        if (!name || !*name || !stub)
            return;
        for (const PendingReference &pending : g_pendingReferences)
        {
            if (pending.type == type && pending.stub == stub && pending.name == name)
                return;
        }
        g_pendingReferences.push_back({type, name, stub});
    }

    // WeaponDef does not store normal XAsset sound references in a fastfile. Each
    // slot initially points at a one-pointer snd_alias_list_name wrapper instead,
    // and Load_SndAliasCustom replaces that wrapper with the sound asset returned
    // by DB_FindXAssetHeader. OAT deliberately leaves the wrapper intact because it
    // has no cross-zone asset database. On LP64 the wrapper looks enough like the
    // start of snd_alias_list_t for aliasName to work, but head and count then read
    // unrelated memory; weapon reports were consequently rejected as empty lists.
    struct PendingWeaponSound
    {
        snd_alias_list_t **slot;
        std::string name;
    };

    std::vector<PendingWeaponSound> g_pendingWeaponSounds;

    // Which zone owns each registered asset, and which zones another zone has borrowed
    // from. Resolution copies the real asset over the stub, so the copy's internal
    // pointers still live in the owner's memory - the owner has to outlive the
    // borrower. Startup zones end up pinned (everything borrows from them, and they
    // are permanent anyway); a map zone is borrowed from by nobody, so it can go.
    std::unordered_map<const void *, std::string> g_assetOwner;
    std::unordered_set<std::string> g_pinnedZones;

    // A few assets are not zone-owned data at all: the engine keeps them in its own
    // globals, and the stock fastfile reader streams them straight into those. Its
    // loaders then assert on that identity rather than on the contents -
    // CM_LoadMapData_FastFile wants DB_FindXAssetHeader(CLIPMAP_PVS) to return &cm
    // (cm_load.cpp:133), and Com_LoadWorld_FastFile wants COMWORLD to return
    // &comWorld (com_bsp_load_obj.cpp:640).
    //
    // OAT loads into its own memory, so copy the payload into the global and hand the
    // database the global's address. The pointers inside the copy still refer to zone
    // memory, which is why a map zone is never freed.
    //
    // GfxWorld, GameWorldMp and MapEnts have no such requirement: the engine keeps
    // whatever pointer the database returns (r_bsp.cpp:224), so they stay zone-owned.
    void *AdoptCodeAsset(int type, void *data)
    {
        switch (type)
        {
        case ASSET_TYPE_CLIPMAP:
        case ASSET_TYPE_CLIPMAP_PVS:
            std::memcpy(&cm, data, sizeof(cm));
            return &cm;
        case ASSET_TYPE_COMWORLD:
            std::memcpy(&comWorld, data, sizeof(comWorld));
            return &comWorld;
        default:
            return data;
        }
    }

    // FxEffectDefRef is a union of a name and a resolved FxEffectDef*. The fastfile
    // carries the name, and the engine's own reader swaps in the handle as it streams
    // the elem in (Load_FxEffectDefRef, db_load.cpp). OAT has no asset database to
    // resolve against, so it leaves the name - and the first thing to walk the effect
    // graph, FX_EffectAffectsGameplay, reads that char* as an FxEffectDef and faults.
    //
    // The refs are only meaningful once, so each effect is converted a single time:
    // reading a name out of a slot that already holds a handle would be worse than
    // leaving it alone.
    constexpr uint8_t kFxElemTypeRunner = 10;

    std::unordered_set<const void *> g_fxResolved;
    std::vector<FxEffectDef *> g_fxAwaitingResolve;

    void ResolveFxEffectRef(FxEffectDefRef *ref)
    {
        if (!ref->name)
            return;
        // Prefer the entry lookup: DB_FindXAssetHeader loads on a miss, which for a
        // name whose zone is not in yet means an error and the default effect.
        const XAssetEntryPoolEntry *const entry = DB_FindXAssetEntry(ASSET_TYPE_FX, ref->name);
        if (entry)
        {
            ref->handle = entry->entry.asset.header.fx;
            return;
        }
        Com_PrintWarning(10, "WARNING: [oat] fx '%s' is not loaded, using the default effect\n", ref->name);
        ref->handle = DB_FindXAssetHeader(ASSET_TYPE_FX, ref->name).fx;
    }

    void ResolveFxEffectRefs(FxEffectDef *effect)
    {
        if (!effect || !g_fxResolved.insert(effect).second)
            return;
        const int elemCount =
            effect->elemDefCountEmission + effect->elemDefCountOneShot + effect->elemDefCountLooping;
        for (int i = 0; i < elemCount; ++i)
        {
            FxElemDef *const elem = const_cast<FxElemDef *>(&effect->elemDefs[i]);
            ResolveFxEffectRef(&elem->effectOnImpact);
            ResolveFxEffectRef(&elem->effectOnDeath);
            ResolveFxEffectRef(&elem->effectEmitted);
            if (elem->elemType != kFxElemTypeRunner)
                continue;
            if (elem->visualCount == 1)
            {
                ResolveFxEffectRef(&elem->visuals.instance.effectDef);
                continue;
            }
            for (uint8_t vis = 0; vis < elem->visualCount; ++vis)
                ResolveFxEffectRef(&elem->visuals.array[vis].effectDef);
        }
    }

    void TracePhysicsFxAsset(const char *assetName, const FxEffectDef *effect)
    {
        if (!std::getenv("KISAK_FX_PHYS_CATALOG") || !effect)
            return;

        constexpr uint8_t kFxElemTypeModel = 5;
        constexpr uint32_t kFxElemUsesPhysics = 0x08000000u;
        const int elemCount = effect->elemDefCountLooping + effect->elemDefCountOneShot
                            + effect->elemDefCountEmission;
        for (int elemIndex = 0; elemIndex < elemCount; ++elemIndex)
        {
            const FxElemDef &elem = effect->elemDefs[elemIndex];
            if (elem.elemType != kFxElemTypeModel || !(elem.flags & kFxElemUsesPhysics))
                continue;

            const XModel *model = nullptr;
            if (elem.visualCount == 1)
                model = elem.visuals.instance.model;
            else if (elem.visualCount > 1 && elem.visuals.array)
                model = elem.visuals.array[0].model;
            Com_Printf(8,
                "[fx-physics-catalog] effect='%s' elem=%d classes=(%d,%d,%d) "
                "spawn=(%d,%d) delay=(%d,%d) life=(%d,%d) range=(%.1f,%.1f) "
                "visuals=%u flags=%08x model='%s' preset='%s'\n",
                assetName ? assetName : (effect->name ? effect->name : "(unnamed)"),
                elemIndex, effect->elemDefCountLooping, effect->elemDefCountOneShot,
                effect->elemDefCountEmission, elem.spawn.oneShot.count.base,
                elem.spawn.oneShot.count.amplitude, elem.spawnDelayMsec.base,
                elem.spawnDelayMsec.amplitude, elem.lifeSpanMsec.base,
                elem.lifeSpanMsec.amplitude, elem.spawnRange.base,
                elem.spawnRange.amplitude, static_cast<unsigned int>(elem.visualCount), elem.flags,
                model && model->name ? model->name : "(null)",
                model && model->physPreset && model->physPreset->name
                    ? model->physPreset->name : "(null)");
        }
    }

#ifdef KISAK_DXVK
    // A zone carries shaders and vertex declarations as data; turning them into
    // device objects is the loader's job, and db_load.cpp does it inline as it
    // streams (Load_CreateMaterialPixelShader, Load_BuildVertexDecl). OAT does not
    // run those, so a technique set arrives with null prog.ps/prog.vs and an empty
    // routing table, and the first draw that reaches it dies in R_UpdateVertexDecl
    // with "vertex type 0 doesn't have the information used by shader ...".
    //
    // IW3 has no separate asset type for any of these - they hang off the technique
    // set - so the walk starts there.
    std::unordered_set<const void *> g_gpuResourcesBuilt;

    void BuildPassGpuResources(MaterialPass *pass)
    {
        if (pass->vertexDecl && !pass->vertexDecl->isLoaded)
            Load_BuildVertexDecl(&pass->vertexDecl);
        if (pass->vertexShader && !pass->vertexShader->prog.vs)
            Load_CreateMaterialVertexShader(&pass->vertexShader->prog.loadDef, pass->vertexShader);
        if (pass->pixelShader && !pass->pixelShader->prog.ps)
            Load_CreateMaterialPixelShader(&pass->pixelShader->prog.loadDef, pass->pixelShader);
    }

    // GfxTexture is a union of the zone's pixel data and a device texture; Load_Texture
    // is what swaps one for the other, and db_load.cpp calls it as the image streams in.
    // Without it the loadDef pointer stays put and gets bound as if it were a texture,
    // which DXVK follows into D3D9DeviceEx::FlushImage and faults on.
    void BuildImageGpuResources(GfxImage *image)
    {
        if (!image || !image->texture.loadDef || !g_gpuResourcesBuilt.insert(image).second)
            return;

        const GfxImageLoadDef *const loadDef = image->texture.loadDef;

        // An image with no pixels in the zone is streamed from its .iwi later, and the
        // loader is expected to have reserved its share of the memory budget by now.
        // OAT leaves cardMemory at zero, which Load_Texture asserts on.
        if (!loadDef->resourceSize)
        {
            const unsigned int amount = Image_GetCardMemoryAmount(
                loadDef->flags, loadDef->format,
                loadDef->dimensions[0], loadDef->dimensions[1], loadDef->dimensions[2]);
            image->cardMemory.platform[0] = amount;
            image->cardMemory.platform[1] = amount;
        }

        // Load_Texture reads the loadDef through its first argument and overwrites the
        // union in place, so the pointer has to be kept somewhere it will survive.
        GfxTexture loadDefHolder = image->texture;
        Load_Texture(&loadDefHolder, image);
    }

    void BuildTechniqueSetGpuResources(MaterialTechniqueSet *techset)
    {
        if (!techset || !g_gpuResourcesBuilt.insert(techset).second)
            return;
        for (MaterialTechnique *const technique : techset->techniques)
        {
            if (!technique)
                continue;
            // Techniques are shared between sets, so the same one can arrive twice.
            if (!g_gpuResourcesBuilt.insert(technique).second)
                continue;
            for (uint16_t i = 0; i < technique->passCount; ++i)
                BuildPassGpuResources(&technique->passArray[i]);
        }
    }
#endif // KISAK_DXVK

    // A scr_string_t inside an asset indexes the zone's own string table, not the
    // runtime interner. The engine's reader translates each one as it streams
    // (Load_ScriptStringCustom), so by the time an asset is registered the ids are
    // global; OAT has no interner to translate against and leaves the zone-local
    // index in place. Nothing downstream can tell the two apart, so the indices are
    // read as interner ids: bone lookups resolve to the wrong name, and
    // DB_FreeUnusedResources adds a reference to whatever memory-tree node the index
    // lands on, which quietly corrupts unrelated strings.
    //
    // Load_TempStringCustom interns with user 4, and DB_FreeUnusedResources sweeps
    // on that bit, so these have to be interned the same way to survive the sweep.
    constexpr unsigned int kScriptStringUser = 4;

    std::vector<uint16_t> g_zoneScriptStrings;
    // OAT preserves the fastfile's pointer sharing. Weapon/camo XModels that use
    // the same skeleton therefore point at the same boneNames allocation, and
    // several XAnims can share their names array as well. Save the actual strings
    // while translating each array the first time. DB_FreeUnusedResources is
    // allowed to release a map's SL ids on unload; a cached OAT zone must then
    // re-intern the names rather than interpreting those stale runtime ids as the
    // original zone-local indexes.
    std::unordered_map<const uint16_t *, std::vector<std::string>> g_scriptStringArrays;

    // A fastfile stores GfxAabbTree::childrenOffset in bytes relative to its
    // 44-byte x86 records. OAT expands those records to the native structure
    // size but intentionally preserves the serialized integer. Translate that
    // relative offset before renderer visibility or impact-mark code walks it.
    void NormalizeGfxAabbTreeOffsets(GfxWorld *world)
    {
        constexpr int kSerializedTreeSize = 44;
        if (!world || sizeof(GfxAabbTree) == kSerializedTreeSize)
            return;

        int adjusted = 0;
        for (int cellIndex = 0; cellIndex < world->dpvsPlanes.cellCount; ++cellIndex)
        {
            GfxCell &cell = world->cells[cellIndex];
            for (int treeIndex = 0; treeIndex < cell.aabbTreeCount; ++treeIndex)
            {
                GfxAabbTree &tree = cell.aabbTree[treeIndex];
                if (!tree.childCount)
                    continue;

                const int serializedOffset = tree.childrenOffset;
                if (serializedOffset <= 0 || serializedOffset % kSerializedTreeSize != 0)
                {
                    Com_PrintError(10, "[oat] invalid AABB child offset %d in cell %d tree %d\n",
                                   serializedOffset, cellIndex, treeIndex);
                    continue;
                }

                const int childDelta = serializedOffset / kSerializedTreeSize;
                if (childDelta <= 0 || treeIndex + childDelta + tree.childCount > cell.aabbTreeCount)
                {
                    Com_PrintError(10,
                                   "[oat] AABB children outside cell %d: tree %d delta %d count %u/%d\n",
                                   cellIndex, treeIndex, childDelta, tree.childCount, cell.aabbTreeCount);
                    continue;
                }

                tree.childrenOffset = childDelta * static_cast<int>(sizeof(GfxAabbTree));
                ++adjusted;
            }
        }

        Com_Printf(8, "[oat] normalized %d native AABB child offset(s)\n", adjusted);
    }

    void BuildZoneScriptStringMap(const OatZone *zone)
    {
        const int count = OAT_ScriptStringCount(zone);
        g_zoneScriptStrings.assign(static_cast<size_t>(count > 0 ? count : 1), 0);
        // Fastfiles preserve the source table verbatim; the null entry is not
        // guaranteed to occupy slot 0. Translate every non-empty slot, including
        // slot 0, exactly as Load_TempStringCustom does in the stock reader.
        for (int i = 0; i < count; ++i)
        {
            const char *const str = OAT_ScriptStringAt(zone, i);
            if (str && *str)
                g_zoneScriptStrings[i] = static_cast<uint16_t>(SL_GetString(str, kScriptStringUser));
        }
    }

    void RemapScriptStrings(uint16_t *ids, size_t count)
    {
        if (!ids || !count)
            return;

        auto [savedIt, inserted] = g_scriptStringArrays.try_emplace(ids);
        if (!inserted)
            return;
        std::vector<std::string> &saved = savedIt->second;
        saved.reserve(count);
        for (size_t i = 0; i < count; ++i)
        {
            const uint16_t local = ids[i];
            ids[i] = local < g_zoneScriptStrings.size() ? g_zoneScriptStrings[local] : 0;
            saved.emplace_back(ids[i] ? SL_ConvertToString(ids[i]) : "");
        }
    }

    void RestoreScriptStrings(uint16_t *ids, size_t count)
    {
        if (!ids || !count)
            return;

        const auto savedIt = g_scriptStringArrays.find(ids);
        if (savedIt == g_scriptStringArrays.end())
        {
            Com_PrintWarning(10, "WARNING: [oat] no saved script strings for cached array %p\n",
                             static_cast<void *>(ids));
            return;
        }

        const std::vector<std::string> &saved = savedIt->second;
        if (saved.size() != count)
        {
            Com_PrintWarning(10,
                             "WARNING: [oat] cached script-string array %p changed size (%zu -> %zu)\n",
                             static_cast<void *>(ids), saved.size(), count);
        }
        const size_t restoreCount = std::min(count, saved.size());
        for (size_t i = 0; i < restoreCount; ++i)
            ids[i] = saved[i].empty() ? 0 : static_cast<uint16_t>(SL_GetString(saved[i].c_str(), kScriptStringUser));
    }

    // The five structures that carry script strings, per the Load_ScriptString call
    // sites in db_load.cpp. Reference stubs are excluded by the caller: their arrays
    // belong to the owning zone, which has already been through here.
    void RemapAssetScriptStrings(int type, void *payload)
    {
        switch (type)
        {
        case ASSET_TYPE_XANIMPARTS:
        {
            XAnimParts *const anim = static_cast<XAnimParts *>(payload);
            RemapScriptStrings(anim->names, anim->boneCount[9]);
            for (uint8_t i = 0; i < anim->notifyCount; ++i)
                RemapScriptStrings(&anim->notify[i].name, 1);
            break;
        }
        case ASSET_TYPE_XMODEL:
        {
            XModel *const model = static_cast<XModel *>(payload);
            RemapScriptStrings(model->boneNames, model->numBones);
            break;
        }
        case ASSET_TYPE_WEAPON:
        {
            WeaponDef *const weapon = static_cast<WeaponDef *>(payload);
            RemapScriptStrings(weapon->hideTags, ARRAY_COUNT(weapon->hideTags));
            RemapScriptStrings(weapon->notetrackSoundMapKeys, ARRAY_COUNT(weapon->notetrackSoundMapKeys));
            RemapScriptStrings(weapon->notetrackSoundMapValues, ARRAY_COUNT(weapon->notetrackSoundMapValues));
            break;
        }
        case ASSET_TYPE_GAMEWORLD_SP:
        {
            PathData &path = static_cast<GameWorldSp *>(payload)->path;
            for (unsigned int i = 0; i < path.nodeCount; ++i)
            {
                pathnode_constant_t &node = path.nodes[i].constant;
                RemapScriptStrings(&node.targetname, 1);
                RemapScriptStrings(&node.script_linkName, 1);
                RemapScriptStrings(&node.script_noteworthy, 1);
                RemapScriptStrings(&node.target, 1);
                RemapScriptStrings(&node.animscript, 1);
            }
            break;
        }
        default:
            break;
        }
    }

    void RestoreAssetScriptStrings(int type, void *payload)
    {
        switch (type)
        {
        case ASSET_TYPE_XANIMPARTS:
        {
            XAnimParts *const anim = static_cast<XAnimParts *>(payload);
            RestoreScriptStrings(anim->names, anim->boneCount[9]);
            for (uint8_t i = 0; i < anim->notifyCount; ++i)
                RestoreScriptStrings(&anim->notify[i].name, 1);
            break;
        }
        case ASSET_TYPE_XMODEL:
        {
            XModel *const model = static_cast<XModel *>(payload);
            RestoreScriptStrings(model->boneNames, model->numBones);
            break;
        }
        case ASSET_TYPE_WEAPON:
        {
            WeaponDef *const weapon = static_cast<WeaponDef *>(payload);
            RestoreScriptStrings(weapon->hideTags, ARRAY_COUNT(weapon->hideTags));
            RestoreScriptStrings(weapon->notetrackSoundMapKeys, ARRAY_COUNT(weapon->notetrackSoundMapKeys));
            RestoreScriptStrings(weapon->notetrackSoundMapValues, ARRAY_COUNT(weapon->notetrackSoundMapValues));
            break;
        }
        case ASSET_TYPE_GAMEWORLD_SP:
        {
            PathData &path = static_cast<GameWorldSp *>(payload)->path;
            for (unsigned int i = 0; i < path.nodeCount; ++i)
            {
                pathnode_constant_t &node = path.nodes[i].constant;
                RestoreScriptStrings(&node.targetname, 1);
                RestoreScriptStrings(&node.script_linkName, 1);
                RestoreScriptStrings(&node.script_noteworthy, 1);
                RestoreScriptStrings(&node.target, 1);
                RestoreScriptStrings(&node.animscript, 1);
            }
            break;
        }
        default:
            break;
        }
    }

    bool ResolveWeaponSoundSlot(snd_alias_list_t **slot, const char *name)
    {
        if (!slot || !name || !*name)
            return true;

        const XAssetEntryPoolEntry *const entry = DB_FindXAssetEntry(ASSET_TYPE_SOUND, name);
        if (!entry || !entry->entry.asset.header.sound)
            return false;

        *slot = entry->entry.asset.header.sound;
        return true;
    }

    void QueueWeaponSoundSlot(snd_alias_list_t **slot)
    {
        if (!slot || !*slot)
            return;

        // snd_alias_list_name::soundName and snd_alias_list_t::aliasName are both
        // the first pointer. Reading only that shared prefix is valid before the
        // custom reference has been resolved.
        const char *const name = (*slot)->aliasName;
        if (!name || !*name)
        {
            *slot = nullptr;
            return;
        }

        if (!ResolveWeaponSoundSlot(slot, name))
            g_pendingWeaponSounds.push_back({slot, name});
    }

    void QueueWeaponSoundRefs(WeaponDef *weapon)
    {
        if (!weapon)
            return;

        snd_alias_list_t **const fixedSlots[] = {
            &weapon->pickupSound,
            &weapon->pickupSoundPlayer,
            &weapon->ammoPickupSound,
            &weapon->ammoPickupSoundPlayer,
            &weapon->projectileSound,
            &weapon->pullbackSound,
            &weapon->pullbackSoundPlayer,
            &weapon->fireSound,
            &weapon->fireSoundPlayer,
            &weapon->fireLoopSound,
            &weapon->fireLoopSoundPlayer,
            &weapon->fireStopSound,
            &weapon->fireStopSoundPlayer,
            &weapon->fireLastSound,
            &weapon->fireLastSoundPlayer,
            &weapon->emptyFireSound,
            &weapon->emptyFireSoundPlayer,
            &weapon->meleeSwipeSound,
            &weapon->meleeSwipeSoundPlayer,
            &weapon->meleeHitSound,
            &weapon->meleeMissSound,
            &weapon->rechamberSound,
            &weapon->rechamberSoundPlayer,
            &weapon->reloadSound,
            &weapon->reloadSoundPlayer,
            &weapon->reloadEmptySound,
            &weapon->reloadEmptySoundPlayer,
            &weapon->reloadStartSound,
            &weapon->reloadStartSoundPlayer,
            &weapon->reloadEndSound,
            &weapon->reloadEndSoundPlayer,
            &weapon->detonateSound,
            &weapon->detonateSoundPlayer,
            &weapon->nightVisionWearSound,
            &weapon->nightVisionWearSoundPlayer,
            &weapon->nightVisionRemoveSound,
            &weapon->nightVisionRemoveSoundPlayer,
            &weapon->altSwitchSound,
            &weapon->altSwitchSoundPlayer,
            &weapon->raiseSound,
            &weapon->raiseSoundPlayer,
            &weapon->firstRaiseSound,
            &weapon->firstRaiseSoundPlayer,
            &weapon->putawaySound,
            &weapon->putawaySoundPlayer,
            &weapon->projExplosionSound,
            &weapon->projDudSound,
            &weapon->projIgnitionSound,
        };

        for (snd_alias_list_t **const slot : fixedSlots)
            QueueWeaponSoundSlot(slot);

        if (weapon->bounceSound)
        {
            for (int surfaceType = 0; surfaceType < 29; ++surfaceType)
                QueueWeaponSoundSlot(&weapon->bounceSound[surfaceType]);
        }
    }

    void ResolvePendingWeaponSounds()
    {
        if (g_pendingWeaponSounds.empty())
            return;

        int resolved = 0;
        std::vector<PendingWeaponSound> stillPending;
        stillPending.reserve(g_pendingWeaponSounds.size());
        for (const PendingWeaponSound &pending : g_pendingWeaponSounds)
        {
            if (ResolveWeaponSoundSlot(pending.slot, pending.name.c_str()))
                ++resolved;
            else
                stillPending.push_back(pending);
        }

        if (resolved)
            Com_Printf(8, "[oat] weapon sounds: resolved %d custom alias reference(s), %zu pending\n",
                       resolved, stillPending.size());
        g_pendingWeaponSounds = std::move(stillPending);
    }
}

// Resolve what OAT left as stubs. Assets in one zone point at assets another zone
// owns, and the fastfile records those as a name with a leading ',' rather than a
// pointer. OAT does not resolve them - it never loads more than one zone at a time -
// so the stub struct stays zeroed, and the first thing to use it dereferences null.
//
// The engine's own loader resolves each handle field as it reads it. That needs a
// per-field walk of the whole asset graph. Copying the real asset over the stub gets
// the same result for every type at once: whatever points at the stub now sees the
// real contents, because the two structs are the same shape.
// Called once the engine has removed this zone's asset entries. Until this existed
// the OAT zone outlived them, so after Com_Restart reloaded a zone both the old and
// new copies of an asset were alive - and UI_AddMenu asserts that looking a menu up
// by name returns the very object the MenuList points at.
extern "C" void Posix_ReleaseOatZone(const char *zoneName)
{
    if (!zoneName)
        return;

    // Nothing is actually freed yet, and the reason is worth stating.
    //
    // Two separate things keep pointers into a zone after the engine says to unload
    // it. Other zones: references resolve by copying the real asset over the stub, so
    // the copy's internal pointers live in the owner's memory (g_pinnedZones tracks
    // that). And the engine itself: on the fastfile path UI_Shutdown skips
    // Menus_FreeAllMemory, so uiInfoArray keeps raw menu pointers across a restart -
    // releasing ui_mp when asked crashed for exactly that reason.
    //
    // The cost is that map zones accumulate, roughly 34 MB per map switched to.
    // Resolving references per handle field rather than by copying the struct fixes
    // the first; the second needs the engine's own pointers dropped on unload.
    (void)g_pinnedZones;
    for (LoadedZone &loaded : g_oatZones)
    {
        if (loaded.name != zoneName)
            continue;

        loaded.registered = false;
        Com_Printf(8, "[oat] zone '%s' unregistered; retaining storage for pointer stability\n",
                   zoneName);
        return;
    }
}

// Point every MenuList entry at the menu the asset database hands out for that name.
//
// A menu a zone references but does not own arrives as a stub, and resolution fills
// the stub by copying the owner's asset over it. That leaves two objects for one name:
// the owner's, and this zone's copy - and the MenuList holds the copy. UI_AddMenu
// requires the two to be the same object, because the engine tracks open menus by
// pointer and would otherwise never match a menu it looked up by name.
static void Posix_ReconcileMenuLists()
{
    int repointed = 0;

    for (const auto &loaded : g_oatZones)
    {
        for (int i = 0, n = OAT_AssetCount(loaded.zone.get()); i < n; ++i)
        {
            OatAsset asset{};
            if (!OAT_AssetAt(loaded.zone.get(), i, &asset) || asset.type != ASSET_TYPE_MENULIST || !asset.data)
                continue;

            auto *list = static_cast<MenuList *>(asset.data);
            for (int slot = 0; slot < list->menuCount; ++slot)
            {
                menuDef_t *const menu = list->menus ? list->menus[slot] : nullptr;
                if (!menu || !menu->window.name)
                    continue;

                const XAssetEntryPoolEntry *entry = DB_FindXAssetEntry(ASSET_TYPE_MENU, menu->window.name);
                menuDef_t *const canonical = entry ? entry->entry.asset.header.menu : nullptr;
                if (!canonical || canonical == menu)
                    continue;

                list->menus[slot] = canonical;
                ++repointed;
            }
        }
    }

    if (repointed)
        Com_Printf(8, "[oat] menulists: repointed %d menu(s) at their registered asset\n", repointed);
}

extern "C" void Posix_ResolveOatReferences()
{
    if (g_pendingReferences.empty())
        return;

    int resolved = 0;
    std::vector<PendingReference> stillPending;

    for (const auto &pending : g_pendingReferences)
    {
        const auto type = static_cast<XAssetType>(pending.type);
        // DB_FindXAssetHeader loads on a miss, which for a name whose zone is not in
        // yet means an error and a default asset. Look the entry up directly instead.
        const XAssetEntryPoolEntry *entry = DB_FindXAssetEntry(type, pending.name.c_str());
        const XAssetHeader real = entry ? entry->entry.asset.header : XAssetHeader();
        if (!real.data || real.data == pending.stub)
        {
            // The zone that owns it may not be loaded yet; try again next time.
            stillPending.push_back(pending);
            continue;
        }

        std::memcpy(pending.stub, real.data, static_cast<size_t>(DB_GetXAssetTypeSize(pending.type)));

        // The copy carries whatever state the original was in: already-converted
        // handles, or names this stub still has to convert for itself.
        if (type == ASSET_TYPE_FX)
        {
            if (g_fxResolved.count(real.data))
                g_fxResolved.insert(pending.stub);
            else
                g_fxAwaitingResolve.push_back(static_cast<FxEffectDef *>(pending.stub));
        }

        // The copy's pointers still point into whoever owns the original.
        const auto owner = g_assetOwner.find(real.data);
        if (owner != g_assetOwner.end())
            g_pinnedZones.insert(owner->second);

        // Register the stub under the real name as well. Assets in this zone point at
        // the stub, not at the original, and parts of the engine look an asset up by
        // pointer rather than by name - DB_GetXAsset walks the hash chain for the name
        // comparing header pointers, and asserted on techset '2d' because the only
        // entry held the owner's copy.
        if (!std::getenv("KISAK_NO_STUB_REG"))
        {
            DB_AddXAsset(type, XAssetHeader(pending.stub));
            g_assetOwner[pending.stub] = "(reference)";
        }

        ++resolved;
    }

    if (resolved || !stillPending.empty())
        Com_Printf(8, "[oat] resolved %d reference(s), %zu still pending\n", resolved, stillPending.size());
    for (const auto &pending : stillPending)
        Com_PrintWarning(10, "WARNING: [oat] unresolved %s (type %d)\n", pending.name.c_str(), pending.type);
    g_pendingReferences = std::move(stillPending);

    // Some sound assets become visible only when the generic cross-zone stubs
    // above are resolved. Finish the WeaponDef custom-name conversion afterwards.
    ResolvePendingWeaponSounds();

    // Every stub is registered by now, so an effect naming one can find it.
    std::vector<FxEffectDef *> fx;
    fx.swap(g_fxAwaitingResolve);
    for (FxEffectDef *const effect : fx)
        ResolveFxEffectRefs(effect);

    if (resolved)
        Posix_ReconcileMenuLists();
}

// The bridge hands over raw pointers, so the two trees must agree on layout, not just
// on field names (structdiff.py checks the names). A mismatch here reads plausible
// garbage rather than failing, so report it loudly the first time a zone loads.
static void Posix_CheckOatLayout()
{
    struct Expected
    {
        int id;
        unsigned long engineSize;
    };

    const Expected expected[] = {
        {OAT_STRUCT_MATERIAL, sizeof(Material)},
        {OAT_STRUCT_MATERIAL_TECHNIQUE_SET, sizeof(MaterialTechniqueSet)},
        {OAT_STRUCT_GFX_IMAGE, sizeof(GfxImage)},
        {OAT_STRUCT_MENU_DEF, sizeof(menuDef_t)},
        {OAT_STRUCT_ITEM_DEF, sizeof(itemDef_s)},
        {OAT_STRUCT_OPERAND, sizeof(Operand)},
        {OAT_STRUCT_EXPRESSION_ENTRY, sizeof(expressionEntry)},
        {OAT_STRUCT_STATEMENT, sizeof(statement_s)},
        // XAnimParts and every nested frame pointer are consumed directly by
        // the viewmodel animation evaluator.  A layout mismatch here presents
        // as broken recoil/reload bones rather than as an obvious load error.
        {OAT_STRUCT_XANIM_PARTS, sizeof(XAnimParts)},
        // AdoptCodeAsset copies sizeof(cm) bytes out of OAT's clipMap_t, so a
        // disagreement here is a buffer overread rather than a garbled asset.
        {OAT_STRUCT_CLIPMAP, sizeof(clipMap_t)},
        {OAT_STRUCT_GFX_WORLD, sizeof(GfxWorld)},
        {OAT_STRUCT_SND_ALIAS, sizeof(snd_alias_t)},
        {OAT_STRUCT_SND_ALIAS_LIST, sizeof(snd_alias_list_t)},
        {OAT_STRUCT_WEAPON_DEF, sizeof(WeaponDef)},
    };

    int mismatches = 0;
    for (const auto &e : expected)
    {
        const unsigned long oatSize = OAT_StructSize(e.id);
        if (oatSize == e.engineSize)
            continue;

        Com_PrintError(10, "[oat] LAYOUT MISMATCH %s: engine %lu bytes, OAT %lu bytes\n",
                       OAT_StructName(e.id), e.engineSize, oatSize);
        ++mismatches;
    }

    if (mismatches)
        Com_PrintError(10, "[oat] %d struct(s) disagree - loaded assets will read as garbage\n", mismatches);
    else
        Com_Printf(8, "[oat] layout check: %zu structs agree\n", sizeof(expected) / sizeof(expected[0]));
}

extern "C" void Posix_ResolveOatReferences();
extern "C" void Posix_ReleaseOatZone(const char *zoneName);

extern "C" double Posix_GetOatLoadFraction()
{
    return g_oatLoadFraction.load(std::memory_order_relaxed);
}

extern "C" int Posix_LoadZoneWithOat(const char *filename, const char *zoneName)
{
    g_lastLoadScreenUpdate = -1.0;
    SetOatLoadFraction(0.0, true);

    static bool layoutChecked = false;
    if (!layoutChecked)
    {
        layoutChecked = true;
        Posix_CheckOatLayout();
    }

    // A zone the engine asks for twice is reused, not loaded again.
    //
    // With fastfiles the engine keeps raw pointers into zone memory across a restart -
    // it skips Menus_FreeAllMemory - and expects a reload to reuse the same storage.
    // Loading a second copy gave every asset two generations, and because references
    // resolve by copying the real asset over the stub, a generation-2 MenuList could
    // end up holding generation-1 menus. UI_AddMenu catches exactly that and asserts.
    // Reusing keeps one generation per zone name and every pointer stable.
    LoadedZone *cachedZone = nullptr;
    for (LoadedZone &loaded : g_oatZones)
    {
        if (loaded.name != zoneName)
            continue;

        // Already loaded, and its assets are already in the database - there is
        // nothing to do. Re-registering them churns the hash chains: DB_AddXAsset
        // links with allowOverride 0, lands in DB_DelayedCloneXAsset, and with g_sync
        // that re-enters with allowOverride 1 and frees the duplicate entry. The
        // engine then cannot find the asset by pointer and DB_GetXAsset asserts.
        if (loaded.registered)
        {
            Com_Printf(8, "[oat] zone '%s' already loaded, reusing\n", zoneName);
            SetOatLoadFraction(1.0, true);
            return 1;
        }

        cachedZone = &loaded;
        break;
    }

    const bool firstRegistration = cachedZone == nullptr;
    std::unique_ptr<OatZone, ZoneDeleter> fresh;
    OatZone *zoneRef = nullptr;
    if (firstRegistration)
    {
        char err[512] = {0};
        fresh.reset(OAT_LoadZoneWithProgress(filename, err, sizeof(err), OatLoadProgress, nullptr));
        if (!fresh)
        {
            Com_PrintWarning(10, "WARNING: OAT could not load zone '%s': %s\n", zoneName, err);
            SetOatLoadFraction(0.0, false);
            return 0;
        }
        zoneRef = fresh.get();
        BuildZoneScriptStringMap(zoneRef);
        SetOatLoadFraction(0.8, true);
    }
    else
    {
        zoneRef = cachedZone->zone.get();
        Com_Printf(8, "[oat] zone '%s' storage cached; re-registering assets\n", zoneName);
        SetOatLoadFraction(0.8, true);
    }

    const int count = OAT_AssetCount(zoneRef);
    const bool trace = std::getenv("KISAK_OAT_TRACE") != nullptr;
    int registered = 0;
    int skipped = 0;
    int nullTechsets = 0;
    int references = 0;
    int imagesTraced = 0;
    int imagesWithPixels = 0;
    int nullData = 0;

    for (int i = 0; i < count; ++i)
    {
        OatAsset asset{};
        if (!OAT_AssetAt(zoneRef, i, &asset))
            continue;

        // The world assets are what a map cannot start without; say what happens to
        // each one so a miss is visible rather than lost in the count.
        const bool isWorld = asset.type == ASSET_TYPE_CLIPMAP || asset.type == ASSET_TYPE_CLIPMAP_PVS ||
                             asset.type == ASSET_TYPE_GFXWORLD || asset.type == ASSET_TYPE_COMWORLD ||
                             asset.type == ASSET_TYPE_GAMEWORLD_MP || asset.type == ASSET_TYPE_MAP_ENTS;
        if (isWorld)
            Com_Printf(8, "[oat]   world asset type=%d '%s' data=%p ref=%d\n",
                       asset.type, asset.name, asset.data, asset.isReference);

        if (!asset.data)
        {
            ++nullData;
            continue;
        }

        // A reference stub stands in for an asset another zone owns. Registering it
        // would shadow the real one, so hold it aside and resolve it once every zone
        // has loaded - see Posix_ResolveOatReferences.
        if (asset.isReference)
        {
            QueuePendingReference(asset.type, asset.name + 1, asset.data);
            ++references;
            continue;
        }

        // Every per-type table in db_registry.cpp is indexed by the raw type with
        // no range check, so an unexpected value reads past the array and lands in
        // whatever data follows it.
        if (asset.type < 0 || asset.type >= ASSET_TYPE_COUNT)
        {
            Com_PrintWarning(10, "WARNING: [oat] '%s' has out-of-range type %d, skipped\n", asset.name, asset.type);
            ++skipped;
            continue;
        }

        if (trace)
        {
            // Watch one pool's free head across every registration: whichever
            // asset leaves it holding non-pointer bytes is the one overrunning.
            void *watched = DB_XAssetPool[9] ? *static_cast<void **>(DB_XAssetPool[9]) : nullptr;
            std::fprintf(stderr, "[oat-trace] %4d type=%2d loadedSoundFreeHead=%p name=%s\n",
                         i, asset.type, watched, asset.name);
            std::fflush(stderr);
        }

        void *const payload = AdoptCodeAsset(asset.type, asset.data);

        if (asset.type == ASSET_TYPE_FX)
            TracePhysicsFxAsset(asset.name, static_cast<FxEffectDef *>(payload));

        if (firstRegistration && asset.type == ASSET_TYPE_GFXWORLD)
            NormalizeGfxAabbTreeOffsets(static_cast<GfxWorld *>(payload));

        // Before the asset is visible to anything: DB_AddXAsset can evict an older
        // asset of the same name, and DB_FreeUnusedResources reads these ids.
        if (firstRegistration)
            RemapAssetScriptStrings(asset.type, payload);
        else
            RestoreAssetScriptStrings(asset.type, payload);

        if (firstRegistration && asset.type == ASSET_TYPE_WEAPON)
            QueueWeaponSoundRefs(static_cast<WeaponDef *>(payload));

#ifdef KISAK_DXVK
        if (asset.type == ASSET_TYPE_TECHNIQUE_SET)
            BuildTechniqueSetGpuResources(static_cast<MaterialTechniqueSet *>(payload));
        else if (asset.type == ASSET_TYPE_IMAGE)
            BuildImageGpuResources(static_cast<GfxImage *>(payload));
#endif

        DB_AddXAsset(static_cast<XAssetType>(asset.type), XAssetHeader(payload));
        g_assetOwner[payload] = zoneName;
        ++registered;

        // Deferred until the whole zone is registered: a runner effect usually names
        // effects that appear later in the same zone.
        if (firstRegistration && asset.type == ASSET_TYPE_FX)
            g_fxAwaitingResolve.push_back(static_cast<FxEffectDef *>(payload));

        // CLIPMAP and CLIPMAP_PVS are the same clipMap_t under two type slots. A map
        // zone carries it under one of them - mp_shipment uses CLIPMAP_PVS - while the
        // engine looks it up under the other and gives up with "Couldn't find the bsp
        // for this map". Register it under both so either lookup finds it.
        if (asset.type == ASSET_TYPE_CLIPMAP || asset.type == ASSET_TYPE_CLIPMAP_PVS)
        {
            const XAssetType other = asset.type == ASSET_TYPE_CLIPMAP ? ASSET_TYPE_CLIPMAP_PVS
                                                                      : ASSET_TYPE_CLIPMAP;
            DB_AddXAsset(other, XAssetHeader(payload));
        }

        if (isWorld)
        {
            // Confirm the registration is findable by the same lookup the engine uses,
            // and by what name the database thinks it has.
            const XAssetEntryPoolEntry *back =
                DB_FindXAssetEntry(static_cast<XAssetType>(asset.type), asset.name);
            Com_Printf(8, "[oat]   -> lookup '%s' type=%d gives %p (registered %p)\n",
                       asset.name, asset.type,
                       back ? (void *)back->entry.asset.header.data : nullptr, payload);
        }

        // Material_GetTechniqueSet returns techniqueSet->remappedTechniqueSet, which
        // the runtime fills in when it remaps a techset for the active renderer. The
        // zone does not carry it either ("set condition remappedTechniqueSet never"),
        // so point each set at itself - the identity remap the engine uses when no
        // substitution applies. Without it the first painted material dereferences
        // null inside Material_HasAnyFogableTechnique.
        if (asset.type == ASSET_TYPE_IMAGE && std::getenv("KISAK_IMG_TRACE"))
        {
            const auto *img = static_cast<const GfxImage *>(asset.data);
            const GfxImageLoadDef *ld = img->texture.loadDef;
            if (imagesTraced < 8)
                Com_Printf(8, "[img] %-28s %ux%u loadDef=%p fmt=%d size=%d levels=%d delay=%d\n",
                           asset.name, img->width, img->height, (const void *)ld,
                           ld ? (int)ld->format : -1, ld ? ld->resourceSize : -1,
                           ld ? ld->levelCount : -1, img->delayLoadPixels ? 1 : 0);
            ++imagesTraced;
            if (ld && ld->resourceSize > 0) ++imagesWithPixels;
        }

        if (asset.type == ASSET_TYPE_TECHNIQUE_SET)
        {
            auto *techSet = static_cast<MaterialTechniqueSet *>(asset.data);
            if (!techSet->remappedTechniqueSet)
                techSet->remappedTechniqueSet = techSet;
        }

        // Not every techset appears as a top-level asset: a material can be the only
        // thing referencing one, and the zone that owns it may already be unloaded as
        // a reference. Remap through the material too, or the first item painted with
        // it dereferences null inside Material_HasAnyFogableTechnique.
        if (asset.type == ASSET_TYPE_MATERIAL)
        {
            auto *material = static_cast<Material *>(asset.data);
            if (material->techniqueSet && !material->techniqueSet->remappedTechniqueSet)
                material->techniqueSet->remappedTechniqueSet = material->techniqueSet;
            if (!material->techniqueSet)
            {
                if (nullTechsets < 5)
                    Com_Printf(8, "[oat]   material without techniqueSet: %s\n", asset.name);
                ++nullTechsets;
            }
        }

        // itemDef_s::parent points back at the owning menu. OAT's zone spec marks it
        // "never" - it is a back reference the game reconstructs rather than data the
        // fastfile carries - so rebuild it here. Item_SetFocus tests parent for null
        // on the way in and then dereferences parent->itemCount at the end without
        // checking, so leaving it null faults while the main menu opens.
        if (asset.type == ASSET_TYPE_MENU)
        {
            auto *menu = static_cast<menuDef_t *>(asset.data);
            for (int item = 0; item < menu->itemCount; ++item)
            {
                if (menu->items && menu->items[item])
                    menu->items[item]->parent = menu;
            }
        }

        SetOatLoadFraction(0.8 + (count ? 0.19 * static_cast<double>(i + 1) / static_cast<double>(count) : 0.19), true);
    }

    Com_Printf(0, "[oat] zone '%s': registered %d of %d assets (%d skipped)\n", zoneName, registered, count, skipped);
    if (imagesTraced)
        Com_Printf(8, "[img] %d image(s), %d with pixel data\n", imagesTraced, imagesWithPixels);
    if (references)
        Com_Printf(8, "[oat]   %d reference(s) deferred\n", references);
    if (nullData)
        Com_Printf(8, "[oat]   %d asset(s) had no data\n", nullData);
    if (nullTechsets)
        Com_Printf(8, "[oat]   %d material(s) have no techniqueSet\n", nullTechsets);

    // Same-zone sound assets may appear later than their WeaponDef in the pool.
    // Resolve once more now that every asset in this zone is registered.
    ResolvePendingWeaponSounds();
    // Release stays engine-driven, from DB_UnloadXZone.  A cached zone keeps the
    // same allocation and simply becomes live in the database again.
    if (firstRegistration)
        g_oatZones.push_back({zoneName, std::move(fresh), true});
    else
        cachedZone->registered = true;

    // Resolve what this zone just made resolvable. Anything still missing waits for a
    // later zone; Posix_LoadDeferredZones runs a final pass once they are all in.
    Posix_ResolveOatReferences();
    SetOatLoadFraction(1.0, true);
    return 1;
}
