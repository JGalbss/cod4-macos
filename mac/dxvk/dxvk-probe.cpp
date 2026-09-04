// Does DXVK actually bring up a D3D9 device on this machine?
//
// Building DXVK proves nothing about running it: the engine's renderer is worth
// porting to D3D9 only if MoltenVK reports the features DXVK's D3D9 backend needs,
// and that cannot be known from the build. This creates a device against an SDL2
// window exactly the way the engine would, clears to a known colour and reads the
// backbuffer back, so a pass means the whole chain works - SDL2 window, DXVK WSI,
// Vulkan on Metal, and a real present.

#include <SDL.h>
#include <d3d9.h>

#include <cstdio>
#include <cstdlib>

namespace
{
    constexpr int kWidth = 640;
    constexpr int kHeight = 360;

    // Nothing meaningful, just a colour no uninitialised buffer is likely to hold.
    constexpr unsigned kClearR = 0x20;
    constexpr unsigned kClearG = 0x90;
    constexpr unsigned kClearB = 0xC0;

    int Fail(const char *what, long hr)
    {
        std::fprintf(stderr, "FAIL %s (hr=0x%08lx)\n", what, static_cast<unsigned long>(hr));
        return 1;
    }
}

int main()
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
    {
        std::fprintf(stderr, "FAIL SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *const window = SDL_CreateWindow(
        "dxvk probe", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, kWidth, kHeight, SDL_WINDOW_HIDDEN);
    if (!window)
    {
        std::fprintf(stderr, "FAIL SDL_CreateWindow: %s\n", SDL_GetError());
        return 1;
    }

    IDirect3D9 *const d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d)
        return Fail("Direct3DCreate9 returned null", 0);

    D3DADAPTER_IDENTIFIER9 ident{};
    if (const HRESULT hr = d3d->GetAdapterIdentifier(D3DADAPTER_DEFAULT, 0, &ident); FAILED(hr))
        return Fail("GetAdapterIdentifier", hr);
    std::printf("adapter: %s (%s)\n", ident.Description, ident.Driver);

    D3DPRESENT_PARAMETERS pp{};
    pp.BackBufferWidth = kWidth;
    pp.BackBufferHeight = kHeight;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = reinterpret_cast<HWND>(window);
    pp.Windowed = TRUE;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;

    IDirect3DDevice9 *device = nullptr;
    const HRESULT created = d3d->CreateDevice(
        D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, reinterpret_cast<HWND>(window),
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(created) || !device)
        return Fail("CreateDevice", created);

    if (const HRESULT hr = device->Clear(
            0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_XRGB(kClearR, kClearG, kClearB), 1.0f, 0);
        FAILED(hr))
    {
        return Fail("Clear", hr);
    }

    if (const HRESULT hr = device->BeginScene(); FAILED(hr))
        return Fail("BeginScene", hr);
    if (const HRESULT hr = device->EndScene(); FAILED(hr))
        return Fail("EndScene", hr);
    if (const HRESULT hr = device->Present(nullptr, nullptr, nullptr, nullptr); FAILED(hr))
        return Fail("Present", hr);

    // Read the colour back rather than trusting the return codes: a stub that
    // answers S_OK to everything would pass every check above.
    IDirect3DSurface9 *backBuffer = nullptr;
    if (const HRESULT hr = device->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &backBuffer); FAILED(hr))
        return Fail("GetBackBuffer", hr);

    IDirect3DSurface9 *readable = nullptr;
    if (const HRESULT hr = device->CreateOffscreenPlainSurface(
            kWidth, kHeight, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &readable, nullptr);
        FAILED(hr))
    {
        return Fail("CreateOffscreenPlainSurface", hr);
    }

    if (const HRESULT hr = device->GetRenderTargetData(backBuffer, readable); FAILED(hr))
        return Fail("GetRenderTargetData", hr);

    D3DLOCKED_RECT locked{};
    if (const HRESULT hr = readable->LockRect(&locked, nullptr, D3DLOCK_READONLY); FAILED(hr))
        return Fail("LockRect", hr);

    const unsigned pixel = *static_cast<const unsigned *>(locked.pBits) & 0x00FFFFFFu;
    readable->UnlockRect();

    const unsigned expected = (kClearR << 16) | (kClearG << 8) | kClearB;
    std::printf("backbuffer pixel: 0x%06x (expected 0x%06x)\n", pixel, expected);

    readable->Release();
    backBuffer->Release();
    device->Release();
    d3d->Release();
    SDL_DestroyWindow(window);
    SDL_Quit();

    if (pixel != expected)
    {
        std::fprintf(stderr, "FAIL backbuffer did not read back the cleared colour\n");
        return 1;
    }

    std::printf("PASS d3d9 device created, cleared and presented through DXVK\n");
    return 0;
}
