#!/bin/bash

set -e

echo "Testing nginx configuration..."
if ! nginx -t; then
    echo "Error: nginx configuration test failed"
    exit 1
fi

echo "Reloading nginx..."
if nginx -s reload; then
    echo "nginx reloaded successfully"
else
    echo "Error: failed to reload nginx, trying restart..."
    systemctl restart nginx || service nginx restart || /etc/init.d/nginx restart
fi
