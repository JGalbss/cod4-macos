#!/bin/bash
# Protect player data and keep the server up.
#
# ne_db/players/*.db holds per-player mod settings and TrueSkill rating, not
# rank - CoD4 keeps rank in each client's own mpdata. The mod buffers those
# fields in memory and flushes them on disconnect and at game end, not
# continuously, so a mid-match crash costs changes since the last map change.
# Two mitigations:
#   1. systemd restarts the server immediately, so a crash is a blip not an outage
#   2. ne_db is snapshotted hourly and kept for a week, so a bad write, a disk
#      problem, or a mistaken wipe is recoverable
set -euo pipefail

SERVER_DIR=/opt/cod4
BACKUP_DIR=/var/backups/cod4

mkdir -p "$BACKUP_DIR" "$SERVER_DIR/ne_db/players"
chown -R cod4:cod4 "$SERVER_DIR/ne_db"

cat > /usr/local/bin/cod4-backup <<'EOF'
#!/bin/bash
# Snapshot player settings and skill. Cheap: the whole database is a few hundred KB.
set -euo pipefail
SRC=/opt/cod4/ne_db
DEST=/var/backups/cod4
[ -d "$SRC" ] || exit 0
STAMP=$(date +%Y%m%d-%H%M)
tar -czf "$DEST/ne_db-$STAMP.tar.gz" -C /opt/cod4 ne_db 2>/dev/null
# Keep a week of hourly snapshots.
find "$DEST" -name 'ne_db-*.tar.gz' -mtime +7 -delete 2>/dev/null
EOF
chmod +x /usr/local/bin/cod4-backup

cat > /etc/systemd/system/cod4-backup.service <<'EOF'
[Unit]
Description=Back up CoD4 player stats
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cod4-backup
EOF

cat > /etc/systemd/system/cod4-backup.timer <<'EOF'
[Unit]
Description=Hourly CoD4 player stats backup
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cod4-backup.timer >/dev/null 2>&1
/usr/local/bin/cod4-backup || true

echo "==> backups: hourly, 7 day retention, in $BACKUP_DIR"
echo "==> restart policy: $(grep -c 'Restart=always' /etc/systemd/system/cod4.service 2>/dev/null || echo 0) (1 = on)"
