#!/usr/bin/env bash
# Build the server-only runtime zone from legally owned retail data.
# The generated mod.ff is private game data: never commit or publish it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COD4_DATA="${COD4_DATA:?set COD4_DATA to the retail CoD4 data directory}"
OUTPUT="${1:?usage: COD4_DATA=/path/to/cod4 $0 /absolute/output/mod.ff}"
UNLINKER="${OAT_UNLINKER:-$REPO_ROOT/build/OpenAssetTools/build/bin/Release_x64/Unlinker}"
LINKER="${OAT_LINKER:-$REPO_ROOT/build/OpenAssetTools/build/bin/Release_x64/Linker}"
SOURCE_ZONE="$COD4_DATA/zone/english/scoutsniper.ff"

for required in "$UNLINKER" "$LINKER" "$SOURCE_ZONE"; do
  if [ ! -f "$required" ]; then
    echo "missing required file: $required" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jgalbs-runtime-zone.XXXXXX")"
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/unlinked" "$WORK_DIR/build/zone_source" "$WORK_DIR/output"
"$UNLINKER" --no-color \
  --include-assets rawfile \
  --output-folder "$WORK_DIR/unlinked/?zone?" \
  "$SOURCE_ZONE"

for shock in radiation_low radiation_med radiation_high; do
  if [ ! -f "$WORK_DIR/unlinked/scoutsniper/shock/$shock.shock" ]; then
    echo "retail zone did not contain shock/$shock.shock" >&2
    exit 1
  fi
done

cat >"$WORK_DIR/build/zone_source/mod.zone" <<'ZONE'
>game,IW3

rawfile,shock/radiation_low.shock
rawfile,shock/radiation_med.shock
rawfile,shock/radiation_high.shock
ZONE

"$LINKER" --no-color \
  --base-folder "$WORK_DIR/build" \
  --output-folder "$WORK_DIR/output" \
  --asset-search-path "$WORK_DIR/unlinked/scoutsniper" \
  mod

mkdir -p "$(dirname "$OUTPUT")"
install -m 0644 "$WORK_DIR/output/mod.ff" "$OUTPUT"
echo "private runtime zone: $OUTPUT"
shasum -a 256 "$OUTPUT"
