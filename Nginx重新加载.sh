#!/bin/bash

set -e

echo "正在测试 nginx 配置..."
if ! nginx -t; then
    echo "错误: nginx 配置测试失败"
    exit 1
fi

echo "正在重新加载 nginx..."
if nginx -s reload; then
    echo "nginx 重新加载成功"
else
    echo "错误: 重新加载 nginx 失败，尝试重启..."
    systemctl restart nginx || service nginx restart || /etc/init.d/nginx restart
fi
