# Pinned SDL runtime libraries

The native package uses the official `libsdl-org/sdl2-compat` 2.32.70 shared
library over the official SDL3 3.4.14 runtime. Build and stage both exact arm64
dependencies with:

```zsh
mac/tools/fetch-build-sdl2-compat.zsh
```

The script downloads official release archives into a temporary directory,
verifies their pinned SHA-256 digests, builds for macOS arm64 with a 15.5
deployment target and fixed source timestamp, validates the dylib, and
installs only these local staging artifacts:

- `mac/vendor/SDL2/libSDL2-2.0.0.dylib`
- `mac/vendor/SDL2/LICENSE.txt`
- `mac/vendor/SDL3/libSDL3.dylib`
- `mac/vendor/SDL3/LICENSE.txt`

The dylibs are intentionally ignored by Git. Downloaded sources and build
files remain under the temporary directory and are removed on exit. The
package places `libSDL3.dylib` next to sdl2-compat in `Contents/Frameworks`,
which is the first location sdl2-compat searches on macOS. Packaging runs a
clean runtime probe and fails if SDL2 does not load this app-local SDL3.
