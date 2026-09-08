#!/usr/bin/env bash
# /opt/mailstack/lib/common.sh
# Shared helpers. Sourced by deploy.sh and by everything in bin/.
# Never echoes a secret.

set -euo pipefail
umask 077

MAILSTACK_DIR="${MAILSTACK_DIR:-/opt/mailstack}"
ENV_FILE="${ENV_FILE:-$MAILSTACK_DIR/.env}"

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_OFF=$'\033[0m'

log()  { printf '%s[ %s ]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n'   "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n'   "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 $*)"; }

# ---------------------------------------------------------------------------
# .env loading. Refuses to proceed if the file is readable by anyone else,
# or if any value is still the CHANGE_ME placeholder.
# ---------------------------------------------------------------------------
load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found. cp $MAILSTACK_DIR/env.example $ENV_FILE && chmod 600 $ENV_FILE && nano $ENV_FILE"

  local mode owner
  mode=$(stat -c '%a' "$ENV_FILE")
  owner=$(stat -c '%U' "$ENV_FILE")
  [ "$mode" = "600" ] || die "$ENV_FILE has mode $mode; run: chmod 600 $ENV_FILE"
  [ "$owner" = "root" ] || die "$ENV_FILE is owned by $owner; run: chown root:root $ENV_FILE"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  : "${NODE_NAME:?NODE_NAME not set in $ENV_FILE}"
  case "$NODE_NAME" in
    mail1|mail2|mail3) : ;;
    *) die "NODE_NAME must be mail1, mail2 or mail3 (got '$NODE_NAME')" ;;
  esac

  derive_node_vars
}

# Fails if any *required for this phase* variable is still CHANGE_ME.
# Usage: require_set PG_APP_PASSWORD GARAGE_RPC_SECRET ...
require_set() {
  local v missing=()
  for v in "$@"; do
    local val="${!v-}"
    if [ -z "$val" ] || [ "$val" = "CHANGE_ME" ]; then
      missing+=("$v")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "these values are still unset/CHANGE_ME in $ENV_FILE: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Per-node derived variables
# ---------------------------------------------------------------------------
derive_node_vars() {
  case "$NODE_NAME" in
    mail1) SELF_HOST="$MAIL1_HOST"; SELF_IP="$MAIL1_IP"; SELF_ZONE="$MAIL1_ZONE"
           PEER_IPS="$MAIL2_IP $MAIL3_IP"; PEER_HOSTS="$MAIL2_HOST $MAIL3_HOST" ;;
    mail2) SELF_HOST="$MAIL2_HOST"; SELF_IP="$MAIL2_IP"; SELF_ZONE="$MAIL2_ZONE"
           PEER_IPS="$MAIL1_IP $MAIL3_IP"; PEER_HOSTS="$MAIL1_HOST $MAIL3_HOST" ;;
    mail3) SELF_HOST="$MAIL3_HOST"; SELF_IP="$MAIL3_IP"; SELF_ZONE="$MAIL3_ZONE"
           PEER_IPS="$MAIL1_IP $MAIL2_IP"; PEER_HOSTS="$MAIL1_HOST $MAIL2_HOST" ;;
  esac
  export SELF_HOST SELF_IP SELF_ZONE PEER_IPS PEER_HOSTS

  if [ "${PG_ROLE:-auto}" = "auto" ]; then
    case "$NODE_NAME" in
      mail2) PG_ROLE=db-primary ;;
      *)     PG_ROLE=db-standby ;;
    esac
  fi
  export PG_ROLE

  if [ "${STALWART_ROLE:-auto}" = "auto" ]; then
    # mail2 owns the singleton background jobs because it is DB-local.
    case "$NODE_NAME" in
      mail2) STALWART_NODE_ROLE=primary ;;
      mail1) STALWART_NODE_ROLE=edge ;;
      mail3) STALWART_NODE_ROLE=internal ;;
    esac
  else
    STALWART_NODE_ROLE="$STALWART_ROLE"
  fi
  export STALWART_NODE_ROLE
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Write a file atomically with a given mode, content on stdin.
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root:root}"
  local tmp; tmp="$(mktemp "${path}.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

# Back up a file once per deploy run before overwriting it.
backup_once() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ -f "${f}.mailstack.orig" ] || cp -a "$f" "${f}.mailstack.orig"
}

# SQL string literal with embedded quotes escaped.
_lit() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

gen_hex()    { openssl rand -hex 32; }
gen_b64()    { openssl rand -base64 32; }
gen_pass()   { openssl rand -base64 24 | tr -d '/+=' | cut -c1-28; }

# TCP reachability check without installing anything.
tcp_open() {
  local host="$1" port="$2" timeout="${3:-5}"
  timeout "$timeout" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

wait_for_tcp() {
  local host="$1" port="$2" tries="${3:-30}"
  local i
  for i in $(seq 1 "$tries"); do
    tcp_open "$host" "$port" 2 && return 0
    sleep 2
  done
  return 1
}
