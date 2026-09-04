#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 '/absolute/path/to/jgalbs cod4.app'"
    exit 64
fi

app_path="${1:A}"
info_plist="${app_path}/Contents/Info.plist"
executable="${app_path}/Contents/MacOS/jgalbs cod4"
framework="${app_path}/Contents/Frameworks/Sparkle.framework"

if [[ "${app_path}" != *.app || ! -x "${executable}" || ! -f "${info_plist}" ]]; then
    print -u2 "Not a packaged jgalbs cod4 application: ${app_path}"
    exit 1
fi

feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${info_plist}")"
key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${info_plist}")"
[[ "${feed}" == https://* ]] || { print -u2 "SUFeedURL is not HTTPS."; exit 1; }
[[ "${feed}" != *OWNER* && "${feed}" != *REPOSITORY* ]] \
    || { print -u2 "SUFeedURL is still a placeholder."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "${info_plist}")" == true ]] \
    || { print -u2 "SURequireSignedFeed is not enabled."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "${info_plist}")" == true ]] \
    || { print -u2 "SUVerifyUpdateBeforeExtraction is not enabled."; exit 1; }

temp_key="$(mktemp "${TMPDIR:-/tmp}/jgalbs-cod4-public-key.XXXXXX")"
trap 'rm -f -- "${temp_key}"' EXIT
if ! print -rn -- "${key}" | base64 -D >"${temp_key}" 2>/dev/null \
    || [[ "$(stat -f %z "${temp_key}")" != 32 ]]; then
    print -u2 "SUPublicEDKey is invalid."
    exit 1
fi

[[ -x "${framework}/Versions/B/Sparkle" ]] \
    || { print -u2 "Sparkle.framework is not embedded."; exit 1; }
otool -L "${executable}" | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || { print -u2 "jgalbs cod4 does not link Sparkle through @rpath."; exit 1; }
codesign --verify --deep --strict --verbose=2 "${app_path}"

print "Updater bundle checks passed."
print "Feed: ${feed}"
print "Bundle version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")"
