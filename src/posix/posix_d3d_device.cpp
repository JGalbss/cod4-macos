// Bring up a real Direct3D 9 device on macOS, through DXVK.
//
// r_init.cpp owns this in the upstream tree, but it is half Win32 windowing -
// RegisterClass, WS_POPUP, MonitorFromPoint, DestroyWindow - which SDL already
// does here, so the file is not built. Only the device half is wanted, and this
// mirrors R_CreateDevice / R_SetD3DPresentParameters / R_CreateDeviceInternal
// against the same API. DXVK Native takes an SDL_Window* where Windows takes an
// HWND, so the window this engine already has is the one the device presents to.
//
// See mac/dxvk/README.md for the library itself and the patches it needs.

#include "posix_d3d_device.h"

#include "gfx_d3d/r_dvars.h"
#include "gfx_d3d/r_init.h"
#include "gfx_d3d/r_buffers.h"
#include "gfx_d3d/r_model_lighting.h"
#include "gfx_d3d/r_rendercmds.h"
#include "gfx_d3d/r_rendertarget.h"
#include "gfx_d3d/r_scene.h"
#include "gfx_d3d/r_state.h"
#include "gfx_d3d/rb_state.h"
#include "posix/posix_gl_present.h"
#include "qcommon/qcommon.h"
#include "universal/com_files.h"

#include <SDL.h>
#include <cstdio>

namespace
{
    // R_CreateDevice passes 0x46: HARDWARE_VERTEXPROCESSING | PUREDEVICE | FPU_PRESERVE.
    constexpr unsigned int kDeviceBehavior = 0x46;

    /**
     * What R_SetupGfxMetrics and R_SetShadowmapFormats_DX do in r_init.cpp: ask the
     * device what it can do and record it. Nothing reads these until the render
     * targets are built, and leaving them zero makes the shadowmap format
     * D3DFMT_UNKNOWN, which Create2DTexture rejects with D3DERR_INVALIDCALL.
     */
    void SetupGfxMetrics(unsigned int adapterIndex)
    {
        D3DCAPS9 caps{};
        if (SUCCEEDED(dx.d3d9->GetDeviceCaps(adapterIndex, D3DDEVTYPE_HAL, &caps)))
        {
            gfxMetrics.maxClipPlanes = caps.MaxUserClipPlanes < 6 ? caps.MaxUserClipPlanes : 6;
            gfxMetrics.hasAnisotropicMinFilter = (caps.TextureFilterCaps & D3DPTFILTERCAPS_MINFANISOTROPIC) != 0;
            gfxMetrics.hasAnisotropicMagFilter = (caps.TextureFilterCaps & D3DPTFILTERCAPS_MAGFANISOTROPIC) != 0;
            gfxMetrics.maxAnisotropy = caps.MaxAnisotropy;
            gfxMetrics.slopeScaleDepthBias = (caps.RasterCaps & D3DPRASTERCAPS_SLOPESCALEDEPTHBIAS) != 0;
            gfxMetrics.canMipCubemaps = (caps.TextureCaps & D3DPTEXTURECAPS_MIPCUBEMAP) != 0;
        }

        // Hardware shadow maps if the device will sample a depth texture, which is
        // what the first matching pair here means; otherwise render depth to colour.
        const D3DFORMAT pairs[3][2] = {
            { D3DFMT_D24S8, D3DFMT_R5G6B5   },
            { D3DFMT_D24S8, D3DFMT_X8R8G8B8 },
            { D3DFMT_D24S8, D3DFMT_A8R8G8B8 },
        };

        for (const auto &pair : pairs)
        {
            const D3DFORMAT depthFormat = pair[0];
            const D3DFORMAT colorFormat = pair[1];
            if (FAILED(dx.d3d9->CheckDepthStencilMatch(
                    adapterIndex, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, colorFormat, depthFormat)))
            {
                continue;
            }
            if (FAILED(dx.d3d9->CheckDeviceFormat(
                    adapterIndex, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
                    D3DRTYPE_TEXTURE, depthFormat)))
            {
                continue;
            }
            gfxMetrics.shadowmapFormatPrimary = depthFormat;
            gfxMetrics.shadowmapFormatSecondary = colorFormat;
            gfxMetrics.shadowmapBuildTechType = TECHNIQUE_BUILD_SHADOWMAP_DEPTH;
            gfxMetrics.hasHardwareShadowmap = 1;
            gfxMetrics.shadowmapSamplerState = SAMPLER_CLAMP_V | SAMPLER_CLAMP_U | SAMPLER_FILTER_LINEAR;
            return;
        }

        gfxMetrics.shadowmapFormatPrimary = D3DFMT_R32F;
        gfxMetrics.shadowmapFormatSecondary = D3DFMT_D24X8;
        gfxMetrics.shadowmapBuildTechType = TECHNIQUE_BUILD_SHADOWMAP_COLOR;
        gfxMetrics.hasHardwareShadowmap = 0;
        gfxMetrics.shadowmapSamplerState = SAMPLER_CLAMP_V | SAMPLER_CLAMP_U | SAMPLER_FILTER_NEAREST;
    }

    /**
     * Fill present parameters the way R_SetD3DPresentParameters does, minus the
     * anti-aliasing setup, which reads adapter capabilities this path has not
     * gathered yet.
     */
    void SetPresentParameters(D3DPRESENT_PARAMETERS *d3dpp, HWND hwnd, int width, int height)
    {
        memset(d3dpp, 0, sizeof(*d3dpp));
        d3dpp->BackBufferWidth = width;
        d3dpp->BackBufferHeight = height;
        d3dpp->BackBufferFormat = D3DFMT_A8R8G8B8;
        d3dpp->BackBufferCount = 1;
        d3dpp->MultiSampleType = D3DMULTISAMPLE_NONE;
        d3dpp->MultiSampleQuality = 0;
        d3dpp->SwapEffect = D3DSWAPEFFECT_DISCARD;
        // The engine allocates and binds its own depth buffer in r_rendertarget.
        d3dpp->EnableAutoDepthStencil = FALSE;
        d3dpp->AutoDepthStencilFormat = dx.depthStencilFormat;
        d3dpp->PresentationInterval =
            (r_vsync && r_vsync->current.enabled) ? D3DPRESENT_INTERVAL_ONE : D3DPRESENT_INTERVAL_IMMEDIATE;
        d3dpp->hDeviceWindow = hwnd;
        d3dpp->Windowed = TRUE;
    }
}

void Posix_D3DScreenshot()
{
    if (!dx.device)
        return;

    IDirect3DSurface9 *backBuffer = nullptr;
    if (FAILED(dx.device->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &backBuffer)) || !backBuffer)
    {
        Com_PrintError(8, "ERROR: screenshot: no backbuffer\n");
        return;
    }

    D3DSURFACE_DESC desc{};
    backBuffer->GetDesc(&desc);

    // The backbuffer lives in default pool and cannot be locked, so it is copied into
    // a system-memory surface first - the same route the probe in mac/dxvk takes.
    IDirect3DSurface9 *readable = nullptr;
    if (FAILED(dx.device->CreateOffscreenPlainSurface(
            desc.Width, desc.Height, desc.Format, D3DPOOL_SYSTEMMEM, &readable, nullptr))
        || FAILED(dx.device->GetRenderTargetData(backBuffer, readable)))
    {
        Com_PrintError(8, "ERROR: screenshot: could not read the backbuffer\n");
        if (readable)
            readable->Release();
        backBuffer->Release();
        return;
    }

    D3DLOCKED_RECT locked{};
    if (SUCCEEDED(readable->LockRect(&locked, nullptr, D3DLOCK_READONLY)))
    {
        static int count;
        char path[MAX_OSPATH];
        Com_sprintf(path, sizeof(path), "%s/screenshots/shot%04d.ppm",
                    fs_basepath->current.string, count++);
        FS_CreatePath(path);

        if (FILE *const f = fopen(path, "wb"))
        {
            fprintf(f, "P6\n%u %u\n255\n", desc.Width, desc.Height);
            for (unsigned int y = 0; y < desc.Height; ++y)
            {
                const uint8_t *row = static_cast<const uint8_t *>(locked.pBits) + (size_t)y * locked.Pitch;
                for (unsigned int x = 0; x < desc.Width; ++x)
                {
                    // X8R8G8B8 is BGRA in memory on a little-endian host.
                    const uint8_t rgb[3] = { row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0] };
                    fwrite(rgb, 1, sizeof(rgb), f);
                }
            }
            fclose(f);
            Com_Printf(8, "Wrote %s (%ux%u)\n", path, desc.Width, desc.Height);
        }
        readable->UnlockRect();
    }

    readable->Release();
    backBuffer->Release();
}

bool Posix_CreateD3DDevice()
{
    if (dx.device)
        return true;

    SDL_Window *const window = posix_gl::Window();
    if (!window)
    {
        Com_PrintError(8, "ERROR: no window to create a Direct3D device on\n");
        return false;
    }

    dx.d3d9 = Direct3DCreate9(D3D_SDK_VERSION);
    if (!dx.d3d9)
    {
        Com_PrintError(8, "ERROR: Direct3DCreate9 failed. Is DXVK_WSI_DRIVER set?\n");
        return false;
    }

    D3DADAPTER_IDENTIFIER9 ident{};
    if (SUCCEEDED(dx.d3d9->GetAdapterIdentifier(D3DADAPTER_DEFAULT, 0, &ident)))
        Com_Printf(8, "Direct3D adapter: %s\n", ident.Description);

    int width = 0;
    int height = 0;
    SDL_GetWindowSize(window, &width, &height);

    dx.adapterIndex = D3DADAPTER_DEFAULT;
    SetupGfxMetrics(dx.adapterIndex);
    dx.depthStencilFormat = (D3DFORMAT)R_GetDepthStencilFormat(D3DFMT_A8R8G8B8);

    D3DPRESENT_PARAMETERS d3dpp{};
    HWND const hwnd = reinterpret_cast<HWND>(window);
    SetPresentParameters(&d3dpp, hwnd, width, height);

    Com_Printf(8, "Creating Direct3D device...\n");
    const HRESULT hr = dx.d3d9->CreateDevice(
        dx.adapterIndex, D3DDEVTYPE_HAL, hwnd, kDeviceBehavior, &d3dpp, &dx.device);
    if (FAILED(hr) || !dx.device)
    {
        Com_PrintError(8, "ERROR: couldn't create a Direct3D device (0x%08x)\n", (unsigned)hr);
        dx.d3d9->Release();
        dx.d3d9 = nullptr;
        return false;
    }

    dx.deviceLost = 0;
    dx.adapterFullscreenWidth = width;
    dx.adapterFullscreenHeight = height;
    dx.adapterNativeWidth = width;
    dx.adapterNativeHeight = height;
    dx.adapterNativeIsValid = true;

    Com_Printf(8, "Direct3D device created, %dx%d\n", width, height);

    // What R_InitHardware does after R_CreateDevice, minus the parts that belong to
    // Win32 windowing or to the worker threads. RB_SetInitialState is the one that
    // matters most: it copies dx.device into gfxCmdBufState.prim.device, which is
    // where the whole backend reads it from, and it is only called from r_init.cpp.
    // R_StoreWindowSettings' job, and it has to happen before the render targets are
    // sized off it - without this they come out 0 x 0 and the depth-stencil surface
    // fails to create.
    vidConfig.displayWidth = width;
    vidConfig.displayHeight = height;
    vidConfig.sceneWidth = width;
    vidConfig.sceneHeight = height;
    vidConfig.displayFrequency = 0;
    vidConfig.isFullscreen = false;
    vidConfig.aspectRatioWindow = (float)width / (float)height;
    vidConfig.aspectRatioScenePixel = 1.0f;
    vidConfig.aspectRatioDisplayPixel = 1.0f;
    vidConfig.maxTextureSize = 4096;
    vidConfig.maxTextureMaps = 8;

    RB_InitSceneViewport();

    // R_CreateForInitOrReset itself lives in r_init.cpp, but everything it does that
    // matters here is in files that are built.
    Com_Printf(8, "Initializing render targets...\n");
    R_InitRenderTargets();
    R_InitRenderBuffers();
    R_InitModelLightingImage();
    Com_Printf(8, "Initializing dynamic buffers...\n");
    R_CreateDynamicBuffers();

    // RB_SwapBuffers inserts a fence at the end of every frame, so the pool has to
    // exist before the first one completes.
    Com_Printf(8, "Creating Direct3D queries...\n");
    dx.nextFence = 0;
    dx.flushGpuQueryIssued = 0;
    dx.flushGpuQueryCount = 0;
    if (FAILED(dx.device->CreateQuery(D3DQUERYTYPE_EVENT, &dx.flushGpuQuery)))
    {
        Com_PrintError(8, "ERROR: event query creation failed\n");
        return false;
    }
    for (auto &fence : dx.fencePool)
    {
        if (FAILED(dx.device->CreateQuery(D3DQUERYTYPE_EVENT, &fence)))
        {
            Com_PrintError(8, "ERROR: event query creation failed\n");
            return false;
        }
    }

    Com_Printf(8, "Setting initial state...\n");
    RB_SetInitialState();
    R_InitScene();

    // The engine's own "run the frame but do not draw" switch, held on because
    // RB_BeginFrame and RB_Draw3D walk into D3D with no device. There is one now.
    extern int g_disableRendering;
    g_disableRendering = 0;
    return true;
}
