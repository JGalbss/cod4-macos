#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
sparkle_root="${SPARKLE_ROOT:-${repo_dir}/mac/vendor/Sparkle}"
generate_appcast="${sparkle_root}/bin/generate_appcast"
sign_update="${sparkle_root}/bin/sign_update"
dmg_path="${RELEASE_DMG:-${repo_dir}/dist/cod4-macos-arm64.dmg}"
updates_dir="${UPDATES_DIR:-${repo_dir}/dist/updates}"
github_repository="${GITHUB_REPOSITORY:-JGalbss/cod4-macos}"
release_tag="${RELEASE_TAG:-}"
release_assets_dir="${RELEASE_ASSETS_DIR:-${repo_dir}/dist/release/${release_tag}}"
release_notes="${RELEASE_NOTES:-}"
key_account="${SPARKLE_KEY_ACCOUNT:-jgalbs-cod4}"
key_file="${SPARKLE_ED_KEY_FILE:-}"
release_source_sha="${RELEASE_SOURCE_SHA:-}"

if [[ -z "${github_repository}" || "${github_repository}" != */* ]]; then
    print -u2 "Set GITHUB_REPOSITORY to the public OWNER/REPOSITORY hosting releases."
    exit 64
fi
if [[ -z "${release_tag}" || "${release_tag}" == */* ]]; then
    print -u2 "Set RELEASE_TAG to the GitHub release tag, for example v0.2.0."
    exit 64
fi
if [[ ! "${release_source_sha}" =~ '^[0-9a-fA-F]{40}$' ]]; then
    print -u2 "Set RELEASE_SOURCE_SHA to the exact 40-character public source commit."
    exit 64
fi
if ! command -v gh >/dev/null; then
    print -u2 "GitHub CLI (gh) is required to verify the public source commit."
    exit 1
fi
if ! gh api "repos/${github_repository}/commits/${release_source_sha}" \
    --jq .sha 2>/dev/null | grep -Fxiq "${release_source_sha}"; then
    print -u2 "RELEASE_SOURCE_SHA is not reachable in ${github_repository}."
    exit 1
fi
if [[ ! -x "${generate_appcast}" || ! -x "${sign_update}" ]]; then
    print -u2 "Sparkle release tools are missing. Run mac/updater/fetch_sparkle.zsh."
    exit 1
fi
if [[ ! -f "${dmg_path}" ]]; then
    print -u2 "Release DMG is missing: ${dmg_path}"
    exit 1
fi
if ! hdiutil verify "${dmg_path}" >/dev/null; then
    print -u2 "Release DMG failed hdiutil verification."
    exit 1
fi
if ! xcrun stapler validate "${dmg_path}" >/dev/null 2>&1; then
    print -u2 "Release DMG is not notarized and stapled."
    exit 1
fi
if ! spctl --assess --type open --context context:primary-signature \
    "${dmg_path}" >/dev/null 2>&1; then
    print -u2 "Gatekeeper rejected the release DMG."
    exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/jgalbs-cod4-update-release.XXXXXX")"
mount_dir="${temp_dir}/mount"
mounted=0
release_complete=0
transaction_dir=''
previous_updates=''
had_previous_updates=0
updates_installed=0
release_assets_installed=0
update_lock=''
lock_acquired=0
cleanup() {
    if (( mounted )); then
        hdiutil detach "${mount_dir}" -quiet || true
    fi
    if (( ! release_complete )) && [[ -n "${transaction_dir}" ]]; then
        if (( release_assets_installed )) && [[ -d "${release_assets_dir}" ]]; then
            mv "${release_assets_dir}" "${transaction_dir}/failed-release-assets" || true
        fi
        if (( updates_installed )) && [[ -d "${updates_dir}" ]]; then
            mv "${updates_dir}" "${transaction_dir}/failed-updates" || true
        fi
        if (( had_previous_updates )) && [[ -d "${previous_updates}" && ! -e "${updates_dir}" ]]; then
            mv "${previous_updates}" "${updates_dir}" || true
        fi
    fi
    [[ -z "${transaction_dir}" || ! -d "${transaction_dir}" ]] \
        || rm -rf -- "${transaction_dir}"
    (( ! lock_acquired )) || rmdir "${update_lock}" 2>/dev/null || true
    rm -rf -- "${temp_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "${mount_dir}"
hdiutil attach -readonly -nobrowse -mountpoint "${mount_dir}" "${dmg_path}" -quiet
mounted=1
app_path="${mount_dir}/jgalbs cod4.app"
info_plist="${app_path}/Contents/Info.plist"
if [[ ! -f "${info_plist}" ]]; then
    print -u2 "DMG does not contain jgalbs cod4.app/Contents/Info.plist."
    exit 1
fi

short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}")"
configured_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${info_plist}")"
expected_feed="https://github.com/${github_repository}/releases/latest/download/appcast.xml"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${info_plist}")"
require_signed_feed="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "${info_plist}")"
verify_before_extract="$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "${info_plist}")"
automatic_checks="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "${info_plist}")"
source_notice="${app_path}/Contents/Resources/SOURCE-NOTICE.txt"

if [[ "${configured_feed}" != "${expected_feed}" ]]; then
    print -u2 "SUFeedURL must equal ${expected_feed}"
    exit 1
fi
if [[ "${release_tag}" != "v${short_version}" ]]; then
    print -u2 "RELEASE_TAG ${release_tag} does not match bundle version ${short_version}."
    exit 1
fi
if [[ "${public_key}" == REPLACE_* || -z "${public_key}" ]]; then
    print -u2 "SUPublicEDKey is still a placeholder."
    exit 1
fi
decoded_key="${temp_dir}/public-key"
if ! print -rn -- "${public_key}" | base64 -D >"${decoded_key}" 2>/dev/null \
    || [[ "$(stat -f %z "${decoded_key}")" != 32 ]]; then
    print -u2 "SUPublicEDKey must be a base64-encoded 32-byte Ed25519 key."
    exit 1
fi
if [[ "${require_signed_feed}" != true || "${verify_before_extract}" != true \
    || "${automatic_checks}" != true ]]; then
    print -u2 "Signed-feed, pre-extraction verification, and automatic checks must be enabled."
    exit 1
fi
expected_source_url="https://github.com/${github_repository}/tree/${release_source_sha:l}"
if [[ ! -s "${source_notice}" ]] \
    || ! grep -Fxiq "${expected_source_url}" "${source_notice}"; then
    print -u2 "SOURCE-NOTICE.txt does not identify the exact public release source."
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${app_path}"
signature_info="$(codesign -dvvv "${app_path}" 2>&1)"
if [[ "${signature_info}" != *$'Authority=Developer ID Application:'* \
    || "${signature_info}" == *$'TeamIdentifier=not set'* \
    || "${signature_info}" != *'(runtime)'* ]]; then
    print -u2 "Application must have a Developer ID signature, team identifier, and hardened runtime."
    exit 1
fi
if ! spctl --assess --type execute "${app_path}" >/dev/null 2>&1; then
    print -u2 "Gatekeeper rejected the application inside the DMG."
    exit 1
fi
if ! otool -L "${app_path}/Contents/MacOS/jgalbs cod4" \
    | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    print -u2 "jgalbs cod4 does not link the embedded Sparkle.framework."
    exit 1
fi
if [[ ! -d "${app_path}/Contents/Frameworks/Sparkle.framework" ]]; then
    print -u2 "Sparkle.framework is not embedded in jgalbs cod4.app."
    exit 1
fi

hdiutil detach "${mount_dir}" -quiet
mounted=0

updates_parent="${updates_dir:h}"
mkdir -p "${updates_parent}"
update_lock="${updates_parent}/.jgalbs-cod4-update.lock"
if ! mkdir "${update_lock}" 2>/dev/null; then
    print -u2 "Another update preparation is active: ${update_lock}"
    exit 1
fi
lock_acquired=1
transaction_dir="$(mktemp -d "${updates_parent}/.jgalbs-cod4-update.XXXXXX")"
staged_updates="${transaction_dir}/updates"
staged_release_assets="${transaction_dir}/release-assets"
mkdir -p "${staged_updates}" "${staged_release_assets}"

archive_name="cod4-macos-arm64-${short_version}-${build_version}.dmg"
staged_archive="${staged_updates}/${archive_name}"
archive_path="${updates_dir}/${archive_name}"
staged_generic="${staged_release_assets}/cod4-macos-arm64.dmg"
generic_archive="${release_assets_dir}/cod4-macos-arm64.dmg"
if [[ -e "${staged_archive}" ]]; then
    print -u2 "Refusing to overwrite an existing release archive: ${archive_path}"
    exit 1
fi
if [[ -e "${release_assets_dir}" ]]; then
    print -u2 "Refusing to overwrite existing release assets: ${release_assets_dir}"
    exit 1
fi
cp "${dmg_path}" "${staged_archive}"
archive_checksum="$(shasum -a 256 "${staged_archive}" | awk '{ print $1 }')"
print -r -- "${archive_checksum}  ${archive_name}" >"${staged_archive}.sha256"
cp "${dmg_path}" "${staged_generic}"
print -r -- "${archive_checksum}  cod4-macos-arm64.dmg" >"${staged_generic}.sha256"

release_notes_name=''
if [[ -n "${release_notes}" ]]; then
    if [[ ! -f "${release_notes}" ]]; then
        print -u2 "Release notes file is missing: ${release_notes}"
        exit 1
    fi
    release_notes_name="${archive_name:r}.md"
    if [[ -e "${staged_updates}/${release_notes_name}" ]]; then
        print -u2 "Refusing to overwrite existing release notes: ${release_notes_name}"
        exit 1
    fi
    cp "${release_notes}" "${staged_updates}/${release_notes_name}"
fi

key_args=(--account "${key_account}")
if [[ -n "${key_file}" ]]; then
    if [[ "${key_file}" == - ]]; then
        # Both generation and verification need the key. Cache piped input once
        # in the already protected temporary directory instead of letting the
        # first tool consume stdin and leave EOF for the second.
        key_file="${temp_dir}/sparkle-private-key"
        (umask 077; cat >"${key_file}")
    fi
    key_args=(--ed-key-file "${key_file}")
fi

generate_log="${temp_dir}/generate-appcast.log"
appcast="${staged_updates}/appcast.xml"
if ! "${generate_appcast}" \
    "${key_args[@]}" \
    --download-url-prefix "https://github.com/${github_repository}/releases/download/${release_tag}/" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "${appcast}" \
    "${staged_updates}" 2>&1 | tee "${generate_log}"; then
    print -u2 "Sparkle failed to generate the appcast."
    exit 1
fi
if grep -q 'SUPublicEDKey.*does not match' "${generate_log}"; then
    print -u2 "The application public key does not match the selected signing key."
    exit 1
fi

xmllint --noout "${appcast}"
if ! "${sign_update}" --verify "${key_args[@]}" "${appcast}"; then
    print -u2 "Generated appcast signature verification failed."
    exit 1
fi
if ! grep -Fq "https://github.com/${github_repository}/releases/download/${release_tag}/${archive_name}" \
    "${appcast}"; then
    print -u2 "Generated appcast does not point at the intended GitHub Release asset."
    exit 1
fi

manifest_name="publish-${release_tag}.txt"
manifest="${updates_dir}/${manifest_name}"
staged_manifest="${staged_updates}/${manifest_name}"
{
    print -r -- "${archive_path}"
    print -r -- "${archive_path}.sha256"
    print -r -- "${generic_archive}"
    print -r -- "${generic_archive}.sha256"
    [[ -n "${release_notes_name}" ]] \
        && print -r -- "${updates_dir}/${release_notes_name}"
    # The production feed intentionally contains one full latest update. GitHub
    # keeps immutable older releases; any older app can jump to this archive.
    xmllint --format "${appcast}" \
        | sed -nE 's/.*url="([^"]+)".*/\1/p' \
        | grep -F "https://github.com/${github_repository}/releases/download/${release_tag}/" \
        | while IFS= read -r enclosure_url; do
            enclosure_name="${enclosure_url:t}"
            if [[ ! -f "${staged_updates}/${enclosure_name}" ]]; then
                print -u2 "Appcast references a missing release asset: ${enclosure_name}"
                exit 1
            fi
            print -r -- "${updates_dir}/${enclosure_name}"
        done
    print -r -- "${updates_dir}/appcast.xml"
} | awk '!seen[$0]++' >"${staged_manifest}"

# Commit the fully validated history and current generic assets with directory
# renames on the destination filesystem. The EXIT trap restores the prior
# history if either install step fails. Mask termination across each atomic
# rename plus its state update so the signal handlers can never observe a move
# that completed before the matching rollback flag was recorded.
trap '' INT TERM HUP
previous_updates="${transaction_dir}/previous-updates"
if [[ -d "${updates_dir}" ]]; then
    mv "${updates_dir}" "${previous_updates}"
    had_previous_updates=1
fi
mv "${staged_updates}" "${updates_dir}"
updates_installed=1
mkdir -p "${release_assets_dir:h}"
mv "${staged_release_assets}" "${release_assets_dir}"
release_assets_installed=1
release_complete=1
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

print "Prepared signed Sparkle release ${short_version} (${build_version})."
print "Publish manifest: ${manifest}"
print "Upload every manifest entry to GitHub release ${release_tag}; upload appcast.xml last."
