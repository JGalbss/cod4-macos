#!/usr/bin/env python3
"""Install the Josh bots into a mod directory on the game host and set up the controller service.

Run on the host as root, from a synced copy of server/jev-bot:

    python3 tools/deploy_live.py --mod /opt/cod4/mods/new_experience --vendor ../vendor/bot-warfare \
        --service --key-file /etc/cod4-control/jev-bots.env

What it does, each step idempotent:
  1. Backs up every mod file it touches to <mod>/jev-backup-<timestamp>/.
  2. Installs code/jev_bot.gsx and code/jev_bot_waypoints.gsx (the helper the CSV loader uses).
  3. Applies the same hooks the private lab copies use: start the fixture after code\\player::init,
     keep team balancing off Jev bots, capture reload ammo, expose the Search and Destroy defuse
     object. Each hook is guarded by jev_enabled, which stays 0 until the web panel turns it on.
  4. Copies Bot Warfare's waypoint CSVs to <mod>/scriptdata/waypoints/ (credit in LICENSE-NOTICE.md).
  5. With --service: writes /etc/systemd/system/jev-bots.service running the controller in live mode
     from this directory with /opt/node, reading TYPESAFE_API_KEY from --key-file.

The game reloads scripts on the next map load; a map_restart from the panel is enough.
"""
import argparse
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
sys.path.insert(0, str(PROJECT / 'lab'))
from remote_worker import capture_reload_ammo, expose_defuse_object, isolate_team_balance, start_fixture  # noqa: E402

UNIT = '''[Unit]
Description=Josh bots: Jev-driven CoD4 bots on the live server
After=network.target cod4.service
Wants=cod4.service

[Service]
Type=simple
User=root
WorkingDirectory={project}
EnvironmentFile={key_file}
ExecStart=/opt/node/bin/node --experimental-strip-types {project}/src/run.ts --live --brain jev --bots 8 --game-mode dm \\
  --telemetry {mod}/jev_telemetry.jsonl --rcon-port {port} --rcon-password-file {rcon_file} \\
  --waypoints-dir {mod}/scriptdata/waypoints
Restart=always
RestartSec=5
StandardOutput=append:/var/log/jev-bots.log
StandardError=append:/var/log/jev-bots.log

[Install]
WantedBy=multi-user.target
'''


def patch(path: Path, transform, backup: Path) -> str:
    source = path.read_text(errors='replace')
    if 'jev_enabled' in source or 'jev_bot::main' in source or 'sdDefuseObject' in source:
        return f'{path.name}: already patched'
    backup.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, backup / path.name)
    path.write_text(transform(source))
    return f'{path.name}: patched (backup in {backup})'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mod', type=Path, default=Path('/opt/cod4/mods/new_experience'))
    parser.add_argument('--vendor', type=Path, default=PROJECT.parent / 'vendor/bot-warfare')
    parser.add_argument('--service', action='store_true', help='write and enable the jev-bots systemd unit')
    parser.add_argument('--key-file', type=Path, default=Path('/etc/cod4-control/jev-bots.env'))
    parser.add_argument('--rcon-password-file', type=Path, default=Path('/etc/cod4-control/rcon_password'))
    parser.add_argument('--port', type=int, default=28961)
    args = parser.parse_args()
    mod = args.mod
    if not (mod / 'code/init.gsx').is_file():
        raise SystemExit(f'{mod} does not look like the mod (no code/init.gsx)')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    backup = mod / f'jev-backup-{stamp}'
    report = []

    for name in ('jev_bot.gsx', 'jev_bot_waypoints.gsx'):
        target = mod / 'code' / name
        if target.exists():
            backup.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, backup / name)
        shutil.copy2(PROJECT / 'game' / name, target)
        report.append(f'code/{name}: installed')

    report.append(patch(mod / 'code/init.gsx', start_fixture, backup))
    report.append(patch(mod / 'maps/mp/gametypes/_teams.gsx', isolate_team_balance, backup))
    report.append(patch(mod / 'code/player.gsx', capture_reload_ammo, backup))
    sd = mod / 'maps/mp/gametypes/sd.gsx'
    if sd.is_file() and 'sdDefuseObject' not in sd.read_text(errors='replace'):
        backup.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sd, backup / 'sd.gsx')
        expose_defuse_object(mod)
        report.append('sd.gsx: defuse object exposed')

    waypoints = mod / 'scriptdata/waypoints'
    waypoints.mkdir(parents=True, exist_ok=True)
    copied = 0
    for csv in sorted((args.vendor / 'scriptdata/waypoints').glob('*_wp.csv')):
        shutil.copy2(csv, waypoints / csv.name)
        copied += 1
    notice = args.vendor / 'LICENSE-NOTICE.md'
    if notice.is_file():
        shutil.copy2(notice, waypoints / 'LICENSE-NOTICE.md')
    report.append(f'scriptdata/waypoints: {copied} maps')

    if args.service:
        if not args.key_file.is_file():
            raise SystemExit(f'{args.key_file} is missing; create it with TYPESAFE_API_KEY=... (mode 0600)')
        Path('/var/lib/jev-bots').mkdir(parents=True, exist_ok=True)
        unit = Path('/etc/systemd/system/jev-bots.service')
        unit.write_text(UNIT.format(project=PROJECT, key_file=args.key_file, mod=mod, port=args.port, rcon_file=args.rcon_password_file))
        report.append(f'{unit}: written (systemctl daemon-reload && systemctl enable --now jev-bots)')

    print('\n'.join(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
