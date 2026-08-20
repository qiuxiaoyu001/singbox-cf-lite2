#!/usr/bin/env bash
set -euo pipefail
# ═══════════════════════════════════════════════════════════
#  sing-box-cf-lite  —  六协议一键脚本
#  CF类(走Cloudflare): VLESS+WS | VMess+WS | Trojan+WS
#  直连类(IP直达):     VLESS-Reality | Hysteria2 | TUIC v5
#  内核: sing-box 精简版 (UPX) · 64M小鸡可跑
# ═══════════════════════════════════════════════════════════

# ── 常量 ──────────────────────────────────────────────
SINGBOX_CONF_DIR="/etc/sing-box/conf"
SINGBOX_BINARY="/usr/local/bin/sing-box"
SINGBOX_WORK_DIR="/etc/sing-box"
STATE_DIR="/etc/singbox-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
LAST_LINKS_PATH="$(pwd)/sb_cf_lite_last_links.txt"
CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="sb-cf-lite "
SINGBOX_MINI_URL="${SINGBOX_MINI_URL:-}"
SINGBOX_OFFICIAL_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

declare -A PROTO_LABEL=([vless]="VLESS+WS" [trojan]="Trojan+WS" [vmess]="VMess+WS" [reality]="VLESS-Reality" [hysteria2]="Hysteria2" [tuic]="TUIC v5")
declare -A PROTO_MODE=([vless]=cf [trojan]=cf [vmess]=cf [reality]=direct [hysteria2]=direct [tuic]=direct)
declare -A PROTO_SUFFIX=([vless]=vl [trojan]=tr [vmess]=vm)

# ── 工具 ──────────────────────────────────────────────
die()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()      { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info()    { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
warn()    { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }
need_cmd(){ command -v "$1" &>/dev/null || die "缺少依赖: $1"; }
b64()     { base64 | tr -d '\n'; }

urlencode() {
    local s="$1" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }
gen_rand_pass() { head -c 16 /dev/urandom | base64 | tr -d '/+=\n'; }
gen_shortid() { head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_reality_keypair() {
    local tmp
    tmp=$("$SINGBOX_BINARY" generate reality-keypair 2>/dev/null)
    REALITY_PRIVATE=$(echo "$tmp" | grep -i "PrivateKey" | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$tmp" | grep -i "PublicKey" | awk '{print $2}')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "Reality 密钥生成失败，内核需 with_reality tag"
}

# ── 内存检测（64M 小鸡优化）──────────────────────────
get_mem_mb() {
    local mem
    mem=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
    [[ -z "$mem" || "$mem" == "0" ]] && mem=999
    echo "$mem"
}
ensure_swap() {
    local mem
    mem=$(get_mem_mb)
    [[ "$mem" -ge 128 ]] && return 0
    if ! swapon --show 2>/dev/null | grep -q .; then
        info "低内存 (${mem}MB) 检测到无 swap，自动创建 128M swap..."
        fallocate -l 128M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=128 2>/dev/null || true
        if [[ -f /swapfile ]]; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile 2>/dev/null && ok "swap 已启用 (128M)" || warn "swap 启用失败，请手动配置"
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi
}

# ── init 系统检测 ─────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 包管理器 ──────────────────────────────────────────
install_deps() {
    local missing=()
    command -v curl  &>/dev/null || missing+=(curl)
    command -v jq    &>/dev/null || missing+=(jq)
    [[ ${#missing[@]} -eq 0 ]] && return
    echo "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖，请手动安装 curl jq"
    fi
}

# ── sing-box 服务管理 ─────────────────────────────────
SINGBOX_OPENRC_SCRIPT="/etc/init.d/sing-box"
write_openrc_script() {
    cat > "$SINGBOX_OPENRC_SCRIPT" << 'INITEOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy server (cf-lite)"
command="/usr/local/bin/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
respawn_delay=1
respawn_max=0
respawn_period=86400
supervise_daemon_args="--respawn-delay ${respawn_delay} --respawn-max ${respawn_max} --respawn-period ${respawn_period}"
supervisor=supervise-daemon
depend() { need net; after firewall; }
INITEOF
    chmod +x "$SINGBOX_OPENRC_SCRIPT"
}
write_systemd_service() {
    local mem_limit="" total_mem
    total_mem=$(get_mem_mb)
    if [[ "$total_mem" -lt 128 ]]; then
        mem_limit="MemoryMax=56M
MemoryHigh=48M"
    fi
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service (cf-lite)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=${SINGBOX_WORK_DIR}
ExecStart=${SINGBOX_BINARY} run -C ${SINGBOX_CONF_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=1
LimitNOFILE=infinity
${mem_limit}
[Install]
WantedBy=multi-user.target
EOF
}
svc_enable()    { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl enable sing-box &>/dev/null; else rc-update add sing-box default &>/dev/null; fi; true; }
svc_start()     { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart sing-box; else [[ -f "$SINGBOX_OPENRC_SCRIPT" ]] || write_openrc_script; rc-service sing-box restart; fi; }
svc_stop()      { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl stop sing-box &>/dev/null; systemctl disable sing-box &>/dev/null; else rc-service sing-box stop &>/dev/null; rc-update del sing-box default &>/dev/null; fi; true; }
svc_is_active() { if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active sing-box &>/dev/null; else rc-service sing-box status &>/dev/null 2>&1; fi; }
restart_singbox() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && write_systemd_service && systemctl daemon-reload
    svc_enable
    svc_start || die "sing-box 重启失败"
    sleep 1
    svc_is_active || die "sing-box 未正常启动，请查看日志"
    ok "sing-box 服务已启动"
}

# ── 网络检测 ─────────────────────────────────────────
get_public_ip() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    die "获取公网 IPv4 失败"
}
detect_nat() {
    local public_ip
    public_ip=$(get_public_ip)
    if ip addr show 2>/dev/null | grep -qE "inet ${public_ip}/"; then
        echo "direct"; return
    fi
    echo "nat"
}
net_mode_label() { [[ "$1" == "direct" ]] && echo "直连" || echo "NAT"; }
prompt_net_mode() {
    local detected="$1" ans
    echo >&2
    info "网络环境探测结果: $(net_mode_label "$detected")" >&2
    read -rp "使用哪种模式? (1=直连, 2=NAT, 回车=用探测结果): " ans
    case "$ans" in 1) echo "direct" ;; 2) echo "nat" ;; "") echo "$detected" ;; *) die "无效选项" ;; esac
}
get_listening_ports() { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' '; }
rand_port() {
    local existing="$1" p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
}

# ── CF API ────────────────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}
cf_call_raw() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

# ── CF 凭据 ───────────────────────────────────────────
CF_EMAIL="" CF_KEY=""
load_cf_account() {
    [[ -f "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}
save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}
cf_verify_credentials() {
    local r
    r=$(curl -s -X GET "${CF_API}/user/tokens/verify" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null && return 0
    r=$(curl -s -X GET "${CF_API}/zones?per_page=1" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null
}
prompt_cf() {
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}"
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]]; then
            cf_verify_credentials && return 0
            echo "已保存的 CF 凭据校验失败，请重新输入"
        fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入已中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入已中断"; echo
        [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]] && { echo "邮箱和 API Key 不能为空"; continue; }
        echo -n "校验凭据... "
        if cf_verify_credentials; then echo "通过"; save_cf_account; return 0; fi
        echo "失败：邮箱或 API Key 错误"
    done
}

# ── CF DNS / SSL / Origin Rules / 安全规则 ────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zone_name zone_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            [[ ${#zone_name} -gt ${#best_name} ]] && best_name="$zone_name" && best_id="$zone_id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}
cf_get_dns() { cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'; }
cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3" payload existing
    payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
    existing=$(cf_get_dns "$zone_id" "$domain")
    if [[ -n "$existing" ]]; then
        local rid; rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/${zone_id}/dns_records/${rid}" "$payload" | jq -r '.result.id'
    else
        cf_call POST "/zones/${zone_id}/dns_records" "$payload" | jq -r '.result.id'
    fi
}
cf_get_ssl()  { cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value'; }
cf_set_ssl()  { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }
cf_set_bot_fight_off() {
    local zone_id="$1"
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$(jq -n '{enable_js:false,sbfm_likely_automated:"allow",sbfm_definitely_automated:"allow",sbfm_verified_bots:"allow",sbfm_static_resource_protection:false}')" | jq -e '.success' &>/dev/null
}
cf_restore_bot_management() {
    local zone_id="$1" backup="$2" payload
    payload=$(echo "$backup" | jq '{enable_js:.enable_js,sbfm_likely_automated:.sbfm_likely_automated,sbfm_definitely_automated:.sbfm_definitely_automated,sbfm_verified_bots:.sbfm_verified_bots,sbfm_static_resource_protection:.sbfm_static_resource_protection}')
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$payload" | jq -e '.success' &>/dev/null
}
cf_relax_security() {
    local zone_id="$1" sec_level bot_mgmt browser_check
    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")
    [[ "$sec_level" != "essentially_off" ]] && { cf_set_security_level "$zone_id" "essentially_off"; ok "Security Level: essentially_off"; }
    [[ "$browser_check" != "off" ]] && { cf_set_browser_check "$zone_id" "off"; ok "Browser Check: off"; }
    local sbfm_likely; sbfm_likely=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    [[ "$sbfm_likely" != "allow" ]] && { cf_set_bot_fight_off "$zone_id"; ok "Bot Fight Mode: 已关闭"; }
    jq -n --arg sl "$sec_level" --arg bc "$browser_check" --argjson bm "$bot_mgmt" '{security_level:$sl,browser_check:$bc,bot_management:$bm}'
}
cf_restore_security() {
    local zone_id="$1" backup="$2" sl bc bm
    [[ -z "$backup" || "$backup" == "null" ]] && return
    sl=$(echo "$backup" | jq -r '.security_level // ""')
    bc=$(echo "$backup" | jq -r '.browser_check // ""')
    bm=$(echo "$backup" | jq '.bot_management // null')
    [[ -n "$sl" ]] && cf_set_security_level "$zone_id" "$sl" && ok "Security Level 已恢复: $sl"
    [[ -n "$bc" ]] && cf_set_browser_check "$zone_id" "$bc" && ok "Browser Check 已恢复: $bc"
    [[ "$bm" != "null" ]] && cf_restore_bot_management "$zone_id" "$bm" && ok "Bot Fight Mode 已恢复"
}
cf_get_origin_rules() {
    local r; r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint")
    echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}
cf_put_origin_rules() {
    local r; r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" "$(jq -n --argjson r "$2" '{rules:$r}')")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}
build_new_origin_rules() {
    local domain="$1" routes_json="$2"
    echo "$routes_json" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | {
            description: ($pfx + .protocol + " " + .path),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + .path + "\")"),
            action: "route",
            action_parameters: { origin: { port: .cf_port } }
        }
    ]'
}
apply_origin_rules() {
    local zone_id="$1" domain="$2" routes_json="$3" existing kept new_managed merged
    existing=$(cf_get_origin_rules "$zone_id")
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | select((.description | startswith($pfx) | not) or (.expression | ascii_downcase | contains("http.host eq \"" + ($d|ascii_downcase) + "\"") | not))
    ]')
    new_managed=$(build_new_origin_rules "$domain" "$routes_json")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b')
    cf_put_origin_rules "$zone_id" "$merged"
}

# ── sing-box 安装 ─────────────────────────────────────
get_singbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;; i386|i686) echo "386" ;; s390x) echo "s390x" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}
install_singbox() {
    echo "正在安装 sing-box ..."
    [[ -f "$SINGBOX_BINARY" ]] && { ok "sing-box 已安装，跳过"; return; }
    local arch; arch=$(get_singbox_arch)
    local mem; mem=$(get_mem_mb)
    local download_url=""
    if [[ -n "$SINGBOX_MINI_URL" ]]; then
        download_url="$SINGBOX_MINI_URL"
        info "使用自定义精简版地址"
    elif [[ "$mem" -lt 128 ]]; then
        warn "检测到内存仅 ${mem}MB，建议使用精简版 (UPX)"
        echo "  设置: export SINGBOX_MINI_URL=https://你的地址/sing-box-linux-${arch}"
        read -rp "继续用官方完整版? (y/N): " use_official
        [[ "${use_official,,}" =~ ^(y|yes)$ ]] || die "已取消，请先配置 SINGBOX_MINI_URL"
    fi
    mkdir -p "$SINGBOX_WORK_DIR" "$SINGBOX_CONF_DIR"
    if [[ -n "$download_url" ]]; then
        info "下载精简版 sing-box (${arch})..."
        curl -fsSL "$download_url" -o "$SINGBOX_BINARY" || die "精简版下载失败"
        chmod +x "$SINGBOX_BINARY"
    else
        local ver=""; ver=$(curl -sf "$SINGBOX_OFFICIAL_API" 2>/dev/null | jq -r '.tag_name' 2>/dev/null) || true
        [[ -n "$ver" && "$ver" != "null" ]] && ver="${ver#v}" || ver="1.11.0"
        info "下载 sing-box v${ver} (linux/${arch})..."
        local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
        local tmp="/tmp/sb-install-$$"; mkdir -p "$tmp"
        curl -fsSL -o "$tmp/sb.tar.gz" "$url" || die "下载失败"
        tar xzf "$tmp/sb.tar.gz" -C "$tmp/"
        cp "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$SINGBOX_BINARY"
        chmod +x "$SINGBOX_BINARY"; rm -rf "$tmp"
    fi
    "$SINGBOX_BINARY" version >/dev/null 2>&1 || die "sing-box 二进制不可用"
    ok "sing-box 安装完成: $("$SINGBOX_BINARY" version 2>/dev/null | head -1)"
}

# ── sing-box 配置生成（六协议）────────────────────────
gen_singbox_config() {
    local routes_json="$1" uid="$2" rpk="${3:-}" rsid="${4:-}" hpass="${5:-}" tpass="${6:-}"
    local conf_dir="$SINGBOX_CONF_DIR"; mkdir -p "$conf_dir"
    cat > "$conf_dir/log.json" << 'EOF'
{"log":{"disabled":false,"level":"error","output":"/etc/sing-box/sing-box.log","timestamp":false}}
EOF
    cat > "$conf_dir/dns.json" << 'EOF'
{"dns":{"servers":[{"tag":"local","type":"local"}],"strategy":"ipv4_only"}}
EOF
    local inbounds
    inbounds=$(echo "$routes_json" | jq \
        --arg uid "$uid" --arg rpk "$rpk" --arg rsid "$rsid" --arg hpass "$hpass" --arg tpass "$tpass" \
        '[.[] |
            if .protocol == "vless" then
                {tag:("in-vless-"+(.listen_port|tostring)), type:"vless", listen:"::", listen_port:.listen_port,
                 users:[{"uuid":$uid}], transport:{"type":"ws","path":.path}}
            elif .protocol == "vmess" then
                {tag:("in-vmess-"+(.listen_port|tostring)), type:"vmess", listen:"::", listen_port:.listen_port,
                 users:[{"uuid":$uid}], transport:{"type":"ws","path":.path}}
            elif .protocol == "trojan" then
                {tag:("in-trojan-"+(.listen_port|tostring)), type:"trojan", listen:"::", listen_port:.listen_port,
                 users:[{"password":$uid}], transport:{"type":"ws","path":.path}}
            elif .protocol == "reality" then
                {tag:("in-reality-"+(.listen_port|tostring)), type:"vless", listen:"::", listen_port:.listen_port,
                 users:[{"uuid":$uid,"flow":"xtls-rprx-vision"}],
                 tls:{enabled:true, server_name:"www.apple.com",
                      reality:{enabled:true, handshake:{server:"www.apple.com",server_port:443},
                               private_key:$rpk, short_id:[$rsid]}}}
            elif .protocol == "hysteria2" then
                {tag:("in-hysteria2-"+(.listen_port|tostring)), type:"hysteria2", listen:"::", listen_port:.listen_port, password:$hpass}
            elif .protocol == "tuic" then
                {tag:("in-tuic-"+(.listen_port|tostring)), type:"tuic", listen:"::", listen_port:.listen_port, uuid:$uid, password:$tpass, congestion_control:"bbr"}
            end
        ]')
    echo "{\"inbounds\":$inbounds}" > "$conf_dir/inbounds.json"
    cat > "$conf_dir/outbounds.json" << 'EOF'
{"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
    cat > "$conf_dir/route.json" << 'EOF'
{"route":{"final":"direct"}}
EOF
    ok "sing-box 配置已写入 $conf_dir/"
}

# ── 链接生成（六协议）────────────────────────────────
# ★ 修复: 直连协议(reality/hysteria2/tuic)使用外网端口 cf_port，而非内网监听端口
build_link() {
    local route_json="$1" uid="$2" host="$3" rpub="${4:-}" rsid="${5:-}" hpass="${6:-}" tpass="${7:-}"
    local proto listen_port ext_port path mode
    proto=$(echo "$route_json" | jq -r '.protocol')
    listen_port=$(echo "$route_json" | jq -r '.listen_port')
    ext_port=$(echo "$route_json" | jq -r '.cf_port')
    path=$(echo "$route_json" | jq -r '.path // ""')
    mode=$(echo "$route_json" | jq -r '.mode')
    case $proto in
    vless)
        echo "vless://${uid}@${host}:443?type=ws&path=$(urlencode "$path")&security=tls&sni=${host}#VLESS-WS-${host}"
        ;;
    vmess)
        local vj; vj=$(printf '{"v":"2","ps":"VMess-WS","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","path":"%s","tls":"tls","sni":"%s"}' "$host" "$uid" "$path" "$host")
        echo "vmess://$(echo "$vj" | b64)"
        ;;
    trojan)
        echo "trojan://${uid}@${host}:443?type=ws&path=$(urlencode "$path")&security=tls&sni=${host}#Trojan-WS-${host}"
        ;;
    reality)
        # 直连协议用外网端口 ext_port
        echo "vless://${uid}@${host}:${ext_port}?security=reality&sni=www.apple.com&pbk=${rpub}&sid=${rsid}&fp=chrome&flow=xtls-rprx-vision#VLESS-Reality-${ext_port}"
        ;;
    hysteria2)
        echo "hysteria2://${hpass}@${host}:${ext_port}/?insecure=1#Hysteria2-${ext_port}"
        ;;
    tuic)
        echo "tuic://${uid}:${tpass}@${host}:${ext_port}/?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUICv5-${ext_port}"
        ;;
    esac
}
gen_all_links() {
    local routes_json="$1" uid="$2" host="$3" rpub="${4:-}" rsid="${5:-}" hpass="${6:-}" tpass="${7:-}"
    local links_json='{}' count i route_json link proto
    count=$(echo "$routes_json" | jq 'length')
    for ((i=0; i<count; i++)); do
        route_json=$(echo "$routes_json" | jq ".[$i]")
        proto=$(echo "$route_json" | jq -r '.protocol')
        link=$(build_link "$route_json" "$uid" "$host" "$rpub" "$rsid" "$hpass" "$tpass")
        links_json=$(echo "$links_json" | jq --arg p "$proto" --arg l "$link" '. + {($p):$l}')
    done
    echo "$links_json"
}

# ── 状态 ──────────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }
save_links_snapshot() {
    local domain="$1" uid="$2" links_json="$3"
    { echo "域名/IP: $domain"; echo "UUID: $uid"; echo
      echo "$links_json" | jq -r 'to_entries[] | "\(.key) \(.value)"'
    } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}
print_links() {
    local links_json="$1" proto link
    while IFS=$'\t' read -r proto link; do
        echo "  ${PROTO_LABEL[$proto]:-$proto}  $link"
    done < <(echo "$links_json" | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

# ── 交互辅助 ─────────────────────────────────────────
prompt_protocols() {
    echo ""
    echo "  ═══ 协议选择（逗号分隔，可自由组合）═══"
    echo "    走 Cloudflare (TCP/WS):"
    echo "      1 = VLESS+WS    2 = Trojan+WS    3 = VMess+WS"
    echo "    直连 IP (不走 CF):"
    echo "      4 = VLESS-Reality    5 = Hysteria2    6 = TUIC v5"
    echo ""
    echo "  示例: 输入 1,4  = VLESS+WS走CF + Reality直连"
    echo "        输入 4,5,6 = 三个直连协议，不需要CF"
    echo "        输入 1,2,3 = 三个WS协议全部走CF"
    read -rp "选择协议编号(留空=1,2,3): " proto_raw
    local protocols=()
    if [[ -z "$proto_raw" ]]; then
        protocols=(vless trojan vmess)
    else
        local -A pmap=([1]=vless [2]=trojan [3]=vmess [4]=reality [5]=hysteria2 [6]=tuic)
        IFS=',' read -ra tokens <<< "$proto_raw"
        for t in "${tokens[@]}"; do
            t="${t// /}"
            [[ -n "${pmap[$t]:-}" ]] || die "未知协议编号: $t (可选1-6)"
            protocols+=("${pmap[$t]}")
        done
    fi
    echo "${protocols[@]}"
}
prompt_uuid() {
    local uid
    read -rp "UUID(留空=自动生成): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uid="${custom_uuid,,}"
    else
        uid=$(gen_uuid)
    fi
    echo "$uid"
}
prompt_path_prefix() {
    local default="$1" pfx
    read -rp "WS 路径前缀(留空=/${default}): " pfx
    [[ -z "$pfx" ]] && pfx="/${default}"
    [[ "$pfx" == /* ]] || pfx="/${pfx}"
    echo "$pfx"
}
has_cf_proto() { echo "$1" | jq -e '[.[] | select(.mode=="cf")] | length > 0' >/dev/null 2>&1; }

# ★ 重写: 逐个协议单独配置端口，NAT模式下分别问内网和外网端口
build_routes() {
    local net_mode="$1" path_prefix="$2"; shift 2
    local protocols=("$@")
    local routes_json='[]' existing_ports
    existing_ports=$(get_listening_ports)

    echo ""
    if [[ "$net_mode" == "nat" ]]; then
        info "NAT 模式: 逐个协议配置 内网监听端口 和 外网映射端口"
    else
        info "直连模式: 逐个协议配置监听端口（内网=外网）"
    fi
    echo ""

    for proto in "${protocols[@]}"; do
        local mode="${PROTO_MODE[$proto]}"
        local label="${PROTO_LABEL[$proto]}"
        local listen_port ext_port path=""

        if [[ "$net_mode" == "nat" ]]; then
            # NAT模式: 分别问内网和外网端口
            while true; do
                read -rp "  [$label] 内网监听端口(sing-box实际监听): " listen_port
                [[ "$listen_port" =~ ^[0-9]+$ ]] && break
                echo "    请输入数字端口"
            done
            while true; do
                read -rp "  [$label] 外网映射端口(路由器/防火墙对外暴露): " ext_port
                [[ "$ext_port" =~ ^[0-9]+$ ]] && break
                echo "    请输入数字端口"
            done
        else
            # 直连模式: 单个端口，回车随机
            read -rp "  [$label] 监听端口(留空=随机): " listen_port
            if [[ -z "$listen_port" ]]; then
                listen_port=$(rand_port "$existing_ports")
            else
                [[ "$listen_port" =~ ^[0-9]+$ ]] || die "无效端口: $listen_port"
            fi
            ext_port="$listen_port"
        fi
        existing_ports="$existing_ports $listen_port"

        # CF类协议需要WS路径
        if [[ "$mode" == "cf" ]]; then
            path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
        fi

        routes_json=$(echo "$routes_json" | jq \
            --arg p "$proto" --arg m "$mode" \
            --argjson lp "$((listen_port))" --argjson cp "$((ext_port))" --arg pa "$path" \
            '. + [{protocol:$p, mode:$m, listen_port:$lp, cf_port:$cp, path:$pa}]')
    done
    echo "$routes_json"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置，请先卸载"
    ensure_swap
    [[ -f "$SINGBOX_BINARY" ]] && ok "sing-box 已安装" || install_singbox
    local net_mode; net_mode=$(prompt_net_mode "$(detect_nat)")
    ok "网络模式: $(net_mode_label "$net_mode")"

    local protocols_str; protocols_str=$(prompt_protocols)
    read -ra protocols <<< "$protocols_str"

    local need_cf=false
    for p in "${protocols[@]}"; do [[ "${PROTO_MODE[$p]}" == "cf" ]] && need_cf=true; done

    local domain="" zone_id=""
    if $need_cf; then
        prompt_cf
        while true; do
            read -rp "绑定域名(用于CF): " domain || die "输入已中断"
            [[ -z "$domain" ]] && { echo "域名不能为空"; continue; }
            if zone_id=$(cf_find_zone "$domain"); then info "匹配到 Zone: $zone_id"; break; fi
            echo "无法匹配 Zone，请确认域名已托管"
        done
    else
        info "仅直连类协议，无需 Cloudflare，直接用公网 IP"
    fi

    local uid; uid=$(prompt_uuid)
    local reality_private="" reality_public="" reality_sid="" hysteria2_pass="" tuic_pass=""
    for p in "${protocols[@]}"; do
        case $p in
        reality) gen_reality_keypair; reality_sid=$(gen_shortid); ok "Reality 密钥已生成" ;;
        hysteria2) hysteria2_pass=$(gen_rand_pass); ok "Hysteria2 密码已生成" ;;
        tuic) tuic_pass=$(gen_rand_pass); ok "TUIC 密码已生成" ;;
        esac
    done

    local path_prefix=""
    if $need_cf; then path_prefix=$(prompt_path_prefix "${uid:0:8}"); fi

    local routes_json; routes_json=$(build_routes "$net_mode" "$path_prefix" "${protocols[@]}")

    echo ""; echo "═══ 配置预览 ═══"
    [[ -n "$domain" ]] && echo "  域名:    $domain"
    echo "  UUID:    $uid"
    echo "  模式:    $(net_mode_label "$net_mode")"
    echo ""
    echo "$routes_json" | jq -r '.[] | "  [\(.protocol)] 模式:\(.mode)  内网:\(.listen_port)  外网:\(.cf_port)  路径:\(.path//"(无)")"'
    echo ""
    [[ -n "$reality_public" ]] && echo "  Reality公钥: $reality_public"
    [[ -n "$hysteria2_pass" ]] && echo "  Hysteria2密码: $hysteria2_pass"
    [[ -n "$tuic_pass" ]] && echo "  TUIC密码: $tuic_pass"
    echo ""
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    gen_singbox_config "$routes_json" "$uid" "$reality_private" "$reality_sid" "$hysteria2_pass" "$tuic_pass"
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$SINGBOX_OPENRC_SCRIPT" ]] && write_openrc_script && ok "OpenRC 服务脚本已创建"
    restart_singbox

    local public_ip; public_ip=$(get_public_ip)
    local dns_before="null" ssl_before="" origin_rules_before="[]" dns_record_id="" security_backup="null"
    if $need_cf; then
        dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
        [[ "$dns_before" == "" ]] && dns_before="null"
        ssl_before=$(cf_get_ssl "$zone_id")
        origin_rules_before=$(cf_get_origin_rules "$zone_id")
        dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
        ok "DNS A 记录: $domain -> $public_ip (已代理)"
        cf_set_ssl "$zone_id" "flexible"
        ok "SSL 模式: flexible (CF边缘TLS)"
        local cf_routes; cf_routes=$(echo "$routes_json" | jq '[.[] | select(.mode=="cf")]')
        apply_origin_rules "$zone_id" "$domain" "$cf_routes"
        ok "Origin Rules: $(echo "$cf_routes" | jq 'length') 条"
        security_backup=$(cf_relax_security "$zone_id")
    fi

    local host; $need_cf && host="$domain" || host="$public_ip"
    local links_json; links_json=$(gen_all_links "$routes_json" "$uid" "$host" "$reality_public" "$reality_sid" "$hysteria2_pass" "$tuic_pass")
    save_links_snapshot "$host" "$uid" "$links_json"

    local dns_existed="false"; [[ "$dns_before" != "null" ]] && dns_existed="true"
    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg mode "$net_mode" \
        --argjson routes "$routes_json" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_rules_before" --argjson links "$links_json" \
        --argjson secbk "$security_backup" \
        --arg rpk "$reality_private" --arg rpub "$reality_public" --arg rsid "$reality_sid" \
        --arg hpass "$hysteria2_pass" --arg tpass "$tuic_pass" \
        '{domain:$d,zone_id:$z,uuid:$u,net_mode:$mode,routes:$routes,
          managed_dns_record_id:$drid,dns_backup:{existed:$dex,record:$drec},
          ssl_backup:$ssl,origin_rules_backup:$orbk,security_backup:$secbk,links:$links,
          reality_private:$rpk,reality_public:$rpub,reality_sid:$rsid,hysteria2_pass:$hpass,tuic_pass:$tpass}')"

    echo ""; ok "部署完成"; echo ""
    print_links "$links_json"
    echo ""; echo "节点链接已保存到 $LAST_LINKS_PATH"
    $need_cf && { echo ""; echo "CF类协议客户端: 地址=$domain 端口=443 TLS=开启 SNI=$domain 网络=WS"; }
    echo ""; echo "⚠ Hysteria2/TUIC 为 UDP 协议，需确保安全组/防火墙放行对应 UDP 外网端口"
}

# ── 2. 卸载 ──────────────────────────────────────────
do_uninstall() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到上次配置"
    local domain; domain=$(echo "$state" | jq -r '.domain // "直连模式"')
    echo "正在卸载: $domain"
    svc_stop; rm -rf "$SINGBOX_CONF_DIR"
    ok "sing-box 已停止"
    if load_cf_account && [[ -n "$(echo "$state" | jq -r '.zone_id // ""')" ]]; then
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id')
        cf_put_origin_rules "$zone_id" "$(echo "$state" | jq '.origin_rules_backup // []')"
        ok "Origin Rules 已恢复"
        local ssl_bk; ssl_bk=$(echo "$state" | jq -r '.ssl_backup // ""')
        [[ -n "$ssl_bk" ]] && cf_set_ssl "$zone_id" "$ssl_bk" && ok "SSL: $ssl_bk"
        local dns_existed record_id
        dns_existed=$(echo "$state" | jq -r '.dns_backup.existed')
        record_id=$(echo "$state" | jq -r '.managed_dns_record_id // ""')
        if [[ "$dns_existed" == "true" ]]; then
            local rp; rp=$(echo "$state" | jq '.dns_backup.record | {type:(.type//"A"),name:(.name//""),content:(.content//""),proxied:(.proxied//false),ttl:(.ttl//1)}')
            cf_call PUT "/zones/${zone_id}/dns_records/${record_id}" "$rp" >/dev/null
            ok "DNS 已恢复"
        elif [[ -n "$record_id" ]]; then
            cf_call_raw DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null 2>&1 || true
            ok "DNS 已删除"
        fi
        cf_restore_security "$zone_id" "$(echo "$state" | jq '.security_backup // null')"
    else
        echo "无 CF 凭据，跳过 CF 恢复"
    fi
    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH"
    ok "已清理状态文件"
    ok "卸载完成"
}

# ── 3. 查看节点链接 ──────────────────────────────────
do_show() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史配置"
    echo "域名/IP: $(echo "$state" | jq -r '.domain // "直连"')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "$state" | jq -r '.links | to_entries[] | "\(.key) \(.value)"'
}

# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local domain uid routes_json net_mode rpk rpub rsid hpass tpass zone_id
    domain=$(echo "$state" | jq -r '.domain // ""')
    uid=$(echo "$state" | jq -r '.uuid')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')
    zone_id=$(echo "$state" | jq -r '.zone_id // ""')
    rpk=$(echo "$state" | jq -r '.reality_private // ""')
    rpub=$(echo "$state" | jq -r '.reality_public // ""')
    rsid=$(echo "$state" | jq -r '.reality_sid // ""')
    hpass=$(echo "$state" | jq -r '.hysteria2_pass // ""')
    tpass=$(echo "$state" | jq -r '.tuic_pass // ""')

    echo ""; echo "当前配置 ($(net_mode_label "$net_mode")):"
    [[ -n "$domain" ]] && echo "  域名: $domain"
    echo "  UUID: $uid"
    echo "$routes_json" | jq -r '.[] | "  [\(.protocol)] 内网:\(.listen_port) 外网:\(.cf_port) 路径:\(.path//"(无)")"'
    echo ""
    echo "  1. 修改 UUID"
    echo "  2. 修改端口（逐个协议改内网/外网）"
    echo "  3. 修改 WS 路径(仅CF类)"
    echo "  4. 全部修改"
    echo "  0. 返回"
    read -rp "请选择 [0-4]: " mc
    local new_uid="$uid" new_routes="$routes_json" changed=false
    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    if [[ "$mc" == "1" || "$mc" == "4" ]]; then
        read -rp "新 UUID(留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            new_uid="${iu,,}"
        else
            new_uid=$(gen_uuid)
        fi
        changed=true; ok "UUID: $new_uid"
    fi

    if [[ "$mc" == "2" || "$mc" == "4" ]]; then
        local pc; pc=$(echo "$new_routes" | jq 'length')
        echo ""
        info "逐个协议修改端口（留空=不改）"
        local idx=0
        for ((idx=0; idx<pc; idx++)); do
            local proto cur_lp cur_cp label
            proto=$(echo "$new_routes" | jq -r ".[$idx].protocol")
            cur_lp=$(echo "$new_routes" | jq -r ".[$idx].listen_port")
            cur_cp=$(echo "$new_routes" | jq -r ".[$idx].cf_port")
            label="${PROTO_LABEL[$proto]:-$proto}"
            if [[ "$net_mode" == "nat" ]]; then
                read -rp "  [$label] 内网端口(当前=$cur_lp, 留空不改): " nl
                read -rp "  [$label] 外网端口(当前=$cur_cp, 留空不改): " nc
                [[ -n "$nl" ]] && { [[ "$nl" =~ ^[0-9]+$ ]] || die "无效端口: $nl"; new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson v "$((nl))" '.[$i].listen_port=$v'); }
                [[ -n "$nc" ]] && { [[ "$nc" =~ ^[0-9]+$ ]] || die "无效端口: $nc"; new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson v "$((nc))" '.[$i].cf_port=$v'); }
            else
                read -rp "  [$label] 端口(当前=$cur_lp, 留空不改): " np
                if [[ -n "$np" ]]; then
                    [[ "$np" =~ ^[0-9]+$ ]] || die "无效端口: $np"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson v "$((np))" '.[$i].listen_port=$v|.[$i].cf_port=$v')
                fi
            fi
        done
        changed=true; ok "端口已更新"
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        echo "当前路径: $(echo "$new_routes" | jq -r '[.[] | select(.mode=="cf") | .path] | join(", ")')"
        read -rp "新 WS 路径前缀(留空=不改): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/${np}"
            new_routes=$(echo "$new_routes" | jq --arg pfx "$np" '[.[] | if .mode=="cf" then .path=($pfx+"-"+(if .protocol=="vless" then "vl" elif .protocol=="trojan" then "tr" else "vm" end)) else . end]')
            changed=true; ok "路径已更新"
        fi
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }
    gen_singbox_config "$new_routes" "$new_uid" "$rpk" "$rsid" "$hpass" "$tpass"
    restart_singbox
    if has_cf_proto "$new_routes" && load_cf_account && [[ -n "$zone_id" ]]; then
        local cf_routes; cf_routes=$(echo "$new_routes" | jq '[.[] | select(.mode=="cf")]')
        apply_origin_rules "$zone_id" "$domain" "$cf_routes"
        ok "Origin Rules 已更新"
    fi
    local host; [[ -n "$domain" ]] && host="$domain" || host=$(get_public_ip)
    local links_json; links_json=$(gen_all_links "$new_routes" "$new_uid" "$host" "$rpub" "$rsid" "$hpass" "$tpass")
    save_links_snapshot "$host" "$new_uid" "$links_json"
    save_state "$(echo "$state" | jq --arg u "$new_uid" --argjson r "$new_routes" --argjson l "$links_json" '.uuid=$u|.routes=$r|.links=$l')"
    echo; ok "配置已更新"; print_links "$links_json"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    echo ""
    echo "域名/IP: $(echo "$state" | jq -r '.domain // "直连"')"
    echo "UUID:     $(echo "$state" | jq -r '.uuid')"
    echo "模式:     $(net_mode_label "$(echo "$state" | jq -r '.net_mode // "direct"')")"
    echo ""
    echo "入站:"
    echo "$state" | jq -r '.routes[] | "  [\(.protocol)] 模式:\(.mode)  内网:\(.listen_port)  外网:\(.cf_port)  路径:\(.path//"(无)")"'
    local rpub hpass tpass
    rpub=$(echo "$state" | jq -r '.reality_public // ""')
    hpass=$(echo "$state" | jq -r '.hysteria2_pass // ""')
    tpass=$(echo "$state" | jq -r '.tuic_pass // ""')
    [[ -n "$rpub" ]] && echo "  Reality公钥: $rpub"
    [[ -n "$hpass" ]] && echo "  Hysteria2密码: $hpass"
    [[ -n "$tpass" ]] && echo "  TUIC密码: $tpass"
    echo ""
    echo -n "sing-box: "; svc_is_active && echo "运行中" || echo "未运行"
    echo "内存占用:"
    ps -o rss= -C sing-box 2>/dev/null | awk '{sum+=$1} END {printf "  RSS: %.1f MB\n", sum/1024}' || echo "  无法获取"
    echo ""
    echo "节点链接:"
    print_links "$(echo "$state" | jq '.links')"
    echo ""
}

# ── 6. 更新外部端口（NAT）───────────────────────────
do_update_ports() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local domain routes_json net_mode zone_id uid
    domain=$(echo "$state" | jq -r '.domain // ""')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')
    zone_id=$(echo "$state" | jq -r '.zone_id // ""')
    uid=$(echo "$state" | jq -r '.uuid')
    echo ""; echo "当前端口映射:"
    echo "$routes_json" | jq -r '.[] | "  [\(.protocol)] 内网:\(.listen_port) -> 外网:\(.cf_port)"'
    [[ "$net_mode" != "nat" ]] && { info "直连模式请使用 [4.修改配置]"; return; }
    local pc; pc=$(echo "$routes_json" | jq 'length')
    info "NAT 模式: 逐个更新外网端口"
    local new_routes="$routes_json" idx=0
    for ((idx=0; idx<pc; idx++)); do
        local proto old_cp label ne
        proto=$(echo "$new_routes" | jq -r ".[$idx].protocol")
        old_cp=$(echo "$new_routes" | jq -r ".[$idx].cf_port")
        label="${PROTO_LABEL[$proto]:-$proto}"
        read -rp "  [$label] 新外网端口(当前=$old_cp, 留空不改): " ne
        [[ -z "$ne" ]] && continue
        [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口: $ne"
        new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ne))" '.[$i].cf_port=$p')
    done
    echo ""; echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  [\(.protocol)] 内网:\(.listen_port) -> 外网:\(.cf_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"
    if has_cf_proto "$new_routes" && load_cf_account && [[ -n "$zone_id" ]]; then
        local cf_routes; cf_routes=$(echo "$new_routes" | jq '[.[] | select(.mode=="cf")]')
        apply_origin_rules "$zone_id" "$domain" "$cf_routes"
        ok "Origin Rules 已更新"
    fi
    local host; [[ -n "$domain" ]] && host="$domain" || host=$(get_public_ip)
    local rpub rsid hpass tpass
    rpub=$(echo "$state" | jq -r '.reality_public // ""')
    rsid=$(echo "$state" | jq -r '.reality_sid // ""')
    hpass=$(echo "$state" | jq -r '.hysteria2_pass // ""')
    tpass=$(echo "$state" | jq -r '.tuic_pass // ""')
    local links_json; links_json=$(gen_all_links "$new_routes" "$uid" "$host" "$rpub" "$rsid" "$hpass" "$tpass")
    save_links_snapshot "$host" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --argjson r "$new_routes" --argjson l "$links_json" '.routes=$r|.links=$l')"
    echo; ok "外部端口已更新"; print_links "$links_json"
}

# ── 7. 重启 ──────────────────────────────────────────
do_restart() { restart_singbox; }

# ── 8. 切换网络模式 ──────────────────────────────────
do_switch_net_mode() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"
    local domain zone_id uid cur routes_json
    domain=$(echo "$state" | jq -r '.domain // ""')
    zone_id=$(echo "$state" | jq -r '.zone_id // ""')
    uid=$(echo "$state" | jq -r '.uuid')
    cur=$(echo "$state" | jq -r '.net_mode // "direct"')
    routes_json=$(echo "$state" | jq '.routes')
    echo ""; echo "当前模式: $(net_mode_label "$cur")"
    echo "$routes_json" | jq -r '.[] | "  [\(.protocol)] 内网:\(.listen_port) 外网:\(.cf_port)"'
    local target; [[ "$cur" == "nat" ]] && target="direct" || target="nat"
    read -rp "确认切换到 $(net_mode_label "$target")? (y/N): " c
    [[ "${c,,}" =~ ^(y|yes)$ ]] || die "已取消"
    local new_routes="$routes_json"
    if [[ "$target" == "direct" ]]; then
        new_routes=$(echo "$new_routes" | jq '[.[] | .cf_port = .listen_port]')
    else
        local pc idx
        pc=$(echo "$new_routes" | jq 'length')
        info "逐个协议设置外网映射端口"
        for ((idx=0; idx<pc; idx++)); do
            local proto lp label ep
            proto=$(echo "$new_routes" | jq -r ".[$idx].protocol")
            lp=$(echo "$new_routes" | jq -r ".[$idx].listen_port")
            label="${PROTO_LABEL[$proto]:-$proto}"
            read -rp "  [$label] 外网端口(内网=$lp, 回车=相同): " ep
            [[ -n "$ep" ]] || ep="$lp"
            [[ "$ep" =~ ^[0-9]+$ ]] || die "无效端口: $ep"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ep))" '.[$i].cf_port=$p')
        done
    fi
    echo ""; echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  [\(.protocol)] 内网:\(.listen_port) 外网:\(.cf_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"
    if has_cf_proto "$new_routes" && load_cf_account && [[ -n "$zone_id" ]]; then
        local cf_routes; cf_routes=$(echo "$new_routes" | jq '[.[] | select(.mode=="cf")]')
        apply_origin_rules "$zone_id" "$domain" "$cf_routes"
        ok "Origin Rules 已更新"
    fi
    local host; [[ -n "$domain" ]] && host="$domain" || host=$(get_public_ip)
    local rpub rsid hpass tpass
    rpub=$(echo "$state" | jq -r '.reality_public // ""')
    rsid=$(echo "$state" | jq -r '.reality_sid // ""')
    hpass=$(echo "$state" | jq -r '.hysteria2_pass // ""')
    tpass=$(echo "$state" | jq -r '.tuic_pass // ""')
    local links_json; links_json=$(gen_all_links "$new_routes" "$uid" "$host" "$rpub" "$rsid" "$hpass" "$tpass")
    save_links_snapshot "$host" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --arg m "$target" --argjson r "$new_routes" --argjson l "$links_json" '.net_mode=$m|.routes=$r|.links=$l')"
    echo; ok "已切换到 $(net_mode_label "$target")"; print_links "$links_json"
}

# ── 快捷指令 ──────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/sb"
    [[ -f "$target" ]] && return
    cat > "$target" << 'SCEOF'
#!/bin/sh
exec bash <(curl -fsSL https://raw.githubusercontent.com/qiuxiaoyu001/singbox-cf-lite2/main/singbox_cf_lite.sh) "$@"
SCEOF
    chmod +x "$target"
}

# ── 主入口 ────────────────────────────────────────────
main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq
    ensure_shortcut
    local state current_domain="" net_mode=""
    state=$(load_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
        current_domain=$(echo "$state" | jq -r '.domain // ""')
        net_mode=$(echo "$state" | jq -r '.net_mode // ""')
    fi
    echo
    echo "  sing-box-cf-lite ($INIT_SYSTEM)"
    echo "  六协议: VLESS+WS | VMess+WS | Trojan+WS (CF) · Reality | Hysteria2 | TUIC v5 (直连)"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看节点链接"
    echo "  4. 修改配置(UUID/端口/路径)"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口(NAT)"
    echo "  7. 重启 sing-box"
    echo "  8. 切换网络模式(直连/NAT)"
    [[ -n "$current_domain" ]] && echo "     (当前: ${current_domain:-直连}${net_mode:+ [$net_mode]})"
    echo
    read -rp "请选择 [1-8]: " choice
    case "$choice" in
        1) do_install ;; 2) do_uninstall ;; 3) do_show ;;
        4) do_modify ;; 5) do_show_config ;; 6) do_update_ports ;;
        7) do_restart ;; 8) do_switch_net_mode ;;
        *) die "无效选项: $choice" ;;
    esac
}
main "$@"
