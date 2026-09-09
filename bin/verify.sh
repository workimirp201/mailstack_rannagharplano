#!/usr/bin/env bash
# /opt/mailstack/bin/verify.sh — read-only health sweep for one node.
# Exit code 0 = everything green.

set -uo pipefail
MAILSTACK_DIR="${MAILSTACK_DIR:-/opt/mailstack}"
# shellcheck source=../lib/common.sh
. "$MAILSTACK_DIR/lib/common.sh"
set +e
load_env

PATRONI_CONFIG=/etc/patroni/patroni.yml
TLS_DIR=/etc/mailstack/tls
FAILED=0
chk() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else warn "$l"; FAILED=$((FAILED+1)); fi; }

printf '\n===== %s / %s =====\n\n' "$NODE_NAME" "$SELF_HOST"

# ------------------------------------------------------------------ services --
log "Services"
for s in etcd patroni haproxy garage stalwart nginx "php${PHP_VERSION}-fpm"; do
  systemctl list-unit-files 2>/dev/null | grep -q "^${s}" || continue
  chk "$s active" systemctl is-active --quiet "$s"
done

# ---------------------------------------------------------------------- etcd --
log "etcd (the thing that makes failover automatic)"
if systemctl is-active --quiet etcd; then
  ETCDCTL_API=3 etcdctl \
    --endpoints="https://${MAIL1_IP}:${ETCD_CLIENT_PORT},https://${MAIL2_IP}:${ETCD_CLIENT_PORT},https://${MAIL3_IP}:${ETCD_CLIENT_PORT}" \
    --cacert="$TLS_DIR/ca.crt" \
    endpoint health --cluster -w table 2>&1 | sed 's/^/  /'
  healthy=$(ETCDCTL_API=3 etcdctl \
    --endpoints="https://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --cacert="$TLS_DIR/ca.crt" \
    endpoint health --cluster 2>&1 | grep -c 'is healthy')
  if [ "${healthy:-0}" -ge 2 ]; then
    ok "etcd quorum present ($healthy/3 healthy)"
  else
    warn "etcd has NO QUORUM ($healthy/3) — automatic failover is disabled and the cluster is read-only"
    FAILED=$((FAILED+1))
  fi
fi

# ------------------------------------------------------------------- patroni --
log "TLS material permissions (this broke etcd once — check it)"
if [ -f "$TLS_DIR/node.key" ]; then
  ls -l "$TLS_DIR" | sed 's/^/  /'
  if id -u etcd >/dev/null 2>&1; then
    sudo -u etcd test -r "$TLS_DIR/node.key" \
      && ok "the etcd user can read node.key" \
      || { warn "the etcd user CANNOT read node.key — run: sudo /opt/mailstack/deploy.sh fix-tls-perms"; FAILED=$((FAILED+1)); }
  fi
fi

log "PostgreSQL / Patroni"
if systemctl is-active --quiet patroni; then
  patronictl -c "$PATRONI_CONFIG" list 2>&1 | sed 's/^/  /'
  leaders=$(patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | grep -ci 'leader')
  members=$(patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | grep -cE '\| (mail1|mail2|mail3) ')
  [ "${leaders:-0}" -eq 1 ] && ok "exactly one leader" || { warn "expected 1 leader, found ${leaders:-0}"; FAILED=$((FAILED+1)); }
  [ "${members:-0}" -eq 3 ] && ok "all 3 members visible" || warn "only ${members:-0} member(s) visible"

  printf '  --- replication lag ---\n'
  sudo -u postgres psql -h /var/run/postgresql -qc \
    "SELECT application_name, client_addr, state, sync_state,
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
       FROM pg_stat_replication;" 2>/dev/null | sed 's/^/  /'
fi

log "Local HAProxy -> current primary"
chk "127.0.0.1:${PG_PROXY_PORT} accepting connections" tcp_open 127.0.0.1 "$PG_PROXY_PORT" 4
if PGPASSWORD="$PG_APP_PASSWORD" psql -h 127.0.0.1 -p "$PG_PROXY_PORT" -U "$PG_APP_USER" \
     -d "$PG_DATABASE" -tAc "SELECT NOT pg_is_in_recovery();" 2>/dev/null | grep -q '^t$'; then
  ok "the proxy reaches a WRITABLE primary"
else
  warn "the proxy is not reaching a writable primary — mail will be read-only"
  FAILED=$((FAILED+1))
fi
printf '  --- haproxy backend states ---\n'
curl -fsS "http://127.0.0.1:7000/;csv" 2>/dev/null \
  | awk -F, '/postgres_primary/ && $2!="FRONTEND" {printf "  %-8s %s\n", $2, $18}' || true

# -------------------------------------------------------------------- garage --
log "Garage"
G=(garage -c /etc/garage.toml)
if systemctl is-active --quiet garage; then
  "${G[@]}" status 2>&1 | sed 's/^/  /'
  up=$("${G[@]}" status 2>/dev/null | grep -c '^[0-9a-f]\{16\}')
  [ "${up:-0}" -ge 3 ] && ok "all 3 Garage nodes visible" || { warn "only ${up:-0} Garage node(s)"; FAILED=$((FAILED+1)); }
  printf '  --- layout (check "Effective capacity") ---\n'
  "${G[@]}" layout show 2>&1 | grep -iE 'zone redundancy|effective capacity|usable capacity' | sed 's/^/  /'
  printf '  --- admin health ---\n'
  curl -fsS -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
       "http://127.0.0.1:${GARAGE_ADMIN_PORT}/health" 2>&1 | sed 's/^/  /'; echo
  errs=$("${G[@]}" block list-errors 2>/dev/null | wc -l)
  [ "${errs:-0}" -le 1 ] && ok "no block errors" || warn "$errs block error line(s) — run: garage repair -a --yes blocks"
fi

# ------------------------------------------------------------------ stalwart --
log "Stalwart"
if systemctl is-active --quiet stalwart; then
  for p in 25 465 993; do
    tcp_open 127.0.0.1 "$p" 3 && ok "  listening on $p" || warn "  NOT listening on $p"
  done
  tcp_open 127.0.0.1 "$STALWART_HTTPS_BACKEND_PORT" 3 \
    && ok "  HTTPS backend on ${STALWART_HTTPS_BACKEND_PORT} (behind nginx SNI)" \
    || warn "  HTTPS backend not on ${STALWART_HTTPS_BACKEND_PORT} — SNI routing will not work"
  printf '  --- errors in the last hour ---\n'
  journalctl -u stalwart --since "1 hour ago" -p err --no-pager -n 15 2>/dev/null | sed 's/^/  /'
fi

# ------------------------------------------------------------------- webmail --
log "Webmail"
if systemctl is-active --quiet nginx; then
  chk "nginx config valid" nginx -t
  chk "webmail backend on ${WEBMAIL_BACKEND_PORT}" tcp_open 127.0.0.1 "$WEBMAIL_BACKEND_PORT" 3
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --resolve "${WEBMAIL_HOSTNAME}:443:127.0.0.1" \
         "https://${WEBMAIL_HOSTNAME}/" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && ok "webmail returns 200 locally" || warn "webmail returned HTTP $code locally"
  if PGPASSWORD="$ROUNDCUBE_DB_PASSWORD" psql -h 127.0.0.1 -p "$PG_PROXY_PORT" \
       -U "$ROUNDCUBE_DB_USER" -d "$ROUNDCUBE_DB" -tAc "SELECT 1 FROM users LIMIT 1" >/dev/null 2>&1; then
    ok "roundcube database reachable"
  else
    warn "roundcube database not reachable (harmless if no user has logged in yet)"
  fi
  printf '  installed Roundcube: %s\n' \
    "$(grep -oP "define\('RCMAIL_VERSION', '\K[^']+" /var/www/roundcube/program/include/iniset.php 2>/dev/null || echo unknown)"
  printf '  latest upstream:     %s\n' \
    "$(curl -fsS --max-time 8 https://api.github.com/repos/roundcube/roundcubemail/releases/latest 2>/dev/null | jq -r '.tag_name // "unknown"')"
  printf '  ^ Roundcube does NOT auto-update. If these differ, upgrade it.\n'
fi

# ----------------------------------------------------------------------- TLS --
log "TLS — SNI routing must send each name to a different terminator"
for h in "$WEBMAIL_HOSTNAME" "$PUBLIC_HOSTNAME"; do
  printf '  %s:\n' "$h"
  echo | timeout 10 openssl s_client -connect "${SELF_IP}:443" -servername "$h" 2>/dev/null \
    | openssl x509 -noout -subject -enddate 2>/dev/null | sed 's/^/    /' \
    || printf '    could not retrieve certificate\n'
done
printf '  993 (Stalwart direct):\n'
echo | timeout 10 openssl s_client -connect "${PUBLIC_HOSTNAME}:993" -servername "$PUBLIC_HOSTNAME" 2>/dev/null \
  | openssl x509 -noout -subject -enddate 2>/dev/null | sed 's/^/    /' || true

# ----------------------------------------------------------------------- DNS --
log "DNS"
printf '  MX:      %s\n' "$(dig +short MX "$DOMAIN" | tr '\n' ' ')"
printf '  SPF:     %s\n' "$(dig +short TXT "$DOMAIN" | grep -i spf1 | head -1)"
printf '  DMARC:   %s\n' "$(dig +short TXT "_dmarc.$DOMAIN" | head -1)"
printf '  mail:    %s\n' "$(dig +short "$PUBLIC_HOSTNAME"  | head -1)"
printf '  webmail: %s\n' "$(dig +short "$WEBMAIL_HOSTNAME" | head -1)"
printf '  db:      %s\n' "$(dig +short "$DB_HOSTNAME"      | head -1)"
printf '  --- forward/reverse match (FCrDNS) ---\n'
for ip in "$MAIL1_IP" "$MAIL2_IP" "$MAIL3_IP"; do
  ptr=$(dig +short -x "$ip" | head -1); fwd=$(dig +short "${ptr%.}" | head -1)
  if [ "$fwd" = "$ip" ]; then printf '  PASS  %-16s <-> %s\n' "$ip" "${ptr%.}"
  else printf '  FAIL  %-16s ->  %s -> %s\n' "$ip" "${ptr%.}" "${fwd:-NXDOMAIN}"; fi
done

# ---------------------------------------------------------------------- disk --
log "Disk and memory"
df -h / /var/lib/garage /var/lib/postgresql 2>/dev/null | sed 's/^/  /'
du -sh /var/lib/garage/data /var/lib/garage/meta /var/lib/etcd 2>/dev/null | sed 's/^/  /'
free -h | sed 's/^/  /'
usedpct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "${usedpct:-0}" -lt 80 ] && ok "root filesystem ${usedpct}% used" \
  || { warn "root filesystem ${usedpct}% used — a full disk corrupts LMDB and stops PostgreSQL"; FAILED=$((FAILED+1)); }

printf '\n'
[ "$FAILED" -eq 0 ] && ok "verify.sh: all checks passed" || warn "verify.sh: $FAILED check(s) failed"
exit "$FAILED"
