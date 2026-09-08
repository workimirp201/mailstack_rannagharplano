#!/usr/bin/env bash
# =============================================================================
#  /opt/mailstack/deploy.sh          REVISION 3
#
#  3-node Stalwart mail system for rannagharplano.com with:
#    * Garage      v2.4.0    3-zone replicated S3 object store
#    * PostgreSQL  16        via Patroni + etcd  -> AUTOMATED failover
#    * HAProxy               local :5433 always points at the current primary
#    * Stalwart    v0.16.19  active-active on all three nodes
#    * Roundcube   1.7.x     webmail on all three nodes, behind nginx SNI
#
#  Target OS: Ubuntu 24.04 LTS, x86_64
#
#  ORDER OF OPERATIONS  (the script refuses to run phases out of order where
#                        it can detect it):
#
#     mail2:  ./deploy.sh gen-secrets
#     ---     copy .env to mail1 and mail3, change NODE_NAME only
#     all:    ./deploy.sh preflight
#     all:    ./deploy.sh prep
#     mail2:  ./deploy.sh pki                 -> scp the printed bundles
#     1 & 3:  ./deploy.sh pki-import /root/pki-mailN.tar.gz
#     all:    ./deploy.sh garage
#     1 & 3:  garage -c /etc/garage.toml node id
#     mail2:  ./deploy.sh garage-cluster      -> paste S3 keys into .env everywhere
#     all:    ./deploy.sh etcd
#     mail2:  ./deploy.sh etcd-auth           (once, after all three are up)
#     mail2:  ./deploy.sh patroni             (bootstraps the cluster)
#     1 & 3:  ./deploy.sh patroni             (clones from the leader)
#     all:    ./deploy.sh haproxy
#     mail2:  ./deploy.sh stalwart            -> run the setup wizard
#     mail2:  ./deploy.sh stalwart            (again, to externalise secrets)
#     1 & 3:  ./deploy.sh stalwart
#     all:    ./deploy.sh webmail
#     all:    ./deploy.sh verify
#
#  No secret is printed except the Garage S3 key pair, which you must copy
#  into .env once.
# =============================================================================

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAILSTACK_DIR="$SCRIPT_DIR"
export MAILSTACK_DIR
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

GARAGE_CONFIG=/etc/garage.toml
GARAGE_META=/var/lib/garage/meta
GARAGE_DATA=/var/lib/garage/data
GARAGE_SNAP=/var/lib/garage/snapshots
GARAGE_BIN=/usr/local/bin/garage

STALWART_ETC=/etc/stalwart
STALWART_CONFIG=$STALWART_ETC/config.json
STALWART_ENVFILE=$STALWART_ETC/stalwart.env
STALWART_BIN=/usr/local/bin/stalwart

ETCD_BIN=/usr/local/bin/etcd
ETCD_DATA=/var/lib/etcd
PATRONI_CONFIG=/etc/patroni/patroni.yml

PKI_DIR=$MAILSTACK_DIR/pki
TLS_DIR=/etc/mailstack/tls

RC_ROOT=/var/www/roundcube
RC_DATA=/var/lib/roundcube


# =============================================================================
#  gen-secrets
# =============================================================================
cmd_gen_secrets() {
  need_root
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found; cp env.example .env first"
  chmod 600 "$ENV_FILE"; chown root:root "$ENV_FILE"

  _set() {
    local key="$1" val="$2"
    if grep -qE "^${key}=CHANGE_ME[[:space:]]*$" "$ENV_FILE"; then
      python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
for line in open(path):
    lines.append(f"{key}={val}\n" if line.rstrip("\n") == f"{key}=CHANGE_ME" else line)
open(path, "w").write("".join(lines))
PY
      printf '  generated %s\n' "$key"
    else
      printf '  kept      %s\n' "$key"
    fi
  }

  log "Generating secrets into $ENV_FILE (values are never printed)"
  _set PG_APP_PASSWORD                   "$(gen_pass)"
  _set PG_REPL_PASSWORD                  "$(gen_pass)"
  _set PG_SUPER_PASSWORD                 "$(gen_pass)"
  _set PG_REWIND_PASSWORD                "$(gen_pass)"
  _set PATRONI_REST_PASSWORD             "$(gen_pass)"
  _set ETCD_INITIAL_TOKEN                "$(gen_hex)"
  _set ETCD_ROOT_PASSWORD                "$(gen_pass)"
  _set ETCD_PATRONI_PASSWORD             "$(gen_pass)"
  _set GARAGE_RPC_SECRET                 "$(gen_hex)"
  _set GARAGE_ADMIN_TOKEN                "$(gen_b64)"
  _set GARAGE_METRICS_TOKEN              "$(gen_b64)"
  _set STALWART_BOOTSTRAP_ADMIN_PASSWORD "$(gen_pass)"
  _set STALWART_ADMIN_PASSWORD           "$(gen_pass)"
  _set STALWART_CLUSTER_SECRET           "$(gen_hex)"
  _set STALWART_RELAY_PASSWORD           "$(gen_pass)"
  _set ROUNDCUBE_DB_PASSWORD             "$(gen_pass)"
  _set ROUNDCUBE_DES_KEY                 "$(openssl rand -hex 12)"   # exactly 24 chars
  _set BACKUP_PASSPHRASE                 "$(gen_pass)"

  chmod 600 "$ENV_FILE"
  ok "done. S3_ACCESS_KEY / S3_SECRET_KEY are filled in later by garage-cluster."
  cat <<EOF

NEXT — copy this exact file to the other two nodes, then edit ONLY NODE_NAME:
    scp $ENV_FILE root@$MAIL1_IP:/opt/mailstack/.env
    scp $ENV_FILE root@$MAIL3_IP:/opt/mailstack/.env
EOF
}


# =============================================================================
#  preflight
# =============================================================================
cmd_preflight() {
  load_env
  log "Identity"
  printf '    %s  host=%s  ip=%s  zone=%s\n' "$NODE_NAME" "$SELF_HOST" "$SELF_IP" "$SELF_ZONE"

  log "OS / arch"
  grep -q 'VERSION_ID="24.04"' /etc/os-release && ok "Ubuntu 24.04 LTS" \
    || warn "not Ubuntu 24.04: $(. /etc/os-release; echo "$PRETTY_NAME")"
  [ "$(uname -m)" = "x86_64" ] || warn "arch $(uname -m) — adjust download URLs"

  log "Hostname"
  local hn; hn=$(hostnamectl --static)
  [ "$hn" = "$SELF_HOST" ] && ok "$hn" || warn "static hostname '$hn' != '$SELF_HOST' (prep fixes this)"

  log "Egress IP"
  local seen; seen=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo unknown)
  printf '    seen=%s  configured=%s\n' "$seen" "$SELF_IP"
  [ "$seen" = "unknown" ] || [ "$seen" = "$SELF_IP" ] || warn "egress IP differs from .env"

  log "Clock"
  timedatectl show -p NTPSynchronized --value | grep -q yes \
    && ok "synchronised" || warn "NOT synchronised (prep configures timesyncd)"

  log "Disk"
  df -h / | tail -1 | awk '{printf "    / size=%s used=%s avail=%s\n",$2,$3,$4}'
  local availg; availg=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "$availg" -ge 40 ] && ok "${availg}G free" \
    || warn "only ${availg}G free — the plan reserves 20G for Garage data alone"

  log "Memory"
  free -m | awk '/^Mem:/{printf "    total=%sMB available=%sMB\n",$2,$7}'
  local memtot; memtot=$(free -m | awk '/^Mem:/{print $2}')
  [ "$memtot" -ge 1800 ] || warn "under 2 GB RAM: Stalwart + PostgreSQL + Garage + etcd + PHP is tight"

  log "Inter-node latency — decides synchronous replication and failover target"
  local ip rtt
  for ip in $PEER_IPS; do
    rtt=$(ping -c 5 -q -W 3 "$ip" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')
    if [ -n "$rtt" ]; then printf '    %-16s avg RTT %s ms\n' "$ip" "$rtt"
    else printf '    %-16s ICMP blocked\n' "$ip"; fi
  done
  printf '    If mail2<->mail3 is under ~40 ms you can set PG_SYNCHRONOUS_MODE=on\n'
  printf '    for zero-data-loss failover. Over that, leave it off.\n'

  log "Ports that must be reachable between the three nodes"
  for ip in $PEER_IPS; do
    local p
    for p in "$GARAGE_RPC_PORT" "$STALWART_ZENOH_PORT" "$ETCD_CLIENT_PORT" "$ETCD_PEER_PORT" "$PATRONI_REST_PORT" "$PG_PORT"; do
      if tcp_open "$ip" "$p" 4; then ok "  $ip:$p"; else warn "  $ip:$p NOT reachable yet"; fi
    done
  done

  log "Outbound TCP 25"
  if tcp_open gmail-smtp-in.l.google.com 25 8; then
    ok "open"
    printf '    banner: '; timeout 10 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25; head -1 <&3' 2>/dev/null || echo "(no banner)"
    printf '    ^ if that banner does not say google, your ISP is intercepting port 25.\n'
  else
    warn "BLOCKED — mail1/mail2 need a Linode ticket; mail3 can relay instead"
  fi

  log "Forward/reverse DNS (FCrDNS)"
  local i
  for i in "$MAIL1_IP" "$MAIL2_IP" "$MAIL3_IP"; do
    local ptr fwd
    ptr=$(dig +short -x "$i" 2>/dev/null | head -1)
    fwd=$(dig +short "${ptr%.}" 2>/dev/null | head -1)
    if [ -z "$ptr" ]; then warn "  $i has NO PTR"
    elif [ "$fwd" = "$i" ]; then ok "  $i <-> ${ptr%.}"
    else warn "  $i -> ${ptr%.} -> ${fwd:-NXDOMAIN}  (chain broken)"; fi
  done
  printf '    mail3 may legitimately show a frontiernet.net name — it relays\n'
  printf '    outbound through mail1/mail2 when MAIL3_DIRECT_OUTBOUND=no.\n'

  ok "preflight complete — read every WARN above before continuing"
}


# =============================================================================
#  prep
# =============================================================================
cmd_prep() {
  need_root; load_env

  log "Hostname"
  hostnamectl set-hostname "$SELF_HOST"
  if ! grep -qE "^127\.0\.1\.1[[:space:]]+${SELF_HOST}" /etc/hosts; then
    backup_once /etc/hosts
    sed -i "/^127\.0\.1\.1/d" /etc/hosts
    printf '127.0.1.1\t%s %s\n' "$SELF_HOST" "$NODE_NAME" >> /etc/hosts
  fi

  log "Base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
      curl wget jq unzip ca-certificates gnupg lsb-release \
      openssl dnsutils net-tools iproute2 iputils-ping mtr-tiny \
      systemd-timesyncd logrotate python3 python3-venv rsync \
      s3cmd swaks unattended-upgrades
  ok "installed"

  log "Unattended security upgrades"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  log "Time synchronisation"
  systemctl enable --now systemd-timesyncd
  timedatectl set-ntp true
  timedatectl status | sed 's/^/    /'

  log "Kernel + limits"
  write_file /etc/sysctl.d/60-mailstack.conf 0644 <<'EOF'
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.ip_local_port_range = 10240 65535
fs.file-max = 262144
vm.swappiness = 10
vm.overcommit_memory = 0
EOF
  sysctl --quiet -p /etc/sysctl.d/60-mailstack.conf
  write_file /etc/security/limits.d/60-mailstack.conf 0644 <<'EOF'
*  soft  nofile  65535
*  hard  nofile  65535
EOF

  log "Directories"
  install -d -m 0755 "$GARAGE_META" "$GARAGE_DATA" "$GARAGE_SNAP"
  install -d -m 0750 "$STALWART_ETC" /etc/patroni
  install -d -m 0700 "$PKI_DIR" "$BACKUP_DIR" "$ETCD_DATA"
  install -d -m 0755 /opt/garage /opt/stalwart /opt/webmail /etc/mailstack
  install -d -m 0750 "$TLS_DIR"

  log "Journal cap"
  mkdir -p /etc/systemd/journald.conf.d
  write_file /etc/systemd/journald.conf.d/60-mailstack.conf 0644 <<'EOF'
[Journal]
SystemMaxUse=1G
SystemKeepFree=2G
MaxRetentionSec=30day
EOF
  systemctl restart systemd-journald

  ok "node prepared"
}


# =============================================================================
#  pki   (mail2 generates everything; the others import a bundle)
# =============================================================================
cmd_pki() {
  need_root; load_env
  [ "$NODE_NAME" = "mail2" ] || die "run 'pki' on mail2, then 'pki-import' elsewhere"
  install -d -m 0700 "$PKI_DIR"

  if [ ! -f "$PKI_DIR/ca.key" ]; then
    log "Creating the internal CA (10 years)"
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
      -keyout "$PKI_DIR/ca.key" -out "$PKI_DIR/ca.crt" \
      -subj "/CN=mailstack-internal-ca/O=${DOMAIN}" 2>/dev/null
    chmod 600 "$PKI_DIR/ca.key"
  fi
  ok "CA present"

  # One certificate per node, usable as BOTH a server and a client cert, and
  # valid for 127.0.0.1 as well as the node's public name/IP. The 127.0.0.1 SAN
  # is what lets Stalwart connect through the local HAProxy to whichever node is
  # primary and still do full certificate verification.
  local n host ip
  for n in mail1 mail2 mail3; do
    case "$n" in
      mail1) host="$MAIL1_HOST"; ip="$MAIL1_IP" ;;
      mail2) host="$MAIL2_HOST"; ip="$MAIL2_IP" ;;
      mail3) host="$MAIL3_HOST"; ip="$MAIL3_IP" ;;
    esac
    [ -f "$PKI_DIR/$n.crt" ] && { ok "$n certificate exists"; continue; }
    log "Issuing certificate for $n"
    openssl req -newkey rsa:2048 -nodes \
      -keyout "$PKI_DIR/$n.key" -out "$PKI_DIR/$n.csr" \
      -subj "/CN=${host}/O=${DOMAIN}" 2>/dev/null
    openssl x509 -req -in "$PKI_DIR/$n.csr" -days 3650 \
      -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
      -out "$PKI_DIR/$n.crt" \
      -extfile <(printf 'subjectAltName=DNS:%s,DNS:%s,IP:%s,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n' \
                        "$host" "$DB_HOSTNAME" "$ip") 2>/dev/null
    rm -f "$PKI_DIR/$n.csr"
    chmod 600 "$PKI_DIR/$n.key"
  done

  log "Building per-node bundles"
  local b
  for n in mail1 mail3; do
    b="/root/pki-$n.tar.gz"
    tar -C "$PKI_DIR" -czf "$b" ca.crt "$n.crt" "$n.key"
    chmod 600 "$b"
  done
  _pki_install mail2

  cat <<EOF

Copy each bundle to its node, then import it there:

    scp /root/pki-mail1.tar.gz root@${MAIL1_IP}:/root/
    scp /root/pki-mail3.tar.gz root@${MAIL3_IP}:/root/

  on mail1:  cd /opt/mailstack && sudo ./deploy.sh pki-import /root/pki-mail1.tar.gz
  on mail3:  cd /opt/mailstack && sudo ./deploy.sh pki-import /root/pki-mail3.tar.gz
EOF
}

cmd_pki_import() {
  need_root; load_env
  local bundle="${1:-}"
  [ -n "$bundle" ] && [ -f "$bundle" ] || die "usage: ./deploy.sh pki-import /root/pki-${NODE_NAME}.tar.gz"
  install -d -m 0700 "$PKI_DIR"
  tar -C "$PKI_DIR" -xzf "$bundle"
  chmod 600 "$PKI_DIR/$NODE_NAME.key"
  _pki_install "$NODE_NAME"
  ok "PKI imported"
}

# Place the node's cert/key/CA where PostgreSQL, etcd and the system trust
# store expect them.
_pki_install() {
  local n="$1"
  install -d -m 0750 "$TLS_DIR"
  install -m 0644 "$PKI_DIR/ca.crt"   "$TLS_DIR/ca.crt"
  install -m 0644 "$PKI_DIR/$n.crt"   "$TLS_DIR/node.crt"
  install -m 0640 "$PKI_DIR/$n.key"   "$TLS_DIR/node.key"

  # PostgreSQL runs as postgres and refuses a key it does not own.
  if id -u postgres >/dev/null 2>&1; then
    install -o postgres -g postgres -m 0644 "$PKI_DIR/ca.crt" /var/lib/postgresql/ca.crt
    install -o postgres -g postgres -m 0644 "$PKI_DIR/$n.crt" /var/lib/postgresql/server.crt
    install -o postgres -g postgres -m 0600 "$PKI_DIR/$n.key" /var/lib/postgresql/server.key
  fi

  # System trust store, so psql/certbot/Stalwart validate the CA.
  install -m 0644 "$PKI_DIR/ca.crt" /usr/local/share/ca-certificates/mailstack-ca.crt
  update-ca-certificates >/dev/null 2>&1 || true
  ok "TLS material installed for $n"
}


# =============================================================================
#  garage
# =============================================================================
cmd_garage() {
  need_root; load_env
  require_set GARAGE_RPC_SECRET GARAGE_ADMIN_TOKEN GARAGE_METRICS_TOKEN

  if [ ! -x "$GARAGE_BIN" ] || ! "$GARAGE_BIN" --version 2>/dev/null | grep -q "${GARAGE_VERSION#v}"; then
    log "Downloading Garage $GARAGE_VERSION"
    local url="https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage"
    curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/garage.new "$url" \
      || die "download failed: $url (check the arch string at https://garagehq.deuxfleurs.fr/download/)"
    chmod 0755 /tmp/garage.new && mv -f /tmp/garage.new "$GARAGE_BIN"
    ok "$("$GARAGE_BIN" --version | head -1)"
  else
    ok "Garage $GARAGE_VERSION already installed"
  fi

  id -u garage >/dev/null 2>&1 || useradd --system --home-dir /var/lib/garage --shell /usr/sbin/nologin garage

  log "Writing $GARAGE_CONFIG"
  backup_once "$GARAGE_CONFIG"
  write_file "$GARAGE_CONFIG" 0640 root:garage <<EOF
# Generated by deploy.sh from .env — do not edit by hand.
replication_factor = ${GARAGE_REPLICATION_FACTOR}
consistency_mode   = "${GARAGE_CONSISTENCY_MODE}"

metadata_dir = "${GARAGE_META}"
data_dir     = "${GARAGE_DATA}"
metadata_snapshots_dir = "${GARAGE_SNAP}"

db_engine = "${GARAGE_DB_ENGINE}"
metadata_fsync = true
data_fsync     = false
metadata_auto_snapshot_interval = "6h"

compression_level = 1
block_size = "1M"

rpc_secret      = "${GARAGE_RPC_SECRET}"
rpc_bind_addr   = "[::]:${GARAGE_RPC_PORT}"
rpc_public_addr = "${SELF_IP}:${GARAGE_RPC_PORT}"
bootstrap_peers = []

[s3_api]
api_bind_addr = "127.0.0.1:${GARAGE_S3_PORT}"
s3_region     = "${GARAGE_S3_REGION}"

[s3_web]
bind_addr   = "127.0.0.1:${GARAGE_WEB_PORT}"
root_domain = ".web.${DOMAIN}"

[admin]
api_bind_addr         = "127.0.0.1:${GARAGE_ADMIN_PORT}"
admin_token           = "${GARAGE_ADMIN_TOKEN}"
metrics_token         = "${GARAGE_METRICS_TOKEN}"
metrics_require_token = true
EOF
  ln -sfn "$GARAGE_CONFIG" /opt/garage/garage.toml

  write_file /etc/systemd/system/garage.service 0644 <<EOF
[Unit]
Description=Garage Data Store
After=network-online.target
Wants=network-online.target

[Service]
Environment='RUST_LOG=garage=info' 'RUST_BACKTRACE=1'
ExecStart=${GARAGE_BIN} server
User=garage
Group=garage
ProtectHome=true
ProtectSystem=full
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=65535
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chown -R garage:garage /var/lib/garage
  systemctl daemon-reload
  systemctl enable --now garage
  sleep 3
  systemctl is-active --quiet garage || die "garage failed: journalctl -u garage -n 50"
  ok "garage running"
  log "This node's Garage identity:"
  "$GARAGE_BIN" -c "$GARAGE_CONFIG" node id 2>/dev/null | sed 's/^/    /' || true
}

cmd_garage_cluster() {
  need_root; load_env
  [ "$NODE_NAME" = "mail2" ] || die "run garage-cluster on mail2 only"
  local G=("$GARAGE_BIN" -c "$GARAGE_CONFIG")

  cat <<EOF

Collect the full node IDs first. On mail1 and mail3 run:
    sudo garage -c /etc/garage.toml node id

EOF
  read -r -p "mail1 node id (…@${MAIL1_IP}:${GARAGE_RPC_PORT}): " ID1
  read -r -p "mail3 node id (…@${MAIL3_IP}:${GARAGE_RPC_PORT}): " ID3
  [ -n "$ID1" ] && [ -n "$ID3" ] || die "both node ids required"

  log "Connecting peers"
  "${G[@]}" node connect "$ID1" || die "mail1 unreachable — is TCP $GARAGE_RPC_PORT open both ways?"
  "${G[@]}" node connect "$ID3" || die "mail3 unreachable — is TCP $GARAGE_RPC_PORT forwarded on the router?"
  sleep 3
  "${G[@]}" status | sed 's/^/    /'

  local SELFID P1 P3
  SELFID=$("${G[@]}" node id -q | cut -d@ -f1)
  P1=$(printf '%s' "$ID1" | cut -d@ -f1)
  P3=$(printf '%s' "$ID3" | cut -d@ -f1)

  log "Assigning layout — capacity ${GARAGE_CAPACITY} per node, one zone per site"
  "${G[@]}" layout assign "${SELFID:0:16}" -z "$MAIL2_ZONE" -c "$GARAGE_CAPACITY" -t mail2
  "${G[@]}" layout assign "${P1:0:16}"     -z "$MAIL1_ZONE" -c "$GARAGE_CAPACITY" -t mail1
  "${G[@]}" layout assign "${P3:0:16}"     -z "$MAIL3_ZONE" -c "$GARAGE_CAPACITY" -t mail3
  "${G[@]}" layout show | sed 's/^/    /'

  read -r -p "Apply this layout? Enter the version number shown above (usually 1): " LV
  [ -n "$LV" ] || die "aborted"
  "${G[@]}" layout apply --version "$LV"

  log "Bucket, key and quota"
  "${G[@]}" bucket create "$GARAGE_BUCKET" 2>/dev/null || warn "bucket exists"
  "${G[@]}" key list 2>/dev/null | grep -q "$GARAGE_KEY_NAME" || "${G[@]}" key create "$GARAGE_KEY_NAME" >/dev/null
  # read+write but deliberately NOT --owner: the app key cannot delete the
  # bucket, change permissions or make it public.
  "${G[@]}" bucket allow --read --write "$GARAGE_BUCKET" --key "$GARAGE_KEY_NAME"
  "${G[@]}" bucket set-quotas "$GARAGE_BUCKET" --max-size "$GARAGE_BUCKET_MAX_SIZE" --max-objects none
  "${G[@]}" bucket website --deny "$GARAGE_BUCKET" 2>/dev/null || true
  "${G[@]}" admin-token create --expires-in 365d \
      --scope GetClusterHealth,GetClusterStatus,GetClusterStatistics \
      mailstack-monitor 2>/dev/null | sed 's/^/    /' \
    || warn "scoped admin tokens unavailable in this build; the static token still works"

  cat <<'EOF'

================================================================================
  S3 CREDENTIALS — put these in /opt/mailstack/.env on ALL THREE nodes
================================================================================
EOF
  "${G[@]}" key info "$GARAGE_KEY_NAME" --show-secret | sed 's/^/    /'
  echo
  echo "    S3_ACCESS_KEY=…   S3_SECRET_KEY=…"
  echo "================================================================================"
}


# =============================================================================
#  etcd   — the consensus store that makes failover automatic
# =============================================================================
cmd_etcd() {
  need_root; load_env
  require_set ETCD_INITIAL_TOKEN ETCD_ROOT_PASSWORD ETCD_PATRONI_PASSWORD
  [ -f "$TLS_DIR/node.crt" ] || die "run './deploy.sh pki' (mail2) / 'pki-import' first"

  if [ ! -x "$ETCD_BIN" ] || ! "$ETCD_BIN" --version 2>/dev/null | grep -q "${ETCD_VERSION#v}"; then
    log "Downloading etcd $ETCD_VERSION"
    local url="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
    curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/etcd.tgz "$url" || die "download failed: $url"
    tar -C /tmp -xzf /tmp/etcd.tgz
    install -m 0755 "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd"    "$ETCD_BIN"
    install -m 0755 "/tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/etcdctl
    rm -rf /tmp/etcd.tgz "/tmp/etcd-${ETCD_VERSION}-linux-amd64"
    ok "$("$ETCD_BIN" --version | head -1)"
  else
    ok "etcd $ETCD_VERSION already installed"
  fi

  id -u etcd >/dev/null 2>&1 || useradd --system --home-dir "$ETCD_DATA" --shell /usr/sbin/nologin etcd
  install -d -o etcd -g etcd -m 0700 "$ETCD_DATA"
  install -d -o root -g etcd -m 0750 "$TLS_DIR"
  chgrp etcd "$TLS_DIR/node.key" && chmod 0640 "$TLS_DIR/node.key"

  local CLUSTER="mail1=https://${MAIL1_IP}:${ETCD_PEER_PORT},mail2=https://${MAIL2_IP}:${ETCD_PEER_PORT},mail3=https://${MAIL3_IP}:${ETCD_PEER_PORT}"

  log "Writing /etc/default/etcd"
  write_file /etc/default/etcd 0640 root:etcd <<EOF
# Generated by deploy.sh.
ETCD_NAME=${NODE_NAME}
ETCD_DATA_DIR=${ETCD_DATA}
ETCD_INITIAL_CLUSTER=${CLUSTER}
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=${ETCD_INITIAL_TOKEN}

ETCD_LISTEN_PEER_URLS=https://0.0.0.0:${ETCD_PEER_PORT}
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://${SELF_IP}:${ETCD_PEER_PORT}
ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:${ETCD_CLIENT_PORT}
ETCD_ADVERTISE_CLIENT_URLS=https://${SELF_IP}:${ETCD_CLIENT_PORT}

# Mutual TLS on both peer and client channels, signed by our internal CA.
ETCD_CERT_FILE=${TLS_DIR}/node.crt
ETCD_KEY_FILE=${TLS_DIR}/node.key
ETCD_TRUSTED_CA_FILE=${TLS_DIR}/ca.crt
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CERT_FILE=${TLS_DIR}/node.crt
ETCD_PEER_KEY_FILE=${TLS_DIR}/node.key
ETCD_PEER_TRUSTED_CA_FILE=${TLS_DIR}/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true

# WAN tuning. etcd docs: heartbeat ~0.5-1.5x max RTT, election >= 10x RTT.
ETCD_HEARTBEAT_INTERVAL=${ETCD_HEARTBEAT_MS}
ETCD_ELECTION_TIMEOUT=${ETCD_ELECTION_MS}

ETCD_AUTO_COMPACTION_RETENTION=1
ETCD_QUOTA_BACKEND_BYTES=2147483648
ETCD_SNAPSHOT_COUNT=10000
EOF

  write_file /etc/systemd/system/etcd.service 0644 <<EOF
[Unit]
Description=etcd — Patroni distributed configuration store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd
EnvironmentFile=/etc/default/etcd
ExecStart=${ETCD_BIN}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${ETCD_DATA}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now etcd
  sleep 4
  systemctl is-active --quiet etcd || die "etcd failed: journalctl -u etcd -n 60"
  ok "etcd running (cluster forms once all three nodes are up)"

  write_file /etc/profile.d/etcdctl.sh 0644 <<EOF
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:${ETCD_CLIENT_PORT}
export ETCDCTL_CACERT=${TLS_DIR}/ca.crt
export ETCDCTL_CERT=${TLS_DIR}/node.crt
export ETCDCTL_KEY=${TLS_DIR}/node.key
EOF
  log "Cluster health (expect errors until all three are running):"
  _etcdctl endpoint health --cluster 2>&1 | sed 's/^/    /' || true
}

_etcdctl() {
  ETCDCTL_API=3 etcdctl \
    --endpoints="https://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --cacert="$TLS_DIR/ca.crt" --cert="$TLS_DIR/node.crt" --key="$TLS_DIR/node.key" \
    "$@"
}

cmd_etcd_auth() {
  need_root; load_env
  [ "$NODE_NAME" = "mail2" ] || die "run etcd-auth on mail2 only, once"
  log "Cluster members"
  _etcdctl member list -w table 2>&1 | sed 's/^/    /'
  local n; n=$(_etcdctl member list 2>/dev/null | wc -l)
  [ "$n" -ge 3 ] || die "only $n member(s) visible — start etcd on all three nodes first"

  log "Enabling RBAC (defence in depth on top of mTLS and your firewall)"
  _etcdctl user add root --new-user-password="$ETCD_ROOT_PASSWORD" 2>/dev/null || warn "root user exists"
  _etcdctl user add patroni --new-user-password="$ETCD_PATRONI_PASSWORD" 2>/dev/null || warn "patroni user exists"
  _etcdctl role add patroni 2>/dev/null || true
  _etcdctl role grant-permission patroni --prefix=true readwrite "/mailstack/" 2>/dev/null || true
  _etcdctl user grant-role patroni patroni 2>/dev/null || true
  _etcdctl auth enable 2>/dev/null || warn "auth already enabled"
  ok "etcd RBAC enabled"
}


# =============================================================================
#  patroni
# =============================================================================
cmd_patroni() {
  need_root; load_env
  require_set PG_APP_PASSWORD PG_REPL_PASSWORD PG_SUPER_PASSWORD PG_REWIND_PASSWORD \
              PATRONI_REST_PASSWORD ETCD_PATRONI_PASSWORD
  [ -f "$TLS_DIR/node.crt" ] || die "run pki / pki-import first"

  log "Installing PostgreSQL $PG_VERSION and Patroni from PGDG"
  export DEBIAN_FRONTEND=noninteractive
  if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
  fi
  apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" patroni

  # Debian/Ubuntu creates a cluster on install and manages it with pg_ctlcluster.
  # Patroni must own the data directory instead, so remove the packaged cluster.
  if pg_lsclusters -h 2>/dev/null | awk '{print $1,$2}' | grep -q "^${PG_VERSION} main$"; then
    if [ ! -f "/var/lib/postgresql/${PG_VERSION}/main/patroni.dynamic.json" ]; then
      log "Removing the distribution-managed cluster so Patroni can bootstrap"
      pg_dropcluster --stop "$PG_VERSION" main || true
    fi
  fi
  systemctl disable --now postgresql 2>/dev/null || true

  _pki_install "$NODE_NAME"

  local DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
  install -d -o postgres -g postgres -m 0700 "$DATA_DIR"

  # mail1 is ~200 ms away; never let it be chosen as the synchronous standby.
  local NOSYNC=false
  [ "$NODE_NAME" = "mail1" ] && NOSYNC=true

  log "Writing $PATRONI_CONFIG"
  install -d -o postgres -g postgres -m 0750 /etc/patroni
  write_file "$PATRONI_CONFIG" 0600 postgres:postgres <<EOF
# Generated by deploy.sh from .env — do not edit by hand.
scope: ${PATRONI_SCOPE}
namespace: /mailstack/
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:${PATRONI_REST_PORT}
  connect_address: ${SELF_IP}:${PATRONI_REST_PORT}
  authentication:
    username: ${PATRONI_REST_USER}
    password: ${PATRONI_REST_PASSWORD}

etcd3:
  protocol: https
  hosts:
  - ${MAIL1_IP}:${ETCD_CLIENT_PORT}
  - ${MAIL2_IP}:${ETCD_CLIENT_PORT}
  - ${MAIL3_IP}:${ETCD_CLIENT_PORT}
  username: patroni
  password: ${ETCD_PATRONI_PASSWORD}
  cacert: ${TLS_DIR}/ca.crt
  cert: ${TLS_DIR}/node.crt
  key: ${TLS_DIR}/node.key

bootstrap:
  dcs:
    # loop_wait + 2*retry_timeout <= ttl   (Patroni's stated constraint)
    ttl: ${PATRONI_TTL}
    loop_wait: ${PATRONI_LOOP_WAIT}
    retry_timeout: ${PATRONI_RETRY_TIMEOUT}
    maximum_lag_on_failover: ${PATRONI_MAX_LAG}
    primary_start_timeout: 300
    synchronous_mode: ${PG_SYNCHRONOUS_MODE}
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        wal_compression: "on"
        wal_log_hints: "on"
        max_connections: 200
        shared_buffers: 256MB
        effective_cache_size: 768MB
        work_mem: 8MB
        maintenance_work_mem: 64MB
        password_encryption: scram-sha-256
        ssl: "on"
        ssl_cert_file: /var/lib/postgresql/server.crt
        ssl_key_file: /var/lib/postgresql/server.key
        ssl_ca_file: /var/lib/postgresql/ca.crt
        logging_collector: "on"
        log_directory: log
        log_filename: postgresql-%a.log
        log_rotation_age: 1d
        log_truncate_on_rotation: "on"
        log_min_duration_statement: 2000
        log_connections: "on"
        log_disconnections: "on"
  initdb:
  - encoding: UTF8
  - data-checksums
  pg_hba:
  - local   all             all                                     peer
  - hostssl all             ${PG_APP_USER}     ${MAIL1_IP}/32       scram-sha-256
  - hostssl all             ${PG_APP_USER}     ${MAIL2_IP}/32       scram-sha-256
  - hostssl all             ${PG_APP_USER}     ${MAIL3_IP}/32       scram-sha-256
  - hostssl all             ${ROUNDCUBE_DB_USER} ${MAIL1_IP}/32     scram-sha-256
  - hostssl all             ${ROUNDCUBE_DB_USER} ${MAIL2_IP}/32     scram-sha-256
  - hostssl all             ${ROUNDCUBE_DB_USER} ${MAIL3_IP}/32     scram-sha-256
  - hostssl replication     ${PG_REPL_USER}    ${MAIL1_IP}/32       scram-sha-256
  - hostssl replication     ${PG_REPL_USER}    ${MAIL2_IP}/32       scram-sha-256
  - hostssl replication     ${PG_REPL_USER}    ${MAIL3_IP}/32       scram-sha-256
  - hostssl all             postgres           ${MAIL1_IP}/32       scram-sha-256
  - hostssl all             postgres           ${MAIL2_IP}/32       scram-sha-256
  - hostssl all             postgres           ${MAIL3_IP}/32       scram-sha-256
  - host    all             all                0.0.0.0/0            reject
  - host    all             all                ::/0                 reject

postgresql:
  listen: 0.0.0.0:${PG_PORT}
  connect_address: ${SELF_IP}:${PG_PORT}
  data_dir: ${DATA_DIR}
  bin_dir: /usr/lib/postgresql/${PG_VERSION}/bin
  pgpass: /var/lib/postgresql/.pgpass_patroni
  authentication:
    superuser:
      username: postgres
      password: ${PG_SUPER_PASSWORD}
    replication:
      username: ${PG_REPL_USER}
      password: ${PG_REPL_PASSWORD}
    rewind:
      username: rewind_user
      password: ${PG_REWIND_PASSWORD}
  parameters:
    unix_socket_directories: /var/run/postgresql

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: ${NOSYNC}

watchdog:
  mode: automatic
  device: /dev/watchdog
  safety_margin: 5

callbacks:
  on_role_change: /opt/mailstack/bin/patroni-callback.sh
EOF

  # The callback runs as postgres and must not be able to read the root-owned
  # .env, so it gets its own minimal credential file.
  log "Writing /etc/mailstack/dns-failover.env for the promotion callback"
  install -d -m 0755 /etc/mailstack
  install -d -o postgres -g postgres -m 0750 /var/log/mailstack
  write_file /etc/mailstack/dns-failover.env 0640 root:postgres <<EOF
# Generated by deploy.sh. Read by bin/patroni-callback.sh as the postgres user.
DNS_FAILOVER_ENABLED=${DNS_FAILOVER_ENABLED}
DNS_FAILOVER_RECORDS="${DNS_FAILOVER_RECORDS}"
DNS_TTL=${DNS_FAILOVER_TTL}
DOMAIN=${DOMAIN}
SELF_IP=${SELF_IP}
DNS_PROVIDER=${ACME_DNS_PROVIDER}
DNS_API_TOKEN=${ACME_DNS_API_TOKEN}
CF_ZONE_ID=${CF_ZONE_ID}
R53_ZONE_ID=${CF_ZONE_ID}
EOF
  chmod 0755 "$MAILSTACK_DIR/bin/patroni-callback.sh"

  # softdog gives Patroni a hardware-style guarantee that a demoted primary
  # really stops. mode:automatic means Patroni runs fine without it too.
  modprobe softdog 2>/dev/null || true
  echo softdog > /etc/modules-load.d/softdog.conf
  [ -e /dev/watchdog ] && chown postgres /dev/watchdog 2>/dev/null || true

  write_file /etc/systemd/system/patroni.service 0644 <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network-online.target etcd.service
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/patroni ${PATRONI_CONFIG}
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=process
TimeoutSec=60
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now patroni
  sleep 10
  systemctl is-active --quiet patroni || die "patroni failed: journalctl -u patroni -n 80"
  ok "patroni running"
  patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | sed 's/^/    /' || true

  if [ "$NODE_NAME" = "mail2" ]; then
    log "Creating application roles and databases (only needed once)"
    _patroni_bootstrap_roles
  fi
}

_patroni_bootstrap_roles() {
  local tries=0
  until patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | grep -qi leader; do
    tries=$((tries+1)); [ "$tries" -gt 30 ] && die "no leader elected after 5 minutes"
    sleep 10
  done
  local sqlf; sqlf=$(mktemp /tmp/mailstack-sql.XXXXXX); chmod 600 "$sqlf"
  {
    printf "SELECT format('CREATE ROLE %%I LOGIN PASSWORD %%L', %s, %s) WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=%s)\\gexec\n" \
           "$(_lit "$PG_APP_USER")" "$(_lit "$PG_APP_PASSWORD")" "$(_lit "$PG_APP_USER")"
    printf "SELECT format('ALTER ROLE %%I LOGIN PASSWORD %%L', %s, %s)\\gexec\n" \
           "$(_lit "$PG_APP_USER")" "$(_lit "$PG_APP_PASSWORD")"
    printf "SELECT format('CREATE ROLE %%I LOGIN PASSWORD %%L', %s, %s) WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=%s)\\gexec\n" \
           "$(_lit "$ROUNDCUBE_DB_USER")" "$(_lit "$ROUNDCUBE_DB_PASSWORD")" "$(_lit "$ROUNDCUBE_DB_USER")"
    printf "SELECT format('ALTER ROLE %%I LOGIN PASSWORD %%L', %s, %s)\\gexec\n" \
           "$(_lit "$ROUNDCUBE_DB_USER")" "$(_lit "$ROUNDCUBE_DB_PASSWORD")"
    printf "SELECT format('CREATE DATABASE %%I OWNER %%I', %s, %s) WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=%s)\\gexec\n" \
           "$(_lit "$PG_DATABASE")" "$(_lit "$PG_APP_USER")" "$(_lit "$PG_DATABASE")"
    printf "SELECT format('CREATE DATABASE %%I OWNER %%I', %s, %s) WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=%s)\\gexec\n" \
           "$(_lit "$ROUNDCUBE_DB")" "$(_lit "$ROUNDCUBE_DB_USER")" "$(_lit "$ROUNDCUBE_DB")"
  } > "$sqlf"
  chown postgres "$sqlf"
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 -h /var/run/postgresql -f "$sqlf" >/dev/null
  rm -f "$sqlf"
  ok "roles and databases created"
}


# =============================================================================
#  haproxy — local :5433 always points at the current primary
# =============================================================================
cmd_haproxy() {
  need_root; load_env
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq haproxy

  log "Writing /etc/haproxy/haproxy.cfg"
  backup_once /etc/haproxy/haproxy.cfg
  write_file /etc/haproxy/haproxy.cfg 0644 <<EOF
# Generated by deploy.sh. Local-only PostgreSQL router.
#
# Patroni's REST API answers 200 on GET /primary ONLY on the current leader,
# and 503 everywhere else. That is what makes application failover automatic:
# Stalwart and Roundcube connect to 127.0.0.1:${PG_PROXY_PORT} and always land
# on whichever node is primary right now, with no DNS change and no restart.
global
    maxconn 500
    log /dev/log local0

defaults
    log     global
    mode    tcp
    retries 2
    timeout client  30m
    timeout server  30m
    timeout connect 5s
    timeout check   5s

listen stats
    mode http
    bind 127.0.0.1:7000
    stats enable
    stats uri /

listen postgres_primary
    bind 127.0.0.1:${PG_PROXY_PORT}
    option httpchk GET /primary
    http-check expect status 200
    # on-marked-down shutdown-sessions kills connections to a demoted primary
    # immediately, so nothing keeps writing to a node that has lost the lock.
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server mail1 ${MAIL1_IP}:${PG_PORT} check port ${PATRONI_REST_PORT}
    server mail2 ${MAIL2_IP}:${PG_PORT} check port ${PATRONI_REST_PORT}
    server mail3 ${MAIL3_IP}:${PG_PORT} check port ${PATRONI_REST_PORT}
EOF
  systemctl enable --now haproxy
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
  sleep 2
  systemctl is-active --quiet haproxy || die "haproxy failed: journalctl -u haproxy -n 40"
  ok "haproxy listening on 127.0.0.1:${PG_PROXY_PORT} -> current primary"
}


# =============================================================================
#  stalwart
# =============================================================================
cmd_stalwart() {
  need_root; load_env
  require_set PG_APP_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY \
              STALWART_BOOTSTRAP_ADMIN_PASSWORD STALWART_CLUSTER_SECRET

  if [ ! -x "$STALWART_BIN" ]; then
    log "Installing Stalwart"
    curl --proto '=https' --tlsv1.2 -sSf https://get.stalw.art/install.sh -o /tmp/stalwart-install.sh
    sh /tmp/stalwart-install.sh
    rm -f /tmp/stalwart-install.sh
  fi
  systemctl stop stalwart 2>/dev/null || true

  log "Writing $STALWART_ENVFILE"
  write_file "$STALWART_ENVFILE" 0600 <<EOF
# Generated by deploy.sh — config.json references these by name, so no secret
# is stored in config.json or in the settings database in cleartext.
STALWART_HOSTNAME=${SELF_HOST}
STALWART_PUBLIC_URL=https://${PUBLIC_HOSTNAME}
MAILSTACK_DB_PASSWORD=${PG_APP_PASSWORD}
MAILSTACK_S3_ACCESS_KEY=${S3_ACCESS_KEY}
MAILSTACK_S3_SECRET_KEY=${S3_SECRET_KEY}
EOF

  if [ "$NODE_NAME" = "mail2" ] && [ ! -f "$STALWART_CONFIG" ]; then
    printf 'STALWART_RECOVERY_ADMIN=%s:%s\n' \
      "$STALWART_BOOTSTRAP_ADMIN_USER" "$STALWART_BOOTSTRAP_ADMIN_PASSWORD" >> "$STALWART_ENVFILE"
    chmod 600 "$STALWART_ENVFILE"
    _stalwart_dropin
    systemctl daemon-reload; systemctl enable --now stalwart
    sleep 4
    cat <<EOF

================================================================================
  mail2 IS IN BOOTSTRAP MODE
================================================================================
  Do NOT expose port 8080. Tunnel from your workstation instead:

      ssh -N -L 8080:127.0.0.1:8080 root@${SELF_IP}

  then open   http://127.0.0.1:8080/admin
  username:   ${STALWART_BOOTSTRAP_ADMIN_USER}
  password:   sudo grep '^STALWART_BOOTSTRAP_ADMIN_PASSWORD=' $ENV_FILE | cut -d= -f2-

  In the wizard, for the data store enter:
      type=PostgreSQL  host=127.0.0.1  port=${PG_PROXY_PORT}  database=${PG_DATABASE}
      user=${PG_APP_USER}  useTls=yes  allowInvalidCerts=no

  ^ 127.0.0.1:${PG_PROXY_PORT} is the local HAProxy. It follows the Patroni
    leader automatically, which is what makes failover invisible to Stalwart.

  Then run:  sudo ./deploy.sh stalwart      (again, to externalise the secrets)
================================================================================
EOF
    return 0
  fi

  log "Writing $STALWART_CONFIG"
  backup_once "$STALWART_CONFIG"
  write_file "$STALWART_CONFIG" 0640 root:stalwart <<EOF
{
  "@type": "PostgreSql",
  "host": "127.0.0.1",
  "port": ${PG_PROXY_PORT},
  "database": "${PG_DATABASE}",
  "authUsername": "${PG_APP_USER}",
  "authSecret": { "@type": "EnvironmentVariable", "variableName": "MAILSTACK_DB_PASSWORD" },
  "useTls": true,
  "allowInvalidCerts": false,
  "timeout": 15000,
  "poolMaxConnections": 10
}
EOF
  ln -sfn "$STALWART_CONFIG" /opt/stalwart/config.json
  ln -sfn "$STALWART_ENVFILE" /opt/stalwart/stalwart.env

  _stalwart_dropin
  systemctl daemon-reload
  systemctl restart stalwart
  sleep 4
  systemctl is-active --quiet stalwart || die "stalwart failed: journalctl -u stalwart -n 80"
  ok "stalwart running as node '${SELF_HOST}'"
  cat <<EOF

  Remaining manual step in the WebUI (Settings -> Server -> Listeners):
    move the HTTPS listener to 127.0.0.1:${STALWART_HTTPS_BACKEND_PORT}
    and set proxyTrustedNetworks to include 127.0.0.0/8
  so nginx can SNI-route port 443 between webmail and Stalwart.
  Run './deploy.sh webmail' after that.
EOF
}

_stalwart_dropin() {
  mkdir -p /etc/systemd/system/stalwart.service.d
  write_file /etc/systemd/system/stalwart.service.d/60-mailstack.conf 0644 <<EOF
[Service]
EnvironmentFile=${STALWART_ENVFILE}
LimitNOFILE=65535
Restart=on-failure
RestartSec=5
EOF
}


# =============================================================================
#  webmail — nginx SNI front door + PHP-FPM + Roundcube
# =============================================================================
cmd_webmail() {
  need_root; load_env
  require_set ROUNDCUBE_DB_PASSWORD ROUNDCUBE_DES_KEY ACME_DNS_API_TOKEN
  [ ${#ROUNDCUBE_DES_KEY} -eq 24 ] || die "ROUNDCUBE_DES_KEY must be exactly 24 characters"

  export DEBIAN_FRONTEND=noninteractive
  log "Installing nginx, PHP ${PHP_VERSION} and certbot"
  apt-get install -y -qq nginx libnginx-mod-stream \
      "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-pgsql" "php${PHP_VERSION}-mbstring" \
      "php${PHP_VERSION}-intl" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" \
      "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-opcache" \
      "php${PHP_VERSION}-ldap" certbot

  # SNI routing needs the stream module AND ssl_preread. Fail loudly, early.
  if ! compgen -G "/usr/lib/nginx/modules/ngx_stream_module*" >/dev/null; then
    die "nginx stream module missing. Install libnginx-mod-stream, or switch to the HAProxy front door in ARCHITECTURE-REVISION-3 §4.4"
  fi
  ok "nginx stream module present"

  case "$ACME_DNS_PROVIDER" in
    cloudflare) apt-get install -y -qq python3-certbot-dns-cloudflare ;;
    route53)    apt-get install -y -qq python3-certbot-dns-route53 ;;
    *)          warn "no certbot DNS plugin for '$ACME_DNS_PROVIDER'; issue the webmail cert manually" ;;
  esac

  log "Downloading Roundcube ${ROUNDCUBE_VERSION}"
  local tgz="roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"
  local url="https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/${tgz}"
  if [ ! -f "$RC_ROOT/index.php" ] || ! grep -q "'${ROUNDCUBE_VERSION}'" "$RC_ROOT/program/include/iniset.php" 2>/dev/null; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "/tmp/$tgz" "$url" \
      || die "download failed: $url — check the asset name on the release page"
    rm -rf /tmp/rcunpack && mkdir -p /tmp/rcunpack
    tar -C /tmp/rcunpack -xzf "/tmp/$tgz"
    install -d "$RC_ROOT"
    rsync -a --delete --exclude config/ "/tmp/rcunpack/roundcubemail-${ROUNDCUBE_VERSION}/" "$RC_ROOT/"
    rm -rf /tmp/rcunpack "/tmp/$tgz"
    ok "Roundcube ${ROUNDCUBE_VERSION} unpacked"
  else
    ok "Roundcube ${ROUNDCUBE_VERSION} already installed"
  fi

  # The installer is a remote-configuration surface. It must not survive.
  rm -rf "$RC_ROOT/installer"
  install -d -o www-data -g www-data -m 0750 "$RC_DATA/temp" "$RC_DATA/logs"
  install -d -m 0750 "$RC_ROOT/config"

  log "Writing Roundcube configuration"
  local plugins="'archive','zipdownload','managesieve','newmail_notifier'"
  write_file "$RC_ROOT/config/config.inc.php" 0640 root:www-data <<EOF
<?php
// Generated by /opt/mailstack/deploy.sh from .env — do not edit by hand.

// --- Storage -----------------------------------------------------------------
// PostgreSQL through the LOCAL HAProxy, so webmail follows the Patroni leader
// exactly like Stalwart does.
\$config['db_dsnw'] = 'pgsql://${ROUNDCUBE_DB_USER}:${ROUNDCUBE_DB_PASSWORD}@127.0.0.1:${PG_PROXY_PORT}/${ROUNDCUBE_DB}';

// --- Mail servers ------------------------------------------------------------
// Always the LOGICAL endpoint, never a node name, so users never see mail1/2/3.
\$config['imap_host'] = 'ssl://${PUBLIC_HOSTNAME}:993';
\$config['smtp_host'] = 'ssl://${PUBLIC_HOSTNAME}:465';
\$config['smtp_user'] = '%u';   // every outgoing message is authenticated as
\$config['smtp_pass'] = '%p';   // the user, so per-user rate limits apply
\$config['username_domain'] = '${DOMAIN}';
\$config['managesieve_host'] = 'localhost:4190';

// --- THE setting that keeps mail out of this database ------------------------
// Left on, Roundcube caches message BODIES in SQL, which would make webmail a
// second mail store. Off means every message is fetched from Stalwart on demand.
\$config['messages_cache'] = false;
// Folder indexes and UID maps only — metadata, never message content.
\$config['imap_cache'] = 'db';
\$config['imap_cache_ttl'] = '10d';

// --- Sessions ----------------------------------------------------------------
// Database-backed: no Redis, no extra daemon, and sessions are covered by the
// existing backup and follow a failover.
\$config['session_storage']  = 'db';
\$config['session_lifetime'] = 30;
\$config['session_samesite'] = 'Strict';

// --- Security ----------------------------------------------------------------
\$config['des_key']            = '${ROUNDCUBE_DES_KEY}';
\$config['ip_check']           = true;
\$config['referer_check']      = true;
\$config['use_secure_urls']    = true;
\$config['login_rate_limit']   = 3;
\$config['failed_login_delay'] = 5;
\$config['log_driver']         = 'file';
\$config['log_dir']            = '${RC_DATA}/logs/';
\$config['temp_dir']           = '${RC_DATA}/temp/';
\$config['enable_installer']   = false;

// --- Appearance --------------------------------------------------------------
\$config['product_name'] = '${ROUNDCUBE_PRODUCT_NAME}';
\$config['skin']         = 'elastic';   // the responsive skin; good on phones
\$config['support_url']  = '';
\$config['plugins']      = array(${plugins});

// Password changes, 2FA and app passwords live in Stalwart's Account Manager.
// The 'password' plugin is deliberately NOT enabled — it has no Stalwart driver.
EOF

  log "Initialising the roundcube schema"
  if ! PGPASSWORD="$ROUNDCUBE_DB_PASSWORD" psql -h 127.0.0.1 -p "$PG_PROXY_PORT" \
        -U "$ROUNDCUBE_DB_USER" -d "$ROUNDCUBE_DB" -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_name='users'" 2>/dev/null | grep -q 1; then
    PGPASSWORD="$ROUNDCUBE_DB_PASSWORD" psql -h 127.0.0.1 -p "$PG_PROXY_PORT" \
      -U "$ROUNDCUBE_DB_USER" -d "$ROUNDCUBE_DB" -q -f "$RC_ROOT/SQL/postgres.initial.sql" \
      || die "schema load failed"
    ok "schema created"
  else
    ok "schema already present"
  fi

  _webmail_cert
  _webmail_nginx
  _webmail_php

  systemctl enable --now "php${PHP_VERSION}-fpm"
  nginx -t || die "nginx config test failed"
  systemctl enable --now nginx
  systemctl reload nginx
  ok "webmail live at https://${WEBMAIL_HOSTNAME} (when DNS points here)"
}

_webmail_cert() {
  local live="/etc/letsencrypt/live/${WEBMAIL_HOSTNAME}"
  if [ -f "$live/fullchain.pem" ]; then ok "webmail certificate present"; return 0; fi

  # DNS-01, not HTTP-01: webmail.<domain> only resolves to ONE node at a time,
  # but all three need a valid certificate so any of them can take the endpoint
  # over during a failover. DNS-01 works regardless of where the name points.
  case "$ACME_DNS_PROVIDER" in
    cloudflare)
      write_file /etc/letsencrypt/cloudflare.ini 0600 <<EOF
dns_cloudflare_api_token = ${ACME_DNS_API_TOKEN}
EOF
      certbot certonly --non-interactive --agree-tos -m "$ACME_CONTACT" \
        --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 \
        -d "$WEBMAIL_HOSTNAME" || die "certbot failed"
      ;;
    route53)
      certbot certonly --non-interactive --agree-tos -m "$ACME_CONTACT" \
        --dns-route53 -d "$WEBMAIL_HOSTNAME" || die "certbot failed"
      ;;
    *)
      warn "issue the certificate for ${WEBMAIL_HOSTNAME} manually, then re-run"
      return 0
      ;;
  esac

  # Three nodes renewing the same name would race on the _acme-challenge TXT
  # record, so stagger them.
  local mins; case "$NODE_NAME" in mail1) mins=07 ;; mail2) mins=27 ;; mail3) mins=47 ;; esac
  mkdir -p /etc/systemd/system/certbot.timer.d
  write_file /etc/systemd/system/certbot.timer.d/60-mailstack.conf 0644 <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:${mins}:00
RandomizedDelaySec=600
EOF
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  write_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 0755 <<'EOF'
#!/bin/sh
systemctl reload nginx 2>/dev/null || true
EOF
  systemctl daemon-reload; systemctl enable --now certbot.timer 2>/dev/null || true
  ok "certificate issued and renewal scheduled"
}

_webmail_nginx() {
  log "Configuring the nginx SNI front door"
  # Port 443 is shared: nginx reads the SNI name WITHOUT decrypting, then hands
  # the raw TLS connection either to its own webmail vhost or straight through
  # to Stalwart. Stalwart therefore keeps its own certificate and its own ACME,
  # and JMAP/WebDAV pass through untouched.
  install -d /etc/nginx/stream-enabled
  if ! grep -q 'stream-enabled' /etc/nginx/nginx.conf; then
    backup_once /etc/nginx/nginx.conf
    printf '\nstream {\n    include /etc/nginx/stream-enabled/*.conf;\n}\n' >> /etc/nginx/nginx.conf
  fi

  write_file /etc/nginx/stream-enabled/mailstack.conf 0644 <<EOF
# Generated by deploy.sh.
map \$ssl_preread_server_name \$mailstack_backend {
    ${WEBMAIL_HOSTNAME}  127.0.0.1:${WEBMAIL_BACKEND_PORT};
    default              127.0.0.1:${STALWART_HTTPS_BACKEND_PORT};
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass  \$mailstack_backend;
    proxy_protocol on;
    proxy_timeout 30m;
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  write_file /etc/nginx/sites-available/webmail 0644 <<EOF
# Generated by deploy.sh.
server {
    listen 80;
    listen [::]:80;
    server_name ${WEBMAIL_HOSTNAME} ${SELF_HOST};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

# Rate limit the login endpoint. This matters more than usual here: Roundcube
# reaches IMAP from this host, so Stalwart's auto-ban cannot see the real
# attacker. nginx is the tier that has to stop password guessing.
limit_req_zone \$binary_remote_addr zone=rcmlogin:10m rate=10r/m;

server {
    # Fed by the stream block above, which speaks PROXY protocol so we still
    # see the real client IP in logs and rate limits.
    listen 127.0.0.1:${WEBMAIL_BACKEND_PORT} ssl proxy_protocol;
    http2 on;
    server_name ${WEBMAIL_HOSTNAME};

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/letsencrypt/live/${WEBMAIL_HOSTNAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${WEBMAIL_HOSTNAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MailstackTLS:10m;
    ssl_stapling on;
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    root ${RC_ROOT};
    index index.php;
    client_max_body_size 55M;

    # Never serve Roundcube's own data or config over HTTP.
    location ~ ^/(config|temp|logs|SQL|bin|installer)/ { deny all; return 404; }
    location ~ /\\.           { deny all; return 404; }
    location ~ ^/(CHANGELOG|INSTALL|LICENSE|README|UPGRADING)  { deny all; return 404; }

    location = /index.php {
        limit_req zone=rcmlogin burst=20 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 300;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 300;
    }

    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
}
EOF
  ln -sfn /etc/nginx/sites-available/webmail /etc/nginx/sites-enabled/webmail
  install -d -m 0755 /var/www/certbot
}

_webmail_php() {
  write_file "/etc/php/${PHP_VERSION}/fpm/conf.d/99-mailstack.ini" 0644 <<'EOF'
; Generated by deploy.sh
upload_max_filesize = 50M
post_max_size = 55M
memory_limit = 256M
max_execution_time = 300
date.timezone = UTC
session.cookie_secure = 1
session.cookie_httponly = 1
session.cookie_samesite = Strict
session.use_strict_mode = 1
expose_php = Off
display_errors = Off
log_errors = On
opcache.enable = 1
opcache.memory_consumption = 96
EOF
  # ondemand keeps idle memory low on a 2 GB node that is also running
  # PostgreSQL, Garage, etcd and Stalwart.
  write_file "/etc/php/${PHP_VERSION}/fpm/pool.d/roundcube.conf" 0644 <<EOF
[roundcube]
user = www-data
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
pm.max_requests = 500
php_admin_value[open_basedir] = ${RC_ROOT}:${RC_DATA}:/tmp:/usr/share/php
EOF
  rm -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
}


# =============================================================================
#  status
# =============================================================================
cmd_status() {
  load_env
  printf '\n=== %s (%s / %s) ===\n\n' "$NODE_NAME" "$SELF_HOST" "$SELF_IP"
  local svc
  for svc in etcd patroni haproxy garage stalwart nginx "php${PHP_VERSION}-fpm"; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}" || continue
    printf '  %-16s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo absent)"
  done
  if systemctl is-active --quiet patroni; then
    printf '\n--- patroni cluster ---\n'
    patronictl -c "$PATRONI_CONFIG" list 2>/dev/null | sed 's/^/  /' || true
  fi
  if systemctl is-active --quiet garage; then
    printf '\n--- garage ---\n'
    "$GARAGE_BIN" -c "$GARAGE_CONFIG" status 2>/dev/null | sed 's/^/  /' || true
  fi
  printf '\n--- disk ---\n'
  df -h / /var/lib/garage 2>/dev/null | sed 's/^/  /'
  printf '\n'
}


# =============================================================================
main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    gen-secrets)    cmd_gen_secrets ;;
    preflight)      cmd_preflight ;;
    prep)           cmd_prep ;;
    pki)            cmd_pki ;;
    pki-import)     cmd_pki_import "$@" ;;
    garage)         cmd_garage ;;
    garage-cluster) cmd_garage_cluster ;;
    etcd)           cmd_etcd ;;
    etcd-auth)      cmd_etcd_auth ;;
    patroni)        cmd_patroni ;;
    haproxy)        cmd_haproxy ;;
    stalwart)       cmd_stalwart ;;
    webmail)        cmd_webmail ;;
    status)         cmd_status ;;
    verify)         exec "$MAILSTACK_DIR/bin/verify.sh" ;;
    help|-h|--help) sed -n '2,48p' "$0" ;;
    *)              die "unknown command '$cmd' (try: $0 help)" ;;
  esac
}
main "$@"
