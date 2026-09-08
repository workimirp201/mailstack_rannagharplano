#!/usr/bin/env bash
# =============================================================================
#  /opt/mailstack/bin/backup.sh          REVISION 3
#
#  One encrypted bundle per run in $BACKUP_DIR, pruned after
#  $BACKUP_RETENTION_DAYS.
#
#  WHY REPLICATION IS NOT A BACKUP
#  Garage replicates a DELETE as faithfully as a PUT. Patroni streams a
#  `DROP TABLE` to both standbys in milliseconds. Replication protects you from
#  a node dying. It does nothing about a mistake, a bad upgrade, or a
#  compromised admin account — those propagate perfectly. Only a point-in-time
#  copy the running system cannot reach does.
#
#  Run it on ALL THREE nodes. The database dump goes through the local HAProxy,
#  so whichever node runs it always reaches the current primary — there is no
#  "run this on the primary" step to get wrong after a failover.
# =============================================================================

set -euo pipefail
umask 077
MAILSTACK_DIR="${MAILSTACK_DIR:-/opt/mailstack}"
# shellcheck source=../lib/common.sh
. "$MAILSTACK_DIR/lib/common.sh"
load_env
need_root

TLS_DIR=/etc/mailstack/tls
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
WORK=$(mktemp -d /tmp/mailstack-backup.XXXXXX)
OUT="$BACKUP_DIR/${NODE_NAME}-${STAMP}.tar.gz.enc"
trap 'rm -rf "$WORK"' EXIT
install -d -m 0700 "$BACKUP_DIR"

log "1/6  Node configuration and secrets"
install -d -m 0700 "$WORK/config"
cp -a "$ENV_FILE"                       "$WORK/config/env"                2>/dev/null || true
cp -a /etc/garage.toml                  "$WORK/config/"                   2>/dev/null || true
cp -a /etc/stalwart/config.json         "$WORK/config/"                   2>/dev/null || true
cp -a /etc/stalwart/stalwart.env        "$WORK/config/"                   2>/dev/null || true
cp -a /etc/patroni/patroni.yml          "$WORK/config/"                   2>/dev/null || true
cp -a /etc/default/etcd                 "$WORK/config/etcd.default"       2>/dev/null || true
cp -a /etc/haproxy/haproxy.cfg          "$WORK/config/"                   2>/dev/null || true
cp -a /etc/mailstack/dns-failover.env   "$WORK/config/"                   2>/dev/null || true
cp -a /var/www/roundcube/config/config.inc.php "$WORK/config/roundcube-config.inc.php" 2>/dev/null || true
cp -a /etc/nginx/sites-available/webmail       "$WORK/config/nginx-webmail.conf"       2>/dev/null || true
cp -a /etc/nginx/stream-enabled/mailstack.conf "$WORK/config/nginx-stream.conf"        2>/dev/null || true
cp -a "$MAILSTACK_DIR/pki"              "$WORK/config/pki"                2>/dev/null || true
cp -a "$TLS_DIR"                        "$WORK/config/tls"                2>/dev/null || true
systemctl cat etcd patroni haproxy garage stalwart nginx > "$WORK/config/systemd-units.txt" 2>/dev/null || true

log "2/6  Stalwart settings, accounts, domains and DKIM keys"
# The single most important file here. `snapshot` exports the live server state
# as a replayable apply plan: domains, accounts, roles, listeners, TLS, spam
# rules AND the DKIM private keys. Lose those keys and every signature you ever
# made becomes unverifiable and you must regenerate and republish DNS.
if command -v stalwart-cli >/dev/null 2>&1; then
  STALWART_URL="https://${PUBLIC_HOSTNAME}" \
  STALWART_USER="${STALWART_ADMIN_USER}" \
  STALWART_PASSWORD="${STALWART_ADMIN_PASSWORD}" \
    stalwart-cli snapshot > "$WORK/stalwart-snapshot.ndjson" 2>"$WORK/stalwart-snapshot.err" \
    || warn "stalwart-cli snapshot failed — see the .err file in the bundle"
else
  warn "stalwart-cli not installed; skipping the settings snapshot"
fi

log "3/6  PostgreSQL (through the local proxy, so it always hits the primary)"
if PGPASSWORD="$PG_APP_PASSWORD" psql -h 127.0.0.1 -p "$PG_PROXY_PORT" -U "$PG_APP_USER" \
     -d "$PG_DATABASE" -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q '^t$'; then
  PGPASSWORD="$PG_APP_PASSWORD" pg_dump -h 127.0.0.1 -p "$PG_PROXY_PORT" -U "$PG_APP_USER" \
      -Fc -Z6 "$PG_DATABASE" > "$WORK/stalwart-db.dump"
  ok "stalwart dump: $(du -h "$WORK/stalwart-db.dump" | cut -f1)"
  PGPASSWORD="$ROUNDCUBE_DB_PASSWORD" pg_dump -h 127.0.0.1 -p "$PG_PROXY_PORT" -U "$ROUNDCUBE_DB_USER" \
      -Fc -Z6 "$ROUNDCUBE_DB" > "$WORK/roundcube-db.dump" 2>/dev/null \
    && ok "roundcube dump: $(du -h "$WORK/roundcube-db.dump" | cut -f1)" \
    || warn "roundcube dump skipped"
  sudo -u postgres pg_dumpall -h /var/run/postgresql --globals-only 2>/dev/null \
      > "$WORK/pg-globals.sql" || true
else
  echo "could not reach a writable primary through 127.0.0.1:${PG_PROXY_PORT}" > "$WORK/pg-skipped.txt"
  warn "no writable primary reachable — database dump skipped on this node"
fi

log "4/6  etcd snapshot (the cluster's leader state and Patroni configuration)"
if command -v etcdctl >/dev/null 2>&1 && systemctl is-active --quiet etcd; then
  ETCDCTL_API=3 etcdctl \
    --endpoints="https://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --cacert="$TLS_DIR/ca.crt" --cert="$TLS_DIR/node.crt" --key="$TLS_DIR/node.key" \
    snapshot save "$WORK/etcd-snapshot.db" >/dev/null 2>&1 \
    && ok "etcd snapshot taken" || warn "etcd snapshot failed"
  patronictl -c /etc/patroni/patroni.yml list > "$WORK/patroni-state.txt" 2>&1 || true
fi

log "5/6  Garage metadata snapshot and cluster state"
if systemctl is-active --quiet garage; then
  garage -c /etc/garage.toml meta snapshot --all 2>/dev/null | sed 's/^/    /' \
    || warn "on-demand meta snapshot unavailable; relying on metadata_auto_snapshot_interval"
  LATEST=$(ls -1dt /var/lib/garage/snapshots/*/ 2>/dev/null | head -1 || true)
  if [ -n "${LATEST:-}" ]; then
    tar -C "$(dirname "${LATEST%/}")" -cf "$WORK/garage-meta-snapshot.tar" "$(basename "${LATEST%/}")"
    ok "captured $(basename "${LATEST%/}")"
  fi
  {
    garage -c /etc/garage.toml layout show
    garage -c /etc/garage.toml status
    garage -c /etc/garage.toml bucket info "$GARAGE_BUCKET"
    garage -c /etc/garage.toml stats
  } > "$WORK/garage-state.txt" 2>&1 || true
fi

log "6/6  Encrypting"
# The blob payload itself (up to ~18 GB) is NOT in this bundle. It is covered by
# the separate off-site object sync — see the runbook's backup section.
tar -C "$WORK" -czf - . \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
      -pass env:BACKUP_PASSPHRASE -out "$OUT"
chmod 600 "$OUT"
ok "wrote $OUT ($(du -h "$OUT" | cut -f1))"

find "$BACKUP_DIR" -name "${NODE_NAME}-*.tar.gz.enc" -mtime "+${BACKUP_RETENTION_DAYS}" -print -delete

cat <<EOF

  RESTORE (rehearse this quarterly — an untested backup is a rumour):
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \\
        -pass env:BACKUP_PASSPHRASE -in $OUT | tar -xzf - -C /tmp/restore

  THIS BUNDLE IS STILL ON THE MACHINE IT PROTECTS. Ship it somewhere else:
      rsync -az $OUT backup-host:/srv/mailstack-backups/${NODE_NAME}/

  BACKUP_PASSPHRASE lives in .env, and .env is INSIDE this bundle. Keep the
  passphrase in a password manager, not only here.
EOF
