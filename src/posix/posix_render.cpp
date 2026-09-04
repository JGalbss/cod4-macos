// Renderer entry points the POSIX build needs from src/gfx_d3d/r_init.cpp.
//
// r_init.cpp itself cannot build yet (it is tied to _D3DDISPLAYMODE and the D3D9 device),
// but two of its functions have nothing to do with D3D and were left as empty stubs in
// posix_backbone_stubs.cpp. That silently disabled all asset loading: the engine built a
// perfectly good GfxConfiguration in CL_SetFastFileNames, handed it to R_ConfigureRenderer,
// and the stub threw it away - so gfxCfg stayed zeroed, every fastfile name was NULL, and
// R_LoadGraphicsAssets never ran. The first visible symptom was
// "Could not load material \"white\"" during CL_InitRenderer.
//
// These are transcribed from r_init.cpp with only the D3D-specific parts removed.

#include "gfx_d3d/r_init.h"
#include "gfx_d3d/r_material.h"
#include "gfx_d3d/r_rendercmds.h"
#include "gfx_d3d/r_drawsurf.h"
#include "gfx_d3d/r_scene.h"
#include "database/database.h"
#include "qcommon/qcommon.h"
#include "client_mp/client_mp.h"

#include <algorithm>
#include <cstring>

// r_init.cpp:2809 SetGfxConfig + 4217 R_ConfigureRenderer.
extern void __cdecl R_RegisterDvars();
extern void __cdecl R_RegisterCmds();
extern void __cdecl R_InitRenderCommands();
extern "C" void Posix_ResolveOatReferences();
#ifdef KISAK_DXVK
#include "posix/posix_d3d_device.h"
#endif

void Material_Sort()
{
    // The stock implementation lives in r_material_load_obj.cpp, a Windows
    // development-asset loader that cannot be part of the POSIX build.  Fastfile
    // rendering still requires this table: every GfxDrawSurf stores only its
    // material's sorted index.  Metal performs its own state selection, so a
    // deterministic sort-key/name order is sufficient and avoids importing the
    // D3D shader comparator solely to establish those indices.
    rgp.materialCount = DB_GetAllXAssetOfType(
        ASSET_TYPE_MATERIAL, reinterpret_cast<XAssetHeader *>(rgp.sortedMaterials),
        static_cast<int>(std::size(rgp.sortedMaterials)));
    std::sort(rgp.sortedMaterials, rgp.sortedMaterials + rgp.materialCount,
              [](const Material *a, const Material *b) {
                  if (a->info.sortKey != b->info.sortKey)
                      return a->info.sortKey < b->info.sortKey;
                  const char *const aName = a->info.name ? a->info.name : "";
                  const char *const bName = b->info.name ? b->info.name : "";
                  return std::strcmp(aName, bName) < 0;
              });
    for (int i = 0; i < rgp.materialCount; ++i)
    {
        Material *const material = rgp.sortedMaterials[i];
        material->info.drawSurf.packed = 0;
        material->info.drawSurf.fields.primarySortKey = material->info.sortKey;
        material->info.drawSurf.fields.prepass = MTL_PREPASS_NONE;
        material->info.drawSurf.fields.customIndex = (material->info.gameFlags & 0x40) != 0;
        material->info.drawSurf.fields.materialSortedIndex = static_cast<unsigned int>(i);
    }
    Com_Printf(8, "[posix] indexed %d native materials\n", rgp.materialCount);
}

void __cdecl R_ConfigureRenderer(const GfxConfiguration *config)
{
    if (!config) return;

    // R_RegisterDvars lives in r_dvars.cpp, which IS built, but its only callers are in
    // r_init.cpp (R_Init / R_Register), which is not. So every r_* dvar pointer stayed
    // NULL and the first read faulted: R_AllocStaticVertexBuffer dereferences
    // r_loadForRenderer->current.enabled on its second instruction, which is why zone
    // loading died at address 0x18. Register them here, once.
    static bool registered = false;
    if (!registered) {
        registered = true;
        R_RegisterDvars();
        // Same reason: r_cmds.cpp is built but R_RegisterCmds only had callers in
        // r_init.cpp, so "screenshot", "imagelist" and the gfx_* listings did not exist.
        R_RegisterCmds();

#ifndef KISAK_DXVK
        // No D3D device exists - gfx_gl is a plain GL renderer, not a D3D9 shim - so tell
        // the asset loader to skip every dx allocation. This is the engine's own dedicated
        // server path, not a hack: "Set to false to disable dx allocations".
        Dvar_SetBoolByName("r_loadForRenderer", 0);
#endif

        // r_init.cpp picks this from the GPU's capabilities and is not built here, so
        // it kept its "Default" (2) registration value while the shipped techsets are
        // Shader Model 3.0 (1). Material_GetTechnique asserts the two agree. gfx_gl
        // never executes a D3D shader, but the mismatch stops every material lookup,
        // so state what the data actually is. DVAR_ROM, set the same way r_init does.
        extern const dvar_t *r_rendererInUse;
        if (r_rendererInUse)
            Dvar_SetInt((dvar_s *)r_rendererInUse, 1);
    }
    std::memcpy(&gfxCfg, config, sizeof(gfxCfg));

    // Not D3D setup, despite the name: this allocates the front end's command buffers
    // and, through R_ToggleSmpFrame, publishes frontEndDataOut. Skipping it left that
    // pointer null and SCR_DrawScreenField faulted on the first frame in
    // R_BeginSharedCmdList. It reads gfxCfg.maxClientViews, so it has to run after the
    // memcpy above.
    static bool cmdsReady = false;
    if (!cmdsReady) {
        cmdsReady = true;
        R_InitRenderCommands();
#ifdef KISAK_METAL
        // Allocate CPU-backed dynamic meshes used by the original FX system.
        // The native backend consumes these buffers directly as Metal input.
        R_InitRenderBuffers();
        // R_InitScene normally runs at the end of D3D device creation.  Metal
        // deliberately has no such device, but still needs the frontend's 34
        // draw-surface arenas and limits for FX, decals, dynamic objects and
        // marks.  Leaving this zeroed made every generated FX draw surface fail
        // allocation even though its vertices and indices were valid.
        R_InitScene();
        // Metal consumes the engine's CPU-skinned vertices directly.  The D3D
        // initialization path normally reserves these two per-frame scratch
        // buffers, but that path is deliberately absent from the native build.
        R_InitTempSkinBuf();
#endif
    }

#ifdef KISAK_DXVK
    // After R_InitRenderCommands, which sizes the model lighting globals the render
    // targets are built from, and before the first zone loads and starts asking for
    // GPU resources.
    static bool deviceReady = false;
    if (!deviceReady) {
        deviceReady = true;
        Posix_CreateD3DDevice();
    }
#endif

    Com_Printf(8, "[posix] renderer configured: code='%s' common='%s' ui='%s'\n",
               gfxCfg.codeFastFileName    ? gfxCfg.codeFastFileName    : "(null)",
               gfxCfg.commonFastFileName  ? gfxCfg.commonFastFileName  : "(null)",
               gfxCfg.uiFastFileName      ? gfxCfg.uiFastFileName      : "(null)");
}

// DB_GetZoneAllocType maps these flags to PMem prim[1], which $init owns while it runs.
static bool Posix_ZoneNeedsInitAlloc(int allocFlags)
{
    return allocFlags == 1 || allocFlags == 4 || allocFlags == 16 || allocFlags == 32 || allocFlags == 64;
}

static XZoneInfo g_deferredZones[6]{};
static unsigned int g_deferredZoneCount = 0;

// r_init.cpp:3641, verbatim - it only touches gfxCfg and DB_LoadXAssets.
static void Posix_LoadGraphicsAssets()
{
    XZoneInfo zoneInfo[6]{};
    unsigned int zoneCount = 0;

    zoneInfo[zoneCount].name = gfxCfg.codeFastFileName;
    zoneInfo[zoneCount].allocFlags = 2;
    zoneInfo[zoneCount].freeFlags = 0;
    zoneCount++;

    if (gfxCfg.localizedCodeFastFileName) {
        zoneInfo[zoneCount].name = gfxCfg.localizedCodeFastFileName;
        zoneInfo[zoneCount].allocFlags = 0;
        zoneInfo[zoneCount].freeFlags = 0;
        zoneCount++;
    }
    if (gfxCfg.uiFastFileName) {
        zoneInfo[zoneCount].name = gfxCfg.uiFastFileName;
        zoneInfo[zoneCount].allocFlags = 8;
        zoneInfo[zoneCount].freeFlags = 0;
        zoneCount++;
    }

    zoneInfo[zoneCount].name = gfxCfg.commonFastFileName;
    zoneInfo[zoneCount].allocFlags = 4;
    zoneInfo[zoneCount].freeFlags = 0;
    zoneCount++;

    if (gfxCfg.localizedCommonFastFileName) {
        zoneInfo[zoneCount].name = gfxCfg.localizedCommonFastFileName;
        zoneInfo[zoneCount].allocFlags = 1;
        zoneInfo[zoneCount].freeFlags = 0;
        zoneCount++;
    }
    if (gfxCfg.modFastFileName) {
        zoneInfo[zoneCount].name = gfxCfg.modFastFileName;
        zoneInfo[zoneCount].allocFlags = 16;
        zoneInfo[zoneCount].freeFlags = 0;
        zoneCount++;
    }

    // sync=1, not upstream's 0. Async queues the zones for the database worker thread,
    // and qcommon/threads.cpp - the Win32-only 934-line threading implementation - is not
    // ported, so nothing ever drains the queue: every "Loading fastfile X" printed and no
    // asset ever registered, which surfaced as "Could not load material white".
    //
    // Loading on this thread does mean the $init allocation is still open, and $init holds
    // PMem prim[1] until Com_Init reaches PMem_EndAlloc(comInitAllocName, 1). Any zone that
    // allocates from prim[1] therefore cannot load yet - upstream never hits this because
    // its worker thread simply runs later. Split the list: take the prim[0] zones now, and
    // leave the rest for Posix_LoadDeferredZones, which Com_Init calls once prim[1] is free.
    unsigned int immediateCount = 0;
    for (unsigned int i = 0; i < zoneCount; ++i)
    {
        if (Posix_ZoneNeedsInitAlloc(zoneInfo[i].allocFlags))
            g_deferredZones[g_deferredZoneCount++] = zoneInfo[i];
        else
            zoneInfo[immediateCount++] = zoneInfo[i];
    }

    Com_Printf(8, "[posix] loading %u fastfile zone(s) now, %u after $init\n", immediateCount, g_deferredZoneCount);
    if (immediateCount)
        DB_LoadXAssets(zoneInfo, immediateCount, 1);
}

// Com_Init calls this immediately after it releases the $init allocation.
void Posix_LoadDeferredZones()
{
    if (!g_deferredZoneCount)
        return;

    const unsigned int count = g_deferredZoneCount;
    g_deferredZoneCount = 0;
    Com_Printf(8, "[posix] loading %u deferred fastfile zone(s)\n", count);
    DB_LoadXAssets(g_deferredZones, count, 1);

    // Every startup zone is in now, so cross-zone references can be resolved.
    Posix_ResolveOatReferences();

    // R_InitSystems normally does this after R_LoadGraphicsAssets, but that
    // routine is tied to D3D device creation and is intentionally absent from
    // the native renderer bootstrap. Material_Init itself is CPU/asset-side in
    // fastfile mode: it binds the built-in material pointers (most importantly
    // rgp.defaultMaterial) to the assets we just loaded. Without it the first
    // scoreboard update after spawning dereferences a null default material.
    Material_Init();
    rg.registered = 1;
    Com_Printf(8, "[posix] native renderer assets initialized\n");
}

// r_init.cpp:2939, minus R_Init()/dx asserts/R_ReleaseThreadOwnership - gfx_gl owns the
// device and cls.vidConfig is seeded in posix_gl_main.cpp before Com_Init.
void R_BeginRegistration(vidConfig_t *vidConfigOut)
{
    // Upstream fills the renderer-side `vidConfig` while creating the D3D device and then
    // copies it out to the caller (which is cls.vidConfig). gfx_gl never populates it, so
    // copying it out here would overwrite the values posix_gl_main.cpp seeded with zeros -
    // and CL_InitRenderer would assert on displayWidth > 0 again. Seed the renderer-side
    // copy FROM the caller's instead, so both agree.
    if (vidConfigOut) {
        if (vidConfigOut->displayWidth > 0)
            std::memcpy(&vidConfig, vidConfigOut, sizeof(vidConfig_t));
        else
            std::memcpy(vidConfigOut, &vidConfig, sizeof(vidConfig_t));
    }
    Posix_LoadGraphicsAssets();
}

// Sys_SyncDatabase, and the rest of the inline database-thread model, moved to
// src/posix/posix_database_thread.cpp.
