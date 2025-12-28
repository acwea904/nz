#!/bin/sh

# =========================
# 环境变量
# =========================
ARGO_DOMAIN=${ARGO_DOMAIN:-"nz.xinxi.pp.ua"}
ARGO_AUTH=${ARGO_AUTH:-"eyJhIjoiZDhlZDg1MmM0Y2I5YTk3Njk2Y2Q4MTJlNDJmZDcyM2QiLCJ0IjoiZjYxNWNjOTEtZDg3Zi00YmU2LWE2MzgtZTQzMTNmN2NlYzgwIiwicyI6Ik5HTTFaalJoTVRVdFlUbGxNQzAwTkRjeExUZ3dPRFF0TkdRM016Y3paakEzWVdZeSJ9"}
NZ_UUID=${NZ_UUID:-"6b98d9bb-639f-f603-7db8-104be2b97f07"}
NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET:-"4efa61d37fe4-5b1f67ede39275b004ca"}
NZ_TLS=${NZ_TLS:-true}
DASHBOARD_VERSION=${DASHBOARD_VERSION:-latest}

GITHUB_REPO_OWNER=${GITHUB_REPO_OWNER:-"acwea904"}
GITHUB_REPO_NAME=${GITHUB_REPO_NAME:-"nzbak"}
GITHUB_TOKEN=${GITHUB_TOKEN:-"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"}
GITHUB_BRANCH=${GITHUB_BRANCH:-main}
ZIP_PASSWORD=${ZIP_PASSWORD:-"#Xe-as/:Ht8H(!"}

# =========================
# 日志函数
# =========================
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_ok() {
    echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# =========================
# 端口等待函数
# =========================
wait_for_port() {
    local port=$1
    local max_wait=${2:-60}
    local count=0
    
    log_info "等待端口 $port 就绪 (超时: ${max_wait}s)"
    while [ $count -lt $max_wait ]; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            log_ok "端口 $port 已就绪"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    log_error "端口 $port 等待超时"
    return 1
}

# =========================
# 步骤 1: 启动 Nginx (健康检查端口 7860)
# =========================
echo "=========================================="
echo " 步骤 1: 启动 Nginx (端口 7860)"
echo "=========================================="

rm -f /etc/nginx/conf.d/default.conf
nginx
sleep 1

if curl -s http://127.0.0.1:7860 > /dev/null 2>&1; then
    log_ok "Nginx 端口 7860 已就绪"
else
    log_warn "Nginx 端口 7860 检查失败"
fi

# =========================
# 步骤 2: 恢复备份
# =========================
echo "=========================================="
echo " 步骤 2: 恢复备份"
echo "=========================================="

if /restore.sh; then
    log_ok "备份恢复成功"
else
    log_warn "无可用备份，继续启动"
fi

# =========================
# 步骤 3: 启动 crond
# =========================
log_info "启动 crond"
crond

# =========================
# 步骤 4: 启动面板 (关键：必须在探针之前启动)
# =========================
echo "=========================================="
echo " 步骤 4: 启动面板"
echo "=========================================="

./app >/dev/null 2>&1 &
APP_PID=$!
log_info "面板已启动 (PID: $APP_PID)"

# 等待面板端口就绪
if ! wait_for_port 8008 60; then
    log_error "面板启动失败"
    exit 1
fi

# 额外等待确保完全初始化
sleep 3
log_ok "面板已完全就绪"

# =========================
# 步骤 5: 生成 SSL 证书
# =========================
if [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 5: 生成 SSL 证书"
    echo "=========================================="
    
    log_info "生成证书: $ARGO_DOMAIN"
    openssl genrsa -out /dashboard/nezha.key 2048 2>/dev/null
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr 2>/dev/null
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem 2>/dev/null
    
    # 替换域名占位符
    sed "s/ARGO_DOMAIN_PLACEHOLDER/$ARGO_DOMAIN/g" /etc/nginx/ssl.conf.template > /etc/nginx/conf.d/ssl.conf
    
    nginx -s reload
    sleep 1
    log_ok "证书生成完成，443 端口已启用"
else
    log_warn "未设置 ARGO_DOMAIN，跳过证书生成"
fi

# =========================
# 步骤 6: 启动 cloudflared
# =========================
if [ -n "$ARGO_AUTH" ]; then
    echo "=========================================="
    echo " 步骤 6: 启动 cloudflared"
    echo "=========================================="
    
    cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
    sleep 5
    
    if pgrep -f "cloudflared" >/dev/null; then
        log_ok "cloudflared 启动成功"
    else
        log_error "cloudflared 启动失败"
    fi
else
    log_warn "未设置 ARGO_AUTH，跳过 cloudflared"
fi

# =========================
# 步骤 7: 下载探针
# =========================
echo "=========================================="
echo " 步骤 7: 下载探针"
echo "=========================================="

arch=$(uname -m)
case $arch in
    x86_64)  fileagent="nezha-agent_linux_amd64.zip" ;;
    aarch64) fileagent="nezha-agent_linux_arm64.zip" ;;
    s390x)   fileagent="nezha-agent_linux_s390x.zip" ;;
    *)
        log_error "不支持的架构: $arch"
        exit 1
        ;;
esac

# 获取版本号
if [ -z "$DASHBOARD_VERSION" ] || [ "$DASHBOARD_VERSION" = "latest" ]; then
    DASHBOARD_VERSION=$(curl -s https://api.github.com/repos/nezhahq/agent/releases/latest \
        | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$DASHBOARD_VERSION" ]; then
        log_error "获取最新版本失败"
        exit 1
    fi
    log_info "使用最新版本: $DASHBOARD_VERSION"
else
    log_info "使用指定版本: $DASHBOARD_VERSION"
fi

URL="https://github.com/nezhahq/agent/releases/download/${DASHBOARD_VERSION}/${fileagent}"
log_info "下载地址: $URL"

wget -q "$URL" -O "$fileagent"
if [ $? -ne 0 ] || [ ! -s "$fileagent" ]; then
    log_error "下载失败: $fileagent"
    exit 1
fi

unzip -qo "$fileagent" -d .
rm -f "$fileagent"
chmod +x ./nezha-agent
log_ok "探针下载完成"

# =========================
# 步骤 8: 启动探针
# =========================
if [ -n "$NZ_UUID" ] && [ -n "$NZ_CLIENT_SECRET" ] && [ -n "$ARGO_DOMAIN" ]; then
    echo "=========================================="
    echo " 步骤 8: 启动探针"
    echo "=========================================="
    
    # 等待隧道建立
    log_info "等待隧道建立"
    sleep 5
    
    # 创建配置文件
    cat > /dashboard/config.yaml <<EOF
client_secret: $NZ_CLIENT_SECRET
debug: true
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: $ARGO_DOMAIN:443
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $NZ_TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $NZ_UUID
EOF

    log_info "探针配置: server=$ARGO_DOMAIN:443, tls=$NZ_TLS"
    
    ./nezha-agent -c /dashboard/config.yaml >/dev/null 2>&1 &
    sleep 3
    
    if pgrep -f "nezha-agent.*config.yaml" >/dev/null; then
        log_ok "探针启动成功"
    else
        log_error "探针启动失败"
    fi
fi

# =========================
# 步骤 9: 启动备份守护进程
# =========================
if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPO_OWNER" ] && [ -n "$GITHUB_REPO_NAME" ]; then
    echo "=========================================="
    echo " 步骤 9: 启动备份守护进程"
    echo "=========================================="
    
    (
        API_BASE="https://api.github.com/repos/$GITHUB_REPO_OWNER/$GITHUB_REPO_NAME"
        BACKUP_HOUR=${BACKUP_HOUR:-4}
        
        while true; do
            current_date=$(date +"%Y-%m-%d")
            current_hour=$(date +"%H")
            
            # 读取 README.md 内容
            readme_content=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                "$API_BASE/contents/README.md?ref=$GITHUB_BRANCH" \
                | jq -r '.content' 2>/dev/null | base64 -d 2>/dev/null | tr -d '[:space:]' || echo "")
            
            should_backup=false
            backup_reason=""
            
            # 情况1: 手动触发
            if [ "$readme_content" = "backup" ]; then
                should_backup=true
                backup_reason="手动触发"
            else
                # 情况2: 定时备份
                latest_backup=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
                    "$API_BASE/contents?ref=$GITHUB_BRANCH" \
                    | jq -r '.[].name' 2>/dev/null | grep '^data-.*\.zip$' | sort -r | head -n1)
                file_date=$(echo "$latest_backup" | sed -n 's/^data-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-.*\.zip$/\1/p')
                
                if [ "$current_hour" -eq "$BACKUP_HOUR" ] && [ "$file_date" != "$current_date" ]; then
                    should_backup=true
                    backup_reason="定时备份 (${BACKUP_HOUR}:00)"
                fi
            fi
            
            # 执行备份
            if [ "$should_backup" = "true" ]; then
                echo "$(date): 触发备份 - $backup_reason"
                [ -f "/backup.sh" ] && /backup.sh
            fi
            
            # 每小时检查一次
            sleep 60
        done
    ) &
    
    log_ok "备份守护进程已启动"
else
    log_warn "GITHUB_TOKEN & GITHUB_REPO_NAME & GITHUB_REPO_OWNER 未设置，跳过备份"
fi

# =========================
# 启动完成
# =========================
echo "=========================================="
echo " 启动完成"
echo "=========================================="
echo " 访问地址: https://$ARGO_DOMAIN"
echo "=========================================="

echo ""
echo "运行中的进程:"
ps aux | grep -E "(app|cloudflared|nezha-agent|nginx)" | grep -v grep

echo ""
log_info "启动健康检查..."

# =========================
# 健康检查循环 (无日志文件)
# =========================
while true; do
    # 检查 NeZha 面板 (核心服务)
    if ! pgrep -x "app" >/dev/null; then
        ./app >/dev/null 2>&1 &
        log_warn "面板已重启"
    fi
    
    # 检查 Cloudflared
    if [ -n "$ARGO_AUTH" ] && ! pgrep -f "cloudflared" >/dev/null; then
        cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
        log_warn "cloudflared 已重启"
    fi

    # 检查 Nginx
    if ! pgrep -x "nginx" >/dev/null; then
        nginx
        log_warn "nginx 已重启"
    fi

    # 检查探针
    if [ -n "$NZ_UUID" ] && ! pgrep -f "nezha-agent" >/dev/null; then
        ./nezha-agent -c /dashboard/config.yaml >/dev/null 2>&1 &
        log_warn "探针已重启"
    fi

    sleep 60
done
