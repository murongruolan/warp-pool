#!/usr/bin/env bash
set -Eeuo pipefail

WPLS_VERSION="2026.10.11-r2"

# wpls - WarpPool exit-node connection manager.
#
# A local management CLI for a WarpPool exit node. It performs no installation.
# Every mutating operation is delegated to legacy_add_client.sh, which owns the
# config rendering, wg-quick validation, hot apply, rollback and NAT handling.
# This script only maintains the local connection registry, renders the list
# with live status, and collects interactive input.
#
# Install-time behaviour (environment checks, dependency installation,
# registration with the main server, WireGuard bring-up) is untouched.

STATE_BASE="/etc/wireguard"
CLIENT_ROOT="/etc/warppool-node/legacy-clients"
CONFIG_DIR="/root/warppool-clients"
HELPER_CACHE="/usr/local/lib/warppool/legacy_add_client.sh"
HELPER=""
VIEW_FILE=""
KEYS_FILE=""
BASE_URL="${WARPPOOL_INSTALL_BASE_URL:-${WARPOOL_INSTALL_BASE_URL:-https://raw.githubusercontent.com/murongruolan/warp-pool/developer/assets}}"

log()  { printf '[wpls] %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

fail() {
  printf '[wpls][ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  printf '[wpls][ERROR] command failed with exit %s at line %s: %s\n' \
    "$status" "$1" "$BASH_COMMAND" >&2
  exit "$status"
}
trap 'on_error $LINENO' ERR

cleanup() {
  [ -n "${VIEW_FILE:-}" ] && [ -f "$VIEW_FILE" ] && rm -f "$VIEW_FILE"
  [ -n "${KEYS_FILE:-}" ] && [ -f "$KEYS_FILE" ] && rm -f "$KEYS_FILE"
  return 0
}
trap cleanup EXIT

usage() {
  cat <<USAGE
wpls - WarpPool 出口节点连接管理  (${WPLS_VERSION})

用法:
  wpls list                     查看本地连接列表
  wpls list add                 添加一台主服务器（对方运行 wpl 主服务器端）
  wpls list wgadd               添加一台独立 WireGuard 设备（只用本节点出口，不装 wpl）
  wpls list remove [序号]       删除指定连接及其 WireGuard 配置
  wpls list edit                修改连接信息（名称 / 公钥 / 地址）
  wpls help                     显示本帮助
  wpls version                  显示版本

列表字段:

  序号  名称           类型     端口    地址             状态
  ----  -------------  -------  ------  ---------------  --------

  类型  wpl     由 wpls list add 登记的主服务器
        wg      由 wpls list wgadd 登记的独立设备
        未登记  已经存在于 WireGuard 配置里、但没有经过 wpls 登记
  端口  wg 类型显示客户端连接用的公网端口；其余显示节点本机监听端口
  状态  在线 = 最近 3 分钟内有握手
        离线 = 有过握手，但已超过 3 分钟
        从未握手 = 一次握手都没有
        不在接口上 = 配置里有，但运行中的接口上没有这个 peer

说明:
  所有改动都会先校验配置、再热更新（wg syncconf），失败自动回滚，
  已有连接不会断线。删除与修改前都会先打印当前列表并要求确认。
USAGE
}

# --------------------------------------------------------------- helpers ----

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd
}

download_helper() {
  command -v curl >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$HELPER_CACHE")" 2>/dev/null || return 1
  if curl -fsSL "$BASE_URL/legacy_add_client.sh" -o "$HELPER_CACHE" 2>/dev/null; then
    chmod 0755 "$HELPER_CACHE" 2>/dev/null || true
    return 0
  fi
  return 1
}

resolve_helper() {
  local d candidate
  d="$(script_dir)"
  for candidate in \
    "$d/legacy_add_client.sh" \
    "$d/warppool-node-client" \
    "/root/legacy_add_client.sh" \
    "$HELPER_CACHE"
  do
    if [ -r "$candidate" ]; then
      HELPER="$candidate"
      return 0
    fi
  done
  if download_helper; then
    HELPER="$HELPER_CACHE"
    log "已从发布地址下载配件脚本: $HELPER_CACHE"
    return 0
  fi
  return 1
}

require_helper() {
  resolve_helper && return 0
  fail "找不到 legacy_add_client.sh。请把它与 wpls 放在同一目录，或放到 /root/ 下。"
}

run_helper() {
  require_helper
  bash "$HELPER" "$@"
}

ask() {
  local var="$1" label="$2" default="${3:-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r reply || fail "输入中断，未做任何改动"
  reply="${reply:-$default}"
  printf -v "$var" '%s' "$(printf '%s' "$reply" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
}

confirm() {
  local label="${1:-确认执行}" reply
  printf '%s？输入 yes 继续，其他任意键取消：' "$label" >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

is_public_key() {
  case "$1" in
    ""|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  [ "${#1}" -eq 44 ] && [ "${1: -1}" = "=" ]
}

# Sets GEN_PRIV / GEN_PUB. legacy_add_client.sh has no "generate for me" mode,
# so the keypair is produced here and both halves are passed on: the public half
# becomes the peer, the private half is written into the exported client config.
GEN_PRIV=""
GEN_PUB=""
gen_keypair() {
  command -v wg >/dev/null 2>&1 || fail "需要 wg 命令生成密钥，请先安装 wireguard-tools"
  GEN_PRIV="$(wg genkey)"
  GEN_PUB="$(printf '%s' "$GEN_PRIV" | wg pubkey)"
  [ -n "$GEN_PUB" ] || fail "生成密钥对失败"
}

all_devices() {
  local f
  for f in "$STATE_BASE"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

device_count() {
  all_devices | grep -c . || true
}

detect_device() {
  local list count picked
  list="$(all_devices)"
  count="$(printf '%s\n' "$list" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    fail "在 $STATE_BASE 下找不到任何 WireGuard 配置"
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$list"
    assert_manageable "$list"
    return 0
  fi
  log "检测到多个 WireGuard 设备:"
  printf '%s\n' "$list" | sed 's/^/  - /' >&2
  while true; do
    ask picked "要操作的设备名" ""
    if printf '%s\n' "$list" | grep -qx "$picked"; then
      assert_manageable "$picked"
      printf '%s\n' "$picked"
      return 0
    fi
    log "没有这个设备，请重新输入"
  done
}

# A shared (Push-deployed) node keeps its peer registry in shared_node.sh's own
# state directory. Editing that config from here would desynchronise the two,
# so refuse instead of corrupting it.
assert_manageable() {
  if [ "$1" = "wpshared" ]; then
    fail "设备 wpshared 属于共享 Push 布局，由 shared_node.sh 管理。
请不要用 wpls 修改它，改用:
  shared_node.sh action=list
  shared_node.sh action=add-client ...
  shared_node.sh action=remove target=<name>"
  fi
}

listen_port_of() {
  sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*//p' "$STATE_BASE/$1.conf" 2>/dev/null |
    head -n 1 | tr -d '[:space:]'
}

conf_prefix() {
  sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$STATE_BASE/$1.conf" 2>/dev/null |
    head -n 1 | cut -d, -f1 | awk -F'[./]' '{print $1"."$2"."$3}'
}

next_free_address() {
  local dev="$1" prefix n used
  prefix="$(conf_prefix "$dev")"
  [ -n "$prefix" ] || return 1
  used="$(wg show "$dev" allowed-ips 2>/dev/null | awk '{print $2}' || true)"
  for n in $(seq 2 254); do
    if ! printf '%s\n' "$used" | grep -qx "$prefix.$n/32"; then
      printf '%s\n' "$prefix.$n"
      return 0
    fi
  done
  return 1
}

record_path() {
  printf '%s/%s/%s.env\n' "$CLIENT_ROOT" "$1" "$2"
}

# Records the fields legacy_add_client.sh does not know about, so a connection
# keeps its kind/device/port across edits and list runs.
augment_record() {
  local dev="$1" name="$2" kind="$3" port="$4" file tmp
  file="$(record_path "$dev" "$name")"
  [ -r "$file" ] || return 0
  tmp="$file.tmp.$$"
  grep -vE "^(KIND|DEVICE|PORT)=" "$file" >"$tmp" || :
  printf "KIND='%s'\nDEVICE='%s'\nPORT='%s'\n" "$kind" "$dev" "${port:-}" >>"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

status_of() {
  local dev="$1" key="$2" ts now
  [ -n "$key" ] || { printf '未登记'; return 0; }
  ts="$(wg show "$dev" latest-handshakes 2>/dev/null | awk -v k="$key" '$1==k{print $2}' || true)"
  if [ -z "$ts" ]; then
    printf '不在接口上'
    return 0
  fi
  if [ "$ts" -eq 0 ]; then
    printf '从未握手'
    return 0
  fi
  now="$(date +%s)"
  if [ $((now - ts)) -lt 180 ]; then
    printf '在线'
  else
    printf '离线'
  fi
}

port_of() {
  local dev="$1" kind="$2" endpoint="$3" p
  if [ "$kind" = "wg" ] && [ -n "$endpoint" ]; then
    p="${endpoint##*:}"
    case "$p" in
      ""|*[!0-9]*) ;;
      *) printf '%s\n' "$p"; return 0 ;;
    esac
  fi
  p="$(listen_port_of "$dev")"
  [ -n "$p" ] || p="-"
  printf '%s\n' "$p"
}

# A peer's endpoint is the address the client connects FROM, so it is NOT the
# address a new client must dial. Ask an external service for this node's own
# public address; on a 1:1 NAT VPS that is exactly the dial address.
guess_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- -T 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  case "$ip" in
    *[!0-9.]*|"") ip="" ;;
  esac
  printf '%s' "$ip"
}

kind_label() {
  case "$1" in
    wpl) printf 'wpl' ;;
    wg) printf 'wg' ;;
    *) printf '未登记' ;;
  esac
}

# ------------------------------------------------------------ list output ----

# Emits one TAB separated line per connection:
#   index  name  kind  port  addr  status  publickey  registered  device
build_view() {
  local dev="$1"
  VIEW_FILE="$(mktemp)"
  KEYS_FILE="$(mktemp)"
  local idx=0

  local rdev rpath
  for rdev in $(all_devices); do
    for rpath in "$CLIENT_ROOT/$rdev"/*.env; do
      [ -e "$rpath" ] || continue
      local NAME="" MODE="" KIND="" DEVICE="" PORT=""
      local CLIENT_PUBLIC_KEY="" CLIENT_IPV4="" WARP_CLIENT_PUBLIC_KEY=""
      local WARP_CLIENT_IPV4="" ENDPOINT=""
      # shellcheck disable=SC1090
      . "$rpath"
      [ -n "$KIND" ] || KIND="wg"
      local use_dev="${DEVICE:-$rdev}"
      local addr="${CLIENT_IPV4:-${WARP_CLIENT_IPV4:-}}"
      idx=$((idx + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tyes\t%s\n' \
        "$idx" "${NAME:-<未命名>}" "$(kind_label "$KIND")" \
        "$(port_of "$use_dev" "$KIND" "$ENDPOINT")" \
        "${addr%%/*}" "$(status_of "$use_dev" "$CLIENT_PUBLIC_KEY")" \
        "$CLIENT_PUBLIC_KEY" "$use_dev" >>"$VIEW_FILE"
      [ -n "$CLIENT_PUBLIC_KEY" ] && printf '%s\n' "$CLIENT_PUBLIC_KEY" >>"$KEYS_FILE"
      [ -n "$WARP_CLIENT_PUBLIC_KEY" ] && printf '%s\n' "$WARP_CLIENT_PUBLIC_KEY" >>"$KEYS_FILE"
    done
  done

  # Peers that exist on an interface but were never registered through wpls.
  local d key addr
  for d in $(all_devices); do
    while read -r key addr; do
      [ -n "$key" ] || continue
      if [ -s "$KEYS_FILE" ] && grep -qxF "$key" "$KEYS_FILE"; then
        continue
      fi
      idx=$((idx + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tno\t%s\n' \
        "$idx" "<未登记>" "未登记" "$(port_of "$d" "" "")" \
        "${addr%%/*}" "$(status_of "$d" "$key")" "$key" "$d" >>"$VIEW_FILE"
      printf '%s\n' "$key" >>"$KEYS_FILE"
    done < <(wg show "$d" allowed-ips 2>/dev/null || true)
  done

  VIEW_COUNT="$idx"
}

print_view() {
  hr
  printf '%s\n' "序号  名称           类型    端口    地址             状态"
  hr
  if [ "${VIEW_COUNT:-0}" -eq 0 ]; then
    printf '%s\n' "  （还没有任何连接）"
    hr
    return 0
  fi
  awk -F'\t' '{ printf "%-4s  %-13s  %-6s  %-6s  %-15s  %s\n", $1, $2, $3, $4, $5, $6 }' "$VIEW_FILE"
  hr
}

view_field() {
  local idx="$1" field="$2"
  awk -F'\t' -v i="$idx" -v f="$field" 'NR==i { print $f }' "$VIEW_FILE"
}

view_header() {
  printf '\n wpls 本地连接列表\n'
  print_view
}

pick_index() {
  local target="$1" chosen
  while true; do
    ask chosen "序号" ""
    case "$chosen" in
      ""|*[!0-9]*) log "请输入列表里的序号数字"; continue ;;
    esac
    if [ "$chosen" -lt 1 ] || [ "$chosen" -gt "${VIEW_COUNT:-0}" ]; then
      log "序号超出范围（1-${VIEW_COUNT:-0}）"
      continue
    fi
    printf -v "$target" '%s' "$chosen"
    return 0
  done
}

# --------------------------------------------------------------- commands ----

simple_list() {
  local dev
  dev="$(detect_device)"
  log "出口节点设备: $dev   本机监听端口: $(listen_port_of "$dev")"
  build_view "$dev"
  print_view
}

cmd_add() {
  local dev name pub ip mode
  dev="$(detect_device)"
  info ""
  info "添加一台主服务器（对方运行 wpl 主服务器端）。"
  info "需要对方 WireGuard 客户端配置里的公钥。"
  info ""

  ask name "连接名称" ""
  [ -n "$name" ] || fail "名称不能为空"

  while true; do
    ask pub "主服务器 WireGuard 公钥（44 字符）" ""
    is_public_key "$pub" && break
    log "公钥格式不对，请重新输入"
  done

  local suggest
  suggest="$(next_free_address "$dev" || true)"
  ask ip "隧道地址（留空则自动分配下一个可用地址）" "$suggest"
  if [ -n "$ip" ]; then
    case "$ip" in
      *[!0-9.]*) fail "地址格式不对: $ip" ;;
    esac
  fi

  while true; do
    ask mode "出口模式  1=direct 本机出口   2=warp WARP出口" "1"
    case "$mode" in
      1|direct) mode="direct"; break ;;
      2|warp) mode="warp"; break ;;
      *) log "请输入 1 或 2" ;;
    esac
  done

  info ""
  info "即将执行："
  info "  设备      : $dev"
  info "  名称      : $name"
  info "  类型      : wpl（主服务器）"
  info "  公钥      : $pub"
  info "  地址      : ${ip:-<自动分配>}"
  info "  出口模式  : $mode"
  info ""
  confirm "确认添加" || { info "已取消，未做任何改动。"; return 0; }

  local args=(action=add "device=$dev" "mode=$mode" "name=$name" "client_public_key=$pub")
  [ -n "$ip" ] && args+=("client_ip=$ip")
  run_helper "${args[@]}"

  augment_record "$dev" "$name" "wpl" "$(listen_port_of "$dev")"
  info ""
  info "已登记为主服务器连接：$name"
}

cmd_wgadd() {
  local dev name mode pub pub_ip pub_port endpoint cpriv wpub wpriv
  dev="$(detect_device)"
  info ""
  info "添加一台独立 WireGuard 设备：只要本节点的出口流量，不安装 wpl。"
  info ""

  ask name "连接名称" ""
  [ -n "$name" ] || fail "名称不能为空"

  while true; do
    ask mode "出口模式  1=direct 本机出口   2=warp WARP出口   3=dual 两者都要" "1"
    case "$mode" in
      1|direct) mode="direct"; break ;;
      2|warp) mode="warp"; break ;;
      3|dual) mode="dual"; break ;;
      *) log "请输入 1、2 或 3" ;;
    esac
  done

  ask pub "客户端公钥（44 字符；直接回车则由本节点生成密钥对）" ""
  if [ -n "$pub" ]; then
    is_public_key "$pub" || fail "公钥格式不对（应 44 字符且以 = 结尾）"
    if [ "$mode" = "dual" ]; then
      ask wpub "第二条（WARP 隧道）公钥（必须与上面不同；直接回车则由本节点生成）" ""
      if [ -n "$wpub" ]; then
        is_public_key "$wpub" || fail "公钥格式不对（应 44 字符且以 = 结尾）"
        [ "$wpub" = "$pub" ] && fail "两条隧道不能用同一个公钥"
      fi
    fi
  fi

  # Fill in whatever was left blank. Done before the summary so the values shown
  # are the ones actually used.
  cpriv=""; wpriv=""
  if [ -z "$pub" ]; then
    gen_keypair
    cpriv="$GEN_PRIV"; pub="$GEN_PUB"
    log "已在本节点生成密钥对，私钥会直接写进客户端配置"
  fi
  if [ "$mode" = "dual" ] && [ -z "$wpub" ]; then
    gen_keypair
    wpriv="$GEN_PRIV"; wpub="$GEN_PUB"
    log "已在本节点生成第二条（WARP）密钥对"
  fi

  local lp ip_hint port_hint
  lp="$(listen_port_of "$dev")"
  info ""
  info "出口节点 $dev 在本机监听 UDP $lp"
  info "NAT 上需要有一条 公网端口 -> 本机 $lp 的 UDP 映射。"
  if [ "$mode" = "dual" ]; then
    info "dual 模式的两条隧道共用这一个端口。"
  fi
  info ""

  ip_hint="$(guess_public_ip)"
  port_hint="$(grep -h '^ENDPOINT=' "$CLIENT_ROOT"/*/*.env 2>/dev/null |
    head -n 1 | cut -d= -f2- | tr -d "'" | awk -F: '{print $NF}' || true)"

  if [ -n "$ip_hint" ]; then
    info "本节点探测到的公网地址: $ip_hint"
  else
    info "探测不到本节点公网地址，请手动填写。"
  fi
  info "注意：这里要填的是【本节点】对外的地址，不是主服务器的地址。"
  info ""
  ask pub_ip "公网 IP（本节点对外地址）" "$ip_hint"
  ask pub_port "公网映射端口（NAT 上的外部端口）" "$port_hint"
  [ -n "$pub_ip" ] || fail "公网 IP 不能为空"
  case "$pub_port" in
    ""|*[!0-9]*) fail "公网映射端口必须是数字: $pub_port" ;;
  esac
  if [ "$pub_port" -lt 1 ] || [ "$pub_port" -gt 65535 ]; then
    fail "公网映射端口必须在 1-65535 之间: $pub_port"
  fi
  endpoint="$pub_ip:$pub_port"

  info ""
  info "即将执行："
  info "  设备         : $dev"
  info "  名称         : $name"
  info "  类型         : wg（独立设备）"
  info "  出口模式     : $mode"
  info "  客户端公钥   : $pub"
  if [ -n "$wpub" ]; then
    info "  WARP 公钥    : $wpub"
  fi
  info "  公网 endpoint: $endpoint"
  info ""
  confirm "确认添加" || { info "已取消，未做任何改动。"; return 0; }

  local args=(action=add "device=$dev" "mode=$mode" "name=$name"
              "endpoint=$endpoint" "client_public_key=$pub")
  [ -n "$cpriv" ] && args+=("client_private_key=$cpriv")
  [ -n "$wpub" ] && args+=("warp_client_public_key=$wpub")
  [ -n "$wpriv" ] && args+=("warp_client_private_key=$wpriv")
  run_helper "${args[@]}"

  augment_record "$dev" "$name" "wg" "$pub_port"
  info ""
  info "已登记为独立设备连接：$name"
  info "客户端配置在 $CONFIG_DIR/ 下，含占位符的私钥那一行需要你自己填写。"
}

cmd_remove() {
  local dev want idx name rkind rdev
  dev="$(detect_device)"
  build_view "$dev"
  view_header

  if [ "${VIEW_COUNT:-0}" -eq 0 ]; then
    info "没有可删除的连接。"
    return 0
  fi

  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    want="$1"
    case "$want" in
      ""|*[!0-9]*) fail "序号必须是数字: $want" ;;
    esac
    if [ "$want" -lt 1 ] || [ "$want" -gt "$VIEW_COUNT" ]; then
      fail "序号超出范围（1-$VIEW_COUNT）"
    fi
  else
    pick_index want
  fi

  if [ "$(view_field "$want" 8)" != "yes" ]; then
    fail "序号 $want 不是通过 wpls 登记的连接，无法在这里删除。
主服务器请在其本机执行 warppool node remove，或直接用 wg 命令移除该 peer。"
  fi

  name="$(view_field "$want" 2)"
  rkind="$(view_field "$want" 3)"
  rdev="$(view_field "$want" 9)"

  info ""
  info "即将删除："
  info "  序号  : $want"
  info "  名称  : $name"
  info "  类型  : $rkind"
  info "  设备  : $rdev"
  info "  地址  : $(view_field "$want" 5)"
  info "  状态  : $(view_field "$want" 6)"
  info ""
  info "会同时移除：WireGuard peer、对应的 NAT 规则、WARP 转发登记、客户端配置文件。"
  confirm "确认删除" || { info "已取消，未做任何改动。"; return 0; }

  run_helper action=remove "device=$rdev" "name=$name"
  rm -f "$(record_path "$rdev" "$name")"
  info ""
  info "已删除连接：$name"
}

cmd_edit() {
  local dev choice newvalue idx name rdev mode
  dev="$(detect_device)"
  info ""
  info "修改连接信息："
  info "  1 = 名称   (name)"
  info "  2 = 公钥   (public key)"
  info "  3 = 地址   (address)"
  info ""
  while true; do
    ask choice "要修改什么" ""
    case "$choice" in
      1|name|名称) choice="name"; break ;;
      2|publickey|public_key|公钥) choice="publickey"; break ;;
      3|address|地址) choice="address"; break ;;
      *) log "请输入 1、2 或 3" ;;
    esac
  done

  case "$choice" in
    name)
      ask newvalue "新的名称" ""
      [ -n "$newvalue" ] || fail "新名称不能为空"
      ;;
    publickey)
      while true; do
        ask newvalue "新的公钥（44 字符）" ""
        is_public_key "$newvalue" && break
        log "公钥格式不对，请重新输入"
      done
      ;;
    address)
      ask newvalue "新的隧道地址" ""
      [ -n "$newvalue" ] || fail "新地址不能为空"
      case "$newvalue" in
        *[!0-9.]*) fail "地址格式不对: $newvalue" ;;
      esac
      ;;
  esac

  build_view "$dev"
  view_header
  if [ "${VIEW_COUNT:-0}" -eq 0 ]; then
    info "没有可修改的连接。"
    return 0
  fi
  pick_index idx

  if [ "$(view_field "$idx" 8)" != "yes" ]; then
    fail "序号 $idx 不是通过 wpls 登记的连接，无法在这里修改。"
  fi

  name="$(view_field "$idx" 2)"
  rdev="$(view_field "$idx" 9)"
  local rpath
  rpath="$(record_path "$rdev" "$name")"
  [ -r "$rpath" ] || fail "找不到登记文件: $rpath"

  local NAME="" MODE="" KIND="" DEVICE="" PORT="" CLIENT_PUBLIC_KEY=""
  local CLIENT_IPV4="" WARP_CLIENT_PUBLIC_KEY="" WARP_CLIENT_IPV4="" ENDPOINT=""
  # shellcheck disable=SC1090
  . "$rpath"
  mode="${MODE:-direct}"
  local oldkey="${CLIENT_PUBLIC_KEY:-}"
  local oldaddr="${CLIENT_IPV4:-${WARP_CLIENT_IPV4:-}}"
  local kind="${KIND:-wg}"
  local port="${PORT:-}"
  local endpoint="${ENDPOINT:-}"

  info ""
  info "即将修改：$name（设备 $rdev）"
  case "$choice" in
    name)      info "  名称 : $name  ->  $newvalue" ;;
    publickey) info "  公钥 : $oldkey  ->  $newvalue" ;;
    address)   info "  地址 : $oldaddr  ->  $newvalue" ;;
  esac
  if [ "$choice" = "address" ]; then
    info "  注意：改地址会先移除再重建该 peer，隧道会短暂中断几秒。"
  fi
  info ""
  confirm "确认修改" || { info "已取消，未做任何改动。"; return 0; }

  if [ "$choice" = "name" ]; then
    [ -e "$(record_path "$rdev" "$newvalue")" ] && fail "名称已存在: $newvalue"
    mv "$rpath" "$(record_path "$rdev" "$newvalue")"
    local suffix f
    for suffix in ".conf" "-direct.conf" "-warp.conf"; do
      f="$CONFIG_DIR/$name$suffix"
      [ -e "$f" ] && mv "$f" "$CONFIG_DIR/$newvalue$suffix"
    done
    info ""
    info "已把连接重命名为：$newvalue"
    info "客户端本地配置无需改动，名称只是本节点上的标记。"
    return 0
  fi

  if [ "$choice" = "publickey" ]; then
    run_helper action=rotate "device=$rdev" "name=$name" "client_public_key=$newvalue"
    info ""
    info "已更换公钥：$name"
    info "客户端需要改用与新公钥配对的私钥。"
    return 0
  fi

  # address: remove and re-add with the requested address.
  local -a addargs=(action=add "device=$rdev" "mode=$mode" "name=$name"
                    "client_public_key=$oldkey" "client_ip=$newvalue")
  [ -n "$endpoint" ] && addargs+=("endpoint=$endpoint")
  [ -n "$WARP_CLIENT_PUBLIC_KEY" ] && addargs+=("warp_client_public_key=$WARP_CLIENT_PUBLIC_KEY")

  local recbak="$rpath.bak.$$"
  cp -a "$rpath" "$recbak" 2>/dev/null || :

  run_helper action=remove "device=$rdev" "name=$name"
  if ! run_helper "${addargs[@]}"; then
    log "重建失败。原登记已备份到: $recbak"
    log "可以用原地址恢复:"
    log "  bash $HELPER action=add device=$rdev mode=$mode name=$name client_public_key=$oldkey client_ip=$oldaddr${endpoint:+ endpoint=$endpoint}"
    fail "地址修改失败，peer 已被移除，请按上面的命令恢复"
  fi
  rm -f "$recbak"
  augment_record "$rdev" "$name" "$kind" "${port:-$(listen_port_of "$rdev")}"
  info ""
  info "已把地址改为：$newvalue"
}

# -------------------------------------------------------------- dispatch ----

dispatch() {
  local sub="${1:-}"
  case "$sub" in
    ""|help|-h|--help) usage ;;
    version|--version) printf 'wpls %s\n' "$WPLS_VERSION" ;;
    list)
      shift
      case "${1:-}" in
        "") simple_list ;;
        add) shift; cmd_add "$@" ;;
        wgadd) shift; cmd_wgadd "$@" ;;
        remove|rm|del) shift; cmd_remove "$@" ;;
        edit|modify) shift; cmd_edit "$@" ;;
        *) fail "未知子命令: wpls list $1（可用: add / wgadd / remove / edit）" ;;
      esac
      ;;
    add) shift; cmd_add "$@" ;;
    wgadd) shift; cmd_wgadd "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    edit) shift; cmd_edit "$@" ;;
    *)
      # Backward compatibility with the legacy "action=..." invocation style.
      run_helper "$@"
      ;;
  esac
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 0
  fi
  case "${1:-}" in
    help|-h|--help|version|--version) ;;
    *)
      if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限运行（要读写 $STATE_BASE 与 iptables）"
      fi
      ;;
  esac
  dispatch "$@"
}

main "$@"
