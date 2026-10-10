# 更新日志

## 未发布

- 新增常驻命令 `wpls`，由节点安装脚本装到 `/usr/local/bin/wpls`，用于管理独占布局节点（`wp<名字>`）上的客户端：`wpls list`、`wpls list add`、`wpls list wgadd`、`wpls list remove [序号]`、`wpls list edit`。列表会把「登记过的连接」和「只存在于 WireGuard 配置里的 peer」合并展示，并显示实时握手状态。
- 新增 `legacy_add_client.sh`，是 `wpls` 的底层实现。它在已部署的 `wp<名字>.conf` 上就地增量修改：原有 `PrivateKey`、`Address`、`ListenPort` 与全部 `[Peer]` 段逐字保留，只重写 `PostUp`/`PostDown`。写盘前用 `wg-quick strip` 校验，用 `wg syncconf` 热应用，失败自动还原上一份配置。
- NAT 地址列表改为直接内联在 `PostUp`/`PostDown` 里（`for ip in A B; do ... done`），不再依赖外部文件。此前外部文件一旦丢失或为空，所有直连客户端的 MASQUERADE 规则会被静默跳过，且只有重启后才会暴露。同时识别 Go 部署流程写入的字面地址形式，并会把「故意不在列表内」的隧道地址打印出来。
- `legacy_add_client.sh` 新增 `action=rotate`，可就地更换客户端的 peer 公钥，隧道地址与 NAT 规则保持不变；另新增 `action=list` 与 `action=remove`。
- `legacy_add_client.sh` 支持在节点上生成客户端密钥对（`client_private_key=`），并支持用 `client_ip=` 指定地址。
- 公网端点提示改为查询节点自身的公网地址，不再复用 peer 的 `endpoint`——那是客户端的来源地址，不是新客户端应当拨入的地址。
- 新增 `shared_node.sh action=add-client`，用于接入非主服务器客户端（本地电脑、手机等）。它会追加 peer、热更新接口而不影响已有隧道、为 `warp`/`dual` 模式注册 WARP 转发，并把可直接导入的全局隧道客户端配置写到 `/root/warppool-clients`。
- 新增 `shared_node.sh action=list` 和 `shared_node.sh action=remove target=<名称|公钥>`。移除会重渲染配置、同步生效、清理该 peer 的 MASQUERADE 规则，并注销它的 WARP 转发客户端。
- `shared_node.sh` 现在为每个 peer 记录 `NAME` 和可选的客户端私钥，便于重新导出和识别客户端。已有 peer 缺少这些字段仍然兼容。
- 新增 `warp_forward.sh action=register`，在转发器已经运行时直接追加客户端而不重启；没有转发器运行时回退到完整启动流程。手动执行 `shared_node.sh action=add mode=warp` 现在自成一体，不再依赖 Go 部署流程补 WARP 接线。
- `shared_node.sh` 在同目录缺少配套脚本时，可以从发布地址自动下载。
- 节点卸载脚本现在会一并清理 `/usr/local/bin/wpls`、`/usr/local/bin/warppool-node-client` 与 `/etc/warppool-node/legacy-clients`。
- 新增 `wpls init`：在没有主服务器的情况下初始化出口节点（生成服务端密钥、写配置、启动接口、装开机自愈）。配套的 `legacy_add_client.sh action=init` 让"不配置主服务器、只当出口用"成为可行路径。
- 安装脚本会把运行期需要的 helper（`warp_forward.sh`、`warp_install.sh`、`warp_wgcf.sh`、`singbox_install.sh`、`wg_preflight.sh`）装到 `/usr/local/lib/warppool/node/`，运行期不再需要联网下载，避免出现"节点版本与拉取的 helper 版本不匹配"。
- 修复 `wpls list edit` 改名只移动文件、未同步记录内的 `NAME` 字段，导致改名之后所有后续编辑都报"找不到登记文件"。
- 修复 `warp` 单隧道模式导出的客户端配置使用了 `warp_client_private_key`（那是 dual 模式第二条隧道用的），与 peer 的 `client_public_key` 不是一对密钥，客户端无法连接。
- 未提供 `endpoint` 时不再生成客户端配置（添加主服务器时那份配置本就无法拨号，是个空壳）。
- 修复配置中还没有任何 peer 时（`wpls init` 刚建好）添加客户端会因 `set -o pipefail` 中断。
- 修复 `wpls init` 未把接口交给 systemd 管理，导致之后 `systemctl restart` 必然失败并因自愈策略无限重试。
- `wpls list` 的类型列改用 ASCII 标记（`wpl` / `wg` / `-`），修正中文因字节数与显示宽度不一致造成的列错位。

## v0.1.12

- 新增 SSH Push 共享出口节点布局。多台主服务器可以部署到同一个出口节点；出口节点只维护一个共享 WireGuard 设备 `wpshared`，后续部署会追加 peer，不再覆盖已有 peer。
- WARP 转发支持同一个远端 WireGuard 设备下的多个 WARP 客户端地址，shared `warp` / `dual` Push 部署可以复用出口节点上的同一份 WARP 运行时。
- 增加保守兼容保护：检测到旧 `/etc/wireguard/wp*.conf` 独占布局时不会自动转换，避免误伤已有可用节点。
- 共享 Push 节点禁用旧式 node mode 切换，避免影响其他主服务器正在使用的远端规则；需要同时使用 direct/WARP 时建议直接部署 `dual` 模式。
- 修复交互式 SSH Push 部署时，`known_hosts` 文件存在但目标主机 HostKey 尚未收录会直接失败的问题；现在会询问本次是否跳过 HostKey 校验并重试。

## v0.1.11

- 新增 `dual` 双模式部署：同一个出口节点同时提供 direct 和 WARP 两个本地代理端口。
- `warppool deploy` / `warppool deploy-token` 支持选择 `dual/direct+warp`，并对两个本地端口做占用检测。
- `warppool ping` 在 dual 模式下会分别检测 direct 和 WARP 两个代理端口。
- Clash 导出会为 dual 节点生成 direct 和 WARP 两个代理条目。
- 修复 `warppool node remove` / `wpl node remove` 只删除节点记录但不刷新本地代理，导致端口继续被占用的问题。
- `node remove` 现在会先输出所选节点信息，并要求 `y/N` 确认，默认 `N`；确认后会刷新/停止本地代理并默认清理本地 WireGuard 客户端配置。
- 新增纯 IPv6 出口节点 `direct` 模式支持：IPv6 WireGuard endpoint 自动加中括号，自动生成 IPv6 隧道地址，并在节点侧开启 IPv6 forwarding 与 `ip6tables` MASQUERADE。
- Pull/Deploy Token 安装脚本会正确格式化 IPv6 字面量主服务器 URL，并优先使用支持 IPv6 的公网端点检测。
- Debian/Ubuntu 安装流程遇到失效的 `*-backports` apt 源时，会备份并禁用对应源条目后自动重试，避免 Debian 11 纯 IPv6 小鸡因过期 backports 源直接部署失败。
- 优化 WARP 转发安装：官方 WARP SOCKS 端口短暂未就绪时会等待重试；Debian/Ubuntu 节点优先使用系统仓库 `redsocks` 做 SOCKS 透明转发，减少纯 IPv6 小鸡因无法访问 GitHub API 而下载 sing-box 失败的问题。
- `singbox_install.sh` 查询 GitHub latest API 失败时会回退到固定 sing-box 版本直链，避免仅因 GitHub API 不通直接中断。
- 修复新增节点后重启本地代理时，旧 dual 节点的 WARP 端口未被识别为已托管端口，导致误报 `address already in use` 的问题。

## v0.1.10

- 新增短命令 `wpl`，等效于 `warppool`，例如 `wpl node list`、`wpl ping nat01`。
- 新增子节点卸载短命令 `wpl-node-uninstall`，等效于 `warppool-node-uninstall`。
- 优化 `warppool ping` 中文输出，将“节点公网地址”调整为更准确的“节点延迟检测地址”。
- 修复中文模式下 `warppool ping` 仍混入英文 `mode`、`proxy check ok` 等提示的问题。
- 增强卸载安全性：主服务器卸载只会删除指向 WarpPool 的 `wpl` 软链接，不会误删其他程序占用的同名文件。

## v0.1.9

- 新增 Alpine WARP 支持，基于 `wgcf` 生成 WireGuard 配置，并通过 sing-box 内置 WireGuard endpoint 出口。
- Alpine WARP 端点探测改为优先 IPv6，失败后回退 IPv4，最后兜底原始域名。
- Alpine 上 sing-box 安装优先使用系统仓库：`apk update && apk add --no-cache sing-box`。
- 当 Alpine 仓库包不存在、无法运行，或无法加载 WarpPool 生成的 WARP 配置时，自动回退到 GitHub musl 版本。
- 修复 Alpine WARP 部署时误下载非 musl 版 sing-box 导致二进制无法运行的问题。

## v0.1.8

- 正式优化 1G 级别小硬盘出口节点的 WARP 模式安装。Debian/Ubuntu 安装脚本不再安装 `wireguard` 元包，只安装必要的 WireGuard tools，尽量使用 `--no-install-recommends`，并在安装步骤后清理软件包缓存。
- 修复轻量依赖调整后 WARP 安装缺少 `gpg` 的问题；仅在 WARP 模式需要 Cloudflare apt 仓库时安装 `gpg`。
- 放宽小硬盘 NAT VPS 的 WARP 磁盘预检：硬盘低于推荐空间但高于硬性最低空间时只提示风险，不再过早阻止安装。
- `warppool node mode --method ssh` 会复用 Push 部署时保存的非敏感 SSH 默认值。SSH 密码不会保存。
- `warppool ping` 新增节点延迟检测地址 RTT、主服务器直连 HTTP 延迟、代理出口 IP 和代理 HTTP 延迟检测，并支持多个 HTTP 检测地址兜底。

## v0.1.5

- 修复节点模式切换的语言继承问题。Pull 安装的节点会保存用户选择的语言，后续执行 `node_mode.sh` 切换 direct/WARP 时会继续使用该语言。
- 为 Deploy Token 和节点模式切换命令增加更醒目的“一次性 token / 有效期”提示。
- 为 Cloudflare WARP 官方客户端安装增加磁盘空间和 inode 预检；当 `apt` 因磁盘配额不足失败时，给出更明确的恢复提示。
- 修复 SSH Push 部署非 root 用户失败的问题；远端用户不是 root 时，会在可用的情况下自动使用 `sudo` 执行需要权限的操作。
