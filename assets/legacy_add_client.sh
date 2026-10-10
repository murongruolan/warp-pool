#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2026.10.10-r6"

# Add a non-main-server client to an existing legacy exclusive WarpPool node
# (/etc/wireguard/wp<name>.conf). Unlike shared_node.sh, which manages its own
# state directory, this edits the deployed config in place and applies it with
# `wg syncconf`, so existing peers never lose their tunnel.

ACTION="add"
DEVICE=""
MODE="dual"
NAME=""
CLIENT_PUBLIC_KEY=""
WARP_CLIENT_PUBLIC_KEY=""
CLIENT_PRIVATE_KEY=""
WARP_CLIENT_PRIVATE_KEY=""
ENDPOINT=""
EGRESS=""
ALLOWED_IPS="0.0.0.0/0, ::/0"
CLIENT_DNS="1.1.1.1, 8.8.8.8"
CONFIG_DIR="/root/warppool-clients"
TRANSPARENT_PORT="14000"
REGISTER_WARP="true"
PRINT_CONFIG="true"
DRY_RUN="false"
INTERACTIVE="false"
MODE_SET="false"
MODE_CHOICE=""
PUB_IP=""
PUB_PORT=""
CLIENT_DIRECT_FILE=""
CLIENT_WARP_FILE=""
ROLLBACK_BACKUP=""
STATE_DIR="/etc/warppool-node/legacy-clients"
BASE_URL="${WARPPOOL_INSTALL_BASE_URL:-${WARPOOL_INSTALL_BASE_URL:-https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets}}"
DOWNLOAD_DIR="/tmp/warppool-legacy.$$"

log() {
  printf '[WarpPool][legacy-client] %s\n' "$*"
}

fail() {
  printf '[WarpPool][legacy-client][ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  local line="$1"
  printf '[WarpPool][legacy-client][ERROR] command failed with exit %s at line %s: %s\n' "$status" "$line" "$BASH_COMMAND" >&2
  exit "$status"
}

cleanup_download_dir() {
  if [ -n "${DOWNLOAD_DIR:-}" ] && [ -d "$DOWNLOAD_DIR" ]; then
    rm -rf -- "$DOWNLOAD_DIR"
  fi
}

trap 'on_error $LINENO' ERR
trap 'cleanup_download_dir' EXIT

usage() {
  cat <<USAGE
WarpPool legacy node client helper
version ${SCRIPT_VERSION}

Usage:
  bash legacy_add_client.sh
  bash legacy_add_client.sh -i
  wpl-add-client

  The commands above start a guided setup. It asks for the exit-node device,
  the exit mode, the client label, the client public key, and the public
  endpoint, then shows a preview and waits for confirmation.

  bash legacy_add_client.sh action=add \
      device=wp2-1 mode=direct|warp|dual name=<label> \
      client_public_key=<key> [warp_client_public_key=<key>] \
      [endpoint=<public-host:port>] [egress=<iface>] \
      [config_dir=/root/warppool-clients] [transparent_port=14000] \
      [register_warp=true|false] [allowed_ips=...] [dns=...] [--dry-run]

  bash legacy_add_client.sh action=list device=wp2-1
  bash legacy_add_client.sh action=remove device=wp2-1 name=<label>

Adds a peer to an already deployed legacy exclusive config in place. The
existing PrivateKey, Address, ListenPort and every current [Peer] block are
preserved verbatim. Only PostUp/PostDown are rewritten, from hardcoded
addresses into a loop over a NAT address file, so newly added direct clients
survive a reboot. The change is applied with `wg syncconf`; the interface is
never brought down.

Only the PUBLIC key of the client is normally required. Private keys stay on
the client machine and the generated config carries a PrivateKey placeholder.
Choosing key source 2 in the guided setup generates the keypair on this node
instead and writes the private key straight into the config.
USAGE
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --help|-h)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN="true"
        ;;
      -i|--interactive)
        INTERACTIVE="true"
        ;;
      action=*) ACTION="${arg#action=}" ;;
      device=*) DEVICE="${arg#device=}" ;;
      mode=*) MODE="${arg#mode=}"; MODE_SET="true" ;;
      name=*) NAME="${arg#name=}" ;;
      client_public_key=*) CLIENT_PUBLIC_KEY="${arg#client_public_key=}" ;;
      warp_client_public_key=*) WARP_CLIENT_PUBLIC_KEY="${arg#warp_client_public_key=}" ;;
      client_private_key=*) CLIENT_PRIVATE_KEY="${arg#client_private_key=}" ;;
      warp_client_private_key=*) WARP_CLIENT_PRIVATE_KEY="${arg#warp_client_private_key=}" ;;
      endpoint=*) ENDPOINT="${arg#endpoint=}" ;;
      egress=*) EGRESS="${arg#egress=}" ;;
      allowed_ips=*) ALLOWED_IPS="${arg#allowed_ips=}" ;;
      dns=*) CLIENT_DNS="${arg#dns=}" ;;
      config_dir=*) CONFIG_DIR="${arg#config_dir=}" ;;
      transparent_port=*) TRANSPARENT_PORT="${arg#transparent_port=}" ;;
      register_warp=*) REGISTER_WARP="${arg#register_warp=}" ;;
      base_url=*) BASE_URL="${arg#base_url=}" ;;
      *) fail "unknown argument: $arg" ;;
    esac
  done
}

validate_bool() {
  case "$2" in
    true|false) ;;
    *) fail "$1 must be true or false, got: $2" ;;
  esac
}

validate_args() {
  case "$ACTION" in
    add|list|remove) ;;
    *) fail "unsupported action: $ACTION, expected add, list, or remove" ;;
  esac
  case "$MODE" in
    direct|warp|dual) ;;
    *) fail "unsupported mode: $MODE, expected direct, warp, or dual" ;;
  esac
  [ -n "$DEVICE" ] || fail "device=<wg-device> is required"
  case "$DEVICE" in
    ""|*[!a-zA-Z0-9_.-]*) fail "invalid device name: $DEVICE" ;;
  esac
  case "$TRANSPARENT_PORT" in
    ""|*[!0-9]*) fail "invalid transparent_port: $TRANSPARENT_PORT" ;;
  esac
  validate_bool register_warp "$REGISTER_WARP"
  validate_bool print_config "$PRINT_CONFIG"
  if [ "$ACTION" = "add" ]; then
    [ -n "$NAME" ] || fail "name=<label> is required"
    [ -n "$CLIENT_PUBLIC_KEY" ] || fail "client_public_key is required"
    if [ "$MODE" = "dual" ]; then
      [ -n "$WARP_CLIENT_PUBLIC_KEY" ] || fail "warp_client_public_key is required in dual mode"
    fi
    if [ "$MODE" = "direct" ] && [ -n "$WARP_CLIENT_PUBLIC_KEY" ]; then
      log "mode=direct ignores warp_client_public_key"
      WARP_CLIENT_PUBLIC_KEY=""
    fi
  fi
  if [ "$ACTION" = "remove" ]; then
    [ -n "$NAME" ] || fail "name=<label> is required"
  fi
}

require_root() {
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

run() {
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
}

state_paths() {
  CONF="/etc/wireguard/$DEVICE.conf"
  CLIENT_STATE_DIR="$STATE_DIR/$DEVICE"
  NAT_V4_FILE="$CLIENT_STATE_DIR/$DEVICE.nat"
}

download_script() {
  local name="$1"
  local target="$2"
  require_command curl
  log "downloading $name from $BASE_URL" >&2
  curl -fsSL "$BASE_URL/$name" -o "$target" || fail "failed to download $name from $BASE_URL"
  chmod 0755 "$target"
}

helper_path() {
  local name="$1"
  local dir local_path
  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  local_path="$dir/$name"
  if [ -r "$local_path" ]; then
    printf '%s\n' "$local_path"
    return 0
  fi
  mkdir -p "$DOWNLOAD_DIR"
  download_script "$name" "$DOWNLOAD_DIR/$name"
  printf '%s\n' "$DOWNLOAD_DIR/$name"
}

sanitize_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g; s/^[-.]*//; s/[-.]*$//' | cut -c1-32
}

is_public_key() {
  case "$1" in
    ""|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  [ "${#1}" -eq 44 ] && [ "${1: -1}" = "=" ]
}

load_conf_meta() {
  [ -r "$CONF" ] || fail "config not found: $CONF"

  if grep -q 'ip6tables' "$CONF"; then
    fail "$CONF contains ip6tables rules. This helper only manages IPv4 NAT and will not rewrite IPv6 forwarding rules. Migrate the node to the shared wpshared layout instead."
  fi

  SERVER_PRIVATE_KEY="$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '[:space:]')"
  [ -n "$SERVER_PRIVATE_KEY" ] || fail "cannot read PrivateKey from $CONF"
  SERVER_ADDRESS="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '[:space:]')"
  [ -n "$SERVER_ADDRESS" ] || fail "cannot read Address from $CONF"
  SERVER_IP="${SERVER_ADDRESS%%/*}"
  IP_PREFIX="$(printf '%s' "$SERVER_IP" | awk -F. '{print $1"."$2"."$3}')"
  SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)"

  if [ -z "$EGRESS" ]; then
    EGRESS="$(sed -n 's/.*POSTROUTING -s [0-9.]*\/32 -o \([^ ]*\) -j MASQUERADE.*/\1/p' "$CONF" | head -n 1)"
  fi
  if [ -z "$EGRESS" ]; then
    EGRESS="$(ip route show default 0.0.0.0/0 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi
  [ -n "$EGRESS" ] || fail "cannot detect the egress interface; pass egress=<iface>"
}

used_ips() {
  {
    sed -n 's/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*//p' "$CONF" |
      tr ',' '\n' |
      sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|/.*||' |
      grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
    # Addresses handed out earlier in this same run, so a dual-mode client
    # never receives the same address twice.
    printf '%s\n' "${RESERVED_IPS:-}"
  } | sort -u
}

# Sets ALLOCATED_IP instead of printing it: the caller must stay in this shell,
# otherwise RESERVED_IPS would be updated inside a subshell and lost.
allocate_ip() {
  local n candidate
  USED_IPS="$(used_ips)"
  for n in $(seq 2 254); do
    candidate="$IP_PREFIX.$n"
    if ! printf '%s\n' "$USED_IPS" | grep -Fxq "$candidate"; then
      RESERVED_IPS="${RESERVED_IPS:+$RESERVED_IPS
}$candidate"
      ALLOCATED_IP="$candidate"
      return 0
    fi
  done
  fail "no free tunnel address left in $IP_PREFIX.0/24"
}

register_warp_client() {
  local ip="$1"
  local forwarder
  [ -n "$ip" ] || return 0
  forwarder="$(helper_path warp_forward.sh)"
  log "registering WARP forwarding client $ip on $DEVICE (no forwarder restart)"
  run bash "$forwarder" action=register \
    device="$DEVICE" client_addr="$ip" \
    server_addr="$SERVER_ADDRESS" transparent_port="$TRANSPARENT_PORT"
}

unregister_warp_client() {
  local ip="$1"
  local forwarder
  [ -n "$ip" ] || return 0
  forwarder="$(helper_path warp_forward.sh)"
  log "unregistering WARP forwarding client $ip on $DEVICE"
  run bash "$forwarder" action=down \
    device="$DEVICE" client_addr="$ip" \
    server_addr="$SERVER_ADDRESS" transparent_port="$TRANSPARENT_PORT"
}

render_hooks() {
  cat <<'HOOKS' | sed \
    -e "s|__NATFILE__|$NAT_V4_FILE|g" \
    -e "s|__EGRESS__|$EGRESS|g"
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; if [ -r __NATFILE__ ]; then while read ip; do [ -n "$ip" ] || continue; iptables -t nat -C POSTROUTING -s "$ip/32" -o __EGRESS__ -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$ip/32" -o __EGRESS__ -j MASQUERADE; done < __NATFILE__; fi
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; if [ -r __NATFILE__ ]; then while read ip; do [ -n "$ip" ] || continue; iptables -t nat -D POSTROUTING -s "$ip/32" -o __EGRESS__ -j MASQUERADE 2>/dev/null || true; done < __NATFILE__; fi
HOOKS
}

render_peer() {
  local public_key="$1" address="$2"
  [ -n "$public_key" ] || return 0
  printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$public_key" "$address"
}

render_client_config() {
  local address="$1" private_key="$2"
  printf '[Interface]\n'
  if [ -n "$private_key" ]; then
    printf 'PrivateKey = %s\n' "$private_key"
  else
    printf '# 把下面这一行替换成你在电脑上生成的私钥\nPrivateKey = REPLACE_WITH_YOUR_PRIVATE_KEY\n'
  fi
  printf 'Address = %s/32\n' "$address"
  printf 'DNS = %s\n' "$CLIENT_DNS"
  printf '\n[Peer]\n'
  printf 'PublicKey = %s\n' "$SERVER_PUBLIC_KEY"
  printf 'Endpoint = %s\n' "$ENDPOINT"
  printf 'AllowedIPs = %s\n' "$ALLOWED_IPS"
  printf 'PersistentKeepalive = 25\n'
}

add_client() {
  NAME="$(sanitize_name "$NAME")"
  [ -n "$NAME" ] || fail "name is invalid after sanitizing"
  is_public_key "$CLIENT_PUBLIC_KEY" || fail "client_public_key does not look like a WireGuard public key"
  if [ -n "$WARP_CLIENT_PUBLIC_KEY" ]; then
    is_public_key "$WARP_CLIENT_PUBLIC_KEY" || fail "warp_client_public_key does not look like a WireGuard public key"
  fi
  if [ -r "$CLIENT_STATE_DIR/$NAME.env" ]; then
    fail "client already registered: $NAME (remove it first, or choose another name)"
  fi

  load_conf_meta

  if grep -Fq "$CLIENT_PUBLIC_KEY" "$CONF"; then
    fail "this public key is already a peer in $CONF"
  fi

  local direct_ip warp_ip primary_ip
  direct_ip=""
  warp_ip=""
  RESERVED_IPS=""
  case "$MODE" in
    direct)
      allocate_ip
      direct_ip="$ALLOCATED_IP"
      ;;
    warp)
      allocate_ip
      warp_ip="$ALLOCATED_IP"
      ;;
    dual)
      allocate_ip
      direct_ip="$ALLOCATED_IP"
      allocate_ip
      warp_ip="$ALLOCATED_IP"
      ;;
  esac
  if [ -n "$direct_ip" ]; then
    primary_ip="$direct_ip"
  else
    primary_ip="$warp_ip"
  fi

  log "device=$DEVICE mode=$MODE server=$SERVER_IP egress=$EGRESS"
  log "assigned direct=${direct_ip:-none} warp=${warp_ip:-none}"

  local ts backup tmp
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$CONF.bak.$ts"

  # 1. NAT address file, seeded from the rules already present in the config so
  #    the existing main server keeps its MASQUERADE rule.
  mkdir -p "$CLIENT_STATE_DIR"
  chmod 0700 "$CLIENT_STATE_DIR"
  local seeded
  seeded="$(sed -n 's/.*POSTROUTING -s \([0-9.]*\)\/32 -o [^ ]* -j MASQUERADE.*/\1/p' "$CONF")"
  if [ -n "$seeded" ]; then
    printf '%s\n' "$seeded" >"$NAT_V4_FILE.seed"
  else
    : >"$NAT_V4_FILE.seed"
  fi
  if [ -n "$direct_ip" ]; then
    printf '%s\n' "$direct_ip" >>"$NAT_V4_FILE.seed"
  fi

  # 2. Render the new config. The Interface section is rebuilt explicitly so
  #    that SaveConfig and the PostUp/PostDown hooks stay INSIDE the section:
  #    wg-quick only strips those keys when they follow [Interface], and passes
  #    them through to wg otherwise, which aborts the sync.
  local save_config
  save_config="$(sed -n 's/^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '[:space:]')"
  [ -n "$save_config" ] || save_config="false"

  local iface_keys bad_keys
  iface_keys="$(sed -n '/^[[:space:]]*\[Interface\]/,/^[[:space:]]*\[Peer\]/p' "$CONF" |
    grep -E '=' |
    sed -E 's/^[[:space:]]*([A-Za-z]+)[[:space:]]*=.*/\1/' |
    sort -u)"
  bad_keys="$(printf '%s\n' "$iface_keys" | grep -vE '^(PrivateKey|Address|ListenPort|SaveConfig|PostUp|PostDown)$' || true)"
  if [ -n "$bad_keys" ]; then
    fail "$CONF has Interface keys this helper will not rebuild: $(printf '%s' "$bad_keys" | tr '\n' ' ')"
  fi

  tmp="/tmp/$DEVICE.new.$$.conf"
  {
    printf '[Interface]\n'
    sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | sed 's/^/PrivateKey = /'
    sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | sed 's/^/Address = /'
    sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | sed 's/^/ListenPort = /'
    printf 'SaveConfig = %s\n' "$save_config"
    render_hooks
    printf '\n'
    sed -n '/^[[:space:]]*\[Peer\]/,$p' "$CONF"
    render_peer "$CLIENT_PUBLIC_KEY" "$primary_ip"
    if [ "$MODE" = "dual" ]; then
      render_peer "$WARP_CLIENT_PUBLIC_KEY" "$warp_ip"
    fi
  } >"$tmp"
  chmod 0600 "$tmp"

  log "new config rendered: $tmp"
  sed 's/^PrivateKey.*/PrivateKey = <REDACTED>/' "$tmp"

  # 3. Validate before touching anything. wg-quick exits 0 even when it leaks a
  #    wg-quick-only directive, so inspect the stripped output explicitly.
  local stripped
  if ! stripped="$(wg-quick strip "$tmp" 2>/dev/null)"; then
    fail "rendered config failed wg-quick validation; nothing was changed"
  fi
  local leaked
  leaked="$(printf '%s\n' "$stripped" |
    grep -E '^[[:space:]]*(SaveConfig|PostUp|PostDown|PreUp|PreDown|DNS|MTU|Table)[[:space:]]*=' || true)"
  if [ -n "$leaked" ]; then
    fail "rendered config still leaks wg-quick-only directives: $(printf '%s' "$leaked" | tr '\n' ' '); nothing was changed"
  fi
  if ! printf '%s\n' "$stripped" | grep -q '^PrivateKey'; then
    fail "rendered config lost the server PrivateKey; nothing was changed"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: stopping before backup and apply"
    return 0
  fi

  cp -a "$CONF" "$backup"
  log "backup: $backup"
  ROLLBACK_BACKUP="$backup"

  sort -u -o "$NAT_V4_FILE" "$NAT_V4_FILE.seed"
  rm -f "$NAT_V4_FILE.seed"
  chmod 0600 "$NAT_V4_FILE"

  install -m 0600 "$tmp" "$CONF"
  log "installed: $CONF"

  # 4. Hot apply. The interface stays up; existing peers keep their sessions.
  #    If the apply fails for any reason, put the previous config straight back
  #    so the node never keeps a broken file on disk.
  require_command wg
  if ! wg syncconf "$DEVICE" <(wg-quick strip "$CONF"); then
    log "syncconf FAILED - restoring $CONF from $backup"
    cp -a "$backup" "$CONF"
    fail "hot apply failed; the previous config has been restored, nothing was lost"
  fi
  log "hot applied with wg syncconf"

  # 5. NAT rules for the new direct client (PostUp only runs on interface start).
  if [ -n "$direct_ip" ] && [ "$MODE" != "warp" ]; then
    while read -r ip; do
      [ -n "$ip" ] || continue
      iptables -t nat -C POSTROUTING -s "$ip/32" -o "$EGRESS" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$ip/32" -o "$EGRESS" -j MASQUERADE
    done <"$NAT_V4_FILE"
    log "MASQUERADE rules reconciled from $NAT_V4_FILE"
  fi

  # 6. WARP forwarding for the new warp client.
  if [ "$REGISTER_WARP" = "true" ] && [ -n "$warp_ip" ]; then
    register_warp_client "$warp_ip"
  fi

  # 7. Client configs.
  mkdir -p "$CONFIG_DIR"
  chmod 0700 "$CONFIG_DIR"
  CLIENT_DIRECT_FILE=""
  CLIENT_WARP_FILE=""
  local direct_file warp_file
  case "$MODE" in
    dual)
      direct_file="$CONFIG_DIR/$NAME-direct.conf"
      warp_file="$CONFIG_DIR/$NAME-warp.conf"
      ;;
    warp)
      warp_file="$CONFIG_DIR/$NAME.conf"
      ;;
    *)
      direct_file="$CONFIG_DIR/$NAME.conf"
      ;;
  esac
  if [ -n "$direct_ip" ] && [ -n "$direct_file" ]; then
    render_client_config "$direct_ip" "$CLIENT_PRIVATE_KEY" >"$direct_file"
    chmod 0600 "$direct_file"
    CLIENT_DIRECT_FILE="$direct_file"
  fi
  if [ -n "$warp_ip" ] && [ -n "$warp_file" ]; then
    render_client_config "$warp_ip" "$WARP_CLIENT_PRIVATE_KEY" >"$warp_file"
    chmod 0600 "$warp_file"
    CLIENT_WARP_FILE="$warp_file"
  fi

  cat >"$CLIENT_STATE_DIR/$NAME.env" <<EOF
NAME='$NAME'
MODE='$MODE'
CREATED_AT='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
CLIENT_PUBLIC_KEY='$CLIENT_PUBLIC_KEY'
CLIENT_PRIVATE_KEY='$CLIENT_PRIVATE_KEY'
CLIENT_IPV4='$direct_ip'
WARP_CLIENT_PUBLIC_KEY='$WARP_CLIENT_PUBLIC_KEY'
WARP_CLIENT_PRIVATE_KEY='$WARP_CLIENT_PRIVATE_KEY'
WARP_CLIENT_IPV4='$warp_ip'
ENDPOINT='$ENDPOINT'
EOF
  chmod 0600 "$CLIENT_STATE_DIR/$NAME.env"

  printf '\n'
  printf '===== client added =====\n'
  printf '  name        : %s\n' "$NAME"
  printf '  mode        : %s\n' "$MODE"
  printf '  device      : %s\n' "$DEVICE"
  printf '  endpoint    : %s\n' "$ENDPOINT"
  printf '  server addr : %s\n' "$SERVER_ADDRESS"
  if [ -n "$direct_ip" ]; then
    printf '  direct addr : %s\n' "$direct_ip"
    printf '  direct file : %s\n' "$CLIENT_DIRECT_FILE"
  fi
  if [ -n "$warp_ip" ]; then
    printf '  warp addr   : %s\n' "$warp_ip"
    printf '  warp file   : %s\n' "$CLIENT_WARP_FILE"
  fi
  printf '  rollback    : cp %s %s && wg syncconf %s <(wg-quick strip %s)\n' "$backup" "$CONF" "$DEVICE" "$CONF"

  if [ "$PRINT_CONFIG" = "true" ]; then
    if [ -n "$CLIENT_DIRECT_FILE" ] && [ -r "$CLIENT_DIRECT_FILE" ]; then
      printf '\n----- BEGIN direct config (%s) -----\n' "$NAME"
      cat "$CLIENT_DIRECT_FILE"
      printf -- '----- END direct config (%s) -----\n' "$NAME"
    fi
    if [ -n "$CLIENT_WARP_FILE" ] && [ -r "$CLIENT_WARP_FILE" ]; then
      printf '\n----- BEGIN WARP config (%s) -----\n' "$NAME"
      cat "$CLIENT_WARP_FILE"
      printf -- '----- END WARP config (%s) -----\n' "$NAME"
    fi
  fi
}

list_clients() {
  load_conf_meta
  printf 'device=%s listen=%s server=%s egress=%s\n' \
    "$DEVICE" \
    "$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '[:space:]')" \
    "$SERVER_ADDRESS" "$EGRESS"
  printf '\n--- peers currently in %s ---\n' "$CONF"
  if command -v wg >/dev/null 2>&1; then
    wg show "$DEVICE" 2>/dev/null || true
  fi
  printf '\n--- managed clients ---\n'
  local f found=0
  for f in "$CLIENT_STATE_DIR"/*.env; do
    [ -e "$f" ] || continue
    found=1
    NAME=""
    MODE=""
    CLIENT_IPV4=""
    WARP_CLIENT_IPV4=""
    CREATED_AT=""
    # shellcheck disable=SC1090
    . "$f"
    printf '\n  name     : %s\n' "$NAME"
    printf '    mode     : %s\n' "$MODE"
    printf '    created  : %s\n' "$CREATED_AT"
    printf '    direct   : %s\n' "${CLIENT_IPV4:-none}"
    printf '    warp     : %s\n' "${WARP_CLIENT_IPV4:-none}"
  done
  if [ "$found" -eq 0 ]; then
    printf '\n  (none)\n'
  fi
}

remove_client() {
  NAME="$(sanitize_name "$NAME")"
  local state="$CLIENT_STATE_DIR/$NAME.env"
  [ -r "$state" ] || fail "no managed client named $NAME (see action=list)"
  load_conf_meta

  local cpub wpub dip wip created mode
  NAME=""
  MODE=""
  CLIENT_PUBLIC_KEY=""
  CLIENT_IPV4=""
  WARP_CLIENT_PUBLIC_KEY=""
  WARP_CLIENT_IPV4=""
  CREATED_AT=""
  # shellcheck disable=SC1090
  . "$state"
  cpub="$CLIENT_PUBLIC_KEY"
  wpub="$WARP_CLIENT_PUBLIC_KEY"
  dip="$CLIENT_IPV4"
  wip="$WARP_CLIENT_IPV4"
  created="$CREATED_AT"
  mode="$MODE"

  log "removing client $NAME (created $created, mode $mode)"

  local ts backup tmp
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$CONF.bak.$ts"
  tmp="/tmp/$DEVICE.remove.$$.conf"

  # Drop whole [Peer] paragraphs whose PublicKey matches. Paragraph mode keeps
  # every other line of the file byte-identical.
  awk -v k1="$cpub" -v k2="$wpub" '
    BEGIN { RS = "" }
    index($0, "PublicKey = " k1) > 0 { next }
    k2 != "" && index($0, "PublicKey = " k2) > 0 { next }
    { printf "%s\n\n", $0 }
  ' "$CONF" >"$tmp"

  # Guard against a paragraph-mode surprise wiping unrelated peers.
  local before after expected
  before="$(grep -c '^[[:space:]]*\[Peer\]' "$CONF" || true)"
  after="$(grep -c '^[[:space:]]*\[Peer\]' "$tmp" || true)"
  expected=1
  if [ -n "$wpub" ]; then
    expected=2
  fi
  if [ "$((before - after))" -ne "$expected" ]; then
    fail "removal render dropped $((before - after)) peers but $expected was targeted; nothing was changed"
  fi

  local stripped_removed
  if ! stripped_removed="$(wg-quick strip "$tmp" 2>/dev/null)"; then
    fail "removal render failed validation; nothing was changed"
  fi
  if printf '%s\n' "$stripped_removed" |
    grep -qE '^[[:space:]]*(SaveConfig|PostUp|PostDown|PreUp|PreDown|DNS|MTU|Table)[[:space:]]*='; then
    fail "removal render leaks wg-quick-only directives; nothing was changed"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: would install:"
    sed 's/^PrivateKey.*/PrivateKey = <REDACTED>/' "$tmp"
    return 0
  fi

  cp -a "$CONF" "$backup"
  install -m 0600 "$tmp" "$CONF"
  if ! wg syncconf "$DEVICE" <(wg-quick strip "$CONF"); then
    log "syncconf FAILED - restoring $CONF from $backup"
    cp -a "$backup" "$CONF"
    fail "removal hot apply failed; the previous config has been restored"
  fi
  log "hot applied removal"

  if [ -n "$dip" ] && [ -r "$NAT_V4_FILE" ]; then
    while iptables -t nat -C POSTROUTING -s "${dip}/32" -o "$EGRESS" -j MASQUERADE >/dev/null 2>&1; do
      run iptables -t nat -D POSTROUTING -s "${dip}/32" -o "$EGRESS" -j MASQUERADE
    done
    grep -vxF "$dip" "$NAT_V4_FILE" >"$NAT_V4_FILE.new" || true
    mv "$NAT_V4_FILE.new" "$NAT_V4_FILE"
  fi

  if [ "$REGISTER_WARP" = "true" ] && [ -n "$wip" ]; then
    unregister_warp_client "$wip"
  fi

  rm -f "$state" "$CONFIG_DIR/$NAME.conf" "$CONFIG_DIR/$NAME-direct.conf" "$CONFIG_DIR/$NAME-warp.conf"
  log "removed $NAME; other peers keep their tunnels"
  log "rollback: cp $backup $CONF && wg syncconf $DEVICE <(wg-quick strip $CONF)"
}

install_shortcut() {
  local target="/usr/local/bin/wpl-add-client"
  local src dir
  if [ "${INSTALL_SHORTCUT:-true}" = "false" ]; then
    return 0
  fi
  dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  src="$dir/$(basename -- "${BASH_SOURCE[0]}")"
  [ "$src" != "$target" ] || return 0
  if ln -sf "$src" "$target" 2>/dev/null; then
    chmod 0755 "$target" 2>/dev/null || true
    log "已安装短命令: $target"
  elif cp -f "$src" "$target" 2>/dev/null; then
    chmod 0755 "$target" 2>/dev/null || true
    log "已安装短命令: $target"
  fi
  return 0
}

prompt() {
  local var="$1" label="$2" default="${3:-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  if ! IFS= read -r reply; then
    fail "no input received; nothing was changed"
  fi
  reply="${reply:-$default}"
  reply="$(printf '%s' "$reply" | tr -d '[:space:]')"
  printf -v "$var" '%s' "$reply"
}

detect_single_device() {
  local found
  found="$(find /etc/wireguard -maxdepth 1 -name 'wp*.conf' -type f 2>/dev/null | sort)"
  local count
  count="$(printf '%s\n' "$found" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then
    basename "$found" .conf
    return 0
  fi
  return 1
}

last_known_endpoint() {
  local f
  for f in "$CLIENT_STATE_DIR"/*.env; do
    [ -e "$f" ] || continue
    grep -h '^ENDPOINT=' "$f" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d "'"
  done
}

listen_port_hint() {
  sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*//p' "$CONF" 2>/dev/null |
    head -n 1 | tr -d '[:space:]'
}

# On a 1:1 NAT VPS every client reaches the node from the same public address,
# so the most frequent peer endpoint is a good guess for it.
guess_public_ip() {
  local ip=""
  if command -v wg >/dev/null 2>&1; then
    ip="$(wg show "$DEVICE" endpoints 2>/dev/null |
      awk '{print $2}' |
      sed 's/^\[//; s/\]:.*//; s/:.*//' |
      grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' |
      sort | uniq -c | sort -rn | head -n 1 | awk '{print $2}')"
  fi
  if [ -z "$ip" ]; then
    ip="$(last_known_endpoint | head -n 1 | sed 's/^\[//; s/\]:.*//; s/:.*//')"
  fi
  printf '%s' "$ip"
}

last_known_port() {
  last_known_endpoint | head -n 1 | awk -F: '{print $NF}'
}

interactive() {
  ACTION="add"
  install_shortcut
  printf '\n'
  printf '===== WarpPool 出口节点：接入非主服务器客户端 =====\n\n'

  if [ -z "$DEVICE" ]; then
    if DEVICE="$(detect_single_device)"; then
      log "自动识别出口节点设备: $DEVICE"
    else
      prompt DEVICE "出口节点 WireGuard 设备名（/etc/wireguard/<name>.conf）" ""
    fi
  fi
  state_paths

  if [ "$MODE_SET" != "true" ]; then
    while true; do
      prompt MODE_CHOICE "出口模式   1=direct 本机出口   2=warp WARP出口   3=dual 两者都要" "1"
      case "$MODE_CHOICE" in
        1|direct)
          MODE="direct"
          log "出口模式: direct（流量走本机出口 IP）"
          break
          ;;
        2|warp)
          MODE="warp"
          log "出口模式: warp（流量走 Cloudflare WARP 出口 IP）"
          break
          ;;
        3|dual)
          MODE="dual"
          log "出口模式: dual（本机出口 + WARP 出口 各一条隧道）"
          break
          ;;
        *) log "请输入 1、2 或 3" ;;
      esac
    done
  fi

  if [ -z "$NAME" ]; then
    if [ "$MODE" = "warp" ]; then
      prompt NAME "客户端名称（这条是 WARP 隧道，建议和直连那条区分开，例如 pc-warp）" "pc-warp"
    else
      prompt NAME "客户端名称（用于标记这台客户端）" "pc"
    fi
  fi

  while true; do
    prompt CLIENT_PUBLIC_KEY "粘贴客户端公钥（WireGuard 生成，44 字符；直接回车则由本节点生成）" ""
    if [ -z "$CLIENT_PUBLIC_KEY" ]; then
      require_command wg
      CLIENT_PRIVATE_KEY="$(wg genkey)"
      CLIENT_PUBLIC_KEY="$(printf '%s' "$CLIENT_PRIVATE_KEY" | wg pubkey)"
      log "已在本节点生成密钥对，私钥会直接写进配置"
      break
    fi
    if is_public_key "$CLIENT_PUBLIC_KEY"; then
      break
    fi
    log "公钥格式不对，请重新输入，或直接回车让本节点生成"
  done

  if [ "$MODE" = "dual" ]; then
    while true; do
      prompt WARP_CLIENT_PUBLIC_KEY "粘贴第二条 WARP 隧道公钥（必须与上面不同；直接回车则由本节点生成）" ""
      if [ -z "$WARP_CLIENT_PUBLIC_KEY" ]; then
        require_command wg
        WARP_CLIENT_PRIVATE_KEY="$(wg genkey)"
        WARP_CLIENT_PUBLIC_KEY="$(printf '%s' "$WARP_CLIENT_PRIVATE_KEY" | wg pubkey)"
        log "已在本节点生成 WARP 密钥对，私钥会直接写进配置"
        break
      fi
      if ! is_public_key "$WARP_CLIENT_PUBLIC_KEY"; then
        log "公钥格式不对，请重新输入，或直接回车让本节点生成"
        continue
      fi
      if [ "$WARP_CLIENT_PUBLIC_KEY" = "$CLIENT_PUBLIC_KEY" ]; then
        log "两条隧道不能用同一个公钥（同一接口不允许重复 peer key），请换一个，或直接回车让本节点生成"
        continue
      fi
      break
    done
  fi

  if [ -z "$ENDPOINT" ]; then
    local lp ip_hint port_hint
    lp="$(listen_port_hint)"
    [ -n "$lp" ] || lp="51820"
    ip_hint="$(guess_public_ip)"
    port_hint="$(last_known_port)"
    printf '\n'
    printf '出口节点 %s 在本机监听 UDP %s\n' "$DEVICE" "$lp"
    printf 'NAT 上需要有一条 公网端口 -> 本机 %s 的 UDP 映射，客户端连的就是这条映射\n' "$lp"
    printf '（主服务器用的就是这条映射，请填相同的公网端口）\n\n'
    prompt PUB_IP "公网 IP（NAT 机器对外的地址）" "$ip_hint"
    prompt PUB_PORT "公网映射端口（NAT 上的外部端口）" "$port_hint"
    if [ -z "$PUB_IP" ]; then
      fail "公网 IP 不能为空"
    fi
    if [ -z "$PUB_PORT" ]; then
      fail "公网映射端口不能为空"
    fi
    case "$PUB_PORT" in
      ""|*[!0-9]*) fail "公网映射端口必须是数字: $PUB_PORT" ;;
    esac
    if [ "$PUB_PORT" -lt 1 ] || [ "$PUB_PORT" -gt 65535 ]; then
      fail "公网映射端口必须在 1-65535 之间: $PUB_PORT"
    fi
    ENDPOINT="$PUB_IP:$PUB_PORT"
    printf '\n'
    printf '已拼装 endpoint = %s   （映射到本机 UDP %s）\n' "$ENDPOINT" "$lp"
  fi

  printf '\n'
  NAME="$(sanitize_name "$NAME")"
  printf '即将执行：\n'
  printf '  出口节点设备 : %s\n' "$DEVICE"
  printf '  出口模式     : %s\n' "$MODE"
  printf '  客户端名称   : %s\n' "$NAME"
  printf '  直连公钥     : %s\n' "$CLIENT_PUBLIC_KEY"
  if [ "$MODE" = "dual" ]; then
    printf '  WARP 公钥    : %s\n' "$WARP_CLIENT_PUBLIC_KEY"
  fi
  printf '  公网 IP      : %s\n' "${ENDPOINT%%:*}"
  printf '  公网端口     : %s  (NAT 上映射到本机 UDP %s)\n' "${ENDPOINT##*:}" "$(listen_port_hint)"
  printf '  公网 endpoint: %s\n' "$ENDPOINT"
  printf '\n确认执行？输入 yes 继续，其他任意键取消：'
  local answer
  IFS= read -r answer || answer=""
  case "$answer" in
    yes|Yes|YES|y|Y) ;;
    *)
      printf '\n已取消，未做任何改动。\n'
      exit 0
      ;;
  esac
  printf '\n'
}

print_next_steps() {
  local key_note="PrivateKey = REPLACE_WITH_YOUR_PRIVATE_KEY"
  if [ -n "$CLIENT_PRIVATE_KEY" ]; then
    key_note="PrivateKey 已由本节点生成，直接可用"
  fi
  printf '\n'
  printf '===== 接下来在你电脑上做什么 =====\n'
  if [ -n "$CLIENT_DIRECT_FILE" ] && [ -r "$CLIENT_DIRECT_FILE" ]; then
    printf '1. 取配置：%s\n' "$CLIENT_DIRECT_FILE"
  fi
  if [ -n "$CLIENT_WARP_FILE" ] && [ -r "$CLIENT_WARP_FILE" ]; then
    printf '2. 取配置：%s\n' "$CLIENT_WARP_FILE"
  fi
  printf '3. %s\n' "$key_note"
  printf '4. 用 WireGuard for Windows「添加空隧道 → 导入配置」导入\n'
  printf '5. 启用后在本机执行：curl https://www.cloudflare.com/cdn-cgi/trace\n'
  printf '   看 ip= 那一行确认出口已经变成目标机房\n'

  if [ "$MODE" = "direct" ]; then
    printf '\n如果这台电脑还想要 WARP 出口：\n'
    printf '  再跑一次 wpl-add-client，模式选 2，名称用 %s-warp，用另一组密钥\n' "$NAME"
  fi
  if [ "$MODE" = "warp" ]; then
    printf '\nWARP 转发只处理 TCP，UDP 不会被转发也不会 NAT，会被丢弃。\n'
    printf '如果这台电脑还想要 UDP 可用的直连出口：\n'
    printf '  再跑一次 wpl-add-client，模式选 1，名称用 %s-direct，用另一组密钥\n' "${NAME%-warp}"
  fi
  if [ "$MODE" = "dual" ]; then
    printf '\n两份配置 AllowedIPs 都是 0.0.0.0/0，一次只能启用其中一份。\n'
    printf 'WARP 那份只有 TCP 走 WARP；需要 UDP 时切换到直连那份。\n'
  fi

  printf '\n回滚命令：\n'
  printf '  cp %s %s && wg syncconf %s <(wg-quick strip %s)\n' "$ROLLBACK_BACKUP" "$CONF" "$DEVICE" "$CONF"
}

main() {
  parse_args "$@"
  require_root
  local was_interactive="false"
  if [ "$#" -eq 0 ] || [ "$INTERACTIVE" = "true" ]; then
    was_interactive="true"
    log "legacy_add_client.sh $SCRIPT_VERSION"
    interactive
  fi
  validate_args
  state_paths
  require_root

  case "$ACTION" in
    add)
      add_client
      if [ "$was_interactive" = "true" ]; then
        print_next_steps
      fi
      ;;
    list)
      list_clients
      ;;
    remove)
      remove_client
      ;;
  esac
}

main "$@"