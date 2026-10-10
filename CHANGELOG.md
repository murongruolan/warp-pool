# Changelog

## Unreleased

- Added `shared_node.sh action=add-client` for non-main-server clients (local PC, phone, secondary machines). It appends a peer, hot-reloads the interface without touching existing tunnels, registers WARP forwarding for `warp`/`dual` mode, and renders a ready-to-import full-tunnel WireGuard client config to `/root/warppool-clients`.
- Added `shared_node.sh action=list` and `shared_node.sh action=remove target=<label|public-key>`. Removal re-renders the config, syncs it live, purges the removed peer's MASQUERADE rules, and unregisters its WARP forwarding client.
- `shared_node.sh` now records a `NAME` and the optional client private keys per peer, so clients can be re-exported and identified. Existing peers without these fields keep working.
- Added `warp_forward.sh action=register`, which adds one more client to an already running forwarder without restarting it, falling back to a full startup when no forwarder is running. Manual `shared_node.sh action=add mode=warp` is now self-sufficient instead of requiring the Go deploy path to finish WARP wiring.
- `shared_node.sh` can now fetch sibling helper scripts from the release URL when they are not next to the script itself.

## v0.1.12

- Added shared SSH Push exit-node layout. Multiple main servers can now deploy to the same exit node; the node keeps one shared WireGuard device (`wpshared`) and appends peers instead of overwriting existing peers.
- WARP forwarding now supports multiple WARP client addresses on the same remote WireGuard device, so shared `warp` / `dual` Push deployments can reuse one WARP runtime on the exit node.
- Added a conservative legacy safeguard: old `/etc/wireguard/wp*.conf` exclusive layouts are not converted automatically, avoiding accidental disruption of existing nodes.
- Disabled old node mode switching for shared Push nodes to avoid changing remote rules used by other main servers; use `dual` deployment when both direct and WARP ports are needed.
- Fixed interactive SSH Push deployment when `known_hosts` exists but does not yet trust the target host key. WarpPool now asks whether to skip HostKey verification for this run and retries.

## v0.1.11

- Added `dual` deployment mode: one exit node can expose both direct and WARP local proxy ports.
- `warppool deploy` and `warppool deploy-token` can select `dual/direct+warp` and validate both local ports.
- `warppool ping` checks both direct and WARP proxy ports for dual nodes.
- Clash export emits separate direct and WARP proxy entries for dual nodes.
- Fixed `warppool node remove` / `wpl node remove` removing only the node record without refreshing the local proxy, which left proxy ports occupied.
- `node remove` now prints the selected node details and asks for `y/N` confirmation, defaulting to `N`; after confirmation it refreshes/stops the local proxy and cleans local WireGuard client config by default.
- Added IPv6-only exit node support for `direct` mode: IPv6 WireGuard endpoints are bracketed automatically, IPv6 tunnel addresses are generated, and node-side direct forwarding now enables IPv6 forwarding plus `ip6tables` MASQUERADE.
- Pull/Deploy Token install scripts now format literal IPv6 main-server URLs correctly and prefer IPv6-capable endpoint detection.
- Debian/Ubuntu installers now back up and disable unavailable `*-backports` apt source entries, then retry `apt-get update`, avoiding deployment failures on Debian 11 IPv6-only nodes with stale backports repositories.
- Improved WARP forwarding setup: official WARP SOCKS readiness is retried, and Debian/Ubuntu nodes now prefer repository `redsocks` for SOCKS transparent forwarding to avoid sing-box download failures when GitHub API is unreachable on IPv6-only nodes.
- `singbox_install.sh` now falls back to a pinned sing-box release URL when the GitHub latest-release API cannot be queried.
- Fixed local proxy restart after adding a node: WARP inbound ports from existing `dual` nodes are now treated as managed ports, avoiding false `address already in use` errors.

## v0.1.10

- Added the short command alias `wpl`, equivalent to `warppool`, for example `wpl node list` and `wpl ping nat01`.
- Added the node-side short uninstaller command `wpl-node-uninstall`, equivalent to `warppool-node-uninstall`.
- Improved `warppool ping` Chinese output by renaming the node address label to the clearer node latency target address.
- Fixed English `mode` / `proxy check ok` style messages appearing in `warppool ping` when Chinese language is selected.
- Improved uninstall safety: the main-server uninstall flow only removes `/usr/local/bin/wpl` when it is a symlink pointing to WarpPool, avoiding accidental removal of another program.

## v0.1.9

- Added Alpine WARP support based on `wgcf` generated WireGuard profiles and sing-box embedded WireGuard endpoints.
- Alpine WARP endpoint probing now prefers IPv6, falls back to IPv4, and finally falls back to the original domain.
- Alpine sing-box installation now prefers the Alpine package repository with `apk update && apk add --no-cache sing-box`.
- Added automatic fallback to the GitHub musl sing-box build when the Alpine package is missing, cannot run, or cannot load WarpPool's generated WARP config.
- Fixed failed Alpine WARP deployment caused by downloading a non-musl sing-box binary.

## v0.1.8

- Officially optimized WARP mode for 1 GB-class small disk exit nodes. Debian/Ubuntu installers now avoid the `wireguard` meta package, install only required WireGuard tools, use `--no-install-recommends` where possible, and clean package caches after install steps.
- Fixed WARP installation after lightweight dependency changes by installing `gpg` only when WARP mode needs the Cloudflare apt repository.
- Relaxed WARP disk preflight for small NAT VPS nodes: low disk space now shows a warning when it is above the hard minimum instead of blocking too early.
- `warppool node mode --method ssh` now reuses saved non-sensitive SSH defaults from Push deployment. SSH passwords are never saved.
- `warppool ping` now reports node latency target RTT, main-server direct HTTP latency, proxy egress IP, and proxy HTTP latency, with multiple fallback check URLs.

## v0.1.5

- Fixed node mode switch language inheritance. Pull-installed nodes now save the selected language, and `node_mode.sh` reads it for later direct/WARP switches.
- Added clearer one-time token expiry warnings for Deploy Token and node mode switch commands.
- Added Cloudflare WARP disk and inode preflight checks before installing the official WARP client, with clearer recovery guidance when `apt` fails because of low disk quota.
- Fixed SSH Push deployment for non-root users by automatically using `sudo` for privileged remote operations when available.
