# Dedicated server and control plane

This directory contains the public, credential-free deployment source for the
household CoD4X server and its private control plane. It does not contain game
data, player profiles, passwords, SSH keys, or RCON credentials.

The server runs CoD4X with the New Experience mod under systemd. The control
plane is one standard-library Python program that provides:

- a loopback-only web interface;
- an SSH-friendly `cod4ctl` command;
- map, mode, rules, player administration, progression and RCON controls;
- RCON-only per-player god mode, ADS aim lock and through-wall enemy markers.

## Install

Copy legally owned dedicated-server data into `/opt/cod4/main` and
`/opt/cod4/zone/english`. New Experience's nuke also references the retail
single-player radiation shellshock definitions. Build their small private
runtime zone locally, then stage it before running `configure.sh`:

```bash
COD4_DATA='/absolute/path/to/Call of Duty 4' \
  server/build-private-runtime-zone.sh /tmp/jgalbs-runtime-mod.ff
scp /tmp/jgalbs-runtime-mod.ff root@SERVER:/opt/cod4/private-assets/mod.ff
```

This requires OpenAssetTools' `Unlinker` and `Linker` under
`build/OpenAssetTools/build/bin/Release_x64`, or their paths in
`OAT_UNLINKER` and `OAT_LINKER`. The generated `mod.ff` contains retail data:
keep it private and never commit it or attach it to a public release.

On a new Ubuntu host, review the scripts and run:

```bash
sudo server/provision.sh
sudo COD4_PASSWORD='set-at-deploy-time' \
  COD4_RCON='set-at-deploy-time' \
  server/configure.sh
sudo server/maps.sh
sudo server/control.sh
sudo server/harden.sh
```

Secrets are accepted only at deployment time. `control.sh` installs the RCON
value into `/etc/cod4-control/rcon_password` with mode `0640`; the web service
runs as the unprivileged `cod4` account and never sends that value to a browser.
The web listener is fixed to `127.0.0.1:8787`, so no public admin port is opened.

From a packaged native client, simply run:

```bash
cod4 menu
```

The launcher creates the SSH tunnel and opens the browser. `cod4 menu stop`
closes it; `cod4 server status` and `cod4 server console` expose the same
backend without the website.

The same player powers are available over SSH as
`cod4ctl power SLOT {godmode,aimbot,wallhack} {on,off}`. They apply only to the
target's current server session and can always be revoked from the dashboard.

`maps.sh` currently installs checksum-pinned CoD4/IW3 builds of Rust,
Terminal, Highrise and Scrapyard. See [`MAPS.md`](MAPS.md) for the compatibility
rule and the status of Wasteland and Afghan.

## Test

```bash
python3 -m unittest server/test_cod4ctl.py server/test_patch_progression.py
bash -n server/*.sh
```

CoD4X probes for `steam_api.so` during startup even when this private server
uses no Steam identity features. Its "Steam is not going to work" line is
expected with `sv_authorizemode -1` and does not affect protocol-21 clients,
RCON, progression, or matches. Do not silence it with an untrusted replacement
library; install an authentic compatible Steam API only if Steam identity is
made an explicit server requirement.
