#!/bin/bash

# 部署SSL证书脚本 - 为每个站点创建独立的HTTPS证书并配置自动续期
# 重要提示：每个站点使用完全独立的证书，不共享证书
# 证书存储位置: /etc/nginx/SSL证书/域名/ (支持版本管理)

set -euo pipefail

# 日志设置
LOG_FILE="/var/log/ssl-deploy.log"
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# 配置
ALIYUN_AK_FILE="/root/aliyunak.conf"
CLOUDFLARE_CONF_FILE="/root/cloudflare.conf"
CERT_STORAGE_BASE="/etc/nginx/SSL证书"
CERTBOT_ORIG_BASE="/etc/letsencrypt/archive"

# 状态变量
USE_ALIYUN_DNS=false
USE_CLOUDFLARE_DNS=false
MANUAL_ALIYUN_DNS=false
MANUAL_CLOUDFLARE_DNS=false
MANUAL_CERT=false
MANUAL_CERT_DIR=""
DOMAIN=""

# 重试配置
MAX_RETRIES=3
RETRY_DELAY=5

# 速率限制配置
RATE_LIMIT_DIR="/var/lib/ssl-deploy"
RATE_LIMIT_FILE="$RATE_LIMIT_DIR/rate_limit.json"
# Let's Encrypt 速率限制: 每周最多 50 个证书，每个域名每小时最多 5 次验证
MAX_CERTS_PER_WEEK=50
MAX_ATTEMPTS_PER_DOMAIN_PER_HOUR=3  # 保守设置，避免触发限制

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" | tee -a "$LOG_FILE"
}

# 错误处理函数
error_exit() {
    log_error "$1"
    echo -e "${RED}错误: $1${NC}"
    exit 1
}

# 带重试的命令执行函数
run_with_retry() {
    local cmd="$1"
    local description="${2:-命令}"
    local max_retries="${3:-$MAX_RETRIES}"
    local retry_delay="${4:-$RETRY_DELAY}"
    
    log_info "执行: $description"
    
    for ((i=1; i<=max_retries; i++)); do
        log_info "尝试 $i/$max_retries: $description"
        
        if eval "$cmd"; then
            log_info "✓ $description 成功"
            return 0
        else
            local exit_code=$?
            log_warn "$description 失败 (退出码: $exit_code)"
            
            if [ $i -lt $max_retries ]; then
                log_info "等待 ${retry_delay} 秒后重试..."
                sleep $retry_delay
            fi
        fi
    done
    
    error_exit "$description 在 $max_retries 次尝试后仍然失败"
}

# 检查命令是否存在
check_command() {
    command -v "$1" &> /dev/null
}

# 安装DNS插件
install_dns_plugin() {
    local plugin_type="$1"
    local package_name="certbot-dns-$plugin_type"

    # 检查插件是否已安装
    if ! check_dns_plugin "dns-$plugin_type"; then
        error_exit "$plugin_type DNS 插件未安装，请先运行 安装Certbot插件.sh 安装插件"
    fi

    log_info "✓ $plugin_type DNS 插件已安装并可用"
}

# 初始化速率限制目录
init_rate_limit() {
    mkdir -p "$RATE_LIMIT_DIR"
    if [ ! -f "$RATE_LIMIT_FILE" ]; then
        echo '{"certificates": [], "attempts": {}}' > "$RATE_LIMIT_FILE"
    fi
}

# 检查速率限制
check_rate_limit() {
    local domain="$1"
    local current_time=$(date +%s)
    local one_week_ago=$((current_time - 604800))
    local one_hour_ago=$((current_time - 3600))
    
    init_rate_limit
    
    # 读取现有数据
    local json_data
    json_data=$(cat "$RATE_LIMIT_FILE" 2>/dev/null || echo '{"certificates": [], "attempts": {}}')
    
    # 检查每周证书数量
    local recent_certs
    recent_certs=$(echo "$json_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
current_time = $current_time
one_week_ago = $one_week_ago
count = sum(1 for cert in data.get('certificates', []) if cert.get('timestamp', 0) > one_week_ago)
print(count)
" 2>/dev/null || echo "0")
    
    if [ "$recent_certs" -ge "$MAX_CERTS_PER_WEEK" ]; then
        error_exit "已达到每周证书申请限制 ($MAX_CERTS_PER_WEEK 个)，请稍后再试"
    fi
    
    # 检查域名每小时尝试次数
    local domain_attempts
    domain_attempts=$(echo "$json_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
domain = '$domain'
current_time = $current_time
one_hour_ago = $one_hour_ago
attempts = data.get('attempts', {}).get(domain, [])
count = sum(1 for ts in attempts if ts > one_hour_ago)
print(count)
" 2>/dev/null || echo "0")
    
    if [ "$domain_attempts" -ge "$MAX_ATTEMPTS_PER_DOMAIN_PER_HOUR" ]; then
        error_exit "域名 $domain 已达到每小时申请限制 ($MAX_ATTEMPTS_PER_DOMAIN_PER_HOUR 次)，请稍后再试"
    fi
    
    log_info "速率检查通过: 本周已申请 $recent_certs/$MAX_CERTS_PER_WEEK 个证书，该域名最近1小时已尝试 $domain_attempts/$MAX_ATTEMPTS_PER_DOMAIN_PER_HOUR 次"
}

# 记录证书申请
record_certificate() {
    local domain="$1"
    local current_time=$(date +%s)
    
    init_rate_limit
    
    python3 << EOF
import json
import sys

try:
    with open('$RATE_LIMIT_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {"certificates": [], "attempts": {}}

# 添加证书记录
data["certificates"].append({
    "domain": "$domain",
    "timestamp": $current_time,
    "date": "$(date '+%Y-%m-%d %H:%M:%S')"
})

# 清理旧记录（保留2周）
one_week_ago = $current_time - 1209600
data["certificates"] = [c for c in data["certificates"] if c.get("timestamp", 0) > one_week_ago]

# 保存
with open('$RATE_LIMIT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
EOF
}

# 记录申请尝试
record_attempt() {
    local domain="$1"
    local current_time=$(date +%s)
    
    init_rate_limit
    
    python3 << EOF
import json
import sys

try:
    with open('$RATE_LIMIT_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {"certificates": [], "attempts": {}}

# 添加尝试记录
domain = "$domain"
if domain not in data["attempts"]:
    data["attempts"][domain] = []

data["attempts"][domain].append($current_time)

# 清理旧记录（保留2小时）
one_hour_ago = $current_time - 7200
for d in data["attempts"]:
    data["attempts"][d] = [ts for ts in data["attempts"][d] if ts > one_hour_ago]

# 保存
with open('$RATE_LIMIT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
EOF
}

# 显示速率限制状态
show_rate_limit_status() {
    init_rate_limit
    
    local current_time=$(date +%s)
    local one_week_ago=$((current_time - 604800))
    local one_hour_ago=$((current_time - 3600))
    
    local json_data
    json_data=$(cat "$RATE_LIMIT_FILE" 2>/dev/null || echo '{"certificates": [], "attempts": {}}')
    
    echo ""
    echo "============================================"
    echo "         证书申请速率限制状态"
    echo "============================================"
    echo ""
    
    # 计算本周证书数量
    local recent_certs
    recent_certs=$(echo "$json_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
current_time = $current_time
one_week_ago = $one_week_ago
certs = [c for c in data.get('certificates', []) if c.get('timestamp', 0) > one_week_ago]
print(len(certs))
" 2>/dev/null || echo "0")
    
    echo "本周已申请证书: $recent_certs / $MAX_CERTS_PER_WEEK"
    echo ""
    
    # 显示最近申请的证书
    echo "最近申请的证书 (最近7天):"
    echo "$json_data" | python3 -c "
import sys, json
from datetime import datetime
data = json.load(sys.stdin)
current_time = $current_time
one_week_ago = $one_week_ago
certs = [c for c in data.get('certificates', []) if c.get('timestamp', 0) > one_week_ago]
if certs:
    for cert in sorted(certs, key=lambda x: x.get('timestamp', 0), reverse=True)[:10]:
        print(f\"  - {cert.get('domain', 'unknown')} ({cert.get('date', 'unknown')})\")
else:
    print('  (无)')
" 2>/dev/null || echo "  (无法解析数据)"
    
    echo ""
    echo "各域名最近1小时尝试次数:"
    echo "$json_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
current_time = $current_time
one_hour_ago = $one_hour_ago
attempts = data.get('attempts', {})
has_attempts = False
for domain, timestamps in attempts.items():
    recent = [ts for ts in timestamps if ts > one_hour_ago]
    if recent:
        print(f\"  - {domain}: {len(recent)} / $MAX_ATTEMPTS_PER_DOMAIN_PER_HOUR\")
        has_attempts = True
if not has_attempts:
    print('  (无)')
" 2>/dev/null || echo "  (无法解析数据)"
    
    echo ""
    echo "============================================"
    echo ""
}

# 检查 DNS 插件是否已安装
check_dns_plugin() {
    local plugin_name="$1"
    certbot plugins 2>/dev/null | grep -q "$plugin_name"
}

print_line() {
    echo "============================================"
}

print_header() {
    echo ""
    print_line
    echo -e "${BLUE}$1${NC}"
    print_line
}

input_domain() {
    # 如果已通过命令行参数指定域名，则跳过输入
    if [ -n "$DOMAIN" ]; then
        log_info "使用命令行指定的域名: $DOMAIN"
        # 验证域名格式
        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            error_exit "域名格式无效: $DOMAIN"
        fi
        return 0
    fi
    
    print_header "SSL证书部署向导"
    echo ""
    read -p "请输入要部署SSL证书的域名: " DOMAIN

    if [ -z "$DOMAIN" ]; then
        error_exit "域名不能为空"
    fi
    
    # 验证域名格式
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error_exit "域名格式无效: $DOMAIN"
    fi
    
    echo -e "${GREEN}✓ 已选择域名: $DOMAIN${NC}"
    log_info "选择的域名: $DOMAIN"
}

select_verification_method() {
    # 如果已通过命令行参数指定验证方式，则使用它
    if [ -n "${VERIFY_CHOICE:-}" ]; then
        log_info "使用命令行指定的验证方式: $VERIFY_CHOICE"
        case $VERIFY_CHOICE in
            1)
                echo -e "${GREEN}✓ 已选择: Nginx验证 (HTTP/80端口)${NC}"
                log_info "验证方式: Nginx"
                return 0
                ;;
            2)
                validate_aliyun_config
                MANUAL_ALIYUN_DNS=true
                echo -e "${GREEN}✓ 已选择: 阿里云DNS验证${NC}"
                log_info "验证方式: 阿里云DNS"
                return 0
                ;;
            3)
                validate_cloudflare_config
                MANUAL_CLOUDFLARE_DNS=true
                echo -e "${GREEN}✓ 已选择: Cloudflare DNS验证${NC}"
                log_info "验证方式: Cloudflare DNS"
                return 0
                ;;
            4)
                setup_manual_cert
                MANUAL_CERT=true
                echo -e "${GREEN}✓ 已选择: 手动导入证书${NC}"
                log_info "验证方式: 手动导入"
                return 0
                ;;
            *)
                error_exit "无效的验证方式: $VERIFY_CHOICE"
                ;;
        esac
    fi
    
    print_header "选择证书验证方式"
    echo ""
    echo -e "${YELLOW}1)${NC} Nginx验证     - 使用HTTP/80端口验证"
    echo -e "${YELLOW}2)${NC} 阿里云DNS验证 - 需配置阿里云AccessKey"
    echo -e "${YELLOW}3)${NC} Cloudflare验证 - 需配置Cloudflare API"
    echo -e "${YELLOW}4)${NC} 手动导入证书  - 从其他渠道获取证书"
    echo ""
    read -p "请选择验证方式 [1-4]: " VERIFY_CHOICE

    case $VERIFY_CHOICE in
        1)
            echo -e "${GREEN}✓ 已选择: Nginx验证 (HTTP/80端口)${NC}"
            log_info "验证方式: Nginx"
            ;;
        2)
            validate_aliyun_config
            MANUAL_ALIYUN_DNS=true
            echo -e "${GREEN}✓ 已选择: 阿里云DNS验证${NC}"
            log_info "验证方式: 阿里云DNS"
            ;;
        3)
            validate_cloudflare_config
            MANUAL_CLOUDFLARE_DNS=true
            echo -e "${GREEN}✓ 已选择: Cloudflare DNS验证${NC}"
            log_info "验证方式: Cloudflare DNS"
            ;;
        4)
            setup_manual_cert
            MANUAL_CERT=true
            echo -e "${GREEN}✓ 已选择: 手动导入证书${NC}"
            log_info "验证方式: 手动导入"
            ;;
        *)
            error_exit "无效选择: $VERIFY_CHOICE"
            ;;
    esac
}

validate_aliyun_config() {
    local need_setup=false
    
    if [ ! -f "$ALIYUN_AK_FILE" ]; then
        log_warn "阿里云AK配置文件不存在: $ALIYUN_AK_FILE"
        need_setup=true
    elif ! grep -qE "^dns_aliyun_access_key\s*=" "$ALIYUN_AK_FILE" 2>/dev/null || \
         ! grep -qE "^dns_aliyun_access_key_secret\s*=" "$ALIYUN_AK_FILE" 2>/dev/null; then
        log_warn "阿里云AK文件格式不正确，缺少必要字段"
        need_setup=true
    elif grep -qE "^dns_aliyun_access_key\s*=\s*YOUR_ACCESS_KEY" "$ALIYUN_AK_FILE" 2>/dev/null; then
        log_warn "阿里云AK配置未更新，仍为默认值"
        need_setup=true
    fi
    
    if [ "$need_setup" = true ]; then
        setup_aliyun_config
    fi
    
    log_info "阿里云配置验证通过"
}

setup_aliyun_config() {
    print_header "阿里云 AccessKey 配置向导"
    echo ""
    echo -e "${CYAN}获取方式:${NC}"
    echo "1. 登录阿里云控制台: https://www.aliyun.com"
    echo "2. 点击右上角头像 → AccessKey 管理"
    echo "3. 创建或使用已有的 AccessKey"
    echo ""
    echo -e "${YELLOW}注意:${NC} 建议使用子账号 AccessKey，授予 DNS 解析权限"
    echo ""
    
    read -p "请输入 AccessKey ID: " ak_id
    read -sp "请输入 AccessKey Secret: " ak_secret
    echo ""
    
    if [ -z "$ak_id" ] || [ -z "$ak_secret" ]; then
        error_exit "AccessKey ID 和 Secret 不能为空"
    fi
    
    # 创建配置文件
    cat > "$ALIYUN_AK_FILE" << EOF
# 阿里云 DNS API 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
dns_aliyun_access_key = $ak_id
dns_aliyun_access_key_secret = $ak_secret
EOF
    
    # 设置权限
    chmod 600 "$ALIYUN_AK_FILE"
    
    echo ""
    echo -e "${GREEN}✓ 阿里云配置已保存到: $ALIYUN_AK_FILE${NC}"
    log_info "阿里云配置已创建"
}

validate_cloudflare_config() {
    local need_setup=false
    
    if [ ! -f "$CLOUDFLARE_CONF_FILE" ]; then
        log_warn "Cloudflare配置文件不存在: $CLOUDFLARE_CONF_FILE"
        need_setup=true
    elif ! grep -qE "^dns_cloudflare_api_key\s*=" "$CLOUDFLARE_CONF_FILE" 2>/dev/null && \
         ! grep -qE "^dns_cloudflare_api_token\s*=" "$CLOUDFLARE_CONF_FILE" 2>/dev/null; then
        log_warn "Cloudflare配置无效，缺少API密钥或Token"
        need_setup=true
    elif grep -qE "^dns_cloudflare_api_token\s*=\s*YOUR_API_TOKEN" "$CLOUDFLARE_CONF_FILE" 2>/dev/null || \
         grep -qE "^dns_cloudflare_api_key\s*=\s*YOUR_GLOBAL_API_KEY" "$CLOUDFLARE_CONF_FILE" 2>/dev/null; then
        log_warn "Cloudflare配置未更新，仍为默认值"
        need_setup=true
    fi
    
    if [ "$need_setup" = true ]; then
        setup_cloudflare_config
    fi
    
    log_info "Cloudflare配置验证通过"
}

setup_cloudflare_config() {
    print_header "Cloudflare API 配置向导"
    echo ""
    echo -e "${CYAN}请选择认证方式:${NC}"
    echo ""
    echo -e "${YELLOW}1)${NC} API Token (推荐，更安全)"
    echo -e "   需要创建具有 DNS 编辑权限的 Token"
    echo ""
    echo -e "${YELLOW}2)${NC} Global API Key (传统方式)"
    echo -e "   需要邮箱 + Global API Key"
    echo ""
    
    local auth_choice
    read -p "请选择 [1-2]: " auth_choice
    
    echo ""
    echo -e "${CYAN}获取方式:${NC}"
    echo "1. 登录 Cloudflare 控制台: https://dash.cloudflare.com"
    echo "2. 点击右上角头像 → 我的个人资料"
    echo "3. 选择左侧 API 令牌"
    echo ""
    
    if [ "$auth_choice" = "1" ]; then
        echo -e "${YELLOW}创建 API Token 步骤:${NC}"
        echo "1. 点击 '创建令牌'"
        echo "2. 使用模板 '编辑区域 DNS'"
        echo "3. 区域资源选择: 区域 - 包括 - 您的域名"
        echo "4. 点击 '继续以显示摘要' → '创建令牌'"
        echo ""
        read -sp "请输入 API Token: " api_token
        echo ""
        
        if [ -z "$api_token" ]; then
            error_exit "API Token 不能为空"
        fi
        
        # 创建配置文件
        cat > "$CLOUDFLARE_CONF_FILE" << EOF
# Cloudflare DNS API 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
dns_cloudflare_api_token = $api_token
EOF
        
    elif [ "$auth_choice" = "2" ]; then
        echo -e "${YELLOW}获取 Global API Key:${NC}"
        echo "在 API 令牌页面，查看 'Global API Key' 栏"
        echo ""
        read -p "请输入 Cloudflare 邮箱: " cf_email
        read -sp "请输入 Global API Key: " api_key
        echo ""
        
        if [ -z "$cf_email" ] || [ -z "$api_key" ]; then
            error_exit "邮箱和 API Key 不能为空"
        fi
        
        # 创建配置文件
        cat > "$CLOUDFLARE_CONF_FILE" << EOF
# Cloudflare DNS API 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
dns_cloudflare_api_key = $api_key
dns_cloudflare_email = $cf_email
EOF
    else
        error_exit "无效选择: $auth_choice"
    fi
    
    # 设置权限
    chmod 600 "$CLOUDFLARE_CONF_FILE"
    
    echo ""
    echo -e "${GREEN}✓ Cloudflare 配置已保存到: $CLOUDFLARE_CONF_FILE${NC}"
    log_info "Cloudflare 配置已创建"
}

setup_manual_cert() {
    read -p "请输入证书目录路径: " MANUAL_CERT_DIR
    
    if [ -z "$MANUAL_CERT_DIR" ]; then
        error_exit "证书目录不能为空"
    fi
    
    if [ ! -d "$MANUAL_CERT_DIR" ]; then
        error_exit "证书目录不存在: $MANUAL_CERT_DIR"
    fi
    
    if [ ! -f "$MANUAL_CERT_DIR/fullchain.pem" ]; then
        error_exit "证书目录中缺少 fullchain.pem 文件"
    fi
    
    if [ ! -f "$MANUAL_CERT_DIR/privkey.pem" ]; then
        error_exit "证书目录中缺少 privkey.pem 文件"
    fi
    
    echo -e "${GREEN}✓ 证书目录: $MANUAL_CERT_DIR${NC}"
}

confirm_operation() {
    print_header "确认部署信息"
    echo ""
    echo -e "${CYAN}域名:${NC} ${GREEN}$DOMAIN${NC}"
    
    if [ "$MANUAL_ALIYUN_DNS" = true ]; then
        echo -e "${CYAN}验证方式:${NC} ${GREEN}阿里云DNS验证${NC}"
    elif [ "$MANUAL_CLOUDFLARE_DNS" = true ]; then
        echo -e "${CYAN}验证方式:${NC} ${GREEN}Cloudflare DNS验证${NC}"
    elif [ "$MANUAL_CERT" = true ]; then
        echo -e "${CYAN}验证方式:${NC} ${GREEN}手动导入证书${NC}"
        echo -e "${CYAN}证书目录:${NC} ${GREEN}$MANUAL_CERT_DIR${NC}"
    else
        echo -e "${CYAN}验证方式:${NC} ${GREEN}Nginx验证 (HTTP/80端口)${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}日志文件: $LOG_FILE${NC}"
    echo ""
    read -p "确认开始部署? [y/n]: " CONFIRM

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        log_info "用户取消部署"
        echo "已取消部署"
        exit 0
    fi
}

# 清理旧证书（带错误处理）
cleanup_old_certs() {
    local domain="$1"
    
    log_info "清理旧证书..."
    
    local dirs_to_remove=(
        "$CERTBOT_ORIG_BASE/$domain"
        "$CERTBOT_ORIG_BASE/${domain}-0001"
    )
    
    for dir in "${dirs_to_remove[@]}"; do
        if [ -d "$dir" ]; then
            log_info "删除旧证书目录: $dir"
            sudo rm -rf "$dir" || log_warn "删除 $dir 失败"
        fi
    done
    
    local config_file="/etc/letsencrypt/renewal/${domain}.conf"
    if [ -f "$config_file" ]; then
        log_info "删除旧证书配置: $config_file"
        sudo rm -f "$config_file" || log_warn "删除 $config_file 失败"
    fi
    
    if [ -d "$CERT_STORAGE_BASE/$domain" ]; then
        log_info "清理存储目录中的旧链接"
        sudo rm -f "$CERT_STORAGE_BASE/$domain/latest" 2>/dev/null || true
        sudo rm -f "$CERT_STORAGE_BASE/$domain/fullchain.pem" 2>/dev/null || true
        sudo rm -f "$CERT_STORAGE_BASE/$domain/privkey.pem" 2>/dev/null || true
    fi
    
    log_info "旧证书清理完成"
}

# 申请证书（带健壮性处理）
request_cert() {
    local certbot_cmd="$1"
    local description="$2"
    
    log_info "开始申请证书: $description"
    log_info "命令: $certbot_cmd"
    
    local attempt=1
    local max_attempts=2
    
    while [ $attempt -le $max_attempts ]; do
        log_info "证书申请尝试 $attempt/$max_attempts"
        
        if eval "$certbot_cmd"; then
            log_info "✓ 证书申请成功"
            return 0
        fi
        
        local exit_code=$?
        log_warn "证书申请失败 (退出码: $exit_code)"
        
        if [ $attempt -lt $max_attempts ]; then
            log_info "等待 10 秒后重试..."
            sleep 10
        fi
        
        ((attempt++))
    done
    
    error_exit "证书申请在 $max_attempts 次尝试后仍然失败"
}

# 部署证书到存储目录
deploy_cert() {
    local domain="$1"
    
    log_info "部署证书到存储目录..."
    
    mkdir -p "$CERT_STORAGE_BASE/$domain"
    
    local actual_cert_path="$CERTBOT_ORIG_BASE/$domain"
    if [ ! -d "$actual_cert_path" ]; then
        error_exit "无法找到申请到的证书目录: $actual_cert_path"
    fi
    
    # 查找最新的证书文件（按数字后缀）
    local fullchain_file
    local privkey_file
    
    # 查找 fullchain*.pem 文件，按数字排序取最新的
    fullchain_file=$(ls -1 "$actual_cert_path"/fullchain*.pem 2>/dev/null | sort -V | tail -1)
    privkey_file=$(ls -1 "$actual_cert_path"/privkey*.pem 2>/dev/null | sort -V | tail -1)
    
    if [ -z "$fullchain_file" ]; then
        error_exit "无法找到 fullchain*.pem 证书文件"
    fi
    
    if [ -z "$privkey_file" ]; then
        error_exit "无法找到 privkey*.pem 私钥文件"
    fi
    
    log_info "使用证书文件: $(basename "$fullchain_file")"
    log_info "使用私钥文件: $(basename "$privkey_file")"
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local version_dir="$CERT_STORAGE_BASE/$domain/$timestamp"
    
    mkdir -p "$version_dir"
    
    # 复制证书文件（复制后去掉数字后缀，统一命名为 fullchain.pem / privkey.pem）
    if ! cp "$fullchain_file" "$version_dir/fullchain.pem"; then
        error_exit "复制 fullchain.pem 失败"
    fi
    
    if ! cp "$privkey_file" "$version_dir/privkey.pem"; then
        error_exit "复制 privkey.pem 失败"
    fi
    
    # 创建符号链接
    ln -sf "$timestamp" "$CERT_STORAGE_BASE/$domain/latest"
    ln -sf "latest/fullchain.pem" "$CERT_STORAGE_BASE/$domain/fullchain.pem"
    ln -sf "latest/privkey.pem" "$CERT_STORAGE_BASE/$domain/privkey.pem"
    
    # 设置权限
    chmod 600 "$version_dir/privkey.pem"
    chmod 644 "$version_dir/fullchain.pem"
    
    log_info "✓ 证书已部署到: $version_dir"
}

# 更新nginx站点配置，启用HTTPS
update_nginx_config() {
    local domain="$1"
    local config_file="/etc/nginx/运行站点/${domain}.conf"
    local cert_path="$CERT_STORAGE_BASE/$domain/fullchain.pem"
    local key_path="$CERT_STORAGE_BASE/$domain/privkey.pem"
    
    log_info "检查nginx配置文件: $config_file"
    
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        log_warn "站点配置文件不存在: $config_file"
        log_info "请手动创建配置文件并添加以下内容:"
        echo ""
        generate_nginx_config "$domain" "$cert_path" "$key_path"
        return 0
    fi
    
    # 检查是否已有443端口配置
    if grep -q "listen 443" "$config_file"; then
        log_info "配置文件已包含HTTPS配置，更新证书路径..."
        # 更新证书路径
        sed -i "s|ssl_certificate .*;|ssl_certificate $cert_path;|" "$config_file"
        sed -i "s|ssl_certificate_key .*;|ssl_certificate_key $key_path;|" "$config_file"
        log_info "✓ 证书路径已更新"
    else
        log_info "配置文件缺少HTTPS配置，正在添加..."
        # 备份原配置
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        
        # 读取原配置内容
        local root_path="/var/www/$domain"
        local has_php=false
        local has_static_cache=false
        
        # 检测原配置中的设置
        if grep -q "PHP" "$config_file" 2>/dev/null; then
            has_php=true
        fi
        if grep -q "静态文件缓存" "$config_file" 2>/dev/null; then
            has_static_cache=true
        fi
        
        # 重新生成完整配置
        generate_full_nginx_config "$domain" "$cert_path" "$key_path" "$root_path" "$has_php" "$has_static_cache" > "$config_file"
        log_info "✓ HTTPS配置已添加到: $config_file"
    fi
    
    # 测试nginx配置
    log_info "测试nginx配置..."
    if nginx -t 2>/dev/null; then
        log_info "✓ nginx配置测试通过"
        
        # 重载nginx
        log_info "重载nginx服务..."
        if systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null; then
            log_info "✓ nginx重载成功"
        else
            log_warn "nginx重载失败，请手动检查"
        fi
    else
        log_warn "nginx配置测试失败，请手动检查: $config_file"
        # 恢复备份
        if [ -f "${config_file}.backup".* ]; then
            local latest_backup
            latest_backup=$(ls -t "${config_file}.backup".* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                log_info "正在恢复备份: $latest_backup"
                cp "$latest_backup" "$config_file"
            fi
        fi
    fi
}

# 生成nginx配置模板（用于显示）
generate_nginx_config() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"
    
    cat << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # HTTP 重定向到 HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $domain;

    root /var/www/$domain;
    index index.php index.html index.htm;

    # SSL 证书配置
    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;

    # 引入 SSL 安全配置
    include /etc/nginx/配置片段/SSL通用配置.conf;

    include /etc/nginx/配置片段/通用安全头.conf;
    include /etc/nginx/配置片段/禁止访问.conf;
    include /etc/nginx/配置片段/错误页面.conf;

    access_log /var/log/nginx/$domain.access.log 主日志格式;
    error_log /var/log/nginx/$domain.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # 根据站点需求可选引入以下配置：
    # include /etc/nginx/配置片段/PHP8.4支持.conf;
    # include /etc/nginx/配置片段/静态文件缓存.conf;
}
EOF
}

# 生成完整的nginx配置（用于写入文件）
generate_full_nginx_config() {
    local domain="$1"
    local cert_path="$2"
    local key_path="$3"
    local root_path="$4"
    local has_php="$5"
    local has_static_cache="$6"
    
    cat << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    # HTTP 重定向到 HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $domain;

    root $root_path;
    index index.php index.html index.htm;

    # SSL 证书配置
    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;

    # 引入 SSL 安全配置
    include /etc/nginx/配置片段/SSL通用配置.conf;

    include /etc/nginx/配置片段/通用安全头.conf;
    include /etc/nginx/配置片段/禁止访问.conf;
    include /etc/nginx/配置片段/错误页面.conf;

    access_log /var/log/nginx/$domain.access.log 主日志格式;
    error_log /var/log/nginx/$domain.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
EOF

    if [ "$has_php" = "true" ]; then
        echo ""
        echo "    include /etc/nginx/配置片段/PHP8.4支持.conf;"
    fi
    
    if [ "$has_static_cache" = "true" ]; then
        echo "    include /etc/nginx/配置片段/静态文件缓存.conf;"
    fi
    
    echo "}"
}

# 手动导入证书
deploy_manual_cert() {
    local domain="$1"
    local cert_dir="$2"
    
    log_info "手动导入证书..."
    
    mkdir -p "$CERT_STORAGE_BASE/$domain"
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local version_dir="$CERT_STORAGE_BASE/$domain/$timestamp"
    
    mkdir -p "$version_dir"
    
    if ! cp "$cert_dir/fullchain.pem" "$version_dir/"; then
        error_exit "复制 fullchain.pem 失败"
    fi
    
    if ! cp "$cert_dir/privkey.pem" "$version_dir/"; then
        error_exit "复制 privkey.pem 失败"
    fi
    
    ln -sf "$timestamp" "$CERT_STORAGE_BASE/$domain/latest"
    ln -sf "latest/fullchain.pem" "$CERT_STORAGE_BASE/$domain/fullchain.pem"
    ln -sf "latest/privkey.pem" "$CERT_STORAGE_BASE/$domain/privkey.pem"
    
    chmod 600 "$version_dir/privkey.pem"
    chmod 644 "$version_dir/fullchain.pem"
    
    log_info "✓ 证书导入成功: $version_dir"
}

# 主流程
main() {
    log_info "========== SSL证书部署脚本启动 =========="
    
    # 检查权限
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        error_exit "需要 root 权限或 sudo 访问权限"
    fi
    
    # 创建基础目录
    mkdir -p "$CERT_STORAGE_BASE"
    chmod 755 "$CERT_STORAGE_BASE"
    
    # 用户输入
    input_domain
    select_verification_method
    confirm_operation
    
    echo ""
    echo -e "${YELLOW}开始部署SSL证书...${NC}"
    echo ""
    
    # 处理手动导入
    if [ "$MANUAL_CERT" = true ]; then
        deploy_manual_cert "$DOMAIN" "$MANUAL_CERT_DIR"
        # 更新nginx配置，启用HTTPS
        update_nginx_config "$DOMAIN"
        echo -e "${GREEN}✓ 证书导入成功${NC}"
        log_info "========== 手动导入完成 =========="
        exit 0
    fi
    
    # 检查并安装依赖
    check_and_install_deps
    
    # 检查速率限制
    check_rate_limit "$DOMAIN"
    
    # 清理旧证书
    cleanup_old_certs "$DOMAIN"
    
    # 根据验证方式申请证书
    if [ "$MANUAL_ALIYUN_DNS" = true ]; then
        log_info "使用阿里云DNS验证"
        
        # 设置配置文件权限
        sudo chmod 600 "$ALIYUN_AK_FILE" 2>/dev/null || true
        
        # 安装并验证 DNS 插件
        install_dns_plugin "aliyun"
        
        # 构建命令
        CERTBOT_CMD="sudo certbot certonly --authenticator dns-aliyun"
        CERTBOT_CMD="$CERTBOT_CMD --dns-aliyun-credentials $ALIYUN_AK_FILE"
        CERTBOT_CMD="$CERTBOT_CMD --dns-aliyun-propagation-seconds 60"
        CERTBOT_CMD="$CERTBOT_CMD --agree-tos -m sunbingchen@13aq.com"
        CERTBOT_CMD="$CERTBOT_CMD --no-eff-email --force-renewal -d $DOMAIN"
        
        # 记录尝试
        record_attempt "$DOMAIN"
        request_cert "$CERTBOT_CMD" "阿里云DNS验证"
        
    elif [ "$MANUAL_CLOUDFLARE_DNS" = true ]; then
        log_info "使用Cloudflare DNS验证"
        
        sudo chmod 600 "$CLOUDFLARE_CONF_FILE" 2>/dev/null || true
        
        install_dns_plugin "cloudflare"
        
        CERTBOT_CMD="sudo certbot certonly --authenticator dns-cloudflare"
        CERTBOT_CMD="$CERTBOT_CMD --dns-cloudflare-credentials $CLOUDFLARE_CONF_FILE"
        CERTBOT_CMD="$CERTBOT_CMD --dns-cloudflare-propagation-seconds 60"
        CERTBOT_CMD="$CERTBOT_CMD --agree-tos -m sunbingchen@13aq.com"
        CERTBOT_CMD="$CERTBOT_CMD --no-eff-email --force-renewal -d $DOMAIN"
        
        # 记录尝试
        record_attempt "$DOMAIN"
        request_cert "$CERTBOT_CMD" "Cloudflare DNS验证"
        
    else
        log_info "使用Nginx验证"
        
        # 停止Nginx
        log_info "停止Nginx服务..."
        sudo nginx -s stop 2>/dev/null || sudo systemctl stop nginx 2>/dev/null || true
        sleep 2
        
        CERTBOT_CMD="sudo certbot certonly --nginx"
        CERTBOT_CMD="$CERTBOT_CMD --agree-tos -m sunbingchen@13aq.com"
        CERTBOT_CMD="$CERTBOT_CMD --no-eff-email -d $DOMAIN"
        
        # 记录尝试
        record_attempt "$DOMAIN"
        request_cert "$CERTBOT_CMD" "Nginx验证"
        
        # 重新启动Nginx
        log_info "重新启动Nginx..."
        if ! sudo nginx; then
            log_warn "Nginx启动失败，尝试使用 systemctl..."
            sudo systemctl start nginx || error_exit "无法启动Nginx"
        fi
    fi
    
    # 部署证书
    deploy_cert "$DOMAIN"
    
    # 记录成功申请的证书
    record_certificate "$DOMAIN"
    
    # 更新nginx配置，启用HTTPS
    update_nginx_config "$DOMAIN"
    
    # 成功提示
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  SSL证书部署成功!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${CYAN}域名:${NC} $DOMAIN"
    echo -e "${CYAN}证书路径:${NC} $CERT_STORAGE_BASE/$DOMAIN/"
    echo -e "${CYAN}站点配置:${NC} /etc/nginx/运行站点/${DOMAIN}.conf"
    echo -e "${CYAN}日志文件:${NC} $LOG_FILE"
    echo ""
    
    log_info "========== SSL证书部署成功完成 =========="
}

# 显示帮助信息
show_help() {
    echo ""
    echo "SSL证书部署脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo "  -s, --status        显示速率限制状态"
    echo "  -d, --domain        指定域名（跳过交互式输入）"
    echo "  -m, --method        指定验证方式（1=Nginx, 2=阿里云DNS, 3=Cloudflare, 4=手动导入）"
    echo ""
    echo "示例:"
    echo "  $0                  交互式运行"
    echo "  $0 -s               查看速率限制状态"
    echo "  $0 -d example.com -m 1   使用Nginx验证为example.com申请证书"
    echo ""
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -s|--status)
                show_rate_limit_status
                exit 0
                ;;
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -m|--method)
                VERIFY_CHOICE="$2"
                shift 2
                ;;
            *)
                echo "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 错误处理陷阱
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "脚本异常退出 (退出码: $exit_code)"
        echo -e "${RED}部署失败，请查看日志: $LOG_FILE${NC}"
    fi
}
trap cleanup_on_error EXIT

# 解析参数
parse_args "$@"

# 运行主程序
main
