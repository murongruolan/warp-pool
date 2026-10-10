# WarpPool

基于 WireGuard 的多出口代理管理工具，面向小型 VPS / NAT VPS 节点。

[English](README.md) | [简体中文](README_CN.md)

## 目录

- [项目概述](#项目概述)
- [核心功能](#核心功能)
- [架构](#架构)
- [支持平台](#支持平台)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始：Push 部署 direct 节点](#快速开始push-部署-direct-节点)
- [WARP 模式](#warp-模式)
- [Dual 双模式](#dual-双模式)
- [Pull 部署](#pull-部署)
- [Deploy Token](#deploy-token)
- [常用命令](#常用命令)
- [出口节点：接入额外客户端](#出口节点接入额外客户端)
- [配置](#配置)
- [更新日志](#更新日志)
- [安全说明](#安全说明)
- [当前限制](#当前限制)

---

## 项目概述

WarpPool 让一台主服务器统一管理多台出口节点。应用程序连接主服务器上的本地代理端口，WarpPool 通过 WireGuard 隧道把流量送到不同出口节点。

出口模式：

- `direct`：流量直接从出口节点本机网络出去。
- `warp`：流量通过出口节点上的 Cloudflare WARP 出去。
- `dual`：同一个出口节点同时提供 direct 和 WARP 两个本地代理端口。

典型流量路径：

```text
应用程序
  -> 127.0.0.1:<本地代理端口>
  -> 主服务器 sing-box mixed/http/socks 入站
  -> WireGuard 隧道
  -> 出口节点
  -> direct 本机网络 或 Cloudflare WARP
  -> 目标网站
```

---

## 核心功能

- 自动生成和部署 WireGuard 隧道配置
- 通过 SSH Push 部署出口节点
- Push 部署默认支持共享出口节点：多台主服务器可复用同一个出口节点，互不覆盖
- 可选 Cloudflare WARP 出口
- 支持 `dual` 双模式：一个节点同时提供直连和 WARP 两个出口端口
- 用户自定义本地代理端口
- 支持 `socks5`、`http`、`mixed` 本地代理模式
- 生成 sing-box 配置并管理进程
- 导出 Clash 兼容 YAML
- 本地诊断命令：version、doctor、ping、speedtest、show

---

## 架构

```text
主服务器
  - WarpPool CLI
  - JSON 配置
  - WireGuard 客户端
  - sing-box 本地代理
  - Clash 导出

出口节点
  - WireGuard 服务端
  - IPv4 转发 / NAT
  - 可选 Cloudflare WARP 出口运行时
  - 不运行 WarpPool Agent
```

---

## 支持平台

### 主服务器

| 平台 | 状态 |
| --- | --- |
| Linux amd64 | 支持 |
| Linux arm64 | 支持 |

### 出口节点

| 系统 | 状态 |
| --- | --- |
| Ubuntu 20.04+ | 支持 |
| Debian 11+ | 支持 |
| Alpine 3.20+ | 支持 |

WARP 模式支持 Ubuntu/Debian 和 Alpine。Ubuntu/Debian 优先使用 Cloudflare 官方 WARP 客户端，并优先通过系统仓库 `redsocks` 做 WARP SOCKS 透明转发，减少纯 IPv6 小鸡对 GitHub API 的依赖；`redsocks` 不可用时再回退到 sing-box。Alpine 使用 `wgcf` 生成 WARP WireGuard 配置，并通过 sing-box 内置 WireGuard endpoint 出口。Alpine 上会先执行 `apk update`，并优先从 Alpine 软件仓库安装 `sing-box`；如果仓库包不存在、无法运行，或无法加载 WarpPool 生成的 WARP 配置，则自动回退到 GitHub musl 版本。

建议硬盘大小 1G 左右。安装脚本已经针对小硬盘场景优化：Debian/Ubuntu 上只安装必要的 WireGuard tools，避免安装 WireGuard 元包，并在安装步骤后清理软件包缓存。

Debian/Ubuntu 安装流程会检测失效的 `*-backports` apt 源。遇到 Debian 11 等系统里过期的 backports 源导致 `apt-get update` 失败时，脚本会先备份对应源文件，再禁用 backports 条目并自动重试。

### CPU 架构

| 架构 | 状态 | WARP |
| --- | --- | --- |
| amd64 | 支持 | 支持 |
| arm64 | 支持 | 支持 |

---

## 环境要求

主服务器：

- 一键安装脚本需要 root 权限
- 执行 `warppool wg up` 需要 WireGuard tools(使用脚本会默认安装)
- sing-box 可由一键安装脚本安装，也可以用户手动提供

出口节点：

- root SSH 权限
- `/dev/net/tun`
- IPv4 或 IPv6 网络。纯 IPv6 出口节点可用于 `direct` 模式；WARP 模式依赖节点系统和 Cloudflare WARP 可用性。
- 根据系统使用 `apt` 或 `apk` 安装依赖

---

## 安装
一行命令安装
```bash
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash

# 或使用wget
wget -qO- ···
```
安装脚本会：

1. 询问交互语言：简体中文或 English。
2. 检测系统和 CPU 架构。
3. 安装基础依赖。
4. 下载并安装匹配的 WarpPool Release 包。
5. 安装 sing-box。
6. 创建 systemd 服务。

安装时选择的语言会写入 WarpPool 配置。后续 `warppool deploy`、`warppool deploy-token`、`warppool uninstall` 等交互命令会使用同一种语言。

安装完成后，也可以使用短命令 `wpl`，它等效于 `warppool`，例如 `wpl node list`、`wpl ping nat01`。如果 `/usr/local/bin/wpl` 已经被其他程序占用，安装脚本不会覆盖，只会保留 `warppool` 主命令可用。


非交互安装

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash -s -- port=8080 --yes

# 安装指定版本：
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install_server.sh | sudo bash -s -- version=v0.1.1
```
---

## 快速开始：Push 部署 direct 节点

安装完成后，部署出口节点：

```bash
warppool deploy
```

WireGuard 端口分两类：

- `wg-listen-port`：出口节点本机 WireGuard 监听端口，默认 `51820`。
- `wg-endpoint-port`：主服务器连接出口节点时使用的公网端口。NAT VPS 做端口转发时，这个端口通常和节点本机监听端口不同。

Push 部署默认使用共享出口节点布局。出口节点会维护一个远端 WireGuard 设备 `wpshared`；另一台主服务器再次部署到同一个出口节点时，WarpPool 会追加新的 peer，而不是覆盖已有配置。这样香港主服务器、美国主服务器等多台主服务器可以共同使用同一台小 NAT 出口节点。

共享 Push 节点说明：

- 所有主服务器使用同一个出口节点 WireGuard 监听端口 / 公网映射端口。
- 每台主服务器仍然独立选择自己的本地代理端口。
- WARP 在出口节点上只安装和运行一份，多台主服务器共同复用。
- 旧版“一台主服务器独占一个远端 WG 配置”的节点不会自动转换。如果出口节点上已有旧 `/etc/wireguard/wp*.conf` 配置，请先用 `wpl-node-uninstall` 清理，或使用新节点部署。

纯 IPv6 出口节点支持 `direct` 模式，前提是主服务器能通过 IPv6 连接该节点。交互式部署时 IPv6 地址直接填裸地址：

```text
SSH 主机/IP: 2001:db8::10
WireGuard 公网端点主机/IP: 2001:db8::10
WireGuard 公网端点端口: 51820
```

WarpPool 会自动把 WireGuard endpoint 写成 `[2001:db8::10]:51820`，并为隧道增加一组 IPv6 ULA 地址。出口节点会开启 IPv6 forwarding，并通过 `ip6tables` MASQUERADE 实现 direct IPv6 出口。如果主服务器注册监听也使用 IPv6 字面量，生成的 URL 会使用 `http://[IPv6]:端口` 格式；实际使用时更推荐绑定 AAAA 域名。

默认开启 SSH HostKey 校验。交互部署时，如果默认 `known_hosts` 文件不存在，或目标主机 HostKey 尚未被 `known_hosts` 信任，WarpPool 会询问本次部署是否跳过 SSH HostKey 校验。非交互部署或临时测试时可以显式传入：

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

部署成功后会自动启动本地代理服务。也可以手动启动：

```bash
warppool node start nat01
```

测试代理：

```bash
curl -x socks5h://127.0.0.1:10133 https://api.ipify.org
```

---

## WARP 模式

部署 WARP 出口节点：

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

验证命令：

```bash
curl --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

当前限制：WARP 转发以 TCP 为主，暂不承诺 UDP / IPv6 完整支持。

Ubuntu/Debian 的 WARP 转发优先复用 Cloudflare 官方 WARP 本地 SOCKS 端口 `127.0.0.1:40000`。如果该端口短暂未就绪，脚本会等待重试；转发组件优先安装系统仓库中的 `redsocks`，只有不可用时才回退到 sing-box。这样纯 IPv6 Debian/Ubuntu 小鸡通常不需要访问 GitHub API 就能完成 WARP 转发安装。

Alpine 的 WARP 模式使用：

```text
wgcf 生成 WARP WireGuard 配置
  -> sing-box 内置 WireGuard endpoint
  -> 端点探测：优先 IPv6，回退 IPv4，最后兜底域名
```

Alpine 上 sing-box 的安装优先级：

```text
1. 已存在且可运行的 sing-box
2. apk update && apk add --no-cache sing-box
3. 回退 GitHub musl 版 sing-box
```

安装后 WarpPool 会检查 sing-box 是否能加载生成的 WARP 配置。如果 Alpine 仓库中的版本过旧或不兼容，会自动回退到 GitHub musl 版本。

安装脚本会通过 `warp=on` 校验 WARP 是否真正可用。如果所有端点都失败，会提示检查 IPv6、UDP 2408 出站、DNS 或服务商是否限制 WARP。

WARP 模式已针对 1G 级别小硬盘节点优化。WarpPool 只会在选择 WARP 模式时安装 WARP 相关工具，尽量使用 `--no-install-recommends`，并在每个安装步骤后清理软件包缓存。硬盘低于推荐空间但高于硬性最低空间时，会提示风险但继续尝试安装。

---

## Dual 双模式

`dual` 模式让同一个出口节点同时提供直连和 WARP 两个本地代理端口：

```text
127.0.0.1:<direct端口> -> WireGuard direct 客户端地址 -> 出口节点本机网络
127.0.0.1:<warp端口>   -> WireGuard WARP 客户端地址   -> 出口节点 WARP
```

Push 部署示例：

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

交互部署时，选择 `dual/direct+warp` 后会分别询问：

- 直连本地代理端口
- WARP 本地代理端口

两个端口会自动做占用检测，不能相同，也不能与已有节点或未使用 Deploy Token 的端口冲突。

测试：

```bash
curl -x socks5h://127.0.0.1:10133 https://api.ipify.org # direct 出口
curl -x socks5h://127.0.0.1:10134 https://api.ipify.org # WARP 出口
```

说明：

- `dual` 模式使用同一个远端 WireGuard 监听端口，不需要额外申请第二个 UDP 转发端口。
- 远端会按 WireGuard 客户端源地址分流：direct 地址走节点本机网络，WARP 地址走 Cloudflare WARP。
- 在共享 Push 部署中，每台主服务器都会拿到自己独立的 direct/WARP WireGuard 客户端地址，但出口节点仍然只使用一个共享 WireGuard 设备和一份 WARP 运行时。
- 纯 IPv6 出口节点可以部署 `dual`，主服务器访问节点时填写裸 IPv6；direct 端口走节点 IPv6 网络，WARP 端口走 Cloudflare WARP。
- `warppool ping <节点>` 在 dual 模式下会分别检测 direct 和 WARP 两个本地代理端口。
- 旧的单模式节点不能只在本地改配置变成 dual，需要重新部署或后续使用配置刷新流程重新下发双通道 WireGuard 配置。

---

## Pull 部署

推荐先在主服务器执行 `warppool deploy-token`，再把输出的一行安装命令复制到出口节点执行。这样节点名称、出口模式、本地代理协议、本地代理端口都由主服务器确定，出口节点只需要填写本机 WireGuard/NAT 端点信息。选择 `dual` 模式时，主服务器会同时询问 direct 和 WARP 两个本地代理端口。

如果直接在出口节点执行安装脚本：

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash
```

脚本会进入手动交互菜单：

1. 询问主服务器 IP/域名，不填将只安装节点依赖。
2. 如果填写了主服务器地址，将询问注册端口。IPv4/IPv6 字面量默认 `8080`，域名默认 `80`。
3. 如需自动注册，需要填写 Deploy Token。
4. 自动注册时会询问本节点 WireGuard 监听端口和主服务器连接本节点的公网 UDP 端口。

纯 IPv6 出口节点建议在询问 WireGuard 公网端点时手动填写节点公网 IPv6，不要带中括号，程序会自动格式化。

如果不填写主服务器 IP/域名 或不填写 Deploy Token，脚本只安装节点依赖，不会写入 WireGuard 配置，也不会在主服务器生成节点记录。后续可以在主服务器执行 `warppool deploy-token`，再把生成的一行命令复制到节点执行。

仅安装节点依赖时可以指定出口模式，用于决定是否安装 WARP：

```bash
# direct 模式，只安装 WireGuard 等基础依赖
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- mode=direct

# WARP 模式，会安装当前节点系统对应的 WARP 运行时
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- mode=warp
```

携带 Deploy Token 自动注册时，通常直接使用 `warppool deploy-token` 输出的命令：

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- token=<token> server=http://<主服务器IP>:8080
```

如果主服务器使用 IPv6 字面量访问，URL 必须带中括号：

```bash
wget -qO- https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/install.sh | sudo bash -s -- token=<token> server=http://[2001:db8::1]:8080
```

这时节点会先从主服务器读取 Deploy Token 中保存的出口模式，再决定是否安装 WARP。

---

## Deploy Token

一键安装脚本会配置注册监听端口。仅在需要 Deploy Token 注册时启动监听：

```bash
warppool listen start
```

生成安装命令：

```bash
warppool deploy-token
```

命令会询问节点名称、出口模式、代理协议、本地代理端口，然后输出 Deploy Token 和一行节点安装命令。选择 `dual` 模式时，会额外询问 WARP 本地代理端口。出口节点执行该命令后，会向主服务器请求 WireGuard 配置、启动 WireGuard，并完成注册。注册完成后主服务器会自动启动本地代理服务。

为避免重复配置，Deploy Token 流程按下面规则决定配置来源：

- 主服务器决定：节点名称、出口模式、代理协议、本地代理端口；dual 模式下还包括 WARP 本地代理端口。
- 出口节点决定：本机 WireGuard 监听端口、自动检测或手动填写的公网端点、NAT 映射后的公网 UDP 端口。纯 IPv6 节点请填写公网 IPv6 作为端点 host/IP。

如果出口节点是 NAT VPS，并且公网 UDP 端口映射和节点本机 WireGuard 监听端口不同，在出口节点执行安装命令后，根据提示填写映射出来的公网 UDP 端口即可。

---

## 常用命令

### 节点相关

```bash
warppool node list # 查看节点列表
warppool node show nat01 # 查看节点nat01信息和运行状态
warppool node start nat01 # 启动节点nat01对应的本地代理服务并设置开机自启
warppool node stop nat01 # 停止本地代理服务
warppool node status nat01 # 查看节点nat01运行状态
warppool node mode nat01 warp # 将节点nat01切换为WARP出口，默认自动检测并安装/复用WARP
warppool node mode nat01 direct # 将节点nat01切换回直连出口
warppool deploy --exit-mode dual # 新部署一个同时提供 direct 和 WARP 端口的节点
warppool remove nat01 # 移除节点nat01，默认会确认、刷新/停止本地代理并清理本地WG客户端配置
warppool node remove nat01 -y # 跳过确认直接移除节点
warppool node remove nat01 --clean-wg=false # 仅移除节点并刷新本地代理，保留本地WG客户端配置
```

短命令示例：

```bash
wpl node list
wpl node show nat01
wpl ping nat01
wpl upgrade --yes
```

`warppool node remove` / `wpl node remove` 会先输出将要移除的节点信息，并要求输入 `y/N` 确认，默认 `N`。确认后会从配置中删除节点、重写并重启本地代理；如果已经没有剩余节点，则停止本地代理并移除旧的 sing-box 配置，从而释放本地代理端口。

`warppool node mode` 默认使用 Pull 方式生成一条需要在出口节点执行的命令。出口节点会自动检测 WARP：已安装则复用，未安装则自动安装。也可以指定：

```bash
warppool node mode nat01 warp --warp-install reuse # 只复用已安装的WARP，未安装则报错
warppool node mode nat01 warp --warp-install reinstall # 强制重装WARP
warppool node mode nat01 direct --remove-warp # 切回直连后同时卸载WARP
warppool node mode nat01 warp --method ssh # 通过SSH自动切换，不需要手动复制命令
```

Pull 切换命令会优先读取出口节点上的 `/etc/warppool-node/state.json`，正常情况下不需要再次填写主服务器地址；旧节点没有该状态文件时，脚本会提示手动填写，或按主服务器输出的备用命令携带 `server=http://<主服务器IP>:<端口>` 执行。

SSH 自动切换会复用 Push 部署时保存的非敏感 SSH 连接信息，包括 SSH 主机、端口、用户、SSH key 路径、known_hosts 路径和 HostKey 校验偏好。SSH 密码不会保存。交互切换时会把已保存的 SSH 主机、端口、用户作为默认值显示，回车沿用，手动输入则覆盖。

### WireGuard相关

```bash
warppool wg config nat01 # 输出节点nat01的本地WireGuard客户端配置
warppool wg up nat01 # 启动节点nat01的系统WireGuard客户端，主要用于诊断
warppool wg status nat01 # 查看节点nat01的本地WireGuard状态
warppool wg down nat01 # 停止节点nat01的本地WireGuard客户端
```

### 代理

```bash
warppool proxy config -o sing-box.json # 生成sing-box配置文件
warppool proxy start # 临时启动本地代理进程
warppool proxy service install # 创建本地代理systemd服务
warppool proxy service enable # 启动全部节点的本地代理并设置开机自启
warppool proxy status # 查看本地代理状态
warppool proxy stop # 停止临时启动的本地代理进程
```

### Clash 导出

```bash
warppool export clash -o clash.yaml # 导出Clash兼容配置
```

### 诊断

```bash
warppool version # 查看版本信息
warppool doctor # 检查本机运行环境和端口状态
warppool ping nat01 # 测试节点延迟检测地址、主服务器直连HTTP延迟、代理出口IP和代理延迟；dual模式会检测两个代理端口
warppool speedtest --proxy http://127.0.0.1:10133 # 通过指定代理进行简易测速
warppool upgrade --yes # 更新主程序二进制和安装脚本资源
```

在出口节点上，可以单独探测 WARP 后端是否可用：

```bash
bash /path/to/warp_forward.sh action=probe device=wpnat01 client_addr=10.200.0.2/32 server_addr=10.200.0.1/32 backend=wireguard
```

`warppool ping` 默认使用多个 HTTP 检测地址兜底：

```text
https://api.ipify.org
https://icanhazip.com
https://ifconfig.me/ip
```

也可以传入逗号分隔的自定义检测地址：

```bash
warppool ping nat01 --url https://api.ipify.org,https://icanhazip.com
```

说明：`speedtest` 当前使用 HTTP proxy URL。完整 SOCKS 代理测速将在后续支持。

### 卸载

```bash
warppool uninstall --force # 卸载主服务器上的WarpPool程序和运行状态
```

`uninstall` 专用于卸载主服务器程序。
移除节点请使用 `warppool remove <name>`。

### 远端出口节点卸载

Push 部署会在出口节点安装一个辅助命令：

```bash
warppool-node-uninstall
```

如果短命令没有被其他程序占用，也会安装：

```bash
wpl-node-uninstall
```

在出口节点上常用：

```bash
wpl-node-uninstall device=wpshared # 卸载共享 Push WireGuard 设备
wpl-node-uninstall device=wpnat01 # 卸载指定WarpPool WireGuard设备
wpl-node-uninstall all=true # 卸载本节点所有WarpPool WireGuard设备
wpl-node-uninstall all=true remove_warp=true # 同时卸载/清理WARP运行时
wpl-node-uninstall all=true remove_wireguard=true # 同时卸载WireGuard软件包
```

如果 `/etc/wireguard/wp*.conf` 只有一个配置文件，可以直接执行 `wpl-node-uninstall`。如果存在多个 WarpPool 设备，需要传 `device=<wg-device>` 或 `all=true`。长命令 `warppool-node-uninstall` 仍然保留，用于兼容。

如果是 Pull 安装且节点上没有该辅助命令，可以直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/node_uninstall.sh | sudo bash -s -- all=true
```

---

## 出口节点：接入额外客户端

出口节点除了主服务器，还可以接入本地电脑、手机等**不安装 WarpPool** 的客户端：它们只需要一条 WireGuard 客户端配置。

用哪个工具取决于节点当初的部署方式：

| 节点布局 | WireGuard 设备 | 使用工具 |
| --- | --- | --- |
| 共享布局（SSH Push 部署） | `wpshared` | `shared_node.sh` |
| 独占布局（Pull / Deploy Token 部署） | `wp<名字>` | `wpls` |

---

### 独占布局：`wpls`

安装脚本会装一个常驻命令到 `/usr/local/bin/wpls`，这是独占布局下管理客户端的标准方式。

```bash
wpls list
```

| 命令 | 说明 |
| --- | --- |
| `wpls init` | 初始化一个完全不用主服务器的独立出口节点 |
| `wpls list` | 查看本地连接列表 |
| `wpls list add` | 添加一台主服务器（由你提供它的 WireGuard 公钥） |
| `wpls list wgadd` | 添加一台独立 WireGuard 设备 |
| `wpls list remove [序号]` | 删除指定连接及其 WireGuard 配置 |
| `wpls list edit` | 修改连接：名称 / 公钥 / 地址 |
| `wpls-update` | 更新节点工具集，并逐项自检已安装文件 |
| `wpls-update --check` | 只自检，不下载 |
| `wpls help` | 完整帮助 |

`wpls init` 从零建出服务端，适用于「只当出口用、不接入任何主服务器」的节点：

```bash
# 先装依赖；独立节点不需要 token
bash install.sh mode=dual
wpls init
wpls list wgadd
```

它会生成服务端密钥对、写 `/etc/wireguard/<设备名>.conf`、启动并启用接口，同时装上开机自愈的 systemd drop-in。

列表会显示序号、名称、类型、端口、地址和实时状态：

```text
序号  名称           类型    端口    地址             状态
1     office-pc      wg      31496   10.200.0.5       在线
2     <未登记>       未登记  51820   10.200.0.2       在线
```

类型含义：

- `wpl` —— 通过 `wpls list add` 登记的主服务器
- `wg` —— 通过 `wpls list wgadd` 登记的独立设备
- `未登记` —— 存在于 WireGuard 配置里、但没经过 `wpls` 登记；主服务器自行部署的 peer 就显示成这样

端口一栏，`wg` 类型显示客户端实际拨入的公网端口，其余显示节点本机监听端口。

状态是实时从接口读取的：

| 状态 | 含义 |
| --- | --- |
| `在线` | 最近 3 分钟内有握手 |
| `离线` | 曾经握过手，但已经不活跃 |
| `从未握手` | 一次都没握手过——客户端还没连上 |
| `不在接口上` | 配置里有，但运行中的接口上没有这个 peer |

`wpls list wgadd` 会走一遍交互向导。公钥留空则由节点生成密钥对，并把可直接导入的配置写到 `/root/warppool-clients/`。端口提示直接用默认值即可，除非你的 NAT 映射不同。

以下安全性质对 `shared_node.sh` 同样适用：

- 每次改动都先用 `wg-quick strip` 校验，通过后才写配置文件
- 用 `wg syncconf` 热更新，接口不重启，其他 peer 的会话不受影响
- 应用失败会自动还原上一份配置
- `remove` 和 `edit` 只作用于经过 `wpls` 登记的连接。主服务器的 peer 归它自己管，请在主服务器上执行 `warppool node remove`
- `edit` 改地址是"移除 + 重建"两步，该隧道会中断几秒
- `wpls` 拒绝操作 `wpshared`，共享节点请改用 `shared_node.sh`

---

### 共享布局：`shared_node.sh`

在出口节点上直接执行：

```bash
# 查看脚本是否在节点上
ls -l /tmp/warppool-install/shared_node.sh

# 没有就下载
curl -fsSL https://raw.githubusercontent.com/murongruolan/warp-pool/main/assets/shared_node.sh -o /root/shared_node.sh
```

#### 列出所有 peer

```bash
bash /root/shared_node.sh action=list
```

#### 新增一个客户端

```bash
bash /root/shared_node.sh action=add-client \
  name=pc \
  mode=direct \
  endpoint=<出口节点公网IP>:<NAT映射后的公网UDP端口>
```

命令会完成四件事：

1. 生成客户端密钥对（也可以用 `client_private_key=<key>` 自带私钥，公私钥分离更安全）
2. 追加 peer 并热更新 WireGuard 接口，不影响已有主服务器隧道
3. `warp` / `dual` 模式自动注册 WARP 转发
4. 生成可直接导入的完整客户端配置

输出配置默认写到 `/root/warppool-clients/<name>.conf`，也直接打印到终端。用 `config_dir=` 换目录，用 `print_config=false` 只写文件不打印。

`endpoint=` 是**客户端要连的地址**。NAT VPS 上自动探测到的公网 IP 是正确的，但**映射端口探测不到**——请查服务商的 NAT 面板，填公网端口，而不是节点本机的 `listen_port`。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `mode=` | `direct` 走子服务器本机出口；`warp` 走 WARP 出口；`dual` 同时生成两条隧道 |
| `allowed_ips=` | 默认 `0.0.0.0/0, ::/0`（全局隧道）；只想访问内网可改成 `10.200.0.0/24` |
| `dns=` | 默认 `1.1.1.1, 8.8.8.8` |
| `config_dir=` | 配置输出目录，默认 `/root/warppool-clients` |
| `register_warp=` | `false` 时跳过 WARP 转发注册 |

`mode=dual` 会生成两份配置，**一次只能启用一条**：

```text
pc.conf       直连出口，UDP 可用
pc-warp.conf  WARP 出口，仅 TCP
```

#### WARP 模式的限制

WARP 转发只重定向 **TCP**（`iptables -t nat PREROUTING ... -p tcp -j REDIRECT`）。`warp` 模式下该客户端的 UDP 不会被转发到 WARP，也不做 NAT，会被丢弃。

需要 UDP 就用 `direct`，或者用 `dual` 拿到两条隧道分开用。

#### 移除客户端

```bash
bash /root/shared_node.sh action=remove target=pc
bash /root/shared_node.sh action=remove target=<公钥>   # 也可以用公钥定位
```

移除会重渲染配置、`wg syncconf` 热更新、清理该 IP 的 MASQUERADE 规则，并在 WARP 模式下注销转发客户端。其它 peer 的隧道不受影响。

---

## 配置

默认配置路径：

| 系统 | 路径 |
| --- | --- |
| Linux | `/etc/warppool/config.json` |

`warppool config init` 会创建这个 JSON 配置文件，并写入默认配置。它保存监听设置、默认代理设置、节点信息、Deploy Token 和 WireGuard 客户端私钥。一键安装脚本会在配置文件不存在时自动执行它。

请妥善保护配置文件。

---

## 更新日志

见 [CHANGELOG_CN.md](CHANGELOG_CN.md)。

---

## 安全说明

- 妥善保护 `/etc/warppool/config.json`。
- 不要把 SSH 密码、WireGuard 私钥、本地运行状态提交到 Git。
- 优先使用 SSH key 或交互式密码输入。
- `--insecure-skip-host-key-check` 仅用于临时测试。
- 本地代理端口默认监听 `127.0.0.1`。

---

## 当前限制

- 没有 Web UI。
- 共享多主服务器复用同一出口节点目前先支持 SSH Push 部署；Pull / Deploy Token 暂时保持原有单次注册流程。
- 额外客户端接入按节点布局区分：`wpls` 管理独占 `wp<名字>` 节点，`shared_node.sh action=add-client` 管理共享 `wpshared` 节点，两个工具都不碰对方的布局。
- `wpls list remove` 与 `wpls list edit` 只作用于经过 `wpls` 登记的连接。主服务器自行部署的 peer 显示为 `未登记`，需要在主服务器上移除。
- WARP 转发只处理 TCP。`warp` 模式客户端的 UDP 会被丢弃；需要 UDP 请用 `direct`，或 `dual` 同时拿两条隧道。
- `upgrade` 会更新主程序二进制和内置安装脚本资源，但不会修改现有配置文件。
