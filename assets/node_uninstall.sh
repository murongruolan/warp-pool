#!/usr/bin/env bash
set -Eeuo pipefail

DEVICE=""
ALL="false"
REMOVE_WARP="false"
REMOVE_WIREGUARD="false"
DRY_RUN="false"

log() {
  printf '[WarpPool][node-uninstall] %s\n' "$*"
}

fail() {
  printf '[WarpPool][node-uninstall][ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  local line="$1"
  printf '[WarpPool][node-uninstall][ERROR] command failed with exit %s at line %s: %s\n' "$status" "$line" "$BASH_COMMAND" >&2
  exit "$status"
}

trap 'on_error $LINENO' ERR

usage() {
  cat <<'USAGE'
WarpPool remote node uninstaller

Usage:
  warppool-node-uninstall [device=wpnat01|all=true] [remove_warp=true] [remove_wireguard=true] [--dry-run]
  bash node_uninstall.sh [device=wpnat01|all=true] [remove_warp=true] [remove_wireguard=true] [--dry-run]

Examples:
  warppool-node-uninstall device=wpnat01
  warppool-node-uninstall all=true
  warppool-node-uninstall all=true remove_warp=true

Notes:
  - Without device= or all=true, the script auto-selects the only /etc/wireguard/wp*.conf file if exactly one exists.
  - remove_warp=true removes the Cloudflare WARP package on apt systems and wgcf WARP state on Alpine.
  - remove_wireguard=true removes WireGuard packages when apt/apk is available.
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
      device=*) DEVICE="${arg#device=}" ;;
      all=*) ALL="${arg#all=}" ;;
      remove_warp=*) REMOVE_WARP="${arg#remove_warp=}" ;;
      remove_wireguard=*) REMOVE_WIREGUARD="${arg#remove_wireguard=}" ;;
      *) fail "unknown argument: $arg" ;;
    esac
  done
}

validate_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) fail "$name must be true or false, got: $value" ;;
  esac
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

validate_device() {
  local device="$1"
  case "$device" in
    ""|*[!a-zA-Z0-9_.-]*)
      fail "invalid WireGuard device name: $device"
      ;;
  esac
}

discover_devices() {
  if [ -n "$DEVICE" ]; then
    validate_device "$DEVICE"
    printf '%s\n' "$DEVICE"
    return 0
  fi

  local configs=()
  local path
  for path in /etc/wireguard/wp*.conf; do
    [ -e "$path" ] || continue
    configs+=("$(basename "$path" .conf)")
  done

  if [ "$ALL" = "true" ]; then
    if [ "${#configs[@]}" -eq 0 ]; then
      fail "no WarpPool WireGuard configs found under /etc/wireguard/wp*.conf"
    fi
    printf '%s\n' "${configs[@]}"
    return 0
  fi

  if [ "${#configs[@]}" -eq 1 ]; then
    printf '%s\n' "${configs[0]}"
    return 0
  fi
  if [ "${#configs[@]}" -eq 0 ]; then
    fail "no WarpPool WireGuard configs found; pass device=<wg-device> if the config was already removed"
  fi
  fail "multiple WarpPool WireGuard configs found: ${configs[*]}; pass device=<wg-device> or all=true"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

openrc_available() {
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]
}

disable_systemd_unit() {
  local unit="$1"
  if systemd_available; then
    run systemctl disable --now "$unit" >/dev/null 2>&1 || true
  fi
}

remove_systemd_unit_file() {
  local unit_path="$1"
  if [ -e "$unit_path" ]; then
    run rm -f "$unit_path"
    if systemd_available; then
      run systemctl daemon-reload
    fi
  fi
}

delete_nat_redirect_rules() {
  local device="$1"
  if ! command -v iptables >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: remove iptables redirect/input rules for $device"
    return 0
  fi

  local rule spec
  while IFS= read -r rule; do
    case "$rule" in
      *" -i $device "*"-j REDIRECT "*)
        spec="${rule#-A PREROUTING }"
        # shellcheck disable=SC2086
        iptables -t nat -D PREROUTING $spec >/dev/null 2>&1 || true
        ;;
    esac
  done <<EOF_RULES
$(iptables -t nat -S PREROUTING 2>/dev/null || true)
EOF_RULES

  while IFS= read -r rule; do
    case "$rule" in
      *" -i $device "*"-j TCPMSS "*)
        spec="${rule#-A PREROUTING }"
        # shellcheck disable=SC2086
        iptables -t mangle -D PREROUTING $spec >/dev/null 2>&1 || true
        ;;
    esac
  done <<EOF_RULES
$(iptables -t mangle -S PREROUTING 2>/dev/null || true)
EOF_RULES

  while IFS= read -r rule; do
    case "$rule" in
      *" -i $device "*"-j ACCEPT"*)
        spec="${rule#-A INPUT }"
        # shellcheck disable=SC2086
        iptables -D INPUT $spec >/dev/null 2>&1 || true
        ;;
    esac
  done <<EOF_RULES
$(iptables -S INPUT 2>/dev/null || true)
EOF_RULES
}

delete_direct_forwarding_rules() {
  local device="$1"
  if ! command -v iptables >/dev/null 2>&1 && ! command -v ip6tables >/dev/null 2>&1; then
    return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: remove iptables/ip6tables direct forwarding rules for $device"
    return 0
  fi

  local rule spec
  if command -v iptables >/dev/null 2>&1; then
    while IFS= read -r rule; do
      case "$rule" in
        *" -i $device "*"-j ACCEPT"*|*" -o $device "*"-j ACCEPT"*)
          spec="${rule#-A FORWARD }"
          # shellcheck disable=SC2086
          iptables -D FORWARD $spec >/dev/null 2>&1 || true
          ;;
      esac
    done <<EOF_RULES
$(iptables -S FORWARD 2>/dev/null || true)
EOF_RULES
  fi

  if command -v ip6tables >/dev/null 2>&1; then
    while IFS= read -r rule; do
      case "$rule" in
        *" -i $device "*"-j ACCEPT"*|*" -o $device "*"-j ACCEPT"*)
          spec="${rule#-A FORWARD }"
          # shellcheck disable=SC2086
          ip6tables -D FORWARD $spec >/dev/null 2>&1 || true
          ;;
      esac
    done <<EOF_RULES
$(ip6tables -S FORWARD 2>/dev/null || true)
EOF_RULES
  fi

  local client_ip="" client_ip6=""
  if [ -r "/etc/wireguard/$device.conf" ]; then
    client_ip="$(awk '/AllowedIPs[[:space:]]*=/ {print $3; exit}' "/etc/wireguard/$device.conf" | cut -d/ -f1)"
    client_ip6="$(awk '/AllowedIPs[[:space:]]*=/ {print $4; exit}' "/etc/wireguard/$device.conf" | cut -d/ -f1)"
  fi
  if [ -n "$client_ip" ] && command -v iptables >/dev/null 2>&1; then
    while IFS= read -r rule; do
      case "$rule" in
        *" -s $client_ip/32 "*"-j MASQUERADE"*)
          spec="${rule#-A POSTROUTING }"
          # shellcheck disable=SC2086
          iptables -t nat -D POSTROUTING $spec >/dev/null 2>&1 || true
          ;;
      esac
    done <<EOF_RULES
$(iptables -t nat -S POSTROUTING 2>/dev/null || true)
EOF_RULES
  fi
  if [ -n "$client_ip6" ] && command -v ip6tables >/dev/null 2>&1; then
    while IFS= read -r rule; do
      case "$rule" in
        *" -s $client_ip6/128 "*"-j MASQUERADE"*)
          spec="${rule#-A POSTROUTING }"
          # shellcheck disable=SC2086
          ip6tables -t nat -D POSTROUTING $spec >/dev/null 2>&1 || true
          ;;
      esac
    done <<EOF_RULES
$(ip6tables -t nat -S POSTROUTING 2>/dev/null || true)
EOF_RULES
  fi

  if [ "$device" = "wpshared" ] && [ -d /etc/warppool-node/shared ]; then
    local shared_ip
    if [ -r /etc/warppool-node/shared/wpshared.direct-v4.txt ] && command -v iptables >/dev/null 2>&1; then
      while IFS= read -r shared_ip; do
        [ -n "$shared_ip" ] || continue
        while IFS= read -r rule; do
          case "$rule" in
            *" -s $shared_ip/32 "*"-j MASQUERADE"*)
              spec="${rule#-A POSTROUTING }"
              # shellcheck disable=SC2086
              iptables -t nat -D POSTROUTING $spec >/dev/null 2>&1 || true
              ;;
          esac
        done <<EOF_RULES
$(iptables -t nat -S POSTROUTING 2>/dev/null || true)
EOF_RULES
      done </etc/warppool-node/shared/wpshared.direct-v4.txt
    fi
    if [ -r /etc/warppool-node/shared/wpshared.direct-v6.txt ] && command -v ip6tables >/dev/null 2>&1; then
      while IFS= read -r shared_ip; do
        [ -n "$shared_ip" ] || continue
        while IFS= read -r rule; do
          case "$rule" in
            *" -s $shared_ip/128 "*"-j MASQUERADE"*)
              spec="${rule#-A POSTROUTING }"
              # shellcheck disable=SC2086
              ip6tables -t nat -D POSTROUTING $spec >/dev/null 2>&1 || true
              ;;
          esac
        done <<EOF_RULES
$(ip6tables -t nat -S POSTROUTING 2>/dev/null || true)
EOF_RULES
      done </etc/warppool-node/shared/wpshared.direct-v6.txt
    fi
  fi
}

stop_legacy_pid() {
  local pid_path="$1"
  if [ ! -r "$pid_path" ]; then
    return 0
  fi
  local pid
  pid="$(cat "$pid_path" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    run kill "$pid" >/dev/null 2>&1 || true
  fi
  run rm -f "$pid_path"
}

remove_warp_forwarding() {
  local device="$1"
  local unit="warppool-warp-forward-$device.service"
  local unit_path="/etc/systemd/system/$unit"
  local openrc="warppool-warp-forward-$device"
  disable_systemd_unit "$unit"
  remove_systemd_unit_file "$unit_path"
  if openrc_available; then
    run rc-service "$openrc" stop >/dev/null 2>&1 || true
    run rc-update del "$openrc" default >/dev/null 2>&1 || true
    run rm -f "/etc/init.d/$openrc"
  fi
  stop_legacy_pid "/var/lib/warppool/warp-forward/$device.pid"
  delete_nat_redirect_rules "$device"
  run rm -f "/var/lib/warppool/warp-forward/$device.json" "/var/lib/warppool/warp-forward/$device.log" "/var/lib/warppool/warp-forward/$device.clients"
}

remove_wireguard_device() {
  local device="$1"
  disable_systemd_unit "wg-quick@$device.service"
  if openrc_available; then
    run rc-service "wg-quick.$device" stop >/dev/null 2>&1 || true
    run rc-update del "wg-quick.$device" default >/dev/null 2>&1 || true
    if [ -L "/etc/init.d/wg-quick.$device" ]; then
      run rm -f "/etc/init.d/wg-quick.$device"
    fi
  fi
  run wg-quick down "$device" >/dev/null 2>&1 || true
  if command -v ip >/dev/null 2>&1 && ip link show "$device" >/dev/null 2>&1; then
    run ip link delete dev "$device" >/dev/null 2>&1 || true
  fi
  run rm -f "/etc/wireguard/$device.conf"
  if [ "$device" = "wpshared" ]; then
    run rm -rf /etc/warppool-node/shared /etc/warppool-node/shared.lock
  fi
}

remaining_warppool_configs() {
  local path
  for path in /etc/wireguard/wp*.conf; do
    [ -e "$path" ] || continue
    return 0
  done
  return 1
}

cleanup_global_warppool_state_if_empty() {
  local alias_path alias_target
  if remaining_warppool_configs; then
    return 0
  fi
  run rm -f /etc/sysctl.d/99-warppool.conf
  alias_path="/usr/local/bin/wpl-node-uninstall"
  if [ "$DRY_RUN" = "true" ]; then
    log "dry-run: remove alias if it points to WarpPool node uninstaller: $alias_path"
  elif [ -L "$alias_path" ]; then
    alias_target="$(readlink "$alias_path" 2>/dev/null || true)"
    if [ "$alias_target" = "/usr/local/bin/warppool-node-uninstall" ] || [ "$alias_target" = "warppool-node-uninstall" ]; then
      run rm -f "$alias_path"
    else
      log "skip alias removal, points outside WarpPool: $alias_path -> $alias_target"
    fi
  elif [ -e "$alias_path" ]; then
    log "skip alias removal, not a symlink: $alias_path"
  fi
  run rm -f /usr/local/bin/warppool-node-uninstall
  run rm -rf /var/lib/warppool/warp-forward
  run rmdir /var/lib/warppool >/dev/null 2>&1 || true
  run rm -rf /usr/local/lib/warppool
}

remove_warp_package() {
  if [ "$REMOVE_WARP" != "true" ]; then
    return 0
  fi
  log "removing WARP package/state"
  if systemd_available; then
    run systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
  fi
  if command -v apt-get >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp
    run rm -f /etc/apt/sources.list.d/cloudflare-client.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    run rm -rf /etc/warppool-node/warp
    run rm -f /usr/local/lib/warppool/bin/wgcf
    return 0
  fi
  log "warning: supported package manager not found, skipping WARP package removal"
}

remove_wireguard_packages() {
  if [ "$REMOVE_WIREGUARD" != "true" ]; then
    return 0
  fi
  log "removing WireGuard packages"
  if command -v apt-get >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y wireguard wireguard-tools
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    run apk del wireguard-tools
    return 0
  fi
  log "warning: supported package manager not found, skipping WireGuard package removal"
}

main() {
  parse_args "$@"
  validate_bool all "$ALL"
  validate_bool remove_warp "$REMOVE_WARP"
  validate_bool remove_wireguard "$REMOVE_WIREGUARD"
  require_root

  local devices
  devices="$(discover_devices)"
  local device
  while IFS= read -r device; do
    [ -n "$device" ] || continue
    validate_device "$device"
    log "removing node device: $device"
  remove_warp_forwarding "$device"
  delete_direct_forwarding_rules "$device"
  remove_wireguard_device "$device"
  done <<EOF_DEVICES
$devices
EOF_DEVICES

  cleanup_global_warppool_state_if_empty
  remove_warp_package
  remove_wireguard_packages
  log "remote node uninstall completed"
}

main "$@"
