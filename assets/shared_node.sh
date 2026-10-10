#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="add"
MODE="direct"
DEVICE="wpshared"
LISTEN_PORT="51820"
SERVER_ADDR="10.200.0.1/24"
SERVER_IPV6_ADDR=""
ENABLE_IPV6="false"
CLIENT_PUBLIC_KEY=""
WARP_CLIENT_PUBLIC_KEY=""
EGRESS_INTERFACE=""
SKIP_UP="false"
STATE_DIR="/etc/warppool-node/shared"
DRY_RUN="false"
REQUESTED_SERVER_IPV6_ADDR=""

# Extra non-main-server client support (action=add-client / list / remove)
BASE_URL="${WARPPOOL_INSTALL_BASE_URL:-${WARPOOL_INSTALL_BASE_URL:-https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets}}"
DOWNLOAD_DIR="/tmp/warppool-shared.$$"
CLIENT_NAME=""
CLIENT_PRIVATE_KEY=""
WARP_CLIENT_PRIVATE_KEY=""
PEER_NAME=""
ENDPOINT=""
CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
CLIENT_DNS="1.1.1.1, 8.8.8.8"
CLIENT_CONFIG_DIR=""
TRANSPARENT_PORT="14000"
REMOVE_TARGET=""
PRINT_CONFIG="true"
REGISTER_WARP="true"
ALLOW_LEGACY="false"
CLIENT_DIRECT_FILE=""
CLIENT_WARP_FILE=""

log() {
  printf '[WarpPool][shared-node] %s\n' "$*"
}

fail() {
  printf '[WarpPool][shared-node][ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  local line="$1"
  printf '[WarpPool][shared-node][ERROR] command failed with exit %s at line %s: %s\n' "$status" "$line" "$BASH_COMMAND" >&2
  exit "$status"
}

cleanup_download_dir() {
  if [ -n "${DOWNLOAD_DIR:-}" ] && [ -d "$DOWNLOAD_DIR" ]; then
    rm -rf -- "$DOWNLOAD_DIR"
  fi
}

on_exit() {
  release_lock
  cleanup_download_dir
}

trap 'on_error $LINENO' ERR

usage() {
  cat <<'USAGE'
WarpPool shared node helper

Usage:
  bash shared_node.sh action=add mode=direct|warp|dual client_public_key=<key> [warp_client_public_key=<key>] [device=wpshared] [listen_port=51820] [server_addr=10.200.0.1/24] [server_ipv6_addr=fd7a:7761:7270::1/64] [enable_ipv6=true|false] [egress=<iface>] [skip_up=true|false]

  bash shared_node.sh action=add-client mode=direct|warp|dual name=<label> \
      [client_public_key=<key>] [client_private_key=<key>] \
      [warp_client_public_key=<key>] [warp_client_private_key=<key>] \
      [endpoint=<public-host:port>] [allowed_ips=0.0.0.0/0,::/0] [dns=1.1.1.1,8.8.8.8] \
      [config_dir=/root/warppool-clients] [transparent_port=14000] [register_warp=true|false]

  bash shared_node.sh action=list
  bash shared_node.sh action=remove target=<label|public-key>

This script keeps one shared WireGuard server on an exit node and appends
additional main-server peers without overwriting existing peers.

action=add-client is for non-main-server clients (a local PC, a phone, a
second admin box). It registers the peer, wires up WARP forwarding for
warp/dual mode, and renders a ready-to-import WireGuard client config with a
full-tunnel AllowedIPs list.

Set allow_legacy=true to bootstrap a shared node on a host that still has an
old /etc/wireguard/wp<name>.conf. The legacy config is left running, so use a
different listen_port for the shared device. This is for planned side-by-side
migrations only.
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
      action=*) ACTION="${arg#action=}" ;;
      mode=*) MODE="${arg#mode=}" ;;
      device=*) DEVICE="${arg#device=}" ;;
      listen_port=*) LISTEN_PORT="${arg#listen_port=}" ;;
      server_addr=*) SERVER_ADDR="${arg#server_addr=}" ;;
      server_ipv6_addr=*) SERVER_IPV6_ADDR="${arg#server_ipv6_addr=}" ;;
      enable_ipv6=*) ENABLE_IPV6="${arg#enable_ipv6=}" ;;
      client_public_key=*) CLIENT_PUBLIC_KEY="${arg#client_public_key=}" ;;
      warp_client_public_key=*) WARP_CLIENT_PUBLIC_KEY="${arg#warp_client_public_key=}" ;;
      egress=*) EGRESS_INTERFACE="${arg#egress=}" ;;
      skip_up=*) SKIP_UP="${arg#skip_up=}" ;;
      state_dir=*) STATE_DIR="${arg#state_dir=}" ;;
      name=*|client_name=*) CLIENT_NAME="${arg#*=}" ;;
      client_private_key=*) CLIENT_PRIVATE_KEY="${arg#client_private_key=}" ;;
      warp_client_private_key=*) WARP_CLIENT_PRIVATE_KEY="${arg#warp_client_private_key=}" ;;
      endpoint=*) ENDPOINT="${arg#endpoint=}" ;;
      allowed_ips=*|client_allowed_ips=*) CLIENT_ALLOWED_IPS="${arg#*=}" ;;
      dns=*|client_dns=*) CLIENT_DNS="${arg#*=}" ;;
      config_dir=*|client_config_dir=*) CLIENT_CONFIG_DIR="${arg#*=}" ;;
      transparent_port=*) TRANSPARENT_PORT="${arg#transparent_port=}" ;;
      print_config=*) PRINT_CONFIG="${arg#*=}" ;;
      register_warp=*) REGISTER_WARP="${arg#*=}" ;;
      allow_legacy=*) ALLOW_LEGACY="${arg#*=}" ;;
      target=*|remove=*) REMOVE_TARGET="${arg#*=}" ;;
      base_url=*) BASE_URL="${arg#base_url=}" ;;
      *) fail "unknown argument: $arg" ;;
    esac
  done
}

run() {
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: $*"
    return 0
  fi
  "$@"
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
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "required command not found: $name"
  fi
}

validate_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) fail "$name must be true or false, got: $value" ;;
  esac
}

validate_args() {
  case "$ACTION" in
    add|add-client|status|list|remove) ;;
    *) fail "unsupported action: $ACTION, expected add, add-client, status, list, or remove" ;;
  esac
  case "$MODE" in
    direct|warp|dual) ;;
    *) fail "unsupported mode: $MODE, expected direct, warp, or dual" ;;
  esac
  case "$DEVICE" in
    ""|*[!a-zA-Z0-9_.-]*)
      fail "invalid WireGuard device name: $DEVICE"
      ;;
  esac
  case "$LISTEN_PORT" in
    ""|*[!0-9]*) fail "invalid listen_port: $LISTEN_PORT" ;;
  esac
  if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
    fail "listen_port must be between 1 and 65535: $LISTEN_PORT"
  fi
  validate_bool enable_ipv6 "$ENABLE_IPV6"
  validate_bool skip_up "$SKIP_UP"
  validate_bool print_config "$PRINT_CONFIG"
  validate_bool register_warp "$REGISTER_WARP"
  validate_bool allow_legacy "$ALLOW_LEGACY"
  case "$TRANSPARENT_PORT" in
    ""|*[!0-9]*) fail "invalid transparent_port: $TRANSPARENT_PORT" ;;
  esac
  if [ "$ACTION" = "add" ] || [ "$ACTION" = "add-client" ]; then
    if [ -z "$CLIENT_PUBLIC_KEY" ] && [ -z "$CLIENT_PRIVATE_KEY" ]; then
      if [ "$ACTION" = "add" ]; then
        fail "client_public_key is required"
      fi
      log "no client keypair supplied; this node will generate one"
    fi
    if [ "$MODE" = "dual" ] && [ -z "$WARP_CLIENT_PUBLIC_KEY" ] && [ -z "$WARP_CLIENT_PRIVATE_KEY" ]; then
      if [ "$ACTION" = "add" ]; then
        fail "warp_client_public_key is required in dual mode"
      fi
      log "no WARP client keypair supplied; this node will generate one"
    fi
  fi
  if [ "$ACTION" = "remove" ]; then
    [ -n "$REMOVE_TARGET" ] || fail "remove requires target=<label|public-key>"
  fi
}

state_paths() {
  REQUESTED_SERVER_IPV6_ADDR="$SERVER_IPV6_ADDR"
  STATE_FILE="$STATE_DIR/state.env"
  PEER_DIR="$STATE_DIR/peers"
  LOCK_DIR="$STATE_DIR.lock"
  CONFIG_PATH="/etc/wireguard/$DEVICE.conf"
  DIRECT_V4_FILE="$STATE_DIR/$DEVICE.direct-v4.txt"
  DIRECT_V6_FILE="$STATE_DIR/$DEVICE.direct-v6.txt"
}

release_lock() {
  if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
  fi
}

acquire_lock() {
  local attempt
  mkdir -p "$(dirname "$STATE_DIR")"
  for attempt in $(seq 1 30); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      trap on_exit EXIT
      return 0
    fi
    sleep 1
  done
  fail "shared node state is locked by another deployment: $LOCK_DIR"
}

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
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
  dir="$(script_dir)"
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

format_endpoint_host() {
  local value="$1"
  value="${value#[}"
  value="${value%]}"
  case "$value" in
    *:*)
      printf '[%s]\n' "$value"
      return 0
      ;;
  esac
  printf '%s\n' "$value"
}

detect_public_endpoint() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- -T 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  [ -n "$ip" ] || return 1
  printf '%s:%s\n' "$(format_endpoint_host "$ip")" "$LISTEN_PORT"
}

load_state() {
  if [ ! -r "$STATE_FILE" ]; then
    return 1
  fi
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  if [ "${DEVICE_NAME:-}" != "$DEVICE" ]; then
    fail "shared node state belongs to device ${DEVICE_NAME:-unknown}, but requested device is $DEVICE"
  fi
  if [ -z "$EGRESS_INTERFACE" ] && [ -n "${SAVED_EGRESS_INTERFACE:-}" ]; then
    EGRESS_INTERFACE="$SAVED_EGRESS_INTERFACE"
  fi
  return 0
}

ipv4_base_from_server() {
  local ip
  ip="${SERVER_ADDR%%/*}"
  case "$ip" in
    *.*.*.*) ;;
    *) fail "invalid server_addr: $SERVER_ADDR" ;;
  esac
  printf '%s\n' "${ip%.*}"
}

init_state() {
  mkdir -p "$STATE_DIR" "$PEER_DIR" /etc/wireguard
  if load_state; then
    if [ -n "$EGRESS_INTERFACE" ] && [ "${SAVED_EGRESS_INTERFACE:-}" != "$EGRESS_INTERFACE" ]; then
      SAVED_EGRESS_INTERFACE="$EGRESS_INTERFACE"
      write_state
      log "updated shared direct egress interface: $EGRESS_INTERFACE"
    fi
    if [ "$ENABLE_IPV6" = "true" ] && [ -z "$SERVER_IPV6_ADDR" ]; then
      SERVER_IPV6_ADDR="${REQUESTED_SERVER_IPV6_ADDR:-fd7a:7761:7270::1/64}"
      write_state
      log "enabled IPv6 addressing for existing shared node"
    fi
    log "using existing shared WireGuard state: $STATE_FILE"
    return 0
  fi

  if [ -e "$CONFIG_PATH" ]; then
    fail "$CONFIG_PATH already exists but $STATE_FILE is missing; this looks like a legacy or manual config. Remove it with warppool-node-uninstall or choose a clean node before enabling shared mode."
  fi
  local legacy legacy_name
  for legacy in /etc/wireguard/wp*.conf; do
    [ -e "$legacy" ] || continue
    legacy_name="$(basename "$legacy" .conf)"
    [ "$legacy_name" = "$DEVICE" ] && continue
    if [ "$ALLOW_LEGACY" = "true" ]; then
      log "warning: legacy config left untouched: $legacy (allow_legacy=true)"
      continue
    fi
    fail "existing legacy WarpPool WireGuard config detected: $legacy. Shared mode will not convert it automatically; remove it with warppool-node-uninstall or use a clean node. Note: when $STATE_FILE already exists this check is skipped."
  done

  require_command wg
  SERVER_PRIVATE_KEY="$(wg genkey)"
  SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)"
  IPV4_BASE="$(ipv4_base_from_server)"
  SERVER_IPV4_NETWORK="$IPV4_BASE.0/24"
  SAVED_EGRESS_INTERFACE="$EGRESS_INTERFACE"
  NEXT_IPV4="2"
  NEXT_IPV6="2"
  if [ "$ENABLE_IPV6" = "true" ] && [ -z "$SERVER_IPV6_ADDR" ]; then
    SERVER_IPV6_ADDR="fd7a:7761:7270::1/64"
  fi

  write_state
  log "initialized shared WireGuard state: $STATE_FILE"
}

quote_env() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

write_state() {
  local tmp
  tmp="$STATE_FILE.tmp"
  mkdir -p "$STATE_DIR" "$PEER_DIR"
  cat >"$tmp" <<EOF
VERSION=1
DEVICE_NAME=$(quote_env "$DEVICE")
LISTEN_PORT=$(quote_env "$LISTEN_PORT")
SERVER_PRIVATE_KEY=$(quote_env "$SERVER_PRIVATE_KEY")
SERVER_PUBLIC_KEY=$(quote_env "$SERVER_PUBLIC_KEY")
SERVER_ADDR=$(quote_env "$SERVER_ADDR")
SERVER_IPV6_ADDR=$(quote_env "$SERVER_IPV6_ADDR")
IPV4_BASE=$(quote_env "$IPV4_BASE")
SERVER_IPV4_NETWORK=$(quote_env "$SERVER_IPV4_NETWORK")
SAVED_EGRESS_INTERFACE=$(quote_env "$EGRESS_INTERFACE")
NEXT_IPV4=$(quote_env "$NEXT_IPV4")
NEXT_IPV6=$(quote_env "$NEXT_IPV6")
EOF
  chmod 0600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

peer_id() {
  local rand
  if command -v od >/dev/null 2>&1; then
    rand="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  fi
  [ -n "${rand:-}" ] || rand="$$"
  printf 'peer-%s-%s\n' "$(date +%s)" "$rand"
}

allocate_ipv4() {
  local next
  next="$NEXT_IPV4"
  if [ "$next" -gt 254 ]; then
    fail "shared IPv4 pool exhausted for $SERVER_IPV4_NETWORK"
  fi
  ALLOCATED_IPV4="$IPV4_BASE.$next/32"
  NEXT_IPV4=$((next + 1))
}

allocate_ipv6() {
  local next hex
  ALLOCATED_IPV6=""
  if [ -z "$SERVER_IPV6_ADDR" ]; then
    return 0
  fi
  next="$NEXT_IPV6"
  if [ "$next" -gt 65534 ]; then
    fail "shared IPv6 pool exhausted"
  fi
  hex="$(printf '%x' "$next")"
  ALLOCATED_IPV6="fd7a:7761:7270::$hex/128"
  NEXT_IPV6=$((next + 1))
}

write_peer() {
  local id path
  id="$(peer_id)"
  path="$PEER_DIR/$id.env"

  allocate_ipv4
  CLIENT_IPV4="$ALLOCATED_IPV4"
  allocate_ipv6
  CLIENT_IPV6="$ALLOCATED_IPV6"

  WARP_CLIENT_IPV4=""
  WARP_CLIENT_IPV6=""
  if [ "$MODE" = "dual" ]; then
    allocate_ipv4
    WARP_CLIENT_IPV4="$ALLOCATED_IPV4"
    allocate_ipv6
    WARP_CLIENT_IPV6="$ALLOCATED_IPV6"
  fi

  write_state
  cat >"$path" <<EOF
MODE=$(quote_env "$MODE")
NAME=$(quote_env "$PEER_NAME")
CLIENT_PUBLIC_KEY=$(quote_env "$CLIENT_PUBLIC_KEY")
CLIENT_PRIVATE_KEY=$(quote_env "$CLIENT_PRIVATE_KEY")
CLIENT_IPV4=$(quote_env "$CLIENT_IPV4")
CLIENT_IPV6=$(quote_env "$CLIENT_IPV6")
WARP_CLIENT_PUBLIC_KEY=$(quote_env "$WARP_CLIENT_PUBLIC_KEY")
WARP_CLIENT_PRIVATE_KEY=$(quote_env "$WARP_CLIENT_PRIVATE_KEY")
WARP_CLIENT_IPV4=$(quote_env "$WARP_CLIENT_IPV4")
WARP_CLIENT_IPV6=$(quote_env "$WARP_CLIENT_IPV6")
CREATED_AT=$(quote_env "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
EOF
  chmod 0600 "$path"
  PEER_PATH="$path"
  RESPONSE_CLIENT_IPV4="$CLIENT_IPV4"
  RESPONSE_CLIENT_IPV6="$CLIENT_IPV6"
  RESPONSE_WARP_CLIENT_IPV4="$WARP_CLIENT_IPV4"
  RESPONSE_WARP_CLIENT_IPV6="$WARP_CLIENT_IPV6"
  log "registered shared peer: $id"
}

write_direct_client_files() {
  : >"$DIRECT_V4_FILE"
  : >"$DIRECT_V6_FILE"
  local peer mode client_ipv4 client_ipv6
  for peer in "$PEER_DIR"/*.env; do
    [ -e "$peer" ] || continue
    MODE=""
    CLIENT_IPV4=""
    CLIENT_IPV6=""
    # shellcheck disable=SC1090
    . "$peer"
    mode="$MODE"
    client_ipv4="$CLIENT_IPV4"
    client_ipv6="$CLIENT_IPV6"
    case "$mode" in
      direct|dual)
        [ -n "$client_ipv4" ] && printf '%s\n' "${client_ipv4%%/*}" >>"$DIRECT_V4_FILE"
        [ -n "$client_ipv6" ] && printf '%s\n' "${client_ipv6%%/*}" >>"$DIRECT_V6_FILE"
        ;;
    esac
  done
  chmod 0600 "$DIRECT_V4_FILE" "$DIRECT_V6_FILE"
}

render_forwarding_hooks() {
  local ipv4_up ipv4_down ipv6_up ipv6_down
  ipv4_up="sysctl -w net.ipv4.ip_forward=1; iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; if [ -r $DIRECT_V4_FILE ]; then while read ip; do [ -n \"\$ip\" ] || continue; iptables -t nat -C POSTROUTING -s \"\$ip/32\" -o $EGRESS_INTERFACE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s \"\$ip/32\" -o $EGRESS_INTERFACE -j MASQUERADE; done < $DIRECT_V4_FILE; fi"
  ipv4_down="iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; if [ -r $DIRECT_V4_FILE ]; then while read ip; do [ -n \"\$ip\" ] || continue; iptables -t nat -D POSTROUTING -s \"\$ip/32\" -o $EGRESS_INTERFACE -j MASQUERADE 2>/dev/null || true; done < $DIRECT_V4_FILE; fi"
  printf 'PostUp = %s\n' "$ipv4_up"
  printf 'PostDown = %s\n' "$ipv4_down"
  if [ -n "$SERVER_IPV6_ADDR" ]; then
    ipv6_up="sysctl -w net.ipv6.conf.all.forwarding=1; ip6tables -C FORWARD -i %i -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -C FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; if [ -r $DIRECT_V6_FILE ]; then while read ip; do [ -n \"\$ip\" ] || continue; ip6tables -t nat -C POSTROUTING -s \"\$ip/128\" -o $EGRESS_INTERFACE -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s \"\$ip/128\" -o $EGRESS_INTERFACE -j MASQUERADE; done < $DIRECT_V6_FILE; fi"
    ipv6_down="ip6tables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; ip6tables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; if [ -r $DIRECT_V6_FILE ]; then while read ip; do [ -n \"\$ip\" ] || continue; ip6tables -t nat -D POSTROUTING -s \"\$ip/128\" -o $EGRESS_INTERFACE -j MASQUERADE 2>/dev/null || true; done < $DIRECT_V6_FILE; fi"
    printf 'PostUp = %s\n' "$ipv6_up"
    printf 'PostDown = %s\n' "$ipv6_down"
  fi
}

render_peer_section() {
  local public_key="$1" ipv4="$2" ipv6="$3" allowed
  [ -n "$public_key" ] || return 0
  [ -n "$ipv4" ] || return 0
  allowed="$ipv4"
  if [ -n "$ipv6" ]; then
    allowed="$allowed, $ipv6"
  fi
  cat <<EOF

[Peer]
PublicKey = $public_key
AllowedIPs = $allowed
EOF
}

render_config() {
  local addresses peer
  write_direct_client_files
  addresses="$SERVER_ADDR"
  if [ -n "$SERVER_IPV6_ADDR" ]; then
    addresses="$addresses, $SERVER_IPV6_ADDR"
  fi

  mkdir -p /etc/wireguard
  {
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$SERVER_PRIVATE_KEY"
    printf 'Address = %s\n' "$addresses"
    printf 'ListenPort = %s\n' "$LISTEN_PORT"
    printf 'SaveConfig = false\n'
    if [ -n "$EGRESS_INTERFACE" ]; then
      render_forwarding_hooks
    fi
    for peer in "$PEER_DIR"/*.env; do
      [ -e "$peer" ] || continue
      NAME=""
      MODE=""
      CLIENT_PUBLIC_KEY=""
      CLIENT_PRIVATE_KEY=""
      CLIENT_IPV4=""
      CLIENT_IPV6=""
      WARP_CLIENT_PUBLIC_KEY=""
      WARP_CLIENT_PRIVATE_KEY=""
      WARP_CLIENT_IPV4=""
      WARP_CLIENT_IPV6=""
      # shellcheck disable=SC1090
      . "$peer"
      render_peer_section "$CLIENT_PUBLIC_KEY" "$CLIENT_IPV4" "$CLIENT_IPV6"
      render_peer_section "$WARP_CLIENT_PUBLIC_KEY" "$WARP_CLIENT_IPV4" "$WARP_CLIENT_IPV6"
    done
  } >"$CONFIG_PATH"
  chmod 0600 "$CONFIG_PATH"
  log "rendered shared WireGuard config: $CONFIG_PATH"
}

apply_direct_rules() {
  if [ -z "$EGRESS_INTERFACE" ]; then
    return 0
  fi
  require_command iptables
  run sysctl -w net.ipv4.ip_forward=1 >/dev/null
  run iptables -C FORWARD -i "$DEVICE" -j ACCEPT 2>/dev/null || run iptables -A FORWARD -i "$DEVICE" -j ACCEPT
  run iptables -C FORWARD -o "$DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || run iptables -A FORWARD -o "$DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  local ip
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    run iptables -t nat -C POSTROUTING -s "$ip/32" -o "$EGRESS_INTERFACE" -j MASQUERADE 2>/dev/null || run iptables -t nat -A POSTROUTING -s "$ip/32" -o "$EGRESS_INTERFACE" -j MASQUERADE
  done <"$DIRECT_V4_FILE"

  if [ -n "$SERVER_IPV6_ADDR" ] && command -v ip6tables >/dev/null 2>&1; then
    run sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    run ip6tables -C FORWARD -i "$DEVICE" -j ACCEPT 2>/dev/null || run ip6tables -A FORWARD -i "$DEVICE" -j ACCEPT
    run ip6tables -C FORWARD -o "$DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || run ip6tables -A FORWARD -o "$DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      run ip6tables -t nat -C POSTROUTING -s "$ip/128" -o "$EGRESS_INTERFACE" -j MASQUERADE 2>/dev/null || run ip6tables -t nat -A POSTROUTING -s "$ip/128" -o "$EGRESS_INTERFACE" -j MASQUERADE
    done <"$DIRECT_V6_FILE"
  fi
}

check_port_conflict() {
  local iface port line
  for iface in $(wg show interfaces 2>/dev/null || true); do
    [ "$iface" = "$DEVICE" ] && continue
    port="$(wg show "$iface" listen-port 2>/dev/null || true)"
    if [ "$port" = "$LISTEN_PORT" ]; then
      fail "UDP port $LISTEN_PORT is already used by WireGuard interface $iface"
    fi
  done
  if ip link show "$DEVICE" >/dev/null 2>&1; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -H -lunp 2>/dev/null | awk -v port=":$LISTEN_PORT" '$5 ~ port"$" {print; exit}' || true)"
    if [ -n "$line" ]; then
      fail "UDP port conflict: $LISTEN_PORT is already in use: $line"
    fi
  fi
}

fix_firewall_when_safe() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status 2>/dev/null | grep -Eq "(^| )$LISTEN_PORT/udp( |$)"; then
      log "allowing shared WireGuard UDP port in ufw: $LISTEN_PORT/udp"
      run ufw allow "$LISTEN_PORT/udp" >/dev/null
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    if ! firewall-cmd --query-port="$LISTEN_PORT/udp" >/dev/null 2>&1; then
      log "allowing shared WireGuard UDP port in firewalld: $LISTEN_PORT/udp"
      run firewall-cmd --add-port="$LISTEN_PORT/udp" >/dev/null
      run firewall-cmd --runtime-to-permanent >/dev/null || true
    fi
  fi

  if command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then
    if ! iptables -C INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT >/dev/null 2>&1; then
      log "allowing shared WireGuard UDP port in iptables INPUT: $LISTEN_PORT/udp"
      run iptables -I INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT
      log "warning: iptables runtime rule may not persist after reboot unless your system persists iptables rules"
    fi
  fi
}

ensure_interface_addresses() {
  local ip4 ip6
  ip4="${SERVER_ADDR%%/*}"
  if ! ip -4 addr show dev "$DEVICE" 2>/dev/null | grep -q " $ip4/"; then
    run ip -4 address add "$SERVER_ADDR" dev "$DEVICE"
  fi
  if [ -n "$SERVER_IPV6_ADDR" ]; then
    ip6="${SERVER_IPV6_ADDR%%/*}"
    if ! ip -6 addr show dev "$DEVICE" 2>/dev/null | grep -q " $ip6/"; then
      run ip -6 address add "$SERVER_IPV6_ADDR" dev "$DEVICE"
    fi
  fi
}

enable_wireguard_boot() {
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl enable "wg-quick@$DEVICE" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v rc-update >/dev/null 2>&1 && [ -e /etc/init.d/wg-quick ]; then
    run ln -sf /etc/init.d/wg-quick "/etc/init.d/wg-quick.$DEVICE"
    run rc-update add "wg-quick.$DEVICE" default >/dev/null 2>&1 || true
  fi
}

apply_config() {
  if [ "$SKIP_UP" = "true" ]; then
    log "skip WireGuard startup requested"
    return 0
  fi
  require_command ip
  require_command wg
  require_command wg-quick
  check_port_conflict
  fix_firewall_when_safe

  if ip link show "$DEVICE" >/dev/null 2>&1; then
    log "updating running shared WireGuard interface: $DEVICE"
    if [ "$DRY_RUN" = "true" ]; then
      log "dry-run: wg syncconf $DEVICE <(wg-quick strip $CONFIG_PATH)"
    else
      wg syncconf "$DEVICE" <(wg-quick strip "$CONFIG_PATH")
    fi
    ensure_interface_addresses
    apply_direct_rules
  else
    log "starting shared WireGuard interface: $DEVICE"
    run wg-quick up "$DEVICE"
  fi
  enable_wireguard_boot
}

print_response() {
  cat <<EOF
WARPPOOL_SHARED_BEGIN
DEVICE=$DEVICE
LISTEN_PORT=$LISTEN_PORT
SERVER_PUBLIC_KEY=$SERVER_PUBLIC_KEY
SERVER_ADDRESS=$SERVER_ADDR
CLIENT_ADDRESS=$RESPONSE_CLIENT_IPV4
SERVER_IPV6_ADDRESS=$SERVER_IPV6_ADDR
CLIENT_IPV6_ADDRESS=$RESPONSE_CLIENT_IPV6
WARP_CLIENT_ADDRESS=$RESPONSE_WARP_CLIENT_IPV4
WARP_CLIENT_IPV6_ADDRESS=$RESPONSE_WARP_CLIENT_IPV6
WARPPOOL_SHARED_END
EOF
}

# --- non-main-server client support ---

prepare_client() {
  PEER_NAME="$(sanitize_name "${CLIENT_NAME:-}")"
  if [ -z "$CLIENT_NAME" ]; then
    PEER_NAME="client-$(date +%s)"
  fi
  if [ -z "$PEER_NAME" ]; then
    fail "name is invalid; pass name=<label> using letters, digits, dot, dash or underscore"
  fi
  # Read existing names in a subshell: sourcing peer files would otherwise
  # overwrite MODE / *_PUBLIC_KEY / *_PRIVATE_KEY for the peer we are adding.
  local existing
  existing="$(
    for f in "$PEER_DIR"/*.env; do
      [ -e "$f" ] || continue
      NAME=""
      # shellcheck disable=SC1090
      . "$f"
      printf '%s\n' "$NAME"
    done
  )"
  if printf '%s\n' "$existing" | grep -Fxq "$PEER_NAME"; then
    fail "client name already in use: $PEER_NAME (remove it first with action=remove target=$PEER_NAME, or choose another name)"
  fi
}

ensure_client_keypair() {
  if [ -n "$CLIENT_PUBLIC_KEY" ]; then
    is_public_key "$CLIENT_PUBLIC_KEY" || fail "client_public_key does not look like a WireGuard public key"
  fi
  if [ -z "$CLIENT_PRIVATE_KEY" ]; then
    require_command wg
    CLIENT_PRIVATE_KEY="$(wg genkey)"
  fi
  if [ -z "$CLIENT_PUBLIC_KEY" ]; then
    CLIENT_PUBLIC_KEY="$(printf '%s' "$CLIENT_PRIVATE_KEY" | wg pubkey)"
  fi
  if [ "$MODE" = "dual" ]; then
    if [ -n "$WARP_CLIENT_PUBLIC_KEY" ]; then
      is_public_key "$WARP_CLIENT_PUBLIC_KEY" || fail "warp_client_public_key does not look like a WireGuard public key"
    fi
    if [ -z "$WARP_CLIENT_PRIVATE_KEY" ]; then
      require_command wg
      WARP_CLIENT_PRIVATE_KEY="$(wg genkey)"
    fi
    if [ -z "$WARP_CLIENT_PUBLIC_KEY" ]; then
      WARP_CLIENT_PUBLIC_KEY="$(printf '%s' "$WARP_CLIENT_PRIVATE_KEY" | wg pubkey)"
    fi
  fi
}

ensure_endpoint() {
  if [ -n "$ENDPOINT" ]; then
    return 0
  fi
  if ENDPOINT="$(detect_public_endpoint)"; then
    log "auto-detected public endpoint: $ENDPOINT"
    log "on a NAT VPS this is often wrong; re-run with endpoint=<public-host:port> if the client cannot connect"
    return 0
  fi
  fail "cannot detect the public endpoint; pass endpoint=<public-host:port>"
}

register_warp_clients() {
  if [ "$REGISTER_WARP" != "true" ]; then
    log "register_warp=false: skipping WARP forwarding registration"
    return 0
  fi
  case "$MODE" in
    warp)
      register_warp_client "${RESPONSE_CLIENT_IPV4%%/*}"
      ;;
    dual)
      register_warp_client "${RESPONSE_WARP_CLIENT_IPV4%%/*}"
      ;;
    *)
      return 0
      ;;
  esac
}

register_warp_client() {
  local ip="$1"
  local forwarder
  [ -n "$ip" ] || return 0
  forwarder="$(helper_path warp_forward.sh)"
  log "registering WARP forwarding client $ip on $DEVICE"
  run bash "$forwarder" action=register \
    device="$DEVICE" client_addr="$ip" \
    server_addr="$SERVER_ADDR" transparent_port="$TRANSPARENT_PORT"
}

unregister_warp_client() {
  local ip="$1"
  local forwarder
  [ -n "$ip" ] || return 0
  forwarder="$(helper_path warp_forward.sh)"
  log "unregistering WARP forwarding client $ip on $DEVICE"
  run bash "$forwarder" action=down \
    device="$DEVICE" client_addr="$ip" \
    server_addr="$SERVER_ADDR" transparent_port="$TRANSPARENT_PORT"
}

render_client_tunnel() {
  local private_key="$1" ipv4="$2" ipv6="$3"
  local address="$ipv4"
  if [ -n "$ipv6" ] && [ -n "$SERVER_IPV6_ADDR" ]; then
    address="$address, $ipv6"
  fi
  cat <<EOF
[Interface]
PrivateKey = $private_key
Address = $address
DNS = $CLIENT_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $ENDPOINT
AllowedIPs = $CLIENT_ALLOWED_IPS
PersistentKeepalive = 25
EOF
}

write_client_config() {
  CLIENT_DIRECT_FILE=""
  CLIENT_WARP_FILE=""
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: skip writing client configs"
    return 0
  fi
  local dir="$CLIENT_CONFIG_DIR"
  if [ -z "$dir" ]; then
    dir="/root/warppool-clients"
  fi
  mkdir -p "$dir"
  chmod 0700 "$dir"
  CLIENT_DIRECT_FILE="$dir/$PEER_NAME.conf"
  render_client_tunnel "$CLIENT_PRIVATE_KEY" "$RESPONSE_CLIENT_IPV4" "$RESPONSE_CLIENT_IPV6" >"$CLIENT_DIRECT_FILE"
  chmod 0600 "$CLIENT_DIRECT_FILE"
  if [ "$MODE" = "dual" ]; then
    CLIENT_WARP_FILE="$dir/$PEER_NAME-warp.conf"
    render_client_tunnel "$WARP_CLIENT_PRIVATE_KEY" "$RESPONSE_WARP_CLIENT_IPV4" "$RESPONSE_WARP_CLIENT_IPV6" >"$CLIENT_WARP_FILE"
    chmod 0600 "$CLIENT_WARP_FILE"
  fi
}

print_client_summary() {
  printf '\n'
  printf 'WarpPool client tunnel configured\n'
  printf '  name        : %s\n' "$PEER_NAME"
  printf '  mode        : %s\n' "$MODE"
  printf '  device      : %s\n' "$DEVICE"
  printf '  endpoint    : %s\n' "$ENDPOINT"
  printf '  server addr : %s\n' "$SERVER_ADDR"
  if [ "$MODE" = "dual" ]; then
    printf '  direct addr : %s\n' "$RESPONSE_CLIENT_IPV4"
    printf '  warp addr   : %s\n' "$RESPONSE_WARP_CLIENT_IPV4"
  else
    printf '  tunnel addr : %s\n' "$RESPONSE_CLIENT_IPV4"
  fi
  printf '  config file : %s\n' "${CLIENT_DIRECT_FILE:-<not written>}"
  if [ -n "$CLIENT_WARP_FILE" ]; then
    printf '  warp config : %s\n' "$CLIENT_WARP_FILE"
  fi
  case "$MODE" in
    warp|dual)
      printf '\n'
      printf 'NOTE: WARP forwarding only redirects TCP. UDP from this tunnel is dropped.\n'
      printf '      Use the direct config for UDP, or deploy mode=dual for both.\n'
      ;;
  esac
  if [ "$PRINT_CONFIG" = "true" ]; then
    if [ -n "$CLIENT_DIRECT_FILE" ] && [ -r "$CLIENT_DIRECT_FILE" ]; then
      printf '\n----- BEGIN WireGuard config: %s -----\n' "$PEER_NAME"
      cat "$CLIENT_DIRECT_FILE"
      printf -- '----- END WireGuard config: %s -----\n' "$PEER_NAME"
    fi
    if [ -n "$CLIENT_WARP_FILE" ] && [ -r "$CLIENT_WARP_FILE" ]; then
      printf '\n----- BEGIN WireGuard config: %s (WARP exit) -----\n' "$PEER_NAME"
      cat "$CLIENT_WARP_FILE"
      printf -- '----- END WireGuard config: %s (WARP exit) -----\n' "$PEER_NAME"
    fi
  fi
}

list_peers() {
  if ! load_state; then
    fail "shared state not found: $STATE_FILE"
  fi
  printf 'device=%s listen_port=%s server_addr=%s ipv6=%s\n' \
    "$DEVICE" "$LISTEN_PORT" "$SERVER_ADDR" "${SERVER_IPV6_ADDR:-<none>}"
  local found=0 f
  for f in "$PEER_DIR"/*.env; do
    [ -e "$f" ] || continue
    found=1
    NAME=""
    MODE=""
    CLIENT_PUBLIC_KEY=""
    CLIENT_IPV4=""
    WARP_CLIENT_PUBLIC_KEY=""
    WARP_CLIENT_IPV4=""
    CREATED_AT=""
    # shellcheck disable=SC1090
    . "$f"
    printf '\npeer file    : %s\n' "$(basename "$f")"
    printf '  name       : %s\n' "${NAME:-<unnamed main-server peer>}"
    printf '  mode       : %s\n' "$MODE"
    printf '  created    : %s\n' "$CREATED_AT"
    printf '  direct key : %s\n' "$CLIENT_PUBLIC_KEY"
    printf '  direct addr: %s\n' "$CLIENT_IPV4"
    if [ -n "$WARP_CLIENT_PUBLIC_KEY" ]; then
      printf '  warp key   : %s\n' "$WARP_CLIENT_PUBLIC_KEY"
      printf '  warp addr  : %s\n' "$WARP_CLIENT_IPV4"
    fi
  done
  if [ "$found" -eq 0 ]; then
    printf '\nno peers registered yet\n'
  fi
}

purge_nat_rules() {
  local ip="$1"
  [ -n "$ip" ] || return 0
  [ -n "$EGRESS_INTERFACE" ] || return 0
  require_command iptables
  while iptables -t nat -C POSTROUTING -s "${ip%%/*}/32" -o "$EGRESS_INTERFACE" -j MASQUERADE >/dev/null 2>&1; do
    run iptables -t nat -D POSTROUTING -s "${ip%%/*}/32" -o "$EGRESS_INTERFACE" -j MASQUERADE
  done
  if [ -n "$SERVER_IPV6_ADDR" ] && command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t nat -C POSTROUTING -s "${ip%%/*}/128" -o "$EGRESS_INTERFACE" -j MASQUERADE >/dev/null 2>&1; do
      run ip6tables -t nat -D POSTROUTING -s "${ip%%/*}/128" -o "$EGRESS_INTERFACE" -j MASQUERADE
    done
  fi
  return 0
}

remove_peer() {
  if ! load_state; then
    fail "shared state not found: $STATE_FILE"
  fi
  local f match="" name="" mode="" client_ip="" warp_ip=""
  for f in "$PEER_DIR"/*.env; do
    [ -e "$f" ] || continue
    NAME=""
    MODE=""
    CLIENT_PUBLIC_KEY=""
    CLIENT_IPV4=""
    WARP_CLIENT_PUBLIC_KEY=""
    WARP_CLIENT_IPV4=""
    # shellcheck disable=SC1090
    . "$f"
    if [ "$NAME" = "$REMOVE_TARGET" ] || [ "$CLIENT_PUBLIC_KEY" = "$REMOVE_TARGET" ] || [ "$WARP_CLIENT_PUBLIC_KEY" = "$REMOVE_TARGET" ]; then
      match="$f"
      name="$NAME"
      mode="$MODE"
      client_ip="$CLIENT_IPV4"
      warp_ip="$WARP_CLIENT_IPV4"
      break
    fi
  done
  [ -n "$match" ] || fail "no peer matched target: $REMOVE_TARGET"

  log "removing peer ${name:-<unnamed>} ($(basename "$match"))"
  run rm -f "$match"
  render_config
  apply_config
  purge_nat_rules "$client_ip"
  purge_nat_rules "$warp_ip"

  if [ "$REGISTER_WARP" = "true" ]; then
    case "$mode" in
      warp)
        unregister_warp_client "${client_ip%%/*}"
        ;;
      dual)
        unregister_warp_client "${warp_ip%%/*}"
        ;;
    esac
  fi
  log "peer removed; other peers keep their tunnels"
}

status() {
  if ! load_state; then
    fail "shared state not found: $STATE_FILE"
  fi
  log "device=$DEVICE listen_port=$LISTEN_PORT server_addr=$SERVER_ADDR server_ipv6_addr=${SERVER_IPV6_ADDR:-}"
  if command -v wg >/dev/null 2>&1; then
    wg show "$DEVICE" 2>/dev/null || true
  fi
}

main() {
  parse_args "$@"
  validate_args
  state_paths
  require_root

  case "$ACTION" in
    status)
      status
      ;;
    list)
      list_peers
      ;;
    remove)
      acquire_lock
      remove_peer
      ;;
    add)
      acquire_lock
      init_state
      write_peer
      render_config
      apply_config
      print_response
      ;;
    add-client)
      acquire_lock
      init_state
      prepare_client
      ensure_client_keypair
      ensure_endpoint
      write_peer
      render_config
      apply_config
      write_client_config
      register_warp_clients
      print_client_summary
      ;;
  esac
}

main "$@"
