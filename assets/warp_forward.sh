#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="up"
DEVICE=""
CLIENT_ADDR=""
SERVER_ADDR=""
TRANSPARENT_PORT="14000"
WARP_TCP_MSS="${WARPPOOL_WARP_TCP_MSS:-1000}"
WARP_PROXY_HOST="127.0.0.1"
WARP_PROXY_PORT="40000"
WARP_BACKEND="auto"
WARP_PROFILE_PATH="/etc/warppool-node/warp/wgcf-profile.conf"
WARP_ENDPOINT=""
WARP_PROBE_PORT="${WARPPOOL_WARP_PROBE_PORT:-40100}"
SINGBOX_BIN=""
FORWARDER_TYPE=""
FORWARDER_BIN=""
STATE_DIR="/var/lib/warppool/warp-forward"
AUTO_INSTALL_SINGBOX="true"
VERIFY_WARP="true"
DRY_RUN="false"
SINGBOX_FEATURE_FALLBACK_DONE="false"

log() {
  printf '[WarpPool][warp-forward] %s\n' "$*"
}

fail() {
  printf '[WarpPool][warp-forward][ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  local line="$1"
  printf '[WarpPool][warp-forward][ERROR] command failed with exit %s at line %s: %s\n' "$status" "$line" "$BASH_COMMAND" >&2
  exit "$status"
}

trap 'on_error $LINENO' ERR

usage() {
  cat <<'USAGE'
WarpPool WARP forwarding helper

Usage:
  bash warp_forward.sh action=up|down|status|probe device=<wg-device> client_addr=<client-cidr> [server_addr=<server-cidr>] [transparent_port=14000] [tcp_mss=1000] [backend=auto|socks|wireguard] [--dry-run]

This script redirects TCP traffic entering the WireGuard device to a local
sing-box redirect inbound, then sends it to Cloudflare WARP. The default
backend first tries the official WARP local SOCKS proxy, then falls back to
wgcf + sing-box embedded WireGuard endpoint.
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
      device=*) DEVICE="${arg#device=}" ;;
      client_addr=*) CLIENT_ADDR="${arg#client_addr=}" ;;
      server_addr=*) SERVER_ADDR="${arg#server_addr=}" ;;
      transparent_port=*) TRANSPARENT_PORT="${arg#transparent_port=}" ;;
      tcp_mss=*|mss=*) WARP_TCP_MSS="${arg#*=}" ;;
      warp_proxy_host=*) WARP_PROXY_HOST="${arg#warp_proxy_host=}" ;;
      warp_proxy_port=*) WARP_PROXY_PORT="${arg#warp_proxy_port=}" ;;
      backend=*) WARP_BACKEND="${arg#backend=}" ;;
      warp_profile=*) WARP_PROFILE_PATH="${arg#warp_profile=}" ;;
      warp_endpoint=*) WARP_ENDPOINT="${arg#warp_endpoint=}" ;;
      probe_port=*) WARP_PROBE_PORT="${arg#probe_port=}" ;;
      singbox_bin=*) SINGBOX_BIN="${arg#singbox_bin=}" ;;
      state_dir=*) STATE_DIR="${arg#state_dir=}" ;;
      auto_install_singbox=*) AUTO_INSTALL_SINGBOX="${arg#auto_install_singbox=}" ;;
      verify_warp=*) VERIFY_WARP="${arg#verify_warp=}" ;;
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
    up|down|status|probe) ;;
    *) fail "unsupported action: $ACTION, expected up, down, status, or probe" ;;
  esac

  case "$DEVICE" in
    ""|*[!a-zA-Z0-9_.-]*)
      fail "invalid WireGuard device name: $DEVICE"
      ;;
  esac

  if [ -z "$CLIENT_ADDR" ]; then
    fail "client_addr is required"
  fi
  CLIENT_IP="${CLIENT_ADDR%%/*}"
  case "$CLIENT_IP" in
    *[!0-9.]*|"")
      fail "invalid IPv4 client address: $CLIENT_ADDR"
      ;;
  esac

  if [ -n "$SERVER_ADDR" ]; then
    REDIRECT_LISTEN="${SERVER_ADDR%%/*}"
    case "$REDIRECT_LISTEN" in
      *[!0-9.]*|"")
        fail "invalid IPv4 server address: $SERVER_ADDR"
        ;;
    esac
  else
    REDIRECT_LISTEN="127.0.0.1"
  fi

  case "$TRANSPARENT_PORT" in
    *[!0-9]*|"")
      fail "invalid transparent_port: $TRANSPARENT_PORT"
      ;;
  esac
  if [ "$TRANSPARENT_PORT" -lt 1 ] || [ "$TRANSPARENT_PORT" -gt 65535 ]; then
    fail "transparent_port must be between 1 and 65535: $TRANSPARENT_PORT"
  fi

  case "$WARP_TCP_MSS" in
    *[!0-9]*|"")
      fail "invalid tcp_mss: $WARP_TCP_MSS"
      ;;
  esac
  if [ "$WARP_TCP_MSS" -lt 536 ] || [ "$WARP_TCP_MSS" -gt 1460 ]; then
    fail "tcp_mss must be between 536 and 1460: $WARP_TCP_MSS"
  fi

  case "$WARP_PROXY_PORT" in
    *[!0-9]*|"")
      fail "invalid warp_proxy_port: $WARP_PROXY_PORT"
      ;;
  esac

  case "$WARP_BACKEND" in
    auto|socks|wireguard) ;;
    *) fail "unsupported backend: $WARP_BACKEND, expected auto, socks, or wireguard" ;;
  esac

  case "$WARP_PROBE_PORT" in
    *[!0-9]*|"")
      fail "invalid probe_port: $WARP_PROBE_PORT"
      ;;
  esac
  if [ "$WARP_PROBE_PORT" -lt 1 ] || [ "$WARP_PROBE_PORT" -gt 65535 ]; then
    fail "probe_port must be between 1 and 65535: $WARP_PROBE_PORT"
  fi

  validate_bool auto_install_singbox "$AUTO_INSTALL_SINGBOX"
  validate_bool verify_warp "$VERIFY_WARP"

  SAFE_DEVICE="$DEVICE"
  CONFIG_PATH="$STATE_DIR/$SAFE_DEVICE.json"
  CLIENTS_PATH="$STATE_DIR/$SAFE_DEVICE.clients"
  PID_PATH="$STATE_DIR/$SAFE_DEVICE.pid"
  LOG_PATH="$STATE_DIR/$SAFE_DEVICE.log"
  UNIT_NAME="warppool-warp-forward-$SAFE_DEVICE.service"
  UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
  OPENRC_NAME="warppool-warp-forward-$SAFE_DEVICE"
  OPENRC_PATH="/etc/init.d/$OPENRC_NAME"
}

register_client() {
  mkdir -p "$STATE_DIR"
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: register WARP forwarding client $CLIENT_IP in $CLIENTS_PATH"
    return 0
  fi
  touch "$CLIENTS_PATH"
  chmod 0600 "$CLIENTS_PATH"
  if ! grep -Fxq "$CLIENT_IP" "$CLIENTS_PATH" 2>/dev/null; then
    printf '%s\n' "$CLIENT_IP" >>"$CLIENTS_PATH"
  fi
}

unregister_client() {
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: unregister WARP forwarding client $CLIENT_IP from $CLIENTS_PATH"
    return 0
  fi
  [ -r "$CLIENTS_PATH" ] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -Fxv "$CLIENT_IP" "$CLIENTS_PATH" >"$tmp" || true
  cat "$tmp" >"$CLIENTS_PATH"
  rm -f "$tmp"
  chmod 0600 "$CLIENTS_PATH"
}

client_rule_loop_add() {
  printf 'if [ -r %s ]; then while read ip; do [ -n "$ip" ] || continue; iptables -t nat -C PREROUTING -i %s -s "$ip/32" -p tcp -j REDIRECT --to-ports %s 2>/dev/null || iptables -t nat -A PREROUTING -i %s -s "$ip/32" -p tcp -j REDIRECT --to-ports %s; done < %s; fi' "$CLIENTS_PATH" "$DEVICE" "$TRANSPARENT_PORT" "$DEVICE" "$TRANSPARENT_PORT" "$CLIENTS_PATH"
}

client_rule_loop_delete_all() {
  printf 'if [ -r %s ]; then while read ip; do [ -n "$ip" ] || continue; while iptables -t nat -C PREROUTING -i %s -s "$ip/32" -p tcp -j REDIRECT --to-ports %s >/dev/null 2>&1; do iptables -t nat -D PREROUTING -i %s -s "$ip/32" -p tcp -j REDIRECT --to-ports %s; done; done < %s; fi' "$CLIENTS_PATH" "$DEVICE" "$TRANSPARENT_PORT" "$DEVICE" "$TRANSPARENT_PORT" "$CLIENTS_PATH"
}

client_mss_rule_loop_add() {
  printf 'if [ -r %s ]; then while read ip; do [ -n "$ip" ] || continue; iptables -t mangle -C PREROUTING -i %s -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s 2>/dev/null || iptables -t mangle -A PREROUTING -i %s -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s; done < %s; fi' "$CLIENTS_PATH" "$DEVICE" "$WARP_TCP_MSS" "$DEVICE" "$WARP_TCP_MSS" "$CLIENTS_PATH"
}

client_mss_rule_loop_delete_all() {
  printf 'if [ -r %s ]; then while read ip; do [ -n "$ip" ] || continue; while iptables -t mangle -C PREROUTING -i %s -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s >/dev/null 2>&1; do iptables -t mangle -D PREROUTING -i %s -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss %s; done; done < %s; fi' "$CLIENTS_PATH" "$DEVICE" "$WARP_TCP_MSS" "$DEVICE" "$WARP_TCP_MSS" "$CLIENTS_PATH"
}

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

singbox_can_run() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  "$binary" version >/dev/null 2>&1
}

singbox_check_config_output() {
  local path="$1"
  "$SINGBOX_BIN" check -c "$path" 2>&1
}

ensure_singbox_config_supported() {
  local path="$1" output
  if output="$(singbox_check_config_output "$path")"; then
    return 0
  fi

  if [ "$AUTO_INSTALL_SINGBOX" = "true" ] && [ "$SINGBOX_FEATURE_FALLBACK_DONE" != "true" ]; then
    log "current sing-box cannot load WarpPool WARP config, falling back to GitHub build"
    printf '%s\n' "$output" >&2
    SINGBOX_FEATURE_FALLBACK_DONE="true"
    install_singbox default
    if output="$(singbox_check_config_output "$path")"; then
      return 0
    fi
  fi

  printf '%s\n' "$output" >&2
  fail "sing-box config check failed; install a newer sing-box or use WarpPool managed GitHub build"
}

resolve_installed_singbox_path() {
  if singbox_can_run "/usr/local/lib/warppool/bin/sing-box"; then
    printf '%s\n' "/usr/local/lib/warppool/bin/sing-box"
    return 0
  fi
  local system_binary
  system_binary="$(command -v sing-box 2>/dev/null || true)"
  if [ -n "$system_binary" ] && singbox_can_run "$system_binary"; then
    printf '%s\n' "$system_binary"
    return 0
  fi
  return 1
}

install_singbox() {
  local installer source
  source="${1:-auto}"
  installer="$(script_dir)/singbox_install.sh"
  if [ ! -r "$installer" ]; then
    fail "sing-box not found and installer missing: $installer"
  fi

  log "installing sing-box, source=$source"
  run bash "$installer" --yes "source=$source" variant=auto install_dir=/usr/local/lib/warppool/bin
  if [ "$DRY_RUN" = "true" ]; then
    SINGBOX_BIN="/usr/local/lib/warppool/bin/sing-box"
    return 0
  fi
  SINGBOX_BIN="$(resolve_installed_singbox_path || true)"
  [ -n "$SINGBOX_BIN" ] || fail "sing-box installation did not produce a discoverable binary"
  if [ "$DRY_RUN" != "true" ] && ! singbox_can_run "$SINGBOX_BIN"; then
    fail "sing-box installation did not produce a runnable binary: $SINGBOX_BIN"
  fi
}

redsocks_can_run() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  "$binary" -h >/dev/null 2>&1 || "$binary" -v >/dev/null 2>&1 || return 0
}

resolve_installed_redsocks_path() {
  local system_binary
  system_binary="$(command -v redsocks 2>/dev/null || true)"
  if [ -n "$system_binary" ] && [ -x "$system_binary" ]; then
    printf '%s\n' "$system_binary"
    return 0
  fi
  return 1
}

install_redsocks() {
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: install redsocks from system package repository"
    FORWARDER_BIN="/usr/sbin/redsocks"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "installing redsocks from apt repository"
    env DEBIAN_FRONTEND=noninteractive apt-get update || true
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends redsocks || return 1
  elif command -v apk >/dev/null 2>&1; then
    log "installing redsocks from apk repository"
    apk update || true
    apk add --no-cache redsocks || return 1
  else
    return 1
  fi

  FORWARDER_BIN="$(resolve_installed_redsocks_path || true)"
  [ -n "$FORWARDER_BIN" ] || return 1
}

resolve_socks_forwarder() {
  if [ -n "$SINGBOX_BIN" ] && singbox_can_run "$SINGBOX_BIN"; then
    FORWARDER_TYPE="singbox"
    FORWARDER_BIN="$SINGBOX_BIN"
    return 0
  fi

  SINGBOX_BIN="$(resolve_installed_singbox_path || true)"
  if [ -n "$SINGBOX_BIN" ]; then
    FORWARDER_TYPE="singbox"
    FORWARDER_BIN="$SINGBOX_BIN"
    log "using existing sing-box forwarder: $SINGBOX_BIN"
    return 0
  fi

  FORWARDER_BIN="$(resolve_installed_redsocks_path || true)"
  if [ -n "$FORWARDER_BIN" ]; then
    FORWARDER_TYPE="redsocks"
    log "using existing redsocks forwarder: $FORWARDER_BIN"
    return 0
  fi

  if install_redsocks; then
    FORWARDER_TYPE="redsocks"
    log "using redsocks forwarder: $FORWARDER_BIN"
    return 0
  fi

  if [ "$AUTO_INSTALL_SINGBOX" = "true" ]; then
    log "redsocks unavailable; falling back to WarpPool managed sing-box"
    install_singbox auto
    FORWARDER_TYPE="singbox"
    FORWARDER_BIN="$SINGBOX_BIN"
    return 0
  fi

  fail "no SOCKS redirect forwarder found; install redsocks or sing-box"
}

resolve_singbox() {
  if [ -n "$SINGBOX_BIN" ]; then
    if ! singbox_can_run "$SINGBOX_BIN"; then
      fail "sing-box binary cannot run: $SINGBOX_BIN"
    fi
    return 0
  fi

  if [ -x "/usr/local/lib/warppool/bin/sing-box" ]; then
    SINGBOX_BIN="/usr/local/lib/warppool/bin/sing-box"
    if singbox_can_run "$SINGBOX_BIN"; then
      return 0
    fi
    log "existing sing-box cannot run, reinstalling: $SINGBOX_BIN"
    if [ "$AUTO_INSTALL_SINGBOX" = "true" ]; then
      install_singbox auto
      return 0
    fi
    fail "existing sing-box cannot run: $SINGBOX_BIN"
  fi

  if command -v sing-box >/dev/null 2>&1; then
    SINGBOX_BIN="$(command -v sing-box)"
    if singbox_can_run "$SINGBOX_BIN"; then
      return 0
    fi
    log "system sing-box cannot run, installing WarpPool managed sing-box: $SINGBOX_BIN"
    if [ "$AUTO_INSTALL_SINGBOX" = "true" ]; then
      install_singbox auto
      return 0
    fi
    fail "system sing-box cannot run: $SINGBOX_BIN"
  fi

  if [ "$AUTO_INSTALL_SINGBOX" != "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      SINGBOX_BIN="/usr/local/lib/warppool/bin/sing-box"
      log "dry-run: assume sing-box binary: $SINGBOX_BIN"
      return 0
    fi
    fail "sing-box not found; install it or set auto_install_singbox=true"
  fi

  log "sing-box not found"
  install_singbox auto
}

verify_warp_proxy() {
  if [ "$VERIFY_WARP" != "true" ]; then
    log "skip WARP proxy verification"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: verify WARP proxy via socks5h://$WARP_PROXY_HOST:$WARP_PROXY_PORT"
    return 0
  fi

  if ! wait_proxy_port_warp "$WARP_PROXY_HOST" "$WARP_PROXY_PORT" 15 2; then
    fail "WARP proxy verification failed: expected warp=on from $WARP_PROXY_HOST:$WARP_PROXY_PORT"
  fi
  log "WARP proxy verified: warp=on"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

read_warp_profile() {
  if [ "$DRY_RUN" = "true" ]; then
    WARP_PRIVATE_KEY="dry-run-private-key"
    WARP_ADDRESS_JSON='"172.16.0.2/32","2606:4700:110::1/128"'
    WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    WARP_PROFILE_ENDPOINT_HOST="engage.cloudflareclient.com"
    WARP_PROFILE_ENDPOINT_PORT="2408"
    WARP_MTU="1280"
    return 0
  fi

  [ -r "$WARP_PROFILE_PATH" ] || fail "WARP WireGuard profile not found: $WARP_PROFILE_PATH"

  WARP_PRIVATE_KEY="$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$WARP_PROFILE_PATH" | sed 's/[[:space:]]*$//' | head -n 1)"
  WARP_PEER_PUBLIC_KEY="$(sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*//p' "$WARP_PROFILE_PATH" | sed 's/[[:space:]]*$//' | head -n 1)"
  WARP_MTU="$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*//p' "$WARP_PROFILE_PATH" | sed 's/[[:space:]]*$//' | head -n 1)"
  [ -n "$WARP_MTU" ] || WARP_MTU="1280"

  local endpoint
  endpoint="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$WARP_PROFILE_PATH" | sed 's/[[:space:]]*$//' | head -n 1)"
  [ -n "$WARP_PRIVATE_KEY" ] || fail "WARP profile missing PrivateKey: $WARP_PROFILE_PATH"
  [ -n "$WARP_PEER_PUBLIC_KEY" ] || fail "WARP profile missing peer PublicKey: $WARP_PROFILE_PATH"
  [ -n "$endpoint" ] || fail "WARP profile missing Endpoint: $WARP_PROFILE_PATH"

  WARP_PROFILE_ENDPOINT_HOST="${endpoint%:*}"
  WARP_PROFILE_ENDPOINT_PORT="${endpoint##*:}"
  case "$WARP_PROFILE_ENDPOINT_PORT" in
    *[!0-9]*|"") fail "invalid WARP endpoint port in profile: $endpoint" ;;
  esac

  WARP_ADDRESS_JSON="$(
    sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$WARP_PROFILE_PATH" | head -n 1 |
      tr ',' '\n' |
      sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
      awk 'NF {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\"%s\"", sep, $0; sep=","}'
  )"
  [ -n "$WARP_ADDRESS_JSON" ] || fail "WARP profile missing Address: $WARP_PROFILE_PATH"
}

add_unique_candidate() {
  local host="$1" port="$2" value
  [ -n "$host" ] || return 0
  [ -n "$port" ] || return 0
  value="$host|$port"
  case "
$WARP_ENDPOINT_CANDIDATES
" in
    *"
$value
"*) return 0 ;;
  esac
  WARP_ENDPOINT_CANDIDATES="${WARP_ENDPOINT_CANDIDATES}${value}
"
}

resolve_with_system_dns() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u
    return 0
  fi
  return 0
}

resolve_with_doh() {
  local host="$1" type="$2"
  command -v curl >/dev/null 2>&1 || return 0
  curl --max-time 10 -fsSL "https://cloudflare-dns.com/dns-query?name=$host&type=$type" \
    -H 'accept: application/dns-json' 2>/dev/null |
    grep -o '"data"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' |
    sort -u || true
}

ip_family() {
  case "$1" in
    *:*) printf '6\n' ;;
    *.*) printf '4\n' ;;
    *) printf 'domain\n' ;;
  esac
}

build_warp_endpoint_candidates() {
  WARP_ENDPOINT_CANDIDATES=""
  local host port ip
  if [ -n "$WARP_ENDPOINT" ]; then
    host="${WARP_ENDPOINT%:*}"
    port="${WARP_ENDPOINT##*:}"
  else
    host="$WARP_PROFILE_ENDPOINT_HOST"
    port="$WARP_PROFILE_ENDPOINT_PORT"
  fi
  host="${host#[}"
  host="${host%]}"
  [ -n "$port" ] || port="2408"

  if [ "$(ip_family "$host")" = "6" ]; then
    add_unique_candidate "$host" "$port"
  fi

  if [ "$(ip_family "$host")" = "domain" ]; then
    for ip in $(resolve_with_system_dns "$host"); do
      [ "$(ip_family "$ip")" = "6" ] && add_unique_candidate "$ip" "$port"
    done
    for ip in $(resolve_with_doh "$host" AAAA); do
      add_unique_candidate "$ip" "$port"
    done
  fi

  add_unique_candidate "2606:4700:d0::a29f:c001" "$port"
  add_unique_candidate "2606:4700:d0::a29f:c008" "$port"

  if [ "$(ip_family "$host")" = "4" ]; then
    add_unique_candidate "$host" "$port"
  fi

  if [ "$(ip_family "$host")" = "domain" ]; then
    for ip in $(resolve_with_system_dns "$host"); do
      [ "$(ip_family "$ip")" = "4" ] && add_unique_candidate "$ip" "$port"
    done
    for ip in $(resolve_with_doh "$host" A); do
      add_unique_candidate "$ip" "$port"
    done
  fi

  add_unique_candidate "162.159.192.1" "$port"
  add_unique_candidate "162.159.192.8" "$port"
  add_unique_candidate "162.159.193.1" "$port"
  add_unique_candidate "162.159.193.8" "$port"
  add_unique_candidate "$host" "$port"
}

split_endpoint_candidate() {
  local candidate="$1"
  WARP_CANDIDATE_HOST="${candidate%%|*}"
  WARP_CANDIDATE_PORT="${candidate##*|}"
}

write_wireguard_singbox_config() {
  local path="$1" listen_port="$2" endpoint_host="$3" endpoint_port="$4" inbound_type="$5"
  local escaped_host escaped_key escaped_pub listen_host
  escaped_host="$(json_escape "$endpoint_host")"
  escaped_key="$(json_escape "$WARP_PRIVATE_KEY")"
  escaped_pub="$(json_escape "$WARP_PEER_PUBLIC_KEY")"
  listen_host="$REDIRECT_LISTEN"
  if [ "$inbound_type" = "mixed" ]; then
    listen_host="127.0.0.1"
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "$inbound_type",
      "tag": "wg-warp-redirect",
      "listen": "$listen_host",
      "listen_port": $listen_port
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-wireguard",
      "system": false,
      "name": "warppool-warp",
      "mtu": $WARP_MTU,
      "address": [
        $WARP_ADDRESS_JSON
      ],
      "private_key": "$escaped_key",
      "peers": [
        {
          "address": "$escaped_host",
          "port": $endpoint_port,
          "public_key": "$escaped_pub",
          "allowed_ips": [
            "0.0.0.0/0",
            "::/0"
          ],
          "persistent_keepalive_interval": 25
        }
      ]
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "wg-warp-redirect"
        ],
        "outbound": "warp-wireguard"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
  chmod 0600 "$path"
}

verify_proxy_port_warp() {
  local host="$1" port="$2"
  local trace
  require_command curl
  trace="$(curl --max-time 20 --socks5-hostname "$host:$port" -fsSL https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  printf '%s\n' "$trace" | grep -q '^warp=on$'
}

wait_proxy_port_warp() {
  local host="$1" port="$2" attempts="$3" delay="$4" attempt
  for attempt in $(seq 1 "$attempts"); do
    if verify_proxy_port_warp "$host" "$port"; then
      [ "$attempt" -gt 1 ] && log "WARP proxy became available on attempt $attempt"
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

probe_wireguard_backend() {
  local candidate host port probe_config probe_log probe_pid
  resolve_singbox
  FORWARDER_TYPE="singbox"
  FORWARDER_BIN="$SINGBOX_BIN"
  read_warp_profile
  build_warp_endpoint_candidates
  [ -n "$WARP_ENDPOINT_CANDIDATES" ] || fail "no WARP endpoint candidates available"

  probe_config="$STATE_DIR/$SAFE_DEVICE.probe.json"
  probe_log="$STATE_DIR/$SAFE_DEVICE.probe.log"
  mkdir -p "$STATE_DIR"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    split_endpoint_candidate "$candidate"
    host="$WARP_CANDIDATE_HOST"
    port="$WARP_CANDIDATE_PORT"
    log "probing WARP WireGuard endpoint: $host:$port"
    if [ "$DRY_RUN" = "true" ]; then
      WARP_SELECTED_HOST="$host"
      WARP_SELECTED_PORT="$port"
      WARP_BACKEND_EFFECTIVE="wireguard"
      log "dry-run: select WARP WireGuard endpoint $host:$port"
      return 0
    fi
    write_wireguard_singbox_config "$probe_config" "$WARP_PROBE_PORT" "$host" "$port" "mixed"
    ensure_singbox_config_supported "$probe_config"
    "$SINGBOX_BIN" run -c "$probe_config" >"$probe_log" 2>&1 &
    probe_pid="$!"
    sleep 3
    if verify_proxy_port_warp "127.0.0.1" "$WARP_PROBE_PORT"; then
      kill "$probe_pid" >/dev/null 2>&1 || true
      wait "$probe_pid" >/dev/null 2>&1 || true
      rm -f "$probe_config" "$probe_log"
      WARP_SELECTED_HOST="$host"
      WARP_SELECTED_PORT="$port"
      WARP_BACKEND_EFFECTIVE="wireguard"
      log "WARP WireGuard endpoint verified: $host:$port"
      return 0
    fi
    kill "$probe_pid" >/dev/null 2>&1 || true
    wait "$probe_pid" >/dev/null 2>&1 || true
    log "WARP WireGuard endpoint failed: $host:$port"
  done <<EOF_CANDIDATES
$WARP_ENDPOINT_CANDIDATES
EOF_CANDIDATES

  fail "WARP WireGuard endpoint probing failed; check IPv6 connectivity, UDP 2408 outbound, DNS resolution, or provider WARP restrictions"
}

select_warp_backend() {
  case "$WARP_BACKEND" in
    socks)
      verify_warp_proxy
      WARP_BACKEND_EFFECTIVE="socks"
      ;;
    wireguard)
      probe_wireguard_backend
      ;;
    auto)
      if [ "$VERIFY_WARP" = "true" ] && [ "$DRY_RUN" != "true" ] && wait_proxy_port_warp "$WARP_PROXY_HOST" "$WARP_PROXY_PORT" 15 2; then
        log "using official WARP local SOCKS proxy: $WARP_PROXY_HOST:$WARP_PROXY_PORT"
        WARP_BACKEND_EFFECTIVE="socks"
      else
        if [ "$VERIFY_WARP" != "true" ]; then
          log "verification disabled; prefer official WARP SOCKS backend"
          WARP_BACKEND_EFFECTIVE="socks"
        else
          if [ "$DRY_RUN" != "true" ] && [ ! -r "$WARP_PROFILE_PATH" ]; then
            fail "official WARP local SOCKS proxy verification failed and WARP WireGuard profile is missing: $WARP_PROFILE_PATH"
          fi
          log "official WARP local SOCKS proxy unavailable; trying wgcf + sing-box WireGuard backend"
          probe_wireguard_backend
        fi
      fi
      ;;
  esac
}

write_singbox_config() {
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: write sing-box config: $CONFIG_PATH"
    return 0
  fi

  if [ "${WARP_BACKEND_EFFECTIVE:-}" = "wireguard" ]; then
    write_wireguard_singbox_config "$CONFIG_PATH" "$TRANSPARENT_PORT" "$WARP_SELECTED_HOST" "$WARP_SELECTED_PORT" "redirect"
    return 0
  fi

  resolve_socks_forwarder

  if [ "$FORWARDER_TYPE" = "redsocks" ]; then
    mkdir -p "$STATE_DIR"
    cat >"$CONFIG_PATH" <<EOF
base {
  log_debug = off;
  log_info = on;
  log = "file:$LOG_PATH";
  daemon = off;
  redirector = iptables;
}

redsocks {
  local_ip = $REDIRECT_LISTEN;
  local_port = $TRANSPARENT_PORT;
  ip = $WARP_PROXY_HOST;
  port = $WARP_PROXY_PORT;
  type = socks5;
}
EOF
    chmod 0600 "$CONFIG_PATH"
    return 0
  fi

  FORWARDER_TYPE="singbox"
  FORWARDER_BIN="$SINGBOX_BIN"
  mkdir -p "$STATE_DIR"
  cat >"$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "redirect",
      "tag": "wg-warp-redirect",
      "listen": "$REDIRECT_LISTEN",
      "listen_port": $TRANSPARENT_PORT
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-proxy",
      "server": "$WARP_PROXY_HOST",
      "server_port": $WARP_PROXY_PORT,
      "version": "5"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "wg-warp-redirect"
        ],
        "outbound": "warp-proxy"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
  chmod 0600 "$CONFIG_PATH"
}

forwarder_exec_start() {
  case "$FORWARDER_TYPE" in
    redsocks)
      printf '%s -c %s' "$FORWARDER_BIN" "$CONFIG_PATH"
      ;;
    *)
      printf '%s run -c %s' "$SINGBOX_BIN" "$CONFIG_PATH"
      ;;
  esac
}

forwarder_command() {
  case "$FORWARDER_TYPE" in
    redsocks) printf '%s' "$FORWARDER_BIN" ;;
    *) printf '%s' "$SINGBOX_BIN" ;;
  esac
}

forwarder_args() {
  case "$FORWARDER_TYPE" in
    redsocks) printf '%s' "-c $CONFIG_PATH" ;;
    *) printf '%s' "run -c $CONFIG_PATH" ;;
  esac
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

openrc_available() {
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]
}

clients_remaining() {
  [ -r "$CLIENTS_PATH" ] || return 1
  grep -Eq '[^[:space:]]' "$CLIENTS_PATH"
}

start_singbox() {
  local exec_start command_path command_args add_client_rules delete_client_rules add_mss_rules delete_mss_rules
  add_client_rules="$(client_rule_loop_add)"
  delete_client_rules="$(client_rule_loop_delete_all)"
  add_mss_rules="$(client_mss_rule_loop_add)"
  delete_mss_rules="$(client_mss_rule_loop_delete_all)"
  if systemd_available; then
    if [ "$DRY_RUN" = "true" ]; then
      log "dry-run: write systemd unit: $UNIT_PATH"
      log "dry-run: systemctl enable/restart $UNIT_NAME"
      return 0
    fi

    exec_start="$(forwarder_exec_start)"
    cat >"$UNIT_PATH" <<EOF
[Unit]
Description=WarpPool WARP forward for $DEVICE
After=network-online.target wg-quick@$DEVICE.service
Wants=network-online.target wg-quick@$DEVICE.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'iptables -C INPUT -i $DEVICE -p tcp -j ACCEPT 2>/dev/null || iptables -A INPUT -i $DEVICE -p tcp -j ACCEPT'
ExecStartPre=/bin/sh -c '$add_client_rules'
ExecStartPre=/bin/sh -c '$add_mss_rules'
ExecStart=$exec_start
ExecStopPost=/bin/sh -c '$delete_mss_rules; $delete_client_rules; while iptables -C INPUT -i $DEVICE -p tcp -j ACCEPT >/dev/null 2>&1; do iptables -D INPUT -i $DEVICE -p tcp -j ACCEPT; done'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl is-active --quiet "$UNIT_NAME"; then
      systemctl restart "$UNIT_NAME"
      systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
    else
      systemctl enable --now "$UNIT_NAME"
    fi
    return 0
  fi

  if openrc_available; then
    if [ "$DRY_RUN" = "true" ]; then
      log "dry-run: write OpenRC service: $OPENRC_PATH"
      log "dry-run: rc-update add $OPENRC_NAME default && rc-service $OPENRC_NAME restart"
      return 0
    fi
    command_path="$(forwarder_command)"
    command_args="$(forwarder_args)"
    cat >"$OPENRC_PATH" <<EOF
#!/sbin/openrc-run
name="WarpPool WARP forward for $DEVICE"
description="WarpPool WARP forward for $DEVICE"
command="$command_path"
command_args="$command_args"
command_background="yes"
pidfile="$PID_PATH"
output_log="$LOG_PATH"
error_log="$LOG_PATH"

depend() {
  need net wg-quick.$DEVICE
  after firewall
}

start_pre() {
  iptables -C INPUT -i $DEVICE -p tcp -j ACCEPT 2>/dev/null || iptables -A INPUT -i $DEVICE -p tcp -j ACCEPT
  $add_client_rules
  $add_mss_rules
}

stop_post() {
  $delete_mss_rules
  $delete_client_rules
  while iptables -C INPUT -i $DEVICE -p tcp -j ACCEPT >/dev/null 2>&1; do
    iptables -D INPUT -i $DEVICE -p tcp -j ACCEPT
  done
}
EOF
    chmod 0755 "$OPENRC_PATH"
    rc-update add "$OPENRC_NAME" default >/dev/null 2>&1 || true
    rc-service "$OPENRC_NAME" restart
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: start sing-box in background"
    return 0
  fi

  if [ -r "$PID_PATH" ]; then
    local pid
    pid="$(cat "$PID_PATH" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      log "sing-box already running with pid $pid"
      return 0
    fi
  fi

  case "$FORWARDER_TYPE" in
    redsocks)
      nohup "$FORWARDER_BIN" -c "$CONFIG_PATH" >"$LOG_PATH" 2>&1 &
      ;;
    *)
      nohup "$SINGBOX_BIN" run -c "$CONFIG_PATH" >"$LOG_PATH" 2>&1 &
      ;;
  esac
  echo "$!" >"$PID_PATH"
}

stop_singbox() {
  if systemd_available; then
    run systemctl disable --now "$UNIT_NAME"
    if [ "$DRY_RUN" != "true" ]; then
      rm -f "$UNIT_PATH"
      systemctl daemon-reload
    fi
    return 0
  fi

  if openrc_available && [ -e "$OPENRC_PATH" ]; then
    run rc-service "$OPENRC_NAME" stop >/dev/null 2>&1 || true
    run rc-update del "$OPENRC_NAME" default >/dev/null 2>&1 || true
    run rm -f "$OPENRC_PATH"
    return 0
  fi

  if [ -r "$PID_PATH" ]; then
    local pid
    pid="$(cat "$PID_PATH" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      run kill "$pid"
    fi
  fi
  run rm -f "$PID_PATH"
}

add_iptables_rules() {
  require_command iptables
  run iptables -C INPUT -i "$DEVICE" -p tcp -j ACCEPT 2>/dev/null || run iptables -A INPUT -i "$DEVICE" -p tcp -j ACCEPT
  if [ -r "$CLIENTS_PATH" ]; then
    local ip
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      run iptables -t nat -C PREROUTING -i "$DEVICE" -s "$ip/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT" 2>/dev/null || run iptables -t nat -A PREROUTING -i "$DEVICE" -s "$ip/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT"
      run iptables -t mangle -C PREROUTING -i "$DEVICE" -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS" 2>/dev/null || run iptables -t mangle -A PREROUTING -i "$DEVICE" -s "$ip/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS"
    done <"$CLIENTS_PATH"
    return 0
  fi
  run iptables -t nat -C PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT" 2>/dev/null || run iptables -t nat -A PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT"
  run iptables -t mangle -C PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS" 2>/dev/null || run iptables -t mangle -A PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS"
}

delete_iptables_rules() {
  require_command iptables
  while iptables -t mangle -C PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS" >/dev/null 2>&1; do
    run iptables -t mangle -D PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$WARP_TCP_MSS"
  done
  while iptables -t nat -C PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT" >/dev/null 2>&1; do
    run iptables -t nat -D PREROUTING -i "$DEVICE" -s "$CLIENT_IP/32" -p tcp -j REDIRECT --to-ports "$TRANSPARENT_PORT"
  done
  while iptables -C INPUT -i "$DEVICE" -p tcp -j ACCEPT >/dev/null 2>&1; do
    run iptables -D INPUT -i "$DEVICE" -p tcp -j ACCEPT
  done
}

status() {
  log "device=$DEVICE client=$CLIENT_IP redirect_listen=$REDIRECT_LISTEN transparent_port=$TRANSPARENT_PORT backend=${WARP_BACKEND_EFFECTIVE:-$WARP_BACKEND} forwarder=${FORWARDER_TYPE:-unknown} warp_proxy=$WARP_PROXY_HOST:$WARP_PROXY_PORT"
  if systemd_available; then
    systemctl is-active "$UNIT_NAME" 2>/dev/null || true
  elif [ -r "$PID_PATH" ]; then
    cat "$PID_PATH"
  fi
  iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$DEVICE" || true
  iptables -t mangle -S PREROUTING 2>/dev/null | grep -- "$DEVICE" || true
}

main() {
  parse_args "$@"
  validate_args
  require_root

  case "$ACTION" in
    up)
      select_warp_backend
      write_singbox_config
      register_client
      start_singbox
      add_iptables_rules
      status
      log "WARP forwarding enabled for $DEVICE"
      ;;
    down)
      delete_iptables_rules
      unregister_client
      if clients_remaining; then
        add_iptables_rules
        log "WARP forwarding client removed for $DEVICE; other shared clients remain"
      else
        stop_singbox
        log "WARP forwarding disabled for $DEVICE"
      fi
      ;;
    status)
      status
      ;;
    probe)
      select_warp_backend
      log "WARP backend probe succeeded: ${WARP_BACKEND_EFFECTIVE:-$WARP_BACKEND}"
      if [ "${WARP_BACKEND_EFFECTIVE:-}" = "wireguard" ]; then
        log "selected WARP WireGuard endpoint: $WARP_SELECTED_HOST:$WARP_SELECTED_PORT"
      fi
      ;;
  esac
}

main "$@"
