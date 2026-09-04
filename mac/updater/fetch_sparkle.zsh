#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
config_file="${script_dir}/sparkle-release.conf"
destination="${1:-${repo_dir}/mac/vendor/Sparkle}"

source "${config_file}"

if [[ "${destination}" != /* || "${destination}" == / ]]; then
    print -u2 "Destination must be an absolute, non-root path."
    exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/jgalbs-cod4-sparkle-fetch.XXXXXX")"
cleanup() {
    rm -rf -- "${temp_dir}"
}
trap cleanup EXIT

archive_path="${temp_dir}/${SPARKLE_ARCHIVE}"
print "Downloading official Sparkle ${SPARKLE_VERSION} distribution..."
curl --fail --location --proto '=https' --tlsv1.2 \
    --output "${archive_path}" "${SPARKLE_URL}"

actual_sha="$(shasum -a 256 "${archive_path}" | awk '{ print $1 }')"
if [[ "${actual_sha}" != "${SPARKLE_SHA256}" ]]; then
    print -u2 "Sparkle checksum mismatch."
    print -u2 "Expected: ${SPARKLE_SHA256}"
    print -u2 "Actual:   ${actual_sha}"
    exit 1
fi

unpack_dir="${temp_dir}/unpack"
mkdir -p "${unpack_dir}"
tar -xf "${archive_path}" -C "${unpack_dir}"

framework="${unpack_dir}/Sparkle.framework"
if [[ ! -x "${framework}/Versions/B/Sparkle" ]]; then
    print -u2 "Official archive does not contain the expected Sparkle.framework layout."
    exit 1
fi
if [[ " $(lipo -archs "${framework}/Versions/B/Sparkle") " != *" arm64 "* ]]; then
    print -u2 "Sparkle.framework does not contain an arm64 slice."
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "${framework}"

destination_parent="${destination:h}"
staged_destination="${destination}.new"
previous_destination="${destination}.previous"
mkdir -p "${destination_parent}"
rm -rf -- "${staged_destination}"
mkdir -p "${staged_destination}/bin"
ditto "${framework}" "${staged_destination}/Sparkle.framework"
for tool in generate_appcast generate_keys sign_update BinaryDelta; do
    ditto "${unpack_dir}/bin/${tool}" "${staged_destination}/bin/${tool}"
done
cp "${unpack_dir}/LICENSE" "${staged_destination}/LICENSE.txt"
cp "${config_file}" "${staged_destination}/sparkle-release.conf"

rm -rf -- "${previous_destination}"
if [[ -e "${destination}" ]]; then
    mv "${destination}" "${previous_destination}"
fi
mv "${staged_destination}" "${destination}"

print "Installed Sparkle ${SPARKLE_VERSION} at ${destination}"
if [[ -e "${previous_destination}" ]]; then
    print "Previous installation preserved at ${previous_destination}"
fi
