# client

mihomo / Shadowrocket / sing-box 客户端配置。

`mihomo.yaml` 的订阅链接是占位符，换成自己的 Sub-Store 地址，或用 `vps/substore-setup.sh` 部署后自动生成。

## sing-box.json：经 Sub-Store 下发

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
