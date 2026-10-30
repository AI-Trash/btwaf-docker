#!/bin/bash
set -e

DB_HOST="${DB_HOST:-cloudwaf_mysql}"
DB_PORT="${DB_PORT:-3306}"
DB_PASS="${MYSQL_ROOT_PASSWORD:-WafDbPass2026}"

# 1. Wait for MySQL and shared /www/cloud_waf/nginx/conf.d directory
echo "Waiting for MySQL at ${DB_HOST}:${DB_PORT}..."
while ! python3 -c "import socket; s = socket.socket(); s.settimeout(2); s.connect(('$DB_HOST', int('$DB_PORT'))); s.close()" 2>/dev/null; do
    sleep 1
done

while [ ! -f /www/cloud_waf/nginx/conf.d/waf/config/config.json ]; do
    sleep 1
done

# 2. Configure MySQL credentials for both Console and OpenResty Lua engine
mkdir -p /www/cloud_waf/console/config
if [ -s /www/cloud_waf/nginx/conf.d/waf/mysql_default.pl ]; then
    DB_PASS=$(tr -d '\r\n' < /www/cloud_waf/nginx/conf.d/waf/mysql_default.pl)
else
    echo -n "$DB_PASS" > /www/cloud_waf/nginx/conf.d/waf/mysql_default.pl
fi

cat << EOF > /www/cloud_waf/console/config/mysql.json
{
    "default": {
        "Host": "$DB_HOST",
        "Port": $DB_PORT,
        "UserName": "root",
        "Password": "$DB_PASS",
        "DbName": "btwaf",
        "PreFix": "",
        "UnixSocket": ""
    }
}
EOF

python3 -c '
import json, sys
p, host, port, pw = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
d.setdefault("database", {})
d["database"]["host"] = host
d["database"]["port"] = port
d["database"]["user"] = "root"
d["database"]["password"] = pw
d["database"]["database"] = "btwaf"
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=4, ensure_ascii=False)
' /www/cloud_waf/nginx/conf.d/waf/config/config.json "$DB_HOST" "$DB_PORT" "$DB_PASS"

# 3. Sync persistent rule configs into container shadow directory vhost/site_json
mkdir -p /www/cloud_waf/vhost/site_json \
         /www/cloud_waf/vhost/history_backups/config \
         /www/cloud_waf/nginx/conf.d/other \
         /www/cloud_waf/nginx/conf.d/user \
         /www/cloud_waf/nginx/conf.d/vhost \
         /www/cloud_waf/nginx/conf.d/cert

if [ ! -s /www/cloud_waf/nginx/conf.d/other/siteid.json ]; then
    echo "{}" > /www/cloud_waf/nginx/conf.d/other/siteid.json
fi

for f in site.json domains.json config.json; do
    if [ -s "/www/cloud_waf/nginx/conf.d/waf/config/$f" ]; then
        cp -f "/www/cloud_waf/nginx/conf.d/waf/config/$f" "/www/cloud_waf/vhost/site_json/$f"
        cp -f "/www/cloud_waf/nginx/conf.d/waf/config/$f" "/www/cloud_waf/vhost/history_backups/config/$f"
    fi
done

# 4. Start ipfilter & 127.0.0.251:80 loopback bridge daemon
if ! ps aux | grep -w ipfilter | grep -v grep >/dev/null 2>&1; then
    python3 /www/cloud_waf/console/ipfilter >/dev/null 2>&1 &
fi

# 5. Initialize console SSL certificate and port
mkdir -p /www/cloud_waf/console/ssl /www/cloud_waf/console/data
if [ ! -s /www/cloud_waf/console/ssl/certificate.pem ]; then
    cp -f /www/cloud_waf/wwwroot/nginx/fullchain.pem /www/cloud_waf/console/ssl/certificate.pem 2>/dev/null || true
    cp -f /www/cloud_waf/wwwroot/nginx/privkey.pem /www/cloud_waf/console/ssl/privateKey.pem 2>/dev/null || true
fi

echo "${WAF_PORT:-8379}" > /www/cloud_waf/console/data/.server-port

# 6. Initialize default admin user on first run
cd /www/cloud_waf/console
if [ "$(/www/cloud_waf/console/CloudWaf default_user_created 2>/dev/null)" = "0" ]; then
    /www/cloud_waf/console/CloudWaf create_default_user "${ADMIN_USER:-admin}" "${ADMIN_PASS:-WafAdmin@2026}"
    /www/cloud_waf/console/CloudWaf set_auth_path "${ADMIN_PATH:-wafadmin}"
fi

# 7. Reload Nginx so OpenResty Lua engine picks up the updated MySQL config
/www/cloud_waf/btw.init reload || true

exec /www/cloud_waf/console/CloudWaf
