#!/bin/bash
# Install the private CoD4 control panel. It stays on loopback and is reached
# through SSH, so this script deliberately opens no firewall port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_SOURCE="${1:-$SCRIPT_DIR/cod4ctl.py}"
UNIT_SOURCE="${2:-$SCRIPT_DIR/cod4-control.service}"
SERVER_CONFIG="${COD4_SERVER_CONFIG:-/opt/cod4/main/server.cfg}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run control.sh as root" >&2
  exit 1
fi
for required in "$CONTROL_SOURCE" "$UNIT_SOURCE" "$SERVER_CONFIG"; do
  if [ ! -f "$required" ]; then
    echo "missing required file: $required" >&2
    exit 1
  fi
done
if ! id cod4 >/dev/null 2>&1; then
  echo "the cod4 service account does not exist" >&2
  exit 1
fi

install -d -m 0755 /usr/local/lib/cod4-control
install -m 0755 "$CONTROL_SOURCE" /usr/local/lib/cod4-control/cod4ctl.py
ln -sfn /usr/local/lib/cod4-control/cod4ctl.py /usr/local/bin/cod4ctl

install -d -o root -g cod4 -m 0750 /etc/cod4-control
rcon_value="${COD4_RCON:-}"
if [ -z "$rcon_value" ]; then
  rcon_value="$(sed -nE 's/^[[:space:]]*set[[:space:]]+rcon_password[[:space:]]+"([^"]+)".*/\1/p' "$SERVER_CONFIG" | tail -n 1)"
fi
if [ -z "$rcon_value" ]; then
  echo "no RCON credential found; set COD4_RCON or configure server.cfg" >&2
  exit 1
fi
secret_tmp="$(mktemp)"
trap 'rm -f "$secret_tmp"' EXIT
chmod 0600 "$secret_tmp"
printf '%s\n' "$rcon_value" > "$secret_tmp"
install -o root -g cod4 -m 0640 "$secret_tmp" /etc/cod4-control/rcon_password
unset rcon_value

rotation="$(sed -nE 's/^[[:space:]]*set[[:space:]]+sv_mapRotation[[:space:]]+"([^"]+)".*/\1/p' "$SERVER_CONFIG" | tail -n 1)"
maps="$(printf '%s\n' "$rotation" | grep -oE 'map[[:space:]]+[A-Za-z0-9_]+' | awk '{print $2}' | paste -sd, - || true)"
if [ -n "$maps" ]; then
  environment_tmp="$(mktemp)"
  printf 'COD4_MAPS=%s\n' "$maps" > "$environment_tmp"
  install -o root -g cod4 -m 0640 "$environment_tmp" /etc/cod4-control/environment
  rm -f "$environment_tmp"
else
  rm -f /etc/cod4-control/environment
fi

install -o root -g root -m 0644 "$UNIT_SOURCE" /etc/systemd/system/cod4-control.service
systemctl daemon-reload
systemctl enable --now cod4-control.service
systemctl restart cod4-control.service
systemctl --quiet is-active cod4-control.service
echo "CoD4 control is running at 127.0.0.1:8787 (SSH tunnel required)."
