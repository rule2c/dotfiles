// Sub-Store 脚本操作：放在 sing-box 模板脚本（template.js）之后执行
//
// 模板脚本发现回落组一个节点都没匹配上时，会插入名为 COMPATIBLE 的 direct 出站，
// 这个组的流量就会用本机 IP 直连出去（AI、Google 等也会暴露真实 IP）。
// 这里把 COMPATIBLE 换成一个连不上的出站：本机 127.0.0.1:9 没有服务，连接立即被拒，
// 效果等同 mihomo 的 empty-fallback: REJECT。sing-box 1.13 起没有 block 出站，所以用这种写法。
// 组名还叫 COMPATIBLE，客户端里看到它就说明节点名或模板脚本参数不对。

const config = JSON.parse($content)
const outbounds = Array.isArray(config.outbounds) ? config.outbounds : []
const i = outbounds.findIndex(o => o.tag === 'COMPATIBLE')
if (i === -1) {
  console.log('[reject-empty] 没有空的回落组')
} else {
  outbounds[i] = { tag: 'COMPATIBLE', type: 'socks', server: '127.0.0.1', server_port: 9 }
  const empty = outbounds
    .filter(o => Array.isArray(o.outbounds) && o.outbounds.includes('COMPATIBLE'))
    .map(o => o.tag)
  console.log(`[reject-empty] 这些组没有节点，已改为拒绝：${empty.join('、')}`)
}
$content = JSON.stringify(config, null, 2)
