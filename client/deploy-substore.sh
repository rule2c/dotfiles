#!/usr/bin/env bash
# 在 Oracle 东京 AMD 上部署 Sub-Store，经 Cloudflare CDN 用 HTTPS 对外提供
#
# 用法：sudo CF_Token=<Cloudflare API Token> bash deploy-substore.sh <域名> [端口]
#   例：sudo CF_Token=xxxx bash deploy-substore.sh sub.example.com 8443
#
# 运行前：
#   1. Cloudflare 添加 A 记录 sub.example.com → 东京 AMD 的 IP，【橙色云朵】
#      （走 CDN：国内访问不依赖这台机器的 IP 是否被墙，也不暴露真实 IP）
#   2. Cloudflare SSL/TLS 加密模式设为【完全（严格）/ Full (strict)】
#   3. Cloudflare 创建 API Token：模板选"编辑区域 DNS"，区域选 example.com
#   4. Oracle 控制台 → VCN → Security List 放行 TCP <端口>（默认 8443）
# 端口必须是 Cloudflare 支持的 HTTPS 端口之一：443、2053、2083、2087、2096、8443
# 证书用 DNS 验证申请，不需要开 80 端口。
set -euo pipefail

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { red "请用 sudo 运行"; exit 1; }
unset SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
export HOME=/root

DOMAIN=${1:-}; PORT=${2:-8443}
[[ -n "$DOMAIN" ]] || { red "用法：sudo CF_Token=xxx bash $0 <域名> [端口]"; exit 1; }
[[ -n "${CF_Token:-}" ]] || { red "缺少 CF_Token（Cloudflare API Token）"; exit 1; }
if ! command -v docker >/dev/null; then
  ylw "没有 docker，自动安装"
  if command -v apt-get >/dev/null; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null
  elif command -v dnf >/dev/null; then
    dnf install -y -q dnf-plugins-core >/dev/null
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
    dnf install -y -q docker-ce docker-ce-cli containerd.io >/dev/null
  else
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  command -v docker >/dev/null || { red "docker 安装失败"; exit 1; }
  grn "docker 已安装：$(docker --version)"
fi
case "$PORT" in 443|2053|2083|2087|2096|8443) ;; *) red "端口 $PORT 不能经 Cloudflare 代理，请改用 443/2053/2083/2087/2096/8443"; exit 1;; esac
ss -tlnH "sport = :$PORT" | grep -q . && ! ss -tlnpH "sport = :$PORT" | grep -q nginx && { red "端口 $PORT 已被其他程序占用："; ss -tlnpH "sport = :$PORT"; exit 1; }

DATA=/root/sub-store-data
INFO=/root/sub-store-info.txt
mkdir -p "$DATA"

# 后端路径：重复运行时沿用旧的，避免已发出去的订阅链接失效
if [[ -f "$INFO" ]] && grep -q '^BACKEND_PATH=' "$INFO"; then
  BP=$(grep '^BACKEND_PATH=' "$INFO" | cut -d= -f2)
else
  BP=/$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
fi

# ---------- 1. Sub-Store 容器（只监听本机） ----------
grn "[1/4] 启动 Sub-Store 容器"
docker rm -f sub-store >/dev/null 2>&1 || true
docker pull xream/sub-store:latest
docker run -d --name sub-store --restart=always \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=$BP" \
  -e "SUB_STORE_CORS_ALLOWED_ORIGINS=https://$DOMAIN:$PORT" \
  -e "SUB_STORE_BACKEND_SYNC_CRON=55 23 * * *" \
  -p 127.0.0.1:3001:3001 \
  -v "$DATA:/opt/app/data" \
  xream/sub-store:latest >/dev/null
sleep 5
curl -fsS -o /dev/null "http://127.0.0.1:3001/" || { red "Sub-Store 没起来："; docker logs --tail 30 sub-store; exit 1; }

# ---------- 2. 证书（DNS 验证，不需要开 80 端口） ----------
grn "[2/4] 申请证书"
if command -v apt-get >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx curl socat cron >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q nginx curl socat cronie >/dev/null
elif command -v yum >/dev/null; then
  yum install -y -q nginx curl socat cronie >/dev/null
fi
[[ -x /root/.acme.sh/acme.sh ]] || curl -fsSL https://get.acme.sh | sh -s email="admin@${DOMAIN#*.}" >/dev/null
ACME=/root/.acme.sh/acme.sh
$ACME --set-default-ca --server letsencrypt >/dev/null
export CF_Token
set +e
$ACME --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
rc=$?
set -e
[[ $rc -eq 0 || $rc -eq 2 ]] || { red "证书申请失败：检查 CF_Token 权限和域名"; exit 1; }
mkdir -p /etc/nginx/ssl
$ACME --install-cert -d "$DOMAIN" --ecc \
  --key-file /etc/nginx/ssl/substore.key \
  --fullchain-file /etc/nginx/ssl/substore.crt \
  --reloadcmd "systemctl reload nginx" >/dev/null

# ---------- 3. nginx HTTPS 反代 ----------
grn "[3/4] 配置 nginx（HTTPS :$PORT）"
CONF_DIR=/etc/nginx/conf.d
cat > "$CONF_DIR/sub-store.conf" <<EOF
server {
    listen $PORT ssl;
    server_name $DOMAIN;
    ssl_certificate     /etc/nginx/ssl/substore.crt;
    ssl_certificate_key /etc/nginx/ssl/substore.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# Oracle 镜像默认用 iptables 拦截入站，放行端口
if command -v iptables >/dev/null; then
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
  fi
fi
if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null && firewall-cmd --reload >/dev/null
fi

# ---------- 4. 输出 ----------
grn "[4/4] 完成"
BASE="https://$DOMAIN:$PORT"
cat > "$INFO" <<EOF
BACKEND_PATH=$BP
管理界面：$BASE/?api=$BASE$BP

在 Sub-Store 里建一个名为 all 的组合订阅后，订阅链接为：
  mihomo（OpenClash / Clash Verge 的 proxy-providers）：
    $BASE$BP/download/collection/all?target=mihomo
  Shadowrocket（policy-path）：
    $BASE$BP/download/collection/all?target=shadowrocket
  sing-box（只有节点，完整配置用下面的文件链接）：
    $BASE$BP/download/collection/all?target=sing-box

完整配置文件（在 Sub-Store「文件」里新建后的链接）：
  OpenClash / Clash Verge：$BASE$BP/api/file/mihomo
  Shadowrocket：          $BASE$BP/api/file/shadowrocket
  sing-box：              $BASE$BP/api/file/sing-box（文件需加模板脚本和 sing-box-reject-empty.js，见 README）
EOF

# 如果模板和脚本放在同一目录，顺手把链接填进去
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=/root/sub-store-ready; mkdir -p "$OUT"
MIHOMO_SUB="$BASE$BP/download/collection/all?target=mihomo"
SR_SUB="$BASE$BP/download/collection/all?target=shadowrocket"
if [[ -f "$SRC/mihomo.yaml" ]]; then
  sed "s#https://sub.example.com:8443/BACKEND_PATH/download/collection/all?target=mihomo#$MIHOMO_SUB#" "$SRC/mihomo.yaml" > "$OUT/mihomo.yaml"
fi
if [[ -f "$SRC/shadowrocket.conf" ]]; then
  sed "s#SUBSTORE_URL#$SR_SUB#g" "$SRC/shadowrocket.conf" > "$OUT/shadowrocket.conf"
fi
# sing-box 模板由 Sub-Store 脚本按组合订阅名插入节点，不含链接，原样复制
[[ -f "$SRC/sing-box.json" ]] && cp "$SRC/sing-box.json" "$OUT/sing-box.json"
# 空回落组改为拒绝的脚本，要加在模板脚本之后（见 README）
[[ -f "$SRC/sing-box-reject-empty.js" ]] && cp "$SRC/sing-box-reject-empty.js" "$OUT/sing-box-reject-empty.js"
echo; cat "$INFO"; echo
if [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then grn "已生成填好链接的配置：$OUT/（把内容粘贴到 Sub-Store 的「文件」里）"; fi
ylw "以上信息已保存在 $INFO。后端路径就是访问密码，不要公开。"
ylw "确认没问题后，可以停掉旧的 subconverter 容器：docker stop <容器名>"
