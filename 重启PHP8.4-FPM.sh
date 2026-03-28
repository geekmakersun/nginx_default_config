#!/bin/bash

set -e

# 颜色定义
绿色='\033[0;32m'
红色='\033[0;31m'
黄色='\033[1;33m'
恢复='\033[0m'

# 显示帮助信息
显示帮助() {
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
检查安装() {
    if ! command -v php-fpm8.4 &> /dev/null; then
        if [ ! -f "/usr/sbin/php-fpm8.4" ] && [ ! -f "/usr/local/sbin/php-fpm8.4" ]; then
            echo -e "${红色}错误: PHP 8.4-FPM 未安装${恢复}"
            exit 1
        fi
    fi
}

# 获取 PHP 8.4-FPM 服务名称
获取服务名() {
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
测试配置() {
    echo "正在测试 PHP 8.4-FPM 配置..."

    local 配置测试结果
    配置测试结果=$(php-fpm8.4 -t 2>&1)
    local 退出码=$?

    if [ $退出码 -eq 0 ]; then
        echo -e "${绿色}✓ PHP 8.4-FPM 配置测试通过${恢复}"
        echo "$配置测试结果" | grep -E "(test|successful|error|warning)" || true
        return 0
    else
        echo -e "${红色}✗ PHP 8.4-FPM 配置测试失败${恢复}"
        echo "$配置测试结果"
        return 1
    fi
}

# 查看 PHP-FPM 状态
查看状态() {
    echo "正在查询 PHP 8.4-FPM 服务状态..."
    echo ""

    local 服务名
    服务名=$(获取服务名)

    if [ -n "$服务名" ]; then
        if [[ "$服务名" == /etc/init.d/* ]]; then
            "$服务名" status 2>/dev/null || echo "无法获取状态"
        else
            systemctl status "$服务名" --no-pager 2>/dev/null || echo "无法获取状态"
        fi
    else
        # 尝试直接检查进程
        local 进程数
        进程数=$(pgrep -c "php-fpm8.4" 2>/dev/null || echo "0")
        if [ "$进程数" -gt 0 ]; then
            echo -e "${绿色}PHP 8.4-FPM 正在运行 (进程数: $进程数)${恢复}"
            echo ""
            echo "进程详情:"
            ps aux | grep "php-fpm8.4" | grep -v grep
        else
            echo -e "${红色}PHP 8.4-FPM 未运行${恢复}"
        fi
    fi

    echo ""
    echo "PHP 8.4 版本信息:"
    php-fpm8.4 -v 2>/dev/null | head -2 || echo "无法获取版本信息"

    echo ""
    echo "监听配置:"
    if [ -S "/var/run/php/php8.4-fpm.sock" ]; then
        echo -e "${绿色}✓ Socket 文件存在: /var/run/php/php8.4-fpm.sock${恢复}"
        ls -la /var/run/php/php8.4-fpm.sock
    else
        echo -e "${黄色}! Socket 文件不存在: /var/run/php/php8.4-fpm.sock${恢复}"
    fi

    # 检查是否有监听端口
    local 监听端口
    监听端口=$(netstat -tlnp 2>/dev/null | grep "php-fpm" | awk '{print $4}' | head -1)
    if [ -n "$监听端口" ]; then
        echo -e "${绿色}✓ TCP 监听: $监听端口${恢复}"
    fi
}

# 重启 PHP-FPM
重启服务() {
    echo "正在重启 PHP 8.4-FPM 服务..."
    echo ""

    local 服务名
    服务名=$(获取服务名)

    if [ -z "$服务名" ]; then
        echo -e "${红色}错误: 无法找到 PHP 8.4-FPM 服务${恢复}"
        echo "请确认 PHP 8.4-FPM 已正确安装"
        exit 1
    fi

    echo "检测到服务: $服务名"
    echo ""

    # 先测试配置
    if ! 测试配置; then
        echo ""
        echo -e "${红色}配置测试失败，取消重启操作${恢复}"
        exit 1
    fi

    echo ""

    # 执行重启
    local 重启成功=false

    if [[ "$服务名" == /etc/init.d/* ]]; then
        if "$服务名" restart; then
            重启成功=true
        fi
    else
        if systemctl restart "$服务名" 2>/dev/null; then
            重启成功=true
        elif service "$(basename "$服务名")" restart 2>/dev/null; then
            重启成功=true
        fi
    fi

    # 等待服务启动
    sleep 2

    # 验证重启结果
    if [ "$重启成功" = true ]; then
        local 进程数
        进程数=$(pgrep -c "php-fpm8.4" 2>/dev/null || echo "0")

        if [ "$进程数" -gt 0 ]; then
            echo ""
            echo -e "${绿色}============================================${恢复}"
            echo -e "${绿色}  PHP 8.4-FPM 重启成功!${恢复}"
            echo -e "${绿色}============================================${恢复}"
            echo ""
            echo "进程数: $进程数"
            echo ""
            echo "运行中的进程:"
            pgrep -a "php-fpm8.4" | head -5

            if [ "$进程数" -gt 5 ]; then
                echo "... 及其他 $((进程数 - 5)) 个进程"
            fi

            echo ""
            echo "Socket 状态:"
            if [ -S "/var/run/php/php8.4-fpm.sock" ]; then
                echo -e "${绿色}✓ Socket 文件正常${恢复}"
            else
                echo -e "${黄色}! Socket 文件可能未创建${恢复}"
            fi

            return 0
        else
            echo -e "${红色}错误: 服务重启后未检测到运行中的进程${恢复}"
            return 1
        fi
    else
        echo -e "${红色}错误: PHP 8.4-FPM 重启失败${恢复}"
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
主程序() {
    # 检查是否有参数
    case "${1:-}" in
        -h|--help)
            显示帮助
            exit 0
            ;;
        -s|--status)
            检查安装
            查看状态
            exit 0
            ;;
        -t|--test)
            检查安装
            测试配置
            exit $?
            ;;
        "")
            # 无参数，执行重启
            ;;
        *)
            echo "未知选项: $1"
            显示帮助
            exit 1
            ;;
    esac

    # 检查权限
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        echo -e "${红色}错误: 需要 root 权限或 sudo 访问权限${恢复}"
        echo "请使用 sudo 运行此脚本"
        exit 1
    fi

    检查安装
    重启服务
}

# 运行主程序
主程序 "$@"
