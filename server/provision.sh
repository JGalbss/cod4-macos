#!/bin/bash
# Provision a CoD4X dedicated server on a fresh Ubuntu droplet.
#
# The CoD4X server binary is 32-bit x86, which on a droplet runs natively - no
# Wine and no translation, unlike hosting from the Mac. That is why the server
# belongs here even though the client does not.
set -euo pipefail

COD4X_VERSION="21.2"
SERVER_DIR=/opt/cod4
GAME_USER=cod4

echo "==> installing 32-bit runtime"
dpkg --add-architecture i386
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  libc6:i386 libstdc++6:i386 zlib1g:i386 libgcc-s1:i386 \
  curl unzip ca-certificates >/dev/null

echo "==> creating service account"
id -u "$GAME_USER" >/dev/null 2>&1 || useradd -r -m -d "$SERVER_DIR" -s /usr/sbin/nologin "$GAME_USER"
mkdir -p "$SERVER_DIR"/{main,zone/english,mods,plugins,usermaps}

echo "==> fetching CoD4X server $COD4X_VERSION"
curl -sL -o "$SERVER_DIR/cod4x18_dedrun" \
  "https://github.com/callofduty4x/CoD4x_Server/releases/download/${COD4X_VERSION}/cod4x18_dedrun"
chmod +x "$SERVER_DIR/cod4x18_dedrun"

curl -sL -o /tmp/plugins.zip \
  "https://github.com/callofduty4x/CoD4x_Server/releases/download/${COD4X_VERSION}/plugins_linux.zip"
unzip -oq /tmp/plugins.zip -d /tmp/plugins
find /tmp/plugins -name '*.so' -exec cp {} "$SERVER_DIR/plugins/" \; 2>/dev/null || true

echo "==> fetching the New Experience mod"
curl -sL -o /tmp/ne.zip \
  "https://github.com/leiizko/cod4_new_experience/archive/refs/heads/master.zip"
unzip -oq /tmp/ne.zip -d /tmp/ne
NE=$(find /tmp/ne -maxdepth 1 -type d -name 'cod4_new_experience-*' | head -1)
mkdir -p "$SERVER_DIR/mods/new_experience"
cp -R "$NE/maps" "$NE/code" "$SERVER_DIR/mods/new_experience/"
cp "$NE/config.cfg" "$SERVER_DIR/mods/new_experience/new_exp_config.cfg"

echo "==> firewall: game port only, plus ssh"
apt-get install -y -qq ufw >/dev/null
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 28961/udp >/dev/null
ufw --force enable >/dev/null

chown -R "$GAME_USER:$GAME_USER" "$SERVER_DIR"
echo "==> base provisioning done; game files still needed in main/ and zone/english/"
