#!/bin/bash

# 生成自签名SSL证书脚本 - 交互式生成自签名证书
# 证书存储位置: /etc/nginx/自签名SSL证书/域名/ (支持版本管理)

set -euo pipefail

# 日志设置
LOG_FILE="/var/log/ssl-self-signed.log"
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# 配置
CERT_STORAGE_BASE="/etc/nginx/自签名SSL证书"

# 状态变量
DOMAIN=""

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

print_line() {
    echo "============================================"
}

print_header() {
    echo ""
    print_line
    echo -e "${BLUE}$1${NC}"
    print_line
}

# 交互式输入域名
input_domain() {
    print_header "自签名SSL证书生成向导"
    echo ""
    read -p "请输入要生成自签名证书的域名: " DOMAIN

    if [ -z "$DOMAIN" ]; then
        error_exit "域名不能为空"
    fi
    
    validate_domain "$DOMAIN"
    echo -e "${GREEN}✓ 已选择域名: $DOMAIN${NC}"
    log_info "选择的域名: $DOMAIN"
}

# 验证域名格式
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error_exit "域名格式无效: $domain"
    fi
}

# 生成自签名证书
generate_self_signed_cert() {
    local domain="$1"
    local cert_dir="$CERT_STORAGE_BASE/$domain"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local version_dir="$cert_dir/$timestamp"
    
    log_info "生成自签名证书..."
    
    # 创建目录结构
    mkdir -p "$version_dir"
    
    # 生成私钥
    local privkey_file="$version_dir/privkey.pem"
    log_info "生成私钥: $privkey_file"
    openssl genrsa -out "$privkey_file" 2048
    chmod 600 "$privkey_file"
    
    # 生成CSR
    local csr_file="$version_dir/cert.csr"
    log_info "生成CSR: $csr_file"
    openssl req -new -key "$privkey_file" -out "$csr_file" -subj "/CN=$domain/O=Self-Signed/C=CN"
    
    # 生成自签名证书
    local cert_file="$version_dir/fullchain.pem"
    log_info "生成自签名证书: $cert_file"
    openssl x509 -req -days 365 -in "$csr_file" -signkey "$privkey_file" -out "$cert_file"
    chmod 644 "$cert_file"
    
    # 清理CSR文件
    rm -f "$csr_file"
    
    # 创建符号链接
    ln -sf "$timestamp" "$cert_dir/latest" 2>/dev/null || true
    ln -sf "latest/fullchain.pem" "$cert_dir/fullchain.pem" 2>/dev/null || true
    ln -sf "latest/privkey.pem" "$cert_dir/privkey.pem" 2>/dev/null || true
    
    log_info "✓ 自签名证书生成成功: $version_dir"
    return 0
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

# 主流程
main() {
    log_info "========== 自签名证书生成脚本启动 =========="
    
    # 检查权限
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        error_exit "需要 root 权限或 sudo 访问权限"
    fi
    
    # 检查openssl是否安装
    if ! command -v openssl &> /dev/null; then
        error_exit "openssl 未安装，请先安装 openssl"
    fi
    
    # 创建基础目录
    mkdir -p "$CERT_STORAGE_BASE"
    chmod 755 "$CERT_STORAGE_BASE"
    
    # 交互式输入域名
    input_domain
    
    echo ""
    echo -e "${YELLOW}开始生成自签名证书...${NC}"
    echo ""
    
    # 生成自签名证书
    generate_self_signed_cert "$DOMAIN"
    
    # 更新nginx配置，启用HTTPS
    update_nginx_config "$DOMAIN"
    
    # 成功提示
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  自签名证书生成成功!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${CYAN}域名:${NC} $DOMAIN"
    echo -e "${CYAN}证书路径:${NC} $CERT_STORAGE_BASE/$DOMAIN/"
    echo -e "${CYAN}站点配置:${NC} /etc/nginx/运行站点/${DOMAIN}.conf"
    echo -e "${CYAN}日志文件:${NC} $LOG_FILE"
    echo ""
    echo -e "${YELLOW}注意:${NC} 自签名证书不会被浏览器信任，仅用于测试或内部环境"
    echo ""
    
    log_info "========== 自签名证书生成成功完成 =========="
}

# 显示帮助信息
show_help() {
    echo ""
    echo "自签名证书生成脚本"
    echo ""
    echo "用法: $0"
    echo ""
    echo "选项:"
    echo "  -h, --help          显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                  交互式运行"
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
        echo -e "${RED}生成失败，请查看日志: $LOG_FILE${NC}"
    fi
}
trap cleanup_on_error EXIT

# 解析参数
parse_args "$@"

# 运行主程序
main
