#!/bin/bash
# sing-box 6协议一键脚本 (全系统通用：Systemd / OpenRC) - Cloudflare 增强版
# 协议: VLESS+WS | VMess+WS | Trojan+WS (支持CF CDN) | VLESS-Reality | Hysteria2 | TUIC v5

# ── 颜色与全局变量 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONF_DIR="/etc/sing-box"
CONF="${CONF_DIR}/config.json"
SERVICE_NAME="sing-box"
LAST_LINK_FILE="${CONF_DIR}/last_link.txt"
CF_ACCOUNT_PATH="${CONF_DIR}/cf_account.json"
CERT_FILE="${CONF_DIR}/cert.pem"
KEY_FILE="${CONF_DIR}/key.pem"
CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="sb-cf-lite "
INIT_SYSTEM=""

if [ "$(id -u)" != "0" ]; then
  echo -e "${RED}✗ 请使用 root 用户运行此脚本！${PLAIN}"
  exit 1
fi

# ── 初始化系统检测 ──
detect_init() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
  else
    echo -e "${RED}✗ 不支持的 init 系统（需要 systemd 或 OpenRC）${PLAIN}"
    exit 1
  fi
}

# ── 基础工具函数 ──
gen_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

gen_rand_pass() {
  head -c 16 /dev/urandom | base64 | tr -d '/+=\n'
}

gen_shortid() {
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

urlencode() {
  local s="$1" c i
  i=0
  while [ $i -lt ${#s} ]; do
    c=$(echo "$s" | cut -c $((i+1)))
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "$(printf '%s' "$c" | od -An -tu1)" ;;
    esac
    i=$((i+1))
  done
}

get_external_ip() {
  curl -s --max-time 3 ifconfig.me 2>/dev/null \
    || curl -s --max-time 3 icanhazip.com 2>/dev/null \
    || echo "127.0.0.1"
}

# ── 依赖安装 (自动适配各大发行版) ──
install_dep() {
  local pkgs=""
  command -v jq >/dev/null 2>&1 || pkgs="$pkgs jq"
  command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
  if [ -n "$pkgs" ]; then
    echo -e "${YELLOW}· 正在安装依赖: $pkgs ...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq $pkgs
    elif command -v yum >/dev/null 2>&1; then
      yum install -y $pkgs
    elif command -v apk >/dev/null 2>&1; then
      apk update && apk add $pkgs
    else
      echo -e "${RED}✗ 无法自动安装依赖，请手动安装 jq 和 curl${PLAIN}"
      exit 1
    fi
  fi
}

# ── 下载内核 ──
download_singbox() {
  mkdir -p "$CONF_DIR"
  if [ -n "${SINGBOX_MINI_URL:-}" ]; then
    echo -e "${YELLOW}· 下载自定义精简内核...${PLAIN}"
    curl -L -o /usr/bin/sing-box "$SINGBOX_MINI_URL"
  else
    echo -e "${YELLOW}· 未设置 SINGBOX_MINI_URL，尝试获取官方最新版...${PLAIN}"
    local arch
    case "$(uname -m)" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) echo -e "${RED}✗ 不支持的架构: $(uname -m)${PLAIN}"; exit 1 ;;
    esac
    
    local version url tmp_dir
    version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    [ -z "$version" ] || [ "$version" = "null" ] && version="1.9.3"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    
    tmp_dir="/tmp/sb_dl"
    mkdir -p "$tmp_dir"
    curl -L -o "$tmp_dir/sb.tar.gz" "$url"
    tar -xzf "$tmp_dir/sb.tar.gz" -C "$tmp_dir"
    mv "$tmp_dir/sing-box-${version}-linux-${arch}/sing-box" /usr/bin/sing-box
    rm -rf "$tmp_dir"
  fi

  chmod +x /usr/bin/sing-box
  if ! /usr/bin/sing-box version >/dev/null 2>&1; then
    echo -e "${RED}✗ 内核二进制不可用！${PLAIN}"
    exit 1
  fi
  echo -e "${GREEN}· 内核安装完成: $(/usr/bin/sing-box version | head -1)${PLAIN}"
}

# ── 服务管理 (自动识别 systemd / OpenRC) ──
setup_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=/usr/bin/sing-box run -c ${CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    echo -e "${GREEN}· Systemd 服务已创建并设置自启${PLAIN}"
  elif [ "$INIT_SYSTEM" = "openrc" ]; then
    cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="/usr/bin/sing-box"
command_args="run -c ${CONF}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="/var/log/${SERVICE_NAME}.log"
error_log="/var/log/${SERVICE_NAME}.log"
depend() {
  need net
}
EOF
    chmod +x /etc/init.d/${SERVICE_NAME}
    rc-update add ${SERVICE_NAME} default >/dev/null 2>&1
    echo -e "${GREEN}· OpenRC 服务已创建${PLAIN}"
  fi
}

start_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl restart ${SERVICE_NAME}
  else
    rc-service ${SERVICE_NAME} restart
  fi
}

stop_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop ${SERVICE_NAME} >/dev/null 2>&1
    systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
  else
    rc-service ${SERVICE_NAME} stop >/dev/null 2>&1
    rc-update del ${SERVICE_NAME} default >/dev/null 2>&1
    rm -f /etc/init.d/${SERVICE_NAME}
  fi
}

status_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl status ${SERVICE_NAME}
  else
    rc-service ${SERVICE_NAME} status
  fi
}

# ── Cloudflare API 模块 ──
CF_EMAIL="" CF_KEY=""
load_cf_account() {
  [ -f "$CF_ACCOUNT_PATH" ] || return 1
  CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
  CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
  [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]
}
save_cf_account() {
  mkdir -p "$CONF_DIR"
  jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
  chmod 600 "$CF_ACCOUNT_PATH"
}
cf_call() {
  local method="$1" endpoint="$2" data="${3:-}"
  local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
  [ -n "$data" ] && args+=("$data")
  curl "${args[@]}" "${CF_API}${endpoint}"
}
cf_call_raw() {
  local method="$1" endpoint="$2" data="${3:-}"
  local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
  [ -n "$data" ] && args+=("-d" "$data")
  curl "${args[@]}" "${CF_API}${endpoint}"
}
cf_verify_credentials() {
  local r
  r=$(curl -s -X GET "${CF_API}/user/tokens/verify" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
  echo "$r" | jq -e '.success == true' >/dev/null 2>&1 && return 0
  r=$(curl -s -X GET "${CF_API}/zones?per_page=1" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
  echo "$r" | jq -e '.success == true' >/dev/null 2>&1
}
prompt_cf() {
  if load_cf_account; then
    printf "检测到已保存的 CF 账号 (%s)，是否复用？(Y/n): " "$CF_EMAIL"
    read ans
    case "$ans" in
      [nN]*) ;;
      *) cf_verify_credentials && return 0; echo "凭据失效，需重新输入" ;;
    esac
  fi
  while true; do
    printf "Cloudflare 邮箱: "
    read CF_EMAIL
    printf "Cloudflare Global API Key: "
    read -r CF_KEY
    [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ] && { echo "不能为空"; continue; }
    printf "正在校验凭据... "
    if cf_verify_credentials; then
      echo -e "${GREEN}通过${PLAIN}"
      save_cf_account
      return 0
    else
      echo -e "${RED}失败，请检查后重试${PLAIN}"
    fi
  done
}
cf_find_zone() {
  local domain="$1" zones zone_name zone_id best_name="" best_id=""
  zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[]? | "\(.name) \(.id)"')
  while read -r zone_name zone_id; do
    [ -z "$zone_name" ] && continue
    if [ "$domain" = "$zone_name" ] || [ "${domain#*.$zone_name}" != "$domain" ]; then
      [ ${#zone_name} -gt ${#best_name} ] && best_name="$zone_name" && best_id="$zone_id"
    fi
  done <<EOF
$zones
EOF
  [ -n "$best_id" ] || return 1
  echo "$best_id"
}
cf_get_dns() {
  cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'
}
cf_upsert_dns() {
  local zone_id="$1" domain="$2" ip="$3"
  local payload existing rid
  payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
  existing=$(cf_get_dns "$zone_id" "$domain")
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    rid=$(echo "$existing" | jq -r '.id')
    cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" | jq -r '.result.id'
  else
    cf_call POST "/zones/${zone_id}/dns_records" "$payload" | jq -r '.result.id'
  fi
}
cf_set_ssl() { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_origin_rules() {
  cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint" | jq -r '.result.rules // []'
}
cf_put_origin_rules() {
  cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" "$(jq -n --argjson r "$2" '{rules:$r}')" >/dev/null
}
apply_origin_rules() {
  local zone_id="$1" domain="$2" proto="$3" port="$4" path="$5"
  local existing kept new_rule merged
  existing=$(cf_get_origin_rules "$zone_id")
  kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[.[] | select((.description | startswith($pfx) | not))]')
  new_rule=$(jq -n --arg d "$domain" --arg pfx "$MANAGED_PREFIX" --arg proto "$proto" --arg path "$path" --argjson port "$port" '[{
    description: ($pfx + $proto),
    enabled: true,
    expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + $path + "\")"),
    action: "route",
    action_parameters: { origin: { port: $port } }
  }]')
  merged=$(jq -n --argjson a "$kept" --argjson b "$new_rule" '$a + $b')
  cf_put_origin_rules "$zone_id" "$merged"
}

# ── 生成配置和链接 ──
gen_config() {
  local proto="$1" port="$2" ext_ip="$3"
  local uuid ws_path link cf_enabled="no" domain="" zone_id=""

  uuid=$(gen_uuid)
  ws_path="/${uuid}"
  mkdir -p "$CONF_DIR"

  if [ "$proto" = "1" ] || [ "$proto" = "2" ] || [ "$proto" = "3" ]; then
    printf "是否通过 Cloudflare (CDN) 隐藏真实 IP？(y/N): "
    read use_cf
    if [ "$use_cf" = "y" ] || [ "$use_cf" = "Y" ]; then
      cf_enabled="yes"
      prompt_cf
      while true; do
        printf "请输入你的托管域名 (例如 sub.example.com): "
        read domain
        if zone_id=$(cf_find_zone "$domain"); then
          break
        fi
        echo -e "${RED}✗ 未能在你的 CF 账号中找到该域名对应的 Zone，请重新输入${PLAIN}"
      done
    fi
  fi

  case $proto in
  1) # VLESS+WS
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": ${port},
    "users": [{"uuid": "${uuid}"}],
    "transport": {"type": "ws", "path": "${ws_path}"}
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    if [ "$cf_enabled" = "yes" ]; then
      link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&path=$(urlencode "$ws_path")#VLESS-CF-${domain}"
    else
      link="vless://${uuid}@${ext_ip}:${port}?type=ws&path=${ws_path}&security=none#VLESS-WS-${port}"
    fi
    ;;

  2) # VMess+WS
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "vmess",
    "listen": "::",
    "listen_port": ${port},
    "users": [{"uuid": "${uuid}"}],
    "transport": {"type": "ws", "path": "${ws_path}"}
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    local vmess_json
    if [ "$cf_enabled" = "yes" ]; then
      vmess_json=$(printf '{"v":"2","ps":"VMess-CF-%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls"}' \
        "$domain" "$domain" "$uuid" "$domain" "$ws_path")
    else
      vmess_json=$(printf '{"v":"2","ps":"VMess-WS-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","path":"%s"}' \
        "$port" "$ext_ip" "$port" "$uuid" "$ws_path")
    fi
    link="vmess://$(echo "$vmess_json" | base64 | tr -d '\n')"
    ;;

  3) # Trojan+WS
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "trojan",
    "listen": "::",
    "listen_port": ${port},
    "users": [{"password": "${uuid}"}],
    "transport": {"type": "ws", "path": "${ws_path}"}
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    if [ "$cf_enabled" = "yes" ]; then
      link="trojan://${uuid}@${domain}:443?security=tls&sni=${domain}&type=ws&path=$(urlencode "$ws_path")#Trojan-CF-${domain}"
    else
      link="trojan://${uuid}@${ext_ip}:${port}?type=ws&path=${ws_path}#Trojan-WS-${port}"
    fi
    ;;

  4) # VLESS-Reality
    gen_reality_keypair
    local reality_sid
    reality_sid=$(gen_shortid)
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": ${port},
    "users": [{"uuid": "${uuid}", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "www.apple.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "www.apple.com", "server_port": 443},
        "private_key": "${REALITY_PRIVATE}",
        "short_id": ["${reality_sid}"]
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    link="vless://${uuid}@${ext_ip}:${port}?security=reality&sni=www.apple.com&pbk=${REALITY_PUBLIC}&sid=${reality_sid}&fp=chrome&flow=xtls-rprx-vision#VLESS-Reality-${port}"
    ;;

  5) # Hysteria2 (UDP)
    [ ! -f "$CERT_FILE" ] && /usr/bin/sing-box generate certificate -c "$CERT_FILE" -k "$KEY_FILE" 2>/dev/null
    local hy2_pass; hy2_pass=$(gen_rand_pass)
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": ${port},
    "password": "${hy2_pass}",
    "tls": {
      "enabled": true,
      "alpn": ["h3"],
      "certificate_path": "${CERT_FILE}",
      "key_path": "${KEY_FILE}"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    link="hysteria2://${hy2_pass}@${ext_ip}:${port}/?insecure=1&sni=www.bing.com#Hysteria2-${port}"
    ;;

  6) # TUIC v5 (UDP)
    [ ! -f "$CERT_FILE" ] && /usr/bin/sing-box generate certificate -c "$CERT_FILE" -k "$KEY_FILE" 2>/dev/null
    local tuic_pass; tuic_pass=$(gen_rand_pass)
    cat > "$CONF" <<JSON
{
  "inbounds": [{
    "type": "tuic",
    "listen": "::",
    "listen_port": ${port},
    "uuid": "${uuid}",
    "password": "${tuic_pass}",
    "congestion_control": "bbr",
    "tls": {
      "enabled": true,
      "alpn": ["h3"],
      "certificate_path": "${CERT_FILE}",
      "key_path": "${KEY_FILE}"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    link="tuic://${uuid}:${tuic_pass}@${ext_ip}:${port}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUICv5-${port}"
    ;;
  esac

  if ! jq . "$CONF" >/dev/null 2>&1; then
    echo -e "${RED}✗ 配置文件生成错误！${PLAIN}"
    exit 1
  fi

  if [ "$cf_enabled" = "yes" ]; then
    echo -e "${YELLOW}· 正在配置 Cloudflare DNS 及 Origin Rules...${PLAIN}"
    cf_upsert_dns "$zone_id" "$domain" "$ext_ip" >/dev/null
    cf_set_ssl "$zone_id" "flexible"
    local proto_name_str
    case $proto in 1) proto_name_str="vless";; 2) proto_name_str="vmess";; 3) proto_name_str="trojan";; esac
    apply_origin_rules "$zone_id" "$domain" "$proto_name_str" "$port" "$ws_path"
    echo -e "${GREEN}✓ Cloudflare 加速代理配置成功！${PLAIN}"
  fi

  echo "$link" > "$LAST_LINK_FILE"

  echo -e "\n${GREEN}==================== 节点信息 ====================${PLAIN}"
  echo "  协议   : $(proto_name "$proto")"
  echo "  端口   : ${port}"
  [ "$cf_enabled" = "yes" ] && echo "  代理域名: ${domain} (通过 CF 443 端口)" || echo "  外部IP : ${ext_ip}"
  echo -e "${GREEN}----------------------------------------------------${PLAIN}"
  echo -e "  节点链接:\n  ${YELLOW}${link}${PLAIN}"
  echo -e "${GREEN}====================================================${PLAIN}\n"
}

proto_name() {
  case $1 in
  1) echo "VLESS+WS" ;; 2) echo "VMess+WS" ;; 3) echo "Trojan+WS" ;;
  4) echo "VLESS-Reality" ;; 5) echo "Hysteria2" ;; 6) echo "TUIC v5" ;;
  esac
}

menu_proto() {
  echo -e "\n===== 协议选择 ====="
  echo "  1) VLESS+WS (支持 Cloudflare CDN 代理)"
  echo "  2) VMess+WS (支持 Cloudflare CDN 代理)"
  echo "  3) Trojan+WS (支持 Cloudflare CDN 代理)"
  echo "  4) VLESS-Reality (直连高性能)"
  echo "  5) Hysteria2 (UDP 高速直连)"
  echo "  6) TUIC v5 (UDP 高速直连)"
  printf "请选择协议 [1-6]: "
  read proto_sel
  if ! echo "$proto_sel" | grep -qE '^[1-6]$'; then
    echo -e "${RED}✗ 只能选择 1-6${PLAIN}"
    return 1
  fi

  printf "输入本地监听端口 (10000-60000) [默认随机]: "
  read lport
  if [ -z "$lport" ]; then
    lport=$(awk -v min=10000 -v max=60000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')
    echo -e "${YELLOW}· 已分配随机端口: $lport${PLAIN}"
  elif ! echo "$lport" | grep -qE '^[0-9]+$' || [ "$lport" -lt 10000 ] || [ "$lport" -gt 60000 ]; then
    echo -e "${RED}✗ 端口非法${PLAIN}"
    return 1
  fi

  local ext_ip
  ext_ip=$(get_external_ip)
  gen_config "$proto_sel" "$lport" "$ext_ip"

  start_service
  echo -e "${GREEN}· sing-box 服务已启动！${PLAIN}"
}

menu_main() {
  detect_init
  while true; do
    echo -e "\n  ╔══════════════════════════════════════════╗"
    echo -e "  ║   ${GREEN}sing-box 6协议 (全系统/CF支持)${PLAIN}       ║"
    echo -e "  ╚══════════════════════════════════════════╝\n"
    echo "  1. 安装 / 部署新节点"
    echo "  2. 卸载 sing-box"
    echo "  3. 查看当前节点链接"
    echo "  4. 查看当前配置文件"
    echo "  5. 重启 sing-box 服务"
    echo "  6. 查看服务状态与日志"
    echo "  0. 退出"
    echo ""
    printf "请选择 [0-6]: "
    read opt
    case $opt in
    1)
      install_dep
      [ ! -f /usr/bin/sing-box ] && download_singbox
      setup_service
      menu_proto
      ;;
    2)
      printf "确认完全卸载？(y/N): "
      read confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        stop_service
        rm -rf "$CONF_DIR"
        rm -f /usr/bin/sing-box
        echo -e "${GREEN}· 卸载完成${PLAIN}"
      else
        echo "· 已取消"
      fi
      ;;
    3)
      [ -f "$LAST_LINK_FILE" ] && echo -e "\n${YELLOW}当前链接:${PLAIN}\n$(cat "$LAST_LINK_FILE")\n" || echo -e "${RED}· 暂无节点${PLAIN}"
      ;;
    4)
      [ -f "$CONF" ] && cat "$CONF" || echo -e "${RED}· 配置文件不存在${PLAIN}"
      ;;
    5)
      start_service
      echo -e "${GREEN}· 已重启${PLAIN}"
      ;;
    6)
      status_service
      ;;
    0)
      exit 0
      ;;
    *)
      echo -e "${RED}✗ 无效输入${PLAIN}"
      ;;
    esac
  done
}

menu_main
