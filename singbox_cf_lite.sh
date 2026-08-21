#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# sing-box-cf-lite
# VLESS+WS | Trojan+WS | VMess+WS
# Cloudflare Flexible + Origin Rules
# =============================================================

SINGBOX_CONF_DIR="/etc/sing-box/conf"
SINGBOX_CONFIG="$SINGBOX_CONF_DIR/config.json"
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
SINGBOX_OPENRC_SCRIPT="/etc/init.d/sing-box"

CF_EDGE_PORTS="443 2053 2083 2087 2096 8443"
declare -A PROTO_SUFFIX=([vless]="vl" [trojan]="tr" [vmess]="vm")
declare -A PROTO_LABEL=([vless]="VLESS" [trojan]="TROJAN" [vmess]="VMESS")

INIT_SYSTEM=""
CF_EMAIL=""
CF_KEY=""

# ---------- basic ----------
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok(){ printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info(){ printf '\033[36m·\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[33m! %s\033[0m\n' "$*" >&2; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }

urlencode(){
    local s="$1" c
    local -i i
    for ((i=0;i<${#s};i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

gen_uuid(){ cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
require_port(){ valid_port "$1" || die "无效端口: $1（1-65535）"; }
port_free(){ ! ss -H -lntup 2>/dev/null | grep -qE "[:.]${1}([[:space:]]|$)"; }

get_mem_mb(){
    local m
    m=$(awk '/MemTotal:/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || true)
    [[ -n "$m" && "$m" != "0" ]] || m=999
    echo "$m"
}

ensure_swap_disabled(){
    local mem="$1"
    [[ "$mem" -ge 128 ]] && return 0
    if awk 'NR>1 && $1!=""{f=1} END{exit !f}' /proc/swaps 2>/dev/null; then
        return 0
    fi
    warn "检测到 ${mem}MB RAM 且没有 swap，尝试创建 128MB swap 作为 OOM 保护。"
    if [[ ! -f /swapfile ]]; then
        fallocate -l 128M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=128 2>/dev/null || true
    fi
    if [[ -f /swapfile ]]; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        swapon /swapfile >/dev/null 2>&1 || true
        grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        swapon --show >/dev/null 2>&1 && ok "swap 已启用 (128MB)" || warn "swap 启用失败，继续运行。"
    fi
}

# ---------- init ----------
detect_init(){
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

install_deps(){
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    [[ ${#missing[@]} -eq 0 ]] && return
    echo "安装依赖: ${missing[*]}"
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing[@]}"
    else
        die "无法自动安装依赖: ${missing[*]}"
    fi
}

# ---------- service ----------
write_openrc_script(){
    cat > "$SINGBOX_OPENRC_SCRIPT" <<'INITEOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy server (cf-lite mini)"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/conf/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
respawn_delay=1
respawn_max=0
respawn_period=86400
supervise_daemon_args="--respawn-delay ${respawn_delay} --respawn-max ${respawn_max} --respawn-period ${respawn_period}"
supervisor=supervise-daemon
depend(){ need net; after firewall; }
INITEOF
    chmod +x "$SINGBOX_OPENRC_SCRIPT"
}

write_systemd_service(){
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/sing-box.service <<'EOF_SERVICE'
[Unit]
Description=sing-box cf-lite mini
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/conf/config.json
Restart=on-failure
RestartSec=1
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

svc_enable(){
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1 || true
    else
        [[ -f "$SINGBOX_OPENRC_SCRIPT" ]] || write_openrc_script
        rc-update add sing-box default >/dev/null 2>&1 || true
    fi
}
svc_start(){
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart sing-box
    else
        rc-service sing-box restart
    fi
}
svc_stop(){
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
    else
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-update del sing-box default >/dev/null 2>&1 || true
    fi
}
svc_is_active(){
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active sing-box >/dev/null 2>&1
    else
        rc-service sing-box status >/dev/null 2>&1
    fi
}
restart_singbox(){
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then write_systemd_service; fi
    [[ "$INIT_SYSTEM" == "openrc" && ! -f "$SINGBOX_OPENRC_SCRIPT" ]] && write_openrc_script
    svc_enable
    svc_start || die "sing-box 重启失败"
    sleep 1
    svc_is_active || die "sing-box 未正常启动，请检查日志"
    ok "sing-box 服务已启动"
}

# ---------- network ----------
get_public_ip(){
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return; fi
    done
    die "获取公网 IPv4 失败"
}

detect_nat(){
    local ip="$1"
    ip addr show 2>/dev/null | grep -qE "inet ${ip}/" && echo direct || echo nat
}

prompt_net_mode(){
    local detected="$1" ans
    echo
    info "网络探测: $([[ "$detected" == direct ]] && echo '直连' || echo 'NAT')"
    read -rp "网络模式 (1=直连, 2=NAT, 回车=探测结果): " ans
    case "$ans" in
        1) echo direct;;
        2) echo nat;;
        "") echo "$detected";;
        *) die "无效选项: $ans";;
    esac
}

# ---------- Cloudflare ----------
cf_call(){
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-sS -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}
cf_call_raw(){
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-sS -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}
load_cf_account(){
    [[ -s "$CF_ACCOUNT_PATH" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
    CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}
save_cf_account(){
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}
cf_verify_credentials(){
    local r
    r=$(curl -sS -X GET "${CF_API}/user/tokens/verify" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" || true)
    echo "$r" | jq -e '.success==true' >/dev/null 2>&1 && return 0
    r=$(curl -sS -X GET "${CF_API}/zones?per_page=1" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json" || true)
    echo "$r" | jq -e '.success==true' >/dev/null 2>&1
}
prompt_cf(){
    if load_cf_account; then
        local masked="${CF_KEY:0:6}...${CF_KEY: -4}" ans
        read -rp "复用已保存 CF 凭据 ($CF_EMAIL, Key=$masked)? (Y/n): " ans
        if [[ "${ans,,}" =~ ^(|y|yes)$ ]] && cf_verify_credentials; then return 0; fi
    fi
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL
        read -rsp "Cloudflare Global API Key: " CF_KEY; echo
        [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]] || { warn "不能为空"; continue; }
        printf '校验凭据... '
        if cf_verify_credentials; then echo '通过'; save_cf_account; return; fi
        echo '失败，请重试'
    done
}
cf_find_zone(){
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r name id; do
        if [[ "$domain" == "$name" || "$domain" == *".$name" ]]; then
            [[ ${#name} -gt ${#best_name} ]] && best_name="$name" && best_id="$id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] && echo "$best_id"
}
cf_get_dns(){ cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'; }
cf_upsert_dns(){
    local z="$1" d="$2" ip="$3" existing payload rid
    payload=$(jq -n --arg n "$d" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')
    existing=$(cf_get_dns "$z" "$d")
    if [[ -n "$existing" ]]; then
        rid=$(echo "$existing" | jq -r '.id')
        cf_call PUT "/zones/$z/dns_records/$rid" "$payload" | jq -r '.result.id'
    else
        cf_call POST "/zones/$z/dns_records" "$payload" | jq -r '.result.id'
    fi
}
cf_get_ssl(){ cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value // ""'; }
cf_set_ssl(){ cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_security_level(){ cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value // ""'; }
cf_set_security_level(){ cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_browser_check(){ cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value // ""'; }
cf_set_browser_check(){ cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }
cf_get_bot_management(){ cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }
cf_set_bot_fight_off(){
    local z="$1"
    cf_call_raw PUT "/zones/$z/bot_management" "$(jq -n '{enable_js:false,sbfm_likely_automated:"allow",sbfm_definitely_automated:"allow",sbfm_verified_bots:"allow",sbfm_static_resource_protection:false}')" | jq -e '.success' >/dev/null 2>&1
}
cf_restore_bot_management(){
    local z="$1" backup="$2"
    local payload
    payload=$(echo "$backup" | jq '{enable_js:.enable_js,sbfm_likely_automated:.sbfm_likely_automated,sbfm_definitely_automated:.sbfm_definitely_automated,sbfm_verified_bots:.sbfm_verified_bots,sbfm_static_resource_protection:.sbfm_static_resource_protection}')
    cf_call_raw PUT "/zones/$z/bot_management" "$payload" | jq -e '.success' >/dev/null 2>&1
}
cf_relax_security(){
    local z="$1" sl bc bm likely
    sl=$(cf_get_security_level "$z")
    bc=$(cf_get_browser_check "$z")
    bm=$(cf_get_bot_management "$z")
    if [[ "$sl" != "essentially_off" ]]; then cf_set_security_level "$z" essentially_off; ok 'Security Level: essentially_off'; fi
    if [[ "$bc" != off ]]; then cf_set_browser_check "$z" off; ok 'Browser Check: off'; fi
    likely=$(echo "$bm" | jq -r '.sbfm_likely_automated // ""')
    if [[ "$likely" != allow ]]; then cf_set_bot_fight_off "$z" && ok 'Bot Fight Mode: 已关闭' || true; fi
    jq -n --arg sl "$sl" --arg bc "$bc" --argjson bm "$bm" '{security_level:$sl,browser_check:$bc,bot_management:$bm}'
}
cf_restore_security(){
    local z="$1" b="$2"
    [[ -z "$b" || "$b" == null ]] && return
    local sl bc bm
    sl=$(echo "$b" | jq -r '.security_level // ""'); bc=$(echo "$b" | jq -r '.browser_check // ""'); bm=$(echo "$b" | jq '.bot_management // null')
    [[ -n "$sl" ]] && cf_set_security_level "$z" "$sl" || true
    [[ -n "$bc" ]] && cf_set_browser_check "$z" "$bc" || true
    [[ "$bm" != null ]] && cf_restore_bot_management "$z" "$bm" || true
}
cf_get_origin_rules(){
    local r
    r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint" || true)
    echo "$r" | jq -c 'if .success then .result.rules // [] else [] end' 2>/dev/null || echo '[]'
}
cf_put_origin_rules(){
    local z="$1" rules="$2" r
    r=$(cf_call_raw PUT "/zones/$z/rulesets/phases/http_request_origin/entrypoint" "$(jq -n --argjson r "$rules" '{rules:$r}')")
    echo "$r" | jq -e '.success' >/dev/null 2>&1 || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors // []')"
}
apply_origin_rules(){
    local z="$1" domain="$2" routes="$3" existing kept managed merged
    [[ -z "$routes" || "$routes" == '[]' ]] && return 0
    existing=$(cf_get_origin_rules "$z")
    kept=$(echo "$existing" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[.[]|select((.description|startswith($pfx)|not) or (.expression|ascii_downcase|contains("http.host eq \""+($d|ascii_downcase)+"\"")|not))]')
    managed=$(echo "$routes" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[.[]|{description:($pfx+.protocol+" "+.path),enabled:true,expression:("(http.host eq \""+$d+"\" and http.request.uri.path eq \""+.path+"\")"),action:"route",action_parameters:{origin:{port:.origin_port}}}]')
    merged=$(jq -n --argjson a "$kept" --argjson b "$managed" '$a+$b')
    cf_put_origin_rules "$z" "$merged"
}

# ---------- sing-box install ----------
get_singbox_arch(){
    case "$(uname -m)" in
        x86_64|amd64) echo amd64;;
        aarch64|arm64) echo arm64;;
        armv7l|armv7*) echo armv7;;
        i386|i686) echo 386;;
        s390x) echo s390x;;
        *) die "不支持的架构: $(uname -m)";;
    esac
}
install_singbox(){
    [[ -x "$SINGBOX_BINARY" ]] && { ok "sing-box 已安装: $($SINGBOX_BINARY version 2>/dev/null | head -1)"; return; }
    mkdir -p "$SINGBOX_WORK_DIR" "$SINGBOX_CONF_DIR"
    local arch; arch=$(get_singbox_arch)
    local url=""
    if [[ -n "$SINGBOX_MINI_URL" ]]; then
        url="${SINGBOX_MINI_URL//\{arch\}/$arch}"
        url="${url//linux-amd64/linux-$arch}"
        info "下载指定精简版: $url"
        curl -fsSL "$url" -o "$SINGBOX_BINARY" || die "精简版下载失败"
    else
        local ver=""
        ver=$(curl -sf "$SINGBOX_OFFICIAL_API" 2>/dev/null | jq -r '.tag_name' 2>/dev/null) || true
        [[ -n "$ver" && "$ver" != null ]] || die "获取 sing-box 最新版本失败；可设置 SINGBOX_MINI_URL 后重试"
        ver="${ver#v}"
        local tmp="/tmp/sb-install-$$"
        mkdir -p "$tmp"
        url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
        info "下载官方 sing-box v${ver} (${arch})"
        curl -fsSL "$url" -o "$tmp/sb.tar.gz" || die "sing-box 下载失败"
        tar xzf "$tmp/sb.tar.gz" -C "$tmp"
        cp "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$SINGBOX_BINARY"
        rm -rf "$tmp"
    fi
    chmod +x "$SINGBOX_BINARY"
    "$SINGBOX_BINARY" version >/dev/null 2>&1 || die "sing-box 二进制不可执行或架构错误"
    ok "sing-box 安装完成: $($SINGBOX_BINARY version 2>/dev/null | head -1)"
}

# ---------- config ----------
gen_singbox_config(){
    local routes="$1"
    mkdir -p "$SINGBOX_CONF_DIR"
    # 单文件配置；不加载 geosite/geoip，不启用 TUN/API，不做复杂 DNS/routing。
    echo "$routes" | jq -c '
      {
        log:{disabled:true,level:"error"},
        inbounds:(map(
          if .protocol=="vless" then
            {type:"vless",tag:("vless-"+(.listen_port|tostring)),listen:"::",listen_port:.listen_port,users:[{uuid:.uuid}],transport:{type:"ws",path:.path}}
          elif .protocol=="trojan" then
            {type:"trojan",tag:("trojan-"+(.listen_port|tostring)),listen:"::",listen_port:.listen_port,users:[{password:.password}],transport:{type:"ws",path:.path}}
          elif .protocol=="vmess" then
            {type:"vmess",tag:("vmess-"+(.listen_port|tostring)),listen:"::",listen_port:.listen_port,users:[{uuid:.uuid,alter_id:0}],transport:{type:"ws",path:.path}}
          else empty end
        )),
        outbounds:[{type:"direct",tag:"direct"}]
      }
    ' > "$SINGBOX_CONFIG"
    chmod 644 "$SINGBOX_CONFIG"
    local tmp="/tmp/sb-check-$$.log"
    if ! "$SINGBOX_BINARY" check -c "$SINGBOX_CONFIG" >"$tmp" 2>&1; then
        cat "$tmp" >&2 || true
        rm -f "$tmp"
        jq . "$SINGBOX_CONFIG" >&2 || true
        die "sing-box 配置校验失败"
    fi
    rm -f "$tmp"
    ok "三协议极简配置已校验"
}

# ---------- links/state ----------
build_link(){
    local uid="$1" domain="$2" proto="$3" port="$4" path="$5"
    case "$proto" in
        vless) echo "vless://${uid}@${domain}:${port}?encryption=none&security=tls&sni=$(urlencode "$domain")&type=ws&host=$(urlencode "$domain")&path=$(urlencode "$path")#VLESS-WS-CF";;
        trojan) echo "trojan://${uid}@${domain}:${port}?security=tls&sni=$(urlencode "$domain")&type=ws&host=$(urlencode "$domain")&path=$(urlencode "$path")#Trojan-WS-CF";;
        vmess)
            local j
            j=$(jq -nc --arg ps "VMess-WS-CF" --arg add "$domain" --arg port "$port" --arg id "$uid" --arg path "$path" '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$add,path:$path,tls:"tls",sni:$add}')
            printf 'vmess://%s#VMess-WS-CF\n' "$(printf '%s' "$j" | base64 -w0 2>/dev/null || printf '%s' "$j" | base64 | tr -d '\n')";;
    esac
}
gen_all_links(){
    local uid="$1" domain="$2" routes="$3" links='{}' proto port path link
    while IFS=$'\t' read -r proto port path; do
        link=$(build_link "$uid" "$domain" "$proto" "$port" "$path")
        links=$(echo "$links" | jq --arg p "$proto" --arg l "$link" '.+{($p):$l}')
    done < <(echo "$routes" | jq -r '.[]|[.protocol,.external_port,.path]|@tsv')
    echo "$links"
}
load_state(){ [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state(){ mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state(){ rm -f "$STATE_PATH"; }
save_links_snapshot(){
    local domain="$1" uid="$2" links="$3"
    { echo "域名: $domain"; echo "UUID: $uid"; echo; echo "$links" | jq -r 'to_entries[]|"\(.key) \(.value)"'; } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}
print_links(){
    local links="$1"
    while IFS=$'\t' read -r p l; do echo "  ${PROTO_LABEL[$p]:-$p}订阅 $l"; done < <(echo "$links" | jq -r 'to_entries[]|[.key,.value]|@tsv')
}

# ---------- prompts/routes ----------
prompt_protocols(){
    echo
    echo "选择协议（默认全部三个）：" >&2
    echo "  1) VLESS+WS" >&2
    echo "  2) Trojan+WS" >&2
    echo "  3) VMess+WS" >&2
    read -rp "请选择 [1-3]，可逗号多选，回车=全部: " raw
    raw="${raw//，/,}"
    raw="${raw:-1,2,3}"
    local -A map=([1]=vless [2]=trojan [3]=vmess)
    local arr=() t p
    IFS=',' read -ra tokens <<< "$raw"
    for t in "${tokens[@]}"; do
        t="${t// /}"; p="${map[$t]:-}"
        [[ -n "$p" ]] || die "未知协议: $t"
        [[ " ${arr[*]} " == *" $p "* ]] || arr+=("$p")
    done
    printf '%s\n' "${arr[@]}"
}
prompt_uuid(){
    local u
    read -rp "UUID（留空=自动生成）: " u
    if [[ -n "$u" ]]; then
        [[ "$u" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        echo "${u,,}"
    else gen_uuid; fi
}
prompt_path(){
    local proto="$1" default="$2" p
    read -rp "${PROTO_LABEL[$proto]} WS 路径（留空=/${default}-${PROTO_SUFFIX[$proto]}）: " p
    p="${p:-/${default}-${PROTO_SUFFIX[$proto]}}"
    [[ "$p" == /* ]] || p="/$p"
    echo "$p"
}
build_routes(){
    local net_mode="$1" path_prefix="$2" protocols=("${@:3}") routes='[]' existing p lp ep path
    existing=" $(ss -H -lntup 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')"
    for p in "${protocols[@]}"; do
        echo
        echo "── ${PROTO_LABEL[$p]} ──" >&2
        while true; do
            read -rp "内网监听端口: " lp
            require_port "$lp"
            port_free "$lp" || { warn "端口 $lp 已占用"; continue; }
            [[ "$existing" != *" $lp "* ]] || { warn "端口 $lp 重复"; continue; }
            existing+="$lp "
            break
        done
        if [[ "$net_mode" == nat ]]; then
            read -rp "CF 外部映射端口（回车=$lp）: " ep
            ep="${ep:-$lp}"; require_port "$ep"
        else
            ep="$lp"
        fi
        if [[ "$net_mode" == direct || "$net_mode" == nat ]]; then
            if [[ "$net_mode" == direct ]]; then ep="$lp"; fi
        fi
        if [[ "$p" =~ ^(vless|trojan|vmess)$ ]]; then
            if [[ "$net_mode" == nat || "$net_mode" == direct ]]; then
                # CF 外部端口必须是 Cloudflare 代理支持的端口。
                if [[ "$net_mode" == nat ]]; then
                    [[ " $CF_EDGE_PORTS " == *" $ep "* ]] || die "CF 不支持外部端口: $ep"
                else
                    read -rp "CF 外部端口（回车=443）: " ep
                    ep="${ep:-443}"
                    [[ " $CF_EDGE_PORTS " == *" $ep "* ]] || die "CF 不支持外部端口: $ep"
                fi
            fi
        fi
        path=$(prompt_path "$p" "${path_prefix#/}")
        routes=$(echo "$routes" | jq --arg p "$p" --argjson lp "$((lp))" --argjson ep "$((ep))" --arg path "$path" '.+[{protocol:$p,listen_port:$lp,external_port:$ep,path:$path}]')
    done
    echo "$routes"
}

# ---------- install ----------
do_install(){
    local state; state=$(load_state 2>/dev/null || true)
    [[ -z "$state" ]] || die "检测到已有配置，请先卸载"
    local mem; mem=$(get_mem_mb); info "系统内存: ${mem}MB"
    ensure_swap_disabled "$mem"
    install_singbox

    local net_mode; net_mode=$(prompt_net_mode "$(detect_nat "$(get_public_ip)")")
    local protocols_str; protocols_str=$(prompt_protocols); mapfile -t protocols <<< "$protocols_str"
    local has_cf=false p
    for p in "${protocols[@]}"; do has_cf=true; done
    local public_ip; public_ip=$(get_public_ip)
    local domain="" zone_id=""
    if [[ "$has_cf" == true ]]; then
        prompt_cf
        while true; do
            read -rp "CF 绑定域名: " domain
            [[ -n "$domain" ]] || { warn "域名不能为空"; continue; }
            if zone_id=$(cf_find_zone "$domain"); then info "匹配到 Zone: $zone_id"; break; fi
            warn "无法匹配该域名的 CF Zone，请重试"
        done
    fi
    local uid; uid=$(prompt_uuid)
    local prefix="${uid:0:8}"
    local routes; routes=$(build_routes "$net_mode" "$prefix" "${protocols[@]}")

    echo
    echo "========== 配置预览 =========="
    echo "域名: ${domain:-$public_ip}"
    echo "UUID: $uid"
    echo "模式: $net_mode"
    echo "$routes" | jq -r '.[]|"  \(.protocol)  监听:\(.listen_port)  外部:\(.external_port)  path:\(.path)"'
    echo "==============================="
    read -rp "确认部署? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    routes=$(echo "$routes" | jq --arg u "$uid" 'map(if .protocol=="trojan" then .+{password:$u} else .+{uuid:$u} end)')
    gen_singbox_config "$routes"
    restart_singbox

    local dns_before='null' ssl_before='' origin_before='[]' dns_id='' sec_backup='null' links_json
    if [[ -n "$zone_id" ]]; then
        dns_before=$(cf_get_dns "$zone_id" "$domain" || echo 'null'); [[ -n "$dns_before" ]] || dns_before='null'
        ssl_before=$(cf_get_ssl "$zone_id")
        origin_before=$(cf_get_origin_rules "$zone_id")
        dns_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
        cf_set_ssl "$zone_id" flexible
        apply_origin_rules "$zone_id" "$domain" "$routes"
        sec_backup=$(cf_relax_security "$zone_id")
        ok "Cloudflare DNS / SSL / Origin Rules 已完成"
        links_json=$(gen_all_links "$uid" "$domain" "$routes")
    else
        links_json=$(gen_all_links "$uid" "$public_ip" "$routes")
    fi
    save_links_snapshot "${domain:-$public_ip}" "$uid" "$links_json"
    save_state "$(jq -n --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg ip "$public_ip" --arg m "$net_mode" --arg drid "$dns_id" --arg ssl "$ssl_before" --argjson routes "$routes" --argjson drec "$dns_before" --argjson orb "$origin_before" --argjson sec "$sec_backup" --argjson links "$links_json" '{version:3,domain:$d,zone_id:$z,uuid:$u,public_ip:$ip,net_mode:$m,routes:$routes,links:$links,managed_dns_record_id:$drid,dns_backup:{existed:($drec!="null"),record:$drec},ssl_backup:$ssl,origin_rules_backup:$orb,security_backup:$sec}')"
    echo; ok "三协议极简版部署完成"; print_links "$links_json"
    echo; echo "sing-box 运行时配置仅包含 3 个 WS 入站 + direct 出站，不加载 geodata/DNS 分流/TUN/API。"
}

# ---------- uninstall ----------
do_uninstall(){
    local state; state=$(load_state 2>/dev/null || true); [[ -n "$state" ]] || die "未检测到部署"
    local z domain; z=$(echo "$state"|jq -r '.zone_id // ""'); domain=$(echo "$state"|jq -r '.domain // ""')
    echo "正在卸载: ${domain:-直连节点}"
    svc_stop
    rm -f "$SINGBOX_CONFIG"
    if [[ -n "$z" ]] && load_cf_account; then
        cf_put_origin_rules "$z" "$(echo "$state"|jq '.origin_rules_backup // []')" || true
        local ssl; ssl=$(echo "$state"|jq -r '.ssl_backup // ""'); [[ -n "$ssl" ]] && cf_set_ssl "$z" "$ssl" || true
        local existed rid; existed=$(echo "$state"|jq -r '.dns_backup.existed // false'); rid=$(echo "$state"|jq -r '.managed_dns_record_id // ""')
        if [[ "$existed" == true && -n "$rid" ]]; then
            local rp; rp=$(echo "$state"|jq '.dns_backup.record|{type:(.type//"A"),name:(.name//""),content:(.content//""),proxied:(.proxied//false),ttl:(.ttl//1)}')
            cf_call PUT "/zones/$z/dns_records/$rid" "$rp" >/dev/null || true
        elif [[ -n "$rid" ]]; then
            cf_call_raw DELETE "/zones/$z/dns_records/$rid" >/dev/null 2>&1 || true
        fi
        cf_restore_security "$z" "$(echo "$state"|jq '.security_backup // null')" || true
        ok "Cloudflare 配置已恢复"
    fi
    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH"
    ok "卸载完成"
}

# ---------- show ----------
do_show(){
    local state; state=$(load_state 2>/dev/null || true); [[ -n "$state" ]] || die "无历史订阅"
    echo "域名: $(echo "$state"|jq -r '.domain // "未配置"')"
    echo "公网 IP: $(echo "$state"|jq -r '.public_ip // "?"')"
    echo "UUID: $(echo "$state"|jq -r '.uuid // "?"')"
    print_links "$(echo "$state"|jq '.links // {}')"
}

do_show_config(){
    local state; state=$(load_state 2>/dev/null || true); [[ -n "$state" ]] || die "未检测到部署"
    echo
    echo "域名: $(echo "$state"|jq -r '.domain // "未配置"')"
    echo "公网 IP: $(echo "$state"|jq -r '.public_ip // "?"')"
    echo "模式: $(echo "$state"|jq -r '.net_mode // "direct"')"
    echo "UUID: $(echo "$state"|jq -r '.uuid // "?"')"
    echo
    echo "入站:"
    echo "$state"|jq -r '.routes[]|"  \(.protocol)  监听:\(.listen_port)  外部:\(.external_port)  path:\(.path)"'
    echo
    echo -n "sing-box: "; svc_is_active && echo 运行中 || echo 未运行
    local rss; rss=$(ps -o rss= -C sing-box 2>/dev/null | awk '{s+=$1}END{if(s)printf "%.1f",s/1024; else print "0"}')
    echo "sing-box RSS: ${rss} MB"
    echo
    print_links "$(echo "$state"|jq '.links // {}')"
}

# ---------- modify ----------
do_modify(){
    local state; state=$(load_state 2>/dev/null || true); [[ -n "$state" ]] || die "未检测到部署"
    local routes; routes=$(echo "$state"|jq '.routes // []')
    echo; echo "当前配置:"; echo "$routes"|jq -r '.[]|"  \(.protocol)  监听:\(.listen_port)  外部:\(.external_port)  path:\(.path)"'
    echo; echo "  1. 修改 UUID"; echo "  2. 修改单个协议端口"; echo "  3. 修改 WS 路径"; echo "  4. 全部 WS 路径"; echo "  0. 返回"
    read -rp "请选择: " c
    [[ "$c" == 0 ]] && return
    local uid; uid=$(echo "$state"|jq -r '.uuid')
    case "$c" in
        1)
            uid=$(prompt_uuid)
            routes=$(echo "$routes"|jq --arg u "$uid" 'map(if .protocol=="trojan" then .password=$u else .uuid=$u end)')
            ;;
        2)
            local p lp ep
            read -rp "协议 (vless/trojan/vmess): " p
            echo "$routes"|jq -e --arg p "$p" 'any(.[];.protocol==$p)' >/dev/null || die "协议不存在"
            read -rp "新监听端口: " lp; require_port "$lp"
            read -rp "新外部端口: " ep; require_port "$ep"
            [[ " $CF_EDGE_PORTS " == *" $ep "* ]] || die "CF 外部端口不支持: $ep"
            routes=$(echo "$routes"|jq --arg p "$p" --argjson l "$((lp))" --argjson e "$((ep))" 'map(if .protocol==$p then .listen_port=$l|.external_port=$e else . end)')
            ;;
        3|4)
            local np; read -rp "新的 WS 路径前缀: " np; [[ -n "$np" ]] || die "不能为空"; [[ "$np" == /* ]] || np="/$np"
            routes=$(echo "$routes"|jq --arg p "$np" 'map(.path=($p+"-"+(.protocol|if .=="vless" then "vl" elif .=="trojan" then "tr" else "vm" end)))')
            ;;
        *) die "无效选项";;
    esac
    gen_singbox_config "$routes"; restart_singbox
    local z domain host links
    z=$(echo "$state"|jq -r '.zone_id // ""'); domain=$(echo "$state"|jq -r '.domain // ""'); host="${domain:-$(echo "$state"|jq -r '.public_ip')}"
    if [[ -n "$z" ]] && load_cf_account; then apply_origin_rules "$z" "$domain" "$routes"; fi
    links=$(gen_all_links "$uid" "$host" "$routes")
    save_links_snapshot "$host" "$uid" "$links"
    save_state "$(echo "$state"|jq --arg u "$uid" --argjson r "$routes" --argjson l "$links" '.uuid=$u|.routes=$r|.links=$l')"
    ok "配置已更新"; print_links "$links"
}

do_update_ports(){
    local state; state=$(load_state 2>/dev/null || true); [[ -n "$state" ]] || die "未检测到部署"
    local routes; routes=$(echo "$state"|jq '.routes')
    local p old ep
    while IFS= read -r p; do
        old=$(echo "$routes"|jq -r --arg p "$p" '.[]|select(.protocol==$p)|.external_port')
        read -rp "$p 新外部端口（当前=$old，回车不变）: " ep
        [[ -z "$ep" ]] && continue
        require_port "$ep"; [[ " $CF_EDGE_PORTS " == *" $ep "* ]] || die "CF 不支持外部端口 $ep"
        routes=$(echo "$routes"|jq --arg p "$p" --argjson e "$((ep))" 'map(if .protocol==$p then .external_port=$e else . end)')
    done < <(echo "$routes"|jq -r '.[].protocol')
    gen_singbox_config "$routes"; restart_singbox
    local z domain host uid links
    z=$(echo "$state"|jq -r '.zone_id // ""'); domain=$(echo "$state"|jq -r '.domain // ""'); host="${domain:-$(echo "$state"|jq -r '.public_ip')}"; uid=$(echo "$state"|jq -r '.uuid')
    if [[ -n "$z" ]] && load_cf_account; then apply_origin_rules "$z" "$domain" "$routes"; fi
    links=$(gen_all_links "$uid" "$host" "$routes")
    save_links_snapshot "$host" "$uid" "$links"
    save_state "$(echo "$state"|jq --argjson r "$routes" --argjson l "$links" '.routes=$r|.links=$l')"
    ok "外部端口已更新"; print_links "$links"
}

do_restart(){ restart_singbox; }

ensure_shortcut(){
    local target=/usr/local/bin/sb
    [[ -f "$target" ]] && return
    cat > "$target" <<'EOF_SHORTCUT'
#!/bin/sh
exec bash <(curl -fsSL https://raw.githubusercontent.com/qiuxiaoyu001/singbox-cf-lite2/main/singbox_cf_lite.sh) "$@"
EOF_SHORTCUT
    chmod +x "$target"
}

main(){
    [[ "$(id -u)" == 0 ]] || die "请使用 root 运行此脚本"
    detect_init
    install_deps
    need_cmd curl; need_cmd jq; need_cmd ss
    ensure_shortcut
    local state domain=""
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && domain=$(echo "$state"|jq -r '.domain // ""')
    echo
    echo "  sing-box-cf-lite — 三协议极简低内存版 ($INIT_SYSTEM)"
    echo "  VLESS+WS | Trojan+WS | VMess+WS"
    echo "  不加载 geosite/geoip · 不启用 TUN/API · 单配置文件"
    [[ -n "$domain" ]] && echo "  当前 CF 域名: $domain"
    echo
    echo "  1. 安装节点"
    echo "  2. 卸载"
    echo "  3. 查看订阅"
    echo "  4. 修改配置"
    echo "  5. 查看当前配置"
    echo "  6. 更新外部端口"
    echo "  7. 重启 sing-box"
    echo
    read -rp "请选择 [1-7]: " choice
    case "$choice" in
        1) do_install;;
        2) do_uninstall;;
        3) do_show;;
        4) do_modify;;
        5) do_show_config;;
        6) do_update_ports;;
        7) do_restart;;
        *) die "无效选项: $choice";;
    esac
}
main "$@"
