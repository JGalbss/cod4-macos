#!/bin/sh
# Start a Shipment free-for-all against Jev bots that a human can join.
# The server binds every interface on the host and gates joins with the game password,
# so UDP 28990 must be open in the host firewall first:
#     ssh root@159.65.37.227 ufw allow 28990/udp
#
# Usage: TYPESAFE_API_KEY=... tools/play.sh [seconds] [bots]
# Then in the CoD4 console:  /password rogo   and   /connect 159.65.37.227:28990
set -eu
cd "$(dirname "$0")/.."
if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  echo "TYPESAFE_API_KEY is not set" >&2
  exit 1
fi
MATCH_SECONDS=${1:-1500}
BOTS=${2:-2}
OUTPUT="$HOME/Code/cod/cod4/artifacts/jev-bot/play-$(date +%Y%m%d-%H%M%S)"
LOADOUT=${LOADOUT:-assault}
nohup npm start -- --brain jev --bots "$BOTS" --game-mode dm --seconds "$MATCH_SECONDS" --loadout "$LOADOUT" \
  --port 28990 --public rogo --output "$OUTPUT" > "$OUTPUT.log" 2>&1 &
echo "match starting: $BOTS Jev bots, $MATCH_SECONDS s, log $OUTPUT.log"
echo "in about 20 s connect with:  /password rogo   then   /connect 159.65.37.227:28990"
