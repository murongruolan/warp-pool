#!/usr/bin/env bash
set -Eeuo pipefail

WPLS_UPDATE_VERSION="2026.10.11-r1"

# Updates the exit-node tooling on an already installed node.
#
# Only touches /usr/local: it never reads or writes /etc/wireguard, iptables or
# any systemd state, so it is safe to run on a node that is serving traffic.
#
# The tarball is requested by commit SHA rather than by branch name. codeload
# serves branch tarballs from a CDN that can hand back a stale copy, which is
# how an update silently installed the previous revision.

REPO="${WARPPOOL_REPO:-murongruolan/warp-pool}"
BRANCH="${WARPPOOL_BRANCH:-developer}"
WORK="/tmp/warppool-update.$$"
BIN_DIR="/usr/local/bin"
NODE_LIB="/usr/local/lib/warppool/node"
HELPERS="warp_forward.sh warp_install.sh warp_wgcf.sh singbox_install.sh wg_preflight.sh"

ok_count=0
bad_count=0

log()  { printf '[wpls-update] %s\n' "$*"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; ok_count=$((ok_count + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; bad_count=$((bad_count + 1)); }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

fail() { printf '[wpls-update][ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() { [ -d "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

require_root() {
  [ "$(id -u)" -eq 0 ] || fail "需要 root 权限"
}

require_tools() {
  local t
  for t in curl tar bash; do
    command -v "$t" >/dev/null 2>&1 || fail "缺少命令: $t"
  done
}

# Resolve the exact commit so the download cannot be a stale CDN copy.
resolve_url() {
  local sha=""
  if command -v curl >/dev/null 2>&1; then
    sha="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null |
      grep -m1 -o '"sha": *"[0-9a-f]\{40\}"' | grep -o '[0-9a-f]\{40\}' || true)"
  fi
  if [ -n "$sha" ]; then
    log "目标提交: $sha"
    printf 'https://codeload.github.com/%s/tar.gz/%s\n' "$REPO" "$sha"
    return 0
  fi
  log "取不到提交 SHA，退回分支 URL（可能命中 CDN 缓存，安装后会逐项比对）"
  printf 'https://codeload.github.com/%s/tar.gz/refs/heads/%s\n' "$REPO" "$BRANCH"
}

download_and_extract() {
  local url src
  url="$(resolve_url)"
  mkdir -p "$WORK"
  log "下载: $url"
  curl -fsSL --max-time 120 -o "$WORK/src.tar.gz" "$url" || fail "下载失败"
  tar -xzf "$WORK/src.tar.gz" -C "$WORK" || fail "解压失败"
  src="$(find "$WORK" -maxdepth 1 -type d -name 'warp-pool-*' | head -n 1)"
  [ -n "$src" ] || fail "解压后找不到源码目录"
  [ -d "$src/assets" ] || fail "解压后找不到 assets 目录"
  printf '%s/assets\n' "$src"
}

install_files() {
  local d="$1"
  [ -r "$d/wpls.sh" ] || fail "包内缺少 wpls.sh"
  [ -r "$d/legacy_add_client.sh" ] || fail "包内缺少 legacy_add_client.sh"
  install -m 0755 "$d/wpls.sh" "$BIN_DIR/wpls"
  install -m 0755 "$d/legacy_add_client.sh" "$BIN_DIR/warppool-node-client"
  mkdir -p "$NODE_LIB"
  local n
  for n in $HELPERS; do
    [ -r "$d/$n" ] && install -m 0755 "$d/$n" "$NODE_LIB/$n"
  done
  # Keep the updater itself around for next time.
  if [ -r "$d/wpls-update.sh" ]; then
    install -m 0755 "$d/wpls-update.sh" "$BIN_DIR/wpls-update"
  fi
}

verify() {
  local d="$1" full="${2:-full}"

  hr
  printf '检查结果\n'
  hr

  if [ "$full" = "full" ]; then
    log "语法检查"
    local f
    for f in "$BIN_DIR/wpls" "$BIN_DIR/warppool-node-client"; do
      if bash -n "$f" 2>/dev/null; then pass "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
    done

    log "文件一致性（与刚下载的包逐字节比对）"
    local pair s t
    for pair in "wpls.sh:$BIN_DIR/wpls" "legacy_add_client.sh:$BIN_DIR/warppool-node-client"; do
      s="${pair%%:*}"
      t="${pair#*:}"
      if cmp -s "$d/$s" "$t"; then pass "$(basename "$t") 与包内一致"; else bad "$(basename "$t") 与包内不一致（可能仍是旧版）"; fi
    done
  fi

  log "运行时 helper"
  local n cnt=0
  for n in $HELPERS; do
    if [ -r "$NODE_LIB/$n" ]; then cnt=$((cnt + 1)); fi
  done
  if [ "$cnt" -eq 5 ]; then pass "$NODE_LIB 下 5 个 helper 齐全"; else bad "$NODE_LIB 只有 $cnt/5 个 helper"; fi
  if [ "$full" = "full" ]; then
    for n in $HELPERS; do
      [ -r "$NODE_LIB/$n" ] || continue
      cmp -s "$d/$n" "$NODE_LIB/$n" || bad "$n 与包内不一致"
    done
  fi

  log "关键能力自检"
  if grep -q 'register)' "$NODE_LIB/warp_forward.sh" 2>/dev/null; then
    pass "warp_forward.sh 支持 action=register"
  else
    bad "warp_forward.sh 不支持 action=register（这是版本不匹配的典型症状）"
  fi
  if grep -q 'client_ip=' "$BIN_DIR/warppool-node-client" 2>/dev/null; then
    pass "客户端脚本支持 client_ip="
  else
    bad "客户端脚本不支持 client_ip="
  fi
  if grep -q 'init_server' "$BIN_DIR/warppool-node-client" 2>/dev/null; then
    pass "客户端脚本支持 action=init"
  else
    bad "客户端脚本不支持 action=init"
  fi
  if grep -q 'cmd_init' "$BIN_DIR/wpls" 2>/dev/null; then
    pass "wpls 支持 init 子命令"
  else
    bad "wpls 不支持 init 子命令"
  fi
  if grep -q 'WARP registration FAILED' "$BIN_DIR/warppool-node-client" 2>/dev/null; then
    pass "客户端脚本具备 WARP 注册失败回滚"
  else
    bad "客户端脚本缺少 WARP 注册失败回滚"
  fi

  log "版本号"
  printf '  wpls                : %s\n' "$("$BIN_DIR/wpls" version 2>/dev/null | awk '{print $2}' || echo '?')"
  printf '  warppool-node-client: %s\n' "$(grep -m1 '^SCRIPT_VERSION=' "$BIN_DIR/warppool-node-client" 2>/dev/null | cut -d'"' -f2 || echo '?')"

  hr
  if [ "$bad_count" -eq 0 ]; then
    printf '\033[32m全部检查通过（%d 项）\033[0m\n' "$ok_count"
  else
    printf '\033[31m有 %d 项不通过\033[0m（通过 %d 项）\n' "$bad_count" "$ok_count"
    return 1
  fi
  return 0
}

show_node_state() {
  hr
  printf '现有节点状态（只读，未做任何改动）\n'
  hr
  if [ -x "$BIN_DIR/wpls" ]; then
    "$BIN_DIR/wpls" list || true
  fi
  printf '\n'
  printf 'WireGuard 配置: %s\n' "$(ls /etc/wireguard/*.conf 2>/dev/null | tr '\n' ' ' || echo '(无)')"
  if command -v wg >/dev/null 2>&1; then
    printf '运行中接口  : %s\n' "$(wg show interfaces 2>/dev/null | tr '\n' ' ' || echo '(无)')"
  fi
}

usage() {
  cat <<USAGE
wpls-update - 更新出口节点上的 wpls 工具集  (${WPLS_UPDATE_VERSION})

用法:
  wpls-update                 从 $BRANCH 分支更新并自检
  wpls-update --check         只做自检，不下载安装
  wpls-update --help

环境变量:
  WARPPOOL_REPO    默认 $REPO
  WARPPOOL_BRANCH  默认 $BRANCH

只写入 /usr/local，不触碰 /etc/wireguard、iptables 与 systemd 状态，
可在正在承载流量的节点上安全执行。
USAGE
}

check_only() {
  bad_count=0
  ok_count=0
  verify "" capability
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --check) require_root; require_tools; check_only; show_node_state; exit $? ;;
  esac

  require_root
  require_tools

  hr
  printf '更新出口节点工具集（%s / %s）\n' "$REPO" "$BRANCH"
  hr

  local assets vrc=0
  assets="$(download_and_extract)"
  log "包内 wpls 版本: $(grep -m1 '^WPLS_VERSION=' "$assets/wpls.sh" | cut -d'"' -f2)"
  log "包内客户端版本: $(grep -m1 '^SCRIPT_VERSION=' "$assets/legacy_add_client.sh" | cut -d'"' -f2)"

  install_files "$assets"
  verify "$assets" full || vrc=1
  show_node_state
  exit "$vrc"
}

main "$@"
