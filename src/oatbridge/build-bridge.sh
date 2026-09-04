#!/usr/bin/env bash
# Compile the OAT bridge and its self-test against OpenAssetTools' static libs.
# OAT must be built first: (cd ../../../oat && ./mac-build.sh UnlinkerCli)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OAT="${OAT_ROOT:-$HERE/../../../oat}"
LIB="$OAT/build/lib/Release_x64"

[ -d "$LIB" ] || { echo "OAT not built: $LIB missing"; exit 1; }

INC=(-I"$HERE")
for d in "$OAT"/src/*/; do INC+=(-I"$d"); done
INC+=(-I"$OAT/thirdparty/zlib" -I"$OAT/thirdparty/json/single_include")

# ld64 reads each archive once, so the group is repeated to settle cycles.
LIBS=()
for pass in 1 2 3; do
  for a in ZoneLoading ZoneCommon ObjLoading ObjCommon ObjImage Parser Common Utils \
           Cryptography XMemCompress zlib lz4 lzx minilzo minizip salsa20 libtomcrypt libtommath; do
    [ -f "$LIB/lib$a.a" ] && LIBS+=("$LIB/lib$a.a")
  done
done

clang++ -std=c++23 -O2 -arch arm64 -mmacosx-version-min=14.0 -DARCH_x64 \
  "${INC[@]}" "$HERE/oatbridge.cpp" "$HERE/oatbridge_test.cpp" \
  "${LIBS[@]}" -lz -o "$HERE/oatbridge_test"
echo "built: $HERE/oatbridge_test"
