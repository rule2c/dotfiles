# dotfiles

个人代理规则、客户端配置和常用脚本。

| 目录 | 内容 |
|---|---|
| `rule/` | 自定义分流规则（Clash classical），`rule/sing-box/` 为自动生成的 sing-box 规则集 |
| `scripts/` | 规则转换脚本，由 `.github/workflows/update-geosite-lists.yml` 定时及规则改动时调用 |
| `client/` | mihomo / Shadowrocket / sing-box 配置，Sub-Store 部署脚本 |
| `vps/` | 代理节点一键部署脚本 |
| `windows/` | Windows 优化脚本 |

规则地址：`https://raw.githubusercontent.com/rule2c/dotfiles/refs/heads/main/rule/<名称>.list`（sing-box 用 `rule/sing-box/<名称>.json`）。

`client/mihomo.yaml` 的订阅链接是占位符，换成自己的 Sub-Store 地址，或用 `client/deploy-substore.sh` 部署后自动生成。

## vps/node-setup.sh：节点一键部署

一台 VPS 提供多条线路，出站统一只走 IPv4：

| 线路 | 端口 | 用途 |
|---|---|---|
| VLESS + Vision + REALITY（偷自己） | TCP 443 | 主力 |
| XHTTP + REALITY | TCP 443 | 同端口备用 |
| Hysteria2 | UDP 443，跳跃 20000-40000 | TCP 被封或限速时 |
| XHTTP / WS + TLS 经 Cloudflare | CDN 443 | IP 被墙后仍可用（可选） |

**准备**

1. 主域名：Cloudflare 灰云，A 记录指向 VPS。
2. （可选）CDN 域名：橙云，SSL 设为 Full (strict)。
3. Cloudflare API Token：权限"区域 → 区域 → 读取"+"区域 → DNS → 编辑"。
4. 安全组放行 TCP 443、UDP 443、UDP 20000-40000（TCP 80 可选）。

证书通过 DNS 验证申请通配符证书，不暴露具体子域名；不用 Cloudflare 时加 `--http01`。有 CDN 域名时自动启用源站隐藏（仅放行 Cloudflare IP 回源）；CDN 线路单独失效时重跑脚本刷新 IP 段。伪装站每台随机生成，放自己的站点到 `/var/www/proxy-node/` 不会被覆盖。

**常用命令**

```bash
sudo bash vps/node-setup.sh
```

```bash
sudo bash vps/node-setup.sh -d a.example.com -c cdn.example.com -e me@example.com
```

```bash
sudo node-setup redeploy
```

```bash
sudo bash vps/node-setup.sh info
```

依次为：交互式部署；参数部署（Token 可用环境变量 `CF_Token`，完整参数见 `--help`）；沿用全部配置和凭据重新部署（`sudo node-setup update` 后用它生效，`--reset` 重新生成凭据）；查看节点信息。

**无域名模式**（`--no-domain`，或 `--target <网站>` 手动指定借用站点）：直接用 VPS 的 IPv4；Reality 默认扫描同 /24 网段借用邻居网站；Hysteria2 用自签证书并默认开启 salamander 混淆（`--no-obfs` 关闭）；不能部署 CDN 线路。抗封锁能力弱于有域名模式。

**Xray 版本**：默认装最新版。v26.9.9 起要求 X25519MLKEM768，Shadowrocket 指纹选 Chrome / Chrome140 / Safari / Firefox（Sub-Store 订阅用 `target=URI`；`target=shadowrocket` 下发的 Clash 格式会被识别成 Chrome120），mihomo 用新版内核；客户端太旧时用 `XRAY_VERSION=v26.7.28` 重跑。

**卸载**

```bash
sudo bash vps/node-setup.sh uninstall
```

```bash
sudo bash vps/node-setup.sh uninstall --all -y
```

前者按编号选择，后者全部卸载不确认。能识别 Xray、sing-box、Hysteria、x-ui/3x-ui 等常见代理程序、面板、Docker 容器和端口跳跃规则。nginx、acme.sh、Caddy、cloudflared 不在"全部"范围内，需单独选；SSH 和防火墙规则不动。

## client/sing-box.json：经 Sub-Store 下发

分流与 mihomo 版一致，适用 sing-box 1.12+。

1. Sub-Store「文件」新建 `sing-box`，来源本地，粘贴 `client/sing-box.json`。
2. 添加「脚本操作」：

   ```
   https://raw.githubusercontent.com/xream/scripts/main/surge/modules/sub-store-scripts/sing-box/template.js#type=组合订阅&name=all&outbound=🕳vmiss回落🏷ℹ️vmiss-🕳Oracle回落🏷ℹ️oracle_arm-(xhttp|vision)🕳nosla回落🏷ℹ️nosla-
   ```

3. 在其后再加本地脚本 `client/sing-box-reject-empty.js`，使空回落组拒绝连接而非直连。
4. 客户端添加远程配置：`https://<Sub-Store 域名>:<端口>/<后端路径>/api/file/sing-box`。

与 mihomo 版的差别：不支持 XHTTP 节点；回落组用大 `tolerance` 的 `urltest` 模拟，节点恢复后不自动切回；出现 `COMPATIBLE` 说明节点名或模板参数不对；`IP-ASN` 规则转换时跳过。

## 广告拦截

三份配置均按域名拦截，规则位于直连规则之后、Google / AI 规则之前。

| 客户端 | 规则源 | 关闭方法 |
|---|---|---|
| mihomo | geosite `category-ads-all` | `🛑 广告拦截` 切 DIRECT |
| Shadowrocket | blackmatrix7 `AdvertisingLite` | `🛑 广告拦截` 切 DIRECT |
| sing-box | `category-ads-all.srs` | 删除该规则 |

误杀时在拦截规则前加放行。同域下发的广告（YouTube、B 站信息流等）需 MITM，未处理。

## windows/windows-optimize.bat：Windows 优化

双击运行，自动提权，按序号多选（如 `1 4 6`；`a` 执行 1-9；`q` 退出），首次执行前备份注册表到 `桌面\优化前注册表备份`。

| 序号 | 内容 |
|---|---|
| 1 | 性能：后台应用、视觉效果、电源模式 |
| 2 | 服务与开机启动项 |
| 3 | 卸载小组件 |
| 4–7 | 隐私：搜索 / 遥测 / 广告推荐 / 输入语音 Copilot |
| 8 | 禁用数据收集计划任务 |
| 9 | 清理临时文件 |
| 10 | 移动用户文件夹到其他盘（默认 `D:\Users`，不含在 `a` 中） |

使用序号 10 前先关闭 OneDrive 的文件夹备份。
