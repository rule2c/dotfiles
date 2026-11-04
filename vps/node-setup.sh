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
#    sudo bash node-setup.sh info                              # 重新显示节点信息
#    sudo bash node-setup.sh uninstall                         # 卸载：列出本机所有代理（含其他脚本装的），选择卸载
#    sudo bash node-setup.sh uninstall --all -y                # 卸载全部代理组件，不询问
#
#  参数：
#    -d, --domain   主域名（必填）。Cloudflare 灰色云朵，A 记录指向本机。Reality 和 Hysteria2 共用
#    -c, --cdn      CDN 域名（可选，不填就不部署 CDN）。Cloudflare 橙色云朵，A 记录指向本机
#        --cf-token Cloudflare API Token（也可用环境变量 CF_Token，或运行时输入）。权限：
#                   Zone → Zone → Read 和 Zone → DNS → Edit，范围只选你的域名
#                   用来做 DNS 验证申请【通配符证书】（*.example.com），证书透明度日志里看不到具体子域名
#        --http01   不用 Cloudflare API，改用 80 端口验证（会在公开日志里留下具体域名，不推荐）
#    -p, --port     Reality 的 TCP 端口，默认 443
#    -u, --hy2-port Hysteria2 的 UDP 端口，默认 443
#        --hop      Hysteria2 端口跳跃范围，默认 20000-40000；off 表示关闭
#        --obfs     Hysteria2 开启 salamander 混淆（不再像 HTTP/3，但 UDP 被 QoS 时可能有用）
#        --no-hy2   不部署 Hysteria2
#    -e, --email    申请证书用的邮箱，默认 admin@主域名
#        --proto    要部署的协议，逗号分隔（默认全部；不给 -c 时没有 cdn-*）：
#                     reality        VLESS + Vision + REALITY（必选：TCP 入口，CDN 回源也从它转给 nginx）
#                     reality-xhttp  同端口 XHTTP + REALITY 备用
#                     hy2            Hysteria2（同 --no-hy2 的反义）
#                     cdn-xhttp      XHTTP + TLS 经 Cloudflare CDN（需要 -c）
#                     cdn-ws         WS + TLS 经 Cloudflare CDN（需要 -c；Xray 已标记 WS 为过时）
#                   例：--proto reality,hy2      只要 Reality 和 Hysteria2
#    -n, --name     节点名前缀，默认取主域名第一段
#    -r, --region   节点名前的国旗：两位国家代码，如 us（🇺🇸）、jp（🇯🇵）；默认按本机 IP 自动识别，none 不加
#        --reset    重新生成 UUID / 密钥 / 密码（默认沿用上次的，客户端不用改）
#        --all      （uninstall）选中全部代理组件；nginx / acme.sh / Caddy / cloudflared 需单独选
#    -y, --yes      （uninstall）不再确认；（部署时）不询问，直接卸载检测到的其他代理
#    Xray 默认固定为 v26.7.28；环境变量 XRAY_VERSION=v26.x.x 可换成别的版本，XRAY_VERSION=latest 安装最新版
# =============================================================================
set -Eeuo pipefail
# v26.7.28 + minClientVer 0.0.0：mihomo 和 Shadowrocket 的 Reality 都实测能连
#   - v26.9.9 起拒绝不带 X25519MLKEM768 的 Client Hello，Shadowrocket 无法开启，连不上
#   - v26.7.28 默认 minClientVer=26.3.27，mihomo 上报版本 1.8.2 会被拒，所以配置里显式写 0.0.0
XRAY_DEFAULT_VERSION=v26.7.28
# 任何一步失败都打印位置，不再静默退出
trap 'rc=$?; printf "\033[31m脚本出错退出：第 %s 行，命令：%s（退出码 %s）\033[0m\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit $rc' ERR

WORKDIR=/root/proxy-node
STATE=$WORKDIR/state.env
INFO=$WORKDIR/node-info.txt
WEB=/var/www/proxy-node
SSL=/etc/ssl/proxy-node
MAIN_DIR=$SSL/main          # 主域名证书；CDN 域名若被同一张通配符覆盖，也用它
CDN_DIR=$SSL/cdn
NGX_SITE=/etc/nginx/sites-available/proxy-node
XRAY_CFG=/usr/local/etc/xray/config.json
XHTTP_SOCK=/dev/shm/xray-xhttp.sock
TARGET_PORT=18443          # 本机 nginx HTTPS，只监听 127.0.0.1，是 Reality 的 target
WS_PORT=10001              # CDN WS 入站，只监听 127.0.0.1

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "$*"; exit 1; }

usage(){ awk 'NR>2 && /^# =====/{exit} NR>2{sub(/^# ?/,""); print}' "$0" 2>/dev/null || echo "用法：sudo bash node-setup.sh -d 主域名 [-c CDN域名] [-p 端口] [-u hy2端口] [--hop 范围]"; }

# ---------------------------------------------------------------- 参数 ----
CMD=install DOMAIN="" CDN="" RPORT="" HPORT="" HOP="" EMAIL="" NODE="" REGION="" PROTO="" OBFS=0 NO_HY2=0 RESET=0 ALL=0 YES=0
CF_TOKEN=${CF_Token:-} HTTP01=0

parse_args(){
  while [[ $# -gt 0 ]]; do
    case $1 in
      install|info|uninstall) CMD=$1 ;;
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
      --obfs)        OBFS=1 ;;
      --no-hy2)      NO_HY2=1 ;;
      --reset)       RESET=1 ;;
      --all)         ALL=1 ;;
      -y|--yes)      YES=1 ;;
      -h|--help)     usage; exit 0 ;;
      *) red "未知参数：$1"; usage; exit 1 ;;
    esac
    shift
  done
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

# 部署向导：能选的都用编号选，命令行已给的参数作为默认值
interactive(){
  [[ -t 0 ]] || die "缺少 -d 主域名（非交互环境请用参数传入，见 --help）"
  local c ans i ok
  echo
  grn "== 部署向导：Reality 偷自己 + Hysteria2 + CDN 备用 =="
  echo
  ylw "主域名：Cloudflare【灰色云朵】，A 记录指向本机"
  while [[ -z $DOMAIN ]]; do ask DOMAIN "主域名" ""; done

  # ---- 协议（多选）
  local names=(reality reality-xhttp hy2 cdn-xhttp cdn-ws)
  local descs=("VLESS + Vision + REALITY  TCP（必选）"
               "XHTTP + REALITY           同端口备用"
               "Hysteria2                 UDP"
               "XHTTP + TLS 经 Cloudflare CDN（IP 被墙后仍可用）"
               "WS + TLS 经 Cloudflare CDN（兼容老客户端，Xray 已标记过时）")
  local def="1 2 3 4 5"
  if [[ -n $PROTO ]]; then
    def=""
    for i in "${!names[@]}"; do [[ ",${PROTO,,}," == *",${names[i]},"* ]] && def+="$((i+1)) "; done
    def=${def% }
  elif (( NO_HY2 )); then def="1 2 4 5"
  fi
  echo
  echo "选择要部署的协议（多个编号用空格分隔）："
  for i in "${!names[@]}"; do printf '  %d) %-14s %s\n' $((i+1)) "${names[i]}" "${descs[i]}"; done
  while :; do
    read -rp "请输入编号 [默认 $def]: " ans || true
    ans=${ans:-$def}; ans=${ans//,/ }
    PROTO="" ok=1
    for c in $ans; do
      [[ $c =~ ^[1-5]$ ]] || { ok=0; break; }
      [[ ",$PROTO," == *",${names[c-1]},"* ]] || PROTO+="${PROTO:+,}${names[c-1]}"
    done
    (( ok )) || { red "  只能输入 1-5"; continue; }
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
  choose c "Reality TCP 端口：" 1 "443（推荐）" "自定义"
  if (( c == 2 )); then ask RPORT "Reality TCP 端口" "${RPORT:-8443}"; else RPORT=443; fi

  # ---- Hysteria2
  if [[ $PROTO == *hy2* ]]; then
    echo
    choose c "Hysteria2 UDP 端口：" 1 "443（推荐，和 Reality 同端口，一个 TCP 一个 UDP）" "自定义"
    if (( c == 2 )); then ask HPORT "Hysteria2 UDP 端口" "${HPORT:-8443}"; else HPORT=443; fi
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
    choose c "salamander 混淆：" $(( OBFS ? 2 : 1 )) \
      "不开（推荐：看起来像正常 HTTP/3）" "开启（不再像 HTTP/3；UDP 被 QoS 时可能有用）"
    OBFS=$(( c == 2 ))
  fi

  # ---- 节点名 / 国旗
  echo
  ask NODE "节点名前缀" "${NODE:-${DOMAIN%%.*}}"
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

  echo
  ask EMAIL "证书邮箱" "${EMAIL:-admin@$DOMAIN}"

  # ---- 确认
  echo
  grn "== 确认 =="
  echo "  主域名：$DOMAIN    Reality 端口：$RPORT"
  echo "  协议：${PROTO//,/ }"
  [[ -n $CDN ]] && echo "  CDN 域名：$CDN"
  [[ $PROTO == *hy2* ]] && echo "  Hysteria2：UDP $HPORT，端口跳跃 ${HOP/off/关闭}，混淆 $( (( OBFS )) && echo 开 || echo 关)"
  echo "  节点名：$NODE    国旗：${REGION:-自动识别}    凭据：$( (( RESET )) && echo 重新生成 || echo 沿用)"
  echo
  choose c "开始部署？" 1 "开始" "退出"
  (( c == 1 )) || exit 0
}

# 不带任何参数运行时的主菜单
main_menu(){
  echo
  grn "== node-setup.sh =="
  local c
  choose c "要做什么？" 1 "部署 / 重新部署" "查看节点信息" "卸载" "退出"
  case $c in
    1) CMD=install ;;
    2) CMD=info ;;
    3) CMD=uninstall ;;
    4) exit 0 ;;
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
  (( HTTP01 )) && return 0
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
  [[ $DOMAIN =~ $re ]] || die "主域名格式不对：$DOMAIN"
  [[ -z $CDN || $CDN =~ $re ]] || die "CDN 域名格式不对：$CDN"
  [[ $DOMAIN != "$CDN" ]] || die "主域名和 CDN 域名必须不同（一个灰云、一个橙云）"
  [[ -z $CF_TOKEN || $CF_TOKEN =~ ^[A-Za-z0-9_-]+$ ]] || die "Cloudflare Token 格式不对"
  RPORT=${RPORT:-443}; HPORT=${HPORT:-443}; HOP=${HOP:-20000-40000}
  EMAIL=${EMAIL:-admin@$DOMAIN}
  NODE=${NODE:-${DOMAIN%%.*}}
  REGION=${REGION,,}
  [[ -z $REGION || $REGION == none || $REGION =~ ^[a-z]{2}$ ]] || die "国家代码不对：$REGION（两位字母，如 us、jp；none 不加国旗）"
  local p
  for p in "$RPORT" "$HPORT"; do
    [[ $p =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || die "端口不对：$p"
  done
  [[ $RPORT != 80 && $RPORT != "$TARGET_PORT" ]] || die "Reality 端口不能用 80 / $TARGET_PORT"
  [[ $HOP == off ]] && HOP=""
  if [[ -n $HOP ]]; then
    [[ $HOP =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535 )) \
      || die "端口跳跃范围格式应为 20000-40000：$HOP"
  fi
  resolve_proto
  (( NO_HY2 )) && { HOP=""; OBFS=0; }
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
  apt-get install -y -qq curl wget jq openssl nginx cron socat iptables ca-certificates >/dev/null
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

check_ports(){
  local busy
  busy=$(ss -tlnpH 2>/dev/null | awk -v a=":80$" -v b=":$RPORT$" -v c=":$TARGET_PORT$" '$4~a||$4~b||$4~c' \
         | grep -vE '"(nginx|xray)"' || true)
  if (( ! NO_HY2 )); then
    busy+=$(ss -ulnpH 2>/dev/null | awk -v a=":$HPORT$" '$4~a' | grep -v '"hysteria"' || true)
  fi
  if [[ -n $busy ]]; then
    red "以下端口被其他程序占用（TCP 80 / $RPORT / $TARGET_PORT，UDP ${HPORT}）："
    echo "$busy"
    die "请先停掉它（例如 systemctl disable --now caddy apache2），或运行 bash $0 uninstall 卸载其他代理，再重新运行。"
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
      SAVED_DOMAIN "$DOMAIN" SAVED_CDN "$CDN" SAVED_CERTS "$CERT_MAIN${CERT_CDN:+ $CERT_CDN}" > "$STATE" )
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
      elif [[ $port == "$RPORT" || $port == "$TARGET_PORT" ]]; then
        bad[$f]=1
      fi
    done
  done <<<"$dump"
  for f in "${!bad[@]}"; do
    [[ $f == "$NGX_SITE" || $f == "$ours_link" ]] || echo "$f"
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
    [[ $f == /etc/nginx/nginx.conf ]] && die "/etc/nginx/nginx.conf 里有 server 监听端口 $RPORT / $TARGET_PORT，请手动删掉那段后重跑"
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
  grn "[2/9] 配置伪装站点"
  mkdir -p "$WEB"
  [[ -f $WEB/index.html ]] || cat > "$WEB/index.html" <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Field Notes</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:80px auto;padding:0 16px;color:#222;line-height:1.6}</style>
</head><body><h1>Field Notes</h1><p>Occasional notes on photography and travel. More posts coming soon.</p></body></html>
EOF
  [[ -f /etc/nginx/nginx.conf ]] || die "nginx 安装不完整（缺 /etc/nginx/nginx.conf），请运行 apt-get install --reinstall nginx-common nginx 后重跑"
  grep -qE '^[^#]*include[[:space:]]+/etc/nginx/sites-enabled/' /etc/nginx/nginx.conf \
    || die "/etc/nginx/nginx.conf 没有加载 sites-enabled 目录（可能不是 Debian 自带的 nginx），请改用 apt 安装的 nginx"
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default
  write_nginx 0
  ln -sf "$NGX_SITE" /etc/nginx/sites-enabled/proxy-node
  nginx -t -q
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || { journalctl -u nginx -n 15 --no-pager; die "nginx 启动失败"; }
}

# write_nginx 0：只有 80；write_nginx 1：80 + 本地 HTTPS（Reality target + CDN 反代）
write_nginx(){
  local with_tls=$1 names="$DOMAIN${CDN:+ $CDN}" v6=""
  has_v6 && v6="listen [::]:80;"
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

  local common
  common=$(cat <<EOF
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
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
    listen 127.0.0.1:$TARGET_PORT ssl$h2l default_server;
    ssl_reject_handshake on;
}
EOF
  fi
  cat >> "$NGX_SITE" <<EOF

# Reality 的 target：未授权连接看到的就是这个站
server {
    listen 127.0.0.1:$TARGET_PORT ssl$h2l;
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
    listen 127.0.0.1:$TARGET_PORT ssl$h2l;
    $h2d
    server_name $CDN;
    ssl_certificate     $CDN_CERT_DIR/fullchain.crt;
    ssl_certificate_key $CDN_CERT_DIR/private.key;
$common

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

issue_cert(){
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
  CERT_CDN="" ; CDN_CERT_DIR=$MAIN_DIR
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
    bash -c "$(curl -fsSL $url)" @ install >/dev/null
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
          "target": "127.0.0.1:$TARGET_PORT",
          "serverNames": [ "$DOMAIN" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ],
          "minClientVer": "0.0.0"
        }
      },
      $sniff
    }$xhttp_inbound$ws_inbound
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block" },
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
  install -m 640 -o root -g hysteria "$MAIN_DIR/fullchain.crt" /etc/hysteria/cert.crt
  install -m 640 -o root -g hysteria "$MAIN_DIR/private.key"   /etc/hysteria/cert.key
  {
    cat <<EOF
listen: :$HPORT

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/cert.key

auth:
  type: password
  password: $HY_PASS
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
  local udp="" hop=""
  (( NO_HY2 )) || udp=$HPORT
  [[ -n $HOP ]] && hop=${HOP/-/:}
  # 写成开机自动执行的脚本，不依赖 iptables-persistent（它会和 ufw 冲突）
  {
    echo '#!/bin/sh'
    echo '# 由 node-setup.sh 生成：放行端口 + Hysteria2 端口跳跃，开机自动执行'
    printf 'TCP_PORTS="80 %s"\nUDP_PORTS="%s"\nHOP="%s"\nHOP_TO="%s"\n' "$RPORT" "$udp" "$hop" "$HPORT"
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
  write_nginx 1
  nginx -t -q || die "nginx 配置测试失败"
  systemctl reload nginx
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  local svcs=(nginx xray)
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

  ylw "  自检：未授权连接应拿到 $DOMAIN 的 Let's Encrypt 证书"
  timeout 8 openssl s_client -connect "127.0.0.1:$RPORT" -servername "$DOMAIN" </dev/null 2>/dev/null \
    | grep -E '^(subject|issuer)=' | sed 's/^/    /' || ylw "    （本地没拿到证书，请从外部再测）"
}

# ------------------------------------------------------------------ 输出 ----
write_info(){
  grn "[9/9] 生成节点信息"
  local hy_extra_yaml="" hy_extra_uri=""
  [[ -n $HOP ]] && { hy_extra_yaml+=", ports: $HOP, hop-interval: 30"; hy_extra_uri+="&mport=$HOP"; }
  (( OBFS )) && { hy_extra_yaml+=", obfs: salamander, obfs-password: $OBFS_PASS"; hy_extra_uri+="&obfs=salamander&obfs-password=$OBFS_PASS"; }

  [[ -n $REGION ]] || REGION=$(ip_country)
  set_flag "${REGION:-none}"
  [[ -n $FLAG ]] && echo "  节点名国旗：${FLAG% }（$REGION）" || ylw "  没识别出本机所在国家，节点名不加国旗（可用 -r us 指定）"
  local N="$FLAG$NODE" U="$FLAG_URI$NODE"
  {
    echo "===== Clash / mihomo（放到 proxies: 下）====="
    echo "  - {name: \"$N-reality\", type: vless, server: $DOMAIN, port: $RPORT, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: $DOMAIN, client-fingerprint: chrome, reality-opts: {public-key: $PUB, short-id: $SID, support-x25519mlkem768: true}}"
    (( P_RX )) && echo "  - {name: \"$N-reality-xhttp\", type: vless, server: $DOMAIN, port: $RPORT, uuid: $UUID, network: xhttp, tls: true, udp: true, servername: $DOMAIN, client-fingerprint: chrome, xhttp-opts: {path: /$XPATH, mode: auto}, reality-opts: {public-key: $PUB, short-id: $SID, support-x25519mlkem768: true}}"
    (( NO_HY2 )) || echo "  - {name: \"$N-hysteria2\", type: hysteria2, server: $DOMAIN, port: $HPORT, password: $HY_PASS, sni: $DOMAIN$hy_extra_yaml}"
    (( P_CW )) && echo "  - {name: \"$N-cdn-ws\", type: vless, server: $CDN, port: 443, uuid: $UUID, udp: true, tls: true, servername: $CDN, client-fingerprint: chrome, network: ws, ws-opts: {path: /$WSPATH, headers: {Host: $CDN}}}"
    echo
    echo "===== 分享链接（v2rayN / NekoBox / Shadowrocket 等）====="
    echo "vless://$UUID@$DOMAIN:$RPORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB&sid=$SID&support-x25519mlkem768=true&type=tcp&flow=xtls-rprx-vision#$U-reality"
    (( P_RX )) && echo "vless://$UUID@$DOMAIN:$RPORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB&sid=$SID&support-x25519mlkem768=true&type=xhttp&path=%2F$XPATH&mode=auto#$U-reality-xhttp"
    (( NO_HY2 )) || echo "hysteria2://$HY_PASS@$DOMAIN:$HPORT/?sni=$DOMAIN$hy_extra_uri#$U-hysteria2"
    if [[ -n $CDN ]]; then
      (( P_CX )) && echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=xhttp&host=$CDN&path=%2F$XPATH&mode=auto#$U-cdn-xhttp"
      (( P_CW )) && echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=ws&host=$CDN&path=%2F$WSPATH#$U-cdn-ws"
    fi
  } > "$INFO"
  chmod 600 "$INFO"
  echo; cat "$INFO"; echo
  grn "已保存到 $INFO（随时运行 sudo bash $0 info 查看）"
  echo
  ylw "还需要手动做的事："
  ylw "  • VPS 商家 / 云控制台安全组放行：TCP $RPORT$( (( NO_HY2 )) || echo "、UDP $HPORT")${HOP:+、UDP $HOP}$( (( HTTP01 )) && echo "、TCP 80（证书续期要用）" || echo "（TCP 80 可选，只用来跳转 https）")"
  ylw "  • Cloudflare：$DOMAIN 保持【灰色云朵】"
  if [[ -n $CDN ]]; then
    ylw "  • Cloudflare：$CDN 保持【橙色云朵】，SSL/TLS 设为 Full (strict)$( (( P_CW )) && echo "，Network 里 WebSockets 保持开启")"
  fi
  (( HTTP01 )) || ylw "  • Cloudflare Token 已保存在 /root/.acme.sh/account.conf 供自动续期；卸载时会一并删除"

  ylw "  • 客户端务必开启国内直连分流（服务端屏蔽了 geoip:cn，回国流量会失败）"
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
  if [[ -e /usr/local/sbin/proxy-node-fw || -e $NGX_SITE || -d $WORKDIR ]]; then
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
  rm -f /etc/nginx/sites-enabled/proxy-node "$NGX_SITE"
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
  rm -rf "$SSL" "$WEB" "$WORKDIR" "$XHTTP_SOCK" /etc/sysctl.d/99-proxy-node.conf /usr/local/bin/proxy-node-cert-reload
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
  [[ -n $DOMAIN ]] || interactive
  ask_token
  validate
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
}

# 允许被 source 进来单独测试函数
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
