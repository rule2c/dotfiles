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

所有线路出站都只用 IPv4（Xray `domainStrategy: UseIPv4`，Hysteria2 `mode: 4`；客户端直接给的 IPv6 地址会被拒绝，让应用回落到 IPv4），保证一台 VPS 只有一个出口 IP。

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

### 没有自己的域名

```bash
sudo bash vps/node-setup.sh --no-domain
```

```bash
sudo bash vps/node-setup.sh --target www.microsoft.com
```

交互式向导第一步也可以选"没有域名"。这个模式和有域名时的区别：

- 节点地址直接用 VPS 的公网 IPv4，不需要 Cloudflare，也不装 nginx 和 acme.sh。
- Reality 改成"偷别人"：target 和 SNI 是借用的网站（默认 `www.microsoft.com`，`--target` 可换）。部署前会检查它是否支持 TLS 1.3 + HTTP/2，不支持就停下。最好选和 VPS 同地区、不跳转的网站。
- Hysteria2 用自签证书（10 年有效，CN 是借用的网站，重跑时沿用，指纹不变），伪装页反代借用的网站。分享链接带 `insecure=1&pinSHA256=指纹`，mihomo 配置带 `skip-cert-verify: true` 和 `fingerprint`。
- 不能部署 CDN 线路（`cdn-xhttp` / `cdn-ws` 需要自己的域名）。VPS 的 IP 被墙后只能换 IP。
- 以前用域名部署过的话，会移除本脚本的 nginx 站点和 Let's Encrypt 证书。

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

Xray 默认固定为 **v26.7.28**，全部线路都用这个版本测试过（v26.9.9 起拒绝不带 X25519MLKEM768 的 Client Hello，Shadowrocket 连不上）。要换版本，用环境变量 `XRAY_VERSION=v26.x.x`；设为 `XRAY_VERSION=latest` 则安装最新版。

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

## client/sing-box.json：sing-box 完整配置（经 Sub-Store 下发）

分流逻辑与 `client/mihomo.yaml` 一致，按 sing-box 1.12+ 的格式写（1.14 下 `download_detour` 会提示已废弃，1.16 前都能用）。sing-box 不能像 mihomo 那样直接引用订阅，节点由 Sub-Store 的模板脚本插进去。

### 在 Sub-Store 里配置

1. 「文件」→ 新建，名称填 `sing-box`，来源选本地，把 `client/sing-box.json` 的内容粘贴进去。
2. 在这个文件里添加「脚本操作」，链接填：

   ```
   https://raw.githubusercontent.com/xream/scripts/main/surge/modules/sub-store-scripts/sing-box/template.js#type=组合订阅&name=all&outbound=🕳vmiss回落🏷ℹ️vmiss-🕳Oracle回落🏷ℹ️oracle_arm-(xhttp|vision)🕳nosla回落🏷ℹ️nosla-
   ```

   含义：读取名为 `all` 的组合订阅，按节点名把节点插进三个回落组（规则和 mihomo 的 `filter` 相同）。
3. 在模板脚本**后面**再添加一个「脚本操作」，选本地脚本，把 `client/sing-box-reject-empty.js` 的内容粘贴进去。回落组没匹配到节点时，它让这个组拒绝连接，而不是直连。
4. 客户端（SFA / SFI / SFM 等）添加远程配置，链接为 `https://<Sub-Store 域名>:<端口>/<后端路径>/api/file/sing-box`。

### 和 mihomo 版的差别

- **不支持 XHTTP：** sing-box 没有 XHTTP 传输，Sub-Store 输出时会丢掉 `xhttp` 节点。东京只剩 vision；洛杉矶剩 reality → hysteria2 → cdn-ws。
- **回落组：** sing-box 没有 `fallback`，用 `urltest` 加很大的 `tolerance`（10000 ms）代替，效果是按顺序用第一个可用节点。区别是前面的节点恢复后不会自动切回去，要等当前节点失效。
- **空组：** 节点名都没匹配上时，模板脚本会往组里放一个名为 `COMPATIBLE` 的直连出站。第 3 步的脚本把它换成连不上的出站（`127.0.0.1:9`），效果和 mihomo 的 `empty-fallback: REJECT` 一样，不会用本机 IP 直连出去。sing-box 1.13 起没有 `block` 出站，所以这样写。看到 `COMPATIBLE` 说明节点名或模板脚本参数不对。
- **自定义规则：** sing-box 读不了 Clash 的 classical 列表。`Customized_Rules` 仓库的 Action 会把 `rule/*.list` 转成 `rule/sing-box/*.json`（sing-box 规则集源文件），配置里以 `format: source` 远程引用。列表改动推送后自动重新生成，不用改这里。Steam_CDN 里的 `IP-ASN,32590` sing-box 不支持，转换时会跳过。
- **geosite / geoip：** 用 MetaCubeX meta-rules-dat 的 `sing` 分支 `.srs` 规则集，与 mihomo 用的是同一份数据，经 `🚀 手动选择` 下载。

## 广告拦截（mihomo / Shadowrocket / sing-box）

三份客户端配置都按域名拦截广告和追踪，规则放在本地 / Tailscale 直连之后、美区锁定和 Google / AI 规则之前（geosite 的 `google` 本身含 Google 广告域名，放后面就拦不到）。

| 客户端 | 规则源 | 关掉的方法 |
|---|---|---|
| mihomo | geosite `category-ads-all`（MetaCubeX，约 900 条） | 策略组 `🛑 广告拦截` 切到 DIRECT |
| Shadowrocket | blackmatrix7 `AdvertisingLite`（DOMAIN-SET 约 3.7 万域名 + 关键词 / IP 规则） | 策略组 `🛑 广告拦截` 切到 DIRECT |
| sing-box | 同 mihomo 的 `category-ads-all.srs`，路由动作 `reject` | 选择器切不了 reject 动作，只能删掉这条规则 |

- **误杀：** 把域名写在拦截规则前面，配置里留了示例注释。
- **Shadowrocket 用 Lite 版：** 完整版 `Advertising_Domain.list` 约 6 MB，容易让 iOS 网络扩展超内存。
- **拦不到的：** 和正文同域名下发的广告（YouTube 视频广告、B 站 / 微博信息流、开屏广告等）需要 MITM 加重写，这里没有做。

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

双击运行即可，**不要**右键"以管理员身份运行"（改的是当前用户的注册表）。脚本会在一个新的命令行窗口里运行，执行完或出错都不会自动关闭，方便查看结果。脚本内容只用英文，避免中文在不同编码下解析出错。运行时会问是否把原来的文件一起移过去：

- **Y**：用 robocopy 把文件移动到新位置
- **N**：只改位置，旧文件留在原处

想放到别的目录，可以在命令行传参数：`move-user-folders.bat E:\MyFiles`。

注意：如果开启了 OneDrive 的"备份桌面/文档/图片"，要先在 OneDrive 设置里关掉，否则会冲突。
