#!/bin/sh
set -e

DEFAULT_DIR="/opt/cloudwaf-default"

# 1. Initialize /usr/local/openresty/nginx/conf if empty
mkdir -p /usr/local/openresty/nginx/conf /usr/local/openresty/nginx/logs /www/wwwlogs
if [ ! -s /usr/local/openresty/nginx/conf/nginx.conf ]; then
    cp -rf "$DEFAULT_DIR/nginx/conf/"* /usr/local/openresty/nginx/conf/
fi

# 2. Initialize or incrementally update /etc/nginx (conf.d)
mkdir -p /etc/nginx/vhost \
         /etc/nginx/user \
         /etc/nginx/pass \
         /etc/nginx/other \
         /etc/nginx/cert \
         /etc/nginx/stream \
         /etc/nginx/backup \
         /etc/nginx/zip \
         /etc/nginx/waf/logs \
         /etc/nginx/waf/data

if [ ! -s /etc/nginx/waf/access.lua ]; then
    cp -rf "$DEFAULT_DIR/nginx/conf.d/"* /etc/nginx/
else
    # Incremental update on container upgrade: preserve user sites, config, and custom rules
    cp -rn "$DEFAULT_DIR/nginx/conf.d/waf/rule/"* /etc/nginx/waf/rule/ 2>/dev/null || true
    cp -rn "$DEFAULT_DIR/nginx/conf.d/waf/html/"* /etc/nginx/waf/html/ 2>/dev/null || true
    for dict_file in args.json pay.json password.json username_top.json; do
        if [ -f "$DEFAULT_DIR/nginx/conf.d/waf/rule/$dict_file" ]; then
            cp -f "$DEFAULT_DIR/nginx/conf.d/waf/rule/$dict_file" "/etc/nginx/waf/rule/$dict_file"
        fi
    done
    for item in "$DEFAULT_DIR/nginx/conf.d/waf/"*; do
        base_name=$(basename "$item")
        case "$base_name" in
            config|rule|html|logs|mysql_default.pl)
                ;;
            *)
                cp -rf "$item" /etc/nginx/waf/
                ;;
        esac
    done
fi

# 3. Ensure 0.default.conf has internal loopback bridge on 10251 -> 127.0.0.1:80
if [ ! -s /etc/nginx/vhost/0.default.conf ] || ! grep -q "listen 10251" /etc/nginx/vhost/0.default.conf 2>/dev/null; then
    cp -f "$DEFAULT_DIR/nginx/conf.d/vhost/0.default.conf" /etc/nginx/vhost/0.default.conf
fi
if [ ! -s /etc/nginx/vhost/0.0default.conf ]; then
    cp -f "$DEFAULT_DIR/nginx/conf.d/vhost/0.0default.conf" /etc/nginx/vhost/0.0default.conf
fi

# 4. Ensure siteid.json and oauth.inc template exist
if [ ! -s /etc/nginx/other/siteid.json ]; then
    echo "{}" > /etc/nginx/other/siteid.json
fi
if [ ! -s /etc/nginx/other/oauth.inc ] && [ -f "$DEFAULT_DIR/nginx/conf.d/other/oauth.inc" ]; then
    cp -f "$DEFAULT_DIR/nginx/conf.d/other/oauth.inc" /etc/nginx/other/oauth.inc
fi

# 5. Initialize /www/wwwroot if empty
mkdir -p /www/wwwroot
if [ ! -s /www/wwwroot/nginx/fullchain.pem ]; then
    cp -rf "$DEFAULT_DIR/wwwroot/"* /www/wwwroot/
fi

exec /usr/bin/openresty -g "daemon off;"
