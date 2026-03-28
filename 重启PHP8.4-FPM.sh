#!/bin/bash

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

# 显示帮助信息
show_help() {
    echo ""
    echo "PHP 8.4-FPM 重启脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help      显示此帮助信息"
    echo "  -s, --status    查看 PHP 8.4-FPM 状态"
    echo "  -t, --test      测试 PHP 配置"
    echo ""
    echo "示例:"
    echo "  $0              重启 PHP 8.4-FPM 服务"
    echo "  $0 -s           查看服务状态"
    echo "  $0 -t           测试配置文件"
    echo ""
}

# 检查 PHP 8.4-FPM 是否已安装
check_install() {
    if ! command -v php-fpm8.4 &> /dev/null; then
        if [ ! -f "/usr/sbin/php-fpm8.4" ] && [ ! -f "/usr/local/sbin/php-fpm8.4" ]; then
            echo -e "${RED}错误: PHP 8.4-FPM 未安装${RESET}"
            exit 1
        fi
    fi
}

# 获取 PHP 8.4-FPM 服务名称
get_service_name() {
    # 尝试不同的服务名称
    if systemctl list-unit-files | grep -q "^php8.4-fpm"; then
        echo "php8.4-fpm"
    elif systemctl list-unit-files | grep -q "^php-fpm8.4"; then
        echo "php-fpm8.4"
    elif systemctl list-unit-files | grep -q "^php8.4-fpm"; then
        echo "php8.4-fpm"
    elif [ -f "/etc/init.d/php8.4-fpm" ]; then
        echo "/etc/init.d/php8.4-fpm"
    elif [ -f "/etc/init.d/php-fpm8.4" ]; then
        echo "/etc/init.d/php-fpm8.4"
    else
        echo ""
    fi
}

# 测试 PHP-FPM 配置
test_config() {
    echo "正在测试 PHP 8.4-FPM 配置..."

    local config_test_result
    config_test_result=$(php-fpm8.4 -t 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ PHP 8.4-FPM 配置测试通过${RESET}"
        echo "$config_test_result" | grep -E "(test|successful|error|warning)" || true
        return 0
    else
        echo -e "${RED}✗ PHP 8.4-FPM 配置测试失败${RESET}"
        echo "$config_test_result"
        return 1
    fi
}

# 查看 PHP-FPM 状态
show_status() {
    echo "正在查询 PHP 8.4-FPM 服务状态..."
    echo ""

    local service_name
    service_name=$(get_service_name)

    if [ -n "$service_name" ]; then
        if [[ "$service_name" == /etc/init.d/* ]]; then
            "$service_name" status 2>/dev/null || echo "无法获取状态"
        else
            systemctl status "$service_name" --no-pager 2>/dev/null || echo "无法获取状态"
        fi
    else
        # 尝试直接检查进程
        local process_count
        process_count=$(pgrep -c "php-fpm8.4" 2>/dev/null || echo "0")
        if [ "$process_count" -gt 0 ]; then
            echo -e "${GREEN}PHP 8.4-FPM 正在运行 (进程数: $process_count)${RESET}"
            echo ""
            echo "进程详情:"
            ps aux | grep "php-fpm8.4" | grep -v grep
        else
            echo -e "${RED}PHP 8.4-FPM 未运行${RESET}"
        fi
    fi

    echo ""
    echo "PHP 8.4 版本信息:"
    php-fpm8.4 -v 2>/dev/null | head -2 || echo "无法获取版本信息"

    echo ""
    echo "监听配置:"
    if [ -S "/var/run/php/php8.4-fpm.sock" ]; then
        echo -e "${GREEN}✓ Socket 文件存在: /var/run/php/php8.4-fpm.sock${RESET}"
        ls -la /var/run/php/php8.4-fpm.sock
    else
        echo -e "${YELLOW}! Socket 文件不存在: /var/run/php/php8.4-fpm.sock${RESET}"
    fi

    # 检查是否有监听端口
    local listen_port
    listen_port=$(netstat -tlnp 2>/dev/null | grep "php-fpm" | awk '{print $4}' | head -1)
    if [ -n "$listen_port" ]; then
        echo -e "${GREEN}✓ TCP 监听: $listen_port${RESET}"
    fi
}

# 重启 PHP-FPM
restart_service() {
    echo "正在重启 PHP 8.4-FPM 服务..."
    echo ""

    local service_name
    service_name=$(get_service_name)

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 无法找到 PHP 8.4-FPM 服务${RESET}"
        echo "请确认 PHP 8.4-FPM 已正确安装"
        exit 1
    fi

    echo "检测到服务: $service_name"
    echo ""

    # 先测试配置
    if ! test_config; then
        echo ""
        echo -e "${RED}配置测试失败，取消重启操作${RESET}"
        exit 1
    fi

    echo ""

    # 执行重启
    local restart_success=false

    if [[ "$service_name" == /etc/init.d/* ]]; then
        if "$service_name" restart; then
            restart_success=true
        fi
    else
        if systemctl restart "$service_name" 2>/dev/null; then
            restart_success=true
        elif service "$(basename "$service_name")" restart 2>/dev/null; then
            restart_success=true
        fi
    fi

    # 等待服务启动
    sleep 2

    # 验证重启结果
    if [ "$restart_success" = true ]; then
        local process_count
        process_count=$(pgrep -c "php-fpm8.4" 2>/dev/null || echo "0")

        if [ "$process_count" -gt 0 ]; then
            echo ""
            echo -e "${GREEN}============================================${RESET}"
            echo -e "${GREEN}  PHP 8.4-FPM 重启成功!${RESET}"
            echo -e "${GREEN}============================================${RESET}"
            echo ""
            echo "进程数: $process_count"
            echo ""
            echo "运行中的进程:"
            pgrep -a "php-fpm8.4" | head -5

            if [ "$process_count" -gt 5 ]; then
                echo "... 及其他 $((process_count - 5)) 个进程"
            fi

            echo ""
            echo "Socket 状态:"
            if [ -S "/var/run/php/php8.4-fpm.sock" ]; then
                echo -e "${GREEN}✓ Socket 文件正常${RESET}"
            else
                echo -e "${YELLOW}! Socket 文件可能未创建${RESET}"
            fi

            return 0
        else
            echo -e "${RED}错误: 服务重启后未检测到运行中的进程${RESET}"
            return 1
        fi
    else
        echo -e "${RED}错误: PHP 8.4-FPM 重启失败${RESET}"
        echo ""
        echo "尝试查看错误日志:"
        if [ -f "/var/log/php8.4-fpm.log" ]; then
            tail -20 /var/log/php8.4-fpm.log
        elif [ -f "/var/log/php-fpm8.4.log" ]; then
            tail -20 /var/log/php-fpm8.4.log
        elif [ -f "/var/log/php-fpm/error.log" ]; then
            tail -20 /var/log/php-fpm/error.log
        else
            echo "未找到错误日志文件"
        fi
        return 1
    fi
}

# 主程序
main() {
    # 检查是否有参数
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--status)
            check_install
            show_status
            exit 0
            ;;
        -t|--test)
            check_install
            test_config
            exit $?
            ;;
        "")
            # 无参数，执行重启
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac

    # 检查权限
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        echo -e "${RED}错误: 需要 root 权限或 sudo 访问权限${RESET}"
        echo "请使用 sudo 运行此脚本"
        exit 1
    fi

    check_install
    restart_service
}

# 运行主程序
main "$@"
