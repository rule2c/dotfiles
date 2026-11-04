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
2. （可选）一个 **CDN 域名**：Cloudflare **橙色云朵**，A 记录指向 VPS，SSL 模式设为 Full (strict)。从一开始就是橙云，不需要先改成灰云。
3. 一个 **Cloudflare API Token**：在"我的个人资料 → API 令牌 → 创建令牌 → 自定义"里创建，权限给"区域 → 区域 → 读取"和"区域 → DNS → 编辑"，区域资源只选你的域名。
4. 在 VPS 商家的防火墙或安全组里放行 TCP 443、UDP 443，以及 UDP 20000-40000。TCP 80 可选，只用来跳转到 https。

证书用 DNS 验证申请**通配符证书**（例如 `*.example.com`）：

- 证书透明度日志里只会出现通配符，看不到具体子域名。
- 连到 VPS IP 的人看到的证书也只有通配符，看不出 CDN 域名托管在这台机器上。
- Token 由 acme.sh 保存在 `/root/.acme.sh/account.conf`，用于自动续期；卸载时会一并删除。

不用 Cloudflare 管理 DNS 时可以加 `--http01` 改用 80 端口验证，但证书会公开具体域名。

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

第一条是交互式，按提示输入即可，Token 的输入不会显示在屏幕上。第二条用参数一次传完，Token 可以用环境变量 `CF_Token` 传入，全部参数见 `--help`。第三条用来重新显示节点信息。

重复运行会沿用上次生成的 UUID、密钥和密码，客户端不用改。加 `--reset` 才会重新生成。

Xray 默认固定为 **v26.9.9**，全部线路都用这个版本测试过。要换版本，用环境变量 `XRAY_VERSION=v26.x.x`；设为 `XRAY_VERSION=latest` 则安装最新版。

### 卸载（包括其他脚本装的代理）

```bash
sudo bash vps/node-setup.sh uninstall
```

```bash
sudo bash vps/node-setup.sh uninstall --all -y
```

第一条列出检测到的组件，按编号选择要卸载的。第二条卸载全部代理组件，不再确认。

能检测的组件：

- **代理程序：** Xray、V2Ray、sing-box（含甬哥脚本）、Hysteria/Hysteria2、TUIC、Trojan/Trojan-Go、Shadowsocks、Juicity、NaiveProxy、gost、Brook、mihomo/Clash
- **面板和一键脚本：** x-ui/3x-ui、s-ui、h-ui、v2ray-agent 八合一
- **Docker：** 名字或镜像像代理的容器
- **端口跳跃：** 其他脚本留下的 UDP 端口跳跃 NAT 规则
- **本脚本的附加配置**

对每个选中的组件，卸载会做这些事：

- 停止并禁用对应的服务，删除 unit 文件
- 结束残留进程
- 删除程序和配置目录。属于 apt 软件包的文件改用 `apt purge` 卸载
- 清理指向已删目录的快捷命令，例如 `/usr/bin/x-ui`、`sb`
- 删除 root crontab 里引用了这些路径的行

nginx、acme.sh、Caddy、cloudflared 可能另有用途，选"全部"时不会包含，需要按编号单独选。SSH 和防火墙的放行规则不会改动。

## windows/move-user-folders.bat：把用户文件夹移到 D 盘

一次性把 **桌面、下载、文档、图片、音乐、视频** 的位置改到 `D:\Users` 下：

| 文件夹 | 新位置 |
|---|---|
| 桌面 | `D:\Users\Desktop` |
| 下载 | `D:\Users\Downloads` |
| 文档 | `D:\Users\Documents` |
| 图片 | `D:\Users\Pictures` |
| 音乐 | `D:\Users\Music` |
| 视频 | `D:\Users\Videos` |

双击运行即可，**不要**右键"以管理员身份运行"（改的是当前用户的注册表）。运行时会问是否把原来的文件一起移过去：

- **Y**：用 robocopy 把文件移动到新位置
- **N**：只改位置，旧文件留在原处

想放到别的目录，可以在命令行传参数：`move-user-folders.bat E:\MyFiles`。

注意：如果开启了 OneDrive 的"备份桌面/文档/图片"，要先在 OneDrive 设置里关掉，否则会冲突。
