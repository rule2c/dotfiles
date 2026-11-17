#!/usr/bin/env bash
# =============================================================================
#  一键部署：Reality 偷自己 + Hysteria2 + Cloudflare CDN 备用（Debian 12/13、Ubuntu 22.04+，x86_64 / ARM64）
#
#  一台机器三条路，哪条被封就换哪条：
#    1) VLESS + Vision + REALITY   TCP（默认 443）  偷自己：target 是本机 nginx + 真证书，SNI 和 IP 对得上
#       └ 同端口 XHTTP + REALITY 备用（fallback）
#    2) Hysteria2                  UDP（默认 443）  真证书，可选端口跳跃 / salamander 混淆
#    3) XHTTP / WS + TLS 经 Cloudflare CDN（可选）  VPS 的 IP 被墙后仍可用
#
#  用法：
#    sudo bash node-setup.sh                                   # 菜单 + 部署向导（按编号选择）
#    CF_Token=xxxx sudo -E bash node-setup.sh -d a.example.com -c cdn.example.com
#    sudo bash node-setup.sh -d a.example.com -p 443 -u 443 --hop 20000-40000 -e me@example.com
#    sudo bash node-setup.sh --no-domain                       # 没有自己的域名：Reality 借用同网段邻居的网站，Hysteria2 自签证书
#    sudo bash node-setup.sh --target www.example.com          # 同上，但手动指定借用的网站（不扫描）
#    node-setup redeploy                                       # 重新部署：沿用上次的全部设置和凭据，什么都不用输
#    sudo bash node-setup.sh info                              # 重新显示节点信息
#    node-setup / node-setup update                            # 部署后已装成命令；update 从 GitHub 更新脚本
#                   仓库是私有的话，把只读 Token（Contents: Read）写进 /root/.gh-token，或用环境变量 GH_TOKEN
#    sudo bash node-setup.sh uninstall                         # 卸载：列出本机所有代理（含其他脚本装的），选择卸载
#    sudo bash node-setup.sh uninstall --all -y                # 卸载全部代理组件，不询问
#
#  参数：
#    -d, --domain   主域名（有域名时必填）。Cloudflare 灰色云朵，A 记录指向本机。Reality 和 Hysteria2 共用
#        --no-domain 没有自己的域名：节点地址用本机 IPv4，Reality 借用别人网站的证书（"偷别人"），
#                   Hysteria2 用自签证书（链接里带 insecure=1 和证书指纹），不能部署 CDN，也不需要 Cloudflare
#                   抗封锁能力弱于有域名模式，有条件请买个域名用 -d
#    -t, --target   无域名模式下 Reality 借用的网站。不给就自动扫描本机同一 /24 网段，
#                   找支持 TLS 1.3 + HTTP/2 + X25519、证书有效、不跳转到别的域名的网站（SNI 和 IP 在同一机房）
#                   给了它就等于 --no-domain；不要用 www.microsoft.com 这类被大量使用的网站
#    -c, --cdn      CDN 域名（可选，不填就不部署 CDN）。Cloudflare 橙色云朵，A 记录指向本机
#                   有 CDN 域名时自动隐藏源站：只有 Cloudflare 的 IP 能以这个域名回源，
#                   别人拿它当 SNI 直连本机 IP 会被拒绝握手（需要 nginx 的 stream 模块）
#        --cf-token Cloudflare API Token（也可用环境变量 CF_Token，或运行时输入）。权限：
#                   Zone → Zone → Read 和 Zone → DNS → Edit，范围只选你的域名
#                   用来做 DNS 验证申请【通配符证书】（*.example.com），证书透明度日志里看不到具体子域名
#        --http01   不用 Cloudflare API，改用 80 端口验证（会在公开日志里留下具体域名，不推荐）
#    -p, --port     Reality 的 TCP 端口，默认 443
#    -u, --hy2-port Hysteria2 的 UDP 端口，默认 443
#        --hop      Hysteria2 端口跳跃范围，默认 20000-40000；off 表示关闭
#        --obfs     Hysteria2 开启 salamander 混淆（不再像 HTTP/3，但 UDP 被 QoS 时可能有用）。无域名模式默认开启
#        --no-obfs  Hysteria2 不开混淆（有域名模式的默认）
#        --no-hy2   不部署 Hysteria2
#    -e, --email    申请证书用的邮箱，默认 admin@主域名
#        --proto    要部署的协议，逗号分隔（默认全部；不给 -c 时没有 cdn-*）：
#                     reality        VLESS + Vision + REALITY（必选：TCP 入口，CDN 回源也从它转给 nginx）
#                     reality-xhttp  同端口 XHTTP + REALITY 备用
#                     hy2            Hysteria2（同 --no-hy2 的反义）
#                     cdn-xhttp      XHTTP + TLS 经 Cloudflare CDN（需要 -c）
#                     cdn-ws         WS + TLS 经 Cloudflare CDN（需要 -c；Xray 已标记 WS 为过时）
#                   例：--proto reality,hy2      只要 Reality 和 Hysteria2
#    -n, --name     节点名前缀，默认取主域名第一段（无域名模式默认 node）
#    -r, --region   节点名前的国旗：两位国家代码，如 us（🇺🇸）、jp（🇯🇵）；默认按本机 IP 自动识别，none 不加
#        --reset    重新生成 UUID / 密钥 / 密码（默认沿用上次的，客户端不用改）
#        --all      （uninstall）选中全部代理组件；nginx / acme.sh / Caddy / cloudflared 需单独选
#    -y, --yes      （uninstall）不再确认；（部署时）不询问，直接卸载检测到的其他代理
#    Xray 默认安装最新版；环境变量 XRAY_VERSION=v26.x.x 可固定成某个版本（如 v26.7.28）
# =============================================================================
set -Eeuo pipefail
# 默认装最新版 Xray。两点要知道：
#   - v26.9.9 起拒绝不带 X25519MLKEM768 的 Client Hello：客户端的 uTLS 指纹要选带它的
#     （Shadowrocket 选 Chrome / Chrome140 / Safari / Firefox，不能用 Chrome120 等旧指纹；mihomo 用新版内核）。
#     客户端太旧连不上时，用 XRAY_VERSION=v26.7.28 重跑，那一版没有这个限制
#   - Xray 默认的 minClientVer 会拒掉 mihomo（上报版本 1.8.2），所以配置里显式写 0.0.0
XRAY_DEFAULT_VERSION=latest
# 任何一步失败都打印位置，不再静默退出
trap 'rc=$?; printf "\033[31m脚本出错退出：第 %s 行，命令：%s（退出码 %s）\033[0m\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit $rc' ERR

WORKDIR=/root/proxy-node
STATE=$WORKDIR/state.env
INFO=$WORKDIR/node-info.txt
DEPLOY=$WORKDIR/deploy.env   # 上次部署用的设置（域名、端口、协议等），redeploy 时读回来
WEB=/var/www/proxy-node
SSL=/etc/ssl/proxy-node
MAIN_DIR=$SSL/main          # 主域名证书；CDN 域名若被同一张通配符覆盖，也用它
CDN_DIR=$SSL/cdn
NGX_SITE=/etc/nginx/sites-available/proxy-node
XRAY_CFG=/usr/local/etc/xray/config.json
SELF_BIN=/usr/local/bin/node-setup
SELF_URL=${NODE_SETUP_URL:-https://raw.githubusercontent.com/rule2c/dotfiles/main/vps/node-setup.sh}
GH_TOKEN_FILE=/root/.gh-token
XHTTP_SOCK=/dev/shm/xray-xhttp.sock
TARGET_PORT=18443          # 本机 nginx，只监听 127.0.0.1，是 Reality 的 target
HTTPS_PORT=18444           # 有 CDN 时：18443 换成 stream 分流层，HTTPS 站点挪到这里
REJECT_PORT=18445          # 有 CDN 时：不是 Cloudflare 来的 CDN 域名连接转到这里，握手被拒
NGX_STREAM=/etc/nginx/modules-enabled/99-proxy-node-stream.conf   # stream{} 得放在 http{} 外面
HIDE=0                     # 1 = 启用 CDN 源站隐藏（probe_stream 决定）
# Cloudflare 回源 IPv4 段（部署时会尝试从 cloudflare.com/ips-v4 更新，拿不到就用这份）
CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
WS_PORT=10001              # CDN WS 入站，只监听 127.0.0.1

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "$*"; exit 1; }

usage(){ awk 'NR>2 && /^# =====/{exit} NR>2{sub(/^# ?/,""); print}' "$0" 2>/dev/null || echo "用法：sudo bash node-setup.sh -d 主域名 [-c CDN域名] [-p 端口] [-u hy2端口] [--hop 范围]"; }

# ---------------------------------------------------------------- 参数 ----
CMD=install DOMAIN="" CDN="" RPORT="" HPORT="" HOP="" EMAIL="" NODE="" REGION="" PROTO="" OBFS="" NO_HY2=0 RESET=0 ALL=0 YES=0
CF_TOKEN=${CF_Token:-} HTTP01=0 NODOMAIN=0 RSNI=""

parse_args(){
  while [[ $# -gt 0 ]]; do
    case $1 in
      install|info|uninstall|update|redeploy) CMD=$1 ;;
      -d|--domain)   DOMAIN=${2:?缺少域名}; shift ;;
      -c|--cdn)      CDN=${2:?缺少 CDN 域名}; shift ;;
      -p|--port)     RPORT=${2:?缺少端口}; shift ;;
      -u|--hy2-port) HPORT=${2:?缺少端口}; shift ;;
      --hop)         HOP=${2:?缺少端口范围}; shift ;;
      -e|--email)    EMAIL=${2:?缺少邮箱}; shift ;;
      -n|--name)     NODE=${2:?缺少名称}; shift ;;
      --proto)       PROTO=${2:?缺少协议列表}; shift ;;
      -r|--region)   REGION=${2:?缺少国家代码}; shift ;;
      --cf-token)    CF_TOKEN=${2:?缺少 Token}; shift ;;
      --http01)      HTTP01=1 ;;
      --no-domain)   NODOMAIN=1 ;;
      -t|--target)   RSNI=${2:?缺少网站域名}; shift ;;
      --obfs)        OBFS=1 ;;
      --no-obfs)     OBFS=0 ;;
      --no-hy2)      NO_HY2=1 ;;
      --reset)       RESET=1 ;;
      --all)         ALL=1 ;;
      -y|--yes)      YES=1 ;;
      -h|--help)     usage; exit 0 ;;
      *) red "未知参数：$1"; usage; exit 1 ;;
    esac
    shift
  done
  # 只给 --target 不给 -d：就是无域名模式
  [[ -n $RSNI && -z $DOMAIN ]] && NODOMAIN=1
  return 0
}

ask(){ # ask 变量名 提示 默认值
  local v; read -rp "$2${3:+ [默认 $3]}: " v || true
  printf -v "$1" '%s' "${v:-$3}"
}

# choose 变量名 提示 默认编号 选项...   单选，变量里存选中的编号（从 1 开始）
choose(){
  local __v=$1 prompt=$2 def=$3 n=0 o ans; shift 3
  echo "$prompt"
  for o in "$@"; do n=$((n+1)); echo "  $n) $o"; done
  while :; do
    read -rp "请输入编号 [默认 $def]: " ans || true
    ans=${ans:-$def}
    [[ $ans =~ ^[0-9]+$ ]] && (( 10#$ans >= 1 && 10#$ans <= n )) && { ans=$((10#$ans)); break; }
    red "  请输入 1-$n 之间的数字"
  done
  printf -v "$__v" '%s' "$ans"
}

# rand_port tcp|udp：40001-60000 里挑一个本机没被占用的端口
# （避开默认端口跳跃范围 20000-40000，以及本脚本内部用的 10001 / 18443-18445）
rand_port(){
  local p flag=-tln; [[ $1 == udp ]] && flag=-uln
  while :; do
    p=$(shuf -i 40001-60000 -n 1)
    [[ -z $(ss -H $flag "sport = :$p" 2>/dev/null) ]] && { echo "$p"; return 0; }
  done
}

# 部署向导：能选的都用编号选，命令行已给的参数作为默认值
interactive(){
  [[ -t 0 ]] || die "缺少 -d 主域名（非交互环境请用参数传入；没有域名用 --no-domain，见 --help）"
  local c ans i ok
  echo
  grn "== 部署向导：Reality + Hysteria2 + CDN 备用 =="
  echo
  choose c "有没有自己的域名？" 1 \
    "有（推荐：Reality 偷自己 + 真证书，可选 Cloudflare CDN）" \
    "没有（节点用本机 IP；Reality 借用别人的网站，Hysteria2 自签证书，不能用 CDN）"
  if (( c == 1 )); then
    NODOMAIN=0
    echo
    ylw "主域名：Cloudflare【灰色云朵】，A 记录指向本机"
    while [[ -z $DOMAIN ]]; do ask DOMAIN "主域名" ""; done
  else
    NODOMAIN=1 DOMAIN="" CDN=""
    echo
    ylw "注意：无域名模式抗封锁能力弱于有域名模式（借用别人的网站、Hysteria2 自签证书、没有 CDN 兜底）。"
    ylw "      有条件建议买一个域名（几美元一年），选 1) 部署。"
    echo
    choose c "Reality 借用哪个网站：" "$( [[ -n $RSNI ]] && echo 2 || echo 1)" \
      "自动扫描本机同网段的网站（推荐：SNI 和 IP 在同一机房；上次扫到的还能用就沿用）" \
      "手动输入（不要用 www.microsoft.com 这类被大量使用的网站）"
    if (( c == 1 )); then RSNI=""
    else local rdef=$RSNI; RSNI=""; while [[ -z $RSNI ]]; do ask RSNI "网站域名，如 www.example.com" "$rdef"; done
    fi
  fi

  # ---- 协议（多选）
  local names=(reality reality-xhttp hy2 cdn-xhttp cdn-ws)
  local descs=("VLESS + Vision + REALITY  TCP（必选）"
               "XHTTP + REALITY           同端口备用"
               "Hysteria2                 UDP"
               "XHTTP + TLS 经 Cloudflare CDN（IP 被墙后仍可用）"
               "WS + TLS 经 Cloudflare CDN（兼容老客户端，Xray 已标记过时）")
  local max=5; (( NODOMAIN )) && max=3      # 无域名不能用 CDN（4、5）
  local def="1 2 3 4 5"
  (( NODOMAIN )) && def="1 2 3"
  if [[ -n $PROTO ]]; then
    def=""
    for ((i=0; i<max; i++)); do [[ ",${PROTO,,}," == *",${names[i]},"* ]] && def+="$((i+1)) "; done
    def=${def% }; [[ -n $def ]] || def=1
  elif (( NO_HY2 )); then def="1 2 4 5"; (( NODOMAIN )) && def="1 2"
  fi
  echo
  echo "选择要部署的协议（多个编号用空格分隔）："
  for ((i=0; i<max; i++)); do printf '  %d) %-14s %s\n' $((i+1)) "${names[i]}" "${descs[i]}"; done
  while :; do
    read -rp "请输入编号 [默认 $def]: " ans || true
    ans=${ans:-$def}; ans=${ans//,/ }
    PROTO="" ok=1
    for c in $ans; do
      [[ $c =~ ^[0-9]$ ]] && (( c >= 1 && c <= max )) || { ok=0; break; }
      [[ ",$PROTO," == *",${names[c-1]},"* ]] || PROTO+="${PROTO:+,}${names[c-1]}"
    done
    (( ok )) || { red "  只能输入 1-$max"; continue; }
    [[ ",$PROTO," == *",reality,"* ]] || { red "  1) reality 必选（它是 TCP 入口，CDN 回源也经过它）"; continue; }
    break
  done
  NO_HY2=0   # 以上面选的协议为准

  # ---- CDN 域名：选了 4 / 5 才问
  if [[ $PROTO == *cdn-* ]]; then
    echo
    ylw "CDN 域名：Cloudflare【橙色云朵】，A 记录指向本机，必须和主域名不同"
    local cdef=$CDN; CDN=""
    while [[ -z $CDN ]]; do ask CDN "CDN 域名" "$cdef"; done
  else
    CDN=""
  fi

  # ---- 端口
  echo
  local rnote=""; [[ -n $CDN ]] && rnote="（用 CDN 时要在 Cloudflare 加 Origin Rule 改回源端口）"
  choose c "Reality TCP 端口：" "$( [[ -n $RPORT && $RPORT != 443 ]] && echo 3 || echo 1)" \
    "443（推荐）" "随机 40001-60000$rnote" "自定义$rnote"
  case $c in
    1) RPORT=443 ;;
    2) RPORT=$(rand_port tcp); echo "  随机到 TCP $RPORT" ;;
    3) ask RPORT "Reality TCP 端口" "${RPORT:-8443}" ;;
  esac

  # ---- Hysteria2
  if [[ $PROTO == *hy2* ]]; then
    echo
    choose c "Hysteria2 UDP 端口：" "$( [[ -n $HPORT && $HPORT != 443 ]] && echo 3 || echo 1)" \
      "443（推荐，和 Reality 同端口，一个 TCP 一个 UDP）" "随机 40001-60000" "自定义"
    case $c in
      1) HPORT=443 ;;
      2) HPORT=$(rand_port udp); echo "  随机到 UDP $HPORT" ;;
      3) ask HPORT "Hysteria2 UDP 端口" "${HPORT:-8443}" ;;
    esac
    echo
    local hdef=1; [[ $HOP == off ]] && hdef=2; [[ -n $HOP && $HOP != off && $HOP != 20000-40000 ]] && hdef=3
    choose c "端口跳跃（把一段 UDP 端口转到 Hysteria2，抗 UDP 限速）：" "$hdef" \
      "开启，20000-40000（推荐）" "关闭" "自定义范围"
    case $c in
      1) HOP=20000-40000 ;;
      2) HOP=off ;;
      3) ask HOP "端口跳跃范围，如 30000-50000" "${HOP:-30000-50000}" ;;
    esac
    echo
    local odef=1
    [[ $OBFS == 1 || ( -z $OBFS && $NODOMAIN == 1 ) ]] && odef=2
    if (( NODOMAIN )); then
      choose c "salamander 混淆：" $odef \
        "不开（像 HTTP/3，但证书是自签的，主动探测能看出来）" "开启（推荐：没有 SNI、证书和 QUIC 特征）"
    else
      choose c "salamander 混淆：" $odef \
        "不开（推荐：看起来像正常 HTTP/3）" "开启（不再像 HTTP/3；UDP 被 QoS 时可能有用）"
    fi
    OBFS=$(( c == 2 ))
  fi

  # ---- 节点名 / 国旗
  echo
  local ndef=${DOMAIN%%.*}; [[ -n $ndef ]] || ndef=node
  ask NODE "节点名前缀" "${NODE:-$ndef}"
  echo
  local rdef=1
  case ${REGION,,} in us) rdef=2 ;; jp) rdef=3 ;; none) rdef=4 ;; "") ;; *) rdef=5 ;; esac
  choose c "节点名前的国旗：" "$rdef" "按本机 IP 自动识别" "🇺🇸 美国 us" "🇯🇵 日本 jp" "不加国旗" "其他（输入两位国家代码）"
  case $c in
    1) REGION="" ;;
    2) REGION=us ;;
    3) REGION=jp ;;
    4) REGION=none ;;
    5) ask REGION "两位国家代码，如 hk、sg、de" "${REGION:-hk}" ;;
  esac

  # ---- 凭据
  if [[ -f $STATE ]] && (( ! RESET )); then
    echo
    choose c "已有上次部署的凭据（UUID / 密钥 / 密码）：" 1 "沿用（客户端不用改）" "重新生成（旧节点全部失效）"
    RESET=$(( c == 2 ))
  fi

  if (( ! NODOMAIN )); then
    echo
    ask EMAIL "证书邮箱" "${EMAIL:-admin@$DOMAIN}"
  fi

  # ---- 确认
  echo
  grn "== 确认 =="
  if (( NODOMAIN )); then
    echo "  无域名：节点地址用本机 IP，Reality 借用 ${RSNI:-（部署时扫描同网段）}    Reality 端口：$RPORT"
  else
    echo "  主域名：$DOMAIN    Reality 端口：$RPORT"
  fi
  echo "  协议：${PROTO//,/ }"
  [[ -n $CDN ]] && echo "  CDN 域名：$CDN"
  [[ $PROTO == *hy2* ]] && echo "  Hysteria2：UDP $HPORT，端口跳跃 ${HOP/off/关闭}，混淆 $( (( OBFS )) && echo 开 || echo 关)"
  echo "  节点名：$NODE    国旗：${REGION:-自动识别}    凭据：$( (( RESET )) && echo 重新生成 || echo 沿用)"
  echo
  choose c "开始部署？" 1 "开始" "退出"
  (( c == 1 )) || exit 0
}

# ------------------------------------------------------------ 自身安装 ----
# fetch_self 输出文件：从 GitHub 下载最新脚本（有 Token 就带上，私有仓库也能下）
fetch_self(){
  local out=$1 tok=${GH_TOKEN:-} code
  [[ -z $tok && -s $GH_TOKEN_FILE ]] && tok=$(tr -d ' \r\n' < "$GH_TOKEN_FILE")
  local -a hdr=()
  [[ -n $tok ]] && hdr=(-H "Authorization: Bearer $tok")
  code=$(curl -sSL --max-time 30 "${hdr[@]}" -o "$out" -w '%{http_code}' "$SELF_URL" || true)
  if [[ $code != 200 ]]; then
    red "下载脚本失败（HTTP ${code:-无响应}）：$SELF_URL"
    if [[ $code == 404 && -z $tok ]]; then
      ylw "仓库是私有的话：在 GitHub 创建 fine-grained token（只选这个仓库，Contents: Read），然后"
      ylw "  echo '你的token' > $GH_TOKEN_FILE && chmod 600 $GH_TOKEN_FILE"
    fi
    return 1
  fi
  grep -q '^XRAY_DEFAULT_VERSION=' "$out" && bash -n "$out" || { red "下载到的内容不是有效的 node-setup.sh"; return 1; }
}

# 把脚本装成 node-setup 命令。直接运行的文件就复制它；bash <(curl ...) 这种读不回来，就重新下载
install_self(){
  local src=${BASH_SOURCE[0]} tmp
  if [[ -f $src && $(readlink -f "$src") == "$SELF_BIN" ]]; then return 0; fi
  if [[ -f $src ]]; then
    install -m 755 "$src" "$SELF_BIN"
  else
    tmp=$(mktemp); fetch_self "$tmp" && install -m 755 "$tmp" "$SELF_BIN" || { rm -f "$tmp"; ylw "  没能装成 node-setup 命令（不影响节点）"; return 0; }
    rm -f "$tmp"
  fi
  grn "  已安装命令：node-setup（以后直接运行 node-setup；更新脚本：node-setup update）"
}

do_update(){
  grn "从 GitHub 更新脚本：$SELF_URL"
  local tmp; tmp=$(mktemp)
  fetch_self "$tmp" || { rm -f "$tmp"; exit 1; }
  if [[ -f $SELF_BIN ]] && cmp -s "$tmp" "$SELF_BIN"; then
    rm -f "$tmp"; grn "已经是最新版"; return 0
  fi
  install -m 755 "$tmp" "$SELF_BIN"; rm -f "$tmp"
  grn "已更新 $SELF_BIN（Xray 默认版本：$(sed -n 's/^XRAY_DEFAULT_VERSION=\([^ ]*\).*/\1/p' "$SELF_BIN")）"
  ylw "节点配置没有变；要让新版脚本的改动生效，运行 node-setup redeploy 重新部署（设置和凭据都沿用，不用输入）"
}

# ------------------------------------------------------ 沿用上次的设置 ----
# 部署成功后把设置写进 $DEPLOY；node-setup redeploy（或菜单第 1 项）读回来，不再提问。
# Cloudflare Token 不另存：acme.sh 为了续期已经存在 /root/.acme.sh/account.conf，从那里读。
save_deploy(){
  local proto=${PROTOS// /,}
  ( umask 077
    printf 'D_%s=%q\n' DOMAIN "$DOMAIN" CDN "$CDN" NODOMAIN "$NODOMAIN" RSNI "$RSNI_USER" PROTO "$proto" \
      RPORT "$RPORT" HPORT "$HPORT" HOP "${HOP:-off}" OBFS "$OBFS" HTTP01 "$HTTP01" \
      EMAIL "$EMAIL" NODE "$NODE" REGION "$REGION" > "$DEPLOY" )
}

# 旧版脚本部署的机器没有 $DEPLOY：从上次的节点信息里还原（还原不出来就返回 1，走向导）
guess_deploy(){
  local r h name
  D_DOMAIN=$(bash -c 'source "$1" 2>/dev/null; echo "${SAVED_DOMAIN:-}"' _ "$STATE")
  D_CDN=$(bash -c 'source "$1" 2>/dev/null; echo "${SAVED_CDN:-}"' _ "$STATE")
  [[ -n $D_DOMAIN ]] || D_NODOMAIN=1
  r=$(grep -m1 -- '-reality", type: vless' "$INFO") || return 1
  D_RPORT=$(sed -n 's/.*, port: \([0-9]*\),.*/\1/p' <<<"$r")
  name=$(sed -n 's/.*{name: "\(.*\)-reality", type.*/\1/p' <<<"$r")
  [[ -n $D_RPORT && -n $name ]] || return 1
  # 名字前面的国旗（两个区域指示符，各 4 字节 F0 9F 87 xx）还原成国家代码；没有国旗就是 none
  local hex; hex=$(printf '%s' "${name%% *}" | od -An -tx1 | tr -d ' \n')
  if [[ $name == *" "* && $hex =~ ^f09f87([0-9a-f]{2})f09f87([0-9a-f]{2})$ ]]; then
    printf -v D_REGION "\\x%02x\\x%02x" $(( 0x${BASH_REMATCH[1]} - 0xA6 + 97 )) $(( 0x${BASH_REMATCH[2]} - 0xA6 + 97 ))
    printf -v D_REGION "$D_REGION"
    name=${name#* }
  else D_REGION=none
  fi
  D_NODE=$name
  D_PROTO=reality
  grep -q -- '-reality-xhttp", type' "$INFO" && D_PROTO+=,reality-xhttp
  if h=$(grep -m1 -- '-hysteria2", type' "$INFO"); then
    D_PROTO+=,hy2
    D_HPORT=$(sed -n 's/.*, port: \([0-9]*\),.*/\1/p' <<<"$h")
    D_HOP=$(sed -n 's/.*, ports: \([0-9]*-[0-9]*\),.*/\1/p' <<<"$h"); D_HOP=${D_HOP:-off}
    [[ $h == *"obfs: salamander"* ]] && D_OBFS=1 || D_OBFS=0
  fi
  grep -q -- '-cdn-xhttp", type' "$INFO" && D_PROTO+=,cdn-xhttp
  grep -q -- '-cdn-ws", type' "$INFO" && D_PROTO+=,cdn-ws
  # 证书上次是用 80 端口验证的（--http01）
  if (( ! D_NODOMAIN )) && grep -qs "^Le_Webroot='/" /root/.acme.sh/*/*.conf; then D_HTTP01=1; fi
  return 0
}

has_saved(){ [[ -s $DEPLOY || ( -s $STATE && -s $INFO ) ]]; }

# 命令行里给了的参数优先，没给的用上次的
load_deploy(){
  local D_DOMAIN="" D_CDN="" D_NODOMAIN=0 D_RSNI="" D_PROTO="" D_RPORT="" D_HPORT="" D_HOP="" D_OBFS="" \
        D_HTTP01=0 D_EMAIL="" D_NODE="" D_REGION=""
  if [[ -s $DEPLOY ]]; then
    # shellcheck disable=SC1090
    source "$DEPLOY"
  elif [[ -s $STATE && -s $INFO ]]; then guess_deploy || return 1
  else return 1
  fi
  if [[ -z $DOMAIN && $NODOMAIN -eq 0 ]]; then
    DOMAIN=$D_DOMAIN NODOMAIN=$D_NODOMAIN
    [[ -n $CDN ]] || CDN=$D_CDN
    [[ -n $RSNI ]] || RSNI=$D_RSNI
    if [[ -z $PROTO ]]; then
      PROTO=$D_PROTO
      if (( NO_HY2 )); then PROTO=${PROTO//,hy2/}; NO_HY2=0; fi
    fi
  fi
  [[ -n $RPORT ]] || RPORT=$D_RPORT
  [[ -n $HPORT ]] || HPORT=$D_HPORT
  [[ -n $HOP ]] || HOP=$D_HOP
  [[ -n $OBFS ]] || OBFS=$D_OBFS
  [[ -n $EMAIL ]] || EMAIL=$D_EMAIL
  [[ -n $NODE ]] || NODE=$D_NODE
  [[ -n $REGION ]] || REGION=$D_REGION
  (( D_HTTP01 )) && HTTP01=1
  [[ -n $DOMAIN ]] || (( NODOMAIN )) || return 1
  if [[ -z $CF_TOKEN && $HTTP01 -eq 0 && $NODOMAIN -eq 0 ]]; then
    CF_TOKEN=$(sed -n "s/^SAVED_CF_Token='\(.*\)'\$/\1/p" /root/.acme.sh/account.conf 2>/dev/null | sed -n 1p || true)
  fi
  grn "沿用上次的设置：$( (( NODOMAIN )) && echo "无域名" || echo "$DOMAIN${CDN:+ + $CDN}")，协议 ${PROTO//,/ }，凭据$( (( RESET )) && echo 重新生成 || echo 不变)"
  return 0
}

# 不带任何参数运行时的主菜单
main_menu(){
  echo
  grn "== node-setup.sh =="
  local c
  if has_saved; then
    choose c "要做什么？" 1 "重新部署（沿用上次的设置和凭据，不用再输入）" "改设置后部署（重新走向导）" \
      "查看节点信息" "更新脚本" "卸载" "退出"
    (( c == 1 )) && { CMD=redeploy; return 0; }
    c=$(( c - 1 ))
  else
    choose c "要做什么？" 1 "部署" "查看节点信息" "更新脚本" "卸载" "退出"
  fi
  case $c in
    1) CMD=install ;;
    2) CMD=info ;;
    3) CMD=update ;;
    4) CMD=uninstall ;;
    5) exit 0 ;;
  esac
}

# 把 --proto / --no-hy2 / -c 解析成 P_RX P_CX P_CW 和 NO_HY2
resolve_proto(){
  P_RX=0 P_CX=0 P_CW=0
  local list=$PROTO p have_r=0 hy=0
  if [[ -z $list ]]; then
    list="reality,reality-xhttp"
    (( NO_HY2 )) || list+=",hy2"
    [[ -n $CDN ]] && list+=",cdn-xhttp,cdn-ws"
  fi
  IFS=', ' read -ra _ps <<<"${list,,}"
  for p in "${_ps[@]}"; do
    case $p in
      "") ;;
      reality|vision)          have_r=1 ;;
      reality-xhttp|rx)        P_RX=1 ;;
      hy2|hysteria2|hysteria)  hy=1 ;;
      cdn-xhttp|cx)            P_CX=1 ;;
      cdn-ws|ws|cw)            P_CW=1 ;;
      *) die "未知协议：$p（可选：reality, reality-xhttp, hy2, cdn-xhttp, cdn-ws）" ;;
    esac
  done
  (( have_r )) || die "reality 必须保留：它是 TCP 入口（CDN 回源也经它转给 nginx）"
  if [[ -n $PROTO ]]; then
    (( NO_HY2 && hy )) && die "--no-hy2 和 --proto 里的 hy2 冲突"
    (( hy )) && NO_HY2=0 || NO_HY2=1
  fi
  if (( P_CX || P_CW )); then
    (( ! NODOMAIN )) || die "无域名模式不能用 cdn-xhttp / cdn-ws（CDN 需要自己的域名）"
    [[ -n $CDN ]] || die "选了 cdn-xhttp / cdn-ws，但没给 CDN 域名（-c）"
  elif [[ -n $CDN ]]; then
    die "给了 CDN 域名 $CDN，但 --proto 里没有 cdn-xhttp / cdn-ws（不要 CDN 就去掉 -c）"
  fi
  PROTOS="reality"
  (( P_RX )) && PROTOS+=" reality-xhttp"
  (( NO_HY2 )) || PROTOS+=" hy2"
  (( P_CX )) && PROTOS+=" cdn-xhttp"
  (( P_CW )) && PROTOS+=" cdn-ws"
  grn "  部署协议：$PROTOS"
}

# Token 不放在命令行参数里也行：环境变量 CF_Token 或这里隐藏输入
ask_token(){
  (( HTTP01 || NODOMAIN )) && return 0
  [[ -n $CF_TOKEN ]] && return 0
  [[ -t 0 ]] || die "缺少 Cloudflare API Token：用环境变量 CF_Token 或 --cf-token 传入（或加 --http01）"
  echo
  ylw "需要 Cloudflare API Token 来申请通配符证书（DNS 验证）。"
  ylw "创建：Cloudflare → 我的个人资料 → API 令牌 → 创建令牌 → 自定义"
  ylw "  权限：区域 → 区域 → 读取；区域 → DNS → 编辑。区域资源：只选你的域名。"
  read -rsp "Cloudflare API Token（输入不显示）: " CF_TOKEN || true; echo
  [[ -n $CF_TOKEN ]] || die "没有输入 Token（不想用 Token 可加 --http01）"
}

validate(){
  local re='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  if (( NODOMAIN )); then
    [[ -z $DOMAIN ]] || die "-d 和 --no-domain / --target 不能同时用"
    [[ -z $CDN ]] || die "无域名模式不能部署 CDN（-c 需要自己的域名）"
    RSNI=${RSNI,,}
    [[ -z $RSNI || $RSNI =~ $re ]] || die "借用的网站域名格式不对：$RSNI"
    NODE=${NODE:-node}
  else
    [[ -n $DOMAIN ]] || die "缺少 -d 主域名（没有域名用 --no-domain）"
    [[ -z $RSNI ]] || die "-d 和 --target 不能同时用（--target 只用于无域名模式）"
    [[ $DOMAIN =~ $re ]] || die "主域名格式不对：$DOMAIN"
    [[ -z $CDN || $CDN =~ $re ]] || die "CDN 域名格式不对：$CDN"
    [[ $DOMAIN != "$CDN" ]] || die "主域名和 CDN 域名必须不同（一个灰云、一个橙云）"
    [[ -z $CF_TOKEN || $CF_TOKEN =~ ^[A-Za-z0-9_-]+$ ]] || die "Cloudflare Token 格式不对"
    EMAIL=${EMAIL:-admin@$DOMAIN}
    NODE=${NODE:-${DOMAIN%%.*}}
  fi
  RPORT=${RPORT:-443}; HPORT=${HPORT:-443}; HOP=${HOP:-20000-40000}
  REGION=${REGION,,}
  [[ -z $REGION || $REGION == none || $REGION =~ ^[a-z]{2}$ ]] || die "国家代码不对：$REGION（两位字母，如 us、jp；none 不加国旗）"
  local p
  for p in "$RPORT" "$HPORT"; do
    [[ $p =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || die "端口不对：$p"
  done
  [[ $RPORT != 80 && $RPORT != "$TARGET_PORT" && $RPORT != "$HTTPS_PORT" && $RPORT != "$REJECT_PORT" ]] \
    || die "Reality 端口不能用 80 / $TARGET_PORT-$REJECT_PORT"
  [[ $HOP == off ]] && HOP=""
  if [[ -n $HOP ]]; then
    [[ $HOP =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535 )) \
      || die "端口跳跃范围格式应为 20000-40000：$HOP"
  fi
  resolve_proto
  # 混淆默认：有域名不开（像正常 HTTP/3）；无域名开（自签证书经不起主动探测）
  [[ -n $OBFS ]] || OBFS=$NODOMAIN
  (( NO_HY2 )) && { HOP=""; OBFS=0; }
  # Reality 的 target / SNI：有域名偷自己（本机 nginx）；无域名偷别人，在 check_dns 里选定
  # Hysteria2：有域名用主域名的真证书；无域名不发 SNI，自签证书只写本机 IP，不冒充别人的域名
  if (( NODOMAIN )); then R_DEST="" R_SNI="" HY_SNI=""
  else R_DEST="127.0.0.1:$TARGET_PORT" R_SNI=$DOMAIN HY_SNI=$DOMAIN
  fi
  HY_FP=""
  if [[ -n $CDN && $RPORT != 443 ]]; then
    ylw "注意：Reality 端口不是 443，Cloudflare 回源默认连 443。"
    ylw "      需要在 Cloudflare → Rules → Origin Rules 把 $CDN 的回源端口改成 $RPORT。"
  fi
}

# ---------------------------------------------------------------- 工具 ----
public_ip(){ curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://ifconfig.me || true; }
# 本机 IP 所在国家的两位代码（小写），识别不到输出空
ip_country(){
  local c
  c=$(curl -4 -s --max-time 5 https://ipinfo.io/country || curl -4 -s --max-time 5 https://ifconfig.co/country-iso || true)
  c=${c//[$'\r\n ']/}
  [[ $c =~ ^[A-Za-z]{2}$ ]] && echo "${c,,}" || true
}

# set_flag 国家代码 → FLAG（国旗 emoji + 空格）和 FLAG_URI（分享链接 # 后面用的百分号编码）
# 国旗 = 两个区域指示符 U+1F1E6+n，UTF-8 是 F0 9F 87 (A6+n)
set_flag(){
  FLAG="" FLAG_URI=""
  [[ $1 =~ ^[a-z]{2}$ ]] || return 0
  local i ch hex
  for i in 0 1; do
    ch=$(printf '%d' "'${1:i:1}")
    printf -v hex '%02X' $(( 0xA6 + ch - 97 ))
    FLAG+=$(printf "\\xF0\\x9F\\x87\\x$hex")
    FLAG_URI+="%F0%9F%87%$hex"
  done
  FLAG+=" " FLAG_URI+="%20"
}

has_v6(){ [[ -s /proc/net/if_inet6 ]]; }
ver_ge(){ [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n 1p) == "$2" ]]; }   # ver_ge 当前 要求

preflight(){
  [[ $EUID -eq 0 ]] || die "请用 root 或 sudo 运行"
  # acme.sh 检测到 sudo 环境变量会拒绝运行；脚本已经是 root，清掉即可
  unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
  export HOME=/root
  grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release || die "只支持 Debian / Ubuntu"
  case $(uname -m) in x86_64|aarch64) ;; *) die "不支持的架构 $(uname -m)" ;; esac
  command -v systemctl >/dev/null || die "需要 systemd"
}

install_deps(){
  grn "[1/9] 安装依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  local -a pkgs=(curl wget jq openssl iptables ca-certificates)
  (( NODOMAIN )) || pkgs+=(nginx cron socat)        # 无域名模式不需要 nginx 和 acme.sh
  apt-get install -y -qq "${pkgs[@]}" >/dev/null
  # CDN 源站隐藏要用 nginx 的 stream 模块；装不上不算失败，probe_stream 会退回旧方式
  [[ -z $CDN ]] || apt-get install -y -qq libnginx-mod-stream >/dev/null 2>&1 || true
  systemctl enable --now cron >/dev/null 2>&1 || true
}

cf_api(){ curl -sS --max-time 20 -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/$1"; }

# cf_zone 域名 → 输出 "zone_id zone名"
cf_zone(){
  local n=$1 r id
  while [[ $n == *.* ]]; do
    r=$(cf_api "zones?name=$n") || die "连不上 Cloudflare API"
    jq -e '.success' >/dev/null 2>&1 <<<"$r" \
      || die "Cloudflare API 报错：$(jq -r '.errors[0].message // "未知错误"' <<<"$r" 2>/dev/null)（检查 Token 是否有 区域:读取 + DNS:编辑 权限）"
    id=$(jq -r '.result[0].id // empty' <<<"$r")
    [[ -n $id ]] && { echo "$id $n"; return 0; }
    n=${n#*.}
  done
  return 1
}

# cf_check 域名 zone_id 期望(gray|orange)
cf_check(){
  local d=$1 zid=$2 want=$3 r hit proxied
  r=$(cf_api "zones/$zid/dns_records?type=A&name=$d") || die "连不上 Cloudflare API"
  jq -e '.success' >/dev/null 2>&1 <<<"$r" \
    || die "读取 $d 的 DNS 记录失败：$(jq -r '.errors[0].message // "未知错误"' <<<"$r" 2>/dev/null)"
  hit=$(jq --arg ip "$IP" '[.result[]? | select(.content==$ip)] | length' <<<"$r")
  if (( hit == 0 )); then
    red "$d 在 Cloudflare 没有指向本机 $IP 的 A 记录。"
    die "请添加 A 记录：$d → $IP（$([[ $want == gray ]] && echo 灰色云朵 || echo 橙色云朵)），然后重跑。"
  fi
  proxied=$(jq -r --arg ip "$IP" '[.result[] | select(.content==$ip)][0].proxied' <<<"$r")
  if [[ $want == gray && $proxied == true ]]; then
    die "$d 现在是橙色云朵。Reality / Hysteria2 必须直连，请改成【灰色云朵】后重跑。"
  fi
  if [[ $want == orange && $proxied != true ]]; then
    ylw "  $d 现在是灰色云朵：真实 IP 会公开在 DNS 里。建议改成【橙色云朵】（现在申请证书不需要灰云了）。"
  fi
}

check_dns(){
  IP=$(public_ip); [[ -n $IP ]] || die "获取不到本机公网 IPv4"
  SERVER=${DOMAIN:-$IP}                      # 客户端连接的地址
  if (( NODOMAIN )); then
    grn "  无域名模式：节点地址用本机 IP $IP"
    select_target
    return 0
  fi
  if (( ! HTTP01 )); then
    local z
    z=$(cf_zone "$DOMAIN") || die "Token 看不到 $DOMAIN 所在的域名（区域），检查 Token 的区域资源范围"
    ZONE_MAIN=${z#* }; cf_check "$DOMAIN" "${z%% *}" gray
    if [[ -n $CDN ]]; then
      z=$(cf_zone "$CDN") || die "Token 看不到 $CDN 所在的域名（区域）"
      ZONE_CDN=${z#* }; cf_check "$CDN" "${z%% *}" orange
    fi
    grn "  本机 $IP，Cloudflare DNS 记录检查通过"
    return 0
  fi
  local r
  r=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
  if [[ $r != "$IP" ]]; then
    red "$DOMAIN 解析到 ${r:-空}，不是本机 $IP。"
    die "请在 Cloudflare 把它设为【灰色云朵】（仅 DNS）并指向 $IP，生效后重跑。"
  fi
  if [[ -n $CDN ]]; then
    r=$(getent ahostsv4 "$CDN" | awk 'NR==1{print $1}' || true)
    if [[ -z $r ]]; then die "$CDN 没有解析，请先添加 A 记录指向 $IP（灰色云朵）"
    elif [[ $r != "$IP" ]]; then
      ylw "$CDN 解析到 $r（可能已是橙色云朵）。经 Cloudflare 也能申请证书，"
      ylw "但如果开了 Always Use HTTPS 失败，请先改回灰色云朵再跑。"
    fi
  fi
  grn "  本机 $IP，域名解析检查通过"
}

# --------------------------------------------- 无域名：选 Reality 借用的网站 ----
# probe_target 域名 [IP]：检查能否借用。能用返回 0；不能用输出原因、返回 1
#   TLS 1.3 + X25519 + HTTP/2（Reality 的握手特征要对得上）、证书有效且和域名相符、首页不跳到别的域名
probe_target(){
  local d=$1 ip=${2:-$1} out r code loc host
  out=$(timeout 6 openssl s_client -connect "$ip:443" -servername "$d" -verify_hostname "$d" \
        -tls1_3 -groups X25519 -alpn h2 </dev/null 2>&1 || true)
  grep -qE '^(New|Reused), TLSv1\.3' <<<"$out" || { echo "连不上，或不支持 TLS 1.3 + X25519"; return 1; }
  grep -q 'ALPN protocol: h2' <<<"$out"        || { echo "不支持 HTTP/2"; return 1; }
  grep -q 'Verify return code: 0 ' <<<"$out"   || { echo "证书无效或和域名不符"; return 1; }
  r=$(curl -s -o /dev/null --max-time 6 --connect-to "$d:443:$ip:443" -w '%{http_code} %{redirect_url}' "https://$d/" || true)
  code=${r%% *} loc=${r#* }
  [[ $code =~ ^[1-5][0-9][0-9]$ ]] || { echo "HTTPS 请求失败"; return 1; }
  if [[ $code == 3* && -n $loc ]]; then
    host=${loc#*://}; host=${host%%[/:?#]*}
    [[ ${host,,} == "${d,,}" ]] || { echo "首页跳转到别的域名 $host"; return 1; }
  fi
  return 0
}

# probe_ip IP：不带 SNI 连过去，从默认证书里取一个具体域名，能借用就输出 "域名 IP"
probe_ip(){
  local ip=$1 out n
  out=$(timeout 4 openssl s_client -connect "$ip:443" -tls1_3 -groups X25519 -alpn h2 </dev/null 2>/dev/null || true)
  grep -qE '^(New|Reused), TLSv1\.3' <<<"$out" || return 0
  for n in $( { openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null <<<"$out" | sed -n 's/^ *CN=//p'
                openssl x509 -noout -ext subjectAltName 2>/dev/null <<<"$out" | tr ',' '\n' | sed -n 's/^ *DNS://p'; } \
              | grep -v '^\*' | grep -vE '^[0-9.]+$' | awk '!s[$0]++' | head -n 3); do
    [[ $n == *.* ]] || continue
    probe_target "$n" "$ip" >/dev/null && { echo "$n $ip"; return 0; }
  done
  return 0
}

# scan_neighbors：并发扫描本机所在 /24 的其他 IP，输出 "域名 IP"
scan_neighbors(){
  local base=${IP%.*} me=${IP##*.}
  export -f probe_ip probe_target
  seq 1 254 | grep -vx "$me" | sed "s/^/$base./" \
    | xargs -P 32 -I{} bash -c 'probe_ip "$1"' _ {} 2>/dev/null | sort -u -k1,1 || true
}

saved_target(){ [[ -f $STATE ]] && bash -c 'source "$1" 2>/dev/null; echo "${SAVED_RSNI:-} ${SAVED_RDEST:-}"' _ "$STATE" || true; }

# 定下 RSNI（SNI）和 R_DEST（Reality 转发的目标）
select_target(){
  local why sv sd c i
  if [[ -n $RSNI ]]; then                                   # 手动指定
    why=$(probe_target "$RSNI") || die "$RSNI 不能借用：$why（换一个，或去掉 --target 自动扫描）"
    R_DEST=$RSNI:443
    grn "  Reality 借用 $RSNI（TLS 1.3 + X25519 + HTTP/2，证书有效）"
    ylw "  手动指定的网站一般和 VPS 不在同一机房，SNI 和 IP 对不上，风险比自动扫描的高"
  else
    read -r sv sd <<<"$(saved_target)"
    if (( ! RESET )) && [[ -n $sv && -n $sd ]]; then        # 沿用上次扫到的，客户端不用改
      if why=$(probe_target "$sv" "${sd%:443}"); then
        RSNI=$sv R_DEST=$sd
        grn "  沿用上次的借用网站：$RSNI（$R_DEST）"
      else
        ylw "  上次借用的 $sv 不能用了：$why。重新扫描（SNI 会变，客户端要重新导入）"
      fi
    fi
    if [[ -z $RSNI ]]; then
      ylw "  扫描同网段 ${IP%.*}.0/24：找支持 TLS 1.3 + HTTP/2 + X25519、证书有效、不跳转的网站（约 1 分钟）"
      local -a found=()
      mapfile -t found < <(scan_neighbors | head -n 15)
      if (( ${#found[@]} )); then
        if [[ -t 0 ]]; then
          local -a opts=()
          for i in "${found[@]}"; do opts+=("${i% *}（${i#* }）"); done
          choose c "选择 Reality 借用的网站（同网段邻居）：" 1 "${opts[@]}" "手动输入"
        else c=1
        fi
        if (( c <= ${#found[@]} )); then
          RSNI=${found[c-1]% *} R_DEST=${found[c-1]#* }:443
          grn "  Reality 借用 $RSNI（$R_DEST，同网段）"
        fi
      else
        ylw "  同网段没有扫到能借用的网站"
        [[ -t 0 ]] || die "请用 --target 手动指定一个支持 TLS 1.3 + HTTP/2 的网站"
      fi
    fi
    while [[ -z $RSNI ]]; do                                # 没扫到，或选了手动输入
      ask RSNI "借用的网站域名（不要用 www.microsoft.com 这类被大量使用的网站）" ""
      RSNI=${RSNI,,}
      [[ -n $RSNI ]] || continue
      if why=$(probe_target "$RSNI"); then R_DEST=$RSNI:443
      else red "  $RSNI 不能借用：$why"; RSNI=""; fi
    done
  fi
  R_SNI=$RSNI
}

check_ports(){
  local busy
  local p80=":80$" ptg=":($TARGET_PORT|$HTTPS_PORT|$REJECT_PORT)$"
  (( NODOMAIN )) && p80='^$' ptg='^$'          # 无域名模式不用 nginx，只看 Reality 端口
  busy=$(ss -tlnpH 2>/dev/null | awk -v a="$p80" -v b=":$RPORT$" -v c="$ptg" '$4~a||$4~b||$4~c' \
         | grep -vE '"(nginx|xray)"' || true)
  if (( ! NO_HY2 )); then
    busy+=$(ss -ulnpH 2>/dev/null | awk -v a=":$HPORT$" '$4~a' | grep -v '"hysteria"' || true)
  fi
  if [[ -n $busy ]]; then
    red "以下端口被其他程序占用（TCP 80 / $RPORT / $TARGET_PORT-$REJECT_PORT，UDP ${HPORT}）："
    echo "$busy"
    die "请先停掉它（例如 systemctl disable --now caddy apache2），或运行 node-setup uninstall（还没装成命令就用 bash $0 uninstall）卸载其他代理，再重新运行。"
  fi
}

# 沿用上次生成的凭据，避免重跑后客户端全部失效
load_or_gen_state(){
  if [[ -f $STATE && $RESET -eq 0 ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
  fi
  local X=/usr/local/bin/xray keys
  UUID=${UUID:-$($X uuid)}
  if [[ -z ${PRIV:-} || -z ${PUB:-} ]]; then
    keys=$($X x25519)
    # 旧版输出 "Private key/Public key"，新版输出 "PrivateKey/Password"
    PRIV=$(awk -F': *' 'tolower($1)~/^private/{print $2}' <<<"$keys" | tr -d ' \r')
    PUB=$(awk -F': *' 'tolower($1)~/^(public|password)/{print $2; exit}' <<<"$keys" | tr -d ' \r')
    [[ -n $PRIV && -n $PUB ]] || die "解析 xray x25519 输出失败：$keys"
  fi
  SID=${SID:-$(openssl rand -hex 8)}
  XPATH=${XPATH:-$(openssl rand -hex 8)}
  WSPATH=${WSPATH:-$(openssl rand -hex 8)}
  HY_PASS=${HY_PASS:-$(openssl rand -hex 16)}
  OBFS_PASS=${OBFS_PASS:-$(openssl rand -hex 16)}
  ( umask 077
    printf '%s=%q\n' UUID "$UUID" PRIV "$PRIV" PUB "$PUB" SID "$SID" XPATH "$XPATH" \
      WSPATH "$WSPATH" HY_PASS "$HY_PASS" OBFS_PASS "$OBFS_PASS" \
      SAVED_DOMAIN "$DOMAIN" SAVED_CDN "$CDN" SAVED_CERTS "$CERT_MAIN${CERT_CDN:+ $CERT_CDN}" \
      SAVED_RSNI "$( (( NODOMAIN )) && echo "$RSNI")" SAVED_RDEST "$( (( NODOMAIN )) && echo "$R_DEST")" > "$STATE" )
}

# ------------------------------------------------------- 清理旧配置冲突 ----
# 其他脚本（包括你以前的 la-setup.sh / reality-setup.sh）留下的东西可能和本脚本冲突：
#   1) 别的 nginx 站点监听公网 Reality 端口 / 18443 / UDP 端口（h3）→ Xray、Hysteria2 起不来
#   2) 别的 acme.sh 证书续期时把旧证书复制给 Hysteria2 → 覆盖掉新证书
# 自动停用并备份到 $WORKDIR/backup-时间/，不会直接删除

# nginx_listen_conflicts → 输出有冲突 listen 的配置文件
nginx_listen_conflicts(){
  local dump f="" line addr port flags ours_link=/etc/nginx/sites-enabled/proxy-node
  local -a tok
  local -A bad=()
  # nginx -T 能列出所有被 include 的文件；配置本身有错时退回到扫描常见目录
  if ! dump=$(nginx -T 2>/dev/null); then
    dump=$(for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
             if [[ -f $f ]]; then echo "# configuration file $f:"; cat "$f"; fi; done)
  fi
  local stmt
  local -a stmts
  while IFS= read -r line; do
    if [[ $line =~ ^#\ configuration\ file\ (.+):$ ]]; then f=${BASH_REMATCH[1]}; continue; fi
    line=${line%%#*}                                   # 去掉注释
    [[ $line == *listen* ]] || continue
    # 一行里可能有多条指令：server { listen 443 ssl; listen [::]:443; ... }
    IFS=$'\n' read -rd '' -a stmts < <(tr ';{}' '\n\n\n' <<<"$line") || true
    for stmt in "${stmts[@]}"; do
      read -ra tok <<<"$stmt"
      [[ ${tok[0]:-} == listen && -n ${tok[1]:-} ]] || continue
      addr=${tok[1]}
      [[ $addr == unix:* ]] && continue
      if [[ $addr == *:* ]]; then port=${addr##*:}; else port=$addr; fi
      [[ $port =~ ^[0-9]+$ ]] || continue
      flags=" ${tok[*]:2} "
      if [[ $flags == *" quic "* || $flags == *" udp "* ]]; then
        (( ! NO_HY2 )) && [[ $port == "$HPORT" ]] && bad[$f]=1
      elif [[ $port == "$RPORT" || $port == "$TARGET_PORT" || $port == "$HTTPS_PORT" || $port == "$REJECT_PORT" ]]; then
        bad[$f]=1
      fi
    done
  done <<<"$dump"
  for f in "${!bad[@]}"; do
    [[ $f == "$NGX_SITE" || $f == "$ours_link" || $f == "$NGX_STREAM" ]] || echo "$f"
  done
}

# acme_val 配置文件 键 → 值（acme.sh 会把 reloadcmd 存成 base64）
acme_val(){
  local v
  v=$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-) || true
  v=${v#\'}; v=${v%\'}
  if [[ $v == __ACME_BASE64__START_*__ACME_BASE64__END_ ]]; then
    v=${v#__ACME_BASE64__START_}; v=${v%__ACME_BASE64__END_}
    v=$(base64 -d <<<"$v" 2>/dev/null || true)
  fi
  printf '%s' "$v"
}

fix_conflicts(){
  grn "[检查] 旧配置冲突"
  local backup found=0 f
  backup=$WORKDIR/backup-$(date +%Y%m%d-%H%M%S)

  # 1) nginx 站点
  while read -r f; do
    [[ -n $f ]] || continue
    [[ $f == /etc/nginx/nginx.conf ]] && die "/etc/nginx/nginx.conf 里有 server 监听端口 $RPORT / $TARGET_PORT-$REJECT_PORT，请手动删掉那段后重跑"
    mkdir -p "$backup"; found=1
    if [[ -L $f ]]; then cp -L "$f" "$backup/$(basename "$f")"; rm -f "$f"
    else mv "$f" "$backup/"; fi
    ylw "  停用 nginx 站点 $f（它占用了 Xray / Hysteria2 要用的端口）"
  done < <(nginx_listen_conflicts)

  # 2) 会覆盖 Hysteria2 证书的旧 acme.sh 证书
  local d base name conf paths reload w hit script
  local -a words opt
  for d in /root/.acme.sh/*/; do
    [[ -d $d ]] || continue
    base=${d%/}; base=${base##*/}; name=${base%_ecc}; conf=$d$name.conf
    [[ -f $conf ]] || continue
    paths="$(acme_val "$conf" Le_RealFullChainPath) $(acme_val "$conf" Le_RealCertPath) $(acme_val "$conf" Le_RealKeyPath)"
    [[ $paths == *"$SSL/"* ]] && continue                       # 本脚本自己的证书
    reload=$(acme_val "$conf" Le_ReloadCmd)
    hit=0; script=""
    [[ $paths == *"/etc/hysteria/"* || $reload == *hysteria* ]] && hit=1
    read -ra words <<<"$reload"
    for w in "${words[@]}"; do                                   # reloadcmd 调用的脚本里是否操作 hysteria
      if [[ $w == /* && -f $w ]] && grep -q hysteria "$w" 2>/dev/null; then hit=1; script=$w; fi
    done
    (( hit )) || continue
    mkdir -p "$backup"; found=1
    opt=(); [[ $base == *_ecc ]] && opt=(--ecc)
    [[ -x $ACME ]] && { $ACME --remove -d "$name" "${opt[@]}" >/dev/null 2>&1 || true; }
    mv "${d%/}" "$backup/"
    [[ -n $script && $script != /usr/local/bin/proxy-node-cert-reload ]] && mv "$script" "$backup/"
    ylw "  移除旧证书 $name：它续期时会把旧证书复制给 Hysteria2${script:+（续期脚本 $script 一并移走）}"
  done

  if (( found )); then ylw "  已备份到 $backup"; else grn "  没有发现冲突"; fi
}

# ------------------------------------------------------------ nginx 站点 ----
setup_site_http(){
  if (( NODOMAIN )); then
    grn "[2/9] 无域名模式：不需要 nginx（Hysteria2 不开混淆时用本地伪装页）"
    write_web_index
    # 以前用域名部署过：本脚本的 nginx 站点已经没用了，移除
    if [[ -e $NGX_SITE || -e $NGX_STREAM || -L /etc/nginx/sites-enabled/proxy-node ]]; then
      rm -f /etc/nginx/sites-enabled/proxy-node "$NGX_SITE" "$NGX_STREAM"
      if systemctl is-active --quiet nginx 2>/dev/null; then nginx -t -q 2>/dev/null && systemctl reload nginx || true; fi
      ylw "  移除上次部署的 nginx 站点"
    fi
    return 0
  fi
  grn "[2/9] 配置伪装站点"
  write_web_index
  [[ -f /etc/nginx/nginx.conf ]] || die "nginx 安装不完整（缺 /etc/nginx/nginx.conf），请运行 apt-get install --reinstall nginx-common nginx 后重跑"
  grep -qE '^[^#]*include[[:space:]]+/etc/nginx/sites-enabled/' /etc/nginx/nginx.conf \
    || die "/etc/nginx/nginx.conf 没有加载 sites-enabled 目录（可能不是 Debian 自带的 nginx），请改用 apt 安装的 nginx"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default
  write_nginx 0
  ln -sf "$NGX_SITE" /etc/nginx/sites-enabled/proxy-node
  nginx -t -q
  probe_stream
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || { journalctl -u nginx -n 15 --no-pager; die "nginx 启动失败"; }
}

# CDN 源站隐藏：别人拿 CDN 域名当 SNI 直接连 VPS 的 IP，本来能拿到 CDN 域名的证书，
# 等于确认"这个 CDN 域名的源站就是这台机器"。做法：
#   Xray(Reality, xver=1) 把未授权连接连同真实来源 IP（PROXY protocol）交给 nginx stream，
#   stream 读 SNI：SNI 是 CDN 域名、来源又不是 Cloudflare → 转到只会拒绝握手的端口，
#   表现和连任何不存在的域名完全一样；其余照常交给 HTTPS 站点。
# 只在有 CDN 域名时启用；nginx 没有 stream 模块或版本太旧就退回旧方式（不隐藏）并提示。
probe_stream(){
  HIDE=0
  [[ -n $CDN ]] || return 0
  local ngv why=""
  ngv=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
  if ! ver_ge "$ngv" 1.19.4; then why="nginx $ngv 太旧（需要 1.19.4 以上）"
  elif ! grep -qE '^[^#]*include[[:space:]]+/etc/nginx/modules-enabled/' /etc/nginx/nginx.conf; then
    why="/etc/nginx/nginx.conf 没有加载 modules-enabled 目录"
  else
    mkdir -p "${NGX_STREAM%/*}"
    printf 'stream {\n  geo $proxy_protocol_addr $pn_cf { default 0; }\n  map "$pn_cf:$ssl_preread_server_name" $pn_backend { default 127.0.0.1:%s; }\n  server { listen 127.0.0.1:%s proxy_protocol; set_real_ip_from 127.0.0.1; ssl_preread on; proxy_protocol on; proxy_pass $pn_backend; }\n}\n' \
      "$HTTPS_PORT" "$TARGET_PORT" > "$NGX_STREAM"
    nginx -t -q 2>/dev/null || why="nginx 没有可用的 stream 模块（试试 apt-get install libnginx-mod-stream），或已有别的 stream 配置"
    rm -f "$NGX_STREAM"
  fi
  if [[ -n $why ]]; then
    ylw "  ⚠ 不启用 CDN 源站隐藏：$why"
    ylw "    CDN 线路照常可用，但拿 $CDN 当 SNI 直连本机 IP 能看到它的证书"
    return 0
  fi
  HIDE=1
  local got
  got=$(curl -fsS --max-time 8 https://www.cloudflare.com/ips-v4 2>/dev/null | tr -s '[:space:]' ' ' || true)
  if [[ $got =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}\ ?){8,40}$ ]]; then CF_V4=${got% }
  else ylw "  拿不到最新的 Cloudflare IP 段，用脚本内置的列表"; fi
  grn "  启用 CDN 源站隐藏（只有 Cloudflare 能以 $CDN 回源）"
}

# 伪装页：nginx 和 Hysteria2（masquerade）共用
# 已有页面就沿用（你自己放的站点也不会被覆盖）；--reset 或旧版那张固定的 "Field Notes" 页面会重新生成
write_web_index(){
  mkdir -p "$WEB"
  local f=$WEB/index.html
  if [[ -s $f ]] && (( ! RESET )) && ! grep -q '<title>Field Notes</title>' "$f"; then return 0; fi
  gen_site > "$f.tmp" && mv -f "$f.tmp" "$f"
  chmod 644 "$f"
}

# 每台机器随机生成一个小博客首页：站名 × 主题 × 文章 × 版式 × 字体 × 配色。
# 所有部署都用同一张页面的话，页面本身就成了能跨机器识别的指纹
gen_site(){
  local -a adj=(Quiet Small Slow Northern Paper Copper Late Open Plain Second Low Far Salt Green Winter Morning Narrow Borrowed Loose Stone Amber Hollow Tin Idle)
  local -a noun=(Harbor Notebook Orchard Ledger Kitchen Lantern Window Compass Margin Bench Field Almanac Porch Thread Garden Signal Shelf Meadow Atlas Workshop Kettle Trail Gable Pantry)
  local -a fonts=('system-ui,-apple-system,"Segoe UI",sans-serif' 'Georgia,"Times New Roman",serif' '"Helvetica Neue",Arial,sans-serif'
                  'ui-monospace,Menlo,Consolas,monospace' 'Charter,"Bitstream Charter",Cambria,serif' 'Verdana,Geneva,sans-serif')
  local -a themes=('#ffffff|#222222|#666666' '#fafaf7|#2b2b2b|#77736a' '#f4f1ea|#33302a|#857c6c' '#16181c|#d8d8d8|#8a8f98' '#fdfdfd|#1a1a1a|#707070' '#eef1f4|#243040|#6b7a8c')
  # 主题|一句话简介|文章标题::摘要|...
  local -a topics=(
"photography|Notes on film, light and long walks with a camera.|First roll through the old rangefinder::Twelve frames, three keepers, and a light leak I have decided to like.|Scanning negatives at home::A flatbed, a cardboard mask and more patience than I expected to need.|Shooting the harbor at dawn::Cold hands and flat light, right up until the sun cleared the cranes.|Why I stopped carrying a zoom::One lens, fewer decisions, and noticeably better pictures.|A year of contact sheets::What looking at every frame taught me about what I keep missing.|Fog on the ridge road::Forty minutes of nothing, then two minutes worth the drive."
"cooking|A home kitchen logbook: what worked, what did not, and what we ate anyway.|Sourdough, attempt nine::Finally an open crumb. The secret was mostly leaving it alone.|Sunday stock from scraps::A freezer bag of trimmings turns into the best soup base of the month.|Getting cast iron properly seasoned::Thin coats, high heat, and ignoring most of the internet.|Quick pickles for people in a hurry::Ten minutes of work and the fridge does the rest.|The lentil soup I keep coming back to::Cheap, forgiving, and better on the second day.|Notes on a failed custard::Scrambled eggs with ambition. Here is what went wrong."
"cycling|Routes, repairs and the occasional wrong turn.|The long way round the reservoir::Sixty kilometers, one puncture and a very good bakery at the halfway point.|Rebuilding a rear wheel::Thirty-two spokes and an evening I will not get back, but it runs true.|Riding through the first frost::What to wear when the forecast lies to you.|A better way to pack a saddle bag::Heavy things low, snacks within reach, and nothing that rattles.|Gravel after rain::Slow, filthy and easily the best ride of the autumn.|Chain wear and when to care::A two-dollar tool that saved me a cassette."
"gardening|A small plot, a lot of weather, and notes for next year.|Starting tomatoes too early again::Leggy seedlings and the windowsill that was never bright enough.|What the slugs left behind::A census of the lettuce bed after a wet week.|Building a cold frame from an old window::Two afternoons, some scrap timber and one cracked pane.|Compost, year two::It finally smells like soil instead of regret.|Saving seed from the best beans::Label everything. I mean everything.|The first frost list::What comes in, what gets covered and what is on its own."
"books|Reading notes, mostly from the back of the shelf.|Rereading a book I hated at nineteen::It turns out the book was fine and the problem was me.|Notes from a month of short stories::One a night, and what stuck after the lights went out.|A used bookshop inventory::Six paperbacks, one map, and a receipt from 1987 used as a bookmark.|On abandoning books without guilt::Life is short and the pile is tall.|Marginalia from a borrowed copy::Arguing with a stranger in pencil.|The best thing I read this winter::A slim novel about a lighthouse and not much else."
"woodworking|Shop notes: small projects, sharp tools, honest mistakes.|A bench hook in an afternoon::The simplest jig in the shop and the one I reach for most.|Sharpening without the mystery::Two stones, a strop and ten minutes.|Dovetails, practice set four::Gaps you could park a bicycle in, but fewer than last time.|Rescuing a flea market plane::Rust, a cracked tote and a very satisfying first shaving.|Finishing with oil and wax::Slow to build, easy to repair, pleasant to touch.|What I learned from a wobbly stool::Measure the legs after you cut them, not just before."
"hiking|Trail notes and weather reports from the nearest hills.|Up the north path before sunrise::Headlamp, frost on the heather and the summit to myself.|Boots, two hundred miles later::What held up, what did not and what I would buy again.|A ridge walk in bad visibility::Compass work, cold sandwiches and one very surprised sheep.|Packing lighter for day trips::Everything I stopped carrying and have not missed.|The river crossing that was not on the map::A detour, wet socks and a better route home.|Autumn on the old drove road::Larch gold, long shadows and nobody else for miles."
"coffee|Brewing notes from a small counter and a hand grinder.|Dialing in a new bag::Three brews too sour, one too bitter, then exactly right.|A week with the pour-over kettle::Slower mornings and a noticeably cleaner cup.|Cold brew without special equipment::A jar, a sieve and twelve hours of doing nothing.|Why my grinder needed cleaning::Stale oils, a small brush and a surprising improvement.|Water matters more than I thought::Same beans, different tap, completely different coffee.|Notes on a light roast::Tea-like, bright and gone before I could decide if I liked it."
  )
  local name topic tagline font bg fg mute hue w lay i n=0 year
  local -a parts posts pt=() ps=() pd=()
  name="${adj[RANDOM % ${#adj[@]}]} ${noun[RANDOM % ${#noun[@]}]}"
  IFS='|' read -ra parts <<<"${topics[RANDOM % ${#topics[@]}]}"
  topic=${parts[0]} tagline=${parts[1]}
  mapfile -t posts < <(printf '%s\n' "${parts[@]:2}" | shuf -n $((RANDOM % 3 + 3)))
  local days=$((RANDOM % 20 + 3))
  for i in "${posts[@]}"; do
    pt+=("${i%%::*}") ps+=("${i#*::}")
    pd+=("$(LC_ALL=C date -d "-$days days" '+%B %-d, %Y' 2>/dev/null || echo "")")
    days=$((days + RANDOM % 60 + 9))
  done
  n=${#pt[@]}
  font=${fonts[RANDOM % ${#fonts[@]}]}
  IFS='|' read -r bg fg mute <<<"${themes[RANDOM % ${#themes[@]}]}"
  hue=$((RANDOM % 360)) w=$((RANDOM % 5 * 40 + 600)) lay=$((RANDOM % 4))
  year=$(date +%Y)
  local css="body{margin:0;background:$bg;color:$fg;font-family:$font;line-height:1.$((RANDOM % 4 + 5))}a{color:hsl($hue,45%,45%);text-decoration:none}a:hover{text-decoration:underline}.wrap{max-width:${w}px;margin:0 auto;padding:$((RANDOM % 5 * 8 + 32))px 20px}.meta,footer{color:$mute;font-size:.85em}"
  echo '<!doctype html>'
  echo "<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  echo "<title>$name</title><meta name=\"description\" content=\"$tagline\">"
  case $lay in
    0)  # 单栏文章列表
      echo "<style>${css}h1{margin-bottom:0}article{margin:2.2em 0}h2{margin:0 0 .2em;font-size:1.25em}</style></head><body><div class=\"wrap\">"
      echo "<header><h1>$name</h1><p class=\"meta\">$tagline</p></header><main>"
      for ((i=0; i<n; i++)); do echo "<article><h2>${pt[i]}</h2><div class=\"meta\">${pd[i]}</div><p>${ps[i]}</p></article>"; done
      echo "</main><footer><p>&copy; $year $name</p></footer></div></body></html>" ;;
    1)  # 顶部导航 + 标题列表 + 关于
      echo "<style>${css}nav{border-bottom:2px solid hsl($hue,45%,45%);padding-bottom:.6em}nav b{font-size:1.3em;margin-right:1.2em}nav a{margin-right:1em}ul{list-style:none;padding:0}li{padding:.7em 0;border-bottom:1px solid ${mute}44}li span{float:right}</style></head><body><div class=\"wrap\">"
      echo "<nav><b>$name</b><a href=\"#posts\">Posts</a><a href=\"#about\">About</a></nav>"
      echo "<section id=\"posts\"><ul>"
      for ((i=0; i<n; i++)); do echo "<li><strong>${pt[i]}</strong><span class=\"meta\">${pd[i]}</span><br>${ps[i]}</li>"; done
      echo "</ul></section><section id=\"about\"><h3>About</h3><p>$tagline Written slowly and updated when there is something worth saying.</p></section>"
      echo "<footer><p>$name, $year.</p></footer></div></body></html>" ;;
    2)  # 卡片网格
      echo "<style>${css}.wrap{max-width:$((w + 240))px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:18px;margin-top:2em}.card{border:1px solid ${mute}55;border-radius:$((RANDOM % 4 * 4))px;padding:16px 18px}.card h2{font-size:1.05em;margin:.2em 0 .5em;color:hsl($hue,45%,45%)}</style></head><body><div class=\"wrap\">"
      echo "<h1>$name</h1><p>$tagline</p><div class=\"grid\">"
      for ((i=0; i<n; i++)); do echo "<section class=\"card\"><div class=\"meta\">${pd[i]}</div><h2>${pt[i]}</h2><p>${ps[i]}</p></section>"; done
      echo "</div><footer><p>All text and pictures by the author. $year</p></footer></div></body></html>" ;;
    3)  # 侧栏 + 日志
      echo "<style>${css}.wrap{max-width:$((w + 200))px;display:flex;gap:40px;flex-wrap:wrap}aside{flex:1 1 180px}main{flex:3 1 380px}aside h1{font-size:1.5em;color:hsl($hue,45%,45%)}dt{font-weight:bold;margin-top:1.4em}dd{margin:.3em 0 0}</style></head><body><div class=\"wrap\">"
      echo "<aside><h1>$name</h1><p>$tagline</p><p class=\"meta\">A personal $topic journal.</p></aside><main><dl>"
      for ((i=0; i<n; i++)); do echo "<dt>${pt[i]} <span class=\"meta\">&middot; ${pd[i]}</span></dt><dd>${ps[i]}</dd>"; done
      echo "</dl><footer><p>&copy; $name</p></footer></main></div></body></html>" ;;
  esac
}

# write_nginx 0：只有 80；write_nginx 1：80 + 本地 HTTPS（Reality target + CDN 反代）
write_nginx(){
  local with_tls=$1 names="$DOMAIN${CDN:+ $CDN}" v6=""
  has_v6 && v6="listen [::]:80;"
  rm -f "$NGX_STREAM"          # 需要时在最后重新生成
  cat > "$NGX_SITE" <<EOF
# 由 node-setup.sh 生成，重跑会覆盖
server {
    listen 80;
    $v6
    server_name $names;
    root $WEB;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  (( with_tls )) || return 0

  local ngv h2l="" h2d="" altsvc=""
  ngv=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n 1p)
  # nginx >= 1.25.1 用 "http2 on;"，旧版本用 listen ... http2
  if ver_ge "$ngv" 1.25.1; then h2d="http2 on;"; else h2l=" http2"; fi
  # 浏览器看到 Alt-Svc 会去连 UDP 443，那里是 Hysteria2 的伪装站，前后一致
  if (( ! NO_HY2 && ! OBFS )) && [[ $HPORT == 443 ]]; then altsvc="add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"; fi

  # 启用源站隐藏时：18443 是 stream 分流层，HTTPS 站点在 18444，并从 PROXY protocol 取真实来源 IP
  local lp=$TARGET_PORT pp="" realip="" guard=""
  if (( HIDE )); then
    lp=$HTTPS_PORT pp=" proxy_protocol"
    realip=$'    set_real_ip_from 127.0.0.1;\n    real_ip_header proxy_protocol;'
    # SNI 写主域名、Host 写 CDN 域名的请求会绕过 stream 那层，这里再挡一次（和未知 Host 一样回 404）
    guard='if ($pn_cf = 0) { return 404; }'
    { echo; echo "# 来源是不是 Cloudflare（1 = 是）"
      echo 'geo $proxy_protocol_addr $pn_cf {'; echo "    default 0;"
      printf '    %s 1;\n' $CF_V4; echo "}"; } >> "$NGX_SITE"
  fi

  # 后量子密钥交换 X25519MLKEM768：新版 Chrome / Firefox 访问真实网站时都会协商它，伪装站也支持才像；
  # Reality 客户端的指纹带它时也能和这里对上。需要 OpenSSL 3.5 以上，旧系统自动不加
  local curves=X25519:prime256v1:secp384r1
  (( with_tls )) && [[ ${2:-} != nopq ]] && ver_ge "$(openssl version 2>/dev/null | awk '{print $2}')" 3.5.0 \
    && curves=X25519MLKEM768:$curves
  local common
  common=$(cat <<EOF
$realip
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve $curves;
    ssl_session_timeout 1d;
    ssl_session_cache shared:PROXYNODE:10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    root $WEB;
    index index.html;
EOF
)
  # 未知 SNI 直接拒绝握手（扫描器、主动探测看到的和普通网站一样）
  if ver_ge "$ngv" 1.19.4; then
    cat >> "$NGX_SITE" <<EOF

server {
    listen 127.0.0.1:$lp ssl$h2l$pp default_server;
    ssl_reject_handshake on;
    return 404;
}
EOF
    (( HIDE )) && cat >> "$NGX_SITE" <<EOF

# 不是 Cloudflare 来的 CDN 域名连接：和未知 SNI 一样拒绝握手
server {
    listen 127.0.0.1:$REJECT_PORT ssl$pp default_server;
    ssl_reject_handshake on;
}
EOF
  fi
  cat >> "$NGX_SITE" <<EOF

# Reality 的 target：未授权连接看到的就是这个站
server {
    listen 127.0.0.1:$lp ssl$h2l$pp;
    $h2d
    server_name $DOMAIN;
    ssl_certificate     $MAIN_DIR/fullchain.crt;
    ssl_certificate_key $MAIN_DIR/private.key;
$common
    $altsvc
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  [[ -n $CDN ]] || return 0
  # Cloudflare 回源时 SNI 是 CDN 域名，不匹配 Reality 的 serverNames，会被原样转到这里
  local loc_x="" loc_w=""
  (( P_CX )) && loc_x=$(cat <<EOF
    # 用 grpc_pass（RPRX #4113："Nginx 推荐 grpc_pass"）；实测 h2 直连和 HTTP/1.1 回源下
    # packet-up / stream-up / stream-one 都通，proxy_pass 只有 packet-up 能通
    location /$XPATH {
        client_max_body_size     0;
        grpc_buffer_size         16k;
        grpc_socket_keepalive    on;
        grpc_read_timeout        1h;
        grpc_send_timeout        1h;
        grpc_set_header Connection         "";
        grpc_set_header X-Real-IP          \$remote_addr;
        grpc_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto  \$scheme;
        grpc_set_header Host               \$host;
        grpc_pass unix:$XHTTP_SOCK;
    }

EOF
)
  (( P_CW )) && loc_w=$(cat <<EOF
    location /$WSPATH {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
    }

EOF
)
  cat >> "$NGX_SITE" <<EOF

# CDN 回源：XHTTP（推荐）+ WS（兼容老客户端），按 --proto 生成
server {
    listen 127.0.0.1:$lp ssl$h2l$pp;
    $h2d
    server_name $CDN;
    ssl_certificate     $CDN_CERT_DIR/fullchain.crt;
    ssl_certificate_key $CDN_CERT_DIR/private.key;
$common
    $guard

    # 以下 XHTTP 反代参数取自 Xray-core discussions #4118（XHTTP 五合一配置）
    http2_max_concurrent_streams 1024;
    http2_body_preread_size      128k;
    keepalive_timeout            600s;
    keepalive_requests           2048;
    client_body_buffer_size      1m;
    client_body_timeout          600s;
    client_header_timeout        300s;
    large_client_header_buffers  8 16k;

$loc_x
$loc_w

    location / { try_files \$uri \$uri/ =404; }
}
EOF
  (( HIDE )) || return 0
  # stream 分流层（见 probe_stream 的说明）。SNI 不分大小写，也允许末尾带点
  local cdn_re=${CDN//./\\.}
  cat > "$NGX_STREAM" <<EOF
# 由 node-setup.sh 生成，重跑会覆盖
stream {
    geo \$proxy_protocol_addr \$pn_cf {
        default 0;
$(printf '        %s 1;\n' $CF_V4)
    }
    map "\$pn_cf:\$ssl_preread_server_name" \$pn_backend {
        default                  127.0.0.1:$HTTPS_PORT;
        "~*^0:$cdn_re\\.?\$"    127.0.0.1:$REJECT_PORT;
    }
    server {
        listen 127.0.0.1:$TARGET_PORT proxy_protocol;
        set_real_ip_from 127.0.0.1;      # 这样转给后面的 PROXY protocol 头里才是真实来源 IP
        ssl_preread on;
        proxy_protocol on;
        proxy_connect_timeout 5s;
        proxy_timeout 1d;
        proxy_pass \$pn_backend;
    }
}
EOF
}

# ------------------------------------------------------------------ 证书 ----
# cert_names 域名 区域 → 证书包含的名字（第一个是 acme.sh 里的证书名）
#   a.example.com → *.example.com     example.com（区域本身）→ example.com *.example.com
cert_names(){
  if (( HTTP01 )); then echo "$1"
  elif [[ $1 == "$2" ]]; then echo "$1 *.$1"
  else echo "*.${1#*.}"; fi
}

ACME=/root/.acme.sh/acme.sh
acme_issue(){ # acme_issue 名字...
  local n rc
  local -a args=()
  for n in "$@"; do args+=(-d "$n"); done
  if (( HTTP01 )); then args+=(--webroot "$WEB"); else args+=(--dns dns_cf); fi
  # 退出码 2 = 证书已存在、跳过，属于正常；用 || 接住，ERR trap 不会把它当成出错
  rc=0
  if (( HTTP01 )); then $ACME --issue "${args[@]}" --keylength ec-256 || rc=$?
  else CF_Token=$CF_TOKEN $ACME --issue "${args[@]}" --keylength ec-256 || rc=$?; fi
  [[ $rc -eq 0 || $rc -eq 2 ]] && return 0
  if (( HTTP01 )); then die "证书申请失败：确认域名是灰色云朵，且 VPS 商家防火墙放行了 TCP 80"
  else die "证书申请失败：检查 Cloudflare Token 权限（区域:读取 + DNS:编辑）"; fi
}

acme_install(){ # acme_install 证书名 目录
  mkdir -p "$2"
  $ACME --install-cert -d "$1" --ecc \
    --key-file "$2/private.key" --fullchain-file "$2/fullchain.crt" \
    --reloadcmd /usr/local/bin/proxy-node-cert-reload >/dev/null
  [[ -s $2/fullchain.crt ]] || die "证书文件不存在：$2/fullchain.crt"
}

# 无域名模式：Hysteria2 用自签证书（CN / SAN 是借用的网站）。重跑时沿用，证书指纹不变
gen_self_cert(){
  local dir=$SSL/self old
  # 不冒充任何域名：证书只写本机 IP，客户端按 IP 连接、不发 SNI（和直接访问 IP 的 HTTPS 一样）
  grn "[3/9] 生成 Hysteria2 自签证书（无域名模式，只含本机 IP $IP）"
  CERT_MAIN="" CERT_CDN="" HY_CERT_DIR=$dir
  old=$(cat "$dir/sni" 2>/dev/null || true)
  if (( RESET )) || [[ ! -s $dir/fullchain.crt || ! -s $dir/private.key || $old != "IP:$IP" ]]; then
    mkdir -p "$dir"; chmod 700 "$dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=$IP" -addext "subjectAltName=IP:$IP" \
      -keyout "$dir/private.key" -out "$dir/fullchain.crt" >/dev/null 2>&1 || die "生成自签证书失败"
    echo "IP:$IP" > "$dir/sni"
    ylw "  已生成新证书（有效期 10 年）"
  else
    ylw "  沿用上次的自签证书（指纹不变，客户端不用改）"
  fi
  HY_FP=$(openssl x509 -in "$dir/fullchain.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  echo "  证书 SHA256 指纹：$HY_FP"
  # 以前用域名部署过：删掉 Let's Encrypt 证书和续期钩子，免得续期时把旧证书复制给 Hysteria2
  rm -rf "$MAIN_DIR" "$CDN_DIR"
  prune_old_certs
  rm -f /usr/local/bin/proxy-node-cert-reload
}

issue_cert(){
  (( NODOMAIN )) && { gen_self_cert; return 0; }
  grn "[3/9] 申请 Let's Encrypt 证书（$( (( HTTP01 )) && echo "HTTP 验证" || echo "DNS 验证，通配符")）"
  [[ -x $ACME ]] || curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
  $ACME --set-default-ca --server letsencrypt >/dev/null

  # 续期后：复制证书给 hysteria、重载 nginx、重启 hysteria（没装就跳过）
  cat > /usr/local/bin/proxy-node-cert-reload <<EOF
#!/bin/sh
if [ -d /etc/hysteria ] && id hysteria >/dev/null 2>&1 && [ -s $MAIN_DIR/fullchain.crt ]; then
  install -m 640 -o root -g hysteria $MAIN_DIR/fullchain.crt /etc/hysteria/cert.crt
  install -m 640 -o root -g hysteria $MAIN_DIR/private.key   /etc/hysteria/cert.key
fi
systemctl reload nginx 2>/dev/null || true
systemctl try-restart hysteria-server 2>/dev/null || true
EOF
  chmod +x /usr/local/bin/proxy-node-cert-reload

  local -a names
  read -ra names <<<"$(cert_names "$DOMAIN" "${ZONE_MAIN:-}")"
  CERT_MAIN=${names[0]}
  ylw "  主证书：${names[*]}"
  acme_issue "${names[@]}"
  acme_install "$CERT_MAIN" "$MAIN_DIR"
  CERT_CDN="" ; CDN_CERT_DIR=$MAIN_DIR HY_CERT_DIR=$MAIN_DIR
  if [[ -n $CDN ]]; then
    read -ra names <<<"$(cert_names "$CDN" "${ZONE_CDN:-}")"
    if [[ ${names[0]} == "$CERT_MAIN" ]]; then
      ylw "  CDN 域名由同一张证书覆盖"
    else
      CERT_CDN=${names[0]}; CDN_CERT_DIR=$CDN_DIR
      ylw "  CDN 证书：${names[*]}"
      acme_issue "${names[@]}"
      acme_install "$CERT_CDN" "$CDN_DIR"
    fi
  fi
  prune_old_certs
}

# 删掉本脚本以前申请、现在不再使用的证书（如旧版的"主域名 + CDN 域名"单证书）
prune_old_certs(){
  [[ -f $STATE ]] || return 0
  local old c keep
  old=$(bash -c 'source "$1" 2>/dev/null; echo "${SAVED_CERTS:-${SAVED_DOMAIN:-}}"' _ "$STATE")
  set -f
  for c in $old; do
    keep=0
    [[ $c == "$CERT_MAIN" || $c == "$CERT_CDN" ]] && keep=1
    (( keep )) && continue
    ylw "  移除不再使用的旧证书：$c"
    $ACME --remove -d "$c" --ecc >/dev/null 2>&1 || true
    rm -rf "/root/.acme.sh/${c}_ecc"
  done
  set +f
  rm -f "$SSL/fullchain.crt" "$SSL/private.key"   # 旧版的证书路径
}

# ------------------------------------------------------------------ Xray ----
install_xray(){
  local want=${XRAY_VERSION:-$XRAY_DEFAULT_VERSION}
  [[ $want == latest || $want == v* ]] || want=v$want          # 允许写 26.9.9
  grn "[4/9] 安装 Xray $( [[ $want == latest ]] && echo "（最新版）" || echo "$want")"
  local url=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  if [[ $want == latest ]]; then
    bash -c "$(curl -fsSL $url)" @ install >/dev/null || die "Xray 最新版安装失败（GitHub 连不上？）"
  else
    bash -c "$(curl -fsSL $url)" @ install --version "$want" >/dev/null \
      || die "Xray $want 安装失败（版本号是否存在？见 https://github.com/XTLS/Xray-core/releases）"
  fi
  local v; v=$(/usr/local/bin/xray version 2>&1) || die "Xray 安装失败：$v"
  echo "  ${v%%$'\n'*}"
  if [[ $want != latest && ${v%%$'\n'*} != "Xray ${want#v} "* ]]; then
    die "装上的 Xray 版本不是 $want：${v%%$'\n'*}"
  fi
}

write_xray(){
  grn "[5/9] 生成 Xray 配置"
  # 出站只走 IPv4：VPS 有 IPv6 时，不同网站（甚至同一网站）会在 v4 / v6 两个出口 IP 之间跳，
  # 地区和 ASN 判定可能不同。domainStrategy=UseIPv4 让域名只解析 A 记录；
  # 客户端直接给的 IPv6 地址（不带域名）拒绝掉，让应用回落到 IPv4。Hysteria2 同样设成只用 IPv4
  local sniff='"sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }'
  local ws_inbound="" xhttp_inbound="" fallback=""
  # reality-xhttp：Vision 入站把非 Vision 流量 fallback 给 XHTTP 入站；cdn-xhttp：nginx 直接转给它
  (( P_RX )) && fallback=',
        "fallbacks": [ { "dest": "'"$XHTTP_SOCK"'" } ]'
  (( P_RX || P_CX )) && xhttp_inbound=$(cat <<EOF
,
    {
      "tag": "xhttp",
      "listen": "$XHTTP_SOCK,0666",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/$XPATH" } },
      $sniff
    }
EOF
)
  (( P_CW )) && ws_inbound=$(cat <<EOF
,
    {
      "tag": "ws-cdn",
      "listen": "127.0.0.1",
      "port": $WS_PORT,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/$WSPATH" } },
      $sniff
    }
EOF
)
  [[ -f $XRAY_CFG ]] && cp "$XRAY_CFG" "$XRAY_CFG.bak.$(date +%s)"
  cat > "$XRAY_CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vision-reality",
      "listen": "0.0.0.0",
      "port": $RPORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"$fallback
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "$R_DEST",$( (( HIDE )) && printf '\n          "xver": 1,')
          "serverNames": [ "$R_SNI" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ],
          "minClientVer": "0.0.0"
        }
      },
      $sniff
    }$xhttp_inbound$ws_inbound
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block" },
      { "ip": ["::/0"], "outboundTag": "block" },
      { "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
  /usr/local/bin/xray run -test -c "$XRAY_CFG" >/dev/null || die "Xray 配置测试失败"
}

# ------------------------------------------------------------- Hysteria2 ----
install_hy2(){
  if (( NO_HY2 )); then
    grn "[6/9] 跳过 Hysteria2"
    # 以前部署过、这次没选：停掉，免得旧服务继续占着 UDP 端口
    systemctl disable --now hysteria-server >/dev/null 2>&1 || true
    return 0
  fi
  grn "[6/9] 安装 Hysteria2"
  bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
  id hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria
  mkdir -p /etc/hysteria
  install -m 640 -o root -g hysteria "$HY_CERT_DIR/fullchain.crt" /etc/hysteria/cert.crt
  install -m 640 -o root -g hysteria "$HY_CERT_DIR/private.key"   /etc/hysteria/cert.key
  {
    cat <<EOF
listen: :$HPORT

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/cert.key

auth:
  type: password
  password: $HY_PASS

# 出站只用 IPv4，与 Xray 保持同一个出口 IP
outbounds:
  - name: v4
    type: direct
    direct:
      mode: 4
EOF
    if (( OBFS )); then
      cat <<EOF

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS
EOF
    else
      cat <<EOF

masquerade:
  type: file
  file:
    dir: $WEB
EOF
    fi
  } > /etc/hysteria/config.yaml
}

# -------------------------------------------------- 防火墙 / 端口跳跃 / BBR ----
setup_firewall(){
  grn "[7/9] 防火墙、端口跳跃、BBR"
  local udp="" hop="" tcp="80 $RPORT"
  (( NODOMAIN )) && tcp=$RPORT
  (( NO_HY2 )) || udp=$HPORT
  [[ -n $HOP ]] && hop=${HOP/-/:}
  # 写成开机自动执行的脚本，不依赖 iptables-persistent（它会和 ufw 冲突）
  {
    echo '#!/bin/sh'
    echo '# 由 node-setup.sh 生成：放行端口 + Hysteria2 端口跳跃，开机自动执行'
    printf 'TCP_PORTS="%s"\nUDP_PORTS="%s"\nHOP="%s"\nHOP_TO="%s"\n' "$tcp" "$udp" "$hop" "$HPORT"
    cat <<'EOF'
for ipt in iptables ip6tables; do
  command -v $ipt >/dev/null 2>&1 || continue
  [ $ipt = ip6tables ] && [ ! -s /proc/net/if_inet6 ] && continue
  for p in $TCP_PORTS; do
    $ipt -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || $ipt -I INPUT -p tcp --dport $p -j ACCEPT
  done
  for p in $UDP_PORTS; do
    $ipt -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null || $ipt -I INPUT -p udp --dport $p -j ACCEPT
  done
  # 端口跳跃：把一段 UDP 端口转到 Hysteria2 实际端口
  $ipt -t nat -N HY2_HOP 2>/dev/null || $ipt -t nat -F HY2_HOP 2>/dev/null || continue
  $ipt -t nat -C PREROUTING -p udp -j HY2_HOP 2>/dev/null || $ipt -t nat -A PREROUTING -p udp -j HY2_HOP
  [ -n "$HOP" ] && $ipt -t nat -A HY2_HOP -p udp --dport $HOP -j REDIRECT --to-ports $HOP_TO
done
exit 0
EOF
  } > /usr/local/sbin/proxy-node-fw
  chmod +x /usr/local/sbin/proxy-node-fw

  cat > /etc/systemd/system/proxy-node-fw.service <<'EOF'
[Unit]
Description=proxy-node firewall rules and Hysteria2 port hopping
After=network-pre.target netfilter-persistent.service ufw.service nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxy-node-fw
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable proxy-node-fw >/dev/null 2>&1
  /usr/local/sbin/proxy-node-fw

  cat > /etc/sysctl.d/99-proxy-node.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ 启动 ----
start_all(){
  grn "[8/9] 启动服务"
  local svcs=(xray)
  if (( ! NODOMAIN )); then
    write_nginx 1
    if ! nginx -t -q 2>/dev/null && grep -q X25519MLKEM768 "$NGX_SITE"; then
      write_nginx 1 nopq        # nginx 链接的 OpenSSL 和命令行的不是同一个版本
    fi
    nginx -t -q || die "nginx 配置测试失败"
    grep -q X25519MLKEM768 "$NGX_SITE" && echo "  伪装站已开启后量子密钥交换 X25519MLKEM768"
    systemctl reload nginx
    svcs=(nginx xray)
  fi
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  if (( ! NO_HY2 )); then
    systemctl enable hysteria-server >/dev/null 2>&1 || true
    systemctl restart hysteria-server
    svcs+=(hysteria-server)
  fi
  sleep 2
  local s
  for s in "${svcs[@]}"; do
    if systemctl is-active --quiet "$s"; then grn "  ✓ $s"
    else red "  ✗ $s 启动失败"; journalctl -u "$s" -n 30 --no-pager; exit 1; fi
  done

  ylw "  自检：未授权连接应拿到 $R_SNI 的$( (( NODOMAIN )) && echo "真实" || echo " Let's Encrypt ")证书"
  timeout 8 openssl s_client -connect "127.0.0.1:$RPORT" -servername "$R_SNI" </dev/null 2>/dev/null \
    | grep -E '^(subject|issuer)=' | sed 's/^/    /' || ylw "    （本地没拿到证书，请从外部再测）"
  if (( HIDE )); then
    # 本机不是 Cloudflare 的 IP：拿 CDN 域名当 SNI 应该被拒绝握手，拿不到证书
    if timeout 8 openssl s_client -connect "127.0.0.1:$RPORT" -servername "$CDN" </dev/null 2>/dev/null | grep -q '^subject='; then
      red "  ✗ CDN 源站隐藏没生效：非 Cloudflare 来源仍能拿到 $CDN 的证书"
    else
      grn "  ✓ CDN 源站隐藏生效：非 Cloudflare 来源拿 $CDN 当 SNI 会被拒绝握手"
    fi
  fi
}

# ------------------------------------------------------------------ 输出 ----
write_info(){
  grn "[9/9] 生成节点信息"
  local hy_extra_yaml="" hy_extra_uri=""
  [[ -n $HOP ]] && { hy_extra_yaml+=", ports: $HOP, hop-interval: 30"; hy_extra_uri+="&mport=$HOP"; }
  (( OBFS )) && { hy_extra_yaml+=", obfs: salamander, obfs-password: $OBFS_PASS"; hy_extra_uri+="&obfs=salamander&obfs-password=$OBFS_PASS"; }
  # 自签证书：跳过 CA 校验，但固定证书指纹，防中间人
  [[ -n $HY_FP ]] && { hy_extra_yaml+=", skip-cert-verify: true, fingerprint: $HY_FP"; hy_extra_uri+="&insecure=1&pinSHA256=$HY_FP"; }

  [[ -n $REGION ]] || REGION=$(ip_country)
  set_flag "${REGION:-none}"
  [[ -n $FLAG ]] && echo "  节点名国旗：${FLAG% }（$REGION）" || ylw "  没识别出本机所在国家，节点名不加国旗（可用 -r us 指定）"
  local N="$FLAG$NODE" U="$FLAG_URI$NODE"
  {
    echo "===== Clash / mihomo（放到 proxies: 下）====="
    echo "  - {name: \"$N-reality\", type: vless, server: $SERVER, port: $RPORT, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: $R_SNI, client-fingerprint: chrome, reality-opts: {public-key: $PUB, short-id: \"$SID\", support-x25519mlkem768: true}}"
    (( P_RX )) && echo "  - {name: \"$N-reality-xhttp\", type: vless, server: $SERVER, port: $RPORT, uuid: $UUID, network: xhttp, tls: true, udp: true, servername: $R_SNI, client-fingerprint: chrome, xhttp-opts: {path: /$XPATH, mode: auto}, reality-opts: {public-key: $PUB, short-id: \"$SID\", support-x25519mlkem768: true}}"
    (( NO_HY2 )) || echo "  - {name: \"$N-hysteria2\", type: hysteria2, server: $SERVER, port: $HPORT, password: $HY_PASS${HY_SNI:+, sni: $HY_SNI}$hy_extra_yaml}"
    (( P_CX )) && echo "  - {name: \"$N-cdn-xhttp\", type: vless, server: $CDN, port: 443, uuid: $UUID, network: xhttp, tls: true, udp: true, servername: $CDN, client-fingerprint: chrome, xhttp-opts: {path: /$XPATH, host: $CDN, mode: auto}}"
    (( P_CW )) && echo "  - {name: \"$N-cdn-ws\", type: vless, server: $CDN, port: 443, uuid: $UUID, udp: true, tls: true, servername: $CDN, client-fingerprint: chrome, network: ws, ws-opts: {path: /$WSPATH, headers: {Host: $CDN}}}"
    echo
    echo "===== 分享链接（v2rayN / NekoBox / Shadowrocket 等）====="
    echo "vless://$UUID@$SERVER:$RPORT?encryption=none&security=reality&sni=$R_SNI&fp=chrome&pbk=$PUB&sid=$SID&support-x25519mlkem768=true&type=tcp&flow=xtls-rprx-vision#$U-reality"
    (( P_RX )) && echo "vless://$UUID@$SERVER:$RPORT?encryption=none&security=reality&sni=$R_SNI&fp=chrome&pbk=$PUB&sid=$SID&support-x25519mlkem768=true&type=xhttp&path=%2F$XPATH&mode=auto#$U-reality-xhttp"
    local hy_q="${HY_SNI:+&sni=$HY_SNI}$hy_extra_uri"
    (( NO_HY2 )) || echo "hysteria2://$HY_PASS@$SERVER:$HPORT/?${hy_q#&}#$U-hysteria2"
    if [[ -n $CDN ]]; then
      (( P_CX )) && echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=xhttp&host=$CDN&path=%2F$XPATH&mode=auto#$U-cdn-xhttp"
      (( P_CW )) && echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=ws&host=$CDN&path=%2F$WSPATH#$U-cdn-ws"
    fi
  } > "$INFO"
  chmod 600 "$INFO"
  echo; cat "$INFO"; echo
  grn "已保存到 $INFO（随时运行 node-setup info 查看）"
  echo
  ylw "还需要手动做的事："
  local p80="（TCP 80 可选，只用来跳转 https）"
  (( HTTP01 )) && p80="、TCP 80（证书续期要用）"
  (( NODOMAIN )) && p80=""
  ylw "  • VPS 商家 / 云控制台安全组放行：TCP $RPORT$( (( NO_HY2 )) || echo "、UDP $HPORT")${HOP:+、UDP $HOP}$p80"
  if (( NODOMAIN )); then
    ylw "  • 无域名模式：Reality 借用 $R_SNI（转发到 $R_DEST）。这个网站下线后 Reality 会连不上，"
    ylw "    重新运行 node-setup 会自动重扫（SNI 变了要重新导入节点）"
    ylw "  • Hysteria2 是只含本机 IP 的自签证书，链接里带 insecure=1 和证书指纹$( (( OBFS )) && echo "，并开了 salamander 混淆")"
    ylw "    （客户端不认 pinSHA256 时只是跳过证书校验；IP 换了要重新导入节点）"
  else
    ylw "  • Cloudflare：$DOMAIN 保持【灰色云朵】"
  fi
  if [[ -n $CDN ]]; then
    ylw "  • Cloudflare：$CDN 保持【橙色云朵】，SSL/TLS 设为 Full (strict)$( (( P_CW )) && echo "，Network 里 WebSockets 保持开启")"
  fi
  (( HTTP01 || NODOMAIN )) || ylw "  • Cloudflare Token 已保存在 /root/.acme.sh/account.conf 供自动续期；卸载时会一并删除"

  ylw "  • 客户端务必开启国内直连分流（服务端屏蔽了 geoip:cn，回国流量会失败）"
  if (( NODOMAIN )); then
    echo
    red "提醒：无域名模式的抗封锁能力弱于有域名模式——Reality 借用别人的网站，Hysteria2 是自签证书，"
    red "      也没有 CDN 线路兜底，IP 被墙只能换 IP。有条件建议买一个域名（几美元一年），用 -d 重新部署。"
  fi
}

# ================================================================== 卸载 ====
# 不只卸载本脚本装的东西，也能清理其他一键脚本 / 面板装的代理，避免端口冲突、残留进程。
# 组件表：名称|systemd 单元（可带 *）|进程名|文件和目录
PROXY_COMPONENTS=(
"Xray|xray.service xray@*.service|xray|/usr/local/bin/xray /usr/bin/xray /usr/local/etc/xray /usr/local/share/xray /etc/xray /var/log/xray /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d"
"V2Ray|v2ray.service v2ray@*.service|v2ray|/usr/local/bin/v2ray /usr/bin/v2ray /usr/local/etc/v2ray /usr/local/share/v2ray /etc/v2ray /var/log/v2ray /etc/systemd/system/v2ray.service.d /etc/systemd/system/v2ray@.service.d"
"sing-box|sing-box.service sing-box@*.service sb.service|sing-box|/usr/local/bin/sing-box /usr/bin/sing-box /etc/sing-box /usr/local/etc/sing-box /var/lib/sing-box /var/log/sing-box /etc/s-box /root/agsb /root/agsbx"
"Hysteria / Hysteria2|hysteria-server.service hysteria-server@*.service hysteria.service hysteria2.service hy2.service|hysteria|/usr/local/bin/hysteria /usr/bin/hysteria /etc/hysteria /var/log/hysteria /root/hy"
"TUIC|tuic.service tuic-server.service tuic@*.service|tuic-server tuic|/usr/local/bin/tuic /usr/local/bin/tuic-server /etc/tuic /opt/tuic /root/tuic"
"Trojan / Trojan-Go|trojan.service trojan-go.service trojan-go@*.service|trojan trojan-go|/usr/local/bin/trojan /usr/local/bin/trojan-go /usr/local/etc/trojan /etc/trojan /etc/trojan-go /usr/share/trojan-go"
"Shadowsocks|shadowsocks-libev.service shadowsocks-libev-server@*.service shadowsocks-rust.service ss-server.service ssserver.service shadowsocks.service|ss-server ssserver|/usr/local/bin/ssserver /usr/local/bin/ss-server /etc/shadowsocks-libev /etc/shadowsocks-rust /etc/shadowsocks"
"x-ui / 3x-ui 面板|x-ui.service|x-ui|/usr/local/x-ui /etc/x-ui /usr/bin/x-ui"
"s-ui 面板|s-ui.service|s-ui sui|/usr/local/s-ui /usr/bin/s-ui"
"h-ui 面板|h-ui.service|h-ui|/usr/local/h-ui /usr/bin/h-ui"
"v2ray-agent 八合一脚本|||/etc/v2ray-agent /usr/bin/vasma /usr/sbin/vasma"
"Juicity|juicity-server.service|juicity-server|/usr/local/bin/juicity-server /etc/juicity"
"NaiveProxy|naive.service naiveproxy.service|naive|/usr/local/bin/naive /etc/naive /etc/naiveproxy"
"gost|gost.service|gost|/usr/local/bin/gost /usr/bin/gost /etc/gost"
"Brook|brook.service|brook|/usr/local/bin/brook /usr/bin/brook"
"mihomo / Clash|mihomo.service clash.service clash-meta.service|mihomo clash clash-meta|/usr/local/bin/mihomo /usr/local/bin/clash /etc/mihomo /etc/clash"
)
# 这些可能另有用途，"全部"不会选中，需要单独选
EXTRA_COMPONENTS=(
"Caddy（常做 NaiveProxy / Trojan 前置，也可能是网站）|caddy.service|caddy|/usr/bin/caddy /usr/local/bin/caddy /etc/caddy"
"cloudflared / Argo 隧道|cloudflared.service argo.service|cloudflared|/usr/local/bin/cloudflared /usr/bin/cloudflared /etc/cloudflared /etc/argox /etc/argo"
)
DOCKER_RE='xray|v2ray|v2fly|sing-?box|hysteria|tuic|trojan|shadowsocks|ss-?rust|x-ui|3x-ui|s-ui|h-ui|naive|juicity|gost|brook|mihomo|clash'

C_TYPE=() C_NAME=() C_DATA=() C_DESC=() C_INALL=()
add_comp(){ C_TYPE+=("$1"); C_NAME+=("$2"); C_DATA+=("$3"); C_DESC+=("$4"); C_INALL+=("$5"); }

# 列出匹配的 systemd 单元（单元文件 + 已加载的实例）
find_units(){
  local pat
  for pat in "$@"; do
    systemctl list-unit-files --no-legend "$pat" 2>/dev/null | awk '{print $1}'
    systemctl list-units --all --no-legend --plain "$pat" 2>/dev/null | awk '{print $1}'
  done | grep -v '^$' | sort -u || true
}

detect_table_comp(){ # $1=表项 $2=是否计入全部
  local name units procs paths u p desc="" running=0
  IFS='|' read -r name units procs paths <<<"$1"
  local -a ua pa fa found_u=() found_p=() found_f=()
  read -ra ua <<<"$units"; read -ra pa <<<"$procs"; read -ra fa <<<"$paths"
  while read -r u; do [[ -n $u ]] && found_u+=("$u"); done < <(find_units "${ua[@]}")
  for u in "${found_u[@]}"; do systemctl is-active --quiet "$u" 2>/dev/null && running=1; done
  for p in "${pa[@]}"; do pgrep -x "$p" >/dev/null 2>&1 && { found_p+=("$p"); running=1; }; done
  for p in "${fa[@]}"; do [[ -e $p || -L $p ]] && found_f+=("$p"); done
  (( ${#found_u[@]} + ${#found_p[@]} + ${#found_f[@]} )) || return 0
  (( running )) && desc="[运行中] "
  (( ${#found_u[@]} )) && desc+="服务: ${found_u[*]}  "
  (( ${#found_p[@]} )) && desc+="进程: ${found_p[*]}  "
  (( ${#found_f[@]} )) && desc+="文件: ${found_f[*]}"
  add_comp table "$name" "$1" "$desc" "$2"
}

detect_all(){
  C_TYPE=() C_NAME=() C_DATA=() C_DESC=() C_INALL=()
  local e line
  if [[ -e /usr/local/sbin/proxy-node-fw || -e $NGX_SITE || -e $NGX_STREAM || -d $WORKDIR ]]; then
    add_comp self "本脚本的附加配置" "" "nginx 站点、防火墙/端口跳跃、证书、凭据（$WORKDIR）" 1
  fi
  for e in "${PROXY_COMPONENTS[@]}"; do detect_table_comp "$e" 1; done
  for e in "${EXTRA_COMPONENTS[@]}"; do detect_table_comp "$e" 0; done
  if command -v docker >/dev/null 2>&1; then
    while read -r line; do
      [[ -n $line ]] || continue
      add_comp docker "Docker 容器 ${line#* }" "${line%% *}" "" 1
    done < <(docker ps -a --format '{{.ID}} {{.Names}} ({{.Image}})' 2>/dev/null | grep -iE "$DOCKER_RE" || true)
  fi
  # 其他脚本留下的 UDP 端口跳跃 NAT 规则（本脚本的 HY2_HOP 归入"本脚本的附加配置"）
  local ipt n
  for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null 2>&1 || continue
    n=$($ipt -t nat -S PREROUTING 2>/dev/null | grep -E '^-A PREROUTING .*-p udp.*-j (REDIRECT|DNAT)' | grep -vc HY2_HOP || true)
    (( n > 0 )) && add_comp nat "$ipt UDP 端口转发规则（多为其他脚本的端口跳跃）" "$ipt" "$n 条" 1
  done
  dpkg -s nginx >/dev/null 2>&1 && add_comp pkg "nginx 软件包" "nginx nginx-common nginx-core nginx-full nginx-light" "如果本机还有其他网站不要选" 0
  [[ -d /root/.acme.sh ]] && add_comp acme "acme.sh 及其全部证书" "" "/root/.acme.sh" 0
  return 0
}

REMOVED_PATHS=()

rm_path(){ # 软件包的文件交给 apt，其余直接删
  local p=$1 pkg
  [[ -e $p || -L $p ]] || return 0
  if pkg=$(dpkg -S "$p" 2>/dev/null | sed -n '1s/:.*//p') && [[ -n $pkg ]]; then
    PURGE_PKGS+=("$pkg")
  else
    rm -rf -- "$p"; REMOVED_PATHS+=("$p")
  fi
}

remove_table_comp(){
  local name units procs paths u p frag
  IFS='|' read -r name units procs paths <<<"$1"
  local -a ua pa fa
  read -ra ua <<<"$units"; read -ra pa <<<"$procs"; read -ra fa <<<"$paths"
  ylw "卸载 $name"
  local d tmpl
  while read -r u; do
    [[ -n $u ]] || continue
    frag=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    [[ -n $frag ]] && rm_path "$frag"
    # 实例 xray@a.service 对应模板 xray@.service；systemd 没给出路径时也到标准目录里找
    tmpl=$(sed -E 's/@[^.]+\./@./' <<<"$u")
    for d in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system /usr/local/lib/systemd/system; do
      rm_path "$d/$u"; rm_path "$d/$tmpl"
    done
    rm -rf "/etc/systemd/system/$u.d" "/etc/systemd/system/$tmpl.d"
  done < <(find_units "${ua[@]}")
  for p in "${pa[@]}"; do pkill -x "$p" 2>/dev/null || true; done
  for p in "${pa[@]}"; do   # 2 秒内没退出就强杀
    for _ in 1 2 3 4; do pgrep -x "$p" >/dev/null || break; sleep 0.5; done
    pkill -9 -x "$p" 2>/dev/null || true
  done
  for p in "${fa[@]}"; do rm_path "$p"; done
  for p in "${pa[@]}"; do   # 删除这些程序专用的系统用户（如 hysteria）
    if getent passwd "$p" >/dev/null && (( $(id -u "$p") < 1000 )); then userdel "$p" 2>/dev/null || true; fi
  done
}

remove_self(){
  ylw "卸载本脚本的附加配置"
  systemctl disable --now proxy-node-fw >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/proxy-node-fw.service /usr/local/sbin/proxy-node-fw
  local ipt
  for ipt in iptables ip6tables; do
    command -v $ipt >/dev/null 2>&1 || continue
    while $ipt -t nat -D PREROUTING -p udp -j HY2_HOP 2>/dev/null; do :; done
    $ipt -t nat -F HY2_HOP 2>/dev/null || true
    $ipt -t nat -X HY2_HOP 2>/dev/null || true
  done
  rm -f /etc/nginx/sites-enabled/proxy-node "$NGX_SITE" "$NGX_STREAM"
  if systemctl is-active --quiet nginx 2>/dev/null; then nginx -t -q 2>/dev/null && systemctl reload nginx || true; fi
  local SAVED_DOMAIN="" SAVED_CERTS="" c
  # shellcheck disable=SC1090
  [[ -f $STATE ]] && source "$STATE"
  if [[ -x /root/.acme.sh/acme.sh ]]; then
    set -f
    for c in ${SAVED_CERTS:-$SAVED_DOMAIN}; do
      /root/.acme.sh/acme.sh --remove -d "$c" --ecc >/dev/null 2>&1 || true
      rm -rf "/root/.acme.sh/${c}_ecc"
    done
    set +f
    # acme.sh 为续期保存的 Cloudflare Token
    [[ -f /root/.acme.sh/account.conf ]] && sed -i '/^SAVED_CF_/d' /root/.acme.sh/account.conf
  fi
  rm -rf "$SSL" "$WEB" "$WORKDIR" "$XHTTP_SOCK" /etc/sysctl.d/99-proxy-node.conf /usr/local/bin/proxy-node-cert-reload "$SELF_BIN"
}

remove_nat(){
  local ipt=$1 line
  local -a args
  ylw "删除 $ipt UDP 端口转发规则"
  while read -r line; do
    [[ -n $line ]] || continue
    read -ra args <<<"${line#-A PREROUTING }"
    $ipt -t nat -D PREROUTING "${args[@]}" 2>/dev/null || red "  删除失败：$line"
  done < <($ipt -t nat -S PREROUTING 2>/dev/null | grep -E '^-A PREROUTING .*-p udp.*-j (REDIRECT|DNAT)' | grep -v HY2_HOP || true)
  ylw "  如果规则是开机脚本加的（rc.local、/etc/iptables/rules.v*、nftables.conf），重启后可能恢复，需要一并清理"
}

cleanup_leftovers(){
  local d l t p c new
  # 指向已删除目录的快捷命令（如 /usr/local/bin/sb、/usr/bin/x-ui）
  for d in /usr/local/bin /usr/bin /usr/sbin /usr/local/sbin; do
    for l in "$d"/*; do
      [[ -L $l && ! -e $l ]] || continue
      t=$(readlink "$l")
      for p in "${REMOVED_PATHS[@]}"; do [[ $t == "$p"* ]] && { rm -f "$l"; break; }; done
    done
  done
  # root crontab 里引用已删除路径的行（@reboot 启动、证书续期等）
  if (( ${#REMOVED_PATHS[@]} )) && c=$(crontab -l 2>/dev/null); then
    new=$c
    for p in "${REMOVED_PATHS[@]}"; do new=$(grep -vF -- "$p" <<<"$new" || true); done
    if [[ $new != "$c" ]]; then
      ylw "从 crontab 删除以下行："; diff <(echo "$c") <(echo "$new") | grep '^<' || true
      if [[ -n $new ]]; then echo "$new" | crontab -; else crontab -r; fi
    fi
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

show_components(){
  local i
  for i in "${!C_NAME[@]}"; do
    printf '  %2d) %s%s\n' $((i+1)) "${C_NAME[$i]}" "$( (( C_INALL[i] )) || echo '  ⚠ 需单独选')"
    [[ -n ${C_DESC[$i]} ]] && printf '      %s\n' "${C_DESC[$i]}"
  done
  echo; ylw "当前监听的端口（不含 sshd）："
  ss -tulnpH 2>/dev/null | grep -v '"sshd"' | awk '{printf "    %-4s %-28s %s\n",$1,$5,$7}' || true
  echo
}

remove_components(){ # remove_components 下标...
  local i
  PURGE_PKGS=()
  for i in "$@"; do
    case ${C_TYPE[$i]} in
      self)   remove_self ;;
      table)  remove_table_comp "${C_DATA[$i]}" ;;
      docker) ylw "删除 ${C_NAME[$i]}"; docker rm -f "${C_DATA[$i]}" >/dev/null || red "  删除失败" ;;
      nat)    remove_nat "${C_DATA[$i]}" ;;
      pkg)    read -ra _p <<<"${C_DATA[$i]}"; PURGE_PKGS+=("${_p[@]}") ;;
      acme)   ylw "卸载 acme.sh"; /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
              rm -rf /root/.acme.sh; REMOVED_PATHS+=(/root/.acme.sh) ;;
    esac
  done
  if (( ${#PURGE_PKGS[@]} )); then
    local -a installed=()
    for i in $(printf '%s\n' "${PURGE_PKGS[@]}" | sort -u); do dpkg -s "$i" >/dev/null 2>&1 && installed+=("$i"); done
    if (( ${#installed[@]} )); then
      ylw "用 apt 卸载软件包：${installed[*]}"
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${installed[@]}" >/dev/null || red "  apt 卸载失败"
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true
    fi
  fi
  cleanup_leftovers
}

# 部署前：列出其他脚本 / 面板装的代理，默认全部卸载，避免端口、服务、配置互相打架
# 本脚本以前部署过（有 state.env）时，Xray / Hysteria2 是自己的，会被原地更新，不列出
# nginx、acme.sh 是本脚本自己要用的，不列出；它们里面冲突的旧配置由 fix_conflicts 处理
preinstall_cleanup(){
  grn "[检查] 已安装的其他代理"
  detect_all
  local i ours=0
  local -a cand=() pick=()
  [[ -f $STATE ]] && ours=1
  for i in "${!C_NAME[@]}"; do
    [[ ${C_TYPE[$i]} == self || ${C_TYPE[$i]} == pkg || ${C_TYPE[$i]} == acme ]] && continue
    if (( ours )) && [[ ${C_NAME[$i]} == Xray || ${C_NAME[$i]} == "Hysteria / Hysteria2" ]]; then continue; fi
    cand+=("$i")
  done
  if (( ${#cand[@]} == 0 )); then grn "  没有发现"; return 0; fi

  ylw "  发现以下已安装的代理组件，部署前建议卸载（否则可能抢端口、服务冲突、残留配置生效）："
  for i in "${cand[@]}"; do
    printf '    %2d) %s%s\n' $((i+1)) "${C_NAME[$i]}" "$( (( C_INALL[i] )) || echo '  ⚠ 可能另有用途，需单独选')"
    [[ -n ${C_DESC[$i]} ]] && printf '        %s\n' "${C_DESC[$i]}"
  done
  local ans n
  if (( YES )) || [[ ! -t 0 ]]; then
    ans=a
    (( YES )) || { ylw "  非交互环境：只卸载不带 ⚠ 的组件（加 -y 可跳过这个提示）"; }
  else
    read -rp "  卸载哪些？编号空格分隔，a=全部不带 ⚠ 的（默认），n=都不卸载: " ans || true
    ans=${ans:-a}
  fi
  case $ans in
    n|N) ylw "  跳过清理，继续部署"; return 0 ;;
    a|A) for i in "${cand[@]}"; do (( C_INALL[i] )) && pick+=("$i"); done ;;
    *)   for n in $ans; do
           [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#C_NAME[@]} )) || die "编号不对：$n"
           [[ " ${cand[*]} " == *" $((n-1)) "* ]] || die "编号不在列表里：$n"
           pick+=("$((n-1))")
         done ;;
  esac
  (( ${#pick[@]} )) || { ylw "  没有要卸载的"; return 0; }
  remove_components "${pick[@]}"
  grn "  清理完成"
}

do_uninstall(){
  detect_all
  if (( ${#C_NAME[@]} == 0 )); then grn "没有检测到代理组件。"; return; fi
  echo; grn "检测到以下组件："
  show_components
  local i

  local -a pick=()
  if (( ALL )); then
    for i in "${!C_NAME[@]}"; do (( C_INALL[i] )) && pick+=("$i"); done
  else
    [[ -t 0 ]] || { ylw "非交互环境：加 --all -y 卸载全部代理组件"; return; }
    local ans n
    read -rp "输入要卸载的编号（空格分隔，a=全部代理组件，回车取消）: " ans || true
    [[ -n $ans ]] || { ylw "已取消"; return; }
    if [[ $ans == a || $ans == A ]]; then
      for i in "${!C_NAME[@]}"; do (( C_INALL[i] )) && pick+=("$i"); done
    else
      for n in $ans; do
        [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#C_NAME[@]} )) || die "编号不对：$n"
        pick+=("$((n-1))")
      done
    fi
  fi
  (( ${#pick[@]} )) || { ylw "没有选中任何组件"; return; }

  echo; red "将要卸载："
  for i in "${pick[@]}"; do red "  - ${C_NAME[$i]}"; done
  if (( ! YES )); then
    [[ -t 0 ]] || die "非交互环境请加 -y 确认"
    local yn; read -rp "确认卸载？此操作不可恢复 (y/N): " yn || true
    [[ $yn =~ ^[Yy] ]] || { ylw "已取消"; return; }
  fi

  remove_components "${pick[@]}"

  echo; grn "卸载完成。还在监听的端口（不含 sshd）："
  ss -tulnpH 2>/dev/null | grep -v '"sshd"' | awk '{printf "    %-4s %-28s %s\n",$1,$5,$7}' || true
  ylw "说明：iptables INPUT 放行规则没有删除（重启后不会再加回）；云控制台安全组请按需自行关闭。"
}

main(){
  parse_args "$@"
  (( $# == 0 )) && [[ -t 0 ]] && main_menu
  if [[ $CMD == info ]]; then
    [[ -f $INFO ]] && cat "$INFO" || die "还没有部署过（找不到 $INFO）"
    exit 0
  fi
  preflight
  if [[ $CMD == uninstall ]]; then do_uninstall; exit 0; fi
  if [[ $CMD == update ]]; then do_update; exit 0; fi
  if [[ $CMD == redeploy ]]; then
    load_deploy || die "找不到上次部署的设置（这台机器还没部署过？），请运行 node-setup 走一遍向导"
  fi
  [[ -n $DOMAIN ]] || (( NODOMAIN )) || interactive
  ask_token
  validate
  RSNI_USER=$RSNI          # 用户手动指定的借用网站（自动扫描时为空）
  mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
  install_deps
  check_dns
  preinstall_cleanup
  fix_conflicts
  check_ports
  setup_site_http
  issue_cert
  install_xray
  load_or_gen_state
  write_xray
  install_hy2
  setup_firewall
  start_all
  write_info
  save_deploy
  install_self
}

# 允许被 source 进来单独测试函数
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
