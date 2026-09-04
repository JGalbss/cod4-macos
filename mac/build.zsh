#!/bin/zsh

set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly OAT_DIR="${PROJECT_DIR}/build/OpenAssetTools"
readonly OAT_REVISION="0ad64096aa6ee2874f835fff8a5c6dc4af8c7f77"
readonly JOBS="$(sysctl -n hw.logicalcpu)"
readonly -a DEPENDENCIES=(cmake ninja premake sdl2-compat glm)

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "This build requires an Apple Silicon Mac."
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  print -u2 "Install the Xcode Command Line Tools, then run this command again:"
  print -u2 "  xcode-select --install"
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  print -u2 "Homebrew is required: https://brew.sh"
  exit 1
fi

typeset -a missing_dependencies=()
for dependency in "${DEPENDENCIES[@]}"; do
  brew list --formula "${dependency}" >/dev/null 2>&1 || \
    missing_dependencies+=("${dependency}")
done

if (( ${#missing_dependencies} )); then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "${missing_dependencies[@]}"
fi

if [[ ! -d "${OAT_DIR}/.git" ]]; then
  git clone --recurse-submodules \
    https://github.com/JGalbss/OpenAssetTools.git "${OAT_DIR}"
elif ! git -C "${OAT_DIR}" cat-file -e "${OAT_REVISION}^{commit}" 2>/dev/null; then
  git -C "${OAT_DIR}" fetch origin
fi

git -C "${OAT_DIR}" checkout --detach "${OAT_REVISION}"
git -C "${OAT_DIR}" submodule update --init --recursive
if [[ ! -f "${OAT_DIR}/build/lib/Release_x64/libZoneLoading.a" ||
      ! -f "${OAT_DIR}/build/lib/Release_x64/libObjLoading.a" ]]; then
  KB_JOBS="${JOBS}" "${OAT_DIR}/mac-build.sh"
fi

cmake -S "${PROJECT_DIR}" -B "${PROJECT_DIR}/build-metal" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DKISAK_TARGET=posix \
  -DKISAK_METAL=ON \
  -DOAT_ROOT="${OAT_DIR}"
cmake --build "${PROJECT_DIR}/build-metal" --target kisak_posix -j "${JOBS}"

print "Built ${PROJECT_DIR}/bin/posix/jgalbs cod4"
