#!/bin/sh
# Search and Destroy on Nuketown against Jev bots, joinable by a human (one round per match).
# UDP 28990 must be open on the host. Usage: TYPESAFE_API_KEY=... tools/play_sd.sh [seconds] [bots] [opponents]
# Jev bots take the map's attacking team; pick the other team in the menu to defend against them.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${TYPESAFE_API_KEY:-}" ]; then echo "TYPESAFE_API_KEY is not set" >&2; exit 1; fi
MATCH_SECONDS=${1:-900}
BOTS=${2:-2}
OUTPUT="$HOME/Code/cod/cod4/artifacts/jev-bot/playsd-$(date +%Y%m%d-%H%M%S)"
nohup npm start -- --brain jev --bots "$BOTS" --game-mode sd --map mp_nuketown --seconds "$MATCH_SECONDS" \
  --port 28990 --public rogo --output "$OUTPUT" > "$OUTPUT.log" 2>&1 &
echo "match starting: $BOTS Jev bots attacking on Nuketown, log $OUTPUT.log"
echo "in about 20 s connect with:  /password rogo   then   /connect 159.65.37.227:28990"
