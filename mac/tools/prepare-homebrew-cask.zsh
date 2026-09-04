#!/bin/zsh
set -euo pipefail

export LC_ALL=C

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
template="${repo_dir}/mac/homebrew/Casks/jgalbs-cod4.rb.in"
dmg_path="${repo_dir}/dist/cod4-macos-arm64.dmg"
repository='JGalbss/cod4-macos'
release_tag=''
force=0
work_dir=''
mount_dir=''
mounted=0

usage() {
    cat <<'EOF'
usage: prepare-homebrew-cask.zsh --tag TAG [options]

Generate a Homebrew cask from an already signed, notarized, and stapled DMG.
This command validates and prepares local tap files; it never uploads or publishes.

Options:
  --tag TAG            Release tag matching v<CFBundleShortVersionString>
  --repository O/R     GitHub repository (default: JGalbss/cod4-macos)
  --dmg PATH           Release DMG (default: dist/cod4-macos-arm64.dmg)
  --force              Replace an existing generated cask
  --help               Show this help
EOF
}

fail() {
    print -u2 -- "prepare-homebrew-cask: $*"
    exit 1
}

cleanup() {
    if (( mounted )) && [[ -n "${mount_dir}" && -d "${mount_dir}" ]]; then
        if ! /usr/bin/hdiutil detach -quiet "${mount_dir}" >/dev/null 2>&1; then
            if /sbin/mount | /usr/bin/grep -F " on ${mount_dir} (" >/dev/null; then
                print -u2 -- "Could not detach ${mount_dir}; preserving its temporary directory."
                work_dir=''
            fi
        fi
    fi
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        /bin/rm -rf -- "${work_dir}"
    fi
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
    case "$1" in
        (--tag)
            (( $# >= 2 )) || fail '--tag requires a value'
            release_tag="$2"
            shift 2
            ;;
        (--repository)
            (( $# >= 2 )) || fail '--repository requires OWNER/REPOSITORY'
            repository="$2"
            shift 2
            ;;
        (--dmg)
            (( $# >= 2 )) || fail '--dmg requires a path'
            dmg_path="$2"
            shift 2
            ;;
        (--force)
            force=1
            shift
            ;;
        (--help|-h)
            usage
            exit 0
            ;;
        (*)
            fail "unknown option: $1"
            ;;
    esac
done

[[ -n "${release_tag}" ]] || fail '--tag is required'
[[ "${release_tag}" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]] || fail 'tag must look like v1.2.3'
[[ "${repository}" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || fail 'repository must be OWNER/REPOSITORY'
[[ -f "${template}" ]] || fail "cask template is missing: ${template}"
[[ -f "${dmg_path}" ]] || fail "DMG is missing: ${dmg_path}"
dmg_path="${dmg_path:A}"
checksum_file="${dmg_path}.sha256"
[[ -f "${checksum_file}" ]] || fail "checksum file is missing: ${checksum_file}"

expected_checksum="$(/usr/bin/awk 'NR == 1 { print $1 }' "${checksum_file}")"
[[ "${expected_checksum}" =~ '^[0-9a-fA-F]{64}$' ]] || fail 'checksum file does not begin with a SHA-256 value'
actual_checksum="$(/usr/bin/shasum -a 256 "${dmg_path}" | /usr/bin/awk '{ print $1 }')"
[[ "${actual_checksum}" == "${expected_checksum:l}" ]] || fail 'DMG checksum does not match its .sha256 file'

/usr/bin/hdiutil verify "${dmg_path}" >/dev/null || fail 'DMG verification failed'
/usr/bin/xcrun stapler validate "${dmg_path}" >/dev/null 2>&1 || fail 'DMG is not notarized and stapled; unsigned/ad-hoc artifacts cannot become a cask'
/usr/sbin/spctl --assess --type open --context context:primary-signature "${dmg_path}" >/dev/null 2>&1 || fail 'Gatekeeper rejected the DMG'
if /usr/bin/hdiutil info | /usr/bin/grep -F "${dmg_path}" >/dev/null; then
    fail 'DMG is already attached; detach its existing volume before preparing the cask'
fi

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jgalbs-cod4-cask.XXXXXX")"
mount_dir="${work_dir}/mounted"
/bin/mkdir "${mount_dir}"
mounted=1
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "${mount_dir}" "${dmg_path}"

app="${mount_dir}/jgalbs cod4.app"
plist="${app}/Contents/Info.plist"
[[ -d "${app}" && -f "${plist}" ]] || fail 'DMG does not contain jgalbs cod4.app at its root'

display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${plist}" 2>/dev/null)" || fail 'bundle display name is missing'
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}" 2>/dev/null)" || fail 'bundle executable is missing'
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null)" || fail 'bundle identifier is missing'
minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${plist}" 2>/dev/null)" || fail 'minimum macOS version is missing'
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null)" || fail 'bundle version is missing'
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2>/dev/null)" || fail 'bundle build number is missing'

[[ "${display_name}" == 'jgalbs cod4' ]] || fail 'unexpected bundle display name'
[[ "${executable}" == 'jgalbs cod4' ]] || fail 'unexpected bundle executable name'
[[ "${identifier}" == 'com.joshgalbreath.jgalbs-cod4' ]] || fail 'unexpected bundle identifier'
[[ "${minimum_version}" == '15.5' ]] || fail 'unexpected minimum macOS version'
[[ "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]] || fail 'bundle version is not a supported release version'
[[ "${build}" =~ '^[0-9]+$' ]] || fail 'bundle build number must be numeric'
[[ "${release_tag}" == "v${version}" ]] || fail "tag ${release_tag} does not match bundle version ${version}"
[[ -x "${app}/Contents/MacOS/${executable}" ]] || fail 'bundle executable is missing or not executable'

architectures="$(/usr/bin/lipo -archs "${app}/Contents/MacOS/${executable}" 2>/dev/null)" || fail 'could not inspect executable architectures'
[[ " ${architectures} " == *' arm64 '* ]] || fail 'bundle executable does not contain arm64'
/usr/bin/codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail 'bundle code-signature verification failed'
"${repo_dir}/mac/updater/verify_updater_bundle.zsh" "${app}" >/dev/null \
    || fail 'bundle updater integration failed validation'

signature_info="$(/usr/bin/codesign -dvvv "${app}" 2>&1)" || fail 'could not inspect the app signature'
[[ "${signature_info}" == *$'Authority=Developer ID Application:'* ]] || fail 'app is not signed by a Developer ID Application identity'
[[ "${signature_info}" == *$'TeamIdentifier='* && "${signature_info}" != *$'TeamIdentifier=not set'* ]] || fail 'app signature has no Apple team identifier'
[[ "${signature_info}" == *'flags='*'(runtime)'* ]] || fail 'app signature does not enable the hardened runtime'
/usr/sbin/spctl --assess --type execute "${app}" >/dev/null 2>&1 || fail 'Gatekeeper rejected the app'

for notice in GPL-3.0.txt NOTICE.txt THIRD-PARTY-NOTICES.txt SOURCE-NOTICE.txt; do
    [[ -s "${app}/Contents/Resources/${notice}" ]] || fail "bundle is missing required notice: ${notice}"
done
source_notice="${app}/Contents/Resources/SOURCE-NOTICE.txt"
/usr/bin/grep -Fq "https://github.com/${repository}/tree/" "${source_notice}" || \
    fail 'source notice does not identify an exact revision in the release repository'

/usr/bin/hdiutil detach -quiet "${mount_dir}"
mounted=0

output_dir="${repo_dir}/dist/homebrew/Casks"
output="${output_dir}/jgalbs-cod4.rb"
if [[ -e "${output}" && ${force} -eq 0 ]]; then
    fail "generated cask already exists; use --force to replace it: ${output}"
fi
/bin/mkdir -p "${output_dir}"
staged_output="${work_dir}/jgalbs-cod4.rb"
/usr/bin/sed \
    -e "s|__VERSION__|${version}|g" \
    -e "s|__BUILD__|${build}|g" \
    -e "s|__SHA256__|${actual_checksum}|g" \
    -e "s|__REPOSITORY__|${repository}|g" \
    -e "s|__TAG__|${release_tag}|g" \
    "${template}" >"${staged_output}"
/usr/bin/ruby -c "${staged_output}" >/dev/null || fail 'generated cask failed Ruby syntax validation'
/bin/mv -f "${staged_output}" "${output}"

print "Prepared cask: ${output}"
print 'Preparation complete; no release, tap, or binary was published.'
