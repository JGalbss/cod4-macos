#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 "usage: $0 /absolute/path/to/Sparkle.framework 'Developer ID Application: ...'"
    exit 64
fi

framework="${1:A}"
identity="$2"
version_dir="${framework}/Versions/B"

if [[ ! -x "${version_dir}/Sparkle" ]]; then
    print -u2 "Not a Sparkle 2 framework: ${framework}"
    exit 1
fi

# The official distribution is already ad-hoc signed for local development.
# Preserve those valid signatures instead of needlessly rewriting every nested
# helper with another ad-hoc identity.
if [[ "${identity}" == - ]]; then
    codesign --verify --deep --strict --verbose=2 "${framework}"
    print "Kept Sparkle's official ad-hoc development signatures."
    exit 0
fi

sign_args=(--force --sign "${identity}" --options runtime --timestamp)
codesign "${sign_args[@]}" "${version_dir}/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements \
    "${version_dir}/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "${version_dir}/Autoupdate"
codesign "${sign_args[@]}" "${version_dir}/Updater.app"
codesign "${sign_args[@]}" "${framework}"

codesign --verify --deep --strict --verbose=2 "${framework}"
print "Re-signed Sparkle and its nested helpers with ${identity}"
