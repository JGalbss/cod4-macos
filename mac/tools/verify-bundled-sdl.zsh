#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 '/absolute/path/to/jgalbs cod4.app'"
    exit 1
fi

script_dir="${0:A:h}"
# dyld reports canonical paths (for example, /private/var/... rather than the
# /var/... symlink spelling returned by TMPDIR), so canonicalize before
# comparing the runtime trace with the expected app-local SDL3 path.
app_path="${1:A}"
probe_source="${script_dir}/sdl-runtime-probe.c"
sdl2_path="${app_path}/Contents/Frameworks/libSDL2-2.0.0.dylib"
sdl3_path="${app_path}/Contents/Frameworks/libSDL3.dylib"

if [[ ! -d "${app_path}" || ! -f "${probe_source}" ]]; then
    print -u2 "Application or SDL runtime probe source is missing."
    exit 1
fi

validate_runtime() {
    local label="$1"
    local dylib_path="$2"
    local expected_install_name="$3"
    local architectures install_name minimum_os dependency_leaks

    if [[ ! -f "${dylib_path}" ]]; then
        print -u2 "Bundled ${label} is missing: ${dylib_path}"
        return 1
    fi
    if [[ "$(file -b "${dylib_path}")" != 'Mach-O 64-bit dynamically linked shared library arm64' ]]; then
        print -u2 "Bundled ${label} is not an arm64 Mach-O dylib."
        return 1
    fi
    architectures="$(lipo -archs "${dylib_path}")"
    if [[ "${architectures}" != arm64 ]]; then
        print -u2 "Bundled ${label} contains unexpected architectures: ${architectures}"
        return 1
    fi
    install_name="$(otool -D "${dylib_path}" | sed -n '2p')"
    if [[ "${install_name}" != "${expected_install_name}" ]]; then
        print -u2 "Bundled ${label} has unexpected install name: ${install_name}"
        return 1
    fi
    minimum_os="$(otool -l "${dylib_path}" | awk '
        $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build_version = 1; next }
        in_build_version && $1 == "minos" { print $2; exit }
    ')"
    if [[ "${minimum_os}" != 15.5 ]]; then
        print -u2 "Bundled ${label} has unexpected deployment target: ${minimum_os}"
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
        print -u2 "Bundled ${label} has build-machine dependencies:"
        print -u2 -- "${dependency_leaks}"
        return 1
    fi
}

validate_runtime "SDL2 compatibility library" "${sdl2_path}" \
    '@rpath/libSDL2-2.0.0.dylib'
validate_runtime "SDL3 runtime" "${sdl3_path}" '@rpath/libSDL3.0.dylib'

temp_parent="${TMPDIR:-/tmp}"
temp_parent="${temp_parent%/}"
temp_dir="$(mktemp -d "${temp_parent}/cod4-macos-sdl-runtime-probe.XXXXXX")"
cleanup() {
    rm -rf -- "${temp_dir}"
}
trap cleanup EXIT

probe_binary="${temp_dir}/sdl-runtime-probe"
probe_log="${temp_dir}/dyld-libraries.log"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.5 -Os \
    "${probe_source}" -o "${probe_binary}"

set +e
DYLD_PRINT_LIBRARIES=1 "${probe_binary}" "${sdl2_path}" >"${probe_log}" 2>&1
probe_status=$?
set -e
if (( probe_status != 0 )); then
    print -u2 "Bundled SDL runtime probe failed:"
    cat "${probe_log}" >&2
    exit 1
fi
if ! grep -Fq -- "${sdl3_path}" "${probe_log}"; then
    print -u2 "SDL2 did not load the app-local SDL3 runtime."
    cat "${probe_log}" >&2
    exit 1
fi
if grep -Eq '/opt/homebrew/|/usr/local/' "${probe_log}"; then
    print -u2 "SDL runtime probe loaded a package-manager library:"
    cat "${probe_log}" >&2
    exit 1
fi

print "Bundled SDL2 -> app-local SDL3 runtime validation passed."
