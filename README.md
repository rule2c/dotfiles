# dotfiles

个人代理规则、客户端配置和常用脚本。

| 目录 | 内容 |
|---|---|
| `rule/` | 自定义分流规则（Clash classical） |
| `client/` | mihomo / Shadowrocket 配置，说明见 [client/README.md](client/README.md) |
| `vps/` | 节点与 Sub-Store 部署脚本，说明见 [vps/README.md](vps/README.md) |
| `windows/` | Windows 优化脚本，说明见 [windows/README.md](windows/README.md) |
| `.github/` | 规则自动更新：`workflows/` 每天调用 `scripts/` 下的转换脚本，把 geosite 分类转成 Shadowrocket 可用的列表 |

规则地址：`https://raw.githubusercontent.com/rule2c/dotfiles/refs/heads/main/rule/<名称>.list`。

`rule/` 和 `vps/node-setup.sh` 的路径被客户端和已部署节点按 URL 引用，不要改名或移动。
