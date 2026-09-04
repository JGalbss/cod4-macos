#!/bin/zsh
set -euo pipefail

# Export the current working tree into a new, reviewable directory without
# copying Git history, retail game data, build products, downloaded vendor
# payloads, credentials, or other release-only material. This script never
# initializes a repository, commits, or pushes.

export LC_ALL=C
setopt NULL_GLOB

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"

if [[ ! -f "${repo_dir}/CMakeLists.txt" || ! -d "${repo_dir}/src" ]]; then
    print -u2 "Could not identify the project root from ${0}."
    exit 1
fi

if (( $# > 1 )); then
    print -u2 "usage: $0 [new-empty-staging-directory]"
    exit 1
fi

if (( $# == 1 )); then
    destination="$1"
    if [[ -e "${destination}" ]]; then
        if [[ ! -d "${destination}" ]]; then
            print -u2 "Destination exists and is not a directory: ${destination}"
            exit 1
        fi
        if [[ -n "$(find "${destination}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            print -u2 "Destination must be empty: ${destination}"
            exit 1
        fi
        destination="${destination:A}"
    else
        destination_parent="${destination:h}"
        mkdir -p -- "${destination_parent}"
        destination_parent="${destination_parent:A}"
        destination="${destination_parent}/${destination:t}"
        mkdir -- "${destination}"
    fi
else
    destination="$(mktemp -d "${TMPDIR:-/tmp}/cod4-macos-public-source.XXXXXX")"
fi

if [[ "${destination}" == "${repo_dir}" ||
      "${destination}" == "${repo_dir}/"* ||
      "${repo_dir}" == "${destination}/"* ||
      "${destination}" == / ]]; then
    print -u2 "Destination must be outside the project tree and cannot contain it."
    exit 1
fi

print "Exporting review snapshot to: ${destination}"

# Rules containing a slash are anchored to the source root. Rules without a
# slash match a basename at any depth. Keep the audit below in sync: rsync is
# only the first line of defense, never the publication decision.
rsync --archive \
    --exclude='/.git/' \
    --exclude='/.gitmodules.private' \
    --exclude='/.DS_Store' \
    --exclude='.DS_Store' \
    --exclude='/build*/' \
    --exclude='/bin/' \
    --exclude='/dist/' \
    --exclude='/Debug/' \
    --exclude='/Release/' \
    --exclude='/out/' \
    --exclude='/logs/' \
    --exclude='/main/' \
    --exclude='/zone/' \
    --exclude='/players/' \
    --exclude='/mods/' \
    --exclude='/usermaps/' \
    --exclude='/demos/' \
    --exclude='/screenshots/' \
    --exclude='/deps/binklib/' \
    --exclude='/deps/msslib/' \
    --exclude='/deps/steamsdk/' \
    --include='/mac/vendor/' \
    --include='/mac/vendor/SDL2/' \
    --include='/mac/vendor/SDL2/LICENSE.txt' \
    --include='/mac/vendor/SDL3/' \
    --include='/mac/vendor/SDL3/LICENSE.txt' \
    --exclude='/mac/vendor/*' \
    --exclude='/mac/first-frame.png' \
    --exclude='/mac/main-menu.png' \
    --exclude='/mac/profile-created.png' \
    --exclude='/mac/profile-screen.png' \
    --exclude='/mac/start-server.png' \
    --exclude='/mac/textured-menu.png' \
    --exclude='/mac/assets/jgalbs-cod4-icon.png' \
    --exclude='/mac/dxvk/dxvk-probe' \
    --exclude='/mac/tools/structdiff.out' \
    --exclude='/src/oatbridge/oatbridge_test' \
    --exclude='/mac/updater/updates/' \
    --exclude='/mac/updater/release/' \
    --exclude='/mac/updater/appcast.xml' \
    --exclude='*.app' \
    --exclude='*.dmg' \
    --exclude='*.pkg' \
    --exclude='*.xcarchive' \
    --exclude='*.zip' \
    --exclude='*.7z' \
    --exclude='*.rar' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tar.xz' \
    --exclude='*.iwd' \
    --exclude='*.ff' \
    --exclude='*.d3dbsp' \
    --exclude='*.dm_1' \
    --exclude='*.mpdata' \
    --exclude='servercache.dat' \
    --exclude='config_mp.cfg' \
    --exclude='*.dylib' \
    --exclude='*.so' \
    --exclude='*.dll' \
    --exclude='*.lib' \
    --exclude='*.a' \
    --exclude='*.exe' \
    --exclude='*.o' \
    --exclude='*.obj' \
    --exclude='*.lo' \
    --exclude='*.bc' \
    --exclude='*.exp' \
    --exclude='*.pdb' \
    --exclude='*.nro' \
    --exclude='.env' \
    --exclude='.env.*' \
    --exclude='*.pem' \
    --exclude='*.p12' \
    --exclude='*.pfx' \
    --exclude='*.key' \
    --exclude='*.keystore' \
    --exclude='*.mobileprovision' \
    --exclude='*.xcuserstate' \
    --exclude='*.log' \
    --exclude='*~' \
    "${repo_dir}/" "${destination}/"

typeset -a audit_failures
audit_failures=()
typeset -a regular_files
regular_files=()

record_failure() {
    audit_failures+=("$1")
}

# Audit every exported entry independently of the copy rules. Reject unusual
# names, symlinks, devices, FIFOs, and every known excluded path or suffix.
while IFS= read -r -d $'\0' exported_path; do
    relative_path="${exported_path#${destination}/}"
    base_name="${relative_path:t}"

    if [[ "${relative_path}" == *$'\n'* || "${relative_path}" == *$'\r'* ]]; then
        record_failure "unsafe control character in path: ${relative_path}"
        continue
    fi

    if [[ -L "${exported_path}" || ! -f "${exported_path}" ]]; then
        record_failure "non-regular exported entry: ${relative_path}"
        continue
    fi
    regular_files+=("${exported_path}")

    case "${relative_path}" in
        (.git/*|build*/*|bin/*|dist/*|Debug/*|Release/*|out/*|logs/*)
            record_failure "build/history output escaped filters: ${relative_path}" ;;
        (main|main/*|zone|zone/*|players|players/*|mods|mods/*|usermaps|usermaps/*|demos|demos/*|screenshots|screenshots/*)
            record_failure "runtime or retail data escaped filters: ${relative_path}" ;;
        (mac/vendor/SDL2/LICENSE.txt|mac/vendor/SDL3/LICENSE.txt)
            ;;
        (deps/binklib/*|deps/msslib/*|deps/steamsdk/*|mac/vendor/*)
            record_failure "excluded third-party payload escaped filters: ${relative_path}" ;;
        (mac/first-frame.png|mac/main-menu.png|mac/profile-created.png|mac/profile-screen.png|mac/start-server.png|mac/textured-menu.png)
            record_failure "retail screenshot escaped filters: ${relative_path}" ;;
        (mac/assets/jgalbs-cod4-icon.png)
            record_failure "unverified branding asset escaped filters: ${relative_path}" ;;
        (mac/dxvk/dxvk-probe|mac/tools/structdiff.out|src/oatbridge/oatbridge_test)
            record_failure "generated probe output escaped filters: ${relative_path}" ;;
        (mac/updater/updates|mac/updater/updates/*|mac/updater/release|mac/updater/release/*|mac/updater/appcast.xml)
            record_failure "generated updater material escaped filters: ${relative_path}" ;;
    esac

    case "${base_name}" in
        (.DS_Store|.env|.env.*|*.pem|*.p12|*.pfx|*.key|*.keystore|*.mobileprovision|*.xcuserstate|*.log|*~)
            record_failure "sensitive or local-only filename escaped filters: ${relative_path}" ;;
        (*.app|*.dmg|*.pkg|*.xcarchive|*.zip|*.7z|*.rar|*.tar|*.tar.gz|*.tar.xz)
            record_failure "archive or bundle escaped filters: ${relative_path}" ;;
        (*.iwd|*.ff|*.d3dbsp|*.dm_1|*.mpdata|servercache.dat|config_mp.cfg)
            record_failure "retail or runtime file escaped filters: ${relative_path}" ;;
        (*.dylib|*.so|*.dll|*.lib|*.a|*.exe|*.o|*.obj|*.lo|*.bc|*.exp|*.pdb|*.nro)
            record_failure "compiled library escaped filters: ${relative_path}" ;;
    esac

    mode="$(stat -f '%Lp' "${exported_path}")"
    if (( (8#${mode} & 8#6000) != 0 )); then
        record_failure "setuid/setgid permission is forbidden: ${relative_path}"
    fi

done < <(find "${destination}" -mindepth 1 ! -type d -print0)

# Run file(1) in one batch so the audit stays fast even on the large inherited
# source tree. Newline-bearing paths were rejected above, so each output line
# remains attributable to exactly one exported entry.
if (( ${#regular_files[@]} != 0 )); then
    compiled_descriptions="$(file "${regular_files[@]}" | \
        rg ': (Mach-O|PE32|ELF|current ar archive|.*COFF object|LLVM bitcode)' || true)"
    if [[ -n "${compiled_descriptions}" ]]; then
        record_failure "compiled executable/object detected:\n${compiled_descriptions}"
    fi
fi

typeset -a required_files
required_files=(
    LICENSE
    NOTICE
    THIRD_PARTY_NOTICES.txt
    CMakeLists.txt
    deps/ode/LICENSE-BSD.TXT
    deps/ode/LICENSE.TXT
    deps/speex/COPYING
    mac/sdl2/README.md
    mac/sdl2/sdl2-compat-release.conf
    mac/vendor/SDL2/LICENSE.txt
    mac/vendor/SDL3/LICENSE.txt
    mac/tools/fetch-build-sdl2-compat.zsh
    mac/tools/sdl-runtime-probe.c
    mac/tools/verify-bundled-sdl.zsh
    mac/tools/export-public-source.zsh
)
for required_file in "${required_files[@]}"; do
    if [[ ! -f "${destination}/${required_file}" ]]; then
        record_failure "required source/notice is missing: ${required_file}"
    fi
done

# High-confidence credential patterns. Construct the prefixes in pieces so
# this scanner does not report its own pattern definitions as credentials.
typeset -a secret_patterns
github_classic_prefix='g''hp_'
github_fine_prefix='github_''pat_'
digitalocean_prefix='dop_''v1_'
openai_prefix='sk-''proj-'
private_key_pattern='-----BEGIN [A-Z0-9 ]*PRIVATE'" KEY-----"
secret_patterns=(
    "${github_classic_prefix}[A-Za-z0-9]{20,}"
    "${github_fine_prefix}[A-Za-z0-9_]{20,}"
    "${digitalocean_prefix}[A-Za-z0-9]{20,}"
    "${openai_prefix}[A-Za-z0-9_-]{20,}"
    'AKIA[0-9A-Z]{16}'
    'ASIA[0-9A-Z]{16}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    "${private_key_pattern}"
    'https?://[^/@[:space:]]+:[^/@[:space:]]+@'
)

secret_hits="$(mktemp "${TMPDIR:-/tmp}/cod4-macos-public-secrets.XXXXXX")"
trap 'rm -f -- "${secret_hits}"' EXIT
: >"${secret_hits}"
for secret_pattern in "${secret_patterns[@]}"; do
    set +e
    rg --line-number --no-heading --hidden \
        --glob '!PUBLIC_SOURCE_MANIFEST.sha256' \
        --regexp "${secret_pattern}" "${destination}" >>"${secret_hits}"
    scan_status=$?
    set -e
    if (( scan_status != 0 && scan_status != 1 )); then
        record_failure "secret scanner failed with status ${scan_status}"
    fi
done
if [[ -s "${secret_hits}" ]]; then
    record_failure "high-confidence credential pattern detected (details withheld; inspect ${secret_hits})"
fi

if (( ${#audit_failures[@]} != 0 )); then
    print -u2 "Public-source audit FAILED. Do not initialize or publish this directory."
    for failure in "${audit_failures[@]}"; do
        print -u2 -- " - ${failure}"
    done
    if [[ -s "${secret_hits}" ]]; then
        print -u2 "Potential secret locations are recorded locally at: ${secret_hits}"
        trap - EXIT
    fi
    exit 1
fi

manifest_path="${destination}/PUBLIC_SOURCE_MANIFEST.sha256"
(
    cd "${destination}"
    typeset -a manifest_files
    manifest_files=("${(@f)$(find . -type f ! -name 'PUBLIC_SOURCE_MANIFEST.sha256' -print | sort)}")
    shasum -a 256 "${manifest_files[@]}" | sed 's#  \./#  #'
) >"${manifest_path}"

rm -f -- "${secret_hits}"
trap - EXIT

file_count="$(find "${destination}" -type f | wc -l | tr -d ' ')"
total_size="$(du -sh "${destination}" | awk '{ print $1 }')"
manifest_digest="$(shasum -a 256 "${manifest_path}" | awk '{ print $1 }')"

print "Public-source audit passed."
print "Files: ${file_count}; size: ${total_size}"
print "Manifest SHA-256: ${manifest_digest}"
print "Review only; no Git history was created and nothing was published."
print "Staging directory: ${destination}"
