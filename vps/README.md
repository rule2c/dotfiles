# vps

服务器端部署脚本。

## node-setup.sh：节点一键部署

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

## substore-setup.sh：Sub-Store 部署

在 VPS 上用 Docker 部署 Sub-Store，经 Cloudflare CDN 以 HTTPS 对外提供。准备步骤见脚本开头注释。

```bash
sudo CF_Token=<Cloudflare API Token> bash vps/substore-setup.sh sub.example.com 8443
```

在仓库里运行时，会把订阅链接填进 `client/` 下的模板，输出到 `/root/sub-store-ready/`。
