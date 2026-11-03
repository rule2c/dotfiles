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
#    sudo bash node-setup.sh                                   # 交互式，按提示输入
#    sudo bash node-setup.sh -d a.example.com -c cdn.example.com
#    sudo bash node-setup.sh -d a.example.com -p 443 -u 443 --hop 20000-40000 -e me@example.com
#    sudo bash node-setup.sh info                              # 重新显示节点信息
#
#  参数：
#    -d, --domain   主域名（必填）。Cloudflare 灰色云朵，A 记录指向本机。Reality 和 Hysteria2 共用
#    -c, --cdn      CDN 域名（可选，不填就不部署 CDN）。先灰色云朵申请证书，部署完改成橙色云朵
#    -p, --port     Reality 的 TCP 端口，默认 443
#    -u, --hy2-port Hysteria2 的 UDP 端口，默认 443
#        --hop      Hysteria2 端口跳跃范围，默认 20000-40000；off 表示关闭
#        --obfs     Hysteria2 开启 salamander 混淆（不再像 HTTP/3，但 UDP 被 QoS 时可能有用）
#        --no-hy2   不部署 Hysteria2
#    -e, --email    申请证书用的邮箱，默认 admin@主域名
#    -n, --name     节点名前缀，默认取主域名第一段
#        --reset    重新生成 UUID / 密钥 / 密码（默认沿用上次的，客户端不用改）
#    环境变量 XRAY_VERSION=v26.x.x 可固定 Xray 版本，默认安装最新版
# =============================================================================
set -euo pipefail

WORKDIR=/root/proxy-node
STATE=$WORKDIR/state.env
INFO=$WORKDIR/node-info.txt
WEB=/var/www/proxy-node
SSL=/etc/ssl/proxy-node
NGX_SITE=/etc/nginx/sites-available/proxy-node
XRAY_CFG=/usr/local/etc/xray/config.json
XHTTP_SOCK=/dev/shm/xray-xhttp.sock
TARGET_PORT=18443          # 本机 nginx HTTPS，只监听 127.0.0.1，是 Reality 的 target
WS_PORT=10001              # CDN WS 入站，只监听 127.0.0.1

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "$*"; exit 1; }

usage(){ sed -n '3,33s/^# \{0,1\}//p' "$0" 2>/dev/null || echo "用法：sudo bash node-setup.sh -d 主域名 [-c CDN域名] [-p 端口] [-u hy2端口] [--hop 范围]"; }

# ---------------------------------------------------------------- 参数 ----
CMD=install DOMAIN="" CDN="" RPORT="" HPORT="" HOP="" EMAIL="" NODE="" OBFS=0 NO_HY2=0 RESET=0

parse_args(){
  while [[ $# -gt 0 ]]; do
    case $1 in
      install|info) CMD=$1 ;;
      -d|--domain)   DOMAIN=${2:?缺少域名}; shift ;;
      -c|--cdn)      CDN=${2:?缺少 CDN 域名}; shift ;;
      -p|--port)     RPORT=${2:?缺少端口}; shift ;;
      -u|--hy2-port) HPORT=${2:?缺少端口}; shift ;;
      --hop)         HOP=${2:?缺少端口范围}; shift ;;
      -e|--email)    EMAIL=${2:?缺少邮箱}; shift ;;
      -n|--name)     NODE=${2:?缺少名称}; shift ;;
      --obfs)        OBFS=1 ;;
      --no-hy2)      NO_HY2=1 ;;
      --reset)       RESET=1 ;;
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

interactive(){
  [[ -t 0 ]] || die "缺少 -d 主域名（非交互环境请用参数传入，见 --help）"
  echo
  grn "== 一键部署：Reality 偷自己 + Hysteria2 + CDN 备用 =="
  ylw "主域名需要在 Cloudflare 设为【灰色云朵】并指向本机；CDN 域名可以留空跳过。"
  echo
  while [[ -z $DOMAIN ]]; do ask DOMAIN "主域名（Reality + Hysteria2 用）" ""; done
  ask CDN   "CDN 域名（留空不部署）" ""
  ask RPORT "Reality TCP 端口" 443
  local yn; ask yn "部署 Hysteria2？(Y/n)" Y
  if [[ $yn =~ ^[Nn] ]]; then NO_HY2=1; else
    ask HPORT "Hysteria2 UDP 端口" 443
    ask HOP   "端口跳跃范围（off 关闭）" 20000-40000
    ask yn    "开启 salamander 混淆？(y/N)" N; [[ $yn =~ ^[Yy] ]] && OBFS=1
  fi
  ask EMAIL "证书邮箱" "admin@$DOMAIN"
}

validate(){
  local re='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  [[ $DOMAIN =~ $re ]] || die "主域名格式不对：$DOMAIN"
  [[ -z $CDN || $CDN =~ $re ]] || die "CDN 域名格式不对：$CDN"
  [[ $DOMAIN != "$CDN" ]] || die "主域名和 CDN 域名必须不同（一个灰云、一个橙云）"
  RPORT=${RPORT:-443}; HPORT=${HPORT:-443}; HOP=${HOP:-20000-40000}
  EMAIL=${EMAIL:-admin@$DOMAIN}
  NODE=${NODE:-${DOMAIN%%.*}}
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
  (( NO_HY2 )) && { HOP=""; OBFS=0; }
  if [[ -n $CDN && $RPORT != 443 ]]; then
    ylw "注意：Reality 端口不是 443，Cloudflare 回源默认连 443。"
    ylw "      需要在 Cloudflare → Rules → Origin Rules 把 $CDN 的回源端口改成 $RPORT。"
  fi
}

# ---------------------------------------------------------------- 工具 ----
public_ip(){ curl -4 -s --max-time 5 https://api.ipify.org || curl -4 -s --max-time 5 https://ifconfig.me || true; }
has_v6(){ [[ -s /proc/net/if_inet6 ]]; }
ver_ge(){ printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qx "$2"; }   # ver_ge 当前 要求

preflight(){
  [[ $EUID -eq 0 ]] || die "请用 root 或 sudo 运行"
  # acme.sh 检测到 sudo 环境变量会拒绝运行；脚本已经是 root，清掉即可
  unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
  export HOME=/root
  grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release || die "只支持 Debian / Ubuntu"
  case $(uname -m) in x86_64|aarch64) ;; *) die "不支持的架构 $(uname -m)" ;; esac
  command -v systemctl >/dev/null || die "需要 systemd"
  mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
}

install_deps(){
  grn "[1/9] 安装依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl wget jq openssl nginx cron socat iptables ca-certificates >/dev/null
  systemctl enable --now cron >/dev/null 2>&1 || true
}

check_dns(){
  IP=$(public_ip); [[ -n $IP ]] || die "获取不到本机公网 IPv4"
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
    die "请先停掉它（例如 systemctl disable --now caddy apache2），再重新运行。"
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
      WSPATH "$WSPATH" HY_PASS "$HY_PASS" OBFS_PASS "$OBFS_PASS" > "$STATE" )
}

# ------------------------------------------------------------ nginx 站点 ----
setup_site_http(){
  grn "[2/9] 配置伪装站点（80 端口，用于申请证书）"
  mkdir -p "$WEB"
  [[ -f $WEB/index.html ]] || cat > "$WEB/index.html" <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Field Notes</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:80px auto;padding:0 16px;color:#222;line-height:1.6}</style>
</head><body><h1>Field Notes</h1><p>Occasional notes on photography and travel. More posts coming soon.</p></body></html>
EOF
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
  ngv=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  # nginx >= 1.25.1 用 "http2 on;"，旧版本用 listen ... http2
  if ver_ge "$ngv" 1.25.1; then h2d="http2 on;"; else h2l=" http2"; fi
  # 浏览器看到 Alt-Svc 会去连 UDP 443，那里是 Hysteria2 的伪装站，前后一致
  if (( ! NO_HY2 && ! OBFS )) && [[ $HPORT == 443 ]]; then altsvc="add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"; fi

  local common
  common=$(cat <<EOF
    ssl_certificate     $SSL/fullchain.crt;
    ssl_certificate_key $SSL/private.key;
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
$common
    $altsvc
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  [[ -n $CDN ]] || return 0
  # Cloudflare 回源时 SNI 是 CDN 域名，不匹配 Reality 的 serverNames，会被原样转到这里
  cat >> "$NGX_SITE" <<EOF

# CDN 回源：XHTTP（推荐）+ WS（兼容老客户端）
server {
    listen 127.0.0.1:$TARGET_PORT ssl$h2l;
    $h2d
    server_name $CDN;
$common

    location /$XPATH {
        client_max_body_size 0;
        grpc_pass unix:$XHTTP_SOCK;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header X-Real-IP \$remote_addr;
    }

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

    location / { try_files \$uri \$uri/ =404; }
}
EOF
}

# ------------------------------------------------------------------ 证书 ----
issue_cert(){
  grn "[3/9] 申请 Let's Encrypt 证书"
  [[ -x /root/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
  local ACME=/root/.acme.sh/acme.sh rc
  $ACME --set-default-ca --server letsencrypt >/dev/null
  set +e
  $ACME --issue -d "$DOMAIN" ${CDN:+-d "$CDN"} --webroot "$WEB" --keylength ec-256
  rc=$?
  set -e
  [[ $rc -eq 0 || $rc -eq 2 ]] || die "证书申请失败：确认域名是灰色云朵，且 VPS 商家防火墙放行了 TCP 80"

  # 续期后：复制证书给 hysteria、重载 nginx、重启 hysteria（没装就跳过）
  cat > /usr/local/bin/proxy-node-cert-reload <<EOF
#!/bin/sh
if [ -d /etc/hysteria ] && id hysteria >/dev/null 2>&1; then
  install -m 640 -o root -g hysteria $SSL/fullchain.crt /etc/hysteria/cert.crt
  install -m 640 -o root -g hysteria $SSL/private.key   /etc/hysteria/cert.key
fi
systemctl reload nginx 2>/dev/null || true
systemctl try-restart hysteria-server 2>/dev/null || true
EOF
  chmod +x /usr/local/bin/proxy-node-cert-reload
  mkdir -p "$SSL"
  $ACME --install-cert -d "$DOMAIN" --ecc \
    --key-file "$SSL/private.key" --fullchain-file "$SSL/fullchain.crt" \
    --reloadcmd /usr/local/bin/proxy-node-cert-reload >/dev/null
  [[ -s $SSL/fullchain.crt ]] || die "证书文件不存在：$SSL/fullchain.crt"
}

# ------------------------------------------------------------------ Xray ----
install_xray(){
  grn "[4/9] 安装 Xray ${XRAY_VERSION:-（最新版）}"
  local url=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  if [[ -n ${XRAY_VERSION:-} ]]; then
    bash -c "$(curl -fsSL $url)" @ install --version "$XRAY_VERSION" >/dev/null
  else
    bash -c "$(curl -fsSL $url)" @ install >/dev/null
  fi
  /usr/local/bin/xray version | head -1
}

write_xray(){
  grn "[5/9] 生成 Xray 配置"
  local sniff='"sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }'
  local ws_inbound=""
  [[ -n $CDN ]] && ws_inbound=$(cat <<EOF
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
        "decryption": "none",
        "fallbacks": [ { "dest": "$XHTTP_SOCK" } ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "127.0.0.1:$TARGET_PORT",
          "serverNames": [ "$DOMAIN" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ]
        }
      },
      $sniff
    },
    {
      "tag": "xhttp",
      "listen": "$XHTTP_SOCK,0666",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/$XPATH" } },
      $sniff
    }$ws_inbound
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
  (( NO_HY2 )) && { grn "[6/9] 跳过 Hysteria2"; return; }
  grn "[6/9] 安装 Hysteria2"
  bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
  id hysteria &>/dev/null || useradd -r -s /usr/sbin/nologin hysteria
  mkdir -p /etc/hysteria
  install -m 640 -o root -g hysteria "$SSL/fullchain.crt" /etc/hysteria/cert.crt
  install -m 640 -o root -g hysteria "$SSL/private.key"   /etc/hysteria/cert.key
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

  {
    echo "===== Clash / mihomo（放到 proxies: 下）====="
    echo "  - {name: $NODE-reality, type: vless, server: $DOMAIN, port: $RPORT, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: $DOMAIN, client-fingerprint: chrome, reality-opts: {public-key: $PUB, short-id: $SID}}"
    (( NO_HY2 )) || echo "  - {name: $NODE-hy2, type: hysteria2, server: $DOMAIN, port: $HPORT, password: $HY_PASS, sni: $DOMAIN$hy_extra_yaml}"
    [[ -n $CDN ]] && echo "  - {name: $NODE-cdn-ws, type: vless, server: $CDN, port: 443, uuid: $UUID, udp: true, tls: true, servername: $CDN, client-fingerprint: chrome, network: ws, ws-opts: {path: /$WSPATH, headers: {Host: $CDN}}}"
    echo
    echo "===== 分享链接（v2rayN / NekoBox / Shadowrocket 等）====="
    echo "vless://$UUID@$DOMAIN:$RPORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&flow=xtls-rprx-vision#$NODE-reality"
    echo "vless://$UUID@$DOMAIN:$RPORT?encryption=none&security=reality&sni=$DOMAIN&fp=chrome&pbk=$PUB&sid=$SID&type=xhttp&path=%2F$XPATH&mode=auto#$NODE-reality-xhttp"
    (( NO_HY2 )) || echo "hysteria2://$HY_PASS@$DOMAIN:$HPORT/?sni=$DOMAIN$hy_extra_uri#$NODE-hy2"
    if [[ -n $CDN ]]; then
      echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=xhttp&host=$CDN&path=%2F$XPATH&mode=auto#$NODE-cdn-xhttp"
      echo "vless://$UUID@$CDN:443?encryption=none&security=tls&sni=$CDN&fp=chrome&type=ws&host=$CDN&path=%2F$WSPATH#$NODE-cdn-ws"
    fi
  } > "$INFO"
  chmod 600 "$INFO"
  echo; cat "$INFO"; echo
  grn "已保存到 $INFO（随时运行 sudo bash $0 info 查看）"
  echo
  ylw "还需要手动做的事："
  ylw "  • VPS 商家 / 云控制台安全组放行：TCP 80、TCP $RPORT$( (( NO_HY2 )) || echo "、UDP $HPORT")${HOP:+、UDP $HOP}"
  ylw "  • Cloudflare：$DOMAIN 保持【灰色云朵】"
  if [[ -n $CDN ]]; then
    ylw "  • Cloudflare：$CDN 改成【橙色云朵】，SSL/TLS 设为 Full (strict)，Network 里 WebSockets 保持开启"
  fi
  ylw "  • 客户端务必开启国内直连分流（服务端屏蔽了 geoip:cn，回国流量会失败）"
}

main(){
  parse_args "$@"
  if [[ $CMD == info ]]; then
    [[ -f $INFO ]] && cat "$INFO" || die "还没有部署过（找不到 $INFO）"
    exit 0
  fi
  preflight
  [[ -n $DOMAIN ]] || interactive
  validate
  install_deps
  check_dns
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
