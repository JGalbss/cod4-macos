#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    print -u2 "usage: $0 '/absolute/path/to/jgalbs cod4.app' [Sparkle installation directory]"
    exit 64
fi

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
app_path="${1:A}"
sparkle_root="${2:-${repo_dir}/mac/vendor/Sparkle}"
source_framework="${sparkle_root}/Sparkle.framework"
target_framework="${app_path}/Contents/Frameworks/Sparkle.framework"

if [[ "${app_path}" != *.app || ! -d "${app_path}/Contents/MacOS" ]]; then
    print -u2 "Not an application bundle: ${app_path}"
    exit 1
fi
if [[ ! -x "${source_framework}/Versions/B/Sparkle" ]]; then
    print -u2 "Sparkle.framework is missing. Run mac/updater/fetch_sparkle.zsh first."
    exit 1
fi

mkdir -p "${app_path}/Contents/Frameworks"
rm -rf -- "${target_framework}"
# ditto preserves the framework's versioned symlink structure and executable
# modes; ordinary recursive copies can invalidate Sparkle's code signature.
ditto "${source_framework}" "${target_framework}"
if [[ -f "${sparkle_root}/LICENSE.txt" ]]; then
    mkdir -p "${app_path}/Contents/Resources"
    cp "${sparkle_root}/LICENSE.txt" \
        "${app_path}/Contents/Resources/Sparkle-LICENSE.txt"
fi
codesign --verify --deep --strict --verbose=2 "${target_framework}"

print "Staged ${target_framework}"
