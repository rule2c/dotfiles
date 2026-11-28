# client

mihomo / Shadowrocket 客户端配置。

| 文件 | 用途 |
|---|---|
| `mihomo.yaml` | OpenClash / Clash Verge 共用模板 |
| `nikki.yaml` | ImmortalWrt 主路由 nikki 专用，由 `mihomo.yaml` 派生（区别见文件开头注释），改策略组 / 分流规则时两份要同步 |
| `shadowrocket.conf` | Shadowrocket |

`mihomo.yaml`、`nikki.yaml` 的订阅链接是占位符，换成自己的 Sub-Store 地址，或用 `vps/substore-setup.sh` 部署后自动生成。Sub-Store 上分别存为 `mihomo`、`nikki` 两个文件。

nikki 的端口、面板、DNS 监听、`+.ts.net` 的 nameserver-policy、TCP Keep Alive 等由路由器 LuCI（`/etc/config/nikki`）混入，不在这个文件里。

## 广告拦截

两份配置均按域名拦截，规则位于直连规则之后、Google / AI 规则之前。

| 客户端 | 规则源 | 关闭方法 |
|---|---|---|
| mihomo | geosite `category-ads-all` | `🛑 广告拦截` 切 DIRECT |
| Shadowrocket | blackmatrix7 `AdvertisingLite` | `🛑 广告拦截` 切 DIRECT |

误杀时在拦截规则前加放行。同域下发的广告（YouTube、B 站信息流等）需 MITM，未处理。
