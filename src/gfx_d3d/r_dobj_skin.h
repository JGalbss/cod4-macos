#pragma once
#include "r_scene.h"

struct GfxModelSurfaceInfo // sizeof=0xC
{                                       // ...
    const struct DObjAnimMat *baseMat;
    unsigned __int8 boneIndex;
    unsigned __int8 boneCount;
    unsigned __int16 gfxEntIndex;
    unsigned __int16 lightingHandle;
    // padding byte
    // padding byte
};

struct GfxModelSkinnedSurface // sizeof=0x18
{                                       // ...
    int skinnedCachedOffset;
    XSurface *xsurf;
    GfxModelSurfaceInfo info;
    //$B667868682928995E3CB40CE466D3989 ___u3;
    union
    {
        GfxPackedVertex *skinnedVert;
        intptr_t oldSkinnedCachedOffset;
    };
};
#if UINTPTR_MAX == 0xFFFFFFFFu
static_assert(sizeof(GfxModelSkinnedSurface) == 24);
#endif

struct GfxModelRigidSurface // sizeof=0x38
{
    GfxModelSkinnedSurface surf;
    GfxScaledPlacement placement;
};
#if UINTPTR_MAX == 0xFFFFFFFFu
static_assert(sizeof(GfxModelRigidSurface) == 56);
#else
static_assert(sizeof(GfxModelSkinnedSurface) == 40);
static_assert(sizeof(GfxModelRigidSurface) == 72);
#endif

// Hidden surfaces only carry the -3 sentinel.  The original 32-bit record was
// four bytes, but retaining that size on LP64 leaves the following
// pointer-bearing descriptor misaligned.  Keep the sentinel compact while
// rounding it up to the native descriptor alignment.
constexpr unsigned int GFX_HIDDEN_MODEL_SURFACE_SIZE = alignof(GfxModelSkinnedSurface);
static_assert((GFX_HIDDEN_MODEL_SURFACE_SIZE & 3u) == 0u);

struct SkinXModelCmd // sizeof=0x1C
{                                       // ...
    void *modelSurfs;
    const DObjAnimMat *mat;
    int surfacePartBits[4];
    unsigned __int16 surfCount;
    // padding byte
    // padding byte
};

int __cdecl DObjBad(const DObj_s *obj);
void __cdecl R_SkinSceneDObj(
    GfxSceneEntity *sceneEnt,
    GfxSceneEntity *localSceneEnt,
    const DObj_s *obj,
    DObjAnimMat *boneMatrix,
    int waitForCullState);
int  R_SkinSceneDObjModels(
    GfxSceneEntity *sceneEnt,
    const DObj_s *obj,
    DObjAnimMat *boneMatrix);
void __cdecl R_SkinGfxEntityCmd(GfxSceneEntity **data);
