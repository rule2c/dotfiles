# client

mihomo / Shadowrocket 客户端配置。

`mihomo.yaml` 的订阅链接是占位符，换成自己的 Sub-Store 地址，或用 `vps/substore-setup.sh` 部署后自动生成。

## 广告拦截

两份配置均按域名拦截，规则位于直连规则之后、Google / AI 规则之前。

| 客户端 | 规则源 | 关闭方法 |
|---|---|---|
| mihomo | geosite `category-ads-all` | `🛑 广告拦截` 切 DIRECT |
| Shadowrocket | blackmatrix7 `AdvertisingLite` | `🛑 广告拦截` 切 DIRECT |

误杀时在拦截规则前加放行。同域下发的广告（YouTube、B 站信息流等）需 MITM，未处理。
