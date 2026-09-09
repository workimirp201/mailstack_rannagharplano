#!/usr/bin/env bash
# =============================================================================
#  /opt/mailstack/bin/patroni-callback.sh
#
#  Patroni runs this on every role change:
#        patroni-callback.sh <action> <role> <scope>
#  e.g.  patroni-callback.sh on_role_change master rannagharplano
#
#  WHAT IT IS FOR
#  Patroni makes the DATABASE failover automatic. HAProxy makes Stalwart's and
#  Roundcube's connection to the database automatic. Neither of those moves the
#  CLIENT-FACING names, so if the node users are pointed at is the one that
#  died, they would still be stranded.
#
#  This closes that gap: whichever node Patroni promotes rewrites mail.,
#  webmail. and db. to point at itself. Patroni's leader lock guarantees exactly
#  one node runs this at a time, so there is no race and no second election to
#  get wrong.
#
#  Runs as the postgres user, so it reads its own tiny 0640 root:postgres
#  credential file rather than the root-owned .env.
# =============================================================================

set -uo pipefail

CONF=/etc/mailstack/dns-failover.env
LOG=/var/log/mailstack/dns-failover.log

ACTION="${1:-}"
ROLE="${2:-}"
SCOPE="${3:-}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
say() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${ROLE:-?}" "$*" >> "$LOG" 2>/dev/null
        logger -t mailstack-dns "$*" 2>/dev/null || true; }

[ -r "$CONF" ] || { say "FATAL: $CONF unreadable"; exit 0; }
# shellcheck disable=SC1090
. "$CONF"

: "${DNS_FAILOVER_ENABLED:=no}"
[ "$DNS_FAILOVER_ENABLED" = "yes" ] || { say "DNS failover disabled; nothing to do"; exit 0; }

# Only the node that just became the leader touches DNS. Demotions do nothing —
# the newly promoted node is responsible for claiming the records.
case "$ACTION::$ROLE" in
  on_role_change::master|on_role_change::primary) ;;
  *) say "no action for action=$ACTION role=$ROLE scope=$SCOPE"; exit 0 ;;
esac

say "promoted — claiming client endpoints for ${SELF_IP}"

# -----------------------------------------------------------------------------
cf_api() {   # cf_api METHOD PATH [BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS --max-time 20 -X "$method" \
      "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${DNS_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -fsS --max-time 20 -X "$method" \
      "https://api.cloudflare.com/client/v4${path}" \
      -H "Authorization: Bearer ${DNS_API_TOKEN}"
  fi
}

update_cloudflare() {
  local fqdn="$1" rec_id current
  local resp
  resp=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=A&name=${fqdn}") || {
    say "ERROR: Cloudflare lookup failed for ${fqdn}"; return 1; }

  rec_id=$(printf '%s' "$resp"  | jq -r '.result[0].id // empty')
  current=$(printf '%s' "$resp" | jq -r '.result[0].content // empty')

  if [ -z "$rec_id" ]; then
    say "ERROR: no A record for ${fqdn} — create it once by hand, then failover can move it"
    return 1
  fi
  if [ "$current" = "$SELF_IP" ]; then
    say "${fqdn} already points at ${SELF_IP}"
    return 0
  fi

  if cf_api PATCH "/zones/${CF_ZONE_ID}/dns_records/${rec_id}" \
       "$(jq -nc --arg ip "$SELF_IP" --argjson ttl "${DNS_TTL:-60}" \
            '{content:$ip, ttl:$ttl, proxied:false}')" >/dev/null; then
    say "${fqdn}: ${current} -> ${SELF_IP}"
  else
    say "ERROR: failed to update ${fqdn}"
    return 1
  fi
}

update_route53() {
  local fqdn="$1"
  command -v aws >/dev/null 2>&1 || { say "ERROR: aws CLI not installed"; return 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$R53_ZONE_ID" \
    --change-batch "$(jq -nc --arg n "$fqdn" --arg ip "$SELF_IP" --argjson ttl "${DNS_TTL:-60}" \
      '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$n,Type:"A",TTL:$ttl,ResourceRecords:[{Value:$ip}]}}]}')" \
    >/dev/null 2>&1 \
    && say "${fqdn} -> ${SELF_IP}" || { say "ERROR: route53 update failed for ${fqdn}"; return 1; }
}

# -----------------------------------------------------------------------------
rc=0
for name in ${DNS_FAILOVER_RECORDS:-}; do
  fqdn="${name}.${DOMAIN}"
  case "${DNS_PROVIDER:-manual}" in
    cloudflare) update_cloudflare "$fqdn" || rc=1 ;;
    route53)    update_route53    "$fqdn" || rc=1 ;;
    *)          say "provider '${DNS_PROVIDER:-manual}' has no updater — repoint ${fqdn} to ${SELF_IP} by hand"; rc=1 ;;
  esac
done

if [ "$rc" -eq 0 ]; then
  say "all endpoints claimed"
else
  say "WARNING: one or more records were not updated — clients may still be pointed at the old node"
fi

# Never fail the callback: a DNS problem must not stop or roll back a promotion
# that has already succeeded. The database is up either way.
exit 0
