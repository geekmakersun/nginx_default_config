# Nginx 多站点配置架构说明

## 目录结构

```
nginx_default_config/
├── nginx.conf                    # 主配置文件
├── README.md                     # 项目说明文档
├── LICENSE                       # 开源许可证
├── 配置片段/                      # 通用配置片段（可复用配置）
│   ├── 日志格式.conf              # 日志格式定义
│   ├── 性能优化.conf              # 性能优化配置
│   ├── Gzip压缩.conf              # Gzip 压缩配置
│   ├── 通用安全头.conf            # 基础安全响应头
│   ├── 高级安全头.conf            # 高级安全响应头（HSTS、CSP）
│   ├── SSL通用配置.conf           # SSL/TLS 安全配置
│   ├── SSL证书.conf               # SSL 证书路径模板
│   ├── 通用代理.conf              # 反向代理通用配置
│   ├── WebSocket代理.conf         # WebSocket 代理配置
│   ├── 静态文件缓存.conf          # 静态文件缓存配置
│   ├── 禁止访问.conf              # 禁止访问敏感文件配置
│   ├── 错误页面.conf              # 错误页面配置
│   ├── PHP7.4支持.conf            # PHP 7.4-FPM 支持
│   ├── PHP8.0支持.conf            # PHP 8.0-FPM 支持
│   ├── PHP8.1支持.conf            # PHP 8.1-FPM 支持
│   ├── PHP8.2支持.conf            # PHP 8.2-FPM 支持
│   ├── 负载均衡配置.conf          # 上游服务器配置示例
│   ├── 站点日志.conf              # 站点独立日志配置
│   ├── 站点详细日志.conf          # 包含上游响应时间的详细日志
│   ├── 站点JSON日志.conf          # JSON格式日志配置
│   ├── 禁用日志.conf              # 禁用访问日志配置
│   └── 审计日志.conf              # 敏感操作审计日志配置
├── 可用站点/                      # 所有站点配置模板
│   ├── 默认站点.conf              # 默认站点配置
│   ├── 示例站点-反向代理.conf     # 反向代理到后端应用
│   ├── 示例站点-SSL安全.conf      # 完整SSL安全配置
│   ├── 示例站点-负载均衡.conf     # 多服务器负载均衡
│   ├── 示例站点-静态资源.conf     # 纯静态站点/CDN源站
│   ├── 示例站点-PHP应用.conf      # PHP 8.1 应用配置
│   ├── 示例站点-PHP7.4应用.conf   # PHP 7.4 专用配置
│   └── 示例站点-PHP8.1应用.conf   # PHP 8.1 专用配置
├── 运行站点/                      # 正在运行的站点（软链接）
│   └── 默认站点.conf              # 默认站点配置
├── 暂停站点/                      # 暂停的站点配置
│   └── .gitkeep                   # 保留空目录
├── SSL证书/                       # SSL证书存放目录
│   └── .gitkeep                   # 保留空目录
└── 日志/                          # 多站点日志目录
    ├── 访问日志/                  # 各站点访问日志
    │   └── .gitkeep               # 保留空目录
    ├── 错误日志/                  # 各站点错误日志
    │   └── .gitkeep               # 保留空目录
    └── 审计日志/                  # 敏感操作审计日志
        └── .gitkeep               # 保留空目录
```

## 核心设计思想

### 1. 模块化配置（DRY 原则）

所有通用配置抽取到 **配置片段** 目录，通过 `include` 引入：

```nginx
# 在站点配置中引入需要的配置片段
include /etc/nginx/配置片段/通用安全头.conf;
include /etc/nginx/配置片段/禁止访问.conf;
include /etc/nginx/配置片段/静态文件缓存.conf;
```

**优势**：
- 避免重复代码
- 统一修改一处生效
- 便于维护和管理

### 2. 多站点管理模式

采用 **"可用/运行/暂停"** 三态管理模式：

- **可用站点**：存放所有站点配置文件模板
- **运行站点**：通过软链接指向可用站点，Nginx 只加载此目录下的配置
- **暂停站点**：临时停用但保留配置的站点

## 配置片段详解

### 安全相关

| 配置片段 | 用途 | 适用场景 |
|---------|------|---------|
| `通用安全头.conf` | X-Frame-Options、XSS保护等基础安全头 | 所有站点 |
| `高级安全头.conf` | HSTS、CSP、Referrer策略等（自动引入通用安全头） | 金融、支付类高安全站点 |
| `禁止访问.conf` | 禁止访问隐藏文件、版本控制目录、敏感文件 | 所有站点 |
| `SSL通用配置.conf` | TLS协议、加密算法、OCSP Stapling | HTTPS站点 |
| `SSL证书.conf` | 证书路径配置模板（仅路径，不包含SSL协议设置） | HTTPS站点 |

### 性能优化

| 配置片段 | 用途 | 适用场景 |
|---------|------|---------|
| `性能优化.conf` | 文件缓存、sendfile、keepalive等 | 所有站点 |
| `Gzip压缩.conf` | Gzip压缩配置和文件类型 | 所有站点 |
| `静态文件缓存.conf` | 图片、CSS、JS等静态资源缓存策略 | 所有站点 |

### 代理相关

| 配置片段 | 用途 | 适用场景 |
|---------|------|---------|
| `通用代理.conf` | 反向代理头设置、超时配置 | API代理、应用代理 |
| `WebSocket代理.conf` | WebSocket长连接代理配置（自动引入通用代理） | 实时通信应用 |
| `负载均衡配置.conf` | upstream服务器组配置示例 | 高可用架构 |

### PHP支持

| 配置片段 | 用途 | 适用场景 |
|---------|------|---------|
| `PHP7.4支持.conf` | PHP 7.4-FPM FastCGI配置 | 旧项目兼容 |
| `PHP8.0支持.conf` | PHP 8.0-FPM FastCGI配置 | 一般项目 |
| `PHP8.1支持.conf` | PHP 8.1-FPM FastCGI配置 | 推荐版本 |
| `PHP8.2支持.conf` | PHP 8.2-FPM FastCGI配置 | 最新版本 |

**注意**：PHP配置中已移除 `location ~ /\.(ht|svn|git)`，请同时引入 `禁止访问.conf`

### 其他

| 配置片段 | 用途 | 适用场景 |
|---------|------|---------|
| `日志格式.conf` | 主日志、详细日志、JSON日志格式定义 | 全局配置 |
| `错误页面.conf` | 404、50x错误页面配置 | 所有站点 |
| `站点日志.conf` | 站点独立访问日志和错误日志 | 所有站点 |
| `站点详细日志.conf` | 包含上游响应时间的详细日志 | 调试场景 |
| `站点JSON日志.conf` | JSON格式日志（用于ELK等） | 日志分析系统 |
| `禁用日志.conf` | 禁用访问日志（仅保留错误日志） | 静态资源站点 |
| `审计日志.conf` | 记录敏感操作（登录、支付等） | 高安全要求站点 |

## 快速开始

### 1. 启用一个站点

```bash
# 方法1：创建软链接（推荐，节省空间，便于同步更新）
ln -s /etc/nginx/可用站点/示例站点-反向代理.conf /etc/nginx/运行站点/我的站点.conf

# 方法2：复制配置文件（独立管理）
cp /etc/nginx/可用站点/示例站点-反向代理.conf /etc/nginx/运行站点/我的站点.conf

# 测试配置语法
nginx -t

# 重载配置（不中断服务）
nginx -s reload
```

### 2. 暂停一个站点

```bash
# 删除软链接（保留原配置）
rm /etc/nginx/运行站点/我的站点

# 或者移动到暂停站点目录
mv /etc/nginx/运行站点/我的站点 /etc/nginx/暂停站点/

# 重载配置
nginx -s reload
```

### 3. 删除一个站点

```bash
# 先停止运行
rm /etc/nginx/运行站点/我的站点

# 再删除配置
rm /etc/nginx/可用站点/我的站点

nginx -s reload
```

## 站点配置示例

### 基础站点结构

```nginx
server {
    listen 80;
    server_name example.com;

    include /etc/nginx/配置片段/禁止访问.conf;

    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name example.com;

    # SSL 证书路径
    ssl_certificate /etc/nginx/SSL证书/example.com.crt;
    ssl_certificate_key /etc/nginx/SSL证书/example.com.key;
    
    # SSL 安全配置（协议、算法等）
    include /etc/nginx/配置片段/SSL通用配置.conf;

    root /var/www/example;
    index index.html;

    # 引入通用配置
    include /etc/nginx/配置片段/通用安全头.conf;
    include /etc/nginx/配置片段/禁止访问.conf;
    include /etc/nginx/配置片段/错误页面.conf;
    include /etc/nginx/配置片段/静态文件缓存.conf;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

### PHP 多版本示例

**PHP 7.4 站点**：
```nginx
# 在 server 块中
location / {
    try_files $uri $uri/ /index.php?$query_string;
}

# 使用 PHP 7.4
include /etc/nginx/配置片段/PHP7.4支持.conf;
include /etc/nginx/配置片段/禁止访问.conf;  # 重要：PHP配置不再包含此部分
include /etc/nginx/配置片段/静态文件缓存.conf;
```

**PHP 8.1 站点**：
```nginx
# 在 server 块中
location / {
    try_files $uri $uri/ /index.php?$query_string;
}

# 使用 PHP 8.1
include /etc/nginx/配置片段/PHP8.1支持.conf;
include /etc/nginx/配置片段/禁止访问.conf;  # 重要：PHP配置不再包含此部分
include /etc/nginx/配置片段/静态文件缓存.conf;
```

## 常用命令

### 配置管理

```bash
# 测试配置语法
nginx -t

# 测试并显示完整配置
nginx -T

# 重载配置（热更新）
nginx -s reload

# 快速停止
nginx -s stop

# 优雅停止（处理完当前请求）
nginx -s quit
```

### 站点管理脚本

```bash
#!/bin/bash
# 站点管理脚本 - 保存为 /usr/local/bin/站点管理

站点目录="/etc/nginx"

启用站点() {
    if [ -f "$站点目录/可用站点/$1" ]; then
        ln -sf "$站点目录/可用站点/$1" "$站点目录/运行站点/$1"
        nginx -t && nginx -s reload
        echo "✓ 站点 $1 已启用"
    else
        echo "✗ 错误：站点 $1 不存在"
    fi
}

停用站点() {
    if [ -L "$站点目录/运行站点/$1" ]; then
        rm "$站点目录/运行站点/$1"
        nginx -s reload
        echo "✓ 站点 $1 已停用"
    else
        echo "✗ 错误：站点 $1 未运行"
    fi
}

暂停站点() {
    if [ -L "$站点目录/运行站点/$1" ]; then
        mv "$站点目录/运行站点/$1" "$站点目录/暂停站点/$1"
        nginx -s reload
        echo "✓ 站点 $1 已暂停"
    else
        echo "✗ 错误：站点 $1 未运行"
    fi
}

恢复站点() {
    if [ -f "$站点目录/暂停站点/$1" ]; then
        ln -sf "$站点目录/可用站点/$1" "$站点目录/运行站点/$1"
        rm "$站点目录/暂停站点/$1"
        nginx -s reload
        echo "✓ 站点 $1 已恢复"
    else
        echo "✗ 错误：站点 $1 不在暂停列表"
    fi
}

列出站点() {
    echo "=== 可用站点 ==="
    ls -1 "$站点目录/可用站点/" 2>/dev/null || echo "(无)"
    echo ""
    echo "=== 运行中站点 ==="
    ls -1 "$站点目录/运行站点/" 2>/dev/null || echo "(无)"
    echo ""
    echo "=== 暂停站点 ==="
    ls -1 "$站点目录/暂停站点/" 2>/dev/null || echo "(无)"
}

case "$1" in
    启用|start)
        启用站点 "$2"
        ;;
    停用|stop)
        停用站点 "$2"
        ;;
    暂停|pause)
        暂停站点 "$2"
        ;;
    恢复|resume)
        恢复站点 "$2"
        ;;
    列表|list|ls)
        列出站点
        ;;
    *)
        echo "用法: $0 {启用|停用|暂停|恢复|列表} [站点名]"
        echo "  启用  <站点名>  - 启用站点"
        echo "  停用  <站点名>  - 停用站点"
        echo "  暂停  <站点名>  - 暂停站点"
        echo "  恢复  <站点名>  - 恢复站点"
        echo "  列表           - 列出所有站点"
        ;;
esac
```

## 最佳实践

### 1. 创建新站点步骤

1. **复制模板**：
   ```bash
   cp /etc/nginx/可用站点/示例站点-反向代理.conf /etc/nginx/可用站点/新站点名.conf
   ```

2. **修改配置**：
   - 修改 `server_name`
   - 修改 `root` 路径
   - 修改 SSL 证书路径
   - 根据需求引入不同的配置片段

3. **启用站点**：
   ```bash
   ln -s /etc/nginx/可用站点/新站点名.conf /etc/nginx/运行站点/
   nginx -t && nginx -s reload
   ```

### 2. 日志管理规范

**多站点独立日志架构**：
```
日志/
├── 访问日志/          # 各站点访问日志（按server_name自动分离）
│   ├── example.com.access.log
│   └── api.example.com.access.log
├── 错误日志/          # 各站点错误日志
│   ├── example.com.error.log
│   └── api.example.com.error.log
└── 审计日志/          # 敏感操作审计日志
    └── admin.example.com.audit.log
```

**日志配置选择**：
```nginx
# 标准日志（推荐）
include /etc/nginx/配置片段/站点日志.conf;

# 详细日志（调试时使用）
include /etc/nginx/配置片段/站点详细日志.conf;

# JSON格式（用于ELK等分析系统）
include /etc/nginx/配置片段/站点JSON日志.conf;

# 禁用访问日志（静态资源站点）
include /etc/nginx/配置片段/禁用日志.conf;
```

**日志轮转配置**（/etc/logrotate.d/nginx）：
```bash
/etc/nginx/日志/*/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
```

### 3. 配置管理规范

- **命名规范**：使用域名或功能命名，如 `www.example.com`、`api-gateway`
- **版本控制**：将 `可用站点` 和 `配置片段` 纳入 Git 管理
- **备份策略**：定期备份配置目录
- **测试环境**：先在测试环境验证配置再应用到生产

### 3. PHP 多版本管理

```bash
# 查看已安装的 PHP 版本
ls /var/run/php/

# 不同站点使用不同 PHP 版本
# 站点A：include /etc/nginx/配置片段/PHP7.4支持.conf;
# 站点B：include /etc/nginx/配置片段/PHP8.1支持.conf;
```

**重要**：PHP配置片段不再包含 `禁止访问.conf` 的内容，请确保同时引入！

### 4. SSL 证书管理

```bash
# 使用 Certbot 自动获取 Let's Encrypt 证书
certbot --nginx -d example.com -d www.example.com

# 证书自动续期测试
certbot renew --dry-run
```

SSL 配置说明：
- `SSL证书.conf`：仅包含证书路径（需要取消注释并修改路径）
- `SSL通用配置.conf`：包含协议、算法等安全设置
- 两者都需要引入，或直接在站点配置中设置证书路径

### 5. 性能优化

```nginx
# 开启文件缓存
open_file_cache max=1000 inactive=20s;
open_file_cache_valid 30s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

# 客户端缓存
location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg)$ {
    expires 6M;
    access_log off;
}
```

## 故障排查

### 常见问题

1. **配置测试失败**
   ```bash
   nginx -t
   # 查看具体错误行号
   ```

2. **端口被占用**
   ```bash
   netstat -tlnp | grep :80
   ss -tlnp | grep :443
   ```

3. **权限问题**
   ```bash
   # 检查目录权限
   ls -la /var/www/
   # 检查 Nginx 用户
   ps aux | grep nginx
   ```

4. **502 Bad Gateway（PHP）**
   - 检查 PHP-FPM 是否运行：`systemctl status php8.1-fpm`
   - 检查 socket 文件是否存在：`ls /var/run/php/`
   - 检查权限：PHP-FPM 用户是否能访问站点文件

5. **404 Not Found**
   - 检查 `root` 路径是否正确
   - 检查文件是否存在
   - 检查 `try_files` 配置

## 参考资源

- [Nginx 官方文档](https://nginx.org/en/docs/)
- [Nginx 配置生成器](https://www.digitalocean.com/community/tools/nginx)
- [SSL 配置测试](https://www.ssllabs.com/ssltest/)
- [Mozilla SSL 配置指南](https://ssl-config.mozilla.org/)
- [PHP-FPM 文档](https://www.php.net/manual/zh/install.fpm.php)

---

**最后更新**：2026-03-25
