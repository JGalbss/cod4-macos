// Native macOS presentation for the POSIX engine target.
//
// SDL creates the NSWindow and CAMetalLayer, but all rendering below goes
// directly through Metal. There is no D3D/Vulkan compatibility layer in this
// path. It currently consumes the engine's 2D command stream; the same device,
// layer and frame lifecycle are the foundation for the scene renderer.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

#include "posix_gl_present.h"

#include "DynEntity/DynEntity_client.h"
#include "cgame_mp/cg_local_mp.h"
#include "gfx_d3d/r_font.h"
#include "gfx_d3d/r_buffers.h"
#include "gfx_d3d/r_add_staticmodel.h"
#include "gfx_d3d/r_dobj_skin.h"
#include "gfx_d3d/r_drawsurf.h"
#include "gfx_d3d/r_dvars.h"
#include "gfx_d3d/r_dpvs.h"
#include "gfx_d3d/r_gfx.h"
#include "gfx_d3d/r_init.h"
#include "gfx_d3d/r_material.h"
#include "gfx_d3d/r_model.h"
#include "gfx_d3d/r_model_lighting.h"
#include "gfx_d3d/r_rendercmds.h"
#include "gfx_d3d/r_scene.h"
#include "gfx_d3d/r_state.h"
#include "gfx_d3d/r_utils.h"
#include "gfx_d3d/r_water.h"
#include "gfx_d3d/r_workercmds.h"
#include "gfx_d3d/rb_backend.h"
#include "gfx_d3d/rb_light.h"
#include "gfx_d3d/rb_tess.h"
#include "posix/posix_input.h"
#include "qcommon/com_pack.h"
#include "qcommon/cmd.h"
#include "qcommon/qcommon.h"
#include "ui/keycodes.h"
#include "universal/com_files.h"
#include "win32/win_local.h"
#include "xanim/dobj.h"
#include "xanim/dobj_utils.h"
#include "xanim/xmodel.h"

#include <SDL.h>
#include <SDL_metal.h>

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <sys/stat.h>
#include <unordered_map>
#include <vector>

namespace posix_gl {
namespace {

SDL_Window *g_window = nullptr;
std::atomic<unsigned long long> g_requestedWindowSize{0};
SDL_MetalView g_metalView = nullptr;
id<NSObject> g_processActivity = nil;
constexpr MTLPixelFormat kDrawableFormat = MTLPixelFormatBGRA8Unorm_sRGB;
CAMetalLayer *g_layer = nil;
id<MTLDevice> g_device = nil;
id<MTLCommandQueue> g_queue = nil;
id<MTLLibrary> g_shaderLibrary = nil;
id<MTLRenderPipelineState> g_flatPipeline = nil;
id<MTLRenderPipelineState> g_imagePipeline = nil;
id<MTLRenderPipelineState> g_glyphPipeline = nil;
id<MTLRenderPipelineState> g_worldPipeline = nil;
id<MTLRenderPipelineState> g_worldBlendPipeline = nil;
id<MTLRenderPipelineState> g_worldAdditivePipeline = nil;
id<MTLRenderPipelineState> g_waterPipeline = nil;
id<MTLRenderPipelineState> g_modelPipeline = nil;
id<MTLRenderPipelineState> g_modelBlendPipeline = nil;
id<MTLRenderPipelineState> g_modelAdditivePipeline = nil;
id<MTLRenderPipelineState> g_effectPipeline = nil;
id<MTLRenderPipelineState> g_effectAdditivePipeline = nil;
id<MTLRenderPipelineState> g_skyPipeline = nil;
id<MTLRenderPipelineState> g_shadowWorldPipeline = nil;
id<MTLRenderPipelineState> g_shadowWorldAlphaPipeline = nil;
id<MTLRenderPipelineState> g_shadowModelPipeline = nil;
id<MTLRenderPipelineState> g_shadowModelAlphaPipeline = nil;
id<MTLRenderPipelineState> g_filmPipeline = nil;
id<MTLRenderPipelineState> g_gammaPipeline = nil;
id<MTLRenderPipelineState> g_glowSetupPipeline = nil;
id<MTLRenderPipelineState> g_gaussianPipeline = nil;
id<MTLRenderPipelineState> g_gaussian2DPipeline = nil;
id<MTLRenderPipelineState> g_dofDownsamplePipeline = nil;
id<MTLRenderPipelineState> g_dofNearCocPipeline = nil;
id<MTLRenderPipelineState> g_dofSmallBlurPipeline = nil;
id<MTLRenderPipelineState> g_dofCompositePipeline = nil;
id<MTLRenderPipelineState> g_feedbackBlendPipeline = nil;
id<MTLRenderPipelineState> g_shellShockBlurredPipeline = nil;
id<MTLRenderPipelineState> g_shellShockFlashedPipeline = nil;
id<MTLDepthStencilState> g_worldDepthState = nil;
id<MTLDepthStencilState> g_viewModelDepthState = nil;
id<MTLDepthStencilState> g_effectDepthState = nil;
id<MTLDepthStencilState> g_transparentDepthState = nil;
id<MTLDepthStencilState> g_disabledDepthState = nil;
id<MTLSamplerState> g_sampler = nil;
id<MTLSamplerState> g_worldSampler = nil;
id<MTLSamplerState> g_lightmapSampler = nil;
id<MTLSamplerState> g_modelLightSampler = nil;
id<MTLSamplerState> g_shadowSampler = nil;
id<MTLTexture> g_whiteTexture = nil;
id<MTLTexture> g_modelLightTexture = nil;
id<MTLTexture> g_depthTexture = nil;
id<MTLTexture> g_sceneColorTexture = nil;
id<MTLTexture> g_postColorTexture = nil;
id<MTLTexture> g_glowTexture[2] = {nil, nil};
id<MTLTexture> g_dofColorTexture = nil;
id<MTLTexture> g_dofTexture[3] = {nil, nil, nil};
id<MTLTexture> g_savedScreenTexture = nil;
id<MTLTexture> g_resolvedSceneTexture = nil;
id<MTLTexture> g_resolvedDepthTexture = nil;
id<MTLTexture> g_sunShadowTexture = nil;
id<MTLBuffer> g_worldVertexBuffer = nil;
id<MTLBuffer> g_worldIndexBuffer = nil;
const GfxWorld *g_bufferedWorld = nullptr;
const GfxWorld *g_modelLightWorld = nullptr;
unsigned int g_modelLightHeight = 0;
bool g_modelLightTextureNeedsClear = false;
bool g_ready = false;
bool g_dumpRequested = false;
bool g_hideUi = false;
bool g_autoJoin = false;
bool g_traceRenderer = false;
bool g_profileRenderer = false;
bool g_dumpedFirstWorldView = false;
int g_dumpCount = 0;
int g_frameCount = 0;
int g_dumpFrame = -1;
int g_worldSeenFrame = -1;
int g_profilePlayableFrame = -1;
const char *g_dumpPath = nullptr;
int g_viewportWidth = 1280;
int g_viewportHeight = 720;
int g_uiWidth = 1280;
int g_uiHeight = 720;
int g_displayFrequency = 60;
MTLClearColor g_clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

std::atomic<uint64_t> g_profileGpuNanoseconds{0};
std::atomic<uint64_t> g_profileGpuSamples{0};
std::atomic<uint64_t> g_profileGpuMaxNanoseconds{0};
double g_profileCpuMilliseconds = 0.0;
double g_profileAcquireMilliseconds = 0.0;
double g_profileFrameMilliseconds = 0.0;
double g_profileCpuMaxMilliseconds = 0.0;
double g_profileAcquireMaxMilliseconds = 0.0;
double g_profileFrameMaxMilliseconds = 0.0;
double g_profilePreviousViewStart = 0.0;
unsigned int g_profileViewFrames = 0;
unsigned int g_profileFrameSamples = 0;
unsigned int g_profileFramesOver8Milliseconds = 0;
unsigned int g_profileFramesOver16Milliseconds = 0;

enum MetalProfilePass : unsigned int
{
    PROFILE_PASS_SETUP,
    PROFILE_PASS_SKY,
    PROFILE_PASS_WORLD,
    PROFILE_PASS_STATIC_MODELS,
    PROFILE_PASS_DYNAMIC_ENTITIES,
    PROFILE_PASS_SCENE_BRUSHES,
    PROFILE_PASS_SCENE_MODELS,
    PROFILE_PASS_EFFECTS,
    PROFILE_PASS_POST,
    PROFILE_PASS_UI,
    PROFILE_PASS_GAMMA,
    PROFILE_PASS_COUNT,
};

double g_profilePassMilliseconds[PROFILE_PASS_COUNT] = {};
double g_profilePassMaxMilliseconds[PROFILE_PASS_COUNT] = {};

// Apple GPUs use argument tables internally. Re-emitting an unchanged texture
// or sampler still dirties that table and showed up prominently in the native
// profile. Keep this cache scoped to the current render encoder; callers that
// bind a different shader family invalidate it explicitly.
id<MTLRenderCommandEncoder> g_materialBindingEncoder = nil;
constexpr NSUInteger kMaterialTextureSlotCount = 13;
constexpr NSUInteger kMaterialSamplerSlotCount = 10;
id<MTLTexture> g_materialBoundTextures[kMaterialTextureSlotCount] = {};
id<MTLSamplerState> g_materialBoundSamplers[kMaterialSamplerSlotCount] = {};
bool g_materialTextureKnown[kMaterialTextureSlotCount] = {};
bool g_materialSamplerKnown[kMaterialSamplerSlotCount] = {};

// Metal validates and records every state setter even when the value is
// unchanged.  A typical exterior frame contains well over a thousand IW3
// surfaces, so faithfully replaying the D3D state stream without this cache
// wastes a measurable amount of CPU time.  Keep the cache encoder-local:
// render-command encoders do not inherit state from one another.
id<MTLRenderCommandEncoder> g_renderStateEncoder = nil;
id<MTLRenderPipelineState> g_renderStatePipeline = nil;
id<MTLDepthStencilState> g_renderStateDepth = nil;
MTLCullMode g_renderStateCullMode = MTLCullModeNone;
MTLViewport g_renderStateViewport{};
bool g_renderStatePipelineKnown = false;
bool g_renderStateDepthKnown = false;
bool g_renderStateCullKnown = false;
bool g_renderStateViewportKnown = false;

void BeginRenderState(id<MTLRenderCommandEncoder> encoder)
{
    if (g_renderStateEncoder == encoder)
        return;
    g_renderStateEncoder = encoder;
    g_renderStatePipeline = nil;
    g_renderStateDepth = nil;
    g_renderStatePipelineKnown = false;
    g_renderStateDepthKnown = false;
    g_renderStateCullKnown = false;
    g_renderStateViewportKnown = false;
}

void SetCachedRenderPipeline(id<MTLRenderCommandEncoder> encoder,
                             id<MTLRenderPipelineState> pipeline)
{
    BeginRenderState(encoder);
    if (g_renderStatePipelineKnown && g_renderStatePipeline == pipeline)
        return;
    [encoder setRenderPipelineState:pipeline];
    g_renderStatePipeline = pipeline;
    g_renderStatePipelineKnown = true;
}

void SetCachedDepthState(id<MTLRenderCommandEncoder> encoder,
                         id<MTLDepthStencilState> depth)
{
    BeginRenderState(encoder);
    if (g_renderStateDepthKnown && g_renderStateDepth == depth)
        return;
    [encoder setDepthStencilState:depth];
    g_renderStateDepth = depth;
    g_renderStateDepthKnown = true;
}

void SetCachedCullMode(id<MTLRenderCommandEncoder> encoder, const MTLCullMode mode)
{
    BeginRenderState(encoder);
    if (g_renderStateCullKnown && g_renderStateCullMode == mode)
        return;
    [encoder setCullMode:mode];
    g_renderStateCullMode = mode;
    g_renderStateCullKnown = true;
}

void SetCachedViewport(id<MTLRenderCommandEncoder> encoder, const MTLViewport viewport)
{
    BeginRenderState(encoder);
    if (g_renderStateViewportKnown
        && g_renderStateViewport.originX == viewport.originX
        && g_renderStateViewport.originY == viewport.originY
        && g_renderStateViewport.width == viewport.width
        && g_renderStateViewport.height == viewport.height
        && g_renderStateViewport.znear == viewport.znear
        && g_renderStateViewport.zfar == viewport.zfar)
    {
        return;
    }
    [encoder setViewport:viewport];
    g_renderStateViewport = viewport;
    g_renderStateViewportKnown = true;
}

void InvalidateMaterialBindings()
{
    g_materialBindingEncoder = nil;
    for (NSUInteger index = 0; index < kMaterialTextureSlotCount; ++index)
    {
        g_materialBoundTextures[index] = nil;
        g_materialTextureKnown[index] = false;
    }
    for (NSUInteger index = 0; index < kMaterialSamplerSlotCount; ++index)
    {
        g_materialBoundSamplers[index] = nil;
        g_materialSamplerKnown[index] = false;
    }
}

void BeginMaterialBindings(id<MTLRenderCommandEncoder> encoder)
{
    if (g_materialBindingEncoder == encoder)
        return;
    InvalidateMaterialBindings();
    g_materialBindingEncoder = encoder;
}

void SetMaterialFragmentTexture(id<MTLRenderCommandEncoder> encoder,
                                id<MTLTexture> texture, const NSUInteger index)
{
    iassert(index < kMaterialTextureSlotCount);
    BeginMaterialBindings(encoder);
    if (g_materialTextureKnown[index] && g_materialBoundTextures[index] == texture)
        return;
    [encoder setFragmentTexture:texture atIndex:index];
    g_materialBoundTextures[index] = texture;
    g_materialTextureKnown[index] = true;
}

void SetMaterialFragmentSampler(id<MTLRenderCommandEncoder> encoder,
                                id<MTLSamplerState> sampler, const NSUInteger index)
{
    iassert(index < kMaterialSamplerSlotCount);
    BeginMaterialBindings(encoder);
    if (g_materialSamplerKnown[index] && g_materialBoundSamplers[index] == sampler)
        return;
    [encoder setFragmentSamplerState:sampler atIndex:index];
    g_materialBoundSamplers[index] = sampler;
    g_materialSamplerKnown[index] = true;
}

enum class QuadMode : uint8_t
{
    Flat,
    Image,
    Glyph,
};

struct UiVertex
{
    float position[2];
    float uv[2];
    float color[4];
};

struct UiBatch
{
    QuadMode mode;
    id<MTLTexture> texture;
    size_t firstVertex;
    size_t vertexCount;
};

struct MetalWorldVertex
{
    float position[3];
    float positionPadding;
    float uv[2];
    float lightmapUv[2];
    float color[4];
    float normal[3];
    float binormalSign;
    float tangent[3];
    float tangentPadding;
};

struct alignas(16) MetalMaterialParams
{
    uint32_t flags;
    uint32_t alphaTest;
    uint32_t dynamicLightCount;
    uint32_t padding;
    float envMapParms[4];
    float cameraOrigin[4];
    float sunDirection[4];
    float sunColor[4];
    float sunSpecular[4];
    float modelLightBase[4];
    float modelLightScale[4];
    float fog[4];
    float fogColor[4];
    float detailScale[4];
    float shadowMatrix[2][16];
    float shadowParams[4];
    float dynamicLightPosition[4][4];
    float dynamicLightColorType[4][4];
    float dynamicLightDirectionExponent[4][4];
    float dynamicLightSpotFactors[4][4];
};

struct alignas(16) MetalShadowParams
{
    uint32_t alphaTest;
    uint32_t padding[3];
};

struct alignas(16) MetalFilmParams
{
    uint32_t enabled;
    uint32_t glowEnabled;
    uint32_t padding[2];
    float colorBias[4];
    float colorTintBase[4];
    float colorTintDelta[4];
    float glowApply[4];
};

struct alignas(16) MetalGammaParams
{
    float exponent;
    float padding[3];
};

struct alignas(16) MetalGlowSetupParams
{
    float sceneInvSize[2];
    float bloomCutoff;
    float bloomCutoffRescale;
    float bloomDesaturation;
    float padding[3];
    float colorBias[4];
    float colorTintBase[4];
    float colorTintDelta[4];
};

struct alignas(16) MetalGaussianParams
{
    float direction[2];
    uint32_t tapCount;
    uint32_t padding;
    float taps[8][4];
};

struct alignas(16) MetalGaussian2DParams
{
    uint32_t tapCount;
    uint32_t padding[3];
    float taps[8][4];
};

struct alignas(16) MetalDofParams
{
    float sceneInvSize[2];
    float zNear;
    float depthHackNear;
    float maxDepth;
    float padding[3];
    float sceneEquation[4];
    float viewModelEquation[4];
    float lerpScale[4];
    float lerpBias[4];
};

struct alignas(16) MetalShellShockParams
{
    float uvOrigin[2];
    float uvSize[2];
    float color[4];
};

enum MetalMaterialFlags : uint32_t
{
    METAL_MATERIAL_PRIMARY_LIGHTMAP = 1u,
    METAL_MATERIAL_NORMAL_MAP = 2u,
    METAL_MATERIAL_SPECULAR_MAP = 4u,
    METAL_MATERIAL_REFLECTION_MAP = 8u,
    METAL_MATERIAL_SECONDARY_LIGHTMAP = 16u,
    METAL_MATERIAL_MODEL_LIGHT = 32u,
    METAL_MATERIAL_MODEL_SUN = 64u,
    METAL_MATERIAL_DETAIL_MAP = 128u,
    METAL_MATERIAL_SUN_SHADOW = 256u,
    // Lit decal materials use the diffuse/vertex alpha as their blend mask.
    // Opaque world/model passes keep the legacy forced-one framebuffer alpha.
    METAL_MATERIAL_PRESERVE_ALPHA = 512u,
};

enum class WorldShaderMode : uint8_t
{
    Lit,
    Simple,
    SimpleFog,
    AddFog,
    Multiply,
};

struct alignas(16) MetalEffectParams
{
    uint32_t flags;
    float zNear;
    float maxDepth;
    float featherInvDistance;
    float viewportInvSize[2];
    float distortionScale[2];
    float cameraOrigin[4];
    float fog[4];
    float fogColor[4];
    float falloffParms[4];
    float falloffBeginColor[4];
    float falloffEndColor[4];
};

struct alignas(16) MetalWaterParams
{
    float cameraOrigin[4];
    float envMapParms[4];
    float waterColor[4];
    float fog[4];
    float fogColor[4];
    float sunDirection[4];
    float sunColor[4];
};

enum MetalEffectFlags : uint32_t
{
    METAL_EFFECT_ZFEATHER = 1u,
    METAL_EFFECT_DISTORTION = 2u,
    METAL_EFFECT_PREMULTIPLY_ALPHA = 4u,
    METAL_EFFECT_FALLOFF = 8u,
    METAL_EFFECT_FOG = 16u,
    METAL_EFFECT_ATEST_GT_ZERO = 32u,
    METAL_EFFECT_ATEST_LT_HALF = 64u,
    METAL_EFFECT_ATEST_GE_HALF = 128u,
};

struct ModelSurfaceBuffers
{
    void *vertices;
    void *indices;
};

struct WaterTextureCache
{
    void *texture;
    int updatedFrame;
};

enum class SavedScreenCommandType : uint8_t
{
    Save,
    SaveSection,
    BlendBlurred,
    BlendFlashed,
};

struct SavedScreenCommand
{
    SavedScreenCommandType type;
    int screenTimerId;
    int fadeMsec;
    float s0;
    float t0;
    float ds;
    float dt;
    float whiteout;
    float screengrab;
};

std::vector<UiVertex> g_vertices;
std::vector<UiBatch> g_batches;
std::vector<SavedScreenCommand> g_savedScreenCommands;
int g_savedScreenTimes[4] = {};
bool g_savedScreenValid[4] = {};
const GfxWorld *g_savedScreenWorld = nullptr;
int g_savedScreenLocalClientNum = -1;
int g_savedScreenServerId = INT_MIN;
int g_savedScreenLastSceneTime = INT_MIN;
std::unordered_map<const GfxImage *, void *> g_textures;
std::unordered_map<const GfxImage *, void *> g_linearTextures;
std::unordered_map<const GfxImage *, void *> g_skyTextures;
std::unordered_map<unsigned int, void *> g_materialSamplers;
std::unordered_map<const XSurface *, ModelSurfaceBuffers> g_modelSurfaceBuffers;
std::unordered_map<uint64_t, void *> g_effectMaterialPipelines;
std::unordered_map<uint64_t, void *> g_worldMaterialPipelines;
std::unordered_map<uint32_t, void *> g_materialDepthStates;
std::unordered_map<const water_t *, WaterTextureCache> g_waterTextures;

void ReleaseRetainedMetalObject(void *object)
{
    if (!object)
        return;
    // Cache entries are inserted with __bridge_retained. Transfer that single
    // ownership back to ARC so it is released at the end of this scope; in-flight
    // Metal command buffers retain any resources they still reference.
    id transferred = (__bridge_transfer id)object;
    (void)transferred;
}

bool HasValidSavedScreen()
{
    return std::any_of(std::begin(g_savedScreenValid), std::end(g_savedScreenValid),
                       [](const bool valid) { return valid; });
}

void InvalidateSavedScreenHistory(const char *reason)
{
    const bool hadValidScreen = HasValidSavedScreen();
    std::fill(std::begin(g_savedScreenTimes), std::end(g_savedScreenTimes), 0);
    std::fill(std::begin(g_savedScreenValid), std::end(g_savedScreenValid), false);
    g_savedScreenWorld = nullptr;
    g_savedScreenLocalClientNum = -1;
    g_savedScreenServerId = INT_MIN;
    g_savedScreenLastSceneTime = INT_MIN;
    if (hadValidScreen && g_traceRenderer)
        Com_Printf(8, "[metal] invalidated saved shellshock screen: %s\n", reason);
}

void ValidateSavedScreenHistoryForFrame(const GfxViewInfo *view)
{
    if (!HasValidSavedScreen())
        return;

    const char *reason = nullptr;
    if (g_savedScreenCommands.empty())
        reason = "command stream ended";
    else if (!view)
        reason = "3D view ended";
    else if (!rgp.world || g_savedScreenWorld != rgp.world)
        reason = "world changed";
    else if (view->localClientNum != g_savedScreenLocalClientNum)
        reason = "local client changed";
    else if (view->localClientNum < 0 || view->localClientNum >= STATIC_MAX_LOCAL_CLIENTS
             || clientUIActives[view->localClientNum].connectionState != CA_ACTIVE
             || !clientUIActives[view->localClientNum].cgameInitialized)
        reason = "client session ended";
    else if (clients[view->localClientNum].serverId != g_savedScreenServerId)
        reason = "server session changed";
    else if (view->sceneDef.time < g_savedScreenLastSceneTime)
        reason = "scene time moved backwards";

    if (reason)
        InvalidateSavedScreenHistory(reason);
    else
        g_savedScreenLastSceneTime = view->sceneDef.time;
}

void ClearLevelResourceCaches()
{
    for (const auto &entry : g_textures)
        ReleaseRetainedMetalObject(entry.second);
    g_textures.clear();
    for (const auto &entry : g_linearTextures)
        ReleaseRetainedMetalObject(entry.second);
    g_linearTextures.clear();
    for (const auto &entry : g_skyTextures)
        ReleaseRetainedMetalObject(entry.second);
    g_skyTextures.clear();
    for (const auto &entry : g_modelSurfaceBuffers)
    {
        ReleaseRetainedMetalObject(entry.second.vertices);
        ReleaseRetainedMetalObject(entry.second.indices);
    }
    g_modelSurfaceBuffers.clear();
    for (const auto &entry : g_waterTextures)
        ReleaseRetainedMetalObject(entry.second.texture);
    g_waterTextures.clear();

    // A zone allocator may reuse both the GfxWorld and asset addresses on the
    // next map. Force all pointer-identity checks to rebuild from the new zone.
    g_worldVertexBuffer = nil;
    g_worldIndexBuffer = nil;
    g_bufferedWorld = nullptr;
    g_modelLightTexture = nil;
    g_modelLightWorld = nullptr;
    g_modelLightHeight = 0;
    g_modelLightTextureNeedsClear = false;
    InvalidateSavedScreenHistory("level resources cleared");
}

id<MTLRenderPipelineState> EffectPipelineForMaterial(const Material *material, int region);
id<MTLTexture> TextureForReflectionProbe(unsigned int reflectionProbeIndex);
id<MTLRenderPipelineState> WorldPipelineForMaterial(
    const Material *material, uint32_t stateBits, bool model);
id<MTLDepthStencilState> DepthStateForMaterial(uint32_t stateBits);

constexpr int kIwiHeaderSize = 28;
constexpr unsigned kFmtDxt1 = 0x31545844; // 'DXT1'
constexpr unsigned kFmtDxt3 = 0x33545844; // 'DXT3'
constexpr unsigned kFmtDxt5 = 0x35545844; // 'DXT5'
constexpr unsigned kFmtA8R8G8B8 = 21;
constexpr unsigned kFmtX8R8G8B8 = 22;
constexpr unsigned kFmtA8 = 28;
constexpr unsigned kFmtL8 = 50;
constexpr unsigned kFmtA8L8 = 51;

struct TextureLayout
{
    MTLPixelFormat format;
    int blockBytes;
    int pixelBytes;
    bool compressed;
};

bool IsSrgbImage(const GfxImage *image)
{
    if (!image || image->category == IMG_CATEGORY_LIGHTMAP)
        return false;
    return image->semantic == TS_2D || image->semantic == TS_COLOR_MAP;
}

MTLPixelFormat SrgbFormat(const MTLPixelFormat format)
{
    switch (format)
    {
    case MTLPixelFormatBC1_RGBA: return MTLPixelFormatBC1_RGBA_sRGB;
    case MTLPixelFormatBC2_RGBA: return MTLPixelFormatBC2_RGBA_sRGB;
    case MTLPixelFormatBC3_RGBA: return MTLPixelFormatBC3_RGBA_sRGB;
    case MTLPixelFormatBGRA8Unorm: return MTLPixelFormatBGRA8Unorm_sRGB;
    case MTLPixelFormatRGBA8Unorm: return MTLPixelFormatRGBA8Unorm_sRGB;
    default: return format;
    }
}

bool LayoutForFormat(const unsigned format, TextureLayout *out)
{
    switch (format)
    {
    case kFmtDxt1:     *out = {MTLPixelFormatBC1_RGBA, 8, 0, true}; return true;
    case kFmtDxt3:     *out = {MTLPixelFormatBC2_RGBA, 16, 0, true}; return true;
    case kFmtDxt5:     *out = {MTLPixelFormatBC3_RGBA, 16, 0, true}; return true;
    case kFmtA8R8G8B8: *out = {MTLPixelFormatBGRA8Unorm, 0, 4, false}; return true;
    // IWI bitmap-RGB payloads are tightly packed BGR; expand to BGRA on upload.
    case kFmtX8R8G8B8: *out = {MTLPixelFormatBGRA8Unorm, 0, 3, false}; return true;
    case kFmtA8:       *out = {MTLPixelFormatA8Unorm, 0, 1, false}; return true;
    case kFmtL8:       *out = {MTLPixelFormatR8Unorm, 0, 1, false}; return true;
    case kFmtA8L8:     *out = {MTLPixelFormatRG8Unorm, 0, 2, false}; return true;
    default: return false;
    }
}

int LevelBytes(const int width, const int height, const TextureLayout &layout)
{
    if (layout.compressed)
        return ((width + 3) / 4) * ((height + 3) / 4) * layout.blockBytes;
    return width * height * layout.pixelBytes;
}

bool InferLayout(const int width, const int height, const int available, TextureLayout *out)
{
    static constexpr unsigned candidates[] = {
        kFmtDxt1, kFmtDxt5, kFmtA8L8, kFmtA8R8G8B8, kFmtX8R8G8B8, kFmtA8,
    };
    for (const unsigned candidate : candidates)
    {
        TextureLayout layout{};
        if (LayoutForFormat(candidate, &layout) && LevelBytes(width, height, layout) == available)
        {
            *out = layout;
            return true;
        }
    }
    return false;
}

int ExactMipCountForBytes(const int width, const int height, const TextureLayout &layout,
                          const int byteCount)
{
    int total = 0;
    int count = 0;
    for (int w = width, h = height; count < 16; w = std::max(1, w >> 1),
         h = std::max(1, h >> 1))
    {
        total += LevelBytes(w, h, layout);
        ++count;
        if (total == byteCount)
            return count;
        if (total > byteCount || (w == 1 && h == 1))
            break;
    }
    return 0;
}

id<MTLTexture> UploadTexture(const int width, const int height, const TextureLayout &layout,
                             const unsigned char *pixels, const int byteCount,
                             const bool srgb = false, const int requestedMipCount = 1,
                             const bool smallestFirst = false)
{
    if (!g_device || !pixels || width <= 0 || height <= 0 || byteCount <= 0)
        return nil;

    MTLPixelFormat uploadFormat = layout.format;
    int uploadPixelBytes = layout.pixelBytes;
    const bool expandLuminanceAlpha = !layout.compressed && layout.format == MTLPixelFormatRG8Unorm;
    const bool expandOpaqueBgr = !layout.compressed && layout.format == MTLPixelFormatBGRA8Unorm
        && layout.pixelBytes == 3;
    if (expandLuminanceAlpha || expandOpaqueBgr)
    {
        uploadFormat = MTLPixelFormatBGRA8Unorm;
        uploadPixelBytes = 4;
    }
    if (srgb)
        uploadFormat = SrgbFormat(uploadFormat);

    const int maxMipCount = 1 + static_cast<int>(std::floor(std::log2(
        static_cast<double>(std::max(width, height)))));
    const int mipCount = std::max(1, std::min(requestedMipCount, maxMipCount));

    std::vector<int> sourceSizes(mipCount);
    std::vector<int> sourceOffsets(mipCount);
    int requiredBytes = 0;
    for (int mip = 0; mip < mipCount; ++mip)
    {
        sourceSizes[mip] = LevelBytes(std::max(1, width >> mip),
                                      std::max(1, height >> mip), layout);
        requiredBytes += sourceSizes[mip];
    }
    if (requiredBytes > byteCount)
        return nil;
    int cursor = 0;
    if (smallestFirst)
    {
        for (int mip = mipCount - 1; mip >= 0; --mip)
        {
            sourceOffsets[mip] = cursor;
            cursor += sourceSizes[mip];
        }
    }
    else
    {
        for (int mip = 0; mip < mipCount; ++mip)
        {
            sourceOffsets[mip] = cursor;
            cursor += sourceSizes[mip];
        }
    }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:uploadFormat
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:mipCount > 1];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [g_device newTextureWithDescriptor:desc];
    if (!texture)
        return nil;

    // D3DFMT_A8L8 is stored as L,A. Sampling it as RG exposes alpha as green,
    // which caused the original neon-green UI. Expand every mip to BGRA.
    std::vector<unsigned char> expanded;
    for (int mip = 0; mip < mipCount; ++mip)
    {
        const int mipWidth = std::max(1, width >> mip);
        const int mipHeight = std::max(1, height >> mip);
        const unsigned char *uploadPixels = pixels + sourceOffsets[mip];
        if (expandLuminanceAlpha)
        {
            expanded.resize(static_cast<size_t>(mipWidth) * mipHeight * 4);
            for (int i = 0; i < mipWidth * mipHeight; ++i)
            {
                const unsigned char luminance = uploadPixels[i * 2];
                expanded[i * 4 + 0] = luminance;
                expanded[i * 4 + 1] = luminance;
                expanded[i * 4 + 2] = luminance;
                expanded[i * 4 + 3] = uploadPixels[i * 2 + 1];
            }
            uploadPixels = expanded.data();
        }
        else if (expandOpaqueBgr)
        {
            expanded.resize(static_cast<size_t>(mipWidth) * mipHeight * 4);
            for (int i = 0; i < mipWidth * mipHeight; ++i)
            {
                expanded[i * 4 + 0] = uploadPixels[i * 3 + 0];
                expanded[i * 4 + 1] = uploadPixels[i * 3 + 1];
                expanded[i * 4 + 2] = uploadPixels[i * 3 + 2];
                expanded[i * 4 + 3] = 255;
            }
            uploadPixels = expanded.data();
        }
        const NSUInteger bytesPerRow = layout.compressed
            ? static_cast<NSUInteger>((mipWidth + 3) / 4 * layout.blockBytes)
            : static_cast<NSUInteger>(mipWidth * uploadPixelBytes);
        [texture replaceRegion:MTLRegionMake2D(0, 0, mipWidth, mipHeight)
                   mipmapLevel:mip
                     withBytes:uploadPixels
                   bytesPerRow:bytesPerRow];
    }
    return texture;
}

id<MTLTexture> UploadCubeFromIwi(const GfxImage *image, const TextureLayout &layout)
{
    char path[256];
    Com_sprintf(path, sizeof(path), "images/%s.iwi", image->name);
    void *buffer = nullptr;
    const int length = FS_ReadFile(path, &buffer);
    if (length < kIwiHeaderSize || !buffer)
    {
        if (buffer)
            FS_FreeFile(static_cast<char *>(buffer));
        return nil;
    }

    const int faceBytes = LevelBytes(image->width, image->height, layout);
    const int cubeBytes = faceBytes * 6;
    const auto *const bytes = static_cast<const unsigned char *>(buffer);
    if (std::memcmp(bytes, "IWi", 3) != 0 || faceBytes <= 0 || cubeBytes > length - kIwiHeaderSize)
    {
        FS_FreeFile(static_cast<char *>(buffer));
        return nil;
    }

    // IWI stores cubemap mips from smallest to largest, with all six faces
    // adjacent at each level.  Therefore the six full-resolution faces are
    // the final cube-sized block in the file.
    const unsigned char *const topMip = bytes + length - cubeBytes;
    const MTLPixelFormat cubeFormat = IsSrgbImage(image) ? SrgbFormat(layout.format) : layout.format;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:cubeFormat
                                                                                  size:image->width
                                                                             mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [g_device newTextureWithDescriptor:desc];
    if (texture)
    {
        const NSUInteger bytesPerRow = layout.compressed
            ? static_cast<NSUInteger>((image->width + 3) / 4 * layout.blockBytes)
            : static_cast<NSUInteger>(image->width * layout.pixelBytes);
        for (int face = 0; face < 6; ++face)
        {
            [texture replaceRegion:MTLRegionMake2D(0, 0, image->width, image->height)
                       mipmapLevel:0
                              slice:face
                          withBytes:topMip + face * faceBytes
                        bytesPerRow:bytesPerRow
                      bytesPerImage:faceBytes];
        }
    }
    FS_FreeFile(static_cast<char *>(buffer));
    return texture;
}

id<MTLTexture> UploadCubeTexture(const GfxImage *image)
{
    if (!image || image->mapType != MAPTYPE_CUBE || !image->texture.loadDef)
        return nil;
    const GfxImageLoadDef *const loadDef = image->texture.loadDef;
    TextureLayout layout{};
    if (!LayoutForFormat(static_cast<unsigned int>(loadDef->format), &layout))
        return nil;
    if (loadDef->resourceSize <= 0)
        return UploadCubeFromIwi(image, layout);

    const int width = std::max(1, static_cast<int>(loadDef->dimensions[0]));
    const int height = std::max(1, static_cast<int>(loadDef->dimensions[1]));
    const int bytesPerFace = loadDef->resourceSize / 6;
    const int exactMipCount = loadDef->resourceSize % 6 == 0
        ? ExactMipCountForBytes(width, height, layout, bytesPerFace) : 0;
    // D3D's levelCount=0 requests a complete mip chain. Reflection probes use
    // that convention, so derive the actual count from their packed bytes.
    const int mipCount = exactMipCount > 0 ? exactMipCount
        : std::max(1, static_cast<int>(loadDef->levelCount));
    const MTLPixelFormat cubeFormat = IsSrgbImage(image) ? SrgbFormat(layout.format) : layout.format;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:cubeFormat
                                                                                  size:width
                                                                             mipmapped:mipCount > 1];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [g_device newTextureWithDescriptor:desc];
    if (!texture)
        return nil;

    // Fastfile cubemaps use the same face-major, then mip-major byte order as
    // the original Image_LoadTexture path.  Upload every real mip so Metal's
    // filtering behaves like the D3D renderer did.
    const unsigned char *data = loadDef->data;
    int remaining = loadDef->resourceSize;
    for (int face = 0; face < 6; ++face)
    {
        for (int mip = 0; mip < mipCount; ++mip)
        {
            const int mipWidth = std::max(1, width >> mip);
            const int mipHeight = std::max(1, height >> mip);
            const int byteCount = LevelBytes(mipWidth, mipHeight, layout);
            if (byteCount <= 0 || byteCount > remaining)
                return nil;
            const NSUInteger bytesPerRow = layout.compressed
                ? static_cast<NSUInteger>((mipWidth + 3) / 4 * layout.blockBytes)
                : static_cast<NSUInteger>(mipWidth * layout.pixelBytes);
            const NSUInteger bytesPerImage = static_cast<NSUInteger>(byteCount);
            [texture replaceRegion:MTLRegionMake2D(0, 0, mipWidth, mipHeight)
                       mipmapLevel:mip
                              slice:face
                          withBytes:data
                        bytesPerRow:bytesPerRow
                      bytesPerImage:bytesPerImage];
            data += byteCount;
            remaining -= byteCount;
        }
    }
    return texture;
}

id<MTLTexture> TextureForSkyImage(const GfxImage *image)
{
    if (!image)
        return nil;
    const auto found = g_skyTextures.find(image);
    if (found != g_skyTextures.end())
        return (__bridge id<MTLTexture>)found->second;
    id<MTLTexture> texture = UploadCubeTexture(image);
    void *retained = texture ? (__bridge_retained void *)texture : nullptr;
    g_skyTextures.emplace(image, retained);
    if (g_traceRenderer)
    {
        const GfxImageLoadDef *const loadDef = image->texture.loadDef;
        Com_Printf(8, "[metal] sky cubemap '%s': %ux%u faces=6 mips=%u format=%d resource=%d %s\n",
                   image->name ? image->name : "(unnamed)", image->width, image->height,
                   texture ? static_cast<unsigned int>(texture.mipmapLevelCount) : 0,
                   loadDef ? loadDef->format : -1,
                   loadDef ? loadDef->resourceSize : -1, texture ? "uploaded" : "FAILED");
    }
    return texture;
}

id<MTLTexture> UploadFromIwi(const GfxImage *image, const TextureLayout &declared,
                             const bool srgb)
{
    char path[256];
    Com_sprintf(path, sizeof(path), "images/%s.iwi", image->name);

    void *buffer = nullptr;
    const int length = FS_ReadFile(path, &buffer);
    if (length < kIwiHeaderSize || !buffer)
    {
        if (buffer)
            FS_FreeFile(static_cast<char *>(buffer));
        return nil;
    }

    const auto *bytes = static_cast<const unsigned char *>(buffer);
    id<MTLTexture> texture = nil;
    if (std::memcmp(bytes, "IWi", 3) == 0)
    {
        unsigned int mips[4] = {};
        std::memcpy(mips, bytes + 12, sizeof(mips));
        const int levelOffset = (mips[1] > 0 && mips[1] < mips[0])
            ? static_cast<int>(mips[1]) : kIwiHeaderSize;
        const int available = length - levelOffset;
        TextureLayout layout = declared;
        int wanted = LevelBytes(image->width, image->height, layout);
        if (wanted != available && InferLayout(image->width, image->height, available, &layout))
            wanted = LevelBytes(image->width, image->height, layout);
        if (wanted > 0 && levelOffset + wanted <= length)
        {
            // IWI6 writes the mip chain smallest-to-largest. Preserve it instead
            // of stretching the top mip across every distance, which caused the
            // severe crawling/shimmering on roads, walls and weapon materials.
            const int payloadBytes = length - kIwiHeaderSize;
            const int mipCount = ExactMipCountForBytes(image->width, image->height,
                                                        layout, payloadBytes);
            if (mipCount > 0)
            {
                texture = UploadTexture(image->width, image->height, layout,
                                        bytes + kIwiHeaderSize, payloadBytes,
                                        srgb, mipCount, true);
                if (g_traceRenderer && mipCount > 1)
                {
                    static int reportedMipChains = 0;
                    if (reportedMipChains++ < 16)
                        Com_Printf(8, "[metal] mip chain '%s': %dx%d, %d levels, %s\n",
                                   image->name ? image->name : "(unnamed)", image->width,
                                   image->height, mipCount, srgb ? "sRGB" : "linear");
                }
            }
            else
            {
                texture = UploadTexture(image->width, image->height, layout,
                                        bytes + levelOffset, wanted, srgb);
            }
        }
    }
    FS_FreeFile(static_cast<char *>(buffer));
    return texture;
}

id<MTLTexture> TextureForImage(const GfxImage *image, const bool forceLinear = false)
{
    if (!image || !image->width || !image->height)
        return nil;
    auto &cache = forceLinear ? g_linearTextures : g_textures;
    const auto found = cache.find(image);
    if (found != cache.end())
        return (__bridge id<MTLTexture>)found->second;

    id<MTLTexture> texture = nil;
    const bool srgb = !forceLinear && IsSrgbImage(image);
    const GfxImageLoadDef *loadDef = image->texture.loadDef;
    TextureLayout layout{};
    if (loadDef && LayoutForFormat(static_cast<unsigned>(loadDef->format), &layout))
    {
        if (loadDef->resourceSize > 0)
        {
            const int exactMipCount = ExactMipCountForBytes(image->width, image->height,
                                                             layout, loadDef->resourceSize);
            const int mipCount = exactMipCount > 0 ? exactMipCount
                : std::max(1, static_cast<int>(loadDef->levelCount));
            texture = UploadTexture(image->width, image->height, layout, loadDef->data,
                                    loadDef->resourceSize, srgb, mipCount);
        }
        else
            texture = UploadFromIwi(image, layout, srgb);
    }

    // Zone assets live for the process lifetime. Retain texture objects on the same
    // schedule; this also makes the cache independent of Objective-C autorelease pools.
    void *retained = texture ? (__bridge_retained void *)texture : nullptr;
    cache.emplace(image, retained);
    if (!texture && g_traceRenderer)
    {
        static int reportedFailures = 0;
        if (reportedFailures++ < 32)
            Com_Printf(8, "[metal] texture upload failed: '%s' %ux%u format=%d resource=%d\n",
                       image->name ? image->name : "(unnamed)", image->width, image->height,
                       loadDef ? loadDef->format : -1, loadDef ? loadDef->resourceSize : -1);
    }
    return texture;
}

const GfxImage *ImageForMaterialTextureDef(const MaterialTextureDef &def)
{
    // MaterialTextureDefInfo is a tagged union. Water maps store a water_t,
    // not a GfxImage, so reading u.image for that semantic corrupts both
    // diagnostics and fallback texture selection on 64-bit hosts.
    if (def.semantic == TS_WATER_MAP)
        return def.u.water ? def.u.water->image : nullptr;
    return def.u.image;
}

bool MaterialWantsTexture(const Material *material)
{
    if (!material || !material->textureTable)
        return false;
    for (int i = 0; i < material->textureCount; ++i)
    {
        if (material->textureTable[i].semantic == TS_2D
            && ImageForMaterialTextureDef(material->textureTable[i]))
            return true;
    }
    return false;
}

id<MTLTexture> TextureForMaterial(const Material *material)
{
    if (!material || !material->textureTable || !material->textureCount)
        return nil;
    for (int i = 0; i < material->textureCount; ++i)
    {
        const MaterialTextureDef &def = material->textureTable[i];
        if (def.semantic == TS_2D && ImageForMaterialTextureDef(def))
            return TextureForImage(ImageForMaterialTextureDef(def));
    }
    return TextureForImage(ImageForMaterialTextureDef(material->textureTable[0]));
}

id<MTLTexture> TextureForWorldMaterial(const Material *material,
                                       const bool forceLinear = false)
{
    if (!material || !material->textureTable)
        return g_whiteTexture;

    // World materials label the diffuse texture as TS_COLOR_MAP, whereas UI
    // materials use TS_2D. Prefer those semantics and avoid accidentally
    // displaying a normal or specular map as color.
    for (int semantic : {TS_COLOR_MAP, TS_2D})
    {
        for (int i = 0; i < material->textureCount; ++i)
        {
            const MaterialTextureDef &def = material->textureTable[i];
            if (def.semantic == semantic && ImageForMaterialTextureDef(def))
            {
                id<MTLTexture> texture = TextureForImage(
                    ImageForMaterialTextureDef(def), forceLinear);
                if (texture)
                    return texture;
            }
        }
    }
    if (g_traceRenderer)
    {
        static std::unordered_map<const Material *, bool> reported;
        if (reported.size() < 64 && reported.emplace(material, true).second)
        {
            Com_Printf(8, "[metal] material '%s' has no usable color map; textures:",
                       material->info.name ? material->info.name : "(unnamed)");
            for (int i = 0; i < material->textureCount; ++i)
            {
                const MaterialTextureDef &def = material->textureTable[i];
                const GfxImage *const image = ImageForMaterialTextureDef(def);
                Com_Printf(8, " [%u:%s]", def.semantic,
                           image && image->name ? image->name : "null");
            }
            Com_Printf(8, "\n");
        }
    }
    return g_whiteTexture;
}

const MaterialTextureDef *MaterialTextureForSemantic(const Material *material, const int semantic)
{
    if (!material || !material->textureTable)
        return nullptr;
    for (int i = 0; i < material->textureCount; ++i)
    {
        const MaterialTextureDef &def = material->textureTable[i];
        if (def.semantic == semantic)
            return &def;
    }
    return nullptr;
}

const MaterialTextureDef *MaterialTextureNamed(const Material *material, const char *name)
{
    if (!material || !material->textureTable || !name)
        return nullptr;
    const unsigned int nameHash = R_HashString(name);
    for (int i = 0; i < material->textureCount; ++i)
    {
        if (material->textureTable[i].nameHash == nameHash)
            return &material->textureTable[i];
    }
    return nullptr;
}

id<MTLTexture> TextureForMaterialSemantic(const Material *material, const int semantic)
{
    const MaterialTextureDef *const def = MaterialTextureForSemantic(material, semantic);
    if (def && ImageForMaterialTextureDef(*def))
        return TextureForImage(ImageForMaterialTextureDef(*def));
    return nil;
}

void DumpPixelShaderForDiagnostics(const MaterialPixelShader *shader)
{
    const char *const directory = std::getenv("KISAK_METAL_SHADER_DUMP_DIR");
    if (!directory || !directory[0] || !shader || !shader->name
        || !shader->prog.loadDef.program || !shader->prog.loadDef.programSize)
        return;
    static std::unordered_map<const MaterialPixelShader *, bool> dumped;
    if (!dumped.emplace(shader, true).second)
        return;

    mkdir(directory, 0755);
    char filename[256];
    size_t filenameLength = 0;
    for (const char *src = shader->name; *src && filenameLength + 1 < sizeof(filename); ++src)
    {
        const unsigned char c = static_cast<unsigned char>(*src);
        filename[filenameLength++] = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '.' || c == '-' ? static_cast<char>(c) : '_';
    }
    filename[filenameLength] = '\0';
    char path[1024];
    Com_sprintf(path, sizeof(path), "%s/%s.bin", directory, filename);
    FILE *const file = std::fopen(path, "wb");
    if (!file)
        return;
    const size_t tokenCount = shader->prog.loadDef.programSize;
    const size_t written = std::fwrite(shader->prog.loadDef.program, sizeof(uint32_t), tokenCount, file);
    std::fclose(file);
    if (written == tokenCount)
        Com_Printf(8, "[metal] dumped D3D9 pixel shader '%s' (%zu tokens) to %s\n",
                   shader->name, tokenCount, path);
}

void DumpVertexShaderForDiagnostics(const MaterialVertexShader *shader)
{
    const char *const directory = std::getenv("KISAK_METAL_SHADER_DUMP_DIR");
    if (!directory || !directory[0] || !shader || !shader->name
        || !shader->prog.loadDef.program || !shader->prog.loadDef.programSize)
        return;
    static std::unordered_map<const MaterialVertexShader *, bool> dumped;
    if (!dumped.emplace(shader, true).second)
        return;

    mkdir(directory, 0755);
    char filename[256];
    size_t filenameLength = 0;
    for (const char *src = shader->name; *src && filenameLength + 1 < sizeof(filename); ++src)
    {
        const unsigned char c = static_cast<unsigned char>(*src);
        filename[filenameLength++] = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '.' || c == '-' ? static_cast<char>(c) : '_';
    }
    filename[filenameLength] = '\0';
    char path[1024];
    Com_sprintf(path, sizeof(path), "%s/%s.vs.bin", directory, filename);
    FILE *const file = std::fopen(path, "wb");
    if (!file)
        return;
    const size_t tokenCount = shader->prog.loadDef.programSize;
    const size_t written = std::fwrite(shader->prog.loadDef.program, sizeof(uint32_t), tokenCount, file);
    std::fclose(file);
    if (written == tokenCount)
        Com_Printf(8, "[metal] dumped D3D9 vertex shader '%s' (%zu tokens) to %s\n",
                   shader->name, tokenCount, path);
}

void TraceMaterialTechnique(const Material *material)
{
    if (!g_traceRenderer || !material)
        return;
    static std::unordered_map<const Material *, bool> reported;
    const bool priorityMaterial = material->info.name
        && std::strstr(material->info.name, "fx_shell") != nullptr;
    if ((!priorityMaterial && reported.size() >= 256)
        || !reported.emplace(material, true).second)
        return;

    Com_Printf(8, "[metal] material '%s' techset='%s' flags=%02x sort=%u textures=%u:",
               material->info.name ? material->info.name : "(unnamed)",
               material->techniqueSet && material->techniqueSet->name
                   ? material->techniqueSet->name : "(none)",
               material->info.gameFlags, material->info.sortKey, material->textureCount);
    for (int i = 0; i < material->textureCount; ++i)
    {
        const MaterialTextureDef &texture = material->textureTable[i];
        const GfxImage *const image = ImageForMaterialTextureDef(texture);
        Com_Printf(8, " [%u/%02x:%s]", texture.semantic, texture.samplerState,
                   image && image->name ? image->name : "null");
    }
    for (int i = 0; i < material->constantCount; ++i)
    {
        const MaterialConstantDef &constant = material->constantTable[i];
        Com_Printf(8, " [const:%.*s=%g/%g/%g/%g]",
                   static_cast<int>(sizeof(constant.name)), constant.name,
                   constant.literal[0], constant.literal[1],
                   constant.literal[2], constant.literal[3]);
    }
    static constexpr MaterialTechniqueType types[] = {
        TECHNIQUE_BUILD_FLOAT_Z, TECHNIQUE_UNLIT, TECHNIQUE_EMISSIVE,
        TECHNIQUE_LIT, TECHNIQUE_LIT_SUN,
        TECHNIQUE_LIT_SPOT, TECHNIQUE_LIT_OMNI,
        TECHNIQUE_LIGHT_SPOT, TECHNIQUE_LIGHT_OMNI,
    };
    for (const MaterialTechniqueType type : types)
    {
        if (!material->techniqueSet)
            continue;
        const MaterialTechnique *const technique = material->techniqueSet->techniques[type];
        if (!technique || !technique->passCount)
            continue;
        const MaterialPass &pass = technique->passArray[0];
        const unsigned int stateEntry = material->stateBitsEntry[type];
        const GfxStateBits *const stateBits = stateEntry != UCHAR_MAX && material->stateBitsTable
            ? &material->stateBitsTable[stateEntry] : nullptr;
        DumpVertexShaderForDiagnostics(pass.vertexShader);
        DumpPixelShaderForDiagnostics(pass.pixelShader);
        Com_Printf(8, " {%u:%s vs=%s ps=%s(%u) state=%08x/%08x samplers=%02x args=%u/%u/%u",
                   static_cast<unsigned int>(type),
                   technique->name ? technique->name : "?",
                   pass.vertexShader && pass.vertexShader->name ? pass.vertexShader->name : "?",
                   pass.pixelShader && pass.pixelShader->name ? pass.pixelShader->name : "?",
                   pass.pixelShader ? pass.pixelShader->prog.loadDef.programSize : 0,
                   stateBits ? stateBits->loadBits[0] : 0,
                   stateBits ? stateBits->loadBits[1] : 0,
                   pass.customSamplerFlags, pass.perPrimArgCount,
                   pass.perObjArgCount, pass.stableArgCount);
        const unsigned int argCount = pass.perPrimArgCount + pass.perObjArgCount
            + pass.stableArgCount;
        for (unsigned int argIndex = 0; argIndex < argCount; ++argIndex)
        {
            const MaterialShaderArgument &arg = pass.args[argIndex];
            Com_Printf(8, "%s%u:%u:%08x", argIndex ? "," : " [",
                       arg.type, arg.dest,
                       static_cast<unsigned int>(arg.u.codeSampler));
        }
        Com_Printf(8, "%s}", argCount ? "]" : "");
    }
    Com_Printf(8, "\n");
}

void TraceEffectMaterial(const Material *material, const int region,
                         const FxCodeMeshData &codeMesh, const GfxMeshData &mesh,
                         const ptrdiff_t firstIndex, const unsigned int vertexCount)
{
    if (!g_traceRenderer || !material)
        return;
    static std::unordered_map<const Material *, bool> reported;
    if (reported.size() >= 128 || !reported.emplace(material, true).second)
        return;

    Com_Printf(8, "[metal] effect material '%s' techset='%s' region=%d sort=%u flags=%02x "
                  "tris=%u args=%u+%u textures=%u:",
               material->info.name ? material->info.name : "(unnamed)",
               material->techniqueSet && material->techniqueSet->name
                   ? material->techniqueSet->name : "(none)",
               region, material->info.sortKey, material->info.gameFlags,
               codeMesh.triCount, codeMesh.argOffset, codeMesh.argCount, material->textureCount);
    for (int i = 0; i < material->textureCount; ++i)
    {
        const MaterialTextureDef &texture = material->textureTable[i];
        const GfxImage *const image = ImageForMaterialTextureDef(texture);
        const GfxImageLoadDef *const loadDef = image ? image->texture.loadDef : nullptr;
        Com_Printf(8, " [%u/%02x:%s sem=%u %ux%u fmt=%d mips=%u bytes=%d]",
                   texture.semantic, texture.samplerState,
                   image && image->name ? image->name : "null",
                   image ? image->semantic : 0,
                   image ? image->width : 0, image ? image->height : 0,
                   loadDef ? loadDef->format : -1,
                   loadDef ? loadDef->levelCount : 0,
                   loadDef ? loadDef->resourceSize : -1);
    }
    for (int i = 0; i < material->constantCount; ++i)
    {
        const MaterialConstantDef &constant = material->constantTable[i];
        Com_Printf(8, " [const:%08x %.5g/%.5g/%.5g/%.5g]", constant.nameHash,
                   constant.literal[0], constant.literal[1],
                   constant.literal[2], constant.literal[3]);
    }

    static constexpr MaterialTechniqueType types[] = {
        TECHNIQUE_UNLIT, TECHNIQUE_EMISSIVE, TECHNIQUE_LIT,
    };
    for (const MaterialTechniqueType type : types)
    {
        const unsigned int entry = material->stateBitsEntry[type];
        if (entry == UCHAR_MAX || entry >= material->stateBitsCount)
            continue;
        const GfxStateBits &state = material->stateBitsTable[entry];
        const MaterialTechnique *const technique = material->techniqueSet
            ? material->techniqueSet->techniques[type] : nullptr;
        Com_Printf(8, " {tech=%u entry=%u passes=%u bits=%08x/%08x}",
                   static_cast<unsigned int>(type), entry,
                   technique ? technique->passCount : 0,
                   state.loadBits[0], state.loadBits[1]);
        if (technique && technique->passCount)
        {
            const MaterialPass &pass = technique->passArray[0];
            DumpVertexShaderForDiagnostics(pass.vertexShader);
            DumpPixelShaderForDiagnostics(pass.pixelShader);
            const unsigned int argCount = pass.perPrimArgCount + pass.perObjArgCount
                + pass.stableArgCount;
            Com_Printf(8, " shaders=%s/%s args=",
                       pass.vertexShader && pass.vertexShader->name
                           ? pass.vertexShader->name : "?",
                       pass.pixelShader && pass.pixelShader->name
                           ? pass.pixelShader->name : "?");
            for (unsigned int argIndex = 0; argIndex < argCount; ++argIndex)
            {
                const MaterialShaderArgument &arg = pass.args[argIndex];
                Com_Printf(8, "%s%u:%u:%08x", argIndex ? "," : "",
                           arg.type, arg.dest,
                           static_cast<unsigned int>(arg.u.codeSampler));
            }
        }
    }

    if (firstIndex >= 0 && static_cast<unsigned int>(firstIndex) < mesh.indexCount)
    {
        const unsigned int vertexIndex = mesh.indices[firstIndex];
        if (vertexIndex < vertexCount && mesh.vertSize >= sizeof(GfxPackedVertex))
        {
            const auto *const source = reinterpret_cast<const GfxPackedVertex *>(
                mesh.vb.cpuData + static_cast<size_t>(vertexIndex) * mesh.vertSize);
            float uv[2];
            Vec2UnpackTexCoords(source->texCoord, uv);
            Com_Printf(8, " sample=v%u xyz=(%.2f,%.2f,%.2f) uv=(%.3f,%.3f) "
                          "bgra=%02x/%02x/%02x/%02x",
                       vertexIndex, source->xyz[0], source->xyz[1], source->xyz[2],
                       uv[0], uv[1], source->color.array[0], source->color.array[1],
                       source->color.array[2], source->color.array[3]);

            float minimum[3] = {FLT_MAX, FLT_MAX, FLT_MAX};
            float maximum[3] = {-FLT_MAX, -FLT_MAX, -FLT_MAX};
            const unsigned int meshIndexCount = codeMesh.triCount * 3;
            for (unsigned int index = 0; index < meshIndexCount; ++index)
            {
                const unsigned int candidate = mesh.indices[firstIndex + index];
                if (candidate >= vertexCount)
                    continue;
                const auto *const vertex = reinterpret_cast<const GfxPackedVertex *>(
                    mesh.vb.cpuData + static_cast<size_t>(candidate) * mesh.vertSize);
                for (int axis = 0; axis < 3; ++axis)
                {
                    minimum[axis] = std::min(minimum[axis], vertex->xyz[axis]);
                    maximum[axis] = std::max(maximum[axis], vertex->xyz[axis]);
                }
            }
            Com_Printf(8, " bounds=(%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f)",
                       minimum[0], minimum[1], minimum[2],
                       maximum[0], maximum[1], maximum[2]);
        }
    }
    Com_Printf(8, "\n");
}

unsigned char SamplerStateForMaterial(const Material *material)
{
    if (!material || !material->textureTable)
        return SAMPLER_FILTER_LINEAR | SAMPLER_MIPMAP_LINEAR;
    for (int semantic : {TS_COLOR_MAP, TS_2D})
    {
        for (int i = 0; i < material->textureCount; ++i)
        {
            const MaterialTextureDef &def = material->textureTable[i];
            if (def.semantic == semantic)
                return def.samplerState;
        }
    }
    return SAMPLER_FILTER_LINEAR | SAMPLER_MIPMAP_LINEAR;
}

id<MTLSamplerState> SamplerForState(const unsigned int state)
{
    const auto found = g_materialSamplers.find(state);
    if (found != g_materialSamplers.end())
    {
        id<MTLSamplerState> cached = (__bridge id<MTLSamplerState>)found->second;
        return cached ? cached : g_worldSampler;
    }

    MTLSamplerDescriptor *descriptor = [MTLSamplerDescriptor new];
    const unsigned int filter = state & SAMPLER_FILTER_MASK;
    const bool nearest = filter == SAMPLER_FILTER_NEAREST;
    descriptor.minFilter = nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    descriptor.magFilter = nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    switch (state & SAMPLER_MIPMAP_MASK)
    {
    case SAMPLER_MIPMAP_NEAREST: descriptor.mipFilter = MTLSamplerMipFilterNearest; break;
    case SAMPLER_MIPMAP_LINEAR: descriptor.mipFilter = MTLSamplerMipFilterLinear; break;
    default: descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
    }
    descriptor.sAddressMode = (state & SAMPLER_CLAMP_U)
        ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
    descriptor.tAddressMode = (state & SAMPLER_CLAMP_V)
        ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
    descriptor.rAddressMode = (state & SAMPLER_CLAMP_W)
        ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
    if (!nearest && (state & SAMPLER_MIPMAP_MASK) != SAMPLER_MIPMAP_DISABLED)
        descriptor.maxAnisotropy = 16;
    id<MTLSamplerState> sampler = [g_device newSamplerStateWithDescriptor:descriptor];
    g_materialSamplers.emplace(state, sampler ? (__bridge_retained void *)sampler : nullptr);
    return sampler ? sampler : g_worldSampler;
}

id<MTLSamplerState> SamplerForMaterial(const Material *material)
{
    return SamplerForState(SamplerStateForMaterial(material));
}

uint32_t MaterialAlphaTest(const Material *material)
{
    if (!material || !material->stateBitsTable || !material->stateBitsCount)
        return 0;
    static constexpr MaterialTechniqueType techniques[] = {
        TECHNIQUE_LIT, TECHNIQUE_UNLIT, TECHNIQUE_EMISSIVE, TECHNIQUE_DEPTH_PREPASS,
    };
    for (const MaterialTechniqueType technique : techniques)
    {
        const unsigned int entry = material->stateBitsEntry[technique];
        if (entry == UCHAR_MAX || entry >= material->stateBitsCount)
            continue;
        const uint32_t bits = material->stateBitsTable[entry].loadBits[0];
        if ((bits & GFXS0_ATEST_DISABLE) != 0)
            return 0;
        switch (bits & GFXS0_ATEST_MASK)
        {
        case GFXS0_ATEST_GT_0: return 1;
        case GFXS0_ATEST_LT_128: return 2;
        case GFXS0_ATEST_GE_128: return 3;
        default: return 0;
        }
    }
    return 0;
}

enum class MaterialBlendMode : uint8_t
{
    Opaque,
    Alpha,
    Additive,
};

GfxStateBits StateBitsForMaterial(const Material *material)
{
    GfxStateBits fallback{{
        GFXS0_ATEST_DISABLE | GFXS0_CULL_BACK
            | GFXS0_COLORWRITE_RGB | GFXS0_COLORWRITE_ALPHA,
        GFXS1_DEPTHWRITE | GFXS1_DEPTHTEST_LESSEQUAL,
    }};
    if (!material || !material->stateBitsTable || !material->stateBitsCount)
        return fallback;
    static constexpr MaterialTechniqueType techniques[] = {
        TECHNIQUE_LIT, TECHNIQUE_UNLIT, TECHNIQUE_EMISSIVE,
    };
    for (const MaterialTechniqueType technique : techniques)
    {
        const unsigned int entry = material->stateBitsEntry[technique];
        if (entry != UCHAR_MAX && entry < material->stateBitsCount)
            return material->stateBitsTable[entry];
    }
    return fallback;
}

const char *PrimaryPixelShaderName(const Material *material)
{
    if (!material || !material->techniqueSet)
        return "";
    static constexpr MaterialTechniqueType techniques[] = {
        TECHNIQUE_LIT, TECHNIQUE_UNLIT, TECHNIQUE_EMISSIVE,
    };
    for (const MaterialTechniqueType type : techniques)
    {
        const MaterialTechnique *const technique = material->techniqueSet->techniques[type];
        if (!technique || !technique->passCount || !technique->passArray[0].pixelShader)
            continue;
        const char *const name = technique->passArray[0].pixelShader->name;
        return name ? name : "";
    }
    return "";
}

WorldShaderMode ShaderModeForMaterial(const Material *material)
{
    const char *const shader = PrimaryPixelShaderName(material);
    if (std::strcmp(shader, "mul.hlsl") == 0)
        return WorldShaderMode::Multiply;
    if (std::strstr(shader, "_add_fog"))
        return WorldShaderMode::AddFog;
    if (std::strstr(shader, "vertcol_simple_fog"))
        return WorldShaderMode::SimpleFog;
    if (std::strstr(shader, "vertcol_simple"))
        return WorldShaderMode::Simple;
    return WorldShaderMode::Lit;
}

const MaterialTechnique *EffectTechniqueForMaterial(const Material *material, const int region,
                                                     MaterialTechniqueType *typeOut = nullptr)
{
    if (!material || !material->techniqueSet)
        return nullptr;
    const bool litRegion = region == DRAW_SURF_FX_CAMERA_LIT
        || region == DRAW_SURF_FX_CAMERA_LIT_AUTO
        || region == DRAW_SURF_FX_CAMERA_LIT_DECAL;
    const MaterialTechniqueType preferred = litRegion ? TECHNIQUE_LIT : TECHNIQUE_EMISSIVE;
    static constexpr MaterialTechniqueType fallbacks[] = {
        TECHNIQUE_EMISSIVE, TECHNIQUE_UNLIT, TECHNIQUE_LIT,
    };
    if (const MaterialTechnique *const technique = material->techniqueSet->techniques[preferred])
    {
        if (typeOut)
            *typeOut = preferred;
        return technique;
    }
    for (const MaterialTechniqueType type : fallbacks)
    {
        if (const MaterialTechnique *const technique = material->techniqueSet->techniques[type])
        {
            if (typeOut)
                *typeOut = type;
            return technique;
        }
    }
    return nullptr;
}

GfxStateBits EffectStateBitsForMaterial(const Material *material, const int region)
{
    // CoD4's common alpha-blended state.  This is only a fallback for a mod
    // material with sprite geometry but no usable technique/state entry.
    GfxStateBits state{{0x19289165u, GFXS1_DEPTHTEST_LESSEQUAL}};
    MaterialTechniqueType type = TECHNIQUE_NONE;
    if (!EffectTechniqueForMaterial(material, region, &type) || !material->stateBitsTable)
        return state;
    const unsigned int entry = material->stateBitsEntry[type];
    if (entry != UCHAR_MAX && entry < material->stateBitsCount)
        return material->stateBitsTable[entry];
    return state;
}

MTLCullMode CullModeForStateBits(const uint32_t stateBits)
{
    // IW3's D3D state table uses clockwise front faces: CULL_BACK maps to
    // D3DCULL_CCW. Metal's default front-facing winding is also clockwise,
    // so the abstract material state maps directly to Metal's cull mode.
    switch (stateBits & GFXS0_CULL_MASK)
    {
    case GFXS0_CULL_BACK: return MTLCullModeBack;
    case GFXS0_CULL_FRONT: return MTLCullModeFront;
    case GFXS0_CULL_NONE: return MTLCullModeNone;
    default: return MTLCullModeNone;
    }
}

const char *EffectPixelShaderName(const Material *material, const int region)
{
    const MaterialTechnique *const technique = EffectTechniqueForMaterial(material, region);
    if (!technique || !technique->passCount || !technique->passArray[0].pixelShader)
        return "";
    const char *const name = technique->passArray[0].pixelShader->name;
    return name ? name : "";
}

const char *EffectVertexShaderName(const Material *material, const int region)
{
    const MaterialTechnique *const technique = EffectTechniqueForMaterial(material, region);
    if (!technique || !technique->passCount || !technique->passArray[0].vertexShader)
        return "";
    const char *const name = technique->passArray[0].vertexShader->name;
    return name ? name : "";
}

const float *MaterialConstant(const Material *material, const unsigned int hash)
{
    if (!material || !material->constantTable)
        return nullptr;
    for (int i = 0; i < material->constantCount; ++i)
    {
        if (material->constantTable[i].nameHash == hash)
            return material->constantTable[i].literal;
    }
    return nullptr;
}

const float *MaterialConstantNamed(const Material *material, const char *name)
{
    if (!material || !material->constantTable || !name)
        return nullptr;
    for (int i = 0; i < material->constantCount; ++i)
    {
        const MaterialConstantDef &constant = material->constantTable[i];
        if (std::strncmp(constant.name, name, sizeof(constant.name)) == 0)
            return constant.literal;
    }
    return nullptr;
}

id<MTLTexture> TextureForWater(const water_t *constWater, const float floatTime)
{
    if (!constWater || constWater->M <= 0 || constWater->N <= 0
        || constWater->M * constWater->N > HCOUNT)
    {
        return nil;
    }
    water_t *const water = const_cast<water_t *>(constWater);
    auto found = g_waterTextures.find(water);
    if (found == g_waterTextures.end())
    {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
        descriptor.textureType = MTLTextureType2D;
        descriptor.pixelFormat = MTLPixelFormatR8Unorm;
        descriptor.width = static_cast<NSUInteger>(water->M);
        descriptor.height = static_cast<NSUInteger>(water->N);
        descriptor.mipmapLevelCount = 1;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [g_device newTextureWithDescriptor:descriptor];
        if (texture)
        {
            texture.label = [NSString stringWithFormat:@"CoD4 water %dx%d", water->M, water->N];
        }
        WaterTextureCache cache{
            texture ? (__bridge_retained void *)texture : nullptr,
            -1,
        };
        found = g_waterTextures.emplace(water, cache).first;
    }

    id<MTLTexture> texture = (__bridge id<MTLTexture>)found->second.texture;
    if (!texture || found->second.updatedFrame == g_frameCount)
        return texture;

    std::vector<unsigned char> pixels(
        static_cast<size_t>(water->M) * static_cast<size_t>(water->N));
    if (!R_GenerateWaterTexturePixels(water, floatTime, pixels.data(),
                                      static_cast<unsigned int>(pixels.size())))
    {
        return nil;
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, water->M, water->N)
               mipmapLevel:0
                 withBytes:pixels.data()
               bytesPerRow:static_cast<NSUInteger>(water->M)];
    found->second.updatedFrame = g_frameCount;
    return texture;
}

MetalWaterParams WaterParamsForMaterial(const Material *material, const GfxViewInfo &view)
{
    MetalWaterParams params{};
    params.cameraOrigin[3] = 1.0f;
    std::memcpy(params.cameraOrigin, view.viewParms.origin, sizeof(float) * 3);
    const float defaultEnvMapParms[4] = {0.5f, 0.9f, 1.0f, 1.0f};
    const float defaultWaterColor[4] = {0.3f, 0.3f, 0.24f, 1.0f};
    std::memcpy(params.envMapParms, defaultEnvMapParms, sizeof(params.envMapParms));
    std::memcpy(params.waterColor, defaultWaterColor, sizeof(params.waterColor));
    if (const float *const envMapParms = MaterialConstantNamed(material, "envMapParms"))
        std::memcpy(params.envMapParms, envMapParms, sizeof(params.envMapParms));
    if (const float *const waterColor = MaterialConstantNamed(material, "waterColor"))
        std::memcpy(params.waterColor, waterColor, sizeof(params.waterColor));
    std::memcpy(params.fog, view.input.consts[CONST_SRC_CODE_FOG], sizeof(params.fog));
    std::memcpy(params.fogColor, view.input.consts[CONST_SRC_CODE_FOG_COLOR],
                sizeof(params.fogColor));
    std::memcpy(params.sunDirection, view.input.consts[CONST_SRC_CODE_SUN_POSITION],
                sizeof(params.sunDirection));
    std::memcpy(params.sunColor, view.input.consts[CONST_SRC_CODE_SUN_DIFFUSE],
                sizeof(params.sunColor));
    return params;
}

bool BindWaterMaterial(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view,
                       const Material *material, const unsigned int reflectionProbeIndex)
{
    const MaterialTextureDef *const waterDef = MaterialTextureForSemantic(material, TS_WATER_MAP);
    if (!waterDef || !waterDef->u.water)
        return false;

    const float floatTime = r_drawWater && !r_drawWater->current.enabled
        ? rg.waterFloatTime : view.sceneDef.floatTime;
    id<MTLTexture> water = TextureForWater(waterDef->u.water, floatTime);
    id<MTLTexture> reflection = TextureForReflectionProbe(reflectionProbeIndex);
    if (!water || !reflection)
        return false;

    TraceMaterialTechnique(material);
    const MetalWaterParams params = WaterParamsForMaterial(material, view);
    // Water owns texture slots 0/1 and sampler 0 with a different shader
    // contract. The next ordinary material must therefore republish its state.
    InvalidateMaterialBindings();
    SetCachedRenderPipeline(encoder, g_waterPipeline);
    SetCachedDepthState(encoder, g_transparentDepthState);
    [encoder setFragmentTexture:water atIndex:0];
    [encoder setFragmentTexture:reflection atIndex:1];
    [encoder setFragmentSamplerState:SamplerForState(waterDef->samplerState) atIndex:0];
    // R_SetReflectionProbe binds the code cubemap with sampler state 0x72:
    // linear min/mag, trilinear mips, and clamped U/V.  It is independent of
    // the material's animated water sampler.
    [encoder setFragmentSamplerState:SamplerForState(
        SAMPLER_FILTER_LINEAR | SAMPLER_MIPMAP_LINEAR
        | SAMPLER_CLAMP_U | SAMPLER_CLAMP_V) atIndex:1];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    return true;
}

MetalEffectParams EffectParamsForMaterial(const Material *material, const int region,
                                          const GfxViewInfo &view)
{
    static constexpr unsigned int kDistortionScaleHash = 0xf37b6913u;
    static constexpr unsigned int kZFeatherHash = 0x4d7ea234u;
    static constexpr unsigned int kFalloffParmsHash = 0xbdde5cf5u;
    static constexpr unsigned int kFalloffBeginColorHash = 0x3d05a1f2u;
    static constexpr unsigned int kFalloffEndColorHash = 0x6b1da6fau;
    MetalEffectParams params{};
    params.zNear = std::max(view.viewParms.zNear, 0.01f);
    params.maxDepth = 0.99951172f;
    params.viewportInvSize[0] = 1.0f / std::max(g_viewportWidth, 1);
    params.viewportInvSize[1] = 1.0f / std::max(g_viewportHeight, 1);
    params.distortionScale[0] = 5.0f;
    params.distortionScale[1] = 5.0f;
    params.featherInvDistance = 1.0f / 30.0f;
    std::memcpy(params.cameraOrigin, view.viewParms.origin, sizeof(params.cameraOrigin));
    std::memcpy(params.fog, view.input.consts[CONST_SRC_CODE_FOG], sizeof(params.fog));
    std::memcpy(params.fogColor, view.input.consts[CONST_SRC_CODE_FOG_COLOR],
                sizeof(params.fogColor));
    params.falloffBeginColor[0] = 1.0f;
    params.falloffBeginColor[1] = 1.0f;
    params.falloffBeginColor[2] = 1.0f;
    params.falloffBeginColor[3] = 1.0f;

    const char *const shaderName = EffectPixelShaderName(material, region);
    const char *const vertexShaderName = EffectVertexShaderName(material, region);
    const bool zFeather = std::strstr(shaderName, "zfeather") != nullptr;
    const bool distortion = std::strstr(shaderName, "distortion") != nullptr;
    if (zFeather)
        params.flags |= METAL_EFFECT_ZFEATHER;
    if (distortion)
        params.flags |= METAL_EFFECT_DISTORTION;
    if (std::strstr(shaderName, "_add"))
        params.flags |= METAL_EFFECT_PREMULTIPLY_ALPHA;
    if (std::strstr(vertexShaderName, "foa"))
        params.flags |= METAL_EFFECT_FALLOFF;
    if (!distortion
        && (std::strstr(shaderName, "fog")
            || (zFeather && !std::strstr(shaderName, "_nf"))))
        params.flags |= METAL_EFFECT_FOG;
    const uint32_t stateBits = EffectStateBitsForMaterial(material, region).loadBits[0];
    if ((stateBits & GFXS0_ATEST_DISABLE) == 0)
    {
        switch (stateBits & GFXS0_ATEST_MASK)
        {
        case GFXS0_ATEST_GT_0: params.flags |= METAL_EFFECT_ATEST_GT_ZERO; break;
        case GFXS0_ATEST_LT_128: params.flags |= METAL_EFFECT_ATEST_LT_HALF; break;
        case GFXS0_ATEST_GE_128: params.flags |= METAL_EFFECT_ATEST_GE_HALF; break;
        default: break;
        }
    }
    if (const float *const scale = MaterialConstant(material, kDistortionScaleHash))
    {
        params.distortionScale[0] = scale[0];
        params.distortionScale[1] = scale[1];
    }
    if (const float *const feather = MaterialConstant(material, kZFeatherHash))
        params.featherInvDistance = feather[0];
    if (const float *const falloff = MaterialConstant(material, kFalloffParmsHash))
        std::memcpy(params.falloffParms, falloff, sizeof(params.falloffParms));
    if (const float *const begin = MaterialConstant(material, kFalloffBeginColorHash))
        std::memcpy(params.falloffBeginColor, begin, sizeof(params.falloffBeginColor));
    if (const float *const end = MaterialConstant(material, kFalloffEndColorHash))
        std::memcpy(params.falloffEndColor, end, sizeof(params.falloffEndColor));
    return params;
}

struct EffectFrameRequirements
{
    bool any;
    bool sceneColor;
    bool sceneDepth;
};

EffectFrameRequirements AnalyzeEffectFrameRequirements()
{
    EffectFrameRequirements requirements{};
    if (!frontEndDataOut || !frontEndDataOut->codeMeshCount)
        return requirements;
    static constexpr int effectRegions[] = {
        DRAW_SURF_FX_CAMERA_LIT, DRAW_SURF_FX_CAMERA_LIT_AUTO,
        DRAW_SURF_FX_CAMERA_LIT_DECAL, DRAW_SURF_FX_CAMERA_EMISSIVE,
        DRAW_SURF_FX_CAMERA_EMISSIVE_AUTO, DRAW_SURF_FX_CAMERA_EMISSIVE_DECAL,
    };
    for (const int region : effectRegions)
    {
        const int count = std::min(static_cast<int>(scene.drawSurfCount[region]),
                                   scene.maxDrawSurfCount[region]);
        for (int i = 0; i < count; ++i)
        {
            const GfxDrawSurf drawSurf = scene.drawSurfs[region][i];
            if (drawSurf.fields.surfType != SF_CODE_MESH
                || drawSurf.fields.materialSortedIndex >= static_cast<unsigned int>(rgp.materialCount))
                continue;
            requirements.any = true;
            const Material *const material = rgp.sortedMaterials[drawSurf.fields.materialSortedIndex];
            const char *const shaderName = EffectPixelShaderName(material, region);
            if (std::strstr(shaderName, "zfeather"))
                requirements.sceneDepth = true;
            if (std::strstr(shaderName, "distortion"))
            {
                requirements.sceneColor = true;
                requirements.sceneDepth = true;
            }
        }
    }
    return requirements;
}

void SetMaterialPipeline(id<MTLRenderCommandEncoder> encoder, const Material *material,
                         const bool model, const bool depthHack)
{
    (void)depthHack;
    const GfxStateBits state = StateBitsForMaterial(material);
    id<MTLRenderPipelineState> pipeline = WorldPipelineForMaterial(
        material, state.loadBits[0], model);
    SetCachedRenderPipeline(encoder, pipeline ? pipeline
                                              : (model ? g_modelPipeline : g_worldPipeline));
    id<MTLDepthStencilState> depth = DepthStateForMaterial(state.loadBits[1]);
    SetCachedDepthState(encoder, depth ? depth
                                      : (model ? g_viewModelDepthState : g_worldDepthState));
}

id<MTLTexture> TextureForReflectionProbe(const unsigned int reflectionProbeIndex)
{
    if (!rgp.world)
        return nil;
    if (rgp.world->reflectionProbes
        && reflectionProbeIndex < rgp.world->reflectionProbeCount)
    {
        GfxImage *const image = rgp.world->reflectionProbes[reflectionProbeIndex].reflectionImage;
        id<MTLTexture> probe = TextureForSkyImage(image);
        if (probe)
            return probe;
    }
    return TextureForSkyImage(rgp.world->skyImage);
}

bool EnsureModelLightTexture()
{
    const unsigned int height = R_GetModelLightingImageHeight();
    if (!rgp.world || !height)
        return false;
    if (g_modelLightTexture && g_modelLightWorld == rgp.world && g_modelLightHeight == height)
        return true;

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = MTLTextureType3D;
    descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.width = 256;
    descriptor.height = height;
    descriptor.depth = 4;
    descriptor.mipmapLevelCount = 1;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageShaderRead;
    g_modelLightTexture = [g_device newTextureWithDescriptor:descriptor];
    g_modelLightTexture.label = @"CoD4 directional model-light volume";
    g_modelLightWorld = rgp.world;
    g_modelLightHeight = height;
    g_modelLightTextureNeedsClear = g_modelLightTexture != nil;
    return g_modelLightTexture != nil;
}

void PrepareViewModelLighting(const GfxViewInfo &view)
{
    if (!frontEndDataOut || !rgp.world)
        return;

    const unsigned int count = std::min(static_cast<unsigned int>(scene.sceneDObjCount), 512u);
    for (unsigned int i = 0; i < count; ++i)
    {
        GfxSceneEntity &entity = scene.sceneDObj[i];
        const unsigned int renderFxFlags = entity.gfxEntIndex
            ? frontEndDataOut->gfxEnts[entity.gfxEntIndex].renderFxFlags
            : 0;
        if ((renderFxFlags & 2) == 0 || !entity.obj || !entity.info.cachedLightingHandle)
            continue;

        // Depth-hacked first-person models intentionally bypass the ordinary
        // world visibility byte, so R_AddAllSceneEntSurfacesCamera never gives
        // them a model-light entry.  Allocate/revalidate it here every frame;
        // the allocator also marks a cached entry as in use for this frame.
        GfxLightingInfo lightingInfo{};
        const unsigned int handle = R_AllocModelLighting_Box(
            &view, entity.lightingOrigin, entity.cull.mins, entity.cull.maxs,
            entity.info.cachedLightingHandle, &lightingInfo);
        if (handle)
            entity.reflectionProbeIndex = lightingInfo.reflectionProbeIndex;

        static bool reported = false;
        if (g_traceRenderer && !reported)
        {
            reported = true;
            Com_Printf(8, "[metal] viewmodel model-light: handle=%u primary=%u probe=%u patches=%d\n",
                       handle, lightingInfo.primaryLightIndex, lightingInfo.reflectionProbeIndex,
                       frontEndDataOut->modelLightingPatchCount);
        }
    }
}

void BuildModelLightBlock(const GfxModelLightingPatch &patch, unsigned char *block)
{
    static constexpr unsigned char sampleMap[64] = {
         0,  1,  2,  3,   4,  5,  6,  7,   8,  9, 10, 11,  12, 13, 14, 15,
        16, 17, 18, 19,  20,  0,  3, 21,  22, 12, 15, 23,  24, 25, 26, 27,
        28, 29, 30, 31,  32, 40, 43, 33,  34, 52, 55, 35,  36, 37, 38, 39,
        40, 41, 42, 43,  44, 45, 46, 47,  48, 49, 50, 51,  52, 53, 54, 55,
    };

    if (!patch.colorsCount)
    {
        for (unsigned int sample = 0; sample < 64; ++sample)
        {
            unsigned char *const pixel = block + sample * 4;
            // GfxColor is stored in D3D BGRA byte order.  The Metal texture is
            // semantic RGBA, so preserve the logical channel order explicitly.
            pixel[0] = patch.groundLighting[2];
            pixel[1] = patch.groundLighting[1];
            pixel[2] = patch.groundLighting[0];
            pixel[3] = patch.groundLighting[3];
        }
        return;
    }

    GfxLightGridColors blended{};
    const GfxLightGridColors *colors = nullptr;
    if (patch.colorsCount == 1)
    {
        colors = &rgp.world->lightGrid.colors[patch.colorsIndex[0]];
    }
    else
    {
        unsigned __int16 weights[8] = {};
        std::memcpy(weights, patch.colorsWeight, sizeof(weights));
        R_FixedPointBlendLightGridColors(&rgp.world->lightGrid, patch.colorsIndex,
                                         weights, patch.colorsCount, &blended);
        colors = &blended;
    }

    for (unsigned int sample = 0; sample < 64; ++sample)
    {
        const unsigned int source = sampleMap[sample];
        unsigned char *const pixel = block + sample * 4;
        pixel[0] = colors->rgb[source][0];
        pixel[1] = colors->rgb[source][1];
        pixel[2] = colors->rgb[source][2];
        pixel[3] = patch.primaryLightWeight;
    }
}

void UploadModelLighting(id<MTLCommandBuffer> commandBuffer)
{
    if (!frontEndDataOut || !EnsureModelLightTexture())
        return;

    unsigned int restoredStaticEntries = 0;
    if (g_modelLightTextureNeedsClear && rgp.world->dpvs.smodelDrawInsts)
    {
        // Static-light handles live across frames.  Metal's atlas is created
        // lazily when the first drawable arrives, which can be after those
        // handles were populated by the front end.  Re-emit their exact light
        // grid patches once so a new native texture never starts with holes.
        for (unsigned int i = 0; i < rgp.world->dpvs.smodelCount; ++i)
        {
            if (frontEndDataOut->modelLightingPatchCount >= 4096)
                break;
            if (!rgp.world->dpvs.smodelDrawInsts[i].lightingHandle)
                continue;
            R_SetStaticModelLighting(i);
            ++restoredStaticEntries;
        }
    }

    const int rawPatchCount = frontEndDataOut->modelLightingPatchCount;
    const unsigned int patchCount = std::min(
        static_cast<unsigned int>(std::max(rawPatchCount, 0)), 4096u);
    if (!patchCount && !g_modelLightTextureNeedsClear)
        return;

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (g_modelLightTextureNeedsClear)
    {
        const NSUInteger bytesPerRow = 256 * 4;
        const NSUInteger bytesPerImage = bytesPerRow * g_modelLightHeight;
        id<MTLBuffer> clear = [g_device newBufferWithLength:bytesPerImage * 4
                                                    options:MTLResourceStorageModeShared];
        if (clear)
        {
            std::memset(clear.contents, 0, clear.length);
            [blit copyFromBuffer:clear sourceOffset:0 sourceBytesPerRow:bytesPerRow
             sourceBytesPerImage:bytesPerImage
                      sourceSize:MTLSizeMake(256, g_modelLightHeight, 4)
                       toTexture:g_modelLightTexture destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            g_modelLightTextureNeedsClear = false;
        }
    }

    // Buffer-to-texture rows on macOS use a 256-byte aligned pitch.  Each
    // logical patch is only 4x4x4 RGBA texels; staging just the dirty blocks
    // keeps the per-frame upload proportional to visible model changes.
    constexpr NSUInteger rowPitch = 256;
    constexpr NSUInteger imagePitch = rowPitch * 4;
    constexpr NSUInteger patchPitch = imagePitch * 4;
    id<MTLBuffer> staging = patchCount
        ? [g_device newBufferWithLength:patchPitch * patchCount
                                options:MTLResourceStorageModeShared]
        : nil;
    unsigned char tightBlock[64 * 4];
    unsigned int uploaded = 0;
    for (unsigned int patchIndex = 0; patchIndex < patchCount && staging; ++patchIndex)
    {
        const GfxModelLightingPatch &patch = frontEndDataOut->modelLightingPatchList[patchIndex];
        const unsigned int entry = patch.modelLightingIndex;
        const unsigned int x = 4 * (entry & 63);
        const unsigned int y = (entry >> 4) & ~3u;
        if (y + 4 > g_modelLightHeight || patch.colorsCount > 8)
            continue;

        BuildModelLightBlock(patch, tightBlock);
        unsigned char *const destination = static_cast<unsigned char *>(staging.contents)
            + patchPitch * uploaded;
        for (unsigned int z = 0; z < 4; ++z)
        {
            for (unsigned int row = 0; row < 4; ++row)
            {
                std::memcpy(destination + z * imagePitch + row * rowPitch,
                            tightBlock + (z * 4 + row) * 16, 16);
            }
        }
        [blit copyFromBuffer:staging sourceOffset:patchPitch * uploaded
           sourceBytesPerRow:rowPitch sourceBytesPerImage:imagePitch
                  sourceSize:MTLSizeMake(4, 4, 4)
                   toTexture:g_modelLightTexture destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(x, y, 0)];
        ++uploaded;
    }
    [blit endEncoding];

    static bool reported = false;
    if (g_traceRenderer && !reported && uploaded)
    {
        reported = true;
        Com_Printf(8, "[metal] uploaded %u directional model-light blocks "
                      "(%u restored static, %ux%ux4 atlas)\n",
                   uploaded, restoredStaticEntries, 256u, g_modelLightHeight);
    }
}

MetalMaterialParams MaterialParams(const GfxViewInfo &view, const Material *material,
                                   const bool usesPrimaryLightmap,
                                   const bool usesSecondaryLightmap, const bool usesNormal,
                                   const bool usesSpecular, const bool usesReflection,
                                   const bool usesDetail,
                                   const unsigned int lightingHandle,
                                   const unsigned int primaryLightIndex,
                                   const bool preserveAlpha = false)
{
    MetalMaterialParams params{};
    params.flags = usesPrimaryLightmap ? METAL_MATERIAL_PRIMARY_LIGHTMAP : 0u;
    if (usesNormal)
        params.flags |= METAL_MATERIAL_NORMAL_MAP;
    if (usesSpecular)
        params.flags |= METAL_MATERIAL_SPECULAR_MAP;
    if (usesReflection)
        params.flags |= METAL_MATERIAL_REFLECTION_MAP;
    if (usesSecondaryLightmap)
        params.flags |= METAL_MATERIAL_SECONDARY_LIGHTMAP;
    if (usesDetail)
        params.flags |= METAL_MATERIAL_DETAIL_MAP;
    if (preserveAlpha)
        params.flags |= METAL_MATERIAL_PRESERVE_ALPHA;
    params.alphaTest = MaterialAlphaTest(material);
    // The shipped r0c0n0s0 shaders bind this named constant directly.  Its
    // components are Fresnel minimum, maximum, exponent and sun-specular
    // intensity respectively.  Do not replace it with generic PBR knobs: the
    // authored values vary substantially between concrete, paint and metal.
    params.envMapParms[2] = 1.0f;
    if (const float *const envMapParms = MaterialConstantNamed(material, "envMapParms"))
        std::memcpy(params.envMapParms, envMapParms, sizeof(params.envMapParms));
    std::memcpy(params.cameraOrigin, view.viewParms.origin, sizeof(float) * 3);
    params.cameraOrigin[3] = 1.0f;
    params.sunDirection[2] = -1.0f;
    params.sunColor[0] = params.sunColor[1] = params.sunColor[2] = 1.0f;
    params.sunColor[3] = 1.0f;
    params.sunSpecular[0] = params.sunSpecular[1] = params.sunSpecular[2] = 1.0f;
    params.sunSpecular[3] = 1.0f;
    // R_SetSunConstants sources these values from input->data->sunLight.  The
    // fallback view's consts array has not passed through the D3D command-buffer
    // uploader, so reading that array here yields a zero direction and NaNs.
    // Read the same authoritative light object and reproduce the code constants.
    const GfxLight *const sun = view.input.data
        ? &view.input.data->sunLight
        : (rgp.world ? rgp.world->sunLight : nullptr);
    if (sun && sun->type == GFX_LIGHT_TYPE_DIR)
    {
        std::memcpy(params.sunDirection, sun->dir, sizeof(float) * 3);
        std::memcpy(params.sunColor, sun->color, sizeof(float) * 3);
        const float specularScale = r_specularColorScale
            ? r_specularColorScale->current.value : 1.0f;
        for (int channel = 0; channel < 3; ++channel)
            params.sunSpecular[channel] = sun->color[channel] * specularScale;
    }
    // The front end has already culled and importance-sorted this list using
    // r_dlightLimit.  These are the same GfxLight values consumed by the D3D9
    // LIGHT_OMNI/LIGHT_SPOT passes; keeping that selection avoids inventing a
    // second visibility policy in the Metal back end.
    params.dynamicLightCount = static_cast<uint32_t>(
        std::min(std::max(view.pointLightCount, 0), 4));
    const float diffuseScale = r_diffuseColorScale
        ? r_diffuseColorScale->current.value : 1.0f;
    for (uint32_t lightIndex = 0; lightIndex < params.dynamicLightCount; ++lightIndex)
    {
        const GfxLight &light = view.pointLightPartitions[lightIndex].light;
        if ((light.type != GFX_LIGHT_TYPE_OMNI && light.type != GFX_LIGHT_TYPE_SPOT)
            || light.radius <= 0.0f || !light.def || !light.def->attenuation.image)
        {
            continue;
        }
        std::memcpy(params.dynamicLightPosition[lightIndex], light.origin,
                    sizeof(light.origin));
        params.dynamicLightPosition[lightIndex][3] = 1.0f / light.radius;
        for (int channel = 0; channel < 3; ++channel)
            params.dynamicLightColorType[lightIndex][channel] = light.color[channel] * diffuseScale;
        params.dynamicLightColorType[lightIndex][3] = static_cast<float>(light.type);
        std::memcpy(params.dynamicLightDirectionExponent[lightIndex], light.dir,
                    sizeof(light.dir));
        params.dynamicLightDirectionExponent[lightIndex][3] = static_cast<float>(light.exponent);
        if (light.type == GFX_LIGHT_TYPE_SPOT
            && light.cosHalfFovInner > light.cosHalfFovOuter)
        {
            const float spotScale = 1.0f / (light.cosHalfFovInner - light.cosHalfFovOuter);
            params.dynamicLightSpotFactors[lightIndex][0] = spotScale;
            params.dynamicLightSpotFactors[lightIndex][1] = -spotScale * light.cosHalfFovOuter;
        }
    }
    static const bool disableModelLighting =
        std::getenv("KISAK_DISABLE_MODEL_LIGHT") != nullptr;
    if (!disableModelLighting && lightingHandle && g_modelLightTexture && g_modelLightHeight)
    {
        const unsigned int entry = lightingHandle - 1;
        if (entry < g_modelLightHeight * 16)
        {
            params.flags |= METAL_MATERIAL_MODEL_LIGHT;
            if (rgp.world && primaryLightIndex
                && primaryLightIndex == rgp.world->sunPrimaryLightIndex)
            {
                params.flags |= METAL_MATERIAL_MODEL_SUN;
            }
            params.modelLightBase[0] = (4.0f * (entry & 63) + 2.0f) / 256.0f;
            params.modelLightBase[1] = (((entry >> 4) & ~3u) + 2.0f) / g_modelLightHeight;
            params.modelLightBase[2] = 0.5f;
            params.modelLightBase[3] = 1.0f;
            params.modelLightScale[0] = 1.5f / 256.0f;
            params.modelLightScale[1] = 1.5f / g_modelLightHeight;
            params.modelLightScale[2] = 0.375f;
        }
    }
    std::memcpy(params.fog, view.input.consts[CONST_SRC_CODE_FOG], sizeof(params.fog));
    std::memcpy(params.fogColor, view.input.consts[CONST_SRC_CODE_FOG_COLOR],
                sizeof(params.fogColor));
    params.detailScale[0] = 1.0f;
    params.detailScale[1] = 1.0f;
    if (const float *const detailScale = MaterialConstantNamed(material, "detailScale"))
        std::memcpy(params.detailScale, detailScale, sizeof(params.detailScale));
    if (view.dynamicShadowType == SHADOW_MAP && g_sunShadowTexture
        && view.sunShadow.partition[0].viewport.width > 0)
    {
        params.flags |= METAL_MATERIAL_SUN_SHADOW;
        for (int cascade = 0; cascade < 2; ++cascade)
        {
            std::memcpy(params.shadowMatrix[cascade],
                        view.sunShadow.partition[cascade].shadowViewParms.viewProjectionMatrix.m,
                        sizeof(params.shadowMatrix[cascade]));
        }
        // Receiver bias is expressed in the normalized depth produced by the
        // original cascade projection. Raster slope bias is applied while the
        // caster map is built; this small receiver term handles quantization.
        params.shadowParams[0] = 0.00035f;
        params.shadowParams[1] = 1.0f / g_sunShadowTexture.width;
    }
    return params;
}

void BindMaterialTextures(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view,
                          const Material *material, id<MTLTexture> primaryLightmap,
                          id<MTLTexture> secondaryLightmap, const bool usesPrimaryLightmap,
                          const bool usesSecondaryLightmap,
                          const unsigned int reflectionProbeIndex = 0,
                          const unsigned int lightingHandle = 0,
                          const unsigned int primaryLightIndex = 0,
                          const bool preserveAlpha = false)
{
    TraceMaterialTechnique(material);
    const GfxStateBits materialState = StateBitsForMaterial(material);
    // Lit alpha materials (notably mc/mtl_fx_shell_alpha) use the diffuse alpha
    // as their RGB blend weight.  Forcing framebuffer alpha to one made the
    // rifle-shell motion-blur mesh appear as opaque red polygon fans.  Opaque
    // materials still get the legacy forced-one behavior.
    const bool materialBlends = (materialState.loadBits[0] & GFXS0_BLENDOP_RGB_MASK) != 0;
    id<MTLTexture> normal = TextureForMaterialSemantic(material, TS_NORMAL_MAP);
    id<MTLTexture> specular = TextureForMaterialSemantic(material, TS_SPECULAR_MAP);
    const MaterialTextureDef *const detailDef = MaterialTextureNamed(material, "detailMap");
    id<MTLTexture> detail = detailDef && ImageForMaterialTextureDef(*detailDef)
        ? TextureForImage(ImageForMaterialTextureDef(*detailDef)) : nil;
    id<MTLSamplerState> detailSampler = detailDef
        ? SamplerForState(detailDef->samplerState) : g_worldSampler;
    static const bool disableReflections =
        std::getenv("KISAK_DISABLE_REFLECTIONS") != nullptr;
    id<MTLTexture> reflection = specular && !disableReflections
        ? TextureForReflectionProbe(reflectionProbeIndex) : nil;
    const MetalMaterialParams params = MaterialParams(view, material, usesPrimaryLightmap,
                                                       usesSecondaryLightmap,
                                                       normal != nil, specular != nil,
                                                       specular != nil && reflection != nil,
                                                       detail != nil,
                                                       lightingHandle, primaryLightIndex,
                                                       preserveAlpha || materialBlends);
    SetMaterialFragmentTexture(encoder, TextureForWorldMaterial(material), 0);
    SetMaterialFragmentTexture(encoder, primaryLightmap ? primaryLightmap : g_whiteTexture, 1);
    SetMaterialFragmentTexture(encoder, normal ? normal : g_whiteTexture, 2);
    SetMaterialFragmentTexture(encoder, specular ? specular : g_whiteTexture, 3);
    SetMaterialFragmentTexture(encoder, reflection, 4);
    SetMaterialFragmentTexture(encoder, secondaryLightmap ? secondaryLightmap : g_whiteTexture, 5);
    SetMaterialFragmentTexture(encoder, g_modelLightTexture, 6);
    SetMaterialFragmentTexture(encoder, detail ? detail : g_whiteTexture, 7);
    SetMaterialFragmentTexture(encoder, g_sunShadowTexture, 8);
    for (int lightIndex = 0; lightIndex < 4; ++lightIndex)
    {
        const GfxLight *light = lightIndex < view.pointLightCount
            ? &view.pointLightPartitions[lightIndex].light : nullptr;
        const GfxLightImage *attenuation = light && light->def
            ? &light->def->attenuation : nullptr;
        id<MTLTexture> attenuationTexture = attenuation && attenuation->image
            ? TextureForImage(attenuation->image) : nil;
        SetMaterialFragmentTexture(encoder,
            attenuationTexture ? attenuationTexture : g_whiteTexture, 9 + lightIndex);
        SetMaterialFragmentSampler(encoder,
            attenuation ? SamplerForState(attenuation->samplerState) : g_worldSampler,
            5 + lightIndex);
    }
    SetMaterialFragmentSampler(encoder, SamplerForMaterial(material), 0);
    // world_fragment declares the lightmap sampler even for materials that
    // fall back to white lightmaps.  Own the complete shader binding contract
    // here so model, world, and mark passes all populate a fresh encoder.
    SetMaterialFragmentSampler(encoder, g_lightmapSampler, 1);
    SetMaterialFragmentSampler(encoder, g_modelLightSampler, 2);
    SetMaterialFragmentSampler(encoder, detailSampler, 3);
    SetMaterialFragmentSampler(encoder, g_shadowSampler, 4);
    // The original renderer binds reflectionProbeSampler separately with
    // state 0x72; sharing the diffuse sampler changed explicit cubemap LODs
    // from trilinear to nearest on common model materials.
    SetMaterialFragmentSampler(encoder, SamplerForState(
        SAMPLER_FILTER_LINEAR | SAMPLER_MIPMAP_LINEAR
        | SAMPLER_CLAMP_U | SAMPLER_CLAMP_V), 9);
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
}

bool BuildWorldBuffers(const GfxWorld *world)
{
    if (g_bufferedWorld == world && g_worldVertexBuffer && g_worldIndexBuffer)
        return true;
    g_bufferedWorld = nullptr;
    g_worldVertexBuffer = nil;
    g_worldIndexBuffer = nil;
    if (!world || !world->vd.vertices || !world->indices || !world->vertexCount || world->indexCount <= 0)
        return false;

    std::vector<MetalWorldVertex> converted(world->vertexCount);
    for (unsigned int i = 0; i < world->vertexCount; ++i)
    {
        const GfxWorldVertex &src = world->vd.vertices[i];
        MetalWorldVertex &dst = converted[i];
        std::memcpy(dst.position, src.xyz, sizeof(dst.position));
        std::memcpy(dst.uv, src.texCoord, sizeof(dst.uv));
        std::memcpy(dst.lightmapUv, src.lmapCoord, sizeof(dst.lightmapUv));
        dst.color[0] = src.color.array[2] / 255.0f;
        dst.color[1] = src.color.array[1] / 255.0f;
        dst.color[2] = src.color.array[0] / 255.0f;
        dst.color[3] = src.color.array[3] / 255.0f;
        Vec3UnpackUnitVec(src.normal, dst.normal);
        Vec3UnpackUnitVec(src.tangent, dst.tangent);
        dst.binormalSign = src.binormalSign;
        dst.tangentPadding = 0.0f;
    }
    g_worldVertexBuffer = [g_device newBufferWithBytes:converted.data()
                                                  length:converted.size() * sizeof(MetalWorldVertex)
                                                 options:MTLResourceStorageModeShared];
    g_worldIndexBuffer = [g_device newBufferWithBytes:world->indices
                                                length:static_cast<NSUInteger>(world->indexCount) * sizeof(uint16_t)
                                               options:MTLResourceStorageModeShared];
    if (!g_worldVertexBuffer || !g_worldIndexBuffer)
        return false;
    g_bufferedWorld = world;
    Com_Printf(8, "[metal] uploaded world geometry: %.2f MiB vertices, %.2f MiB indices\n",
               g_worldVertexBuffer.length / (1024.0 * 1024.0),
               g_worldIndexBuffer.length / (1024.0 * 1024.0));
    return true;
}

void EnsureDepthTexture()
{
    if (g_depthTexture && g_depthTexture.width == static_cast<NSUInteger>(g_viewportWidth)
        && g_depthTexture.height == static_cast<NSUInteger>(g_viewportHeight))
        return;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                   width:static_cast<NSUInteger>(g_viewportWidth)
                                  height:static_cast<NSUInteger>(g_viewportHeight)
                               mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    // Depth-of-field consumes the hardware depth image after the scene pass.
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    g_depthTexture = [g_device newTextureWithDescriptor:desc];
    g_depthTexture.label = @"CoD4 scene depth / float-Z source";
}

void EnsureFrameColorTextures()
{
    const NSUInteger width = static_cast<NSUInteger>(std::max(g_viewportWidth, 1));
    const NSUInteger height = static_cast<NSUInteger>(std::max(g_viewportHeight, 1));
    const NSUInteger glowWidth = std::max<NSUInteger>(width >> 2, 1);
    const NSUInteger glowHeight = std::max<NSUInteger>(height >> 2, 1);
    if (g_sceneColorTexture && g_sceneColorTexture.width == width
        && g_sceneColorTexture.height == height && g_postColorTexture
        && g_postColorTexture.width == width && g_postColorTexture.height == height
        && g_glowTexture[0] && g_glowTexture[0].width == glowWidth
        && g_glowTexture[0].height == glowHeight && g_glowTexture[1]
        && g_glowTexture[1].width == glowWidth && g_glowTexture[1].height == glowHeight
        && g_dofColorTexture && g_dofColorTexture.width == width
        && g_dofColorTexture.height == height
        && g_savedScreenTexture && g_savedScreenTexture.width == width
        && g_savedScreenTexture.height == height
        && g_dofTexture[0] && g_dofTexture[0].width == glowWidth
        && g_dofTexture[0].height == glowHeight && g_dofTexture[1]
        && g_dofTexture[1].width == glowWidth && g_dofTexture[1].height == glowHeight
        && g_dofTexture[2] && g_dofTexture[2].width == glowWidth
        && g_dofTexture[2].height == glowHeight)
    {
        return;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:kDrawableFormat
                                   width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    g_sceneColorTexture = [g_device newTextureWithDescriptor:descriptor];
    g_sceneColorTexture.label = @"CoD4 scene color";
    g_postColorTexture = [g_device newTextureWithDescriptor:descriptor];
    g_postColorTexture.label = @"CoD4 post-film and HUD color";
    g_dofColorTexture = [g_device newTextureWithDescriptor:descriptor];
    g_dofColorTexture.label = @"CoD4 depth-of-field composite";
    g_savedScreenTexture = [g_device newTextureWithDescriptor:descriptor];
    g_savedScreenTexture.label = @"CoD4 saved shellshock screen";
    InvalidateSavedScreenHistory("frame targets resized");
    descriptor.width = glowWidth;
    descriptor.height = glowHeight;
    g_glowTexture[0] = [g_device newTextureWithDescriptor:descriptor];
    g_glowTexture[0].label = @"CoD4 glow ping";
    g_glowTexture[1] = [g_device newTextureWithDescriptor:descriptor];
    g_glowTexture[1].label = @"CoD4 glow pong";
    for (unsigned int index = 0; index < std::size(g_dofTexture); ++index)
    {
        g_dofTexture[index] = [g_device newTextureWithDescriptor:descriptor];
        g_dofTexture[index].label = [NSString stringWithFormat:@"CoD4 DOF quarter %u", index];
    }
}

bool EnsureSunShadowTexture()
{
    constexpr NSUInteger kShadowMapSize = 1024;
    if (g_sunShadowTexture
        && g_sunShadowTexture.width == kShadowMapSize
        && g_sunShadowTexture.arrayLength == 2)
    {
        return true;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = MTLTextureType2DArray;
    descriptor.pixelFormat = MTLPixelFormatDepth32Float;
    descriptor.width = kShadowMapSize;
    descriptor.height = kShadowMapSize;
    descriptor.depth = 1;
    descriptor.arrayLength = 2;
    descriptor.mipmapLevelCount = 1;
    descriptor.sampleCount = 1;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    g_sunShadowTexture = [g_device newTextureWithDescriptor:descriptor];
    g_sunShadowTexture.label = @"CoD4 cascaded sun shadows";
    return g_sunShadowTexture != nil;
}

void EnsureResolvedEffectTextures(const EffectFrameRequirements &requirements)
{
    const NSUInteger width = static_cast<NSUInteger>(std::max(g_viewportWidth, 1));
    const NSUInteger height = static_cast<NSUInteger>(std::max(g_viewportHeight, 1));
    if (requirements.any
        && (!g_resolvedSceneTexture || g_resolvedSceneTexture.width != width
            || g_resolvedSceneTexture.height != height))
    {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:kDrawableFormat
                                       width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageShaderRead;
        g_resolvedSceneTexture = [g_device newTextureWithDescriptor:desc];
        g_resolvedSceneTexture.label = @"CoD4 resolved scene for distortion";
    }
    if (requirements.any
        && (!g_resolvedDepthTexture || g_resolvedDepthTexture.width != width
            || g_resolvedDepthTexture.height != height))
    {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                       width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageShaderRead;
        g_resolvedDepthTexture = [g_device newTextureWithDescriptor:desc];
        g_resolvedDepthTexture.label = @"CoD4 resolved depth for effects";
    }
}

MetalFilmParams FilmParamsForView(const GfxViewInfo *view)
{
    MetalFilmParams params{};
    if (!view || !view->film.enabled)
        return params;

    params.enabled = 1;
    const float saturation = std::max(1.0f / 4096.0f, view->film.desaturation);
    float tintScale = view->film.contrast * saturation;
    float tintBias = view->film.brightness + 0.5f - view->film.contrast * 0.5f;
    if (view->film.invert)
    {
        tintScale = -tintScale;
        tintBias += 1.0f;
    }
    params.colorBias[0] = tintBias;
    params.colorBias[1] = tintBias;
    params.colorBias[2] = tintBias;
    params.colorBias[3] = 1.0f / saturation - 1.0f;
    for (int channel = 0; channel < 3; ++channel)
    {
        params.colorTintBase[channel] = view->film.tintDark[channel] * tintScale;
        params.colorTintDelta[channel] = (view->film.tintLight[channel]
            - view->film.tintDark[channel]) * tintScale;
    }
    return params;
}

bool UsingGlow(const GfxViewInfo *view)
{
    return view && view->glow.enabled && view->glow.bloomIntensity != 0.0f
        && view->glow.radius != 0.0f && r_glow && r_glow->current.enabled
        && r_fullbright && !r_fullbright->current.enabled
        && ((r_glow_allowed && r_glow_allowed->current.enabled)
            || (r_glow_allowed_script_forced
                && r_glow_allowed_script_forced->current.enabled));
}

GfxDepthOfField DepthOfFieldForView(const GfxViewInfo &view)
{
    GfxDepthOfField dof = view.dof;
    if (std::getenv("KISAK_METAL_TEST_DOF"))
    {
        dof.viewModelStart = 2.0f;
        dof.viewModelEnd = 8.0f;
        dof.nearStart = 10.0f;
        dof.nearEnd = 60.0f;
        dof.farStart = 400.0f;
        dof.farEnd = 900.0f;
        dof.nearBlur = 6.0f;
        dof.farBlur = 3.0f;
    }
    return dof;
}

bool UsingDepthOfField(const GfxViewInfo *view)
{
    if (!view)
        return false;
    const GfxDepthOfField dof = DepthOfFieldForView(*view);
    if (dof.viewModelEnd > dof.viewModelStart + 1.0f)
        return true;
    if (dof.nearEnd > dof.nearStart + 1.0f)
        return true;
    return dof.farEnd > dof.farStart + 1.0f && dof.farBlur > 0.0f;
}

void NearDepthOfFieldEquation(float outOfFocus, float inFocus, const float nearClip,
                              const float depthScale, float equation[4])
{
    if (std::max(outOfFocus, nearClip) >= inFocus)
    {
        inFocus = nearClip * 0.5f;
        outOfFocus = 0.0f;
    }
    equation[0] = depthScale / (outOfFocus - inFocus);
    equation[2] = inFocus / (inFocus - outOfFocus);
}

MetalDofParams DofParamsForView(const GfxViewInfo &view, const GfxDepthOfField &dof)
{
    MetalDofParams params{};
    params.sceneInvSize[0] = 1.0f / static_cast<float>(std::max(g_viewportWidth, 1));
    params.sceneInvSize[1] = 1.0f / static_cast<float>(std::max(g_viewportHeight, 1));
    params.zNear = view.viewParms.zNear;
    params.depthHackNear = std::fabs(view.viewParms.depthHackNearClip);
    params.maxDepth = 0.99951172f;

    NearDepthOfFieldEquation(dof.nearStart, dof.nearEnd,
                             view.viewParms.zNear, 1.0f, params.sceneEquation);
    if (std::max(view.viewParms.zNear, dof.farStart) < dof.farEnd)
    {
        params.sceneEquation[1] = 1.0f / (dof.farEnd - dof.farStart);
        params.sceneEquation[3] = dof.farStart / (dof.farStart - dof.farEnd);
    }

    NearDepthOfFieldEquation(dof.viewModelStart, dof.viewModelEnd,
                             params.depthHackNear, 1.0f, params.viewModelEquation);
    const float nearBlur = std::max(dof.nearBlur, 0.0001f);
    const float bias = r_dof_bias ? r_dof_bias->current.value : 0.5f;
    params.viewModelEquation[3] = std::pow(std::max(dof.farBlur, 0.0f) / nearBlur, bias);

    float smallFraction = std::pow((1.4f * 480.0f / std::max(g_viewportHeight, 1))
                                     / nearBlur, bias);
    float mediumFraction = std::pow((3.6f * 480.0f / std::max(g_viewportHeight, 1))
                                      / nearBlur, bias);
    // Authored IW3 values satisfy 0 < small < medium < 1. Keep malformed mod
    // input finite without changing the valid path.
    smallFraction = std::clamp(smallFraction, 0.0001f, 0.9997f);
    mediumFraction = std::clamp(mediumFraction, smallFraction + 0.0001f, 0.9998f);
    params.lerpScale[0] = -1.0f / smallFraction;
    params.lerpScale[1] = -1.0f / (mediumFraction - smallFraction);
    params.lerpScale[2] = -1.0f / (1.0f - mediumFraction);
    params.lerpScale[3] = 1.0f / (1.0f - mediumFraction);
    params.lerpBias[0] = 1.0f;
    params.lerpBias[1] = mediumFraction / (mediumFraction - smallFraction);
    params.lerpBias[2] = 1.0f / (1.0f - mediumFraction);
    params.lerpBias[3] = -mediumFraction / (1.0f - mediumFraction);
    return params;
}

MetalGlowSetupParams GlowSetupParamsForView(const GfxViewInfo &view,
                                            const MetalFilmParams &film)
{
    MetalGlowSetupParams params{};
    params.sceneInvSize[0] = 1.0f / std::max(g_viewportWidth, 1);
    params.sceneInvSize[1] = 1.0f / std::max(g_viewportHeight, 1);
    params.bloomCutoff = view.glow.bloomCutoff;
    params.bloomCutoffRescale = params.bloomCutoff < 1.0f
        ? 1.0f / (1.0f - params.bloomCutoff) : 0.0f;
    params.bloomDesaturation = view.glow.bloomDesaturation;
    std::memcpy(params.colorBias, film.colorBias, sizeof(params.colorBias));
    std::memcpy(params.colorTintBase, film.colorTintBase, sizeof(params.colorTintBase));
    std::memcpy(params.colorTintDelta, film.colorTintDelta, sizeof(params.colorTintDelta));
    if (!film.enabled)
    {
        params.colorTintBase[0] = 1.0f;
        params.colorTintBase[1] = 1.0f;
        params.colorTintBase[2] = 1.0f;
    }
    return params;
}

MetalGaussianParams GaussianParams(const float radius, const unsigned int resolution,
                                   const bool horizontal)
{
    MetalGaussianParams params{};
    params.direction[horizontal ? 0 : 1] = 1.0f;
    if (radius <= 0.0f || !resolution)
    {
        params.tapCount = 1;
        params.taps[0][1] = 0.5f;
        return params;
    }

    float combinedWeights[8]{};
    float totalWeight = 0.0f;
    const float exponent = -0.5f / (radius * radius);
    for (int tap = 0; tap < 8; ++tap)
    {
        const float sample0 = static_cast<float>(tap * 2);
        const float sample1 = sample0 + 1.0f;
        float weight0 = std::exp(sample0 * sample0 * exponent);
        const float weight1 = std::exp(sample1 * sample1 * exponent);
        if (tap == 0)
            weight0 *= 0.5f;
        combinedWeights[tap] = weight0 + weight1;
        params.taps[tap][0] = combinedWeights[tap] > 0.0f
            ? (sample0 * weight0 + sample1 * weight1)
                / (static_cast<float>(resolution) * combinedWeights[tap])
            : (sample0 + sample1) * 0.5f / static_cast<float>(resolution);
        totalWeight += combinedWeights[tap];
    }
    params.tapCount = 8;
    const float weightScale = totalWeight > 0.001f ? 0.5f / totalWeight : 1.0f;
    for (int tap = 7; tap >= 0; --tap)
    {
        params.taps[tap][1] = combinedWeights[tap] * weightScale;
        if (params.taps[tap][1] < 0.01f)
            params.tapCount = static_cast<uint32_t>(tap + 1);
    }
    return params;
}

void GaussianFilterPoints(const float radius, const unsigned int sourceResolution,
                          const unsigned int targetResolution, const unsigned int tapLimit,
                          float *offsets, float *weights)
{
    const int resolutionRatio = SnapFloatToInt(
        static_cast<float>(sourceResolution) / static_cast<float>(targetResolution));
    const float sampleBias = (resolutionRatio & 1) ? 0.0f : 0.5f;
    const float exponent = -0.5f / (radius * radius);
    float totalWeight = 0.0f;
    for (unsigned int tap = 0; tap < tapLimit; ++tap)
    {
        const float sample0 = static_cast<float>(tap * 2) + sampleBias;
        const float sample1 = sample0 + 1.0f;
        float weight0 = std::exp(sample0 * sample0 * exponent);
        const float weight1 = std::exp(sample1 * sample1 * exponent);
        if (tap == 0 && sampleBias == 0.0f)
            weight0 *= 0.5f;
        weights[tap] = weight0 + weight1;
        offsets[tap] = weights[tap] > 0.0f
            ? (sample0 * weight0 + sample1 * weight1)
                / (static_cast<float>(sourceResolution) * weights[tap])
            : (sample0 + sample1) * 0.5f / static_cast<float>(sourceResolution);
        totalWeight += weights[tap];
    }
    const float scale = totalWeight > 0.001f ? 0.5f / totalWeight : 1.0f;
    for (unsigned int tap = 0; tap < tapLimit; ++tap)
        weights[tap] *= scale;
}

MetalGaussian2DParams Gaussian2DParams(const float radius,
                                       const unsigned int sourceWidth,
                                       const unsigned int sourceHeight,
                                       const unsigned int targetWidth,
                                       const unsigned int targetHeight)
{
    MetalGaussian2DParams params{};
    float offsetsX[2]{};
    float offsetsY[2]{};
    float weightsX[2]{};
    float weightsY[2]{};
    GaussianFilterPoints(radius, sourceWidth, targetWidth, 2, offsetsX, weightsX);
    GaussianFilterPoints(radius, sourceHeight, targetHeight, 2, offsetsY, weightsY);
    for (unsigned int y = 0; y < 2; ++y)
    {
        for (unsigned int x = 0; x < 2; ++x)
        {
            const unsigned int tap = (y * 2 + x) * 2;
            const float weight = weightsX[x] * weightsY[y];
            params.taps[tap][0] = -offsetsX[x];
            params.taps[tap][1] = offsetsY[y];
            params.taps[tap][2] = weight;
            params.taps[tap + 1][0] = offsetsX[x];
            params.taps[tap + 1][1] = offsetsY[y];
            params.taps[tap + 1][2] = weight;
        }
    }
    params.tapCount = 8;
    return params;
}

void EncodeGaussianPass(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> source,
                        id<MTLTexture> target, const MetalGaussianParams &params)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    SetCachedRenderPipeline(encoder, g_gaussianPipeline);
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

void EncodeGaussian2DPass(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> source,
                          id<MTLTexture> target, const MetalGaussian2DParams &params)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    SetCachedRenderPipeline(encoder, g_gaussian2DPipeline);
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

id<MTLTexture> EncodeGaussianChain(id<MTLCommandBuffer> commandBuffer,
                                   id<MTLTexture> source,
                                   id<MTLTexture> scratch0,
                                   id<MTLTexture> scratch1,
                                   float radiusX, float radiusY)
{
    constexpr float kMinimumRadius = 0.3295051157474518f;
    constexpr float kMaximumPassRadius = 6.497750282287598f;
    constexpr float kMaximum2DRadius = 1.389560461044312f;
    id<MTLTexture> current = source;
    id<MTLTexture> target = scratch0;
    if (source.width != scratch0.width || source.height != scratch0.height)
    {
        const float passRadius = std::min(std::min(radiusX, radiusY), kMaximum2DRadius);
        radiusX = std::sqrt(std::max(radiusX * radiusX - passRadius * passRadius, 0.0f))
            * static_cast<float>(scratch0.width) / static_cast<float>(source.width);
        radiusY = std::sqrt(std::max(radiusY * radiusY - passRadius * passRadius, 0.0f))
            * static_cast<float>(scratch0.height) / static_cast<float>(source.height);
        const MetalGaussian2DParams params = Gaussian2DParams(
            passRadius, static_cast<unsigned int>(source.width),
            static_cast<unsigned int>(source.height),
            static_cast<unsigned int>(scratch0.width),
            static_cast<unsigned int>(scratch0.height));
        EncodeGaussian2DPass(commandBuffer, source, scratch0, params);
        current = scratch0;
        target = scratch1;
    }
    for (unsigned int passIndex = 0;
         passIndex < 32 && (radiusX >= kMinimumRadius || radiusY >= kMinimumRadius);
         ++passIndex)
    {
        if (std::fabs(radiusX - radiusY) < kMinimumRadius)
        {
            const float radius = (radiusX + radiusY) * 0.5f;
            if (radius <= kMaximum2DRadius)
            {
                const MetalGaussian2DParams params = Gaussian2DParams(
                    radius, static_cast<unsigned int>(scratch0.width),
                    static_cast<unsigned int>(scratch0.height),
                    static_cast<unsigned int>(scratch0.width),
                    static_cast<unsigned int>(scratch0.height));
                EncodeGaussian2DPass(commandBuffer, current, target, params);
                current = target;
                break;
            }
        }

        const bool vertical = radiusY >= radiusX;
        float &remainingRadius = vertical ? radiusY : radiusX;
        const float passRadius = std::min(remainingRadius, kMaximumPassRadius);
        if (remainingRadius > kMaximumPassRadius)
            remainingRadius = std::sqrt(remainingRadius * remainingRadius
                                      - kMaximumPassRadius * kMaximumPassRadius);
        else
            remainingRadius = 0.0f;
        const MetalGaussianParams params = GaussianParams(
            passRadius,
            static_cast<unsigned int>(vertical ? scratch0.height : scratch0.width),
            !vertical);
        EncodeGaussianPass(commandBuffer, current, target, params);
        current = target;
        target = target == scratch0 ? scratch1 : scratch0;
    }
    return current;
}

id<MTLTexture> EncodeDepthOfField(id<MTLCommandBuffer> commandBuffer,
                                  const GfxViewInfo &view)
{
    const GfxDepthOfField dof = DepthOfFieldForView(view);
    const MetalDofParams params = DofParamsForView(view, dof);

    MTLRenderPassDescriptor *downsamplePass = [MTLRenderPassDescriptor renderPassDescriptor];
    downsamplePass.colorAttachments[0].texture = g_dofTexture[0];
    downsamplePass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    downsamplePass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:downsamplePass];
    SetCachedRenderPipeline(encoder, g_dofDownsamplePipeline);
    [encoder setFragmentTexture:g_sceneColorTexture atIndex:0];
    [encoder setFragmentTexture:g_depthTexture atIndex:1];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    const float radiusY = dof.nearBlur
        * static_cast<float>(std::max(g_viewportHeight, 1)) / 1920.0f;
    const float scenePixelAspect = vidConfig.aspectRatioScenePixel > 0.0f
        ? vidConfig.aspectRatioScenePixel : 1.0f;
    const float radiusX = radiusY * scenePixelAspect;
    id<MTLTexture> largeBlur = EncodeGaussianChain(commandBuffer, g_dofTexture[0],
                                                   g_dofTexture[1], g_dofTexture[2],
                                                   radiusX, radiusY);
    if (largeBlur == g_dofTexture[0])
    {
        const MetalGaussianParams copyParams = GaussianParams(
            0.0f, static_cast<unsigned int>(g_dofTexture[0].width), true);
        EncodeGaussianPass(commandBuffer, g_dofTexture[0], g_dofTexture[1], copyParams);
        largeBlur = g_dofTexture[1];
    }
    id<MTLTexture> nearCoc = largeBlur == g_dofTexture[1]
        ? g_dofTexture[2] : g_dofTexture[1];

    MTLRenderPassDescriptor *nearPass = [MTLRenderPassDescriptor renderPassDescriptor];
    nearPass.colorAttachments[0].texture = nearCoc;
    nearPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    nearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:nearPass];
    SetCachedRenderPipeline(encoder, g_dofNearCocPipeline);
    [encoder setFragmentTexture:largeBlur atIndex:0];
    [encoder setFragmentTexture:g_dofTexture[0] atIndex:1];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    MTLRenderPassDescriptor *smallPass = [MTLRenderPassDescriptor renderPassDescriptor];
    smallPass.colorAttachments[0].texture = g_dofTexture[0];
    smallPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    smallPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:smallPass];
    SetCachedRenderPipeline(encoder, g_dofSmallBlurPipeline);
    [encoder setFragmentTexture:nearCoc atIndex:0];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    MTLRenderPassDescriptor *compositePass = [MTLRenderPassDescriptor renderPassDescriptor];
    compositePass.colorAttachments[0].texture = g_dofColorTexture;
    compositePass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    compositePass.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:compositePass];
    SetCachedRenderPipeline(encoder, g_dofCompositePipeline);
    [encoder setFragmentTexture:g_sceneColorTexture atIndex:0];
    [encoder setFragmentTexture:g_dofTexture[0] atIndex:1];
    [encoder setFragmentTexture:largeBlur atIndex:2];
    [encoder setFragmentTexture:g_depthTexture atIndex:3];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    static bool reported = false;
    if (g_traceRenderer && !reported)
    {
        reported = true;
        Com_Printf(8, "[metal] depth of field: native float-Z reconstruction, "
                      "quarter-res near/large lobes, exact four-band composite\n");
    }
    return g_dofColorTexture;
}

float ScreenBlurRadiusForView(const GfxViewInfo &view)
{
    if (const char *const overrideValue = std::getenv("KISAK_METAL_TEST_BLUR"))
    {
        char *end = nullptr;
        const float radius = std::strtof(overrideValue, &end);
        return end != overrideValue && radius >= 0.0f ? radius : 6.0f;
    }
    const float dvarRadius = r_blur ? std::max(r_blur->current.value, 0.0f) : 0.0f;
    const float viewRadius = std::max(view.blurRadius, 0.0f);
    return std::sqrt(dvarRadius * dvarRadius + viewRadius * viewRadius);
}

void EncodeScreenBlur(id<MTLCommandBuffer> commandBuffer, const GfxViewInfo &view,
                      const MetalFilmParams &film)
{
    float blurRadius = ScreenBlurRadiusForView(view);
    if (blurRadius <= 0.0f)
        return;

    const float minimumRadius = 1440.0f / static_cast<float>(std::max(g_viewportHeight, 1));
    float blendAlpha = 1.0f;
    if (minimumRadius > blurRadius)
    {
        const int packedAlpha = std::clamp(
            SnapFloatToInt(blurRadius / minimumRadius * 255.0f), 0, 255);
        blendAlpha = static_cast<float>(packedAlpha) / 255.0f;
        blurRadius = minimumRadius;
    }

    const float radiusY = static_cast<float>(std::max(g_viewportHeight, 1))
        * blurRadius / 480.0f;
    const float scenePixelAspect = vidConfig.aspectRatioScenePixel > 0.0f
        ? vidConfig.aspectRatioScenePixel : 1.0f;
    const float radiusX = radiusY * scenePixelAspect;
    id<MTLTexture> blurred = EncodeGaussianChain(commandBuffer, g_sceneColorTexture,
                                                  g_dofTexture[0], g_dofTexture[1],
                                                  radiusX, radiusY);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = g_postColorTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    SetCachedRenderPipeline(encoder, g_feedbackBlendPipeline);
    [encoder setFragmentTexture:blurred atIndex:0];
    [encoder setFragmentSamplerState:g_sampler atIndex:0];
    [encoder setFragmentBytes:&film length:sizeof(film) atIndex:0];
    [encoder setFragmentBytes:&blendAlpha length:sizeof(blendAlpha) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    static bool reported = false;
    if (g_traceRenderer && !reported)
    {
        reported = true;
        Com_Printf(8, "[metal] screen blur: radius=%.3f alpha=%.3f "
                      "full-to-quarter IW3 Gaussian chain\n", blurRadius, blendAlpha);
    }
}

void EncodeSavedScreenCommands(id<MTLCommandBuffer> commandBuffer, const GfxViewInfo &view)
{
    if (!g_savedScreenTexture || g_savedScreenCommands.empty())
        return;

    const int sceneTime = view.sceneDef.time;
    static int reportedCommands = 0;
    static int reportedBlendChecks = 0;
    for (const SavedScreenCommand &command : g_savedScreenCommands)
    {
        if (command.type == SavedScreenCommandType::Save
            || command.type == SavedScreenCommandType::SaveSection)
        {
            if (command.screenTimerId < 0 || command.screenTimerId >= 4)
                continue;

            MTLOrigin origin = MTLOriginMake(0, 0, 0);
            MTLSize size = MTLSizeMake(g_postColorTexture.width,
                                       g_postColorTexture.height, 1);
            if (command.type == SavedScreenCommandType::SaveSection)
            {
                const NSUInteger left = static_cast<NSUInteger>(std::clamp(
                    SnapFloatToInt(command.s0 * g_postColorTexture.width),
                    0, static_cast<int>(g_postColorTexture.width)));
                const NSUInteger top = static_cast<NSUInteger>(std::clamp(
                    SnapFloatToInt(command.t0 * g_postColorTexture.height),
                    0, static_cast<int>(g_postColorTexture.height)));
                const NSUInteger right = static_cast<NSUInteger>(std::clamp(
                    SnapFloatToInt((command.s0 + command.ds) * g_postColorTexture.width),
                    static_cast<int>(left), static_cast<int>(g_postColorTexture.width)));
                const NSUInteger bottom = static_cast<NSUInteger>(std::clamp(
                    SnapFloatToInt((command.t0 + command.dt) * g_postColorTexture.height),
                    static_cast<int>(top), static_cast<int>(g_postColorTexture.height)));
                origin = MTLOriginMake(left, top, 0);
                size = MTLSizeMake(right - left, bottom - top, 1);
            }
            if (size.width && size.height)
            {
                id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
                [blit copyFromTexture:g_postColorTexture sourceSlice:0 sourceLevel:0
                         sourceOrigin:origin sourceSize:size
                            toTexture:g_savedScreenTexture destinationSlice:0
                     destinationLevel:0 destinationOrigin:origin];
                [blit endEncoding];
                g_savedScreenTimes[command.screenTimerId] = sceneTime;
                g_savedScreenValid[command.screenTimerId] = true;
                g_savedScreenWorld = rgp.world;
                g_savedScreenLocalClientNum = view.localClientNum;
                g_savedScreenServerId = view.localClientNum >= 0
                    && view.localClientNum < STATIC_MAX_LOCAL_CLIENTS
                    ? clients[view.localClientNum].serverId : INT_MIN;
                g_savedScreenLastSceneTime = sceneTime;
            }
            if (g_traceRenderer && reportedCommands++ < 48)
                Com_Printf(8, "[metal] saved shellshock screen timer=%d time=%d section=%.3f/%.3f/%.3f/%.3f\n",
                           command.screenTimerId, sceneTime, command.s0, command.t0,
                           command.ds, command.dt);
            continue;
        }

        bool shouldDraw = false;
        MetalShellShockParams params{};
        params.uvOrigin[0] = command.s0;
        params.uvOrigin[1] = command.t0;
        params.uvSize[0] = command.ds;
        params.uvSize[1] = command.dt;
        id<MTLRenderPipelineState> pipeline = nil;
        if (command.type == SavedScreenCommandType::BlendBlurred)
        {
            if (g_traceRenderer && reportedBlendChecks++ < 16)
                Com_Printf(8, "[metal] shellshock blur request timer=%d fade=%d valid=%d now=%d saved=%d rect=%.3f/%.3f/%.3f/%.3f\n",
                           command.screenTimerId, command.fadeMsec,
                           command.screenTimerId >= 0 && command.screenTimerId < 4
                               ? g_savedScreenValid[command.screenTimerId] : 0,
                           sceneTime,
                           command.screenTimerId >= 0 && command.screenTimerId < 4
                               ? g_savedScreenTimes[command.screenTimerId] : 0,
                           command.s0, command.t0, command.ds, command.dt);
            if (command.screenTimerId >= 0 && command.screenTimerId < 4
                && g_savedScreenValid[command.screenTimerId] && command.fadeMsec > 0)
            {
                const int frameTime = sceneTime - g_savedScreenTimes[command.screenTimerId];
                if (frameTime >= 0 && frameTime < command.fadeMsec)
                {
                    const float alpha = std::min(std::pow(0.01f,
                        static_cast<float>(frameTime) / command.fadeMsec), 0.99f);
                    const int packedAlpha = std::clamp(SnapFloatToInt(alpha * 255.0f), 0, 255);
                    params.color[0] = 1.0f;
                    params.color[1] = 1.0f;
                    params.color[2] = 1.0f;
                    params.color[3] = static_cast<float>(packedAlpha) / 255.0f;
                    pipeline = g_shellShockBlurredPipeline;
                    shouldDraw = true;
                }
            }
        }
        else
        {
            // The MP client has one local view, and its timer id is zero.  Do not
            // let a valid section belonging to another timer authorize a flash
            // blend from unrelated saved-screen contents.
            if (command.screenTimerId >= 0 && command.screenTimerId < 4
                && g_savedScreenValid[command.screenTimerId])
            {
                const int packedWhiteout = std::clamp(
                    SnapFloatToInt(command.whiteout * 255.0f), 0, 255);
                const int packedScreengrab = std::clamp(
                    SnapFloatToInt(command.screengrab * 255.0f), 0, 255);
                params.color[0] = static_cast<float>(packedWhiteout) / 255.0f;
                params.color[1] = params.color[0];
                params.color[2] = params.color[0];
                params.color[3] = static_cast<float>(packedScreengrab) / 255.0f;
                pipeline = g_shellShockFlashedPipeline;
                shouldDraw = true;
            }
        }
        if (!shouldDraw || command.ds <= 0.0f || command.dt <= 0.0f)
            continue;

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = g_postColorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        SetCachedRenderPipeline(encoder, pipeline);
        SetCachedViewport(encoder, MTLViewport{0.0, 0.0,
            g_postColorTexture.width * command.ds,
            g_postColorTexture.height * command.dt, 0.0, 1.0});
        [encoder setFragmentTexture:g_savedScreenTexture atIndex:0];
        [encoder setFragmentSamplerState:g_sampler atIndex:0];
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        if (g_traceRenderer && reportedCommands++ < 48)
            Com_Printf(8, "[metal] blended shellshock screen type=%s timer=%d fade=%d color=%.3f/%.3f\n",
                       command.type == SavedScreenCommandType::BlendBlurred ? "blurred" : "flashed",
                       command.screenTimerId, command.fadeMsec,
                       params.color[0], params.color[3]);
    }
}

void PushAutoAssignClick()
{
    posix_input::InjectKey(K_MOUSE1, true);
    posix_input::InjectKey(K_MOUSE1, false);
}

bool BoundsOutsideView(const float bounds[2][3], const float matrix[4][4])
{
    bool outsideLeft = true;
    bool outsideRight = true;
    bool outsideBottom = true;
    bool outsideTop = true;
    bool outsideNear = true;
    bool outsideFar = true;
    for (int corner = 0; corner < 8; ++corner)
    {
        const float x = bounds[(corner >> 0) & 1][0];
        const float y = bounds[(corner >> 1) & 1][1];
        const float z = bounds[(corner >> 2) & 1][2];
        // Metal receives this storage as four columns and evaluates M * p.
        const float cx = matrix[0][0] * x + matrix[1][0] * y + matrix[2][0] * z + matrix[3][0];
        const float cy = matrix[0][1] * x + matrix[1][1] * y + matrix[2][1] * z + matrix[3][1];
        const float cz = matrix[0][2] * x + matrix[1][2] * y + matrix[2][2] * z + matrix[3][2];
        const float cw = matrix[0][3] * x + matrix[1][3] * y + matrix[2][3] * z + matrix[3][3];
        outsideLeft &= cx < -cw;
        outsideRight &= cx > cw;
        outsideBottom &= cy < -cw;
        outsideTop &= cy > cw;
        outsideNear &= cz < 0.0f;
        outsideFar &= cz > cw;
    }
    return outsideLeft || outsideRight || outsideBottom || outsideTop || outsideNear || outsideFar;
}

void SetSceneDepthRange(id<MTLRenderCommandEncoder> encoder, bool depthHack);

void EncodeSky(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!rgp.world || !rgp.world->skyImage || !g_skyPipeline)
        return;
    id<MTLTexture> sky = TextureForSkyImage(rgp.world->skyImage);
    if (!sky)
        return;

    // Build world-space ray vectors directly from CoD's camera basis. This
    // avoids reconstructing through the engine's infinite-far projection,
    // where a z=1 clip point has homogeneous w=0 by design.
    static const float vertices[6][2] = {
        {-1.0f,  1.0f}, { 1.0f,  1.0f}, {-1.0f, -1.0f},
        { 1.0f,  1.0f}, { 1.0f, -1.0f}, {-1.0f, -1.0f},
    };
    float rayBasis[3][4] = {};
    const float inverseProjectionX = 1.0f / view.viewParms.projectionMatrix.m[0][0];
    const float inverseProjectionY = 1.0f / view.viewParms.projectionMatrix.m[1][1];
    for (int axis = 0; axis < 3; ++axis)
    {
        rayBasis[0][axis] = view.viewParms.axis[0][axis];
        rayBasis[1][axis] = -view.viewParms.axis[1][axis] * inverseProjectionX;
        rayBasis[2][axis] = view.viewParms.axis[2][axis] * inverseProjectionY;
    }
    SetCachedRenderPipeline(encoder, g_skyPipeline);
    SetCachedDepthState(encoder, g_disabledDepthState);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setVertexBytes:rayBasis length:sizeof(rayBasis) atIndex:1];
    [encoder setFragmentTexture:sky atIndex:0];
    [encoder setFragmentSamplerState:g_worldSampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

void EncodeWorld(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    const GfxWorld *const world = rgp.world;
    if (!BuildWorldBuffers(world))
        return;

    SetSceneDepthRange(encoder, false);
    SetCachedRenderPipeline(encoder, g_worldPipeline);
    SetCachedDepthState(encoder, g_worldDepthState);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setVertexBuffer:g_worldVertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:view.viewParms.viewProjectionMatrix.m
                     length:sizeof(view.viewParms.viewProjectionMatrix.m)
                    atIndex:1];
    [encoder setFragmentSamplerState:g_lightmapSampler atIndex:1];

    unsigned int drawnSurfaces = 0;
    unsigned int drawnTriangles = 0;
    unsigned int culledSurfaces = 0;
    unsigned int dpvsCulledSurfaces = 0;
    unsigned int skippedSkySurfaces = 0;
    unsigned int capturedVisibilityCount = 0;
    const unsigned char *cameraVisibility =
        R_GetCameraSurfaceVisibility(&capturedVisibilityCount);
    if (capturedVisibilityCount != static_cast<unsigned int>(world->surfaceCount))
        cameraVisibility = world->dpvs.surfaceVisData[0];
    const bool hasCameraVisibility = cameraVisibility
        && std::any_of(cameraVisibility,
                       cameraVisibility + world->surfaceCount,
                       [](const unsigned char value) { return value != 0; });
    for (int i = 0; i < world->surfaceCount; ++i)
    {
        if (hasCameraVisibility && !cameraVisibility[i])
        {
            ++dpvsCulledSurfaces;
            continue;
        }
        const GfxSurface &surface = world->dpvs.surfaces[i];
        const srfTriangles_t &tris = surface.tris;
        const NSUInteger indexCount = static_cast<NSUInteger>(tris.triCount) * 3;
        if (!indexCount || tris.baseIndex < 0 || tris.firstVertex < 0
            || static_cast<uint64_t>(tris.baseIndex) + indexCount > static_cast<uint64_t>(world->indexCount)
            || static_cast<uint64_t>(tris.firstVertex) + tris.vertexCount > world->vertexCount)
            continue;
        if (surface.material && (surface.material->info.gameFlags & 8) != 0)
        {
            TraceMaterialTechnique(surface.material);
            ++skippedSkySurfaces;
            continue;
        }
        if (BoundsOutsideView(surface.bounds, view.viewParms.viewProjectionMatrix.m))
        {
            ++culledSurfaces;
            continue;
        }

        if (!BindWaterMaterial(encoder, view, surface.material, surface.reflectionProbeIndex))
        {
            SetMaterialPipeline(encoder, surface.material, false, false);

            bool usesPrimaryLightmap = false;
            bool usesSecondaryLightmap = false;
            id<MTLTexture> primaryLightmap = g_whiteTexture;
            id<MTLTexture> secondaryLightmap = g_whiteTexture;
            if (surface.lightmapIndex != 31 && surface.lightmapIndex < world->lightmapCount
                && world->lightmaps)
            {
                const GfxLightmapArray &lightmaps = world->lightmaps[surface.lightmapIndex];
                if (lightmaps.primary)
                {
                    id<MTLTexture> uploaded = TextureForImage(lightmaps.primary);
                    if (uploaded)
                    {
                        primaryLightmap = uploaded;
                        usesPrimaryLightmap = true;
                    }
                }
                if (lightmaps.secondary)
                {
                    id<MTLTexture> uploaded = TextureForImage(lightmaps.secondary);
                    if (uploaded)
                    {
                        secondaryLightmap = uploaded;
                        usesSecondaryLightmap = true;
                    }
                }
            }
            BindMaterialTextures(encoder, view, surface.material, primaryLightmap,
                                 secondaryLightmap, usesPrimaryLightmap,
                                 usesSecondaryLightmap, surface.reflectionProbeIndex);
        }
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:indexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:g_worldIndexBuffer
                     indexBufferOffset:static_cast<NSUInteger>(tris.baseIndex) * sizeof(uint16_t)
                         instanceCount:1
                            baseVertex:tris.firstVertex
                          baseInstance:0];
        ++drawnSurfaces;
        drawnTriangles += tris.triCount;
    }

    static const GfxWorld *reportedDraw = nullptr;
    if (reportedDraw != world)
    {
        reportedDraw = world;
        Com_Printf(8, "[metal] fallback world pass: %u surfaces, %u triangles "
                      "(%u DPVS-culled, %u frustum-culled, %u sky)\n",
                   drawnSurfaces, drawnTriangles, dpvsCulledSurfaces,
                   culledSurfaces, skippedSkySurfaces);
    }
}

void ConvertModelVertices(const GfxPackedVertex *source, const unsigned int count,
                          std::vector<MetalWorldVertex> *converted)
{
    converted->resize(count);
    for (unsigned int i = 0; i < count; ++i)
    {
        const GfxPackedVertex &src = source[i];
        MetalWorldVertex &dst = (*converted)[i];
        std::memcpy(dst.position, src.xyz, sizeof(dst.position));
        dst.positionPadding = 0.0f;
        Vec2UnpackTexCoords(src.texCoord, dst.uv);
        dst.lightmapUv[0] = 0.0f;
        dst.lightmapUv[1] = 0.0f;
        dst.color[0] = src.color.array[2] / 255.0f;
        dst.color[1] = src.color.array[1] / 255.0f;
        dst.color[2] = src.color.array[0] / 255.0f;
        dst.color[3] = src.color.array[3] / 255.0f;
        Vec3UnpackUnitVec(src.normal, dst.normal);
        Vec3UnpackUnitVec(src.tangent, dst.tangent);
        dst.binormalSign = src.binormalSign;
        dst.tangentPadding = 0.0f;
    }
}

bool BuffersForModelSurface(const XSurface *surface, id<MTLBuffer> *vertices,
                            id<MTLBuffer> *indices)
{
    if (!surface || !surface->verts0 || !surface->triIndices
        || !surface->vertCount || !surface->triCount)
        return false;
    const auto found = g_modelSurfaceBuffers.find(surface);
    if (found != g_modelSurfaceBuffers.end())
    {
        *vertices = (__bridge id<MTLBuffer>)found->second.vertices;
        *indices = (__bridge id<MTLBuffer>)found->second.indices;
        return *vertices && *indices;
    }

    std::vector<MetalWorldVertex> converted;
    ConvertModelVertices(surface->verts0, surface->vertCount, &converted);
    id<MTLBuffer> vertexBuffer = [g_device newBufferWithBytes:converted.data()
                                                       length:converted.size() * sizeof(MetalWorldVertex)
                                                      options:MTLResourceStorageModeShared];
    id<MTLBuffer> indexBuffer = [g_device newBufferWithBytes:surface->triIndices
                                                      length:static_cast<NSUInteger>(surface->triCount) * 3
                                                             * sizeof(uint16_t)
                                                     options:MTLResourceStorageModeShared];
    ModelSurfaceBuffers retained = {
        vertexBuffer ? (__bridge_retained void *)vertexBuffer : nullptr,
        indexBuffer ? (__bridge_retained void *)indexBuffer : nullptr,
    };
    g_modelSurfaceBuffers.emplace(surface, retained);
    *vertices = vertexBuffer;
    *indices = indexBuffer;
    return vertexBuffer && indexBuffer;
}

void PrewarmWorldResources(const GfxWorld *world)
{
    if (!world)
        return;

    const size_t textureBefore = g_textures.size() + g_skyTextures.size();
    const size_t surfaceBefore = g_modelSurfaceBuffers.size();
    const double start = CACurrentMediaTime();
    std::unordered_map<const Material *, bool> materials;
    std::unordered_map<const XModel *, bool> models;
    auto prewarmMaterial = [&](const Material *material) {
        if (!material || !material->textureTable
            || !materials.emplace(material, true).second)
        {
            return;
        }
        for (int textureIndex = 0; textureIndex < material->textureCount; ++textureIndex)
        {
            const GfxImage *const image =
                ImageForMaterialTextureDef(material->textureTable[textureIndex]);
            if (image && image->mapType != MAPTYPE_CUBE)
                TextureForImage(image);
        }
    };

    BuildWorldBuffers(world);
    TextureForSkyImage(world->skyImage);
    for (int surfaceIndex = 0; surfaceIndex < world->surfaceCount; ++surfaceIndex)
        prewarmMaterial(world->dpvs.surfaces[surfaceIndex].material);
    for (unsigned int lightmapIndex = 0;
         lightmapIndex < world->lightmapCount && world->lightmaps; ++lightmapIndex)
    {
        TextureForImage(world->lightmaps[lightmapIndex].primary);
        TextureForImage(world->lightmaps[lightmapIndex].secondary);
    }
    for (unsigned int probeIndex = 0; probeIndex < world->reflectionProbeCount; ++probeIndex)
        TextureForReflectionProbe(probeIndex);

    // FX definitions refer to materials indirectly, so they are not present in
    // the BSP surface lists above.  Preload their small atlases as well; the
    // first muzzle flash or bullet impact must not become an image-upload frame.
    for (int materialIndex = 0; materialIndex < rgp.materialCount; ++materialIndex)
    {
        const Material *const material = rgp.sortedMaterials[materialIndex];
        const char *const materialName = material && material->info.name
            ? material->info.name : "";
        const char *const techniqueName = material && material->techniqueSet
            && material->techniqueSet->name ? material->techniqueSet->name : "";
        if (std::strncmp(materialName, "gfx_", 4) == 0
            || std::strstr(techniqueName, "effect")
            || std::strstr(techniqueName, "distortion"))
        {
            prewarmMaterial(material);
        }
    }

    if (world->dpvs.smodelDrawInsts)
    {
        for (unsigned int instanceIndex = 0;
             instanceIndex < world->dpvs.smodelCount; ++instanceIndex)
        {
            const XModel *const model = world->dpvs.smodelDrawInsts[instanceIndex].model;
            if (!model || !models.emplace(model, true).second)
                continue;
            for (int lod = 0; lod < model->numLods; ++lod)
            {
                XSurface *surfaces = nullptr;
                const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
                Material **const modelMaterials = XModelGetSkins(model, lod);
                for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
                {
                    id<MTLBuffer> vertices = nil;
                    id<MTLBuffer> indices = nil;
                    if (surfaces)
                        BuffersForModelSurface(&surfaces[surfaceIndex], &vertices, &indices);
                    if (modelMaterials)
                        prewarmMaterial(modelMaterials[surfaceIndex]);
                }
            }
        }
    }
    Com_Printf(8,
               "[metal] prewarmed level resources: %zu textures, %zu model surfaces, "
               "%zu materials/%zu models in %.2fms\n",
               g_textures.size() + g_skyTextures.size() - textureBefore,
               g_modelSurfaceBuffers.size() - surfaceBefore,
               materials.size(), models.size(),
               (CACurrentMediaTime() - start) * 1000.0);
}

void PlacementMatrix(const GfxScaledPlacement &placement, float matrix[4][4])
{
    const float x = placement.base.quat[0];
    const float y = placement.base.quat[1];
    const float z = placement.base.quat[2];
    const float w = placement.base.quat[3];
    const float scale = placement.scale;

    matrix[0][0] = (1.0f - 2.0f * (y * y + z * z)) * scale;
    matrix[0][1] = (2.0f * (x * y + z * w)) * scale;
    matrix[0][2] = (2.0f * (x * z - y * w)) * scale;
    matrix[0][3] = 0.0f;
    matrix[1][0] = (2.0f * (x * y - z * w)) * scale;
    matrix[1][1] = (1.0f - 2.0f * (x * x + z * z)) * scale;
    matrix[1][2] = (2.0f * (y * z + x * w)) * scale;
    matrix[1][3] = 0.0f;
    matrix[2][0] = (2.0f * (x * z + y * w)) * scale;
    matrix[2][1] = (2.0f * (y * z - x * w)) * scale;
    matrix[2][2] = (1.0f - 2.0f * (x * x + y * y)) * scale;
    matrix[2][3] = 0.0f;
    matrix[3][0] = placement.base.origin[0];
    matrix[3][1] = placement.base.origin[1];
    matrix[3][2] = placement.base.origin[2];
    matrix[3][3] = 1.0f;
}

void PackedPlacementMatrix(const GfxPackedPlacement &placement, float matrix[4][4])
{
    for (int axis = 0; axis < 3; ++axis)
    {
        matrix[axis][0] = placement.axis[axis][0] * placement.scale;
        matrix[axis][1] = placement.axis[axis][1] * placement.scale;
        matrix[axis][2] = placement.axis[axis][2] * placement.scale;
        matrix[axis][3] = 0.0f;
    }
    matrix[3][0] = placement.origin[0];
    matrix[3][1] = placement.origin[1];
    matrix[3][2] = placement.origin[2];
    matrix[3][3] = 1.0f;
}

void BindShadowMaterial(id<MTLRenderCommandEncoder> encoder, const Material *material,
                        const bool model)
{
    const uint32_t alphaTest = MaterialAlphaTest(material);
    if (!alphaTest)
    {
        SetCachedRenderPipeline(encoder, model ? g_shadowModelPipeline
                                               : g_shadowWorldPipeline);
        return;
    }

    SetCachedRenderPipeline(encoder, model ? g_shadowModelAlphaPipeline
                                           : g_shadowWorldAlphaPipeline);
    [encoder setFragmentTexture:TextureForWorldMaterial(material) atIndex:0];
    [encoder setFragmentSamplerState:SamplerForMaterial(material) atIndex:0];
    const MetalShadowParams params{alphaTest, {0, 0, 0}};
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
}

bool EncodeShadowModelSurface(id<MTLRenderCommandEncoder> encoder,
                              const XSurface *surface,
                              const float modelMatrix[4][4],
                              const Material *material)
{
    id<MTLBuffer> vertices = nil;
    id<MTLBuffer> indices = nil;
    if (!BuffersForModelSurface(surface, &vertices, &indices))
        return false;

    BindShadowMaterial(encoder, material, true);
    [encoder setVertexBuffer:vertices offset:0 atIndex:0];
    [encoder setVertexBytes:modelMatrix length:sizeof(float) * 16 atIndex:2];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:static_cast<NSUInteger>(surface->triCount) * 3
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:indices
                 indexBufferOffset:0];
    return true;
}

void EncodeSunShadowCascade(id<MTLRenderCommandEncoder> encoder,
                            const GfxViewInfo &view, const int cascade,
                            unsigned int *worldSurfacesOut,
                            unsigned int *modelSurfacesOut)
{
    const GfxWorld *const world = rgp.world;
    const GfxSunShadowPartition &partition = view.sunShadow.partition[cascade];
    const float (*shadowMatrix)[4] = partition.shadowViewParms.viewProjectionMatrix.m;
    SetCachedDepthState(encoder, g_worldDepthState);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setDepthBias:1.0f slopeScale:2.0f clamp:0.0f];
    [encoder setVertexBytes:shadowMatrix length:sizeof(GfxMatrix) atIndex:1];

    unsigned int worldSurfaces = 0;
    if (BuildWorldBuffers(world))
    {
        [encoder setVertexBuffer:g_worldVertexBuffer offset:0 atIndex:0];
        const unsigned char *const visibility = world->dpvs.surfaceVisData[cascade + 1];
        const unsigned int begin = world->dpvs.litSurfsBegin;
        const unsigned int end = std::min(world->dpvs.emissiveSurfsEnd,
                                          static_cast<unsigned int>(world->surfaceCount));
        for (unsigned int sortedIndex = begin; sortedIndex < end; ++sortedIndex)
        {
            if (visibility && !visibility[sortedIndex])
                continue;
            if (world->dpvs.surfaceCastsSunShadow
                && !(world->dpvs.surfaceCastsSunShadow[sortedIndex >> 5]
                     & (1u << (sortedIndex & 31))))
            {
                continue;
            }
            const unsigned int surfaceIndex = world->dpvs.sortedSurfIndex
                ? world->dpvs.sortedSurfIndex[sortedIndex] : sortedIndex;
            if (surfaceIndex >= static_cast<unsigned int>(world->surfaceCount))
                continue;
            const GfxSurface &surface = world->dpvs.surfaces[surfaceIndex];
            const srfTriangles_t &tris = surface.tris;
            const NSUInteger indexCount = static_cast<NSUInteger>(tris.triCount) * 3;
            if (!indexCount || tris.baseIndex < 0 || tris.firstVertex < 0
                || static_cast<uint64_t>(tris.baseIndex) + indexCount
                    > static_cast<uint64_t>(world->indexCount))
            {
                continue;
            }
            BindShadowMaterial(encoder, surface.material, false);
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:indexCount
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:g_worldIndexBuffer
                         indexBufferOffset:static_cast<NSUInteger>(tris.baseIndex)
                                             * sizeof(uint16_t)
                             instanceCount:1
                                baseVertex:tris.firstVertex
                              baseInstance:0];
            ++worldSurfaces;
        }
    }

    unsigned int modelSurfaces = 0;
    const unsigned char *const staticVisibility = world->dpvs.smodelVisData[cascade + 1];
    for (unsigned int modelIndex = 0; modelIndex < world->dpvs.smodelCount; ++modelIndex)
    {
        if (staticVisibility && !staticVisibility[modelIndex])
            continue;
        const GfxStaticModelDrawInst &instance = world->dpvs.smodelDrawInsts[modelIndex];
        const XModel *const model = instance.model;
        if (!model || !model->surfs || !model->materialHandles || instance.placement.scale == 0.0f)
            continue;

        // Shadow DPVS has already chosen visibility. Use its camera LOD result
        // where available so the caster mesh matches the regular scene mesh.
        const float dx = instance.placement.origin[0] - view.viewParms.origin[0];
        const float dy = instance.placement.origin[1] - view.viewParms.origin[1];
        const float dz = instance.placement.origin[2] - view.viewParms.origin[2];
        int lod = XModelGetLodForDist(
            model, std::sqrt(dx * dx + dy * dy + dz * dz) / instance.placement.scale);
        if (lod < 0 || lod >= model->numLods)
            continue;
        XSurface *surfaces = nullptr;
        const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
        Material **materials = XModelGetSkins(model, lod);
        if (!surfaces || !materials)
            continue;
        float modelMatrix[4][4];
        PackedPlacementMatrix(instance.placement, modelMatrix);
        for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
        {
            if (EncodeShadowModelSurface(encoder, &surfaces[surfaceIndex], modelMatrix,
                                         materials[surfaceIndex]))
            {
                ++modelSurfaces;
            }
        }
    }

    // Rigid scene models (vehicles, dropped world models and script models)
    // also cast through CoD's sun partitions. Animated DObjs are added by the
    // skinned-caster path separately once their current pose is available.
    const unsigned int sceneModelCount = std::min(
        static_cast<unsigned int>(scene.sceneModelCount), 1024u);
    for (unsigned int sceneModelIndex = 0; sceneModelIndex < sceneModelCount;
         ++sceneModelIndex)
    {
        if ((scene.sceneModelVisData[cascade + 1][sceneModelIndex] & 1) == 0)
            continue;
        const GfxSceneModel &instance = scene.sceneModel[sceneModelIndex];
        const XModel *const model = instance.model;
        if (!model || !model->surfs || !model->materialHandles)
            continue;
        int lod = instance.info.lod;
        if (lod < 0 || lod >= model->numLods)
            lod = 0;
        XSurface *surfaces = nullptr;
        const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
        Material **materials = XModelGetSkins(model, lod);
        if (!surfaces || !materials)
            continue;
        float modelMatrix[4][4];
        PlacementMatrix(instance.placement, modelMatrix);
        for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
        {
            if (EncodeShadowModelSurface(encoder, &surfaces[surfaceIndex], modelMatrix,
                                         materials[surfaceIndex]))
            {
                ++modelSurfaces;
            }
        }
    }

    [encoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    *worldSurfacesOut = worldSurfaces;
    *modelSurfacesOut = modelSurfaces;
}

void EncodeSunShadows(id<MTLCommandBuffer> commandBuffer, const GfxViewInfo &view)
{
    if (!rgp.world || view.dynamicShadowType != SHADOW_MAP
        || view.sunShadow.partition[0].viewport.width <= 0
        || !g_shadowWorldPipeline || !g_shadowModelPipeline
        || !EnsureSunShadowTexture())
    {
        return;
    }

    unsigned int totalWorldSurfaces = 0;
    unsigned int totalModelSurfaces = 0;
    for (int cascade = 0; cascade < 2; ++cascade)
    {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.depthAttachment.texture = g_sunShadowTexture;
        pass.depthAttachment.slice = cascade;
        pass.depthAttachment.level = 0;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 1.0;
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        SetCachedViewport(encoder, MTLViewport{0.0, 0.0,
            static_cast<double>(g_sunShadowTexture.width),
            static_cast<double>(g_sunShadowTexture.height), 0.0, 1.0});
        unsigned int worldSurfaces = 0;
        unsigned int modelSurfaces = 0;
        EncodeSunShadowCascade(encoder, view, cascade,
                               &worldSurfaces, &modelSurfaces);
        [encoder endEncoding];
        totalWorldSurfaces += worldSurfaces;
        totalModelSurfaces += modelSurfaces;
    }

    static bool reported = false;
    if (g_traceRenderer && !reported)
    {
        reported = true;
        Com_Printf(8, "[metal] sun shadows: two 1024 cascades, %u world and %u model surfaces\n",
                   totalWorldSurfaces, totalModelSurfaces);
    }
}

void SetSceneDepthRange(id<MTLRenderCommandEncoder> encoder, const bool depthHack)
{
    // CoD4 reserves the first 1/64th of the hardware depth range for the
    // first-person weapon. Matching that split prevents sights and attachments
    // from being clipped by the world.
    const MTLViewport viewport = {
        0.0, 0.0,
        static_cast<double>(g_viewportWidth), static_cast<double>(g_viewportHeight),
        depthHack ? 0.0 : 0.015625,
        depthHack ? 0.015625 : 1.0,
    };
    SetCachedViewport(encoder, viewport);
}

bool EncodeModelSurfaceWithMatrix(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view,
                                  const XSurface *surface, const GfxPackedVertex *vertices,
                                  const float modelMatrix[4][4], const Material *material,
                                  const bool depthHack,
                                  const unsigned int reflectionProbeIndex = 0,
                                  const unsigned int lightingHandle = 0,
                                  const unsigned int primaryLightIndex = 0)
{
    if (!surface || !vertices || !surface->triIndices || !surface->vertCount || !surface->triCount)
        return false;

    id<MTLBuffer> vertexBuffer = nil;
    id<MTLBuffer> indexBuffer = nil;
    if (vertices == surface->verts0)
    {
        if (!BuffersForModelSurface(surface, &vertexBuffer, &indexBuffer))
            return false;
    }
    else
    {
        std::vector<MetalWorldVertex> converted;
        ConvertModelVertices(vertices, surface->vertCount, &converted);
        vertexBuffer = [g_device newBufferWithBytes:converted.data()
                                             length:converted.size() * sizeof(MetalWorldVertex)
                                            options:MTLResourceStorageModeShared];
        indexBuffer = [g_device newBufferWithBytes:surface->triIndices
                                            length:static_cast<NSUInteger>(surface->triCount) * 3
                                                   * sizeof(uint16_t)
                                           options:MTLResourceStorageModeShared];
        if (!vertexBuffer || !indexBuffer)
            return false;
    }

    GfxMatrix depthHackProjection{};
    GfxMatrix depthHackViewProjection{};
    const float (*viewProjection)[4] = view.viewParms.viewProjectionMatrix.m;
    if (depthHack)
    {
        depthHackProjection = view.viewParms.projectionMatrix;
        depthHackProjection.m[3][2] = view.viewParms.depthHackNearClip;
        MatrixMultiply44(view.viewParms.viewMatrix.m, depthHackProjection.m,
                         depthHackViewProjection.m);
        viewProjection = depthHackViewProjection.m;
    }

    SetSceneDepthRange(encoder, depthHack);
    SetMaterialPipeline(encoder, material, true, depthHack);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:viewProjection length:sizeof(GfxMatrix) atIndex:1];
    [encoder setVertexBytes:modelMatrix length:sizeof(float) * 16 atIndex:2];
    [encoder setFragmentSamplerState:g_worldSampler atIndex:0];
    [encoder setFragmentSamplerState:g_lightmapSampler atIndex:1];
    BindMaterialTextures(encoder, view, material, g_whiteTexture, g_whiteTexture, false, false,
                         reflectionProbeIndex, lightingHandle, primaryLightIndex);
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:static_cast<NSUInteger>(surface->triCount) * 3
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:indexBuffer
                 indexBufferOffset:0];
    return true;
}

bool EncodeModelSurface(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view,
                        const XSurface *surface, const GfxPackedVertex *vertices,
                        const GfxScaledPlacement &placement, const Material *material,
                        const bool depthHack,
                        const unsigned int reflectionProbeIndex = 0,
                        const unsigned int lightingHandle = 0,
                        const unsigned int primaryLightIndex = 0)
{
    float modelMatrix[4][4];
    PlacementMatrix(placement, modelMatrix);
    return EncodeModelSurfaceWithMatrix(encoder, view, surface, vertices, modelMatrix,
                                        material, depthHack, reflectionProbeIndex,
                                        lightingHandle, primaryLightIndex);
}

unsigned int EncodePlacedXModel(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view,
                                const XModel *model, const GfxScaledPlacement &placement,
                                const float radius)
{
    if (!model || !model->surfs || !model->materialHandles || placement.scale <= 0.0f)
        return 0;

    float bounds[2][3];
    for (int axis = 0; axis < 3; ++axis)
    {
        bounds[0][axis] = placement.base.origin[axis] - radius;
        bounds[1][axis] = placement.base.origin[axis] + radius;
    }
    if (BoundsOutsideView(bounds, view.viewParms.viewProjectionMatrix.m))
        return 0;

    const float dx = placement.base.origin[0] - view.viewParms.origin[0];
    const float dy = placement.base.origin[1] - view.viewParms.origin[1];
    const float dz = placement.base.origin[2] - view.viewParms.origin[2];
    const float distance = std::sqrt(dx * dx + dy * dy + dz * dz);
    int lod = XModelGetLodForDist(model, distance / placement.scale);
    if (lod < 0 || lod >= model->numLods)
        lod = 0;

    XSurface *surfaces = nullptr;
    const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
    Material **materials = XModelGetSkins(model, lod);
    if (!surfaces || !materials)
        return 0;

    const unsigned int reflectionProbeIndex = R_CalcReflectionProbeIndex(placement.base.origin);
    unsigned int drawn = 0;
    for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
    {
        if (EncodeModelSurface(encoder, view, &surfaces[surfaceIndex], surfaces[surfaceIndex].verts0,
                               placement, materials[surfaceIndex], false, reflectionProbeIndex))
            ++drawn;
    }
    return drawn;
}

unsigned int EncodePlacedBrushModel(id<MTLRenderCommandEncoder> encoder,
                                    const GfxViewInfo &view,
                                    const GfxBrushModel *bmodel,
                                    const GfxPlacement &placement,
                                    const float radius)
{
    const GfxWorld *const world = rgp.world;
    if (!world || !bmodel || !bmodel->surfaceCount || !g_worldVertexBuffer || !g_worldIndexBuffer)
        return 0;

    float bounds[2][3];
    for (int axis = 0; axis < 3; ++axis)
    {
        bounds[0][axis] = placement.origin[axis] - radius;
        bounds[1][axis] = placement.origin[axis] + radius;
    }
    if (BoundsOutsideView(bounds, view.viewParms.viewProjectionMatrix.m))
        return 0;

    GfxScaledPlacement scaledPlacement{};
    scaledPlacement.base = placement;
    scaledPlacement.scale = 1.0f;
    float modelMatrix[4][4];
    PlacementMatrix(scaledPlacement, modelMatrix);
    const unsigned int reflectionProbeIndex = R_CalcReflectionProbeIndex(placement.origin);
    unsigned int drawn = 0;
    for (unsigned int localSurface = 0; localSurface < bmodel->surfaceCount; ++localSurface)
    {
        const unsigned int surfaceIndex = bmodel->startSurfIndex + localSurface;
        if (surfaceIndex >= static_cast<unsigned int>(world->surfaceCount))
            break;
        const GfxSurface &surface = world->dpvs.surfaces[surfaceIndex];
        const srfTriangles_t &tris = surface.tris;
        const NSUInteger indexCount = static_cast<NSUInteger>(tris.triCount) * 3;
        if (!indexCount || tris.baseIndex < 0 || tris.firstVertex < 0
            || static_cast<uint64_t>(tris.baseIndex) + indexCount > static_cast<uint64_t>(world->indexCount)
            || static_cast<uint64_t>(tris.firstVertex) + tris.vertexCount > world->vertexCount)
            continue;
        if (surface.material && (surface.material->info.gameFlags & 8) != 0)
            continue;

        SetSceneDepthRange(encoder, false);
        SetMaterialPipeline(encoder, surface.material, true, false);
        SetCachedCullMode(encoder, MTLCullModeNone);
        [encoder setVertexBuffer:g_worldVertexBuffer offset:0 atIndex:0];
        [encoder setVertexBytes:view.viewParms.viewProjectionMatrix.m
                         length:sizeof(view.viewParms.viewProjectionMatrix.m)
                        atIndex:1];
        [encoder setVertexBytes:modelMatrix length:sizeof(modelMatrix) atIndex:2];
        [encoder setFragmentSamplerState:g_lightmapSampler atIndex:1];

        bool usesPrimaryLightmap = false;
        bool usesSecondaryLightmap = false;
        id<MTLTexture> primaryLightmap = g_whiteTexture;
        id<MTLTexture> secondaryLightmap = g_whiteTexture;
        if (surface.lightmapIndex != 31 && surface.lightmapIndex < world->lightmapCount
            && world->lightmaps)
        {
            const GfxLightmapArray &lightmaps = world->lightmaps[surface.lightmapIndex];
            if (lightmaps.primary)
            {
                if (id<MTLTexture> texture = TextureForImage(lightmaps.primary))
                {
                    primaryLightmap = texture;
                    usesPrimaryLightmap = true;
                }
            }
            if (lightmaps.secondary)
            {
                if (id<MTLTexture> texture = TextureForImage(lightmaps.secondary))
                {
                    secondaryLightmap = texture;
                    usesSecondaryLightmap = true;
                }
            }
        }
        BindMaterialTextures(encoder, view, surface.material, primaryLightmap, secondaryLightmap,
                             usesPrimaryLightmap, usesSecondaryLightmap, reflectionProbeIndex);
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:indexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:g_worldIndexBuffer
                     indexBufferOffset:static_cast<NSUInteger>(tris.baseIndex) * sizeof(uint16_t)
                         instanceCount:1
                            baseVertex:tris.firstVertex
                          baseInstance:0];
        ++drawn;
    }
    return drawn;
}

void EncodeDynamicEntities(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!rgp.world || (r_drawDynEnts && !r_drawDynEnts->current.enabled))
        return;

    unsigned int modelSurfaces = 0;
    unsigned int brushSurfaces = 0;
    unsigned int pieceSurfaces = 0;
    const unsigned int modelCount = DynEnt_GetEntityCount(DYNENT_COLL_CLIENT_MODEL);
    for (unsigned int dynEntId = 0; dynEntId < modelCount; ++dynEntId)
    {
        const DynEntityClient *client = DynEnt_GetClientEntity(dynEntId, DYNENT_DRAW_MODEL);
        if (!client || (client->flags & 2u) == 0)
            continue;
        const DynEntityDef *def = DynEnt_GetEntityDef(dynEntId, DYNENT_DRAW_MODEL);
        const DynEntityPose *pose = DynEnt_GetClientPose(dynEntId, DYNENT_DRAW_MODEL);
        if (!def || !pose || !def->xModel)
            continue;
        GfxScaledPlacement placement{};
        placement.base = pose->pose;
        placement.scale = 1.0f;
        modelSurfaces += EncodePlacedXModel(encoder, view, def->xModel, placement, pose->radius);
    }

    const unsigned int brushCount = DynEnt_GetEntityCount(DYNENT_COLL_CLIENT_BRUSH);
    for (unsigned int dynEntId = 0; dynEntId < brushCount; ++dynEntId)
    {
        const DynEntityClient *client = DynEnt_GetClientEntity(dynEntId, DYNENT_DRAW_BRUSH);
        if (!client || (client->flags & 2u) == 0)
            continue;
        const DynEntityDef *def = DynEnt_GetEntityDef(dynEntId, DYNENT_DRAW_BRUSH);
        const DynEntityPose *pose = DynEnt_GetClientPose(dynEntId, DYNENT_DRAW_BRUSH);
        if (!def || !pose || def->brushModel >= rgp.world->modelCount)
            continue;
        brushSurfaces += EncodePlacedBrushModel(
            encoder, view, &rgp.world->models[def->brushModel], pose->pose, pose->radius);
    }

    for (int pieceIndex = 0; pieceIndex < numPieces; ++pieceIndex)
    {
        const BreakablePiece &piece = g_breakablePieces[pieceIndex];
        if (!piece.active || !piece.model || !piece.physObjId)
            continue;
        GfxScaledPlacement placement{};
        Sys_EnterCriticalSection(CRITSECT_PHYSICS);
        dxBody *const body = Phys_ObjFromId(piece.physObjId);
        if (body)
            Phys_ObjGetInterpolatedState(PHYS_WORLD_FX, body, placement.base.origin, placement.base.quat);
        Sys_LeaveCriticalSection(CRITSECT_PHYSICS);
        if (!body)
            continue;
        placement.scale = 1.0f;
        pieceSurfaces += EncodePlacedXModel(
            encoder, view, piece.model, placement, XModelGetRadius(piece.model));
    }

    static const GfxWorld *reportedWorld = nullptr;
    if (reportedWorld != rgp.world)
    {
        reportedWorld = rgp.world;
        Com_Printf(8,
                   "[metal] dynamic pass: %u model entities/%u surfaces, "
                   "%u brush entities/%u surfaces, %d pieces/%u surfaces\n",
                   modelCount, modelSurfaces, brushCount, brushSurfaces,
                   numPieces, pieceSurfaces);
    }
}

void EncodeSceneBrushes(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!rgp.world || !scene.sceneBrushCount)
        return;

    const unsigned int brushCount = std::min(
        static_cast<unsigned int>(scene.sceneBrushCount), 512u);
    unsigned int visibleBrushes = 0;
    unsigned int drawnSurfaces = 0;
    for (unsigned int brushIndex = 0; brushIndex < brushCount; ++brushIndex)
    {
        // The low bit is camera visibility. Other bits are renderer state and
        // must not make an otherwise visible brush disappear.
        if ((scene.sceneBrushVisData[0][brushIndex] & 1) == 0)
            continue;

        const GfxSceneBrush &brush = scene.sceneBrush[brushIndex];
        if (!brush.bmodel || !brush.bmodel->surfaceCount)
            continue;

        // The writable bounds have already been transformed by the scene
        // linker. Derive a conservative radius around the placement origin so
        // the native frustum test cannot clip a rotated/off-centre mover.
        float radiusSquared = 0.0f;
        for (int corner = 0; corner < 8; ++corner)
        {
            float distanceSquared = 0.0f;
            for (int axis = 0; axis < 3; ++axis)
            {
                const float extent = (corner & (1 << axis))
                    ? brush.bmodel->writable.maxs[axis]
                    : brush.bmodel->writable.mins[axis];
                const float delta = extent - brush.placement.origin[axis];
                distanceSquared += delta * delta;
            }
            radiusSquared = std::max(radiusSquared, distanceSquared);
        }

        ++visibleBrushes;
        drawnSurfaces += EncodePlacedBrushModel(
            encoder, view, brush.bmodel, brush.placement,
            std::sqrt(radiusSquared));
    }

    if (g_traceRenderer && (g_frameCount % 300) == 0)
    {
        Com_Printf(8, "[metal] scene brush pass: %u/%u visible, %u surfaces\n",
                   visibleBrushes, brushCount, drawnSurfaces);
    }
}

void EncodeStaticModels(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!rgp.world || !rgp.world->dpvs.smodelDrawInsts || !rgp.world->dpvs.smodelInsts)
        return;

    static const GfxWorld *inventoriedWorld = nullptr;
    if (std::getenv("KISAK_MODEL_INVENTORY") && inventoriedWorld != rgp.world)
    {
        inventoriedWorld = rgp.world;
        for (unsigned int i = 0; i < rgp.world->dpvs.smodelCount; ++i)
        {
            const GfxStaticModelDrawInst &instance = rgp.world->dpvs.smodelDrawInsts[i];
            const XModel *const model = instance.model;
            Com_Printf(8, "[metal-model] %u '%s' origin=(%.1f %.1f %.1f) scale=%.3f "
                          "cull=%.1f lods=%u surfaces=%u\n",
                       i, model && model->name ? model->name : "(null)",
                       instance.placement.origin[0], instance.placement.origin[1],
                       instance.placement.origin[2], instance.placement.scale,
                       instance.cullDist, model ? model->numLods : 0,
                       model && model->numLods ? XModelGetSurfCount(model, 0) : 0);
        }
    }

    static const GfxWorld *materialInventoryWorld = nullptr;
    const char *const modelFilter = std::getenv("KISAK_MODEL_FILTER");
    if (modelFilter && modelFilter[0] && materialInventoryWorld != rgp.world)
    {
        materialInventoryWorld = rgp.world;
        std::unordered_map<const XModel *, bool> describedModels;
        for (unsigned int i = 0; i < rgp.world->dpvs.smodelCount; ++i)
        {
            const XModel *const model = rgp.world->dpvs.smodelDrawInsts[i].model;
            if (!model || !model->name || !std::strstr(model->name, modelFilter))
            {
                continue;
            }
            const GfxStaticModelDrawInst &drawInstance =
                rgp.world->dpvs.smodelDrawInsts[i];
            Com_Printf(8, "[metal-model-material]   instance=%u origin=(%.1f %.1f %.1f) "
                          "probe=%u lightHandle=%u primaryLight=%u\n",
                       i, drawInstance.placement.origin[0], drawInstance.placement.origin[1],
                       drawInstance.placement.origin[2], drawInstance.reflectionProbeIndex,
                       drawInstance.lightingHandle, drawInstance.primaryLightIndex);
            if (!describedModels.emplace(model, true).second)
                continue;
            Com_Printf(8, "[metal-model-material] model='%s' lods=%u\n",
                       model->name, model->numLods);
            for (int lod = 0; lod < model->numLods; ++lod)
            {
                XSurface *surfaces = nullptr;
                const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
                Material **const materials = XModelGetSkins(model, lod);
                for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
                {
                    const Material *const material = materials ? materials[surfaceIndex] : nullptr;
                    Com_Printf(8, "[metal-model-material]   lod=%d surf=%d verts=%u tris=%u mat='%s'",
                               lod, surfaceIndex, surfaces ? surfaces[surfaceIndex].vertCount : 0,
                               surfaces ? surfaces[surfaceIndex].triCount : 0,
                               material && material->info.name ? material->info.name : "(null)");
                    if (surfaces && surfaces[surfaceIndex].verts0
                        && surfaces[surfaceIndex].vertCount)
                    {
                        unsigned char minimum[4] = {255, 255, 255, 255};
                        unsigned char maximum[4] = {};
                        for (unsigned int vertexIndex = 0;
                             vertexIndex < surfaces[surfaceIndex].vertCount; ++vertexIndex)
                        {
                            const GfxColor &vertexColor =
                                surfaces[surfaceIndex].verts0[vertexIndex].color;
                            for (int channel = 0; channel < 4; ++channel)
                            {
                                minimum[channel] = std::min(minimum[channel],
                                                            vertexColor.array[channel]);
                                maximum[channel] = std::max(maximum[channel],
                                                            vertexColor.array[channel]);
                            }
                        }
                        Com_Printf(8, " vertexBGRA=[%u..%u %u..%u %u..%u %u..%u]",
                                   minimum[0], maximum[0], minimum[1], maximum[1],
                                   minimum[2], maximum[2], minimum[3], maximum[3]);
                    }
                    if (material && material->textureTable)
                    {
                        for (int textureIndex = 0; textureIndex < material->textureCount; ++textureIndex)
                        {
                            const MaterialTextureDef &texture = material->textureTable[textureIndex];
                            const GfxImage *const image = ImageForMaterialTextureDef(texture);
                            Com_Printf(8, " [%u:%s]", texture.semantic,
                                       image && image->name ? image->name : "(null)");
                        }
                    }
                    Com_Printf(8, "\n");
                }
            }
        }
    }

    unsigned int visibleModels = 0;
    unsigned int drawnSurfaces = 0;
    unsigned int dpvsRejectedModels = 0;
    unsigned int capturedVisibilityCount = 0;
    const unsigned char *cameraVisibility =
        R_GetCameraStaticModelVisibility(&capturedVisibilityCount);
    if (capturedVisibilityCount != rgp.world->dpvs.smodelCount)
        cameraVisibility = rgp.world->dpvs.smodelVisData[0];
    // An exterior/free-camera position can sit outside every BSP cell.  The
    // legacy portal walker then leaves this entire array clear; treating that
    // as authoritative would erase every static prop.  Use DPVS when it
    // contains a real result, otherwise retain the conservative frustum path.
    const bool hasCameraVisibility = cameraVisibility
        && std::any_of(cameraVisibility,
                       cameraVisibility + rgp.world->dpvs.smodelCount,
                       [](const unsigned char value) { return value != 0; });
    for (unsigned int i = 0; i < rgp.world->dpvs.smodelCount; ++i)
    {
        // The front end has already portal/occlusion/frustum-culled static models
        // into this byte array.  Re-testing only the frustum here drew thousands of
        // models through walls; exterior vehicle clusters made that mistake
        // especially expensive when the camera faced them.
        if (hasCameraVisibility && !cameraVisibility[i])
        {
            ++dpvsRejectedModels;
            continue;
        }
        const GfxStaticModelInst &bounds = rgp.world->dpvs.smodelInsts[i];
        const float (*modelBounds)[3] = reinterpret_cast<const float (*)[3]>(&bounds.mins);
        if (BoundsOutsideView(modelBounds, view.viewParms.viewProjectionMatrix.m))
            continue;

        const GfxStaticModelDrawInst &instance = rgp.world->dpvs.smodelDrawInsts[i];
        const XModel *const model = instance.model;
        if (!model || !model->surfs || !model->materialHandles || instance.placement.scale == 0.0f)
            continue;
        const float dx = instance.placement.origin[0] - view.viewParms.origin[0];
        const float dy = instance.placement.origin[1] - view.viewParms.origin[1];
        const float dz = instance.placement.origin[2] - view.viewParms.origin[2];
        const float originDistance = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (instance.cullDist > 0.0f && originDistance >= instance.cullDist)
            continue;
        const int lod = XModelGetLodForDist(model, originDistance / instance.placement.scale);
        if (lod < 0 || lod >= model->numLods)
            continue;

        XSurface *surfaces = nullptr;
        const int surfaceCount = XModelGetSurfaces(model, &surfaces, lod);
        Material **materials = XModelGetSkins(model, lod);
        if (!surfaces || !materials)
            continue;
        float modelMatrix[4][4];
        PackedPlacementMatrix(instance.placement, modelMatrix);
        ++visibleModels;
        for (int surfaceIndex = 0; surfaceIndex < surfaceCount; ++surfaceIndex)
        {
            if (EncodeModelSurfaceWithMatrix(encoder, view, &surfaces[surfaceIndex],
                                             surfaces[surfaceIndex].verts0, modelMatrix,
                                             materials[surfaceIndex], false,
                                             instance.reflectionProbeIndex,
                                             instance.lightingHandle,
                                             instance.primaryLightIndex))
                ++drawnSurfaces;
        }
    }

    static const GfxWorld *reportedWorld = nullptr;
    static int lastStatsFrame = -120;
    if (reportedWorld != rgp.world
        || (g_traceRenderer && g_frameCount - lastStatsFrame >= 120))
    {
        reportedWorld = rgp.world;
        lastStatsFrame = g_frameCount;
        Com_Printf(8,
                   "[metal] static model pass frame=%d view=(%.1f %.1f %.1f): "
                   "%u/%u visible models, %u surfaces (%u DPVS-culled)\n",
                   g_frameCount, view.viewParms.origin[0], view.viewParms.origin[1],
                   view.viewParms.origin[2],
                   visibleModels, rgp.world->dpvs.smodelCount, drawnSurfaces,
                   dpvsRejectedModels);
    }
}

void EncodeSceneModels(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    unsigned int modelSurfaces = 0;
    unsigned int dobjSurfaces = 0;
    unsigned int visibleSceneModels = 0;
    unsigned int frustumCulledSceneModels = 0;
    const unsigned int sceneModelCount = std::min(static_cast<unsigned int>(scene.sceneModelCount), 1024u);
    for (unsigned int i = 0; i < sceneModelCount; ++i)
    {
        if ((scene.sceneModelVisData[0][i] & 1) == 0)
            continue;
        const GfxSceneModel &sceneModel = scene.sceneModel[i];
        const XModel *model = sceneModel.model;
        if (!model || !model->surfs || !model->materialHandles)
            continue;
        // Unlinked script models such as destructible map vehicles do not get
        // portal/entity visibility bits. Keep the engine's conservative sphere
        // test here so a stale/broad visibility byte cannot submit every car.
        const float radius = std::max(sceneModel.radius, 0.0f);
        const float sceneModelBounds[2][3] = {
            {sceneModel.placement.base.origin[0] - radius,
             sceneModel.placement.base.origin[1] - radius,
             sceneModel.placement.base.origin[2] - radius},
            {sceneModel.placement.base.origin[0] + radius,
             sceneModel.placement.base.origin[1] + radius,
             sceneModel.placement.base.origin[2] + radius},
        };
        if (BoundsOutsideView(sceneModelBounds,
                              view.viewParms.viewProjectionMatrix.m))
        {
            ++frustumCulledSceneModels;
            continue;
        }
        ++visibleSceneModels;
        const char *const modelFilter = std::getenv("KISAK_MODEL_FILTER");
        if (modelFilter && modelFilter[0] && model->name
            && std::strstr(model->name, modelFilter))
        {
            static unsigned int reportedFilteredSceneModels = 0;
            if (reportedFilteredSceneModels++ < 64)
            {
                const unsigned int calculatedProbe = rgp.world
                    ? R_CalcReflectionProbeIndex(rgp.world,
                        sceneModel.placement.base.origin) : 0;
                Com_Printf(8, "[metal-scene-model] frame=%d index=%u model='%s' "
                              "origin=(%.1f %.1f %.1f) radius=%.1f probe=%u/%u "
                              "lightHandle=%u lod=%d vis=%u\n",
                           g_frameCount, i, model->name,
                           sceneModel.placement.base.origin[0],
                           sceneModel.placement.base.origin[1],
                           sceneModel.placement.base.origin[2],
                           radius, sceneModel.reflectionProbeIndex, calculatedProbe,
                           sceneModel.cachedLightingHandle
                               ? *sceneModel.cachedLightingHandle : 0,
                           sceneModel.info.lod,
                           scene.sceneModelVisData[0][i]);
            }
        }
        if (g_traceRenderer && model->name && std::strstr(model->name, "fx_") != nullptr)
        {
            static std::unordered_map<const XModel *, bool> reportedSceneModels;
            if (reportedSceneModels.size() < 256
                && reportedSceneModels.emplace(model, true).second)
            {
                Com_Printf(8,
                           "[metal] scene model '%s': bones=%u roots=%u lods=%d "
                           "scale=%.3f origin=(%.2f %.2f %.2f) radius=%.2f\n",
                           model->name ? model->name : "(unnamed)", model->numBones,
                           model->numRootBones, model->numLods, sceneModel.placement.scale,
                           sceneModel.placement.base.origin[0], sceneModel.placement.base.origin[1],
                           sceneModel.placement.base.origin[2], sceneModel.radius);
                for (int traceLod = 0; traceLod < model->numLods; ++traceLod)
                {
                    XSurface *traceSurfaces = nullptr;
                    const int traceCount = XModelGetSurfaces(model, &traceSurfaces, traceLod);
                    Material **const traceMaterials = XModelGetSkins(model, traceLod);
                    for (int traceSurface = 0; traceSurface < traceCount; ++traceSurface)
                    {
                        const XSurface &surface = traceSurfaces[traceSurface];
                        const Material *const material = traceMaterials
                            ? traceMaterials[traceSurface] : nullptr;
                        Com_Printf(8,
                                   "[metal]   lod=%d surf=%d mat='%s' verts=%u tris=%u "
                                   "deformed=%d rigidLists=%u\n",
                                   traceLod, traceSurface,
                                   material && material->info.name
                                       ? material->info.name : "(null)",
                                   surface.vertCount, surface.triCount, surface.deformed,
                                   surface.vertListCount);
                    }
                }
            }
        }
        int lod = sceneModel.info.lod;
        if (lod < 0 || lod >= model->numLods)
            lod = 0;
        XSurface *surfaces = nullptr;
        const int count = XModelGetSurfaces(model, &surfaces, lod);
        Material **materials = XModelGetSkins(model, lod);
        const unsigned int lightingHandle = sceneModel.cachedLightingHandle
            ? *sceneModel.cachedLightingHandle : 0;
        GfxLightingInfo lightingInfo{};
        const bool hasLightingInfo =
            R_GetDynamicModelLightingInfo(lightingHandle, &lightingInfo);
        // R_AddAllSceneEntSurfacesCamera normally fills this as part of D3D
        // draw-surface generation.  The native backend does not consume those
        // draw surfaces, and destructible map cars can arrive with no lighting
        // cache entry and probe zero.  Select the same cell-local probe here so
        // they do not all reflect the map's global fallback cubemap.
        const unsigned int reflectionProbeIndex = hasLightingInfo
            ? lightingInfo.reflectionProbeIndex
            : (rgp.world
                ? R_CalcReflectionProbeIndex(rgp.world,
                    sceneModel.placement.base.origin)
                : sceneModel.reflectionProbeIndex);
        for (int surfaceIndex = 0; surfaceIndex < count; ++surfaceIndex)
        {
            if (EncodeModelSurface(encoder, view, &surfaces[surfaceIndex], surfaces[surfaceIndex].verts0,
                                   sceneModel.placement, materials[surfaceIndex], false,
                                   reflectionProbeIndex, lightingHandle,
                                   lightingInfo.primaryLightIndex))
                ++modelSurfaces;
        }
    }

    const unsigned int sceneDObjCount = std::min(static_cast<unsigned int>(scene.sceneDObjCount), 512u);
    for (unsigned int i = 0; i < sceneDObjCount; ++i)
    {
        GfxSceneEntity &entity = scene.sceneDObj[i];
        const DObj_s *obj = entity.obj;
        const unsigned int renderFxFlags = entity.gfxEntIndex && frontEndDataOut
            ? frontEndDataOut->gfxEnts[entity.gfxEntIndex].renderFxFlags
            : 0;
        const bool depthHack = (renderFxFlags & 2) != 0;
        if (obj && !entity.cull.skinnedSurfs.firstSurf && entity.cull.state < CULL_STATE_DONE)
        {
            R_SkinAndBoundSceneEnt(&entity);
            R_WaitWorkerCmdsOfType(WRKCMD_SKIN_XMODEL);
        }
        static bool reportedAnyDObj = false;
        if (g_traceRenderer && !reportedAnyDObj)
        {
            reportedAnyDObj = true;
            Com_Printf(8, "[metal] raw DObj %u: vis=%u ent=%u gfxEnt=%u cullState=%u "
                          "renderFx=%08x obj=%p firstSurf=%p lightHandle=%u "
                          "lightOrigin=(%.2f %.2f %.2f) patches=%d\n",
                       i, scene.sceneDObjVisData[0][i], entity.entnum, entity.gfxEntIndex,
                       entity.cull.state, renderFxFlags, obj, entity.cull.skinnedSurfs.firstSurf,
                       entity.info.cachedLightingHandle ? *entity.info.cachedLightingHandle : 0,
                       entity.lightingOrigin[0], entity.lightingOrigin[1], entity.lightingOrigin[2],
                       frontEndDataOut ? frontEndDataOut->modelLightingPatchCount : 0);
        }
        // The low bit is camera visibility; other bits carry renderer state.
        // Testing equality with 1 incorrectly discarded entities marked 3.
        // Depth-hacked entities are first-person view models. The legacy DPVS
        // camera byte is left at zero for them because they bypass world
        // visibility; nevertheless they must always be submitted.
        if ((scene.sceneDObjVisData[0][i] & 1) == 0 && !depthHack)
            continue;
        if (!obj)
            continue;

        const bool traceAnimation = depthHack && std::getenv("KISAK_ANIM_TRACE") != nullptr;
        const DObjAnimMat *const boneMatrices = traceAnimation ? DObjGetRotTransArray(obj) : nullptr;
        static const DObj_s *describedViewModel = nullptr;
        if (boneMatrices && describedViewModel != obj)
        {
            describedViewModel = obj;
            Com_Printf(8, "[metal-anim] viewmodel ent=%u bones=%d", entity.entnum, DObjNumBones(obj));
            for (int boneIndex = 0; boneIndex < DObjNumBones(obj); ++boneIndex)
                Com_Printf(8, " [%d:%s]", boneIndex, DObjGetBoneName(obj, boneIndex));
            Com_Printf(8, "\n");
            for (int modelIndex = 0, firstBone = 0; modelIndex < DObjGetNumModels(obj); ++modelIndex)
            {
                const XModel *const traceModel = DObjGetModel(obj, modelIndex);
                if (!traceModel)
                    continue;
                Com_Printf(8, "[metal-anim] model=%d '%s' firstBone=%d bones=%u roots=%u\n",
                           modelIndex, traceModel->name, firstBone,
                           traceModel->numBones, traceModel->numRootBones);
                for (int localBone = 0; localBone < traceModel->numBones; ++localBone)
                {
                    const char *const boneName = DObjGetBoneName(obj, firstBone + localBone);
                    if (localBone != 0
                        && !std::strstr(boneName, "clip")
                        && !std::strstr(boneName, "mag")
                        && !std::strstr(boneName, "flash")
                        && !std::strstr(boneName, "weapon")
                        && !std::strstr(boneName, "gun")
                        && !std::strstr(boneName, "bolt")
                        && !std::strstr(boneName, "trigger")
                        && !std::strstr(boneName, "slide"))
                    {
                        continue;
                    }
                    const DObjAnimMat &base = traceModel->baseMat[localBone];
                    const int parentOffset = localBone < traceModel->numRootBones
                        ? 0
                        : traceModel->parentList[localBone - traceModel->numRootBones];
                    Com_Printf(8,
                               "[metal-anim]   base=%d:%s parentOffset=%d "
                               "t=(%.3f %.3f %.3f) q=(%.3f %.3f %.3f %.3f) w=%.3f\n",
                               firstBone + localBone, boneName, parentOffset,
                               base.trans[0], base.trans[1], base.trans[2],
                               base.quat[0], base.quat[1], base.quat[2], base.quat[3],
                               base.transWeight);
                }
                for (int lodIndex = 0; lodIndex < traceModel->numLods; ++lodIndex)
                {
                    XSurface *traceSurfaces = nullptr;
                    const int traceSurfaceCount = XModelGetSurfaces(traceModel, &traceSurfaces, lodIndex);
                    Material **const traceMaterials = XModelGetSkins(traceModel, lodIndex);
                    for (int surfaceIndex = 0; surfaceIndex < traceSurfaceCount; ++surfaceIndex)
                    {
                        const XSurface &surface = traceSurfaces[surfaceIndex];
                        const Material *const material = traceMaterials ? traceMaterials[surfaceIndex] : nullptr;
                        Com_Printf(8,
                                   "[metal-anim]   lod=%d surf=%d mat='%s' verts=%u tris=%u "
                                   "deformed=%d rigidLists=%u weights=%d/%d/%d/%d "
                                   "parts=%08x/%08x/%08x/%08x",
                                   lodIndex, surfaceIndex,
                                   material && material->info.name ? material->info.name : "(null)",
                                   surface.vertCount, surface.triCount, surface.deformed,
                                   surface.vertListCount,
                                   surface.vertInfo.vertCount[0], surface.vertInfo.vertCount[1],
                                   surface.vertInfo.vertCount[2], surface.vertInfo.vertCount[3],
                                   surface.partBits[0], surface.partBits[1],
                                   surface.partBits[2], surface.partBits[3]);
                        for (unsigned int rigidIndex = 0; rigidIndex < surface.vertListCount; ++rigidIndex)
                        {
                            const int localBone = surface.vertList[rigidIndex].boneOffset >> 6;
                            const int globalBone = firstBone + localBone;
                            Com_Printf(8, " [rigid=%u bone=%d:%s verts=%u]", rigidIndex,
                                       globalBone,
                                       globalBone < DObjNumBones(obj)
                                           ? DObjGetBoneName(obj, globalBone) : "(invalid)",
                                       surface.vertList[rigidIndex].vertCount);
                        }
                        Com_Printf(8, "\n");
                    }
                }
                firstBone += traceModel->numBones;
            }
        }
        static int lastAnimationTraceFrame = -1;
        const bool sampleAnimation = boneMatrices
            && g_frameCount != lastAnimationTraceFrame
            && (g_frameCount % 6) == 0;
        if (sampleAnimation)
        {
            lastAnimationTraceFrame = g_frameCount;
            Com_Printf(8, "[metal-anim] frame=%d", g_frameCount);
            for (int boneIndex = 0; boneIndex < DObjNumBones(obj); ++boneIndex)
            {
                const char *const boneName = DObjGetBoneName(obj, boneIndex);
                if (boneIndex != 0
                    && !std::strstr(boneName, "clip")
                    && !std::strstr(boneName, "mag")
                    && !std::strstr(boneName, "flash")
                    && !std::strstr(boneName, "weapon")
                    && !std::strstr(boneName, "gun")
                    && !std::strstr(boneName, "bolt")
                    && !std::strstr(boneName, "trigger")
                    && !std::strstr(boneName, "slide"))
                {
                    continue;
                }
                // The animation array is intentionally only populated for the
                // surface hierarchy requested this frame.  Reading an absent
                // tag (tag_flash is normally requested only while an effect is
                // bolted to it) reports the allocator's NaN fill and falsely
                // makes a healthy skeleton look corrupt.
                if (!obj->skel.partBits.skel.testBit(boneIndex))
                {
                    Com_Printf(8, " [%d:%s uncomputed]", boneIndex, boneName);
                    continue;
                }
                const DObjAnimMat &matrix = boneMatrices[boneIndex];
                const float worldPosition[3] = {
                    matrix.trans[0] + view.sceneDef.viewOffset[0],
                    matrix.trans[1] + view.sceneDef.viewOffset[1],
                    matrix.trans[2] + view.sceneDef.viewOffset[2],
                };
                const float (*const viewProjection)[4] = view.viewParms.viewProjectionMatrix.m;
                const float clipX = worldPosition[0] * viewProjection[0][0]
                    + worldPosition[1] * viewProjection[1][0]
                    + worldPosition[2] * viewProjection[2][0]
                    + viewProjection[3][0];
                const float clipY = worldPosition[0] * viewProjection[0][1]
                    + worldPosition[1] * viewProjection[1][1]
                    + worldPosition[2] * viewProjection[2][1]
                    + viewProjection[3][1];
                const float clipW = worldPosition[0] * viewProjection[0][3]
                    + worldPosition[1] * viewProjection[1][3]
                    + worldPosition[2] * viewProjection[2][3]
                    + viewProjection[3][3];
                const float screenX = clipW != 0.0f
                    ? (clipX / clipW * 0.5f + 0.5f) * g_viewportWidth : 0.0f;
                const float screenY = clipW != 0.0f
                    ? (0.5f - clipY / clipW * 0.5f) * g_viewportHeight : 0.0f;
                Com_Printf(8,
                           " [%d:%s t=(%.3f %.3f %.3f) q=(%.3f %.3f %.3f %.3f) "
                           "w=%.3f screen=(%.1f %.1f)]",
                           boneIndex, boneName,
                           matrix.trans[0], matrix.trans[1], matrix.trans[2],
                           matrix.quat[0], matrix.quat[1], matrix.quat[2], matrix.quat[3],
                           matrix.transWeight, screenX, screenY);
            }
            Com_Printf(8, "\n");
        }
        unsigned int hiddenParts[4] = {};
        DObjGetHidePartBits(obj, hiddenParts);
        const int modelCount = DObjGetNumModels(obj);
        const unsigned int lightingHandle = entity.info.cachedLightingHandle
            ? *entity.info.cachedLightingHandle : 0;
        GfxLightingInfo lightingInfo{};
        const bool hasLightingInfo =
            R_GetDynamicModelLightingInfo(lightingHandle, &lightingInfo);
        // A newly visible animated entity can be skinned before the legacy
        // draw-surface path has allocated its model-light cache entry.  Probe
        // zero is the map-wide fallback and is not spatially representative;
        // on Vacant it turns nearby SAS characters bright red.  Resolve the
        // same cell-local probe the model-light allocator will assign, just as
        // the scene-model path above does for uncached destructibles.
        const unsigned int reflectionProbeIndex = hasLightingInfo
            ? lightingInfo.reflectionProbeIndex
            : (rgp.world
                ? R_CalcReflectionProbeIndex(rgp.world, entity.lightingOrigin)
                : entity.reflectionProbeIndex);
        static bool reportedDObj = false;
        if (g_traceRenderer && !reportedDObj)
        {
            reportedDObj = true;
            Com_Printf(8, "[metal] DObj %u: ent=%u models=%d depthHack=%d firstSurf=%p "
                          "hidden=%08x/%08x/%08x/%08x\n",
                       i, entity.entnum, modelCount, depthHack,
                       entity.cull.skinnedSurfs.firstSurf, hiddenParts[0], hiddenParts[1],
                       hiddenParts[2], hiddenParts[3]);
            for (int modelIndex = 0; modelIndex < modelCount; ++modelIndex)
            {
                const XModel *model = DObjGetModel(obj, modelIndex);
                Com_Printf(8, "[metal]   model %d: '%s' cullLod=%d lods=%d surfaces=%u\n",
                           modelIndex, model && model->name ? model->name : "(null)",
                           entity.cull.lods[modelIndex], model ? model->numLods : 0,
                           model && model->numLods > 0 ? XModelGetSurfCount(model, 0) : 0);
            }
        }
        const unsigned char *modelSurf = static_cast<const unsigned char *>(entity.cull.skinnedSurfs.firstSurf);
        GfxScaledPlacement skinnedPlacement{};
        skinnedPlacement.base.quat[3] = 1.0f;
        skinnedPlacement.base.origin[0] = view.sceneDef.viewOffset[0];
        skinnedPlacement.base.origin[1] = view.sceneDef.viewOffset[1];
        skinnedPlacement.base.origin[2] = view.sceneDef.viewOffset[2];
        skinnedPlacement.scale = 1.0f;
        for (int modelIndex = 0; modelIndex < modelCount; ++modelIndex)
        {
            const XModel *model = DObjGetModel(obj, modelIndex);
            if (!model || !model->surfs || !model->materialHandles)
                continue;
            int lod = entity.cull.lods[modelIndex];
            if (lod < 0 || lod >= model->numLods)
                lod = 0;
            XSurface *surfaces = nullptr;
            const int count = XModelGetSurfaces(model, &surfaces, lod);
            Material **materials = XModelGetSkins(model, lod);
            for (int surfaceIndex = 0; surfaceIndex < count; ++surfaceIndex)
            {
                const XSurface &surface = surfaces[surfaceIndex];
                if (modelSurf)
                {
                    const auto *const skinned = reinterpret_cast<const GfxModelSkinnedSurface *>(modelSurf);
                    if (skinned->skinnedCachedOffset == -3)
                    {
                        modelSurf += GFX_HIDDEN_MODEL_SURFACE_SIZE;
                        continue;
                    }
                    if (skinned->skinnedCachedOffset == -2)
                    {
                        const auto *const rigid = reinterpret_cast<const GfxModelRigidSurface *>(modelSurf);
                        const XSurface *const encodedSurface = rigid->surf.xsurf ? rigid->surf.xsurf : &surface;
                        if (EncodeModelSurface(encoder, view, encodedSurface, encodedSurface->verts0,
                                               rigid->placement, materials[surfaceIndex], depthHack,
                                               reflectionProbeIndex, lightingHandle,
                                               lightingInfo.primaryLightIndex))
                            ++dobjSurfaces;
                        modelSurf += sizeof(GfxModelRigidSurface);
                        continue;
                    }

                    const GfxPackedVertex *skinnedVertices = nullptr;
                    if (skinned->skinnedCachedOffset >= 0 && gfxBuf.skinnedCacheLockAddr)
                    {
                        skinnedVertices = reinterpret_cast<const GfxPackedVertex *>(
                            gfxBuf.skinnedCacheLockAddr + skinned->skinnedCachedOffset);
                    }
                    else if (skinned->skinnedCachedOffset == -1)
                    {
                        skinnedVertices = skinned->skinnedVert;
                    }
                    const XSurface *const encodedSurface = skinned->xsurf ? skinned->xsurf : &surface;
                    if (skinnedVertices
                        && EncodeModelSurface(encoder, view, encodedSurface, skinnedVertices,
                                              skinnedPlacement, materials[surfaceIndex], depthHack,
                                              reflectionProbeIndex, lightingHandle,
                                              lightingInfo.primaryLightIndex))
                    {
                        ++dobjSurfaces;
                    }
                    modelSurf += sizeof(GfxModelSkinnedSurface);
                    continue;
                }

                // Fallback for a model whose pose could not be generated. This
                // remains useful for truly rigid world entities, but animated
                // view models normally take the descriptor path above.
                if (!surface.deformed
                    && EncodeModelSurface(encoder, view, &surface, surface.verts0, entity.placement,
                                          materials[surfaceIndex], depthHack,
                                          reflectionProbeIndex, lightingHandle,
                                          lightingInfo.primaryLightIndex))
                {
                    ++dobjSurfaces;
                }
            }
        }
    }

    static int lastModelStatsFrame = -120;
    if ((modelSurfaces || dobjSurfaces)
        && (lastModelStatsFrame < 0
            || (g_traceRenderer && g_frameCount - lastModelStatsFrame >= 120)))
    {
        lastModelStatsFrame = g_frameCount;
        Com_Printf(8, "[metal] model pass frame=%d: %u/%u scene models, "
                      "%u scene surfaces, %u DObj surfaces (%u frustum-culled)\n",
                   g_frameCount, visibleSceneModels, sceneModelCount,
                   modelSurfaces, dobjSurfaces, frustumCulledSceneModels);
    }
}

void EncodeCodeMeshes(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!frontEndDataOut || !g_effectPipeline || !g_effectDepthState)
        return;
    const GfxMeshData &mesh = frontEndDataOut->codeMesh;
    const unsigned int vertexCount = mesh.vertSize
        ? mesh.vb.used / mesh.vertSize
        : 0;
    if (!frontEndDataOut->codeMeshCount || !vertexCount || !mesh.indexCount
        || !mesh.vb.cpuData || !mesh.indices)
        return;

    std::vector<MetalWorldVertex> converted;
    ConvertModelVertices(reinterpret_cast<const GfxPackedVertex *>(mesh.vb.cpuData),
                         vertexCount, &converted);
    id<MTLBuffer> vertexBuffer = [g_device newBufferWithBytes:converted.data()
                                                       length:converted.size() * sizeof(MetalWorldVertex)
                                                      options:MTLResourceStorageModeShared];
    id<MTLBuffer> indexBuffer = [g_device newBufferWithBytes:mesh.indices
                                                      length:static_cast<NSUInteger>(mesh.indexCount)
                                                             * sizeof(uint16_t)
                                                     options:MTLResourceStorageModeShared];
    if (!vertexBuffer || !indexBuffer)
        return;

    static const float identity[4][4] = {
        {1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1},
    };
    bool rendered[2048] = {};
    unsigned int drawCount = 0;
    unsigned int skippedType = 0;
    unsigned int skippedObject = 0;
    unsigned int skippedMaterial = 0;
    unsigned int skippedIndices = 0;
    unsigned int skippedRange = 0;
    SetSceneDepthRange(encoder, false);
    SetCachedRenderPipeline(encoder, g_effectPipeline);
    SetCachedDepthState(encoder, g_effectDepthState);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:view.viewParms.viewProjectionMatrix.m
                     length:sizeof(view.viewParms.viewProjectionMatrix.m)
                    atIndex:1];
    [encoder setVertexBytes:identity length:sizeof(identity) atIndex:2];
    [encoder setFragmentSamplerState:g_worldSampler atIndex:0];

    static constexpr int effectRegions[] = {
        DRAW_SURF_FX_CAMERA_LIT,
        DRAW_SURF_FX_CAMERA_LIT_AUTO,
        DRAW_SURF_FX_CAMERA_LIT_DECAL,
        DRAW_SURF_FX_CAMERA_EMISSIVE,
        DRAW_SURF_FX_CAMERA_EMISSIVE_AUTO,
        DRAW_SURF_FX_CAMERA_EMISSIVE_DECAL,
    };
    for (const int region : effectRegions)
    {
        const int regionCount = std::min(static_cast<int>(scene.drawSurfCount[region]),
                                         scene.maxDrawSurfCount[region]);
        for (int i = 0; i < regionCount; ++i)
        {
            const GfxDrawSurf drawSurf = scene.drawSurfs[region][i];
            const unsigned int objectId = drawSurf.fields.objectId;
            if (drawSurf.fields.surfType != SF_CODE_MESH)
            {
                ++skippedType;
                continue;
            }
            if (objectId >= static_cast<unsigned int>(frontEndDataOut->codeMeshCount)
                || objectId >= 2048 || rendered[objectId])
            {
                ++skippedObject;
                continue;
            }
            if (drawSurf.fields.materialSortedIndex >= static_cast<unsigned int>(rgp.materialCount))
            {
                ++skippedMaterial;
                continue;
            }
            const FxCodeMeshData &codeMesh = frontEndDataOut->codeMeshes[objectId];
            if (!codeMesh.indices)
            {
                ++skippedIndices;
                continue;
            }
            const ptrdiff_t firstIndex = codeMesh.indices - mesh.indices;
            const NSUInteger indexCount = static_cast<NSUInteger>(codeMesh.triCount) * 3;
            if (firstIndex < 0
                || static_cast<uint64_t>(firstIndex) + indexCount > mesh.indexCount)
            {
                ++skippedRange;
                continue;
            }
            Material *const material = rgp.sortedMaterials[drawSurf.fields.materialSortedIndex];
            TraceEffectMaterial(material, region, codeMesh, mesh, firstIndex, vertexCount);
            const char *const effectShaderName = EffectPixelShaderName(material, region);
            // Screen-distortion maps encode signed vectors, not color.  Several
            // stock assets expose them through the generic TS_2D semantic, so
            // loading them through an sRGB texture would turn neutral 0.5 into
            // ~0.214 and impose a large one-directional offset over the entire
            // shock-wave card.  Keep a linear view/cache only for the technique
            // that consumes those values as vectors.
            const bool distortion = std::strstr(effectShaderName, "distortion") != nullptr;
            id<MTLTexture> texture = TextureForWorldMaterial(material, distortion);
            const GfxStateBits state = EffectStateBitsForMaterial(material, region);
            SetCachedRenderPipeline(encoder,
                                    EffectPipelineForMaterial(material, region));
            SetCachedDepthState(encoder, DepthStateForMaterial(state.loadBits[1]));
            SetCachedCullMode(encoder, CullModeForStateBits(state.loadBits[0]));
            [encoder setFragmentTexture:texture ? texture : g_whiteTexture atIndex:0];
            [encoder setFragmentTexture:g_resolvedSceneTexture atIndex:1];
            [encoder setFragmentTexture:g_resolvedDepthTexture atIndex:2];
            [encoder setFragmentSamplerState:SamplerForMaterial(material) atIndex:0];
            const MetalEffectParams params = EffectParamsForMaterial(material, region, view);
            [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:indexCount
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:static_cast<NSUInteger>(firstIndex) * sizeof(uint16_t)];
            rendered[objectId] = true;
            ++drawCount;
        }
    }

    if (g_traceRenderer && (g_frameCount % 300) == 0)
    {
        Com_Printf(8, "[metal] effect pass: %u/%d code meshes, %u verts, %u indices, materials=%d "
                      "skip(t/o/m/i/r)=%u/%u/%u/%u/%u; regions",
                   drawCount, frontEndDataOut->codeMeshCount, vertexCount, mesh.indexCount,
                   rgp.materialCount, skippedType, skippedObject, skippedMaterial,
                   skippedIndices, skippedRange);
        for (const int region : effectRegions)
            Com_Printf(8, " %d=%d", region,
                       std::min(static_cast<int>(scene.drawSurfCount[region]),
                                scene.maxDrawSurfCount[region]));
        for (const int region : effectRegions)
        {
            if (scene.drawSurfCount[region] <= 0)
                continue;
            const GfxDrawSurf sample = scene.drawSurfs[region][0];
            Com_Printf(8, " sample=%d:type%u,obj%u,mat%u", region,
                       sample.fields.surfType, sample.fields.objectId,
                       sample.fields.materialSortedIndex);
            break;
        }
        Com_Printf(8, "\n");
    }
}

void EncodeMarkMeshes(id<MTLRenderCommandEncoder> encoder, const GfxViewInfo &view)
{
    if (!frontEndDataOut || !g_effectPipeline || !g_effectDepthState)
        return;
    const GfxMeshData &mesh = frontEndDataOut->markMesh;
    const unsigned int vertexCount = mesh.vertSize ? mesh.vb.used / mesh.vertSize : 0;
    if (!frontEndDataOut->markMeshCount || !vertexCount || !mesh.indexCount
        || !mesh.vb.cpuData || !mesh.indices || mesh.vertSize != sizeof(GfxWorldVertex))
        return;

    const auto *const source = reinterpret_cast<const GfxWorldVertex *>(mesh.vb.cpuData);
    std::vector<MetalWorldVertex> converted(vertexCount);
    for (unsigned int i = 0; i < vertexCount; ++i)
    {
        const GfxWorldVertex &src = source[i];
        MetalWorldVertex &dst = converted[i];
        std::memcpy(dst.position, src.xyz, sizeof(dst.position));
        dst.positionPadding = 0.0f;
        std::memcpy(dst.uv, src.texCoord, sizeof(dst.uv));
        std::memcpy(dst.lightmapUv, src.lmapCoord, sizeof(dst.lightmapUv));
        dst.color[0] = src.color.array[2] / 255.0f;
        dst.color[1] = src.color.array[1] / 255.0f;
        dst.color[2] = src.color.array[0] / 255.0f;
        dst.color[3] = src.color.array[3] / 255.0f;
        Vec3UnpackUnitVec(src.normal, dst.normal);
        Vec3UnpackUnitVec(src.tangent, dst.tangent);
        dst.binormalSign = src.binormalSign;
        dst.tangentPadding = 0.0f;
    }
    id<MTLBuffer> vertexBuffer = [g_device newBufferWithBytes:converted.data()
                                                       length:converted.size() * sizeof(MetalWorldVertex)
                                                      options:MTLResourceStorageModeShared];
    id<MTLBuffer> indexBuffer = [g_device newBufferWithBytes:mesh.indices
                                                      length:static_cast<NSUInteger>(mesh.indexCount)
                                                             * sizeof(uint16_t)
                                                     options:MTLResourceStorageModeShared];
    if (!vertexBuffer || !indexBuffer)
        return;

    static const float identity[4][4] = {
        {1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1},
    };
    bool rendered[1536] = {};
    unsigned int drawCount = 0;
    SetSceneDepthRange(encoder, false);
    SetCachedCullMode(encoder, MTLCullModeNone);
    [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBytes:view.viewParms.viewProjectionMatrix.m
                     length:sizeof(view.viewParms.viewProjectionMatrix.m) atIndex:1];
    [encoder setVertexBytes:identity length:sizeof(identity) atIndex:2];

    static constexpr int markRegions[] = {
        DRAW_SURF_FX_CAMERA_LIT,
        DRAW_SURF_FX_CAMERA_LIT_AUTO,
        DRAW_SURF_FX_CAMERA_LIT_DECAL,
    };
    for (const int region : markRegions)
    {
        const int regionCount = std::min(static_cast<int>(scene.drawSurfCount[region]),
                                         scene.maxDrawSurfCount[region]);
        for (int i = 0; i < regionCount; ++i)
        {
            const GfxDrawSurf drawSurf = scene.drawSurfs[region][i];
            const unsigned int objectId = drawSurf.fields.objectId;
            if (drawSurf.fields.surfType != SF_MARK_MESH
                || objectId >= static_cast<unsigned int>(frontEndDataOut->markMeshCount)
                || objectId >= 1536 || rendered[objectId]
                || drawSurf.fields.materialSortedIndex >= static_cast<unsigned int>(rgp.materialCount))
                continue;
            const FxMarkMeshData &mark = frontEndDataOut->markMeshes[objectId];
            if (!mark.indices || !mark.triCount)
                continue;
            const ptrdiff_t firstIndex = mark.indices - mesh.indices;
            const NSUInteger indexCount = static_cast<NSUInteger>(mark.triCount) * 3;
            if (firstIndex < 0 || static_cast<uint64_t>(firstIndex) + indexCount > mesh.indexCount)
                continue;
            Material *const material = rgp.sortedMaterials[drawSurf.fields.materialSortedIndex];
            const GfxStateBits state = EffectStateBitsForMaterial(material, region);
            SetCachedRenderPipeline(encoder, WorldPipelineForMaterial(
                material, state.loadBits[0], false));
            SetCachedDepthState(encoder, DepthStateForMaterial(state.loadBits[1]));
            SetCachedCullMode(encoder, CullModeForStateBits(state.loadBits[0]));

            // Preserve the state-map's decal offset multiplier instead of
            // applying one hard-coded bias to every mark material.
            const float polygonOffset = -static_cast<float>(
                (state.loadBits[1] & GFXS1_POLYGON_OFFSET_MASK)
                >> GFXS1_POLYGON_OFFSET_SHIFT);
            [encoder setDepthBias:polygonOffset slopeScale:polygonOffset clamp:0.0f];

            id<MTLTexture> primaryLightmap = g_whiteTexture;
            id<MTLTexture> secondaryLightmap = g_whiteTexture;
            bool usesPrimaryLightmap = false;
            bool usesSecondaryLightmap = false;
            unsigned int lightingHandle = 0;
            unsigned int primaryLightIndex = drawSurf.fields.primaryLightIndex;
            const unsigned int markType = mark.modelTypeAndSurf & MARK_MODEL_TYPE_MASK;
            if (markType == MARK_MODEL_TYPE_WORLD_BRUSH
                || markType == MARK_MODEL_TYPE_ENT_BRUSH)
            {
                const unsigned int lightmapIndex = drawSurf.fields.customIndex;
                if (rgp.world && rgp.world->lightmaps
                    && lightmapIndex != 31 && lightmapIndex < rgp.world->lightmapCount)
                {
                    const GfxLightmapArray &lightmaps = rgp.world->lightmaps[lightmapIndex];
                    if (lightmaps.primary)
                    {
                        if (id<MTLTexture> texture = TextureForImage(lightmaps.primary))
                        {
                            primaryLightmap = texture;
                            usesPrimaryLightmap = true;
                        }
                    }
                    if (lightmaps.secondary)
                    {
                        if (id<MTLTexture> texture = TextureForImage(lightmaps.secondary))
                        {
                            secondaryLightmap = texture;
                            usesSecondaryLightmap = true;
                        }
                    }
                }
            }
            else if (markType == MARK_MODEL_TYPE_WORLD_MODEL && rgp.world
                     && mark.modelIndex < rgp.world->dpvs.smodelCount)
            {
                const GfxStaticModelDrawInst &instance =
                    rgp.world->dpvs.smodelDrawInsts[mark.modelIndex];
                lightingHandle = instance.lightingHandle;
                primaryLightIndex = instance.primaryLightIndex;
            }
            else if (markType == MARK_MODEL_TYPE_ENT_MODEL)
            {
                // Entity marks store the dynamic model-light handle directly.
                lightingHandle = mark.modelIndex;
            }

            BindMaterialTextures(encoder, view, material, primaryLightmap,
                                 secondaryLightmap, usesPrimaryLightmap,
                                 usesSecondaryLightmap,
                                 drawSurf.fields.reflectionProbeIndex,
                                 lightingHandle, primaryLightIndex, true);
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:indexCount
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:indexBuffer
                         indexBufferOffset:static_cast<NSUInteger>(firstIndex) * sizeof(uint16_t)];
            rendered[objectId] = true;
            ++drawCount;
        }
    }
    [encoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    if (g_traceRenderer && drawCount && (g_frameCount % 300) == 0)
        Com_Printf(8, "[metal] mark pass: %u/%d meshes, %u verts, %u indices\n",
                   drawCount, frontEndDataOut->markMeshCount, vertexCount, mesh.indexCount);
}

void PushQuad(const QuadMode mode, id<MTLTexture> texture,
              const float x, const float y, const float w, const float h,
              const float s0, const float t0, const float s1, const float t1,
              const float r, const float g, const float b, const float a)
{
    // Command coordinates are in SDL window points. Metal's drawable is in
    // physical pixels on Retina displays, but clip space already spans all of
    // those pixels; normalising by drawable size would render at half scale.
    const float x0 = x / static_cast<float>(g_uiWidth) * 2.0f - 1.0f;
    const float x1 = (x + w) / static_cast<float>(g_uiWidth) * 2.0f - 1.0f;
    const float y0 = 1.0f - y / static_cast<float>(g_uiHeight) * 2.0f;
    const float y1 = 1.0f - (y + h) / static_cast<float>(g_uiHeight) * 2.0f;
    const UiVertex quad[6] = {
        {{x0, y0}, {s0, t0}, {r, g, b, a}},
        {{x1, y0}, {s1, t0}, {r, g, b, a}},
        {{x0, y1}, {s0, t1}, {r, g, b, a}},
        {{x1, y0}, {s1, t0}, {r, g, b, a}},
        {{x1, y1}, {s1, t1}, {r, g, b, a}},
        {{x0, y1}, {s0, t1}, {r, g, b, a}},
    };

    const size_t first = g_vertices.size();
    g_vertices.insert(g_vertices.end(), std::begin(quad), std::end(quad));
    if (!g_batches.empty() && g_batches.back().mode == mode && g_batches.back().texture == texture
        && g_batches.back().firstVertex + g_batches.back().vertexCount == first)
    {
        g_batches.back().vertexCount += 6;
    }
    else
    {
        g_batches.push_back({mode, texture, first, 6});
    }
}

void PushQuadCorners(const QuadMode mode, id<MTLTexture> texture,
                     const float positions[4][2], const float uvs[4][2],
                     const float r, const float g, const float b, const float a)
{
    UiVertex corners[4]{};
    for (int i = 0; i < 4; ++i)
    {
        corners[i].position[0] = positions[i][0] / static_cast<float>(g_uiWidth) * 2.0f - 1.0f;
        corners[i].position[1] = 1.0f - positions[i][1] / static_cast<float>(g_uiHeight) * 2.0f;
        corners[i].uv[0] = uvs[i][0];
        corners[i].uv[1] = uvs[i][1];
        corners[i].color[0] = r;
        corners[i].color[1] = g;
        corners[i].color[2] = b;
        corners[i].color[3] = a;
    }
    const UiVertex quad[6] = {
        corners[0], corners[1], corners[3],
        corners[1], corners[2], corners[3],
    };
    const size_t first = g_vertices.size();
    g_vertices.insert(g_vertices.end(), std::begin(quad), std::end(quad));
    if (!g_batches.empty() && g_batches.back().mode == mode && g_batches.back().texture == texture
        && g_batches.back().firstVertex + g_batches.back().vertexCount == first)
    {
        g_batches.back().vertexCount += 6;
    }
    else
    {
        g_batches.push_back({mode, texture, first, 6});
    }
}

void PushMaterialQuad(const Material *material, const GfxColor color,
                      const float positions[4][2], const float uvs[4][2])
{
    const float r = color.array[2] / 255.0f;
    const float g = color.array[1] / 255.0f;
    const float b = color.array[0] / 255.0f;
    const float a = color.array[3] / 255.0f;
    id<MTLTexture> texture = TextureForMaterial(material);
    if (texture)
        PushQuadCorners(QuadMode::Image, texture, positions, uvs, r, g, b, a);
    else if (!MaterialWantsTexture(material))
        PushQuadCorners(QuadMode::Flat, nil, positions, uvs, r, g, b, a);
}

void DrawText(const GfxCmdDrawText2D *cmd)
{
    id<MTLTexture> atlas = TextureForMaterial(cmd->font->material);
    if (!atlas)
        return;

    const float baseR = cmd->color.array[2] / 255.0f;
    const float baseG = cmd->color.array[1] / 255.0f;
    const float baseB = cmd->color.array[0] / 255.0f;
    const float a = cmd->color.array[3] / 255.0f;
    float r = baseR;
    float g = baseG;
    float b = baseB;
    float penX = cmd->x - 0.5f * cmd->xScale;
    const float penY = cmd->y - 0.5f * cmd->yScale;

    const char *text = cmd->text;
    for (int drawn = 0; *text && drawn < cmd->maxChars;)
    {
        // CoD strings embed palette changes as ^0 through ^9.  The D3D
        // backend consumes these control pairs rather than treating them as
        // glyphs; do the same in the native presenter so prompts do not leak
        // strings such as "^3F^7" onto the HUD.
        if (text[0] == '^' && text[1] >= '0' && text[1] <= '9')
        {
            if (text[1] == '7')
            {
                r = baseR;
                g = baseG;
                b = baseB;
            }
            else
            {
                GfxColor inlineColor{};
                RB_LookupColor(static_cast<unsigned char>(text[1]), &inlineColor);
                r = inlineColor.array[0] / 255.0f;
                g = inlineColor.array[1] / 255.0f;
                b = inlineColor.array[2] / 255.0f;
            }
            text += 2;
            continue;
        }

        const Glyph *glyph = R_GetCharacterGlyph(cmd->font, static_cast<unsigned char>(*text++));
        ++drawn;
        if (!glyph)
            continue;
        if (glyph->pixelWidth && glyph->pixelHeight)
        {
            PushQuad(QuadMode::Glyph, atlas,
                     penX + glyph->x0 * cmd->xScale,
                     penY + glyph->y0 * cmd->yScale,
                     glyph->pixelWidth * cmd->xScale,
                     glyph->pixelHeight * cmd->yScale,
                     glyph->s0, glyph->t0, glyph->s1, glyph->t1,
                     r, g, b, a);
        }
        penX += glyph->dx * cmd->xScale;
    }
}

void TraceUiMaterial(const GfxCmdStretchPic *cmd)
{
    if (!g_traceRenderer || !rgp.world || !cmd || !cmd->material)
        return;
    static std::vector<const Material *> reported;
    if (reported.size() >= 32
        || std::find(reported.begin(), reported.end(), cmd->material) != reported.end())
        return;
    reported.push_back(cmd->material);
    Com_Printf(8, "[metal] UI material '%s' color(BGRA)=%u/%u/%u/%u textures=%u\n",
               cmd->material->info.name ? cmd->material->info.name : "(unnamed)",
               cmd->color.array[0], cmd->color.array[1], cmd->color.array[2], cmd->color.array[3],
               cmd->material->textureCount);
    for (int i = 0; i < cmd->material->textureCount; ++i)
    {
        const MaterialTextureDef &def = cmd->material->textureTable[i];
        const GfxImage *image = ImageForMaterialTextureDef(def);
        Com_Printf(8, "[metal]   semantic=%u image='%s' %ux%u format=%d\n", def.semantic,
                   image && image->name ? image->name : "(null)", image ? image->width : 0,
                   image ? image->height : 0,
                   image && image->texture.loadDef ? image->texture.loadDef->format : -1);
    }
}

void DispatchCommands(const GfxCmdArray *list)
{
    if (!list || !list->cmds || list->usedTotal <= 0)
        return;
    unsigned int commandCounts[RC_COUNT] = {};
    for (size_t pos = 0; pos < static_cast<size_t>(list->usedTotal);)
    {
        const auto *header = reinterpret_cast<const GfxCmdHeader *>(list->cmds + pos);
        if (header->id == RC_END_OF_LIST || !header->byteCount)
            break;
        if (header->id < RC_COUNT)
            ++commandCounts[header->id];
        switch (header->id)
        {
        case RC_SAVE_SCREEN:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdSaveScreen *>(header);
            g_savedScreenCommands.push_back({SavedScreenCommandType::Save,
                cmd->screenTimerId, 0, 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, 0.0f});
            break;
        }
        case RC_SAVE_SCREEN_SECTION:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdSaveScreenSection *>(header);
            g_savedScreenCommands.push_back({SavedScreenCommandType::SaveSection,
                cmd->screenTimerId, 0, cmd->s0, cmd->t0, cmd->ds, cmd->dt, 0.0f, 0.0f});
            break;
        }
        case RC_BLEND_SAVED_SCREEN_BLURRED:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdBlendSavedScreenBlurred *>(header);
            g_savedScreenCommands.push_back({SavedScreenCommandType::BlendBlurred,
                cmd->screenTimerId, cmd->fadeMsec, cmd->s0, cmd->t0,
                cmd->ds, cmd->dt, 0.0f, 0.0f});
            break;
        }
        case RC_BLEND_SAVED_SCREEN_FLASHED:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdBlendSavedScreenFlashed *>(header);
            g_savedScreenCommands.push_back({SavedScreenCommandType::BlendFlashed,
                0, 0, cmd->s0, cmd->t0, cmd->ds, cmd->dt,
                cmd->intensityWhiteout, cmd->intensityScreengrab});
            break;
        }
        case RC_CLEAR_SCREEN:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdClearScreen *>(header);
            g_clearColor = MTLClearColorMake(cmd->color[0], cmd->color[1], cmd->color[2], cmd->color[3]);
            break;
        }
        case RC_STRETCH_PIC:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdStretchPic *>(header);
            TraceUiMaterial(cmd);
            const float r = cmd->color.array[2] / 255.0f;
            const float g = cmd->color.array[1] / 255.0f;
            const float b = cmd->color.array[0] / 255.0f;
            const float a = cmd->color.array[3] / 255.0f;
            id<MTLTexture> texture = TextureForMaterial(cmd->material);
            if (texture)
                PushQuad(QuadMode::Image, texture, cmd->x, cmd->y, cmd->w, cmd->h,
                         cmd->s0, cmd->t0, cmd->s1, cmd->t1, r, g, b, a);
            else if (!MaterialWantsTexture(cmd->material))
                PushQuad(QuadMode::Flat, nil, cmd->x, cmd->y, cmd->w, cmd->h,
                         0, 0, 1, 1, r, g, b, a);
            break;
        }
        case RC_STRETCH_PIC_ROTATE_XY:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdStretchPicRotateXY *>(header);
            const float radians = cmd->rotation * 0.01745329251994329577f;
            const float cosAngle = std::cos(radians);
            const float sinAngle = std::sin(radians);
            const float halfWidth = cmd->w * 0.5f;
            const float halfHeight = cmd->h * 0.5f;
            const float midX = cmd->x + halfWidth;
            const float midY = cmd->y + halfHeight;
            const float stepX[2] = {halfWidth * cosAngle, halfWidth * sinAngle};
            const float stepY[2] = {-halfHeight * sinAngle, halfHeight * cosAngle};
            const float positions[4][2] = {
                {midX - stepX[0] - stepY[0], midY - stepX[1] - stepY[1]},
                {midX + stepX[0] - stepY[0], midY + stepX[1] - stepY[1]},
                {midX + stepX[0] + stepY[0], midY + stepX[1] + stepY[1]},
                {midX - stepX[0] + stepY[0], midY - stepX[1] + stepY[1]},
            };
            const float uvs[4][2] = {
                {cmd->s0, cmd->t0}, {cmd->s1, cmd->t0},
                {cmd->s1, cmd->t1}, {cmd->s0, cmd->t1},
            };
            PushMaterialQuad(cmd->material, cmd->color, positions, uvs);
            break;
        }
        case RC_STRETCH_PIC_ROTATE_ST:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdStretchPicRotateST *>(header);
            const float radians = cmd->rotation * 0.01745329251994329577f;
            const float cosAngle = std::cos(radians);
            const float sinAngle = std::sin(radians);
            const float stepS = cmd->radiusST * cosAngle * cmd->scaleFinalS;
            const float stepSVertical = cmd->radiusST * sinAngle * cmd->scaleFinalT;
            const float stepT = -cmd->radiusST * sinAngle * cmd->scaleFinalS;
            const float stepTVertical = cmd->radiusST * cosAngle * cmd->scaleFinalT;
            const float positions[4][2] = {
                {cmd->x, cmd->y}, {cmd->x + cmd->w, cmd->y},
                {cmd->x + cmd->w, cmd->y + cmd->h}, {cmd->x, cmd->y + cmd->h},
            };
            const float uvs[4][2] = {
                {cmd->centerS - stepS - stepT, cmd->centerT - stepSVertical - stepTVertical},
                {cmd->centerS + stepS - stepT, cmd->centerT + stepSVertical - stepTVertical},
                {cmd->centerS + stepS + stepT, cmd->centerT + stepSVertical + stepTVertical},
                {cmd->centerS - stepS + stepT, cmd->centerT - stepSVertical + stepTVertical},
            };
            PushMaterialQuad(cmd->material, cmd->color, positions, uvs);
            break;
        }
        case RC_DRAW_QUAD_PIC:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdDrawQuadPic *>(header);
            const float uvs[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
            PushMaterialQuad(cmd->material, cmd->color, cmd->verts, uvs);
            break;
        }
        case RC_DRAW_TEXT_2D:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdDrawText2D *>(header);
            if (cmd->maxChars > 0 && cmd->font)
                DrawText(cmd);
            break;
        }
        default:
            break;
        }
        pos += header->byteCount;
    }
    if (g_traceRenderer && rgp.world && (g_frameCount % 300) == 0)
    {
        Com_Printf(8, "[metal] frame %d commands=%d uiVerts=%zu scene: dobj=%u model=%u brush=%u "
                      "fx: meshes=%d verts=%u indices=%u viewDraws: lit=%u decal=%u emissive=%u ids:",
                   g_frameCount, list->usedTotal, g_vertices.size(), scene.sceneDObjCount,
                   scene.sceneModelCount, scene.sceneBrushCount,
                   frontEndDataOut ? frontEndDataOut->codeMeshCount : 0,
                   frontEndDataOut && frontEndDataOut->codeMesh.vertSize
                       ? frontEndDataOut->codeMesh.vb.used / frontEndDataOut->codeMesh.vertSize : 0,
                   frontEndDataOut ? frontEndDataOut->codeMesh.indexCount : 0,
                   frontEndDataOut && frontEndDataOut->viewInfoCount
                       ? frontEndDataOut->viewInfo[frontEndDataOut->viewInfoIndex].litInfo.drawSurfCount : 0,
                   frontEndDataOut && frontEndDataOut->viewInfoCount
                       ? frontEndDataOut->viewInfo[frontEndDataOut->viewInfoIndex].decalInfo.drawSurfCount : 0,
                   frontEndDataOut && frontEndDataOut->viewInfoCount
                       ? frontEndDataOut->viewInfo[frontEndDataOut->viewInfoIndex].emissiveInfo.drawSurfCount : 0);
        for (int id = 0; id < RC_COUNT; ++id)
        {
            if (commandCounts[id])
                Com_Printf(8, " %d=%u", id, commandCounts[id]);
        }
        Com_Printf(8, "\n");
    }
}

id<MTLRenderPipelineState> MakePipeline(id<MTLLibrary> library, NSString *fragmentName)
{
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"ui_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:fragmentName];
    desc.colorAttachments[0].pixelFormat = kDrawableFormat;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] pipeline '%s' failed: %s\n",
                     fragmentName.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeWorldPipeline(id<MTLLibrary> library, NSString *vertexName,
                                             NSString *label,
                                             NSString *fragmentName = @"world_fragment",
                                             const MaterialBlendMode blendMode = MaterialBlendMode::Opaque)
{
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = label;
    desc.vertexFunction = [library newFunctionWithName:vertexName];
    desc.fragmentFunction = [library newFunctionWithName:fragmentName];
    desc.colorAttachments[0].pixelFormat = kDrawableFormat;
    desc.colorAttachments[0].blendingEnabled = blendMode != MaterialBlendMode::Opaque;
    if (blendMode == MaterialBlendMode::Additive)
    {
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    }
    else if (blendMode == MaterialBlendMode::Alpha)
    {
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] pipeline '%s' failed: %s\n",
                     label.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeWaterPipeline(id<MTLLibrary> library)
{
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = @"CoD4 water_l_sun";
    desc.vertexFunction = [library newFunctionWithName:@"world_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"water_fragment"];
    desc.colorAttachments[0].pixelFormat = kDrawableFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    // wc_water's stock state map: SRCALPHA/INVSRCALPHA for RGB and
    // INVDESTALPHA/ONE for alpha. The water technique does not write depth.
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOneMinusDestinationAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc
                                                                                   error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] water pipeline failed: %s\n",
                     error.localizedDescription.UTF8String);
    return pipeline;
}

MTLBlendFactor MetalBlendFactor(const unsigned int factor)
{
    switch (factor)
    {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    default: return MTLBlendFactorOne;
    }
}

MTLBlendOperation MetalBlendOperation(const unsigned int operation)
{
    switch (operation)
    {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

id<MTLRenderPipelineState> MakeWorldStatePipeline(
    const uint32_t stateBits, const bool model, const WorldShaderMode shaderMode)
{
    if (!g_shaderLibrary)
        return model ? g_modelPipeline : g_worldPipeline;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = [NSString stringWithFormat:@"CoD4 %s state %08x",
                  model ? "model" : "world", stateBits];
    desc.vertexFunction = [g_shaderLibrary newFunctionWithName:model ? @"model_vertex"
                                                                : @"world_vertex"];
    NSString *fragmentName = @"world_fragment";
    switch (shaderMode)
    {
    case WorldShaderMode::Simple: fragmentName = @"world_simple_fragment"; break;
    case WorldShaderMode::SimpleFog: fragmentName = @"world_simple_fog_fragment"; break;
    case WorldShaderMode::AddFog: fragmentName = @"world_add_fog_fragment"; break;
    case WorldShaderMode::Multiply: fragmentName = @"world_multiply_fragment"; break;
    default: break;
    }
    desc.fragmentFunction = [g_shaderLibrary newFunctionWithName:fragmentName];
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = kDrawableFormat;
    const unsigned int rgbOperation = (stateBits & GFXS0_BLENDOP_RGB_MASK)
        >> GFXS0_BLENDOP_RGB_SHIFT;
    color.blendingEnabled = rgbOperation != 0;
    if (rgbOperation)
    {
        color.sourceRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_SRCBLEND_RGB_MASK) >> GFXS0_SRCBLEND_RGB_SHIFT);
        color.destinationRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_DSTBLEND_RGB_MASK) >> GFXS0_DSTBLEND_RGB_SHIFT);
        color.rgbBlendOperation = MetalBlendOperation(rgbOperation);
        unsigned int alphaOperation = (stateBits & GFXS0_BLENDOP_ALPHA_MASK)
            >> GFXS0_BLENDOP_ALPHA_SHIFT;
        unsigned int alphaSource = (stateBits & GFXS0_SRCBLEND_ALPHA_MASK)
            >> GFXS0_SRCBLEND_ALPHA_SHIFT;
        unsigned int alphaDestination = (stateBits & GFXS0_DSTBLEND_ALPHA_MASK)
            >> GFXS0_DSTBLEND_ALPHA_SHIFT;
        if (!alphaOperation)
        {
            alphaOperation = rgbOperation;
            alphaSource = (stateBits & GFXS0_SRCBLEND_RGB_MASK)
                >> GFXS0_SRCBLEND_RGB_SHIFT;
            alphaDestination = (stateBits & GFXS0_DSTBLEND_RGB_MASK)
                >> GFXS0_DSTBLEND_RGB_SHIFT;
        }
        color.sourceAlphaBlendFactor = MetalBlendFactor(alphaSource);
        color.destinationAlphaBlendFactor = MetalBlendFactor(alphaDestination);
        color.alphaBlendOperation = MetalBlendOperation(alphaOperation);
    }
    MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
    if (stateBits & GFXS0_COLORWRITE_RGB)
        writeMask |= MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    if (stateBits & GFXS0_COLORWRITE_ALPHA)
        writeMask |= MTLColorWriteMaskAlpha;
    color.writeMask = writeMask;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc
                                                                                   error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] %s pipeline %08x failed: %s\n",
                     model ? "model" : "world", stateBits,
                     error.localizedDescription.UTF8String);
    return pipeline ? pipeline : (model ? g_modelPipeline : g_worldPipeline);
}

id<MTLRenderPipelineState> WorldPipelineForMaterial(
    const Material *material, const uint32_t stateBits, const bool model)
{
    const WorldShaderMode shaderMode = ShaderModeForMaterial(material);
    const uint64_t key = stateBits | (static_cast<uint64_t>(model) << 32)
        | (static_cast<uint64_t>(shaderMode) << 33);
    const auto found = g_worldMaterialPipelines.find(key);
    if (found != g_worldMaterialPipelines.end())
        return (__bridge id<MTLRenderPipelineState>)found->second;
    id<MTLRenderPipelineState> pipeline = MakeWorldStatePipeline(stateBits, model, shaderMode);
    g_worldMaterialPipelines.emplace(
        key, pipeline ? (__bridge_retained void *)pipeline : nullptr);
    return pipeline;
}

id<MTLDepthStencilState> DepthStateForMaterial(const uint32_t stateBits)
{
    const uint32_t key = stateBits & (GFXS1_DEPTHWRITE | GFXS1_DEPTHTEST_DISABLE
                                      | GFXS1_DEPTHTEST_MASK);
    const auto found = g_materialDepthStates.find(key);
    if (found != g_materialDepthStates.end())
        return (__bridge id<MTLDepthStencilState>)found->second;

    MTLDepthStencilDescriptor *descriptor = [MTLDepthStencilDescriptor new];
    descriptor.depthWriteEnabled = (stateBits & GFXS1_DEPTHWRITE) != 0;
    if (stateBits & GFXS1_DEPTHTEST_DISABLE)
    {
        descriptor.depthCompareFunction = MTLCompareFunctionAlways;
    }
    else
    {
        switch (stateBits & GFXS1_DEPTHTEST_MASK)
        {
        case GFXS1_DEPTHTEST_LESS: descriptor.depthCompareFunction = MTLCompareFunctionLess; break;
        case GFXS1_DEPTHTEST_EQUAL: descriptor.depthCompareFunction = MTLCompareFunctionEqual; break;
        case GFXS1_DEPTHTEST_LESSEQUAL:
            descriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
            break;
        default: descriptor.depthCompareFunction = MTLCompareFunctionAlways; break;
        }
    }
    id<MTLDepthStencilState> depth = [g_device newDepthStencilStateWithDescriptor:descriptor];
    g_materialDepthStates.emplace(key, depth ? (__bridge_retained void *)depth : nullptr);
    return depth;
}

id<MTLRenderPipelineState> MakeEffectPipeline(const uint32_t stateBits)
{
    if (!g_shaderLibrary)
        return g_effectPipeline;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = [NSString stringWithFormat:@"CoD4 effect state %08x", stateBits];
    desc.vertexFunction = [g_shaderLibrary newFunctionWithName:@"model_vertex"];
    desc.fragmentFunction = [g_shaderLibrary newFunctionWithName:@"effect_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = kDrawableFormat;
    const unsigned int rgbOperation = (stateBits & GFXS0_BLENDOP_RGB_MASK)
        >> GFXS0_BLENDOP_RGB_SHIFT;
    color.blendingEnabled = rgbOperation != 0;
    if (rgbOperation)
    {
        color.sourceRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_SRCBLEND_RGB_MASK) >> GFXS0_SRCBLEND_RGB_SHIFT);
        color.destinationRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_DSTBLEND_RGB_MASK) >> GFXS0_DSTBLEND_RGB_SHIFT);
        color.rgbBlendOperation = MetalBlendOperation(rgbOperation);
        unsigned int alphaOperation = (stateBits & GFXS0_BLENDOP_ALPHA_MASK)
            >> GFXS0_BLENDOP_ALPHA_SHIFT;
        unsigned int alphaSource = (stateBits & GFXS0_SRCBLEND_ALPHA_MASK)
            >> GFXS0_SRCBLEND_ALPHA_SHIFT;
        unsigned int alphaDestination = (stateBits & GFXS0_DSTBLEND_ALPHA_MASK)
            >> GFXS0_DSTBLEND_ALPHA_SHIFT;
        // D3D9 disables separate-alpha blending when no alpha operation is
        // encoded, causing alpha to inherit the RGB equation and factors.
        if (!alphaOperation)
        {
            alphaOperation = rgbOperation;
            alphaSource = (stateBits & GFXS0_SRCBLEND_RGB_MASK)
                >> GFXS0_SRCBLEND_RGB_SHIFT;
            alphaDestination = (stateBits & GFXS0_DSTBLEND_RGB_MASK)
                >> GFXS0_DSTBLEND_RGB_SHIFT;
        }
        color.sourceAlphaBlendFactor = MetalBlendFactor(alphaSource);
        color.destinationAlphaBlendFactor = MetalBlendFactor(alphaDestination);
        color.alphaBlendOperation = MetalBlendOperation(alphaOperation);
    }
    MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
    if (stateBits & GFXS0_COLORWRITE_RGB)
        writeMask |= MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    if (stateBits & GFXS0_COLORWRITE_ALPHA)
        writeMask |= MTLColorWriteMaskAlpha;
    color.writeMask = writeMask;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc
                                                                                   error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] effect pipeline %08x failed: %s\n", stateBits,
                     error.localizedDescription.UTF8String);
    return pipeline ? pipeline : g_effectPipeline;
}

id<MTLRenderPipelineState> EffectPipelineForMaterial(const Material *material, const int region)
{
    const uint32_t stateBits = EffectStateBitsForMaterial(material, region).loadBits[0];
    const auto found = g_effectMaterialPipelines.find(stateBits);
    if (found != g_effectMaterialPipelines.end())
        return (__bridge id<MTLRenderPipelineState>)found->second;
    id<MTLRenderPipelineState> pipeline = MakeEffectPipeline(stateBits);
    g_effectMaterialPipelines.emplace(stateBits,
        pipeline ? (__bridge_retained void *)pipeline : nullptr);
    return pipeline ? pipeline : g_effectPipeline;
}

void PrewarmMaterialPipelines(const GfxWorld *world)
{
    // Pipeline creation is intentionally synchronous in this backend so a
    // failed state translation is reported immediately.  Doing it the first
    // time a car, weapon attachment, decal, or particle enters the frustum,
    // however, turns shader compilation into a gameplay hitch.  The complete
    // loaded material catalogue is already sorted by this point; compile only
    // its unique Metal state combinations while the level's loading UI/countdown
    // is still on screen.
    if (!world)
        return;
    const size_t worldBefore = g_worldMaterialPipelines.size();
    const size_t effectBefore = g_effectMaterialPipelines.size();
    const size_t depthBefore = g_materialDepthStates.size();
    const double start = CACurrentMediaTime();
    static constexpr int effectRegions[] = {
        DRAW_SURF_FX_CAMERA_LIT,
        DRAW_SURF_FX_CAMERA_LIT_AUTO,
        DRAW_SURF_FX_CAMERA_LIT_DECAL,
        DRAW_SURF_FX_CAMERA_EMISSIVE,
        DRAW_SURF_FX_CAMERA_EMISSIVE_AUTO,
        DRAW_SURF_FX_CAMERA_EMISSIVE_DECAL,
    };
    for (int materialIndex = 0; materialIndex < rgp.materialCount; ++materialIndex)
    {
        const Material *const material = rgp.sortedMaterials[materialIndex];
        if (!material)
            continue;
        const GfxStateBits state = StateBitsForMaterial(material);
        WorldPipelineForMaterial(material, state.loadBits[0], false);
        WorldPipelineForMaterial(material, state.loadBits[0], true);
        DepthStateForMaterial(state.loadBits[1]);
        for (const int region : effectRegions)
            EffectPipelineForMaterial(material, region);
    }
    Com_Printf(8,
               "[metal] prewarmed material states: world=%zu effect=%zu depth=%zu "
               "from %d materials in %.2fms\n",
               g_worldMaterialPipelines.size() - worldBefore,
               g_effectMaterialPipelines.size() - effectBefore,
               g_materialDepthStates.size() - depthBefore, rgp.materialCount,
               (CACurrentMediaTime() - start) * 1000.0);
}

id<MTLRenderPipelineState> MakeSkyPipeline(id<MTLLibrary> library)
{
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = @"CoD4 sky cubemap";
    desc.vertexFunction = [library newFunctionWithName:@"sky_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"sky_fragment"];
    desc.colorAttachments[0].pixelFormat = kDrawableFormat;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] sky pipeline failed: %s\n",
                     error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeFullscreenPipeline(id<MTLLibrary> library,
                                                  NSString *fragmentName,
                                                  NSString *label)
{
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = label;
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreen_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentName];
    descriptor.colorAttachments[0].pixelFormat = kDrawableFormat;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] fullscreen pipeline '%s' failed: %s\n",
                     label.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeFullscreenBlendPipeline(id<MTLLibrary> library,
                                                       NSString *fragmentName,
                                                       NSString *label)
{
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = label;
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreen_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentName];
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = kDrawableFormat;
    color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.rgbBlendOperation = MTLBlendOperationAdd;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.alphaBlendOperation = MTLBlendOperationAdd;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] fullscreen blend pipeline '%s' failed: %s\n",
                     label.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeFullscreenStatePipeline(id<MTLLibrary> library,
                                                       NSString *fragmentName,
                                                       NSString *label,
                                                       const uint32_t stateBits)
{
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = label;
    descriptor.vertexFunction = [library newFunctionWithName:@"fullscreen_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentName];
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    color.pixelFormat = kDrawableFormat;
    const unsigned int rgbOperation = (stateBits & GFXS0_BLENDOP_RGB_MASK)
        >> GFXS0_BLENDOP_RGB_SHIFT;
    color.blendingEnabled = rgbOperation != 0;
    if (rgbOperation)
    {
        color.sourceRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_SRCBLEND_RGB_MASK) >> GFXS0_SRCBLEND_RGB_SHIFT);
        color.destinationRGBBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_DSTBLEND_RGB_MASK) >> GFXS0_DSTBLEND_RGB_SHIFT);
        color.rgbBlendOperation = MetalBlendOperation(rgbOperation);
        color.sourceAlphaBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_SRCBLEND_ALPHA_MASK) >> GFXS0_SRCBLEND_ALPHA_SHIFT);
        color.destinationAlphaBlendFactor = MetalBlendFactor(
            (stateBits & GFXS0_DSTBLEND_ALPHA_MASK) >> GFXS0_DSTBLEND_ALPHA_SHIFT);
        color.alphaBlendOperation = MetalBlendOperation(
            (stateBits & GFXS0_BLENDOP_ALPHA_MASK) >> GFXS0_BLENDOP_ALPHA_SHIFT);
    }
    MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
    if (stateBits & GFXS0_COLORWRITE_RGB)
        writeMask |= MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
    if (stateBits & GFXS0_COLORWRITE_ALPHA)
        writeMask |= MTLColorWriteMaskAlpha;
    color.writeMask = writeMask;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] fullscreen state pipeline '%s' failed: %s\n",
                     label.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

id<MTLRenderPipelineState> MakeShadowPipeline(id<MTLLibrary> library,
                                              NSString *vertexName,
                                              const bool alphaTest)
{
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = [NSString stringWithFormat:@"CoD4 sun shadow %@%@",
                        vertexName, alphaTest ? @" alpha" : @""];
    descriptor.vertexFunction = [library newFunctionWithName:vertexName];
    descriptor.fragmentFunction = alphaTest
        ? [library newFunctionWithName:@"shadow_alpha_fragment"] : nil;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [g_device
        newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline)
        std::fprintf(stderr, "[metal] shadow pipeline '%s' failed: %s\n",
                     vertexName.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

bool InitMetal()
{
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device)
    {
        std::fprintf(stderr, "[metal] no Metal device\n");
        return false;
    }
    g_layer.device = g_device;
    g_layer.pixelFormat = kDrawableFormat;
    g_layer.framebufferOnly = NO;
    // Keep three frames available to the Apple GPU so command encoding and
    // display scanout can overlap.  Synchronization remains controlled by the
    // user's r_vsync setting below rather than an implicit CAMetalLayer default.
    g_layer.maximumDrawableCount = 3;
    g_layer.presentsWithTransaction = NO;
    // Start unsynchronised so the layer's first drawable is not enrolled in
    // display-paced presentation before r_vsync is registered. PresentFrame
    // applies the live dvar on its first frame (and can turn sync back on).
    g_layer.displaySyncEnabled = NO;
    g_queue = [g_device newCommandQueue];

    static const char *const sourceText = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct UiVertex { float2 position; float2 uv; float4 color; };
struct UiOut { float4 position [[position]]; float2 uv; float4 color; };
vertex UiOut ui_vertex(const device UiVertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {
    UiOut out;
    out.position = float4(vertices[id].position, 0.0, 1.0);
    out.uv = vertices[id].uv;
    out.color = vertices[id].color;
    return out;
}
fragment float4 ui_flat(UiOut in [[stage_in]]) { return in.color; }
fragment float4 ui_image(UiOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv) * in.color;
}
fragment float4 ui_glyph(UiOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float4 sample = tex.sample(smp, in.uv);
    // CoD's font atlases use D3DFMT_A8, whose value is the sampled alpha.
    return float4(in.color.rgb, in.color.a * sample.a);
}

struct FullscreenOut { float4 position [[position]]; float2 uv; };
vertex FullscreenOut fullscreen_vertex(uint id [[vertex_id]]) {
    FullscreenOut out;
    float2 uv = float2(float((id << 1u) & 2u), float(id & 2u));
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

struct FilmParams {
    uint enabled;
    uint glowEnabled;
    uint2 padding;
    float4 colorBias;
    float4 colorTintBase;
    float4 colorTintDelta;
    float4 glowApply;
};

fragment float4 film_fragment(FullscreenOut in [[stage_in]],
                              texture2d<float> sceneColor [[texture(0)]],
                              texture2d<float> glowColor [[texture(1)]],
                              sampler sceneSampler [[sampler(0)]],
                              constant FilmParams &film [[buffer(0)]]) {
    float4 scene = sceneColor.sample(sceneSampler, in.uv);
    float3 color = scene.rgb;
    if (film.enabled != 0u) {
        // Verbatim algebra from postfx_color.hlsl.  The engine has already folded
        // film saturation, contrast, brightness, inversion and both authored tints
        // into these three constants in R_UpdateColorManipulation.
        float luminance = dot(color, float3(0.299, 0.587, 0.114));
        float3 desaturated = color + luminance * film.colorBias.w;
        float3 tint = film.colorTintBase.rgb + luminance * film.colorTintDelta.rgb;
        color = desaturated * tint + film.colorBias.rgb;
    }
    if (film.glowEnabled != 0u)
        color += glowColor.sample(sceneSampler, in.uv).rgb * film.glowApply.w;
    return float4(color, scene.a);
}

fragment float4 feedback_blend_fragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> feedback [[texture(0)]],
                                        sampler feedbackSampler [[sampler(0)]],
                                        constant FilmParams &film [[buffer(0)]],
                                        constant float &blendAlpha [[buffer(1)]]) {
    float3 color = feedback.sample(feedbackSampler, in.uv).rgb;
    if (film.enabled != 0u) {
        // vertcol_film.hlsl applies the vertex RGB before deriving luminance.
        // RB_BlurScreen always submits white RGB, so this is the bytecode's
        // remaining color-manipulation sequence verbatim.
        float luminance = dot(color, float3(0.299, 0.587, 0.114));
        float3 desaturated = color + luminance * film.colorBias.w;
        float3 tint = film.colorTintBase.rgb + luminance * film.colorTintDelta.rgb;
        color = desaturated * tint + film.colorBias.rgb;
    }
    return float4(color, blendAlpha);
}

struct ShellShockParams {
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
};

fragment float4 shellshock_blurred_fragment(FullscreenOut in [[stage_in]],
                                            texture2d<float> savedScreen [[texture(0)]],
                                            sampler screenSampler [[sampler(0)]],
                                            constant ShellShockParams &shell [[buffer(0)]]) {
    float3 colored = savedScreen.sample(screenSampler,
        shell.uvOrigin + in.uv * shell.uvSize).rgb * shell.color.rgb;
    float luminance = dot(colored, float3(0.299, 0.587, 0.114));
    // shell_shock.hlsl: 75% saved color plus 25% luminance.  Framebuffer
    // SRCALPHA/INVSRCALPHA blending supplies the temporal blur itself.
    return float4(colored * 0.75 + luminance * 0.25, shell.color.a);
}

fragment float4 shellshock_flashed_fragment(FullscreenOut in [[stage_in]],
                                            texture2d<float> savedScreen [[texture(0)]],
                                            sampler screenSampler [[sampler(0)]],
                                            constant ShellShockParams &shell [[buffer(0)]]) {
    float3 saved = savedScreen.sample(screenSampler,
        shell.uvOrigin + in.uv * shell.uvSize).rgb;
    // shell_shock_flashed.hlsl.  Its material uses ONE/ONE framebuffer blend,
    // retaining the live frame underneath the frozen screengrab and whiteout.
    return float4(saved * shell.color.a + shell.color.rgb, 1.0);
}

struct GlowSetupParams {
    float2 sceneInvSize;
    float bloomCutoff;
    float bloomCutoffRescale;
    float bloomDesaturation;
    float padding0;
    float padding1;
    float padding2;
    float4 colorBias;
    float4 colorTintBase;
    float4 colorTintDelta;
};

float3 applyFilmConstants(float3 color, constant GlowSetupParams &glow) {
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    float3 desaturated = color + luminance * glow.colorBias.w;
    float3 tint = glow.colorTintBase.rgb + luminance * glow.colorTintDelta.rgb;
    return desaturated * tint + glow.colorBias.rgb;
}

fragment float4 glow_setup_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> sceneColor [[texture(0)]],
                                    sampler sceneSampler [[sampler(0)]],
                                    constant GlowSetupParams &glow [[buffer(0)]]) {
    float3 color = float3(0.0);
    for (int y = -1; y <= 1; y += 2) {
        for (int x = -1; x <= 1; x += 2) {
            float2 uv = in.uv + float2(float(x), float(y)) * glow.sceneInvSize;
            float3 rawColor = sceneColor.sample(sceneSampler, uv).rgb;
            float luminance = dot(rawColor, float3(0.299, 0.587, 0.114));
            float bloomWeight = saturate(luminance - glow.bloomCutoff)
                              * glow.bloomCutoffRescale;
            color += applyFilmConstants(rawColor, glow) * bloomWeight * 0.25;
        }
    }
    float luminance = dot(color, float3(0.299, 0.587, 0.114));
    color = mix(color, float3(luminance), glow.bloomDesaturation);
    return float4(color, 1.0);
}

struct GaussianParams {
    float2 direction;
    uint tapCount;
    uint padding;
    float4 taps[8];
};

fragment float4 gaussian_fragment(FullscreenOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  sampler sourceSampler [[sampler(0)]],
                                  constant GaussianParams &filter [[buffer(0)]]) {
    float4 color = float4(0.0);
    for (uint tap = 0u; tap < filter.tapCount; ++tap) {
        float2 offset = filter.direction * filter.taps[tap].x;
        color += (source.sample(sourceSampler, in.uv - offset)
                + source.sample(sourceSampler, in.uv + offset)) * filter.taps[tap].y;
    }
    return color;
}

struct Gaussian2DParams {
    uint tapCount;
    uint padding0;
    uint padding1;
    uint padding2;
    float4 taps[8];
};

fragment float4 gaussian2d_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    sampler sourceSampler [[sampler(0)]],
                                    constant Gaussian2DParams &filter [[buffer(0)]]) {
    float4 color = float4(0.0);
    for (uint tap = 0u; tap < filter.tapCount; ++tap) {
        float2 offset = filter.taps[tap].xy;
        color += (source.sample(sourceSampler, in.uv - offset)
                + source.sample(sourceSampler, in.uv + offset)) * filter.taps[tap].z;
    }
    return color;
}

struct DofParams {
    float2 sceneInvSize;
    float zNear;
    float depthHackNear;
    float maxDepth;
    float padding0;
    float padding1;
    float padding2;
    float4 sceneEquation;
    float4 viewModelEquation;
    float4 lerpScale;
    float4 lerpBias;
};

float dofSignedEyeDepth(float hardwareDepth, constant DofParams &dof) {
    constexpr float kViewModelDepthRange = 1.0 / 64.0;
    if (hardwareDepth < kViewModelDepthRange) {
        float projectionDepth = saturate(hardwareDepth * 64.0);
        // IW3 changes depthFromClip.w's sign while drawing depth-hack surfaces.
        // Preserve that negative float-Z convention: dof_downsample explicitly
        // negates it before applying the viewmodel CoC equation.
        return -dof.depthHackNear
             / max(dof.maxDepth - projectionDepth, 0.000001);
    }
    float projectionDepth = saturate((hardwareDepth - kViewModelDepthRange)
                                   * (64.0 / 63.0));
    return dof.maxDepth * dof.zNear
         / max(dof.maxDepth - projectionDepth, 0.000001);
}

fragment float4 dof_downsample_fragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> sceneColor [[texture(0)]],
                                        depth2d<float> sceneDepth [[texture(1)]],
                                        sampler sceneSampler [[sampler(0)]],
                                        constant DofParams &dof [[buffer(0)]]) {
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge,
                                   filter::nearest);
    const float2 colorOffsets[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float3 color = float3(0.0);
    for (uint sampleIndex = 0u; sampleIndex < 4u; ++sampleIndex)
        color += sceneColor.sample(sceneSampler,
            in.uv + colorOffsets[sampleIndex] * dof.sceneInvSize).rgb * 0.25;

    float nearCoc = 0.0;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float2 offset = (float2(float(x), float(y)) - 1.5)
                          * dof.sceneInvSize;
            float signedDepth = dofSignedEyeDepth(
                sceneDepth.sample(depthSampler, in.uv + offset), dof);
            float sceneNear = saturate(dof.sceneEquation.x * signedDepth
                                     + dof.sceneEquation.z);
            float viewModelNear = saturate(dof.viewModelEquation.x * -signedDepth
                                         + dof.viewModelEquation.z);
            nearCoc = max(nearCoc, min(sceneNear, viewModelNear));
        }
    }
    return float4(color, nearCoc);
}

fragment float4 dof_near_coc_fragment(FullscreenOut in [[stage_in]],
                                      texture2d<float> largeBlur [[texture(0)]],
                                      texture2d<float> downsample [[texture(1)]],
                                      sampler sceneSampler [[sampler(0)]]) {
    float4 large = largeBlur.sample(sceneSampler, in.uv);
    float4 original = downsample.sample(sceneSampler, in.uv);
    return float4(original.rgb, 2.0 * max(large.a, original.a) - original.a);
}

fragment float4 dof_small_blur_fragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        sampler sceneSampler [[sampler(0)]]) {
    float2 halfTexel = 0.5 / float2(source.get_width(), source.get_height());
    return (source.sample(sceneSampler, in.uv + float2(-halfTexel.x, -halfTexel.y))
          + source.sample(sceneSampler, in.uv + float2( halfTexel.x, -halfTexel.y))
          + source.sample(sceneSampler, in.uv + float2(-halfTexel.x,  halfTexel.y))
          + source.sample(sceneSampler, in.uv + float2( halfTexel.x,  halfTexel.y))) * 0.25;
}

fragment float4 dof_composite_fragment(FullscreenOut in [[stage_in]],
                                       texture2d<float> sceneColor [[texture(0)]],
                                       texture2d<float> smallBlur [[texture(1)]],
                                       texture2d<float> largeBlur [[texture(2)]],
                                       depth2d<float> sceneDepth [[texture(3)]],
                                       sampler sceneSampler [[sampler(0)]],
                                       constant DofParams &dof [[buffer(0)]]) {
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge,
                                   filter::nearest);
    const float2 ringOffsets[4] = {
        float2( 0.5, -1.5), float2(-1.5, -0.5),
        float2(-0.5,  1.5), float2( 1.5,  0.5)
    };
    float4 original = sceneColor.sample(sceneSampler, in.uv);
    float3 fineBlur = original.rgb * (1.0 / 17.0);
    for (uint sampleIndex = 0u; sampleIndex < 4u; ++sampleIndex)
        fineBlur += sceneColor.sample(sceneSampler,
            in.uv + ringOffsets[sampleIndex] * dof.sceneInvSize).rgb * (4.0 / 17.0);

    float signedDepth = dofSignedEyeDepth(
        sceneDepth.sample(depthSampler, in.uv), dof);
    float farCoc = saturate(dof.sceneEquation.y * signedDepth
                          + dof.sceneEquation.w) * dof.viewModelEquation.w;
    float4 small = smallBlur.sample(sceneSampler, in.uv);
    float coc = signedDepth < 1500000.0 ? max(farCoc, small.a) : small.a;
    // D3D's destination modifier is SATURATE|PARTIALPRECISION (0x3). The
    // bytecode disassembler used during bring-up only printed SATURATE when it
    // was the sole modifier, which initially hid this clamp.
    float4 weights = saturate(coc * dof.lerpScale + dof.lerpBias);
    float2 middleWeights = min(1.0 - weights.xy, weights.yz);
    float3 color = fineBlur * middleWeights.x
                 + original.rgb * weights.x
                 + small.rgb * middleWeights.y
                 + largeBlur.sample(sceneSampler, in.uv).rgb * weights.w;
    return float4(color, 1.0);
}

struct GammaParams {
    float exponent;
    float padding0;
    float padding1;
    float padding2;
};

float3 linearToSrgb(float3 value) {
    value = max(value, 0.0);
    return select(12.92 * value,
                  1.055 * pow(value, float3(1.0 / 2.4)) - 0.055,
                  value > 0.0031308);
}

float3 srgbToLinear(float3 value) {
    value = max(value, 0.0);
    return select(value / 12.92,
                  pow((value + 0.055) / 1.055, float3(2.4)),
                  value > 0.04045);
}

fragment float4 gamma_fragment(FullscreenOut in [[stage_in]],
                               texture2d<float> frameColor [[texture(0)]],
                               sampler frameSampler [[sampler(0)]],
                               constant GammaParams &gamma [[buffer(0)]]) {
    float4 frame = frameColor.sample(frameSampler, in.uv);
    // D3D9 applied R_CalcGammaRamp after the complete frame, including HUD.
    // Recreate that encoded-display-space pow curve, then return to linear so
    // Metal's sRGB drawable performs exactly one final encode.
    float3 encoded = linearToSrgb(frame.rgb);
    encoded = pow(saturate(encoded), float3(gamma.exponent));
    return float4(srgbToLinear(encoded), frame.a);
}

struct SkyOut { float4 position [[position]]; float3 direction; };
vertex SkyOut sky_vertex(const device packed_float2 *vertices [[buffer(0)]],
                         constant float4 *rayBasis [[buffer(1)]],
                         uint id [[vertex_id]]) {
    SkyOut out;
    float2 clip = float2(vertices[id]);
    out.position = float4(clip, 1.0, 1.0);
    float3 worldDirection = rayBasis[0].xyz
                          + clip.x * rayBasis[1].xyz
                          + clip.y * rayBasis[2].xyz;
    // IWI cubemap slices use the standard +X,-X,+Y,-Y,+Z,-Z order. CoD's
    // original sky shader passes its world-space direction straight to the
    // D3D cube sampler; preserve that axis order for Metal as well.
    out.direction = worldDirection;
    return out;
}
fragment float4 sky_fragment(SkyOut in [[stage_in]], texturecube<float> sky [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return float4(sky.sample(smp, normalize(in.direction)).rgb, 1.0);
}

struct WorldVertex {
    packed_float3 position;
    float positionPadding;
    float2 uv;
    float2 lightmapUv;
    float4 color;
    packed_float3 normal;
    float binormalSign;
    packed_float3 tangent;
    float tangentPadding;
};
struct ShadowOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};
struct ShadowParams {
    uint alphaTest;
    uint3 padding;
};
vertex ShadowOut shadow_world_vertex(const device WorldVertex *vertices [[buffer(0)]],
                                     constant float4x4 &shadowViewProjection [[buffer(1)]],
                                     uint id [[vertex_id]]) {
    ShadowOut out;
    out.position = shadowViewProjection * float4(float3(vertices[id].position), 1.0);
    out.uv = vertices[id].uv;
    out.color = vertices[id].color;
    return out;
}
vertex ShadowOut shadow_model_vertex(const device WorldVertex *vertices [[buffer(0)]],
                                     constant float4x4 &shadowViewProjection [[buffer(1)]],
                                     constant float4x4 &model [[buffer(2)]],
                                     uint id [[vertex_id]]) {
    ShadowOut out;
    out.position = shadowViewProjection
                 * model * float4(float3(vertices[id].position), 1.0);
    out.uv = vertices[id].uv;
    out.color = vertices[id].color;
    return out;
}
fragment void shadow_alpha_fragment(ShadowOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler smp [[sampler(0)]],
                                    constant ShadowParams &params [[buffer(0)]]) {
    const float alpha = tex.sample(smp, in.uv).a * in.color.a;
    if ((params.alphaTest == 1 && alpha <= (1.0 / 255.0)) ||
        (params.alphaTest == 2 && alpha >= 0.5) ||
        (params.alphaTest == 3 && alpha < 0.5))
        discard_fragment();
}
struct WorldOut {
    float4 position [[position]];
    float2 uv;
    float2 lightmapUv;
    float4 color;
    float3 worldPosition;
    float3 normal;
    float3 tangent;
    float binormalSign;
    float clipW;
    float clipZ;
    float4 screenLookup;
    float4 tangentClip;
    float4 bitangentClip;
};
vertex WorldOut world_vertex(const device WorldVertex *vertices [[buffer(0)]],
                             constant float4x4 &viewProjection [[buffer(1)]],
                             uint id [[vertex_id]]) {
    WorldOut out;
    float3 worldPosition = float3(vertices[id].position);
    out.position = viewProjection * float4(worldPosition, 1.0);
    out.uv = vertices[id].uv;
    out.lightmapUv = vertices[id].lightmapUv;
    out.color = vertices[id].color;
    out.worldPosition = worldPosition;
    out.normal = normalize(float3(vertices[id].normal));
    out.tangent = normalize(float3(vertices[id].tangent));
    out.binormalSign = vertices[id].binormalSign;
    out.clipW = out.position.w;
    out.clipZ = out.position.z;
    // D3D's clipSpaceLookupScale/Offset path is emitted per vertex and then
    // perspective-interpolated.  Keep that projective coordinate explicitly;
    // fragment [[position]] is a post-viewport value and is not interchangeable
    // for these legacy screen-space material shaders.
    out.screenLookup = float4(0.5 * out.position.x + 0.5 * out.position.w,
                              -0.5 * out.position.y + 0.5 * out.position.w,
                              0.0, out.position.w);
    out.tangentClip = viewProjection * float4(out.tangent, 0.0);
    // The packed-effect vertex shaders form this basis directly as
    // cross(tangent, normal); the standalone binormalSign field is not part of
    // their vertex declaration/algebra.
    float3 bitangent = normalize(cross(out.tangent, out.normal));
    out.bitangentClip = viewProjection * float4(bitangent, 0.0);
    return out;
}
vertex WorldOut model_vertex(const device WorldVertex *vertices [[buffer(0)]],
                             constant float4x4 &viewProjection [[buffer(1)]],
                             constant float4x4 &model [[buffer(2)]],
                             uint id [[vertex_id]]) {
    WorldOut out;
    float4 worldPosition = model * float4(float3(vertices[id].position), 1.0);
    out.position = viewProjection * worldPosition;
    out.uv = vertices[id].uv;
    out.lightmapUv = vertices[id].lightmapUv;
    out.color = vertices[id].color;
    out.worldPosition = worldPosition.xyz;
    out.normal = normalize((model * float4(float3(vertices[id].normal), 0.0)).xyz);
    out.tangent = normalize((model * float4(float3(vertices[id].tangent), 0.0)).xyz);
    out.binormalSign = vertices[id].binormalSign;
    out.clipW = out.position.w;
    out.clipZ = out.position.z;
    out.screenLookup = float4(0.5 * out.position.x + 0.5 * out.position.w,
                              -0.5 * out.position.y + 0.5 * out.position.w,
                              0.0, out.position.w);
    out.tangentClip = viewProjection * float4(out.tangent, 0.0);
    float3 bitangent = normalize(cross(out.tangent, out.normal));
    out.bitangentClip = viewProjection * float4(bitangent, 0.0);
    return out;
}

struct MaterialParams {
    uint flags;
    uint alphaTest;
    uint dynamicLightCount;
    uint padding;
    float4 envMapParms;
    float4 cameraOrigin;
    float4 sunDirection;
    float4 sunColor;
    float4 sunSpecular;
    float4 modelLightBase;
    float4 modelLightScale;
    float4 fog;
    float4 fogColor;
    float4 detailScale;
    float4x4 shadowMatrix[2];
    float4 shadowParams;
    float4 dynamicLightPosition[4];
    float4 dynamicLightColorType[4];
    float4 dynamicLightDirectionExponent[4];
    float4 dynamicLightSpotFactors[4];
};

float3 applyWorldFog(float3 color, WorldOut in, constant MaterialParams &material) {
    float radialDistance = distance(in.worldPosition, material.cameraOrigin.xyz);
    float fogVisibility = saturate(exp(radialDistance * material.fog.z + material.fog.w));
    return mix(material.fogColor.rgb, color, fogVisibility);
}

float sampleSunShadow(WorldOut in, constant MaterialParams &material,
                      depth2d_array<float> shadowMap, sampler shadowSmp) {
    if ((material.flags & 256u) == 0u)
        return 1.0;
    for (uint cascade = 0; cascade < 2; ++cascade) {
        float4 shadowPosition = material.shadowMatrix[cascade]
                              * float4(in.worldPosition, 1.0);
        float3 shadowCoord = shadowPosition.xyz / max(abs(shadowPosition.w), 1.0e-6);
        if (abs(shadowCoord.x) <= 1.0 && abs(shadowCoord.y) <= 1.0
            && shadowCoord.z >= 0.0 && shadowCoord.z <= 1.0) {
            float2 uv = float2(shadowCoord.x * 0.5 + 0.5,
                               0.5 - shadowCoord.y * 0.5);
            return shadowMap.sample_compare(shadowSmp, uv, cascade,
                                            shadowCoord.z - material.shadowParams.x);
        }
    }
    return 1.0;
}

fragment float4 world_fragment(WorldOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                               texture2d<float> lightmap [[texture(1)]],
                               texture2d<float> normalMap [[texture(2)]],
                               texture2d<float> specularMap [[texture(3)]],
                               texturecube<float> reflectionMap [[texture(4)]],
                               texture2d<float> secondaryLightmap [[texture(5)]],
                               texture3d<float> modelLighting [[texture(6)]],
                               texture2d<float> detailMap [[texture(7)]],
                               depth2d_array<float> shadowMap [[texture(8)]],
                               texture2d<float> lightAttenuation0 [[texture(9)]],
                               texture2d<float> lightAttenuation1 [[texture(10)]],
                               texture2d<float> lightAttenuation2 [[texture(11)]],
                               texture2d<float> lightAttenuation3 [[texture(12)]],
                               sampler smp [[sampler(0)]], sampler lightmapSmp [[sampler(1)]],
                               sampler modelLightSmp [[sampler(2)]],
                               sampler detailSmp [[sampler(3)]],
                               sampler shadowSmp [[sampler(4)]],
                               sampler lightAttenuationSmp0 [[sampler(5)]],
                               sampler lightAttenuationSmp1 [[sampler(6)]],
                               sampler lightAttenuationSmp2 [[sampler(7)]],
                               sampler lightAttenuationSmp3 [[sampler(8)]],
                               sampler reflectionSmp [[sampler(9)]],
                               constant MaterialParams &material [[buffer(0)]]) {
    float4 baseColor = tex.sample(smp, in.uv);
    float4 color = baseColor * in.color;
    if ((material.flags & 128u) != 0u) {
        float3 detail = detailMap.sample(detailSmp, in.uv * material.detailScale.xy).rgb;
        color.rgb = (baseColor.rgb + detail - 0.5) * in.color.rgb;
    }
    if ((material.alphaTest == 1 && color.a <= (1.0 / 255.0)) ||
        (material.alphaTest == 2 && color.a >= 0.5) ||
        (material.alphaTest == 3 && color.a < 0.5)) {
        discard_fragment();
    }

    float3 N = normalize(in.normal);
    float2 tangentNormalXY = float2(0.0);
    float tangentNormalInvLength = 1.0;
    if ((material.flags & 2u) != 0u) {
        float4 packedNormal = normalMap.sample(smp, in.uv);
        // The shipped SM3 shaders expand the DXT5nm alpha/green pair from
        // its quantization-safe [~.25, ~.75] interval, then normalize (x,y,1).
        // Using the common *2-1 decode made CoD4 normal maps far too flat.
        tangentNormalXY = packedNormal.ag * float2(4.08, 4.064516)
                        + float2(-2.08, -2.064516);
        tangentNormalInvLength = rsqrt(dot(tangentNormalXY, tangentNormalXY) + 1.0);
        float3 tangentNormal = float3(tangentNormalXY, 1.0) * tangentNormalInvLength;
        float3 T = normalize(in.tangent - N * dot(N, in.tangent));
        float3 B = normalize(cross(N, T)) * in.binormalSign;
        N = normalize(T * tangentNormal.x + B * tangentNormal.y + N * tangentNormal.z);
    }

    float3 L = normalize(material.sunDirection.xyz);
    float ndl = saturate(dot(N, L));
    float sunShadow = sampleSunShadow(in, material, shadowMap, shadowSmp);
    float3 illumination;
    float sunVisibility = 0.0;
    if ((material.flags & 16u) != 0u) {
        // CoD4 packs two half-height directional-light samples into the
        // secondary lightmap. The alphas encode the light-vector x/y pair;
        // this is a direct translation of lm_*_sm3 rather than an approximation.
        float2 topUv = float2(in.lightmapUv.x, in.lightmapUv.y * 0.5);
        float2 bottomUv = float2(in.lightmapUv.x, in.lightmapUv.y * 0.5 + 0.5);
        float4 topLight = secondaryLightmap.sample(lightmapSmp, topUv);
        float4 bottomLight = secondaryLightmap.sample(lightmapSmp, bottomUv);
        float2 encodedLight = float2(topLight.a, bottomLight.a)
                            * float2(4.08, 4.064516)
                            + float2(-2.08, -2.064516);
        float lightInvLength = rsqrt(dot(encodedLight, encodedLight) + 1.0);
        float directionalWeight = lightInvLength;
        if ((material.flags & 2u) != 0u) {
            float alignment = dot(encodedLight, tangentNormalXY) + 1.0;
            directionalWeight = saturate((alignment + 1.0)
                                * lightInvLength * tangentNormalInvLength);
        }
        illumination = topLight.rgb * tangentNormalInvLength
                     + bottomLight.rgb * directionalWeight;
        if ((material.flags & 1u) != 0u) {
            // The integrated sun technique adds the L8 shadow mask to the
            // directional bake. Metal exposes L8 as R8, so read .r explicitly.
            float sunMask = lightmap.sample(lightmapSmp, in.lightmapUv).r;
            sunVisibility = sunMask * sunShadow;
            illumination += sunVisibility * ndl * material.sunColor.rgb;
        }
    } else if ((material.flags & 1u) != 0u) {
        float baked = lightmap.sample(lightmapSmp, in.lightmapUv).r;
        illumination = float3(baked);
    } else if ((material.flags & 32u) != 0u) {
        // IW3's lp_* model shaders normalize the surface normal onto a cube,
        // then trilinearly sample the cached 4x4x4 directional light volume.
        // RGB stores half-intensity ambient/directional light; alpha is the
        // visibility weight for the selected primary light (normally the sun).
        float maxNormalComponent = max(abs(N.x), max(abs(N.y), abs(N.z)));
        float3 cubeNormal = N / max(maxNormalComponent, 1.0e-6);
        float3 modelLightUv = material.modelLightBase.xyz
                            + cubeNormal * material.modelLightScale.xyz;
        float4 modelLight = modelLighting.sample(modelLightSmp, modelLightUv);
        illumination = 2.0 * modelLight.rgb;
        if ((material.flags & 64u) != 0u) {
            sunVisibility = modelLight.a * sunShadow;
            illumination += sunVisibility * ndl * material.sunColor.rgb;
        }
    } else {
        illumination = 0.24 + material.sunColor.rgb * (0.76 * ndl * sunShadow);
    }
    const float3 unlitSurface = color.rgb;
    color.rgb *= illumination;

    // Direct translation of l_omni/l_spot.  The original shader samples the
    // authored attenuation image at saturate(distance / radius), rather than
    // using a generic inverse-square approximation, then adds the pass to the
    // already-lit surface.  Spot lights additionally apply their exact cone
    // scale/bias/exponent constants from R_SetLightProperties.
    float3 dynamicIllumination = float3(0.0);
    for (uint lightIndex = 0; lightIndex < material.dynamicLightCount; ++lightIndex) {
        const float lightType = material.dynamicLightColorType[lightIndex].w;
        if (lightType != 2.0 && lightType != 3.0)
            continue;
        float3 toLight = material.dynamicLightPosition[lightIndex].xyz - in.worldPosition;
        float distanceSquared = dot(toLight, toLight);
        if (distanceSquared <= 1.0e-12)
            continue;
        float inverseDistance = rsqrt(distanceSquared);
        float3 lightDirection = toLight * inverseDistance;
        float radial = saturate((1.0 / inverseDistance)
                              * material.dynamicLightPosition[lightIndex].w);
        float3 attenuation;
        if (lightIndex == 0)
            attenuation = lightAttenuation0.sample(lightAttenuationSmp0, float2(radial)).rgb;
        else if (lightIndex == 1)
            attenuation = lightAttenuation1.sample(lightAttenuationSmp1, float2(radial)).rgb;
        else if (lightIndex == 2)
            attenuation = lightAttenuation2.sample(lightAttenuationSmp2, float2(radial)).rgb;
        else
            attenuation = lightAttenuation3.sample(lightAttenuationSmp3, float2(radial)).rgb;

        float cone = 1.0;
        if (lightType == 2.0) {
            float spot = dot(lightDirection,
                             material.dynamicLightDirectionExponent[lightIndex].xyz)
                       * material.dynamicLightSpotFactors[lightIndex].x
                       + material.dynamicLightSpotFactors[lightIndex].y;
            cone = spot < 0.0 ? 0.0
                 : pow(spot, material.dynamicLightDirectionExponent[lightIndex].w);
        }
        dynamicIllumination += attenuation
                             * (max(dot(lightDirection, N), 0.0) * cone)
                             * material.dynamicLightColorType[lightIndex].rgb;
    }
    color.rgb += unlitSurface * dynamicIllumination;

    if ((material.flags & 4u) != 0u) {
        float4 packedSpecular = specularMap.sample(smp, in.uv);
        float3 incident = normalize(in.worldPosition - material.cameraOrigin.xyz);
        float viewDotNormal = dot(incident, N);
        float3 reflected = normalize(incident - (2.0 * viewDotNormal) * N);
        // Analytically this lies in [0,1], but Metal's normalization can put
        // the dot a few ulps outside that range.  Fractional pow of the
        // resulting negative epsilon is NaN and blackens the complete pixel.
        float edge = saturate(1.0 - abs(viewDotNormal));
        float fresnel = mix(material.envMapParms.x, material.envMapParms.y,
                            pow(edge, material.envMapParms.z));
        float3 surfaceSpecular = packedSpecular.rgb * fresnel;
        float3 specularLighting = float3(0.0);

        if ((material.flags & 8u) != 0u) {
            // The D3D9 shader selects a deliberately broad cubemap mip for
            // rough pixels and the sharpest mip for glossy pixels.
            float reflectionLod = 6.0 - 8.0 * packedSpecular.a;
            float4 environment = reflectionMap.sample(
                reflectionSmp, reflected, level(reflectionLod));
            specularLighting = environment.rgb * environment.a;
        }
        if (sunVisibility > 0.0) {
            // Direct specular is the original IW3 exponential lobe.  The
            // constants below are verbatim from lm_sun_r0c0n0s0_sm3:
            // exp((R.L - .99925) * (exp2(alpha * 9.3775177) + 7)).
            float glossWidth = exp2(packedSpecular.a * 9.3775177) + 7.0;
            float highlight = exp((dot(reflected, L) - 0.99925) * glossWidth);
            specularLighting += sunVisibility * highlight
                              * material.envMapParms.w * material.sunSpecular.rgb;
        }
        color.rgb += specularLighting * surfaceSpecular;
    }
    color.rgb = applyWorldFog(color.rgb, in, material);
    color.a = (material.flags & 512u) != 0u ? baseColor.a * in.color.a : 1.0;
    return color;
}

fragment float4 world_simple_fragment(WorldOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler smp [[sampler(0)]],
                                      constant MaterialParams &material [[buffer(0)]]) {
    float4 color = tex.sample(smp, in.uv) * in.color;
    if ((material.alphaTest == 1 && color.a <= (1.0 / 255.0)) ||
        (material.alphaTest == 2 && color.a >= 0.5) ||
        (material.alphaTest == 3 && color.a < 0.5))
        discard_fragment();
    return color;
}

fragment float4 world_simple_fog_fragment(WorldOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler smp [[sampler(0)]],
                                          constant MaterialParams &material [[buffer(0)]]) {
    float4 color = tex.sample(smp, in.uv) * in.color;
    if ((material.alphaTest == 1 && color.a <= (1.0 / 255.0)) ||
        (material.alphaTest == 2 && color.a >= 0.5) ||
        (material.alphaTest == 3 && color.a < 0.5))
        discard_fragment();
    color.rgb = applyWorldFog(color.rgb, in, material);
    return color;
}

fragment float4 world_add_fog_fragment(WorldOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler smp [[sampler(0)]],
                                       constant MaterialParams &material [[buffer(0)]]) {
    float4 color = tex.sample(smp, in.uv) * in.color;
    color.rgb = applyWorldFog(color.rgb, in, material);
    color.rgb *= color.a;
    return color;
}

fragment float4 world_multiply_fragment(WorldOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        sampler smp [[sampler(0)]]) {
    float3 multiplied = tex.sample(smp, in.uv).rgb * in.color.rgb;
    return float4(multiplied * in.color.a + (1.0 - in.color.a), 1.0);
}

struct WaterParams {
    float4 cameraOrigin;
    float4 envMapParms;
    float4 waterColor;
    float4 fog;
    float4 fogColor;
    float4 sunDirection;
    float4 sunColor;
};

float waterHeight(texture2d<float> heightMap, sampler smp, float2 uv) {
    float height = 0.0;
    float amplitude = 1.0;
    for (uint octave = 0; octave < 3; ++octave) {
        height += heightMap.sample(smp, uv).r * amplitude;
        uv *= 3.7;
        amplitude *= 0.6;
    }
    return height;
}

fragment float4 water_fragment(WorldOut in [[stage_in]],
                               texture2d<float> heightMap [[texture(0)]],
                               texturecube<float> reflectionMap [[texture(1)]],
                               sampler smp [[sampler(0)]],
                               sampler reflectionSmp [[sampler(1)]],
                               constant WaterParams &water [[buffer(0)]]) {
    // Direct translation of IW3's water_l_sun SM3 program. The source color
    // map is deliberately absent: it is an editor preview, not a diffuse map.
    if (in.color.a <= (1.0 / 255.0))
        discard_fragment();

    float3 incident = normalize(in.worldPosition - water.cameraOrigin.xyz);
    float coarseHeight = heightMap.sample(smp, in.uv * 0.5).r;
    float2 uv = in.uv + (0.5 - coarseHeight) * incident.xy * 0.0234375;
    float centerHeight = waterHeight(heightMap, smp, uv);
    float heightX = waterHeight(heightMap, smp, uv + float2(1.0 / 256.0, 0.0));
    float heightY = waterHeight(heightMap, smp, uv + float2(0.0, 1.0 / 256.0));
    float3 normal = normalize(float3(heightX - centerHeight,
                                    heightY - centerHeight, 1.0));

    float incidentDotNormal = dot(incident, normal);
    float3 reflected = incident - 2.0 * incidentDotNormal * normal;
    reflected.z = abs(reflected.z);
    float4 reflectedSample = reflectionMap.sample(reflectionSmp, reflected);
    float3 reflectedColor = 4.0 * reflectedSample.a * reflectedSample.rgb
                          - water.waterColor.rgb * normal.z;

    float edge = 1.0 - abs(incidentDotNormal);
    float fresnelPower = pow(max(edge, 0.0), water.envMapParms.z);
    float fresnel = saturate(mix(water.envMapParms.x,
                                 water.envMapParms.y, fresnelPower));
    float3 color = fresnel * reflectedColor + normal.z * water.waterColor.rgb;

    float sunAlignment = max(dot(reflected, water.sunDirection.xyz) + 0.00075, 0.0);
    float specular = pow(fresnel * sunAlignment, 64.0);
    color += specular * water.sunColor.rgb * water.envMapParms.w;

    float radialDistance = distance(in.worldPosition, water.cameraOrigin.xyz);
    float fogVisibility = saturate(exp(radialDistance * water.fog.z + water.fog.w));
    color = mix(water.fogColor.rgb, color, fogVisibility);
    return float4(color, in.color.a);
}

fragment float4 effect_simple_fragment(WorldOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv) * in.color;
}

struct EffectParams {
    uint flags;
    float zNear;
    float maxDepth;
    float featherInvDistance;
    float2 viewportInvSize;
    float2 distortionScale;
    float4 cameraOrigin;
    float4 fog;
    float4 fogColor;
    float4 falloffParms;
    float4 falloffBeginColor;
    float4 falloffEndColor;
};

float linearEyeDepth(float depth, constant EffectParams &effect) {
    // SetSceneDepthRange maps world depth into [1/64, 1]. Undo that viewport
    // transform before inverting IW3's infinite-perspective projection.
    float projectionDepth = saturate((depth - (1.0 / 64.0)) * (64.0 / 63.0));
    return effect.maxDepth * effect.zNear
         / max(effect.maxDepth - projectionDepth, 0.000001);
}

fragment float4 effect_fragment(WorldOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                texture2d<float> resolvedScene [[texture(1)]],
                                depth2d<float> resolvedDepth [[texture(2)]],
                                sampler smp [[sampler(0)]],
                                constant EffectParams &effect [[buffer(0)]]) {
    constexpr sampler resolvedSampler(coord::normalized, address::clamp_to_edge,
                                      filter::linear);
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge,
                                   filter::nearest);
    float lookupBaseW = abs(in.screenLookup.w) >= 0.000001
        ? in.screenLookup.w
        : (in.screenLookup.w < 0.0 ? -0.000001 : 0.000001);
    float2 screenUv = in.screenLookup.xy / lookupBaseW
                    + 0.5 * effect.viewportInvSize;
    if ((effect.flags & 2u) != 0u) {
        float4 distortion = tex.sample(smp, in.uv);
        float2 signedDistortion = distortion.rg * 2.0 - 1.0;
        // Preserve the projective W terms emitted by IW3's
        // distortion_scale_zfeather_dtex vertex shader.  Dividing each basis
        // vector by the unperturbed W first is only an affine approximation;
        // for nearby explosion cards it can drive the lookup across most of
        // the framebuffer, producing blue patches and giant scene-colored
        // polygons.  The original shader adds both homogeneous offsets and
        // performs one texldp divide afterwards.
        float4 distortedLookup = in.screenLookup;
        distortedLookup.xy += 0.5 * effect.viewportInvSize * distortedLookup.w;
        float4 tangentLookup = float4(0.5 * in.tangentClip.xy,
                                     0.0, in.tangentClip.w)
                             * effect.distortionScale.x * in.color.r;
        // This is the exact c17/c12 product emitted by
        // distortion_scale_zfeather_dtex for cross(tangent, normal).
        float4 bitangentLookup = float4(-0.5 * in.bitangentClip.xy,
                                       0.0, -in.bitangentClip.w)
                               * effect.distortionScale.y * in.color.g;
        distortedLookup += signedDistortion.x * tangentLookup
                         + signedDistortion.y * bitangentLookup;
        // TEXLD_PROJECT performs this divide unconditionally in the stock
        // shader. The depth/Float-Z comparison below decides whether its
        // result is visible at the displaced sample.
        float2 distortedUv = distortedLookup.xy / distortedLookup.w;
        // IW3's distortion z-feather shader does not compare hardware depth
        // to the fragment's window-space depth. Its s5 sampler is the FLOAT_Z
        // color target, whose build shader stores scene clip W, and v5.x is
        // the particle's raw clip Z. Reconstruct the former from Metal's
        // hardware depth and preserve the latter as an explicit varying.
        float sampledDepth = resolvedDepth.sample(depthSampler, distortedUv);
        // The retail FLOAT_Z target is cleared to the literal sentinel 1,
        // not to far-plane clip W. Preserve that value for untouched sky.
        float sceneFloatZ = sampledDepth >= 0.999999
            ? 1.0 : linearEyeDepth(sampledDepth, effect);
        float2 chosenUv = abs(sceneFloatZ) >= in.clipZ
            ? distortedUv : screenUv;
        float3 sceneColor = resolvedScene.sample(resolvedSampler, chosenUv).rgb;
        float alpha = distortion.a * in.color.a;
        if (((effect.flags & 32u) != 0u && alpha <= (1.0 / 255.0))
            || ((effect.flags & 64u) != 0u && alpha >= 0.5)
            || ((effect.flags & 128u) != 0u && alpha < 0.5))
            discard_fragment();
        // The stock VS emits COLOR0 as v1.zzzw: blue is the uniform RGB
        // intensity, while red/green independently scale the two refraction
        // basis vectors.  Treating RGB as an ordinary tint exposes every
        // overlapping card as a dark colored polygon.
        return float4(sceneColor * in.color.b, alpha);
    }

    float4 color = tex.sample(smp, in.uv) * in.color;
    float radialDistance = distance(in.worldPosition, effect.cameraOrigin.xyz);
    if ((effect.flags & 8u) != 0u) {
        float3 viewDirection = normalize(in.worldPosition - effect.cameraOrigin.xyz);
        float facing = dot(viewDirection, normalize(in.normal));
        float falloff = saturate(facing * facing * effect.falloffParms.z
                               + effect.falloffParms.w);
        float3 falloffColor = mix(effect.falloffEndColor.rgb,
                                  effect.falloffBeginColor.rgb, falloff);
        color.rgb *= falloffColor * falloff;
    }
    if ((effect.flags & 1u) != 0u) {
        float sceneDistance = linearEyeDepth(resolvedDepth.sample(depthSampler, screenUv), effect);
        float particleDistance = max(abs(in.clipW), effect.zNear);
        float intersectionFade = saturate((sceneDistance - particleDistance)
                                        * effect.featherInvDistance);
        float nearFade = saturate(particleDistance * effect.featherInvDistance);
        color.a *= intersectionFade * nearFade;
    }
    if ((effect.flags & 16u) != 0u) {
        float fogVisibility = saturate(exp(radialDistance * effect.fog.z + effect.fog.w));
        color.rgb = mix(effect.fogColor.rgb, color.rgb, fogVisibility);
    }
    // IW3's additive pixel shaders premultiply RGB and pair that with the
    // material's ONE/ONE blend state. Regular alpha effects remain straight.
    if ((effect.flags & 4u) != 0u)
        color.rgb *= color.a;
    if (((effect.flags & 32u) != 0u && color.a <= (1.0 / 255.0))
        || ((effect.flags & 64u) != 0u && color.a >= 0.5)
        || ((effect.flags & 128u) != 0u && color.a < 0.5))
        discard_fragment();
    return color;
}
)MSL";
    NSString *const source = [NSString stringWithUTF8String:sourceText];

    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_0;
    NSError *error = nil;
    id<MTLLibrary> library = [g_device newLibraryWithSource:source options:options error:&error];
    if (!library)
    {
        std::fprintf(stderr, "[metal] shader compilation failed: %s\n", error.localizedDescription.UTF8String);
        return false;
    }
    g_shaderLibrary = library;
    g_flatPipeline = MakePipeline(library, @"ui_flat");
    g_imagePipeline = MakePipeline(library, @"ui_image");
    g_glyphPipeline = MakePipeline(library, @"ui_glyph");
    g_worldPipeline = MakeWorldPipeline(library, @"world_vertex", @"CoD4 world");
    g_worldBlendPipeline = MakeWorldPipeline(library, @"world_vertex", @"CoD4 world alpha",
                                             @"world_fragment", MaterialBlendMode::Alpha);
    g_worldAdditivePipeline = MakeWorldPipeline(library, @"world_vertex", @"CoD4 world additive",
                                                @"world_fragment", MaterialBlendMode::Additive);
    g_waterPipeline = MakeWaterPipeline(library);
    g_modelPipeline = MakeWorldPipeline(library, @"model_vertex", @"CoD4 models");
    g_modelBlendPipeline = MakeWorldPipeline(library, @"model_vertex", @"CoD4 models alpha",
                                             @"world_fragment", MaterialBlendMode::Alpha);
    g_modelAdditivePipeline = MakeWorldPipeline(library, @"model_vertex", @"CoD4 models additive",
                                                @"world_fragment", MaterialBlendMode::Additive);
    g_effectPipeline = MakeWorldPipeline(library, @"model_vertex", @"CoD4 effects",
                                         @"effect_simple_fragment", MaterialBlendMode::Alpha);
    g_effectAdditivePipeline = MakeWorldPipeline(library, @"model_vertex", @"CoD4 additive effects",
                                                 @"effect_simple_fragment", MaterialBlendMode::Additive);
    g_skyPipeline = MakeSkyPipeline(library);
    g_shadowWorldPipeline = MakeShadowPipeline(library, @"shadow_world_vertex", false);
    g_shadowWorldAlphaPipeline = MakeShadowPipeline(library, @"shadow_world_vertex", true);
    g_shadowModelPipeline = MakeShadowPipeline(library, @"shadow_model_vertex", false);
    g_shadowModelAlphaPipeline = MakeShadowPipeline(library, @"shadow_model_vertex", true);
    g_filmPipeline = MakeFullscreenPipeline(library, @"film_fragment", @"CoD4 film composite");
    g_gammaPipeline = MakeFullscreenPipeline(library, @"gamma_fragment", @"CoD4 gamma ramp");
    g_glowSetupPipeline = MakeFullscreenPipeline(library, @"glow_setup_fragment",
                                                 @"CoD4 glow setup");
    g_gaussianPipeline = MakeFullscreenPipeline(library, @"gaussian_fragment",
                                                @"CoD4 Gaussian filter");
    g_gaussian2DPipeline = MakeFullscreenPipeline(library, @"gaussian2d_fragment",
                                                  @"CoD4 Gaussian 2D filter");
    g_dofDownsamplePipeline = MakeFullscreenPipeline(library, @"dof_downsample_fragment",
                                                      @"CoD4 DOF downsample");
    g_dofNearCocPipeline = MakeFullscreenPipeline(library, @"dof_near_coc_fragment",
                                                  @"CoD4 DOF near CoC");
    g_dofSmallBlurPipeline = MakeFullscreenPipeline(library, @"dof_small_blur_fragment",
                                                    @"CoD4 DOF small blur");
    g_dofCompositePipeline = MakeFullscreenPipeline(library, @"dof_composite_fragment",
                                                    @"CoD4 DOF composite");
    g_feedbackBlendPipeline = MakeFullscreenBlendPipeline(
        library, @"feedback_blend_fragment", @"CoD4 feedback blur blend");
    // These are the exact state words authored on shellshock and
    // shellshock_flashed's unlit passes (including separate-alpha state).
    g_shellShockBlurredPipeline = MakeFullscreenStatePipeline(
        library, @"shellshock_blurred_fragment", @"CoD4 shellshock temporal blend",
        0x19289165u);
    g_shellShockFlashedPipeline = MakeFullscreenStatePipeline(
        library, @"shellshock_flashed_fragment", @"CoD4 shellshock flash blend",
        0x19288922u);

    MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
    depth.depthCompareFunction = MTLCompareFunctionLessEqual;
    depth.depthWriteEnabled = YES;
    g_worldDepthState = [g_device newDepthStencilStateWithDescriptor:depth];

    MTLDepthStencilDescriptor *viewModelDepth = [MTLDepthStencilDescriptor new];
    viewModelDepth.depthCompareFunction = MTLCompareFunctionLessEqual;
    viewModelDepth.depthWriteEnabled = YES;
    g_viewModelDepthState = [g_device newDepthStencilStateWithDescriptor:viewModelDepth];

    MTLDepthStencilDescriptor *effectDepth = [MTLDepthStencilDescriptor new];
    effectDepth.depthCompareFunction = MTLCompareFunctionLessEqual;
    effectDepth.depthWriteEnabled = NO;
    g_effectDepthState = [g_device newDepthStencilStateWithDescriptor:effectDepth];
    g_transparentDepthState = g_effectDepthState;

    MTLDepthStencilDescriptor *disabledDepth = [MTLDepthStencilDescriptor new];
    disabledDepth.depthCompareFunction = MTLCompareFunctionAlways;
    disabledDepth.depthWriteEnabled = NO;
    g_disabledDepthState = [g_device newDepthStencilStateWithDescriptor:disabledDepth];

    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_sampler = [g_device newSamplerStateWithDescriptor:sampler];

    MTLSamplerDescriptor *worldSampler = [MTLSamplerDescriptor new];
    worldSampler.minFilter = MTLSamplerMinMagFilterLinear;
    worldSampler.magFilter = MTLSamplerMinMagFilterLinear;
    worldSampler.mipFilter = MTLSamplerMipFilterLinear;
    worldSampler.sAddressMode = MTLSamplerAddressModeRepeat;
    worldSampler.tAddressMode = MTLSamplerAddressModeRepeat;
    worldSampler.maxAnisotropy = 16;
    g_worldSampler = [g_device newSamplerStateWithDescriptor:worldSampler];

    MTLSamplerDescriptor *lightmapSampler = [MTLSamplerDescriptor new];
    lightmapSampler.minFilter = MTLSamplerMinMagFilterLinear;
    lightmapSampler.magFilter = MTLSamplerMinMagFilterLinear;
    lightmapSampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    lightmapSampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_lightmapSampler = [g_device newSamplerStateWithDescriptor:lightmapSampler];

    MTLSamplerDescriptor *modelLightSampler = [MTLSamplerDescriptor new];
    modelLightSampler.minFilter = MTLSamplerMinMagFilterLinear;
    modelLightSampler.magFilter = MTLSamplerMinMagFilterLinear;
    modelLightSampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    modelLightSampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    modelLightSampler.rAddressMode = MTLSamplerAddressModeClampToEdge;
    g_modelLightSampler = [g_device newSamplerStateWithDescriptor:modelLightSampler];

    MTLSamplerDescriptor *shadowSampler = [MTLSamplerDescriptor new];
    shadowSampler.minFilter = MTLSamplerMinMagFilterLinear;
    shadowSampler.magFilter = MTLSamplerMinMagFilterLinear;
    shadowSampler.mipFilter = MTLSamplerMipFilterNotMipmapped;
    shadowSampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    shadowSampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    shadowSampler.compareFunction = MTLCompareFunctionLessEqual;
    g_shadowSampler = [g_device newSamplerStateWithDescriptor:shadowSampler];

    const uint32_t white = 0xffffffffu;
    TextureLayout whiteLayout{MTLPixelFormatBGRA8Unorm, 0, 4, false};
    g_whiteTexture = UploadTexture(1, 1, whiteLayout,
                                   reinterpret_cast<const unsigned char *>(&white), sizeof(white));
    return g_queue && g_flatPipeline && g_imagePipeline && g_glyphPipeline
        && g_worldPipeline && g_waterPipeline && g_modelPipeline
        && g_effectPipeline && g_effectAdditivePipeline
        && g_skyPipeline
        && g_shadowWorldPipeline && g_shadowWorldAlphaPipeline
        && g_shadowModelPipeline && g_shadowModelAlphaPipeline
        && g_filmPipeline && g_gammaPipeline && g_glowSetupPipeline && g_gaussianPipeline
        && g_gaussian2DPipeline && g_dofDownsamplePipeline && g_dofNearCocPipeline
        && g_dofSmallBlurPipeline && g_dofCompositePipeline && g_feedbackBlendPipeline
        && g_shellShockBlurredPipeline && g_shellShockFlashedPipeline
        && g_worldDepthState && g_viewModelDepthState && g_effectDepthState
        && g_disabledDepthState
        && g_sampler && g_worldSampler
        && g_lightmapSampler && g_modelLightSampler && g_shadowSampler && g_whiteTexture;
}

void DumpDrawable(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> texture)
{
    const NSUInteger bytesPerRow = texture.width * 4;
    id<MTLBuffer> pixels = [g_device newBufferWithLength:bytesPerRow * texture.height
                                                options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                 toBuffer:pixels destinationOffset:0 destinationBytesPerRow:bytesPerRow
       destinationBytesPerImage:bytesPerRow * texture.height];
    [blit endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    char path[MAX_OSPATH];
    if (g_dumpPath && *g_dumpPath)
        I_strncpyz(path, g_dumpPath, sizeof(path));
    else
        Com_sprintf(path, sizeof(path), "%s/screenshots/metal%04d.ppm",
                    fs_basepath->current.string, g_dumpCount++);
    FS_CreatePath(path);
    if (FILE *file = std::fopen(path, "wb"))
    {
        std::fprintf(file, "P6\n%lu %lu\n255\n", texture.width, texture.height);
        const auto *bgra = static_cast<const uint8_t *>(pixels.contents);
        for (NSUInteger y = 0; y < texture.height; ++y)
        {
            const uint8_t *row = bgra + y * bytesPerRow;
            for (NSUInteger x = 0; x < texture.width; ++x)
            {
                const uint8_t rgb[3] = {row[x * 4 + 2], row[x * 4 + 1], row[x * 4]};
                std::fwrite(rgb, 1, sizeof(rgb), file);
            }
        }
        std::fclose(file);
        Com_Printf(8, "[metal] wrote %s (%lux%lu)\n", path, texture.width, texture.height);
    }
}

} // namespace

bool CreateWindow(const int width, const int height)
{
    // A raw Terminal launch has no application bundle metadata, so AppKit
    // otherwise labels it with the executable name and shows the generic
    // black "exec" tile in the Dock.  The packaged app gets the same identity
    // from Info.plist; these assignments make both launch paths consistently
    // appear as jgalbs cod4 with the project-owned icon.
    [NSProcessInfo processInfo].processName = @"jgalbs cod4";
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"jgalbs-cod4" ofType:@"icns"];
    if (!iconPath)
    {
        NSString *const executableDirectory = [[[NSBundle mainBundle] executablePath]
            stringByDeletingLastPathComponent];
        NSString *const adjacentIcon = [executableDirectory
            stringByAppendingPathComponent:@"jgalbs-cod4-icon.png"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:adjacentIcon])
            iconPath = adjacentIcon;
    }
    if (!iconPath && fs_basepath && fs_basepath->current.string[0])
    {
        iconPath = [[NSString stringWithUTF8String:fs_basepath->current.string]
            stringByAppendingPathComponent:@"jgalbs-cod4-icon.png"];
    }
    if (iconPath)
    {
        NSImage *const applicationIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (applicationIcon)
            [NSApp setApplicationIconImage:applicationIcon];
    }

    // A focused game is inherently user-initiated, latency-sensitive work.
    // Explicitly declaring it prevents App Nap from throttling the engine when
    // its window temporarily loses focus (notably a second native client).
    g_processActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep
                                  | NSActivityLatencyCritical)
                        reason:@"Native jgalbs cod4 gameplay"];
    g_dumpPath = std::getenv("KISAK_METAL_DUMP");
    g_hideUi = std::getenv("KISAK_METAL_HIDE_UI") != nullptr;
    g_autoJoin = std::getenv("KISAK_METAL_AUTO_JOIN") != nullptr;
    g_traceRenderer = std::getenv("KISAK_METAL_TRACE") != nullptr;
    g_profileRenderer = std::getenv("KISAK_METAL_PROFILE") != nullptr;
    if (g_dumpPath)
    {
        const char *const dumpFrame = std::getenv("KISAK_METAL_DUMP_FRAME");
        g_dumpFrame = dumpFrame ? std::atoi(dumpFrame) : 120;
    }
    // SDL maps RESIZABLE to NSWindowStyleMaskResizable and opts the window
    // into macOS full-screen Spaces. Without it AppKit disables the green
    // traffic-light control entirely, even though the Metal renderer already
    // follows the drawable size every frame.
    g_window = SDL_CreateWindow("jgalbs cod4", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                width, height, SDL_WINDOW_METAL | SDL_WINDOW_SHOWN
                                    | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE);
    if (!g_window)
    {
        std::fprintf(stderr, "SDL_CreateWindow(Metal) failed: %s\n", SDL_GetError());
        return false;
    }
    // Keep multiple native clients visible during deterministic multiplayer
    // tests. macOS throttles fully occluded CAMetalLayer windows, which makes
    // frame-based input automation needlessly nondeterministic. Normal launches
    // remain centered when these diagnostic variables are absent.
    const char *const windowX = std::getenv("KISAK_WINDOW_X");
    const char *const windowY = std::getenv("KISAK_WINDOW_Y");
    if (windowX && windowY)
        SDL_SetWindowPosition(g_window, std::atoi(windowX), std::atoi(windowY));
    g_metalView = SDL_Metal_CreateView(g_window);
    if (!g_metalView)
    {
        std::fprintf(stderr, "SDL_Metal_CreateView failed: %s\n", SDL_GetError());
        return false;
    }
    g_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(g_metalView);
    // SDL's refresh-rate query can report zero for a variable-refresh
    // ProMotion panel.  NSScreen exposes the panel's maximum cadence, which is
    // the value CoD4 expects in vidConfig when choosing frame-rate policy.
    NSScreen *const screen = [NSScreen mainScreen];
    if (screen && screen.maximumFramesPerSecond > 0)
        g_displayFrequency = static_cast<int>(screen.maximumFramesPerSecond);
    else
    {
        SDL_DisplayMode displayMode{};
        const int displayIndex = SDL_GetWindowDisplayIndex(g_window);
        if (displayIndex >= 0 && SDL_GetCurrentDisplayMode(displayIndex, &displayMode) == 0
            && displayMode.refresh_rate > 0)
        {
            g_displayFrequency = displayMode.refresh_rate;
        }
    }
    SDL_GetWindowSize(g_window, &g_uiWidth, &g_uiHeight);
    SDL_Metal_GetDrawableSize(g_window, &g_viewportWidth, &g_viewportHeight);
    return InitMetal();
}

SDL_Window *Window()
{
    return g_window;
}

bool AdoptContext()
{
    g_ready = g_layer && g_device && g_queue;
    if (g_ready)
        std::printf("[metal] native device: %s, drawable %dx%d\n",
                    g_device.name.UTF8String, g_viewportWidth, g_viewportHeight);
    return g_ready;
}

bool HasWindow()
{
    return g_window != nullptr;
}

int DisplayFrequency()
{
    return g_displayFrequency;
}

namespace {

constexpr NSString *kGameDataDefaultsKey = @"CoD4RetailDataDirectory";

bool CopyPath(NSString *source, char *path, const std::size_t pathSize)
{
    if (!source || !path || !pathSize)
        return false;
    const char *const fileSystemPath = source.fileSystemRepresentation;
    if (!fileSystemPath || std::strlen(fileSystemPath) >= pathSize)
        return false;
    std::memcpy(path, fileSystemPath, std::strlen(fileSystemPath) + 1);
    return true;
}

bool ContainsRetailData(NSString *directory)
{
    if (!directory)
        return false;
    NSString *const sentinel = [directory stringByAppendingPathComponent:@"main/iw_00.iwd"];
    return [[NSFileManager defaultManager] isReadableFileAtPath:sentinel];
}

} // namespace

bool SavedGameDataDirectory(char *path, const std::size_t pathSize)
{
    @autoreleasepool
    {
        NSString *const saved = [[NSUserDefaults standardUserDefaults]
            stringForKey:kGameDataDefaultsKey];
        return ContainsRetailData(saved) && CopyPath(saved, path, pathSize);
    }
}

bool SelectGameDataDirectory(char *path, const std::size_t pathSize)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        NSOpenPanel *const panel = [NSOpenPanel openPanel];
        panel.title = @"Locate Call of Duty 4";
        panel.message = @"Choose your Call of Duty 4 folder (the folder containing main/iw_00.iwd).";
        panel.prompt = @"Use This Folder";
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = NO;
        while ([panel runModal] == NSModalResponseOK)
        {
            NSString *const selected = panel.URL.path;
            if (ContainsRetailData(selected))
            {
                [[NSUserDefaults standardUserDefaults] setObject:selected
                                                          forKey:kGameDataDefaultsKey];
                return CopyPath(selected, path, pathSize);
            }
            NSAlert *const alert = [NSAlert new];
            alert.messageText = @"That is not a Call of Duty 4 data folder";
            alert.informativeText = @"Select the folder that contains main/iw_00.iwd.";
            [alert runModal];
        }
        return false;
    }
}

bool WritableGameDataDirectory(char *path, const std::size_t pathSize)
{
    @autoreleasepool
    {
        NSURL *const applicationSupport = [[NSFileManager defaultManager]
            URLForDirectory:NSApplicationSupportDirectory
                   inDomain:NSUserDomainMask
          appropriateForURL:nil
                     create:YES
                      error:nil];
        NSURL *const writable = [applicationSupport URLByAppendingPathComponent:@"cod4"
                                                                    isDirectory:YES];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:writable
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error])
        {
            std::fprintf(stderr, "Could not create cod4 Application Support folder: %s\n",
                         error.localizedDescription.UTF8String);
            return false;
        }
        return CopyPath(writable.path, path, pathSize);
    }
}

void WindowSize(int *width, int *height)
{
    int w = 0;
    int h = 0;
    if (g_window)
        SDL_GetWindowSize(g_window, &w, &h);
    if (width) *width = w;
    if (height) *height = h;
}

void RequestWindowSize(const int width, const int height)
{
    if (width < 640 || height < 480)
        return;
    const auto packed = (static_cast<unsigned long long>(static_cast<unsigned int>(width)) << 32)
        | static_cast<unsigned int>(height);
    g_requestedWindowSize.store(packed, std::memory_order_release);
}

void UpdateWindowMainThread()
{
    if (!g_window || (SDL_GetWindowFlags(g_window) & SDL_WINDOW_FULLSCREEN) != 0)
        return;
    const auto packed = g_requestedWindowSize.exchange(0, std::memory_order_acq_rel);
    if (!packed)
        return;
    const int width = static_cast<int>(packed >> 32);
    const int height = static_cast<int>(packed & 0xffffffffu);
    SDL_SetWindowSize(g_window, width, height);
}

void DrawableSize(int *width, int *height)
{
    int w = 0;
    int h = 0;
    if (g_window)
        SDL_Metal_GetDrawableSize(g_window, &w, &h);
    if (width) *width = w;
    if (height) *height = h;
}

void RequestFrameDump()
{
    g_dumpRequested = true;
}

void PresentFrame()
{
    if (!g_ready)
        return;
    @autoreleasepool
    {
        const double profileFrameStart = g_profileRenderer
            ? CACurrentMediaTime() : 0.0;
        double profileEncodeStart = 0.0;
        double profileAcquireStart = 0.0;
        double profileAcquireEnd = 0.0;
        bool profileThisFrame = false;
        const auto encodeProfiled = [&](const MetalProfilePass pass, auto &&encode) {
            if (!profileThisFrame)
            {
                encode();
                return;
            }
            const double start = CACurrentMediaTime();
            encode();
            const double elapsed = (CACurrentMediaTime() - start) * 1000.0;
            g_profilePassMilliseconds[pass] += elapsed;
            g_profilePassMaxMilliseconds[pass] =
                std::max(g_profilePassMaxMilliseconds[pass], elapsed);
        };
        const int currentFrame = g_frameCount++;
        // Frame dumps use the same gameplay-relative convention as the input
        // hooks.  Keeping the path as the enable flag leaves -1 available as
        // a useful "one frame after control becomes active" target.
        const int resolvedDumpFrame = g_dumpFrame >= 0 ? g_dumpFrame
            : (g_profilePlayableFrame >= 0
                ? g_profilePlayableFrame - g_dumpFrame : INT_MIN);
        if (g_dumpPath && currentFrame == resolvedDumpFrame)
            g_dumpRequested = true;
        SDL_GetWindowSize(g_window, &g_uiWidth, &g_uiHeight);
        SDL_Metal_GetDrawableSize(g_window, &g_viewportWidth, &g_viewportHeight);

        // Match the legacy renderer's public control while using Metal's
        // native presentation mechanism.  With vsync enabled, CAMetalLayer
        // paces directly at ProMotion's current cadence; an additional
        // com_maxfps sleep would miss refresh boundaries and create judder.
        if (r_vsync)
        {
            static int appliedVsync = -1;
            const int wantedVsync = r_vsync->current.enabled ? 1 : 0;
            if (wantedVsync != appliedVsync)
            {
                appliedVsync = wantedVsync;
                g_layer.displaySyncEnabled = wantedVsync ? YES : NO;
                if (wantedVsync && com_maxfps && com_maxfps->current.integer)
                    Dvar_SetIntByName("com_maxfps", 0);
                Com_Printf(8, "[metal] presentation: %d Hz, vsync=%d (layer=%d), triple buffered\n",
                           g_displayFrequency, wantedVsync,
                           g_layer.displaySyncEnabled ? 1 : 0);
            }
        }

        // Deterministic console-command hook for end-to-end tests.  Each
        // semicolon-separated entry is "frame,command" and follows the real
        // command buffer, so movement/teleport/viewpos tests exercise the
        // same client-command and network paths as typed console input. A
        // negative frame means that many frames after first-person gameplay
        // becomes active (for example -60), avoiding map/countdown timing races.
        const char *autocmd = std::getenv("KISAK_AUTOCMD");
        for (const char *step = autocmd; step && *step;)
        {
            const char *const comma = std::strchr(step, ',');
            const char *const next = std::strchr(step, ';');
            const int requestedFrame = std::atoi(step);
            const int commandFrame = requestedFrame >= 0 ? requestedFrame
                : (g_profilePlayableFrame >= 0
                    ? g_profilePlayableFrame - requestedFrame : INT_MIN);
            if (comma && (!next || comma < next) && currentFrame == commandFrame)
            {
                const char *const command = comma + 1;
                const size_t commandLength = next
                    ? static_cast<size_t>(next - command) : std::strlen(command);
                if (commandLength > 0 && commandLength < 1023)
                {
                    char commandLine[1024];
                    std::memcpy(commandLine, command, commandLength);
                    commandLine[commandLength] = '\n';
                    commandLine[commandLength + 1] = '\0';
                    Com_Printf(8, "[metal] diagnostic command at frame %d: %.*s\n",
                               currentFrame, static_cast<int>(commandLength), command);
                    Cbuf_AddText(0, commandLine);
                }
            }
            step = next ? next + 1 : nullptr;
        }

        // Deterministic native UI test input. Coordinates are SDL window points,
        // matching UI_MouseEvent even on Retina displays. A semicolon-separated
        // sequence allows complete menu paths: "x,y,frame;x,y,frame".
        const char *autoclick = std::getenv("KISAK_AUTOCLICK");
        for (const char *step = autoclick; step && *step;)
        {
            int clickX = 0;
            int clickY = 0;
            int clickFrame = 0;
            if (std::sscanf(step, "%d,%d,%d", &clickX, &clickY, &clickFrame) == 3)
            {
                if (currentFrame >= clickFrame - 4 && currentFrame <= clickFrame + 4)
                    posix_input::InjectCursor(clickX, clickY);
                if (currentFrame == clickFrame)
                    posix_input::InjectKey(K_MOUSE1, true);
                if (currentFrame == clickFrame + 2)
                    posix_input::InjectKey(K_MOUSE1, false);
            }
            const char *const next = std::strchr(step, ';');
            step = next ? next + 1 : nullptr;
        }

        // Deterministic gameplay input for renderer/animation validation. Each
        // semicolon-separated step is "key,downFrame,heldFrames", using the
        // engine key number (printable keys use their lowercase ASCII value).
        // A negative downFrame is an offset from first-person gameplay.
        const char *autokey = std::getenv("KISAK_AUTOKEY");
        for (const char *step = autokey; step && *step;)
        {
            int key = 0;
            int downFrame = 0;
            int heldFrames = 0;
            if (std::sscanf(step, "%i,%d,%d", &key, &downFrame, &heldFrames) == 3)
            {
                const int resolvedDownFrame = downFrame >= 0 ? downFrame
                    : (g_profilePlayableFrame >= 0
                        ? g_profilePlayableFrame - downFrame : INT_MIN);
                if (currentFrame == resolvedDownFrame)
                    posix_input::InjectKey(key, true);
                if (currentFrame == resolvedDownFrame + std::max(heldFrames, 1))
                    posix_input::InjectKey(key, false);
            }
            const char *const next = std::strchr(step, ';');
            step = next ? next + 1 : nullptr;
        }

        // Deterministic relative mouse motion for the native camera/input regression
        // test. Each step is "dx,dy,frame" and enters the same accumulator as an
        // SDL_MOUSEMOTION event, so the engine's smoothing and sensitivity remain in
        // the path under test. A negative motionFrame is gameplay-relative.
        const char *automouse = std::getenv("KISAK_AUTOMOUSE");
        for (const char *step = automouse; step && *step;)
        {
            int dx = 0;
            int dy = 0;
            int motionFrame = 0;
            if (std::sscanf(step, "%d,%d,%d", &dx, &dy, &motionFrame) == 3)
            {
                const int resolvedMotionFrame = motionFrame >= 0 ? motionFrame
                    : (g_profilePlayableFrame >= 0
                        ? g_profilePlayableFrame - motionFrame : INT_MIN);
                if (currentFrame == resolvedMotionFrame)
                {
                    posix_input::InjectMotion(dx, dy);
                    Com_Printf(8, "[metal] diagnostic mouse motion: (%d,%d) at frame %d\n",
                               dx, dy, currentFrame);
                }
            }
            const char *const next = std::strchr(step, ';');
            step = next ? next + 1 : nullptr;
        }

        static const GfxWorld *reportedWorld = nullptr;
        static std::string reportedWorldName;
        static unsigned int reportedWorldVertices = 0;
        static int reportedWorldIndices = 0;
        static int reportedWorldSurfaces = 0;
        if (!rgp.world && reportedWorld)
        {
            ClearLevelResourceCaches();
            reportedWorld = nullptr;
            reportedWorldName.clear();
            reportedWorldVertices = 0;
            reportedWorldIndices = 0;
            reportedWorldSurfaces = 0;
            // Gameplay-relative diagnostics are level-relative as well.  Reset
            // their anchors so profiling, automated input and auto-join exercise
            // every map after a rotation instead of only the first map in a run.
            g_worldSeenFrame = -1;
            g_profilePlayableFrame = -1;
            g_dumpedFirstWorldView = false;
        }
        const char *const currentWorldName = rgp.world && rgp.world->name
            ? rgp.world->name : "";
        if (rgp.world
            && (rgp.world != reportedWorld || reportedWorldName != currentWorldName
                || reportedWorldVertices != rgp.world->vertexCount
                || reportedWorldIndices != rgp.world->indexCount
                || reportedWorldSurfaces != rgp.world->surfaceCount))
        {
            ClearLevelResourceCaches();
            reportedWorld = rgp.world;
            reportedWorldName = currentWorldName;
            reportedWorldVertices = rgp.world->vertexCount;
            reportedWorldIndices = rgp.world->indexCount;
            reportedWorldSurfaces = rgp.world->surfaceCount;
            Com_Printf(8, "[metal] world '%s': %u vertices, %d indices, %d surfaces\n",
                       rgp.world->name ? rgp.world->name : "(unnamed)", rgp.world->vertexCount,
                       rgp.world->indexCount, rgp.world->surfaceCount);
            PrewarmMaterialPipelines(rgp.world);
            PrewarmWorldResources(rgp.world);
        }
        if (g_autoJoin && rgp.world && g_worldSeenFrame < 0)
            g_worldSeenFrame = g_frameCount;
        if (g_autoJoin && g_worldSeenFrame >= 0 && g_frameCount == g_worldSeenFrame + 60)
        {
            // Move first so IN_Frame has time to publish the position before the
            // click event reaches the menu on the following frame.
            posix_input::InjectCursor(g_uiWidth * 320 / 1280, g_uiHeight * 390 / 720);
        }
        if (g_autoJoin && g_worldSeenFrame >= 0 && g_frameCount == g_worldSeenFrame + 65)
        {
            Com_Printf(8, "[metal] diagnostic auto-join: click Auto-Assign at frame %d\n", g_frameCount);
            PushAutoAssignClick();
        }
        if (g_autoJoin && g_worldSeenFrame >= 0 && g_frameCount == g_worldSeenFrame + 90)
        {
            // The first selectable class row is centred at virtual y=112.  The
            // old y=82 target landed on the "Default Classes" heading after the
            // Retina/safe-area UI fixes, leaving diagnostics stuck in this menu.
            posix_input::InjectCursor(g_uiWidth * 320 / 1280, g_uiHeight * 112 / 720);
        }
        if (g_autoJoin && g_worldSeenFrame >= 0 && g_frameCount == g_worldSeenFrame + 95)
        {
            Com_Printf(8, "[metal] diagnostic auto-join: click Assault at frame %d\n", g_frameCount);
            PushAutoAssignClick();
        }
        static bool reportedView = false;
        if (!reportedView && frontEndDataOut && frontEndDataOut->viewInfoCount)
        {
            reportedView = true;
            const GfxViewInfo &view = frontEndDataOut->viewInfo[frontEndDataOut->viewInfoIndex];
            Com_Printf(8, "[metal] first 3D view: origin=(%.1f %.1f %.1f), viewport=%dx%d\n",
                       view.viewParms.origin[0], view.viewParms.origin[1], view.viewParms.origin[2],
                       view.sceneViewport.width, view.sceneViewport.height);
            if (g_traceRenderer)
            {
                Com_Printf(8, "[metal] postfx: film=%d brightness=%.4f contrast=%.4f "
                              "desaturation=%.4f invert=%d dark=(%.3f %.3f %.3f) "
                              "light=(%.3f %.3f %.3f); glow=%d cutoff=%.4f "
                              "desaturation=%.4f intensity=%.4f radius=%.4f; "
                              "dof=(%.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f) "
                              "blur=%.3f gamma=%.3f\n",
                           view.film.enabled, view.film.brightness, view.film.contrast,
                           view.film.desaturation, view.film.invert,
                           view.film.tintDark[0], view.film.tintDark[1], view.film.tintDark[2],
                           view.film.tintLight[0], view.film.tintLight[1], view.film.tintLight[2],
                           view.glow.enabled, view.glow.bloomCutoff,
                           view.glow.bloomDesaturation, view.glow.bloomIntensity,
                           view.glow.radius, view.dof.viewModelStart, view.dof.viewModelEnd,
                           view.dof.nearStart, view.dof.nearEnd, view.dof.farStart,
                           view.dof.farEnd, view.dof.nearBlur, view.dof.farBlur,
                           view.blurRadius, r_gamma ? r_gamma->current.value : 1.0f);
                TraceMaterialTechnique(rgp.postFxColorMaterial);
                TraceMaterialTechnique(rgp.glowConsistentSetupMaterial);
                TraceMaterialTechnique(rgp.glowApplyBloomMaterial);
                TraceMaterialTechnique(rgp.dofDownsampleMaterial);
                TraceMaterialTechnique(rgp.dofNearCocMaterial);
                TraceMaterialTechnique(rgp.smallBlurMaterial);
                TraceMaterialTechnique(rgp.postFxDofMaterial);
                TraceMaterialTechnique(rgp.postFxDofColorMaterial);
                TraceMaterialTechnique(rgp.feedbackBlendMaterial);
                TraceMaterialTechnique(rgp.feedbackFilmBlendMaterial);
                TraceMaterialTechnique(rgp.shellShockBlurredMaterial);
                TraceMaterialTechnique(rgp.shellShockFlashedMaterial);
            }
        }

        g_vertices.clear();
        g_batches.clear();
        g_savedScreenCommands.clear();
        const GfxCmdArray *commands = frontEndDataOut ? frontEndDataOut->commands : nullptr;
        if (!g_hideUi)
            DispatchCommands(commands);

        profileEncodeStart = g_profileRenderer ? CACurrentMediaTime() : 0.0;
        id<MTLCommandBuffer> commandBuffer = [g_queue commandBuffer];
        const GfxViewInfo *view = nullptr;
        if (frontEndDataOut && frontEndDataOut->viewInfoCount)
        {
            view = &frontEndDataOut->viewInfo[frontEndDataOut->viewInfoIndex];
            // A world view and first-person weapon are both rendered during the
            // pre-match freeze, so visuals alone are not a gameplay signal.
            // Anchor tests/profiling only when the predicted player can actually
            // accept movement; this also makes two-client countdowns deterministic.
            if (g_profilePlayableFrame < 0
                && clientUIActives[0].connectionState == CA_ACTIVE
                && cgArray[0].nextSnap
                && cgArray[0].predictedPlayerState.pm_type == PM_NORMAL
                && !(cgArray[0].predictedPlayerState.pm_flags & PMF_FROZEN))
            {
                g_profilePlayableFrame = g_frameCount;
                if (g_profileRenderer)
                    Com_Printf(8, "[metal-profile] gameplay warmup begins at frame %d\n",
                               g_profilePlayableFrame);
            }
            profileThisFrame = g_profileRenderer
                && g_profilePlayableFrame >= 0
                && g_frameCount >= g_profilePlayableFrame + 60;
            if (g_traceRenderer && view->pointLightCount > 0)
            {
                static int reportedDynamicLightFrames = 0;
                if (reportedDynamicLightFrames++ < 48)
                {
                    Com_Printf(8, "[metal] dynamic lights frame=%d partitions=%d sceneAdded=%d\n",
                               g_frameCount, view->pointLightCount, scene.addedLightCount);
                    for (int lightIndex = 0;
                         lightIndex < std::min(view->pointLightCount, 4); ++lightIndex)
                    {
                        const GfxLight &light = view->pointLightPartitions[lightIndex].light;
                        const GfxImage *attenuation = light.def
                            ? light.def->attenuation.image : nullptr;
                        Com_Printf(8, "[metal]   light[%d] type=%u origin=(%.1f %.1f %.1f) "
                                      "radius=%.1f color=(%.2f %.2f %.2f) attenuation=%s %ux%u\n",
                                   lightIndex, light.type, light.origin[0], light.origin[1],
                                   light.origin[2], light.radius, light.color[0], light.color[1],
                                   light.color[2], attenuation && attenuation->name
                                       ? attenuation->name : "(none)",
                                   attenuation ? attenuation->width : 0,
                                   attenuation ? attenuation->height : 0);
                    }
                }
            }
            encodeProfiled(PROFILE_PASS_SETUP, [&] {
                PrepareViewModelLighting(*view);
                UploadModelLighting(commandBuffer);
                EncodeSunShadows(commandBuffer, *view);
            });
        }
        // Saved-screen commands form a continuous temporal effect.  A frame
        // without one is the renderer-side lifetime boundary corresponding to
        // cgame clearing shellshock.hasSavedScreen.  Session/world/time checks
        // cover disconnects and map restarts even if a stale blend command is
        // queued on the transition frame.
        ValidateSavedScreenHistoryForFrame(view);
        const EffectFrameRequirements effectRequirements = AnalyzeEffectFrameRequirements();
        const bool usingDepthOfField = UsingDepthOfField(view);
        EnsureResolvedEffectTextures(effectRequirements);
        EnsureFrameColorTextures();
        EnsureDepthTexture();
        if (!g_sceneColorTexture || !g_postColorTexture || !g_depthTexture)
            return;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = g_sceneColorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = g_clearColor;
        pass.depthAttachment.texture = g_depthTexture;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = (effectRequirements.sceneDepth || usingDepthOfField)
            ? MTLStoreActionStore : MTLStoreActionDontCare;
        pass.depthAttachment.clearDepth = 1.0;

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (view)
        {
            encodeProfiled(PROFILE_PASS_SKY, [&] { EncodeSky(encoder, *view); });
            encodeProfiled(PROFILE_PASS_WORLD, [&] { EncodeWorld(encoder, *view); });
            encodeProfiled(PROFILE_PASS_STATIC_MODELS,
                           [&] { EncodeStaticModels(encoder, *view); });
            encodeProfiled(PROFILE_PASS_DYNAMIC_ENTITIES,
                           [&] { EncodeDynamicEntities(encoder, *view); });
            encodeProfiled(PROFILE_PASS_SCENE_BRUSHES,
                           [&] { EncodeSceneBrushes(encoder, *view); });
            encodeProfiled(PROFILE_PASS_SCENE_MODELS,
                           [&] { EncodeSceneModels(encoder, *view); });
            if (g_dumpPath && g_hideUi && !g_dumpedFirstWorldView)
            {
                g_dumpedFirstWorldView = true;
                g_dumpRequested = true;
            }
        }
        if (view && (effectRequirements.sceneColor || effectRequirements.sceneDepth))
        {
            [encoder endEncoding];
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            const MTLSize copySize = MTLSizeMake(g_sceneColorTexture.width,
                                                  g_sceneColorTexture.height, 1);
            if (effectRequirements.sceneColor && g_resolvedSceneTexture)
            {
                [blit copyFromTexture:g_sceneColorTexture sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:copySize
                            toTexture:g_resolvedSceneTexture destinationSlice:0
                     destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            if (effectRequirements.sceneDepth && g_resolvedDepthTexture)
            {
                [blit copyFromTexture:g_depthTexture sourceSlice:0 sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:copySize
                            toTexture:g_resolvedDepthTexture destinationSlice:0
                     destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            }
            [blit endEncoding];

            MTLRenderPassDescriptor *effectPass = [MTLRenderPassDescriptor renderPassDescriptor];
            effectPass.colorAttachments[0].texture = g_sceneColorTexture;
            effectPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            effectPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            effectPass.depthAttachment.texture = g_depthTexture;
            effectPass.depthAttachment.loadAction = MTLLoadActionLoad;
            effectPass.depthAttachment.storeAction = usingDepthOfField
                ? MTLStoreActionStore : MTLStoreActionDontCare;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:effectPass];
        }
        if (view)
        {
            encodeProfiled(PROFILE_PASS_EFFECTS, [&] {
                EncodeCodeMeshes(encoder, *view);
                // FX code meshes bind their own color/distortion/depth textures
                // directly.  Marks use world_fragment immediately afterwards, so
                // the material cache must not assume the pre-FX texture table is
                // still resident on this encoder.  A stale slot 0 made impact
                // decals sample the last muzzle/smoke texture when both passes
                // shared the main render encoder.
                InvalidateMaterialBindings();
                EncodeMarkMeshes(encoder, *view);
            });
        }
        [encoder endEncoding];
        InvalidateMaterialBindings();

        const double profilePostStart = profileThisFrame ? CACurrentMediaTime() : 0.0;
        id<MTLTexture> postSceneTexture = g_sceneColorTexture;
        if (view && usingDepthOfField)
            postSceneTexture = EncodeDepthOfField(commandBuffer, *view);

        MetalFilmParams filmParams = FilmParamsForView(view);
        const bool usingGlow = UsingGlow(view);
        if (usingGlow)
        {
            filmParams.glowEnabled = 1;
            filmParams.glowApply[3] = view->glow.bloomIntensity;
            const MetalGlowSetupParams glowParams = GlowSetupParamsForView(*view, filmParams);

            MTLRenderPassDescriptor *glowSetupPass = [MTLRenderPassDescriptor renderPassDescriptor];
            glowSetupPass.colorAttachments[0].texture = g_glowTexture[0];
            glowSetupPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            glowSetupPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:glowSetupPass];
            SetCachedRenderPipeline(encoder, g_glowSetupPipeline);
            [encoder setFragmentTexture:postSceneTexture atIndex:0];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];
            [encoder setFragmentBytes:&glowParams length:sizeof(glowParams) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];

            const float glowRadius = view->glow.radius
                * static_cast<float>(g_viewportHeight) / 1920.0f;
            const MetalGaussianParams horizontal = GaussianParams(
                glowRadius, static_cast<unsigned int>(g_glowTexture[0].width), true);
            MTLRenderPassDescriptor *horizontalPass = [MTLRenderPassDescriptor renderPassDescriptor];
            horizontalPass.colorAttachments[0].texture = g_glowTexture[1];
            horizontalPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            horizontalPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:horizontalPass];
            SetCachedRenderPipeline(encoder, g_gaussianPipeline);
            [encoder setFragmentTexture:g_glowTexture[0] atIndex:0];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];
            [encoder setFragmentBytes:&horizontal length:sizeof(horizontal) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];

            const MetalGaussianParams vertical = GaussianParams(
                glowRadius, static_cast<unsigned int>(g_glowTexture[0].height), false);
            MTLRenderPassDescriptor *verticalPass = [MTLRenderPassDescriptor renderPassDescriptor];
            verticalPass.colorAttachments[0].texture = g_glowTexture[0];
            verticalPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            verticalPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:verticalPass];
            SetCachedRenderPipeline(encoder, g_gaussianPipeline);
            [encoder setFragmentTexture:g_glowTexture[1] atIndex:0];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];
            [encoder setFragmentBytes:&vertical length:sizeof(vertical) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
        }
        const float screenBlurRadius = view ? ScreenBlurRadiusForView(*view) : 0.0f;
        const bool needsPostColor = filmParams.enabled || usingGlow
            || screenBlurRadius > 0.0f || !g_savedScreenCommands.empty();
        id<MTLTexture> composedTexture = postSceneTexture;
        if (needsPostColor)
        {
            MTLRenderPassDescriptor *filmPass = [MTLRenderPassDescriptor renderPassDescriptor];
            filmPass.colorAttachments[0].texture = g_postColorTexture;
            filmPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            filmPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:filmPass];
            SetCachedRenderPipeline(encoder, g_filmPipeline);
            [encoder setFragmentTexture:postSceneTexture atIndex:0];
            [encoder setFragmentTexture:g_glowTexture[0] atIndex:1];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];
            [encoder setFragmentBytes:&filmParams length:sizeof(filmParams) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
            composedTexture = g_postColorTexture;
        }

        if (view && screenBlurRadius > 0.0f)
        {
            EncodeScreenBlur(commandBuffer, *view, filmParams);
            composedTexture = g_postColorTexture;
        }

        if (view)
        {
            EncodeSavedScreenCommands(commandBuffer, *view);
            if (!g_savedScreenCommands.empty())
                composedTexture = g_postColorTexture;
        }
        if (profileThisFrame)
        {
            g_profilePassMilliseconds[PROFILE_PASS_POST] +=
                (CACurrentMediaTime() - profilePostStart) * 1000.0;
        }

        const double profileUiStart = profileThisFrame ? CACurrentMediaTime() : 0.0;
        if (!g_vertices.empty())
        {
            MTLRenderPassDescriptor *uiPass = [MTLRenderPassDescriptor renderPassDescriptor];
            uiPass.colorAttachments[0].texture = composedTexture;
            uiPass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            uiPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            uiPass.depthAttachment.texture = g_depthTexture;
            uiPass.depthAttachment.loadAction = MTLLoadActionDontCare;
            uiPass.depthAttachment.storeAction = MTLStoreActionDontCare;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:uiPass];
            SetCachedDepthState(encoder, g_disabledDepthState);
            id<MTLBuffer> buffer = [g_device newBufferWithBytes:g_vertices.data()
                                                        length:g_vertices.size() * sizeof(UiVertex)
                                                       options:MTLResourceStorageModeShared];
            [encoder setVertexBuffer:buffer offset:0 atIndex:0];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];
            for (const UiBatch &batch : g_batches)
            {
                switch (batch.mode)
                {
                case QuadMode::Flat:  SetCachedRenderPipeline(encoder, g_flatPipeline); break;
                case QuadMode::Image: SetCachedRenderPipeline(encoder, g_imagePipeline); break;
                case QuadMode::Glyph: SetCachedRenderPipeline(encoder, g_glyphPipeline); break;
                }
                if (batch.texture)
                    [encoder setFragmentTexture:batch.texture atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:batch.firstVertex
                            vertexCount:batch.vertexCount];
            }
            [encoder endEncoding];
        }
        if (profileThisFrame)
        {
            g_profilePassMilliseconds[PROFILE_PASS_UI] +=
                (CACurrentMediaTime() - profileUiStart) * 1000.0;
        }

        // Everything above renders into private/offscreen targets. Acquire the
        // scarce CAMetalLayer drawable only for the final gamma/composite pass;
        // asking for it before CPU encoding held all three display buffers and
        // turned nextDrawable into a multi-millisecond front-end stall.
        profileAcquireStart = g_profileRenderer ? CACurrentMediaTime() : 0.0;
        id<CAMetalDrawable> drawable = [g_layer nextDrawable];
        profileAcquireEnd = g_profileRenderer ? CACurrentMediaTime() : 0.0;
        if (!drawable)
            return;
        const double profileGammaStart = profileThisFrame ? CACurrentMediaTime() : 0.0;
        MetalGammaParams gammaParams{};
        gammaParams.exponent = r_gamma && r_gamma->current.value > 0.0f
            && (!r_ignoreHwGamma || !r_ignoreHwGamma->current.enabled)
            ? 1.0f / r_gamma->current.value : 1.0f;
        MTLRenderPassDescriptor *gammaPass = [MTLRenderPassDescriptor renderPassDescriptor];
        gammaPass.colorAttachments[0].texture = drawable.texture;
        gammaPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        gammaPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        encoder = [commandBuffer renderCommandEncoderWithDescriptor:gammaPass];
        SetCachedRenderPipeline(encoder, g_gammaPipeline);
        [encoder setFragmentTexture:composedTexture atIndex:0];
        [encoder setFragmentSamplerState:g_sampler atIndex:0];
        [encoder setFragmentBytes:&gammaParams length:sizeof(gammaParams) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        if (profileThisFrame)
        {
            g_profilePassMilliseconds[PROFILE_PASS_GAMMA] +=
                (CACurrentMediaTime() - profileGammaStart) * 1000.0;
        }

        if (profileThisFrame)
        {
            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                const double gpuStart = completed.GPUStartTime;
                const double gpuEnd = completed.GPUEndTime;
                if (gpuEnd > gpuStart)
                {
                    const uint64_t nanoseconds = static_cast<uint64_t>(
                        (gpuEnd - gpuStart) * 1000000000.0);
                    g_profileGpuNanoseconds.fetch_add(
                        nanoseconds, std::memory_order_relaxed);
                    g_profileGpuSamples.fetch_add(1, std::memory_order_relaxed);
                    uint64_t previousMax = g_profileGpuMaxNanoseconds.load(
                        std::memory_order_relaxed);
                    while (previousMax < nanoseconds
                           && !g_profileGpuMaxNanoseconds.compare_exchange_weak(
                               previousMax, nanoseconds, std::memory_order_relaxed))
                    {
                    }
                }
            }];
        }

        if (g_dumpRequested)
        {
            g_dumpRequested = false;
            DumpDrawable(commandBuffer, drawable.texture);
        }
        else
        {
            if (r_vsync && r_vsync->current.enabled)
                [commandBuffer presentDrawable:drawable];
            else
                [commandBuffer presentDrawable:drawable afterMinimumDuration:0.0];
            [commandBuffer commit];
        }

        if (profileThisFrame)
        {
            const double profileEnd = CACurrentMediaTime();
            const double acquireMilliseconds =
                (profileAcquireEnd - profileAcquireStart) * 1000.0;
            const double cpuMilliseconds = std::max(0.0,
                (profileEnd - profileEncodeStart) * 1000.0 - acquireMilliseconds);
            g_profileCpuMilliseconds += cpuMilliseconds;
            g_profileAcquireMilliseconds += acquireMilliseconds;
            g_profileCpuMaxMilliseconds =
                std::max(g_profileCpuMaxMilliseconds, cpuMilliseconds);
            g_profileAcquireMaxMilliseconds =
                std::max(g_profileAcquireMaxMilliseconds, acquireMilliseconds);
            ++g_profileViewFrames;
            if (g_profilePreviousViewStart > 0.0)
            {
                const double frameMilliseconds =
                    (profileFrameStart - g_profilePreviousViewStart) * 1000.0;
                g_profileFrameMilliseconds += frameMilliseconds;
                g_profileFrameMaxMilliseconds =
                    std::max(g_profileFrameMaxMilliseconds, frameMilliseconds);
                if (frameMilliseconds > 8.333333)
                    ++g_profileFramesOver8Milliseconds;
                if (frameMilliseconds > 16.666667)
                    ++g_profileFramesOver16Milliseconds;
                ++g_profileFrameSamples;
            }
            g_profilePreviousViewStart = profileFrameStart;

            if (g_profileViewFrames >= 120)
            {
                const uint64_t gpuNanoseconds = g_profileGpuNanoseconds.exchange(
                    0, std::memory_order_relaxed);
                const uint64_t gpuSamples = g_profileGpuSamples.exchange(
                    0, std::memory_order_relaxed);
                const uint64_t gpuMaxNanoseconds = g_profileGpuMaxNanoseconds.exchange(
                    0, std::memory_order_relaxed);
                const double averageCpu = g_profileCpuMilliseconds
                    / static_cast<double>(g_profileViewFrames);
                const double averageFrame = g_profileFrameSamples
                    ? g_profileFrameMilliseconds
                        / static_cast<double>(g_profileFrameSamples)
                    : 0.0;
                const double averageGpu = gpuSamples
                    ? static_cast<double>(gpuNanoseconds) / 1000000.0
                        / static_cast<double>(gpuSamples)
                    : 0.0;
                const double averageAcquire = g_profileAcquireMilliseconds
                    / static_cast<double>(g_profileViewFrames);
                Com_Printf(8, "[metal-profile] %u view frames: frame=%.3f/%.3fms "
                              "avg/max (%.1f fps), spikes >8.3/>16.7ms=%u/%u, "
                              "drawable=%.3f/%.3fms, encode CPU=%.3f/%.3fms, "
                              "GPU=%.3f/%.3fms (%llu samples)\n",
                           g_profileViewFrames, averageFrame,
                           g_profileFrameMaxMilliseconds,
                           averageFrame > 0.0 ? 1000.0 / averageFrame : 0.0,
                           g_profileFramesOver8Milliseconds,
                           g_profileFramesOver16Milliseconds,
                           averageAcquire, g_profileAcquireMaxMilliseconds,
                           averageCpu, g_profileCpuMaxMilliseconds,
                           averageGpu,
                           static_cast<double>(gpuMaxNanoseconds) / 1000000.0,
                           static_cast<unsigned long long>(gpuSamples));
                Com_Printf(8, "[metal-profile] CPU passes avg/max ms: "
                              "setup=%.3f/%.3f sky=%.3f/%.3f world=%.3f/%.3f "
                              "static=%.3f/%.3f dyn=%.3f/%.3f brushes=%.3f/%.3f "
                              "models=%.3f/%.3f effects=%.3f/%.3f post=%.3f/%.3f "
                              "UI=%.3f/%.3f gamma=%.3f/%.3f\n",
                           g_profilePassMilliseconds[PROFILE_PASS_SETUP]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_SETUP],
                           g_profilePassMilliseconds[PROFILE_PASS_SKY]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_SKY],
                           g_profilePassMilliseconds[PROFILE_PASS_WORLD]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_WORLD],
                           g_profilePassMilliseconds[PROFILE_PASS_STATIC_MODELS]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_STATIC_MODELS],
                           g_profilePassMilliseconds[PROFILE_PASS_DYNAMIC_ENTITIES]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_DYNAMIC_ENTITIES],
                           g_profilePassMilliseconds[PROFILE_PASS_SCENE_BRUSHES]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_SCENE_BRUSHES],
                           g_profilePassMilliseconds[PROFILE_PASS_SCENE_MODELS]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_SCENE_MODELS],
                           g_profilePassMilliseconds[PROFILE_PASS_EFFECTS]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_EFFECTS],
                           g_profilePassMilliseconds[PROFILE_PASS_POST]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_POST],
                           g_profilePassMilliseconds[PROFILE_PASS_UI]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_UI],
                           g_profilePassMilliseconds[PROFILE_PASS_GAMMA]
                               / static_cast<double>(g_profileViewFrames),
                           g_profilePassMaxMilliseconds[PROFILE_PASS_GAMMA]);
                g_profileCpuMilliseconds = 0.0;
                g_profileAcquireMilliseconds = 0.0;
                g_profileFrameMilliseconds = 0.0;
                g_profileCpuMaxMilliseconds = 0.0;
                g_profileAcquireMaxMilliseconds = 0.0;
                g_profileFrameMaxMilliseconds = 0.0;
                g_profileViewFrames = 0;
                g_profileFrameSamples = 0;
                g_profileFramesOver8Milliseconds = 0;
                g_profileFramesOver16Milliseconds = 0;
                std::fill(std::begin(g_profilePassMilliseconds),
                          std::end(g_profilePassMilliseconds), 0.0);
                std::fill(std::begin(g_profilePassMaxMilliseconds),
                          std::end(g_profilePassMaxMilliseconds), 0.0);
            }
        }
    }
}

} // namespace posix_gl
