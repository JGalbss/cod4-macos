#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    print -u2 "usage: $0 OWNER/REPOSITORY RELEASE_TAG [publish-TAG.txt]"
    exit 64
fi

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
github_repository="$1"
release_tag="$2"
manifest="${3:-${repo_dir}/dist/updates/publish-${release_tag}.txt}"
release_source_sha="${RELEASE_SOURCE_SHA:-}"

if [[ "${github_repository}" != */* || "${release_tag}" == */* ]]; then
    print -u2 "Invalid repository or release tag."
    exit 64
fi
if [[ ! -f "${manifest}" ]]; then
    print -u2 "Publish manifest is missing: ${manifest}"
    exit 1
fi
if ! command -v gh >/dev/null; then
    print -u2 "GitHub CLI (gh) is required."
    exit 1
fi
if [[ ! "${release_source_sha}" =~ '^[0-9a-fA-F]{40}$' ]]; then
    print -u2 "Set RELEASE_SOURCE_SHA to the exact public source commit."
    exit 64
fi
if ! gh api "repos/${github_repository}/commits/${release_source_sha}" \
    --jq .sha 2>/dev/null | grep -Fxiq "${release_source_sha}"; then
    print -u2 "RELEASE_SOURCE_SHA is not reachable in ${github_repository}."
    exit 1
fi

visibility="$(gh repo view "${github_repository}" --json visibility --jq .visibility)"
if [[ "${visibility}" != PUBLIC ]]; then
    print -u2 "The updater feed must be hosted in a public GitHub repository."
    exit 1
fi

typeset -a assets
typeset -a release_dmgs
appcast_asset=''
while IFS= read -r asset; do
    [[ -n "${asset}" ]] || continue
    if [[ ! -f "${asset}" ]]; then
        print -u2 "Manifest asset is missing: ${asset}"
        exit 1
    fi
    assets+=("${asset}")
    [[ "${asset:l}" == *.dmg ]] && release_dmgs+=("${asset}")
    [[ "${asset:t}" == appcast.xml ]] && appcast_asset="${asset}"
done <"${manifest}"

if (( ${#release_dmgs} < 2 )) || [[ -z "${appcast_asset}" ]]; then
    print -u2 "Manifest must contain the generic and versioned DMGs plus appcast.xml."
    exit 1
fi
has_generic_dmg=0
generic_dmg=''
release_dmg_checksum=''
for release_dmg in "${release_dmgs[@]}"; do
    if [[ "${release_dmg:t}" == cod4-macos-arm64.dmg ]]; then
        has_generic_dmg=1
        generic_dmg="${release_dmg}"
    fi
    checksum_path="${release_dmg}.sha256"
    [[ -f "${checksum_path}" ]] \
        || { print -u2 "Checksum sidecar is missing: ${checksum_path}"; exit 1; }
    /usr/bin/grep -Fxq "${checksum_path}" "${manifest}" \
        || { print -u2 "Manifest omits checksum sidecar: ${checksum_path}"; exit 1; }
    expected_checksum="$(/usr/bin/awk 'NR == 1 { print $1 }' "${checksum_path}")"
    actual_checksum="$(/usr/bin/shasum -a 256 "${release_dmg}" | /usr/bin/awk '{ print $1 }')"
    [[ "${expected_checksum:l}" == "${actual_checksum}" ]] \
        || { print -u2 "Checksum mismatch: ${release_dmg}"; exit 1; }
    if [[ -n "${release_dmg_checksum}" && "${release_dmg_checksum}" != "${actual_checksum}" ]]; then
        print -u2 "Generic and versioned release DMGs are not byte-identical."
        exit 1
    fi
    release_dmg_checksum="${actual_checksum}"
    /usr/bin/hdiutil verify "${release_dmg}" >/dev/null \
        || { print -u2 "Release DMG failed verification: ${release_dmg}"; exit 1; }
    /usr/bin/xcrun stapler validate "${release_dmg}" >/dev/null 2>&1 \
        || { print -u2 "Release DMG is not notarized and stapled: ${release_dmg}"; exit 1; }
    /usr/sbin/spctl --assess --type open --context context:primary-signature \
        "${release_dmg}" >/dev/null 2>&1 \
        || { print -u2 "Gatekeeper rejected the release DMG: ${release_dmg}"; exit 1; }
done
(( has_generic_dmg )) \
    || { print -u2 "Manifest is missing cod4-macos-arm64.dmg for Homebrew."; exit 1; }
if ! /usr/bin/grep -Fq "/releases/download/${release_tag}/" "${appcast_asset}"; then
    print -u2 "Appcast does not target release ${release_tag}."
    exit 1
fi

publish_temp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jgalbs-cod4-publish-audit.XXXXXX")"
publish_mount="${publish_temp}/mount"
publish_mounted=0
cleanup_publish_audit() {
    (( publish_mounted )) && /usr/bin/hdiutil detach -quiet "${publish_mount}" >/dev/null 2>&1 || true
    /bin/rm -rf -- "${publish_temp}"
}
trap cleanup_publish_audit EXIT
/bin/mkdir "${publish_mount}"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "${publish_mount}" \
    "${generic_dmg}" -quiet
publish_mounted=1
publish_app="${publish_mount}/jgalbs cod4.app"
publish_plist="${publish_app}/Contents/Info.plist"
publish_source_notice="${publish_app}/Contents/Resources/SOURCE-NOTICE.txt"
[[ -f "${publish_plist}" ]] \
    || { print -u2 "Release DMG does not contain jgalbs cod4.app."; exit 1; }
publish_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${publish_plist}")"
[[ "${release_tag}" == "v${publish_version}" ]] \
    || { print -u2 "Release tag does not match bundle version ${publish_version}."; exit 1; }
expected_source_url="https://github.com/${github_repository}/tree/${release_source_sha:l}"
[[ -s "${publish_source_notice}" ]] \
    && /usr/bin/grep -Fxiq "${expected_source_url}" "${publish_source_notice}" \
    || { print -u2 "Release app does not identify the exact public source commit."; exit 1; }
/usr/bin/codesign --verify --deep --strict "${publish_app}" >/dev/null 2>&1 \
    || { print -u2 "Release app signature failed verification."; exit 1; }
publish_signature="$(/usr/bin/codesign -dvvv "${publish_app}" 2>&1)"
[[ "${publish_signature}" == *$'Authority=Developer ID Application:'* \
    && "${publish_signature}" != *$'TeamIdentifier=not set'* \
    && "${publish_signature}" == *'(runtime)'* ]] \
    || { print -u2 "Release app lacks Developer ID, team, or hardened runtime."; exit 1; }
/usr/sbin/spctl --assess --type execute "${publish_app}" >/dev/null 2>&1 \
    || { print -u2 "Gatekeeper rejected the release app."; exit 1; }
/usr/bin/hdiutil detach -quiet "${publish_mount}"
publish_mounted=0

# Do not mutate GitHub until every local artifact has passed its release gates.
if gh release view "${release_tag}" --repo "${github_repository}" >/dev/null 2>&1; then
    is_draft="$(gh release view "${release_tag}" --repo "${github_repository}" \
        --json isDraft --jq .isDraft)"
    if [[ "${is_draft}" != true ]]; then
        print -u2 "Release ${release_tag} already exists and is not a draft; refusing partial publication."
        exit 1
    fi
else
    gh release create "${release_tag}" --repo "${github_repository}" \
        --draft --title "jgalbs cod4 ${release_tag}" --generate-notes
fi

# Keep the release draft until all authenticated artifacts and the signed feed
# are present. This prevents releases/latest from exposing a partial update.
gh release upload "${release_tag}" "${assets[@]}" \
    --repo "${github_repository}" --clobber

remote_assets="$(gh release view "${release_tag}" --repo "${github_repository}" \
    --json assets --jq '.assets[].name')"
for asset in "${assets[@]}"; do
    if ! grep -Fxq "${asset:t}" <<<"${remote_assets}"; then
        print -u2 "GitHub did not report uploaded asset ${asset:t}."
        exit 1
    fi
done

print "Draft release is complete and verified:"
gh release view "${release_tag}" --repo "${github_repository}" --json url --jq .url
print "Publish only after installing from the signed feed in a release-candidate test."
print "Command: gh release edit ${release_tag} --repo ${github_repository} --draft=false --latest"
