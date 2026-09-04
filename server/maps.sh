#!/bin/bash
# Install custom maps on the CoD4X server and serve them over HTTP.
#
# CoD4 downloads missing maps from the server it is joining. Stock 1.7 does that
# over the game's own UDP channel at a few KB/s, which for a 60 MB map means the
# player sits on "Downloading" for ten minutes and the server pays the
# bandwidth out of its game-traffic budget. CoD4X can instead redirect the
# client to a web server holding the same directory layout (sv_wwwDownload),
# and a plain nginx on the droplet hands out the files at line rate. So this
# script does both halves: puts the maps in usermaps/, and stands up nginx in
# front of usermaps/ and mods/. configure.sh then points sv_wwwBaseURL here and
# adds the installed maps to the rotation.
#
# Run as root on the droplet, after provision.sh. Idempotent: maps already
# installed are left alone, nginx is reconfigured in place.
set -euo pipefail

SERVER_DIR=/opt/cod4
GAME_USER=cod4
WEB_USER=www-data
# Not port 80. Spectrum's "Security Shield" (the CUJO box in the router) sits
# on plain HTTP to unfamiliar addresses and answers port-80 requests to the
# droplet with its own warning page, so the client got HTML where it expected a
# fastfile. Port 8080 passes untouched. The client's `cod4 maps sync` and the
# server's sv_wwwBaseURL (configure.sh) both carry the port.
WEB_PORT="${COD4_WWW_PORT:-8080}"

# name|archive url|sha256 of the archive
# The archive layout differs per author (some zip the map folder, some zip a
# whole usermaps/ tree, some add screenshots and readmes), so installation goes
# by file name rather than by unpacking in place: the three files every CoD4
# map consists of are located wherever they landed and moved into
# usermaps/<name>/. Hashes are pinned so a swapped download is refused.
MAPS=(
  "mp_mw2_rust|https://www.customapscod.com/ftp/maps/COD4/mp_mw2_rust.rar|e9209ba4f86befa6c1640684d3f83e422452b90d129eecc30159f8e6e07cd09c"
  "mp_mw2_term|https://www.customapscod.com/ftp/maps/COD4/mp_mw2_term.zip|3a82a248879eddb395b306e09b34574e767e90b05f9140dfe52a5652163c0974"
  "mp_highrise|https://www.customapscod.com/ftp/maps/COD4/mp_highrise.rar|c7d47f62c13fa3c095a3d270d14708cc0981ac2bfcf1e1de986841c7b5218bbc"
  "mp_scrapyard|https://www.customapscod.com/ftp/maps/COD4/mp_sps_scrapyard.rar|1254f66874aa5ba33eaf43a44a096b4f21b12ed7d127c523e1842665ec42b0a5"
)

say() { printf '==> %s\n' "$*"; }

is_installed() {
  local name="$1" dir="$SERVER_DIR/usermaps/$1"
  [ -f "$dir/$name.ff" ] && [ -f "$dir/${name}_load.ff" ] && [ -f "$dir/$name.iwd" ]
}

fetch_verified() {
  local url="$1" sha="$2" dest="$3"
  curl -sSL -A "Mozilla/5.0" -o "$dest" "$url"
  local got; got="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { echo "checksum mismatch for $url: got $got" >&2; return 1; }
}

extract() {
  local archive="$1" into="$2"
  case "$archive" in
    *.rar) unrar x -inul -o+ "$archive" "$into/" ;;
    *.zip) unzip -oq "$archive" -d "$into" ;;
    *) echo "unknown archive type: $archive" >&2; return 1 ;;
  esac
}

install_map() {
  local name="$1" url="$2" sha="$3"
  if is_installed "$name"; then
    say "$name: already installed"
    return 0
  fi
  say "$name: fetching"
  local work; work="$(mktemp -d)"
  local archive="$work/${url##*/}"
  fetch_verified "$url" "$sha" "$archive"
  extract "$archive" "$work/x"
  local dest="$SERVER_DIR/usermaps/$name" part src
  mkdir -p "$dest"
  for part in "$name.ff" "${name}_load.ff" "$name.iwd"; do
    src="$(find "$work/x" -type f -name "$part" | head -1)"
    [ -n "$src" ] || { echo "$name: $part not in archive" >&2; rm -rf "$work"; return 1; }
    mv "$src" "$dest/$part"
  done
  rm -rf "$work"
  chown -R "$GAME_USER:$GAME_USER" "$dest"
  say "$name: installed ($(du -sh "$dest" | cut -f1))"
}

say "installing tools"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends unrar unzip nginx >/dev/null

mkdir -p "$SERVER_DIR/usermaps"
for entry in "${MAPS[@]}"; do
  IFS='|' read -r name url sha <<<"$entry"
  install_map "$name" "$url" "$sha"
done

say "web server for client downloads (port $WEB_PORT)"
# The game directory is 750 cod4:cod4. nginx needs to read through it, so it
# joins the group rather than the directory opening up to everyone.
usermod -aG "$GAME_USER" "$WEB_USER"
cat > /etc/nginx/sites-available/cod4-downloads <<EOF
# CoD4X fast download. The client asks the server for a file, the server
# answers with sv_wwwBaseURL/<path>, and the path is exactly the one relative
# to the game root: usermaps/mp_x/mp_x.ff, mods/foo/mod.ff. So the web root is
# the game root and only those shapes are answered. Everything else - configs,
# player databases, logs - is 404 regardless of permissions.
server {
    listen $WEB_PORT default_server;
    listen [::]:$WEB_PORT default_server;
    server_name _;
    root $SERVER_DIR;
    access_log /var/log/nginx/cod4-downloads.log;

    location ~ ^/(usermaps|mods)/[^/]+/[^/]+\.(ff|iwd)$ {
        try_files \$uri =404;
    }

    # Directory listings as JSON, so a client can find out what maps and mods
    # exist and fetch them ahead of time instead of at the moment the rotation
    # reaches one. Only the two levels of usermaps/ and mods/ are listed; the
    # listing shows a mod's configs/ but the location above refuses to serve it.
    location ~ ^/(usermaps|mods)/$ {
        autoindex on;
        autoindex_format json;
    }
    location ~ ^/(usermaps|mods)/[^/]+/$ {
        autoindex on;
        autoindex_format json;
    }

    location / {
        return 404;
    }
}
EOF
ln -sf /etc/nginx/sites-available/cod4-downloads /etc/nginx/sites-enabled/cod4-downloads
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
# Only the download port is open; an earlier install on port 80 loses its rule.
[ "$WEB_PORT" = 80 ] || ufw delete allow 80/tcp >/dev/null 2>&1 || true
ufw allow "$WEB_PORT/tcp" >/dev/null

say "installed maps:"
for d in "$SERVER_DIR"/usermaps/*/; do
  [ -d "$d" ] && printf '    %s\n' "$(basename "$d")"
done
say "clients will be sent to http://$(hostname -I | awk '{print $1}'):$WEB_PORT/usermaps/... - now run configure.sh"
