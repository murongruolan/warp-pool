# WarpPool

WireGuard-based multi-exit proxy management for small VPS and NAT VPS nodes.

[English](README.md) | [简体中文](README_CN.md)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Supported Platforms](#supported-platforms)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start: Push Deployment with Direct Mode](#quick-start-push-deployment-with-direct-mode)
- [WARP Mode](#warp-mode)
- [Dual Mode](#dual-mode)
- [Pull Deployment](#pull-deployment)
- [Deploy Token](#deploy-token)
- [Commands](#commands)
- [Exit Node: Extra Clients](#exit-node-extra-clients)
- [Configuration](#configuration)
- [Changelog](#changelog)
- [Release Process](#release-process)
- [Security Notes](#security-notes)
- [Current Limitations](#current-limitations)

---

## Overview

WarpPool lets one main server manage multiple exit nodes. Applications connect to local proxy ports on the main server, and WarpPool routes traffic through WireGuard tunnels to different exit nodes.

Exit mode:

- `direct`: traffic exits through the node's own network.
- `warp`: traffic exits through Cloudflare WARP on the node.
- `dual`: one exit node exposes both direct and WARP local proxy ports.

Typical flow:

```text
Application
  -> 127.0.0.1:<local proxy port>
  -> sing-box mixed/http/socks inbound on the main server
  -> WireGuard tunnel
  -> exit node
  -> direct network or Cloudflare WARP
  -> target website
```

---

## Features

- WireGuard tunnel generation and deployment
- SSH Push deployment for exit nodes
- Shared Push exit nodes: multiple main servers can reuse the same exit node without overwriting each other
- Optional Cloudflare WARP egress
- `dual` mode: one node can provide both direct and WARP egress ports
- User-defined local proxy ports
- `socks5`, `http`, and `mixed` local proxy modes
- sing-box config generation and process management
- Clash-compatible YAML export
- Local diagnostics: version, doctor, ping, speedtest, show

---

## Architecture

```text
Main server
  - WarpPool CLI
  - JSON config
  - WireGuard client
  - sing-box local proxy
  - Clash export

Exit node
  - WireGuard server
  - IPv4 forwarding / NAT
  - optional Cloudflare WARP egress runtime
  - no WarpPool Agent
```

---

## Supported Platforms

### Main server

| Platform | Status |
| --- | --- |
| Linux amd64 | Supported |
| Linux arm64 | Supported |

### Exit node

| OS | Status |
| --- | --- |
| Ubuntu 20.04+ | Supported |
| Debian 11+ | Supported |
| Alpine 3.20+ | Supported |

WARP mode is supported on Ubuntu/Debian and Alpine. Ubuntu/Debian use the official Cloudflare WARP client when available and prefer repository `redsocks` for WARP SOCKS transparent forwarding, reducing GitHub API dependency on IPv6-only nodes; if `redsocks` is unavailable, WarpPool falls back to sing-box. Alpine uses `wgcf` to generate a WARP WireGuard profile and sing-box's embedded WireGuard endpoint. On Alpine, WarpPool first runs `apk update` and installs `sing-box` from the Alpine package repository when available; if the package is unavailable, cannot run, or cannot load the generated WARP config, WarpPool falls back to the GitHub musl build.

Recommended disk size: around 1 GB. The installer is optimized for small disks by installing only required WireGuard tools, avoiding the WireGuard meta package on Debian/Ubuntu, and cleaning package caches after installation steps.

Debian/Ubuntu installers detect unavailable `*-backports` apt sources. If an expired backports repository on systems such as Debian 11 breaks `apt-get update`, WarpPool backs up the source file, disables the backports entry, and retries automatically.

### CPU Architecture

| Architecture | Status | WARP |
| --- | --- | --- |
| amd64 | Supported | Supported |
| arm64 | Supported | Supported |

---

## Requirements

Main server:

- Root permission for the one-line installer
- WireGuard tools for `warppool wg up` (installed automatically by the official installer)
- sing-box installed by the one-line installer or provided manually

Exit node:

- Root SSH access
- `/dev/net/tun`
- IPv4 or IPv6 connectivity. IPv6-only exit nodes can be used with `direct` mode; WARP mode depends on the node OS and Cloudflare WARP availability.
- `apt` or `apk` package manager depending on OS

---

## Installation

One-line installation:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash
```

Or use `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash
```

The installer will:

1. Ask for the interactive language: Simplified Chinese or English.
2. Detect OS and CPU architecture.
3. Install base dependencies.
4. Download and install the matching WarpPool release package.
5. Install sing-box.
6. Create systemd services.

The selected language is saved to the WarpPool config. Later interactive commands such as `warppool deploy`, `warppool deploy-token`, and `warppool uninstall` use the same language.

After installation, `wpl` is also available as a short alias for `warppool`, for example `wpl node list` and `wpl ping nat01`. If `/usr/local/bin/wpl` is already occupied by another program, the installer keeps the existing file and only installs `warppool`.

Non-interactive installation:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash -s -- port=8080 --yes
```

Install a specific version:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash -s -- version=v0.1.1
```

---

## Quick Start: Push Deployment with Direct Mode

After installation, deploy an exit node:

```bash
warppool deploy
```

The command asks for node name, exit mode, proxy protocol, local proxy port, SSH host, SSH port, SSH user, the node-side WireGuard listen port, and the public WireGuard endpoint used by the main server. Menu-style fields can be selected with numbers.

The local proxy port must be entered by the user. WarpPool checks for duplicate ports in the config and also checks whether the port is currently occupied on the main server. SSH host has no default value; enter the real reachable IP or domain.

WireGuard ports are split into two values:

- `wg-listen-port`: the WireGuard listen port on the exit node. Default: `51820`.
- `wg-endpoint-port`: the public port used by the main server to connect to the exit node. On NAT VPS nodes, this is often different from the node-side listen port.

Push mode asks for the SSH port, the node-side WireGuard listen port, and the public WireGuard mapped port. NAT nodes commonly use non-standard SSH and UDP mapped ports, so enter the real forwarded ports from your provider.

Push deployment uses a shared exit-node WireGuard layout by default. The exit node keeps one remote WireGuard device named `wpshared`; when another main server deploys to the same exit node, WarpPool appends a new peer instead of overwriting existing peers. This allows, for example, a Hong Kong main server and a US main server to use the same small NAT exit node.

Notes for shared Push nodes:

- Use the same node-side WireGuard listen port / public endpoint port for all main servers.
- Each main server still chooses its own local proxy ports.
- WARP is installed and run once on the exit node; multiple main servers share that WARP runtime.
- Legacy one-main-server WireGuard configs are not converted automatically. If the node already has old `/etc/wireguard/wp*.conf` configs, clean it with `wpl-node-uninstall` or use a fresh node before shared deployment.

IPv6-only exit nodes are supported for `direct` mode when the main server can reach the node over IPv6. Enter bare IPv6 addresses in interactive fields:

```text
SSH host/IP: 2001:db8::10
WireGuard public endpoint host/IP: 2001:db8::10
WireGuard public endpoint port: 51820
```

WarpPool automatically writes the WireGuard endpoint as `[2001:db8::10]:51820` and adds an IPv6 ULA address pair to the tunnel. The exit node enables IPv6 forwarding and `ip6tables` MASQUERADE for direct IPv6 egress. If the main server registration listener itself uses a literal IPv6 address, generated URLs use `http://[IPv6]:port`; using an AAAA domain is still recommended for easier operation.

By default, SSH host key verification is enabled. During interactive deployment, WarpPool asks whether to skip SSH HostKey verification if the default `known_hosts` file does not exist or the target host key is not yet trusted by `known_hosts`. For non-interactive deployment or temporary tests, pass:

```bash
warppool deploy \
  --name nat01 \
  --exit-mode direct \
  --port 10133 \
  --ssh-host 203.0.113.10 \
  --ssh-user root \
  --wg-listen-port 51820 \
  --wg-endpoint-port 30021 \
  --insecure-skip-host-key-check
```

Deployment starts the local proxy service automatically. To start it manually:

```bash
warppool node start nat01
```

Test the proxy:

```bash
curl -x socks5h://127.0.0.1:10133 https://api.ipify.org
```

---

## WARP Mode

Deploy a WARP exit node:

```bash
warppool deploy \
  --name warp01 \
  --exit-mode warp \
  --proxy mixed \
  --port 10134 \
  --ssh-host 203.0.113.11 \
  --ssh-user root \
  --wg-listen-port 51821
```

On Ubuntu/Debian, the installer uses the official Cloudflare WARP client and runs:

```bash
warp-cli --accept-tos registration new
warp-cli --accept-tos mode proxy
warp-cli --accept-tos connect
```

Verification requires:

```text
warp=on
```

from:

```bash
curl --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

Current limitation: WARP forwarding is TCP-first. UDP and IPv6 are not promised as complete yet.

On Ubuntu/Debian, WARP forwarding first reuses the official Cloudflare WARP local SOCKS port `127.0.0.1:40000`. If the port is not ready immediately, the helper waits and retries. The forwarding component prefers repository `redsocks` and only falls back to sing-box when `redsocks` is unavailable. This lets most IPv6-only Debian/Ubuntu nodes complete WARP forwarding without querying the GitHub API.

On Alpine, WARP mode uses:

```text
wgcf generated WARP WireGuard profile
  -> sing-box embedded WireGuard endpoint
  -> endpoint probing: IPv6 first, IPv4 fallback, domain fallback
```

For sing-box on Alpine, WarpPool uses this priority:

```text
1. Existing runnable sing-box
2. apk update && apk add --no-cache sing-box
3. GitHub musl sing-box package fallback
```

After installation, WarpPool checks that sing-box can load the generated WARP config. If the Alpine repository package is too old or incompatible, WarpPool automatically falls back to the GitHub musl build.

The installer verifies WARP by checking `warp=on`. If all endpoint candidates fail, it reports the tried path and asks you to check IPv6 connectivity, UDP 2408 outbound access, DNS, or provider WARP restrictions.

WARP mode is optimized for 1 GB-class small disk nodes. WarpPool installs WARP-specific tools only when WARP mode is selected, uses `--no-install-recommends` where possible, cleans package caches after each step, and warns instead of blocking when disk space is below the recommended threshold but above the hard minimum.

---

## Dual Mode

`dual` mode lets one exit node expose both direct and WARP local proxy ports:

```text
127.0.0.1:<direct-port> -> WireGuard direct client address -> node's own network
127.0.0.1:<warp-port>   -> WireGuard WARP client address   -> node WARP
```

Push deployment example:

```bash
warppool deploy \
  --name nat01 \
  --exit-mode dual \
  --proxy mixed \
  --port 10133 \
  --warp-port 10134 \
  --ssh-host 203.0.113.10 \
  --ssh-user root \
  --wg-listen-port 51820 \
  --wg-endpoint-port 30021
```

In interactive deployment, selecting `dual/direct+warp` asks for:

- direct local proxy port
- WARP local proxy port

Both ports are checked for availability. They must be different and must not conflict with existing nodes or unused Deploy Tokens.

Test:

```bash
curl -x socks5h://127.0.0.1:10133 https://api.ipify.org # direct egress
curl -x socks5h://127.0.0.1:10134 https://api.ipify.org # WARP egress
```

Notes:

- `dual` uses the same remote WireGuard listen port, so NAT VPS users do not need a second UDP mapping.
- The exit node routes by WireGuard client source address: the direct address goes to the node network, and the WARP address goes to Cloudflare WARP.
- In shared Push deployment, each main server receives its own direct/WARP WireGuard client addresses, while the exit node still uses one shared WireGuard device and one WARP runtime.
- IPv6-only exit nodes can use `dual`; enter the node's bare IPv6 address when the main server connects to the node. The direct port exits through the node's IPv6 network, while the WARP port exits through Cloudflare WARP.
- `warppool ping <node>` checks both local proxy ports in dual mode.
- Existing single-mode nodes cannot become dual by changing local config only. Redeploy the node, or later use the configuration refresh flow to push dual WireGuard metadata.

---

## Pull Deployment

Recommended flow: run `warppool deploy-token` on the main server first, then copy the generated one-line install command to the exit node. This makes the main server the source of truth for node name, exit mode, local proxy protocol, and local proxy port. The exit node only provides node-side WireGuard/NAT endpoint information. In `dual` mode, the main server asks for both direct and WARP local proxy ports.

If you run the node installer directly on the exit node:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash
```

The script enters a manual setup menu:

1. Enter the main server IP/domain. Press Enter to install node dependencies only.
2. If a main server address is entered, enter the registration port. IPv4/IPv6 literals default to `8080`; domains default to `80`.
3. Enter a Deploy Token if auto registration is needed.
4. For auto registration, enter the node-side WireGuard listen port and the public UDP port used by the main server.

For IPv6-only exit nodes, manually enter the node's public IPv6 when asked for the WireGuard public endpoint. Do not include brackets in the prompt; the installer and server format the endpoint automatically.

If the main server IP or Deploy Token is left empty, the script only installs node dependencies. It will not write WireGuard config and will not create a node record on the main server. You can later run `warppool deploy-token` on the main server and execute the generated one-line command on the node.

For dependency-only installation, pass the exit mode to decide whether WARP should be installed:

```bash
# direct mode installs WireGuard and base dependencies only
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- mode=direct

# WARP mode installs the WARP runtime for the node OS
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- mode=warp
```

For auto registration, normally use the command printed by `warppool deploy-token`:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- token=<token> server=http://<main-server-ip>:8080
```

If the main server is reached by literal IPv6, use bracketed URL syntax:

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- token=<token> server=http://[2001:db8::1]:8080
```

The node first reads the exit mode stored in the Deploy Token from the main server, then decides whether WARP should be installed.

---

## Deploy Token

The one-line installer configures the registration listener port. Start the listener only when you need Deploy Token registration:

```bash
warppool listen start
```

Generate token command:

```bash
warppool deploy-token
```

The command asks for node name, exit mode, proxy protocol, and local proxy port. In `dual` mode, it also asks for the WARP local proxy port. It then prints the Deploy Token plus a one-line node installation command. The exit node uses that command to request WireGuard config, start WireGuard, and complete registration. After registration, the main server starts the local proxy service automatically.

To avoid duplicate configuration, Deploy Token uses these sources of truth:

- Main server: node name, exit mode, proxy protocol, local proxy port; in dual mode, also the WARP local proxy port.
- Exit node: node-side WireGuard listen port, auto-detected or manually entered public endpoint, and NAT-mapped public UDP port. For IPv6-only nodes, enter the public IPv6 as the endpoint host/IP.

For NAT VPS nodes where the public UDP mapping differs from the node-side WireGuard listen port, run the generated install command on the exit node and enter the provider-mapped public UDP port when prompted.

---

## Commands

### Node

```bash
warppool node list # List nodes
warppool node show nat01 # Show node nat01 details and runtime status
warppool node start nat01 # Start local proxy service for nat01 and enable autostart
warppool node stop nat01 # Stop local proxy service
warppool node status nat01 # Show node nat01 runtime status
warppool node mode nat01 warp # Switch nat01 to WARP egress; auto-detect and install/reuse WARP
warppool node mode nat01 direct # Switch nat01 back to direct egress
warppool deploy --exit-mode dual # Deploy a new node with both direct and WARP ports
warppool remove nat01 # Remove nat01, confirm first, refresh/stop local proxy, and clean local WG client config
warppool node remove nat01 -y # Remove nat01 without confirmation
warppool node remove nat01 --clean-wg=false # Remove node and refresh local proxy, but keep local WG client config
```

Short alias examples:

```bash
wpl node list
wpl node show nat01
wpl ping nat01
wpl upgrade --yes
```

`warppool node remove` / `wpl node remove` prints the selected node details first and asks for `y/N` confirmation, defaulting to `N`. After confirmation, it removes the node from config and rewrites/restarts the local proxy. If no nodes remain, it stops the local proxy and removes the stale sing-box config so the local proxy port is released.

`warppool node mode` defaults to Pull mode and prints a command to run on the exit node. The exit node detects WARP automatically: reuse it when already installed, otherwise install it. Advanced options:

```bash
warppool node mode nat01 warp --warp-install reuse # Reuse existing WARP only; fail if missing
warppool node mode nat01 warp --warp-install reinstall # Force reinstall WARP
warppool node mode nat01 direct --remove-warp # Remove WARP after switching back to direct
warppool node mode nat01 warp --method ssh # Switch automatically over SSH
```

Pull mode first reads `/etc/warppool-node/state.json` on the exit node, so normally you do not need to enter the main server address again. For old nodes without this state file, the script prompts for the server address, or you can use the fallback command printed by the main server with `server=http://<main-server-ip>:<port>`.

SSH mode reuses the non-sensitive SSH connection information saved during Push deployment, including SSH host, port, user, SSH key path, known_hosts path, and host-key-check preference. SSH passwords are never saved. During interactive mode switching, saved SSH host, port, and user are shown as defaults; press Enter to reuse them or type new values to override.

### WireGuard

```bash
warppool wg config nat01 # Print local WireGuard client config for nat01
warppool wg up nat01 # Start system WireGuard client for diagnostics
warppool wg status nat01 # Show local WireGuard status for nat01
warppool wg down nat01 # Stop local WireGuard client for nat01
```

### Proxy

```bash
warppool proxy config -o sing-box.json # Generate sing-box config
warppool proxy start # Start local proxy as a temporary process
warppool proxy service install # Create local proxy systemd service
warppool proxy service enable # Start local proxy for all nodes and enable autostart
warppool proxy status # Show local proxy status
warppool proxy stop # Stop the temporary local proxy process
```

### Clash Export

```bash
warppool export clash -o clash.yaml # Export Clash-compatible config
```

### Diagnostics

```bash
warppool version # Show version information
warppool doctor # Check local runtime and port status
warppool ping nat01 # Test node latency target, direct HTTP latency, and proxy egress IP/latency; dual mode checks both proxy ports
warppool upgrade --yes # Upgrade binary and bundled installer assets
warppool speedtest --proxy http://127.0.0.1:10133 # Run a simple speed test through a proxy
```

On an exit node, WARP backend probing can be run manually for diagnostics:

```bash
bash /path/to/warp_forward.sh action=probe device=wpnat01 client_addr=10.200.0.2/32 server_addr=10.200.0.1/32 backend=wireguard
```

`warppool ping` uses multiple fallback HTTP check URLs by default:

```text
https://api.ipify.org
https://icanhazip.com
https://ifconfig.me/ip
```

Custom URLs can be supplied as a comma-separated list:

```bash
warppool ping nat01 --url https://api.ipify.org,https://icanhazip.com
```

Note: `speedtest` is safest with HTTP proxy URLs. Full SOCKS proxy handling is planned.

### Uninstall

```bash
warppool uninstall --force # Uninstall WarpPool program and runtime state from the main server
```

`uninstall` is only for uninstalling the main server program. It asks whether to remove local WireGuard client configs and whether to remove local proxy/listener services plus runtime state. To remove a node, use `warppool remove <name>`.

### Remote Node Uninstall

Push deployment installs a helper command on the exit node:

```bash
warppool-node-uninstall
```

It also installs a shorter alias when not occupied by another command:

```bash
wpl-node-uninstall
```

Common usage on the exit node:

```bash
wpl-node-uninstall device=wpshared # Remove the shared Push WireGuard device
wpl-node-uninstall device=wpnat01 # Remove one WarpPool WireGuard device
wpl-node-uninstall all=true # Remove all WarpPool WireGuard devices on this node
wpl-node-uninstall all=true remove_warp=true # Also remove/clean WARP runtime
wpl-node-uninstall all=true remove_wireguard=true # Also remove WireGuard packages
```

If exactly one `/etc/wireguard/wp*.conf` file exists, `wpl-node-uninstall` can run without arguments. If multiple WarpPool devices exist, pass `device=<wg-device>` or `all=true`. The long command `warppool-node-uninstall` remains available for compatibility.

For Pull-only nodes where the helper was not installed, run:

```bash
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/node_uninstall.sh | sudo bash -s -- all=true
```

---

## Exit Node: Extra Clients

Besides main servers, an exit node can accept clients that only need a WireGuard client config and do not run WarpPool: a local PC, a phone, a second admin box.

Which tool manages them depends on the layout the node was deployed with:

| Node layout | WireGuard device | Managed with |
| --- | --- | --- |
| Shared (SSH Push deployment) | `wpshared` | `shared_node.sh` |
| Exclusive (Pull / Deploy Token) | `wp<name>` | `wpls` |

---

### Exclusive layout: `wpls`

The installer puts a connection manager at `/usr/local/bin/wpls`. It is the supported way to add, inspect, change and remove clients on an exclusive-layout node.

```bash
wpls list
```

| Command | Description |
| --- | --- |
| `wpls init` | Set up a standalone exit node that uses no main server at all |
| `wpls list` | Show every connection |
| `wpls list add` | Register a main server (you supply its WireGuard public key) |
| `wpls list wgadd` | Register a standalone WireGuard device |
| `wpls list remove [index]` | Delete a connection and its WireGuard config |
| `wpls list edit` | Change a connection: name, public key, or address |
| `wpls-update` | Update the node tooling and self-check every installed file |
| `wpls-update --check` | Self-check only, without downloading anything |
| `wpls help` | Full reference |

`wpls init` builds the server side from nothing, for a node that should serve as an exit without ever being registered to a main server:

```bash
# install dependencies first; no token is needed for a standalone node
bash install.sh mode=dual
wpls init
wpls list wgadd
```

It generates the server keypair, writes `/etc/wireguard/<device>.conf`, starts and enables the interface, and installs a systemd drop-in that retries a failed boot start.

The list shows index, name, type, port, address and live status:

```text
序号  名称           类型    端口    地址             状态
1     office-pc      wg      31496   10.200.0.5       在线
2     <未登记>       未登记  51820   10.200.0.2       在线
```

Type:

- `wpl` — a main server registered through `wpls list add`
- `wg` — a standalone device registered through `wpls list wgadd`
- `未登记` — present in the WireGuard config but never registered through `wpls`; this is how a main server that deployed itself appears

Port is the public port a `wg` client dials, or the node's local listen port for everything else.

Status is read live from the interface:

| Status | Meaning |
| --- | --- |
| `在线` | Handshake within the last 3 minutes |
| `离线` | Has handshaked before, but not recently |
| `从未握手` | No handshake ever — the client has not connected yet |
| `不在接口上` | In the config file but missing from the running interface |

`wpls list wgadd` walks through the setup, generating the keypair on the node if you leave the public key blank, and writes an import-ready config to `/root/warppool-clients/`. Leave the port prompts at their defaults unless your NAT mapping differs.

Safety properties, which also apply to `shared_node.sh`:

- Every change is validated with `wg-quick strip` before it touches the config file
- Changes are applied with `wg syncconf`, so the interface is never brought down and other peers keep their sessions
- If the apply fails, the previous config is restored automatically
- `remove` and `edit` act only on connections registered through `wpls`. The main server owns its own peer — remove that one with `warppool node remove` on the main server
- `edit address` is implemented as a remove followed by a re-add, so that tunnel drops for a few seconds
- `wpls` refuses to touch `wpshared`; use `shared_node.sh` on a shared node

---

### Shared layout: `shared_node.sh`

Run this on the exit node:

```bash
# The script is usually already uploaded by Push deployment
ls -l /tmp/warppool-install/shared_node.sh

# Otherwise download it
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/shared_node.sh -o /root/shared_node.sh
```

#### List every peer

```bash
bash /root/shared_node.sh action=list
```

#### Add a client

```bash
bash /root/shared_node.sh action=add-client \
  name=pc \
  mode=direct \
  endpoint=<exit-node-public-ip>:<nat-mapped-public-udp-port>
```

One command does four things:

1. Generates the client keypair (supply `client_private_key=<key>` to keep the private key off the exit node)
2. Appends the peer and hot-reloads the WireGuard interface, leaving existing main-server tunnels untouched
3. Registers WARP forwarding automatically for `warp` / `dual` mode
4. Renders a complete, ready-to-import WireGuard client config

Configs are written to `/root/warppool-clients/<name>.conf` and also printed to stdout. Use `config_dir=` to change the directory and `print_config=false` to only write files.

`endpoint=` is the address the **client** dials. On a NAT VPS the auto-detected public IP is correct, but the mapped port cannot be discovered — check your provider's NAT panel and pass the public port, not the node's local `listen_port`.

| Option | Description |
| --- | --- |
| `mode=` | `direct` for the node's own egress IP, `warp` for WARP egress, `dual` for both |
| `allowed_ips=` | Defaults to `0.0.0.0/0, ::/0` (full tunnel); use `10.200.0.0/24` for split tunnel |
| `dns=` | Defaults to `1.1.1.1, 8.8.8.8` |
| `config_dir=` | Output directory, defaults to `/root/warppool-clients` |
| `register_warp=` | Set `false` to skip WARP forwarding registration |

`mode=dual` writes two configs and only one may be active at a time:

```text
pc.conf       direct egress, UDP works
pc-warp.conf  WARP egress, TCP only
```

#### WARP mode limitation

WARP forwarding only redirects **TCP** (`iptables -t nat PREROUTING ... -p tcp -j REDIRECT`). In `warp` mode a client's UDP is neither redirected to WARP nor NATed, so it is dropped.

Use `direct` when you need UDP, or use `dual` to get both tunnels and pick per traffic type.

#### Remove a client

```bash
bash /root/shared_node.sh action=remove target=pc
bash /root/shared_node.sh action=remove target=<public-key>   # target by public key instead
```

Removal re-renders the config, hot-reloads with `wg syncconf`, purges that IP's MASQUERADE rules, and unregisters the WARP forwarding client. Other peers keep their tunnels.

---

## Configuration

Default config path:

| OS | Path |
| --- | --- |
| Linux | `/etc/warppool/config.json` |

`warppool config init` creates this JSON config file with default values. It stores listener settings, default proxy settings, node metadata, deploy tokens, and WireGuard client private keys. The one-line installer runs it automatically when the config file does not exist.

Keep the config file private.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## Release Process

Release builds only run when tags are pushed. Normal branch pushes do not create GitHub Releases.

Published packages:

- `warppool-linux-amd64.tar.gz`
- `warppool-linux-arm64.tar.gz`

`VERSION` contains one line:

```text
0.1.1
```

From the `developer` branch:

```powershell
.\scripts\release.ps1 patch
git push origin developer v0.1.1
```

The script checks the working tree, updates `VERSION`, creates a Chinese commit, and creates an annotated tag. GitHub Actions verifies that the tag equals `v<VERSION>`.

---

## Security Notes

- Keep `/etc/warppool/config.json` private.
- Do not commit SSH passwords, WireGuard private keys, or local runtime files.
- Prefer SSH keys or interactive password input.
- `--insecure-skip-host-key-check` is for temporary testing only.
- Local proxy ports bind to `127.0.0.1` by default.

---

## Current Limitations

- No Web UI.
- No database.
- No multi-user permission model.
- No remote Agent.
- Shared multi-main-server exit-node reuse is currently implemented for SSH Push deployment. Pull / Deploy Token keep the original single-registration flow for now.
- Extra client access depends on the node layout: `wpls` manages exclusive `wp<name>` nodes, `shared_node.sh action=add-client` manages shared `wpshared` nodes. Neither tool touches the other layout.
- `wpls list remove` and `wpls list edit` only act on connections registered through `wpls`. Peers that a main server deployed for itself are shown as `未登记` and must be removed from the main server.
- WARP forwarding redirects TCP only. A `warp`-mode client's UDP is dropped; use `direct`, or `dual` to get both.
- `upgrade` updates the main binary and bundled installer assets. Existing config is preserved.
