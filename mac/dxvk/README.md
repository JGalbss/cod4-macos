# DXVK on macOS arm64

CoD4's renderer is Direct3D 9 and its materials carry compiled SM3.0 shader
bytecode, so anything that draws the world has to speak D3D9. DXVK Native is a
D3D9 implementation over Vulkan built for exactly this - porting a game without
writing a second renderer - and MoltenVK puts Vulkan on Metal. Going through it
means the game runs its own shaders and its own material system rather than an
approximation of them.

macOS is not a platform upstream DXVK supports. `macos-native.patch` carries the
six changes needed, and `dxvk-probe.cpp` proves the result actually works on the
machine rather than merely compiling.

## Building

```sh
brew install meson ninja molten-vk vulkan-headers vulkan-loader vulkan-tools

git clone --recursive https://github.com/doitsujin/dxvk.git
cd dxvk
git apply /path/to/cod4/mac/dxvk/macos-native.patch

meson setup build-native \
  -Denable_dxgi=false -Denable_d3d8=false -Denable_d3d10=false -Denable_d3d11=false \
  -Dnative_sdl2=enabled -Dnative_sdl3=disabled -Dnative_glfw=disabled \
  --buildtype release
ninja -C build-native
```

The result is `build-native/src/d3d9/libdxvk_d3d9.dylib`, a Mach-O arm64 library
exporting `Direct3DCreate9`.

## Running

Three environment variables are required. DXVK Native has no default window
system, Homebrew's MoltenVK does not install its ICD manifest where the loader
looks, and the loader itself is keg-only.

```sh
export DXVK_WSI_DRIVER=SDL2
export VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json
export DYLD_LIBRARY_PATH=/opt/homebrew/lib
```

## Checking it works

```sh
c++ -std=gnu++17 -arch arm64 -o dxvk-probe dxvk-probe.cpp \
  -I$DXVK/include/native -I$DXVK/include/native/windows -I$DXVK/include/native/directx \
  $(pkg-config --cflags --libs sdl2) \
  -L$DXVK/build-native/src/d3d9 -ldxvk_d3d9 -Wl,-rpath,$DXVK/build-native/src/d3d9
./dxvk-probe
```

It creates a device against an SDL2 window, clears to a known colour, presents,
and reads the backbuffer back - so it fails rather than passes if any part of the
chain is a stub. Expect:

```
PASS d3d9 export created, cleared and presented through DXVK
```

## What the patch changes, and why

Four are portability gaps, plain bugs on a platform nobody builds for:

- `util_env.cpp` - `getExePath` had branches for Linux and FreeBSD and none for
  Darwin, so it fell off the end of a non-void function and clang planted a trap
  there. It fired on the first `Direct3DCreate9`. Uses `_NSGetExecutablePath`.
- `util_env.cpp` - Apple's `pthread_setname_np` can only name the calling thread,
  so it takes one argument rather than two.
- `util_win32_compat.h` - the `LoadLibraryA`/`GetProcAddress` shim over `dlopen`
  is gated on `__unix__`, which Apple's clang does not define.
- `vulkan_loader.cpp` - looks for `libvulkan.so`; on macOS it is `libvulkan.dylib`.
- `d3d9/meson.build` - `--version-script` is GNU ld only.

The sixth is not a bug but a deliberate trade. MoltenVK cannot provide five of
DXVK's fifty-one required features, and the device is rejected outright without
them:

| Feature | Why it is safe to drop for D3D9 |
| --- | --- |
| `geometryShader` | Metal has none. Inside D3D9 the only user is the software vertex processing emulator; a title asking for hardware vertex processing never reaches it. |
| `shaderCullDistance` | `SV_CullDistance` is D3D10+. D3D9 cannot ask for it. |
| `depthClipEnable` | MoltenVK has `depth_clip_control` instead. Depth clipping can no longer be disabled independently of clamping; `depthClamp` is supported and covers the common case. |
| `robustBufferAccess2` | Out-of-bounds buffer reads become undefined rather than clamped. |
| `nullDescriptor` | An unbound resource reads as undefined rather than zero. |

The last two are the ones to suspect if something renders wrongly rather than not
at all. Upstream calls them required for correctness rather than for function, and
the probe passes without them, but a title that samples a slot it never bound will
get undefined data here where it would get zeroes on a desktop GPU.
