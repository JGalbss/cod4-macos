#!/bin/zsh
set -euo pipefail

export LC_ALL=C
setopt EXTENDED_GLOB

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
config_file="${repo_dir}/mac/sdl2/sdl2-compat-release.conf"
vendor_root="${1:-${repo_dir}/mac/vendor}"

if (( $# > 1 )); then
    print -u2 "usage: $0 [absolute-vendor-staging-root]"
    exit 1
fi

if [[ ! -f "${config_file}" ]]; then
    print -u2 "Pinned SDL configuration is missing: ${config_file}"
    exit 1
fi
source "${config_file}"

if [[ "$(uname -s)" != Darwin ]]; then
    print -u2 "This artifact must be built on macOS."
    exit 1
fi
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]]; then
    print -u2 "This artifact must be built on an Apple Silicon Mac."
    exit 1
fi

typeset -a required_tools
required_tools=(cmake curl file install lipo ninja otool shasum tar xcrun)
for required_tool in "${required_tools[@]}"; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
        print -u2 "Required build tool is missing: ${required_tool}"
        exit 1
    fi
done

if [[ "${vendor_root}" != /* || "${vendor_root}" == / || -L "${vendor_root}" ]]; then
    print -u2 "Destination must be an absolute, non-root, non-symlink path."
    exit 1
fi
if [[ -e "${vendor_root}" && ! -d "${vendor_root}" ]]; then
    print -u2 "Destination exists and is not a directory: ${vendor_root}"
    exit 1
fi
sdl2_destination="${vendor_root}/SDL2"
sdl3_destination="${vendor_root}/SDL3"

expected_sdl2_url="https://github.com/libsdl-org/sdl2-compat/releases/download/release-${SDL2COMPAT_VERSION}/${SDL2COMPAT_ARCHIVE}"
expected_sdl3_url="https://github.com/libsdl-org/SDL/releases/download/release-${SDL3_HEADERS_VERSION}/${SDL3_HEADERS_ARCHIVE}"
if [[ "${SDL2COMPAT_URL}" != "${expected_sdl2_url}" ||
      "${SDL3_HEADERS_URL}" != "${expected_sdl3_url}" ]]; then
    print -u2 "Pinned SDL source URL does not match the official release layout."
    exit 1
fi
if [[ "${SDL2COMPAT_SHA256}" != [0-9a-f]## || ${#SDL2COMPAT_SHA256} -ne 64 ||
      "${SDL3_HEADERS_SHA256}" != [0-9a-f]## || ${#SDL3_HEADERS_SHA256} -ne 64 ]]; then
    print -u2 "Pinned SDL SHA-256 value is malformed."
    exit 1
fi
if [[ "${SDL2COMPAT_DEPLOYMENT_TARGET}" != 15.5 ||
      "${SDL2COMPAT_SOURCE_DATE_EPOCH}" != <-> ||
      "${SDL2COMPAT_DYLIB}" != libSDL2-2.0.0.dylib ||
      "${SDL2COMPAT_INSTALL_NAME}" != @rpath/libSDL2-2.0.0.dylib ||
      "${SDL3_BUILD_DYLIB}" != libSDL3.0.dylib ||
      "${SDL3_RUNTIME_DYLIB}" != libSDL3.dylib ||
      "${SDL3_INSTALL_NAME}" != @rpath/libSDL3.0.dylib ]]; then
    print -u2 "Pinned SDL output contract is not the supported release contract."
    exit 1
fi

build_jobs="${SDL_BUILD_JOBS:-4}"
if [[ "${build_jobs}" != <-> ]] || (( build_jobs < 1 || build_jobs > 16 )); then
    print -u2 "SDL_BUILD_JOBS must be an integer from 1 through 16."
    exit 1
fi

# sdl2-compat includes __DATE__ and __TIME__ in a diagnostic string. Clang
# honors SOURCE_DATE_EPOCH for those macros, making repeated builds with the
# same compiler and SDK byte-identical instead of embedding the wall clock.
export SOURCE_DATE_EPOCH="${SDL2COMPAT_SOURCE_DATE_EPOCH}"
export ZERO_AR_DATE=1
export TZ=UTC

temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent%/}"
temp_dir="$(mktemp -d "${temp_parent}/cod4-macos-sdl2-compat.XXXXXX")"
staged_sdl2_dylib=""
staged_sdl2_license=""
staged_sdl3_dylib=""
staged_sdl3_license=""
cleanup() {
    if [[ -n "${staged_sdl2_dylib}" ]]; then
        rm -f -- "${staged_sdl2_dylib}"
    fi
    if [[ -n "${staged_sdl2_license}" ]]; then
        rm -f -- "${staged_sdl2_license}"
    fi
    if [[ -n "${staged_sdl3_dylib}" ]]; then
        rm -f -- "${staged_sdl3_dylib}"
    fi
    if [[ -n "${staged_sdl3_license}" ]]; then
        rm -f -- "${staged_sdl3_license}"
    fi
    rm -rf -- "${temp_dir}"
}
trap cleanup EXIT

sdl2_archive="${temp_dir}/${SDL2COMPAT_ARCHIVE}"
sdl3_archive="${temp_dir}/${SDL3_HEADERS_ARCHIVE}"

print "Downloading official sdl2-compat ${SDL2COMPAT_VERSION} source..."
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --output "${sdl2_archive}" "${SDL2COMPAT_URL}"
print "Downloading official SDL3 ${SDL3_HEADERS_VERSION} source..."
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --output "${sdl3_archive}" "${SDL3_HEADERS_URL}"

actual_sdl2_sha="$(shasum -a 256 "${sdl2_archive}" | awk '{ print $1 }')"
actual_sdl3_sha="$(shasum -a 256 "${sdl3_archive}" | awk '{ print $1 }')"
if [[ "${actual_sdl2_sha}" != "${SDL2COMPAT_SHA256}" ]]; then
    print -u2 "sdl2-compat source checksum mismatch."
    print -u2 "Expected: ${SDL2COMPAT_SHA256}"
    print -u2 "Actual:   ${actual_sdl2_sha}"
    exit 1
fi
if [[ "${actual_sdl3_sha}" != "${SDL3_HEADERS_SHA256}" ]]; then
    print -u2 "SDL3 header source checksum mismatch."
    print -u2 "Expected: ${SDL3_HEADERS_SHA256}"
    print -u2 "Actual:   ${actual_sdl3_sha}"
    exit 1
fi

unpack_dir="${temp_dir}/source"
mkdir -p -- "${unpack_dir}"
tar -xzf "${sdl2_archive}" -C "${unpack_dir}"
tar -xzf "${sdl3_archive}" -C "${unpack_dir}"

sdl2_source="${unpack_dir}/sdl2-compat-${SDL2COMPAT_VERSION}"
sdl3_source="${unpack_dir}/SDL3-${SDL3_HEADERS_VERSION}"
if [[ ! -f "${sdl2_source}/CMakeLists.txt" ||
      ! -f "${sdl2_source}/LICENSE.txt" ||
      ! -f "${sdl3_source}/include/SDL3/SDL.h" ||
      ! -f "${sdl3_source}/CMakeLists.txt" ||
      ! -f "${sdl3_source}/LICENSE.txt" ]]; then
    print -u2 "Verified archives do not contain the expected source layout."
    exit 1
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

# Build the actual SDL3 runtime first. Disable package-manager discovery for
# optional dependencies so a Homebrew installation cannot change the output.
sdl3_build_dir="${temp_dir}/build-sdl3"
cmake -S "${sdl3_source}" -B "${sdl3_build_dir}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${SDL2COMPAT_DEPLOYMENT_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${sdk_path}" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TEST_LIBRARY=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL=OFF \
    -DSDL_UNINSTALL=OFF \
    -DSDL_HIDAPI_LIBUSB=OFF \
    -DSDL_VULKAN=OFF \
    -DSDL_CCACHE=OFF

sdl3_cache_file="${sdl3_build_dir}/CMakeCache.txt"
typeset -a required_sdl3_cache_entries
required_sdl3_cache_entries=(
    "CMAKE_OSX_ARCHITECTURES:STRING=arm64"
    "CMAKE_OSX_DEPLOYMENT_TARGET:UNINITIALIZED=${SDL2COMPAT_DEPLOYMENT_TARGET}"
    "CMAKE_DISABLE_FIND_PACKAGE_PkgConfig:UNINITIALIZED=TRUE"
    "SDL_SHARED:BOOL=ON"
    "SDL_STATIC:BOOL=OFF"
    "SDL_TEST_LIBRARY:BOOL=OFF"
    "SDL_TESTS:INTERNAL=OFF"
    "SDL_EXAMPLES:BOOL=OFF"
    "SDL_INSTALL:BOOL=OFF"
    "SDL_UNINSTALL:BOOL=OFF"
    "SDL_HIDAPI_LIBUSB:BOOL=OFF"
    "SDL_VULKAN:BOOL=OFF"
    "SDL_CCACHE:BOOL=OFF"
)
sdl3_cache_contract_ok=1
for required_cache_entry in "${required_sdl3_cache_entries[@]}"; do
    if ! grep -Fqx -- "${required_cache_entry}" "${sdl3_cache_file}"; then
        print -u2 "Missing SDL3 CMake cache contract: ${required_cache_entry}"
        sdl3_cache_contract_ok=0
    fi
done
if (( sdl3_cache_contract_ok != 1 )); then
    print -u2 "CMake did not preserve the pinned SDL3 runtime contract."
    exit 1
fi

cmake --build "${sdl3_build_dir}" --target SDL3-shared --parallel "${build_jobs}"
built_sdl3_dylib="${sdl3_build_dir}/${SDL3_BUILD_DYLIB}"

# Build sdl2-compat only against the just-verified source tree's SDL3 headers.
sdl2_build_dir="${temp_dir}/build-sdl2"
cmake -S "${sdl2_source}" -B "${sdl2_build_dir}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${SDL2COMPAT_DEPLOYMENT_TARGET}" \
    -DCMAKE_OSX_SYSROOT="${sdk_path}" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_DISABLE_FIND_PACKAGE_SDL3=TRUE \
    -DSDL3_INCLUDE_DIRS="${sdl3_source}/include" \
    -DSDL2COMPAT_TESTS=OFF \
    -DSDL2COMPAT_INSTALL=OFF \
    -DSDL2COMPAT_STATIC=OFF

sdl2_cache_file="${sdl2_build_dir}/CMakeCache.txt"
typeset -a required_cache_entries
required_cache_entries=(
    "CMAKE_OSX_ARCHITECTURES:STRING=arm64"
    "CMAKE_OSX_DEPLOYMENT_TARGET:UNINITIALIZED=${SDL2COMPAT_DEPLOYMENT_TARGET}"
    "CMAKE_DISABLE_FIND_PACKAGE_SDL3:UNINITIALIZED=TRUE"
    "SDL3_INCLUDE_DIRS:PATH=${sdl3_source}/include"
    "SDL2COMPAT_TESTS:BOOL=OFF"
    "SDL2COMPAT_INSTALL:BOOL=OFF"
    "SDL2COMPAT_STATIC:BOOL=OFF"
)
cache_contract_ok=1
for required_cache_entry in "${required_cache_entries[@]}"; do
    if ! grep -Fqx -- "${required_cache_entry}" "${sdl2_cache_file}"; then
        print -u2 "Missing CMake cache contract: ${required_cache_entry}"
        cache_contract_ok=0
    fi
done
if (( cache_contract_ok != 1 )); then
    print -u2 "CMake did not preserve the pinned SDL build contract."
    grep -E '^(CMAKE_OSX_ARCHITECTURES|CMAKE_OSX_DEPLOYMENT_TARGET|CMAKE_DISABLE_FIND_PACKAGE_SDL3|SDL3_INCLUDE_DIRS|SDL2COMPAT_TESTS|SDL2COMPAT_INSTALL|SDL2COMPAT_STATIC):' \
        "${sdl2_cache_file}" >&2 || true
    exit 1
fi

cmake --build "${sdl2_build_dir}" --target SDL2 --parallel "${build_jobs}"
built_sdl2_dylib="${sdl2_build_dir}/${SDL2COMPAT_DYLIB}"

validate_dylib() {
    local dylib_path="$1"
    local label="$2"
    local expected_install_name="$3"
    local architectures install_name minimum_os dependency_leaks

    if [[ ! -f "${dylib_path}" ]]; then
        print -u2 "Expected ${label} dylib is missing: ${dylib_path}"
        return 1
    fi
    if [[ "$(file -b "${dylib_path}")" != 'Mach-O 64-bit dynamically linked shared library arm64' ]]; then
        print -u2 "${label} output is not an arm64 Mach-O dylib."
        return 1
    fi
    architectures="$(lipo -archs "${dylib_path}")"
    if [[ "${architectures}" != arm64 ]]; then
        print -u2 "${label} output contains unexpected architectures: ${architectures}"
        return 1
    fi
    install_name="$(otool -D "${dylib_path}" | sed -n '2p')"
    if [[ "${install_name}" != "${expected_install_name}" ]]; then
        print -u2 "Unexpected ${label} install name: ${install_name}"
        return 1
    fi
    minimum_os="$(otool -l "${dylib_path}" | awk '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build_version = 1; next }
        in_build_version && $1 == "minos" { print $2; exit }
    ')"
    if [[ "${minimum_os}" != "${SDL2COMPAT_DEPLOYMENT_TARGET}" ]]; then
        print -u2 "Unexpected ${label} deployment target: ${minimum_os}"
        return 1
    fi
    dependency_leaks="$(otool -L "${dylib_path}" | awk '
        NR > 1 && ($1 ~ /^\/opt\/homebrew\// ||
                   $1 ~ /^\/usr\/local\// ||
                   $1 ~ /^\/Users\// ||
                   $1 ~ /^\/private\/tmp\// ||
                   $1 ~ /^\/tmp\//) { print $1 }
    ')"
    if [[ -n "${dependency_leaks}" ]]; then
        print -u2 "${label} output has build-machine dependencies:"
        print -u2 -- "${dependency_leaks}"
        return 1
    fi
}

validate_dylib "${built_sdl2_dylib}" "SDL2 compatibility" "${SDL2COMPAT_INSTALL_NAME}"
validate_dylib "${built_sdl3_dylib}" "SDL3 runtime" "${SDL3_INSTALL_NAME}"

mkdir -p -- "${sdl2_destination}" "${sdl3_destination}"
staged_sdl2_dylib="${sdl2_destination}/.${SDL2COMPAT_DYLIB}.new.$$"
staged_sdl2_license="${sdl2_destination}/.LICENSE.txt.new.$$"
staged_sdl3_dylib="${sdl3_destination}/.${SDL3_RUNTIME_DYLIB}.new.$$"
staged_sdl3_license="${sdl3_destination}/.LICENSE.txt.new.$$"
install -m 755 "${built_sdl2_dylib}" "${staged_sdl2_dylib}"
install -m 644 "${sdl2_source}/LICENSE.txt" "${staged_sdl2_license}"
install -m 755 "${built_sdl3_dylib}" "${staged_sdl3_dylib}"
install -m 644 "${sdl3_source}/LICENSE.txt" "${staged_sdl3_license}"
validate_dylib "${staged_sdl2_dylib}" "staged SDL2 compatibility" "${SDL2COMPAT_INSTALL_NAME}"
validate_dylib "${staged_sdl3_dylib}" "staged SDL3 runtime" "${SDL3_INSTALL_NAME}"
cmp "${sdl2_source}/LICENSE.txt" "${staged_sdl2_license}"
cmp "${sdl3_source}/LICENSE.txt" "${staged_sdl3_license}"

mv -f -- "${staged_sdl2_dylib}" "${sdl2_destination}/${SDL2COMPAT_DYLIB}"
staged_sdl2_dylib=""
mv -f -- "${staged_sdl2_license}" "${sdl2_destination}/LICENSE.txt"
staged_sdl2_license=""
mv -f -- "${staged_sdl3_dylib}" "${sdl3_destination}/${SDL3_RUNTIME_DYLIB}"
staged_sdl3_dylib=""
mv -f -- "${staged_sdl3_license}" "${sdl3_destination}/LICENSE.txt"
staged_sdl3_license=""

sdl2_artifact_sha="$(shasum -a 256 "${sdl2_destination}/${SDL2COMPAT_DYLIB}" | awk '{ print $1 }')"
sdl3_artifact_sha="$(shasum -a 256 "${sdl3_destination}/${SDL3_RUNTIME_DYLIB}" | awk '{ print $1 }')"
print "Installed verified SDL runtime artifacts:"
print "  ${sdl2_destination}/${SDL2COMPAT_DYLIB}"
print "  SHA-256: ${sdl2_artifact_sha}"
print "  ${sdl3_destination}/${SDL3_RUNTIME_DYLIB}"
print "  SHA-256: ${sdl3_artifact_sha}"
print "  architecture: arm64; deployment target: ${SDL2COMPAT_DEPLOYMENT_TARGET}"
