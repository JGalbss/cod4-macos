#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
product_name="jgalbs cod4"
executable_name="${product_name}"
app_bundle="${product_name}.app"
native_binary="${repo_dir}/bin/posix/${executable_name}"
icon_source="${APP_ICON_SOURCE:-}"
vendored_sdl2="${repo_dir}/mac/vendor/SDL2/libSDL2-2.0.0.dylib"
vendored_sdl2_license="${repo_dir}/mac/vendor/SDL2/LICENSE.txt"
vendored_sdl3="${repo_dir}/mac/vendor/SDL3/libSDL3.dylib"
vendored_sdl3_license="${repo_dir}/mac/vendor/SDL3/LICENSE.txt"
release_readme="${repo_dir}/mac/RELEASE_README.txt"
gpl_license="${repo_dir}/LICENSE"
project_notice="${repo_dir}/NOTICE"
third_party_notices="${repo_dir}/THIRD_PARTY_NOTICES.txt"
output_dir="${repo_dir}/dist"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/cod4-native-package.XXXXXX")"
stage_app="${stage_dir}/${app_bundle}"
publish_release="${PUBLISH_RELEASE:-0}"
notary_profile="${NOTARYTOOL_PROFILE:-}"
source_code_url="${SOURCE_CODE_URL:-}"

cleanup_stage() {
    rm -rf -- "${stage_dir}"
}
trap cleanup_stage EXIT

if [[ ! -x "${native_binary}" ]]; then
    print -u2 "Native binary is missing. Build build-metal first: ${native_binary}"
    exit 1
fi
for runtime_input in "${vendored_sdl2}" "${vendored_sdl2_license}" \
                     "${vendored_sdl3}" "${vendored_sdl3_license}"; do
    if [[ ! -f "${runtime_input}" ]]; then
        print -u2 "Pinned SDL runtime input is missing: ${runtime_input}"
        print -u2 "Run mac/tools/fetch-build-sdl2-compat.zsh before packaging."
        exit 1
    fi
done
if [[ -z "${icon_source}" ]]; then
    print -u2 "APP_ICON_SOURCE is required and must point to an authorized square PNG."
    exit 1
fi
if [[ ! -f "${icon_source}" ]]; then
    print -u2 "APP_ICON_SOURCE was not found: ${icon_source}"
    exit 1
fi
icon_width="$(sips -g pixelWidth "${icon_source}" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
icon_height="$(sips -g pixelHeight "${icon_source}" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
if [[ -z "${icon_width}" || "${icon_width}" != "${icon_height}" ]]; then
    print -u2 "APP_ICON_SOURCE must be a readable square image: ${icon_source}"
    exit 1
fi
if [[ "${publish_release}" != 0 && "${publish_release}" != 1 ]]; then
    print -u2 "PUBLISH_RELEASE must be 0 or 1."
    exit 1
fi

mkdir -p "${stage_app}/Contents/MacOS" \
         "${stage_app}/Contents/Resources" \
         "${stage_app}/Contents/Frameworks"
"${repo_dir}/mac/updater/stage_sparkle.zsh" "${stage_app}"
cp "${repo_dir}/mac/Info.plist" "${stage_app}/Contents/Info.plist"
# Development packages must not poll a production feed that may not exist yet.
# Manual Check for Updates remains available for deliberate updater testing.
if [[ "${publish_release}" != 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' \
        "${stage_app}/Contents/Info.plist"
fi
cp "${native_binary}" "${stage_app}/Contents/MacOS/${executable_name}"
chmod 755 "${stage_app}/Contents/MacOS/${executable_name}"

# Build a complete Retina icon family from the explicitly supplied authorized image.
# Retail game data is never copied into the application.
iconset_dir="${stage_dir}/jgalbs-cod4.iconset"
mkdir -p "${iconset_dir}"
for icon_size in 16 32 128 256 512; do
    sips -s format png -z "${icon_size}" "${icon_size}" "${icon_source}" \
        --out "${iconset_dir}/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -s format png -z "${retina_size}" "${retina_size}" "${icon_source}" \
        --out "${iconset_dir}/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "${iconset_dir}" -o "${stage_app}/Contents/Resources/jgalbs-cod4.icns"

cp "${vendored_sdl2_license}" \
    "${stage_app}/Contents/Resources/SDL2-LICENSE.txt"
cp "${vendored_sdl3_license}" \
    "${stage_app}/Contents/Resources/SDL3-LICENSE.txt"
if [[ -f "${repo_dir}/mac/vendor/Sparkle/LICENSE.txt" ]]; then
    cp "${repo_dir}/mac/vendor/Sparkle/LICENSE.txt" \
        "${stage_app}/Contents/Resources/SPARKLE-LICENSE.txt"
fi
cp "${release_readme}" "${stage_app}/Contents/Resources/README.txt"
cp "${gpl_license}" "${stage_app}/Contents/Resources/GPL-3.0.txt"
cp "${project_notice}" "${stage_app}/Contents/Resources/NOTICE.txt"
cp "${third_party_notices}" "${stage_app}/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "${repo_dir}/deps/ode/LICENSE-BSD.TXT" \
    "${stage_app}/Contents/Resources/ODE-LICENSE-BSD.txt"
cp "${repo_dir}/deps/speex/COPYING" \
    "${stage_app}/Contents/Resources/SPEEX-LICENSE.txt"
source_notice="${stage_app}/Contents/Resources/SOURCE-NOTICE.txt"
if [[ -n "${source_code_url}" ]]; then
    print -r -- "Corresponding source code for this exact build:" >"${source_notice}"
    print -r -- "${source_code_url}" >>"${source_notice}"
else
    print -r -- "This GPLv3 development build must not be publicly distributed without corresponding source code." >"${source_notice}"
fi

# Make the app self-contained for Macs that do not have the build machine's
# Homebrew SDL/GLM libraries. System frameworks remain linked from macOS.
bundled_sdl=0
cp "${vendored_sdl3}" "${stage_app}/Contents/Frameworks/libSDL3.dylib"
while IFS= read -r library_path; do
    [[ -n "${library_path}" ]] || continue
    library_name="${library_path:t}"
    if [[ "${library_name}" == libSDL2-2.0.0.dylib ]]; then
        cp "${vendored_sdl2}" "${stage_app}/Contents/Frameworks/${library_name}"
        bundled_sdl=1
    else
        cp "${library_path}" "${stage_app}/Contents/Frameworks/${library_name}"
    fi
    install_name_tool -change "${library_path}" "@rpath/${library_name}" \
        "${stage_app}/Contents/MacOS/${executable_name}"
done < <(otool -L "${native_binary}" | awk '$1 ~ /^\/opt\/homebrew\// { print $1 }')
if (( bundled_sdl != 1 )); then
    print -u2 "The native executable did not expose the SDL2 dependency expected by the package."
    exit 1
fi

# Do not leave the build machine's Homebrew directory ahead of the bundled
# libraries. dyld searches LC_RPATH entries in load-command order; retaining
# /opt/homebrew/lib made an otherwise self-contained app silently use whatever
# SDL/GLM happened to be installed on the launching Mac. CMake can also embed
# the absolute directory of a downloaded framework, so remove every absolute
# rpath; packaged dependencies must resolve from the app bundle.
while IFS= read -r rpath; do
    [[ -n "${rpath}" ]] || continue
    install_name_tool -delete_rpath "${rpath}" "${stage_app}/Contents/MacOS/${executable_name}"
done < <(otool -l "${stage_app}/Contents/MacOS/${executable_name}" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
        if ($2 ~ /^\//) print $2
        in_rpath = 0
    }')
if ! otool -l "${stage_app}/Contents/MacOS/${executable_name}" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
        print $2
        in_rpath = 0
    }' | grep -Fxq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${stage_app}/Contents/MacOS/${executable_name}"
fi

# Refuse to publish a package that still reaches into this build Mac. Keep this
# recursive so a future bundled library cannot smuggle in a transitive Homebrew
# dependency that the main executable's direct scan did not reveal.
dependency_leaks="${stage_dir}/dependency-leaks.txt"
: >"${dependency_leaks}"
while IFS= read -r -d '' candidate; do
    file "${candidate}" | grep -q 'Mach-O' || continue
    otool -L "${candidate}" | awk \
        '$1 ~ /^\/Users\// || $1 ~ /^\/opt\/homebrew\// || $1 ~ /^\/usr\/local\// { print }' \
        >>"${dependency_leaks}"
    otool -l "${candidate}" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" {
            if ($2 ~ /^\/Users\// || $2 ~ /^\/opt\// || $2 ~ /^\/usr\/local\//) print $2
            in_rpath = 0
        }' >>"${dependency_leaks}"
done < <(find "${stage_app}" -type f -print0)
if [[ -s "${dependency_leaks}" ]]; then
    print -u2 "Package still contains build-machine dependencies:"
    cat "${dependency_leaks}" >&2
    exit 1
fi

# Load commands are not the only way a local path can escape. Compiler debug
# metadata and __FILE__ expansions can preserve the checkout directory inside
# a Mach-O even after its rpaths are clean. Reject common macOS build roots in
# every bundled executable/framework so a public package cannot disclose or
# depend on the build host's filesystem layout.
build_path_leaks="${stage_dir}/build-path-leaks.txt"
: >"${build_path_leaks}"
while IFS= read -r -d '' candidate; do
    file "${candidate}" | grep -q 'Mach-O' || continue
    strings -a "${candidate}" | awk -v binary="${candidate}" '
        (/^\/(Users|Volumes|tmp|var\/folders)\// ||
         /^\/private\/(tmp|var)\// ||
         /^\/opt\/homebrew\// ||
         /^\/usr\/local\//) && $0 !~ /XXXXXX/ {
            print binary ": " $0
        }' >>"${build_path_leaks}"
done < <(find "${stage_app}" -type f -print0)
if [[ -s "${build_path_leaks}" ]]; then
    print -u2 "Package still embeds build-machine paths:"
    cat "${build_path_leaks}" >&2
    exit 1
fi
"${repo_dir}/mac/tools/verify-bundled-sdl.zsh" "${stage_app}"

# Ad-hoc signing makes local/test builds internally consistent. A public build
# can supply CODE_SIGN_IDENTITY with a Developer ID Application certificate;
# notarization remains a separate credentialed release step.
sign_identity="${CODE_SIGN_IDENTITY:--}"
if [[ "${publish_release}" == 1 ]]; then
    if [[ "${sign_identity}" == - ]]; then
        print -u2 "Publish mode requires CODE_SIGN_IDENTITY with a Developer ID Application certificate."
        exit 1
    fi
    if [[ -z "${notary_profile}" ]]; then
        print -u2 "Publish mode requires NOTARYTOOL_PROFILE from 'xcrun notarytool store-credentials'."
        exit 1
    fi
    if [[ -z "${source_code_url}" ]]; then
        print -u2 "Publish mode requires SOURCE_CODE_URL for this exact GPLv3 source revision."
        exit 1
    fi
    release_revision="$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || true)"
    if [[ ! "${release_revision}" =~ '^[0-9a-f]{40}$' \
        || "${source_code_url}" != "https://github.com/JGalbss/cod4-macos/tree/${release_revision}" ]]; then
        print -u2 "SOURCE_CODE_URL must identify this exact public source commit."
        exit 1
    fi
    if [[ -n "$(git -C "${repo_dir}" status --porcelain --untracked-files=no)" ]]; then
        print -u2 "Publish mode requires a clean tracked source checkout."
        exit 1
    fi
    if ! command -v gh >/dev/null \
        || ! gh api "repos/JGalbss/cod4-macos/commits/${release_revision}" \
            --jq .sha 2>/dev/null | grep -Fxiq "${release_revision}"; then
        print -u2 "The exact source commit is not reachable in JGalbss/cod4-macos."
        exit 1
    fi
fi
sign_options=(--force --sign "${sign_identity}")
if [[ "${sign_identity}" != - ]]; then
    sign_options+=(--options runtime --timestamp)
fi
for framework in "${stage_app}"/Contents/Frameworks/*.dylib(N); do
    codesign "${sign_options[@]}" "${framework}" >/dev/null
    codesign --verify --strict --verbose=2 "${framework}"
done
"${repo_dir}/mac/updater/resign_sparkle.zsh" \
    "${stage_app}/Contents/Frameworks/Sparkle.framework" "${sign_identity}"
codesign "${sign_options[@]}" "${stage_app}" >/dev/null
codesign --verify --deep --strict --verbose=2 "${stage_app}"
"${repo_dir}/mac/tools/verify-bundled-sdl.zsh" "${stage_app}"
"${repo_dir}/mac/updater/verify_updater_bundle.zsh" "${stage_app}"
mkdir -p "${output_dir}"

new_app="${output_dir}/${app_bundle}.new"
previous_app="${output_dir}/${app_bundle}.previous"
rm -rf -- "${new_app}" "${previous_app}"
mv "${stage_app}" "${new_app}"
if [[ -e "${output_dir}/${app_bundle}" ]]; then
    mv "${output_dir}/${app_bundle}" "${previous_app}"
fi
mv "${new_app}" "${output_dir}/${app_bundle}"

dmg_path="${output_dir}/cod4-macos-arm64.dmg"
rm -f -- "${dmg_path}"
dmg_stage="${stage_dir}/dmg"
mkdir -p "${dmg_stage}"
cp -R "${output_dir}/${app_bundle}" "${dmg_stage}/${app_bundle}"
ln -s /Applications "${dmg_stage}/Applications"
cp "${release_readme}" "${dmg_stage}/README.txt"
cp "${gpl_license}" "${dmg_stage}/GPL-3.0.txt"
cp "${project_notice}" "${dmg_stage}/NOTICE.txt"
cp "${third_party_notices}" "${dmg_stage}/THIRD-PARTY-NOTICES.txt"
cp "${output_dir}/${app_bundle}/Contents/Resources/SOURCE-NOTICE.txt" \
    "${dmg_stage}/SOURCE-NOTICE.txt"
hdiutil create -quiet -volname "${product_name}" -srcfolder "${dmg_stage}" \
    -format UDZO "${dmg_path}"
if [[ "${sign_identity}" != - ]]; then
    codesign --force --sign "${sign_identity}" --timestamp "${dmg_path}" >/dev/null
fi
if [[ -n "${notary_profile}" ]]; then
    if [[ "${sign_identity}" == - ]]; then
        print -u2 "NOTARYTOOL_PROFILE requires a real CODE_SIGN_IDENTITY."
        exit 1
    fi
    xcrun notarytool submit "${dmg_path}" \
        --keychain-profile "${notary_profile}" --wait
    xcrun stapler staple "${dmg_path}"
    xcrun stapler validate "${dmg_path}"
fi
if [[ "${publish_release}" == 1 ]]; then
    codesign --verify --deep --strict --verbose=2 "${output_dir}/${app_bundle}"
    spctl --assess --type open --context context:primary-signature \
        --verbose=2 "${dmg_path}"
fi

# Generate this after signing/notarization/stapling so it authenticates the
# exact bytes recipients download, rather than the pre-notarization image.
checksum_path="${dmg_path}.sha256"
checksum_value="$(shasum -a 256 "${dmg_path}" | awk '{ print $1 }')"
print -r -- "${checksum_value}  ${dmg_path:t}" >"${checksum_path}"

print "Built ${output_dir}/${app_bundle}"
print "Built ${dmg_path}"
print "Built ${checksum_path}"
