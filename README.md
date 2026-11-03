# personal-scripts
Personal utility scripts

## vps/node-setup.sh：代理节点一键部署

合并了原来的 `reality-setup.sh`（Reality）和 `la-setup.sh`（Hysteria2 + CDN）。一台 VPS 同时提供三条线路，被封时可以切换：

| 线路 | 端口 | 作用 |
|---|---|---|
| VLESS + Vision + REALITY（偷自己） | TCP 443 | 主力。target 是本机 nginx + 自己域名的真证书 |
| XHTTP + REALITY | 同上 | 同端口备用（fallback） |
| Hysteria2 | UDP 443 + 端口跳跃 20000-40000 | TCP 被封或限速时使用 |
| XHTTP / WS + TLS 经 Cloudflare | CDN 443 | VPS 的 IP 被墙后仍能用（可选） |

### 准备

1. 一个**主域名**：Cloudflare 灰色云朵，A 记录指向 VPS。Reality 和 Hysteria2 共用这个域名。
2. （可选）一个 **CDN 域名**：先设为灰色云朵，部署完成后再改成橙色云朵，SSL 模式设为 Full (strict)。
3. 在 VPS 商家的防火墙或安全组里放行 TCP 80、TCP 443、UDP 443，以及 UDP 20000-40000。

### 运行

```bash
sudo bash vps/node-setup.sh
```

```bash
sudo bash vps/node-setup.sh -d a.example.com -c cdn.example.com -e me@example.com
```

```bash
sudo bash vps/node-setup.sh info
```

第一条是交互式，按提示输入即可；第二条用参数一次传完，全部参数见 `--help`；第三条用来重新显示节点信息。

重复运行会沿用上次生成的 UUID、密钥和密码，客户端不用改。加 `--reset` 才会重新生成。
