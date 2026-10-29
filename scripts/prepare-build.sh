#!/bin/bash
set -e

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    ARCH_SUFFIX="-aarch64"
elif [ "$ARCH" = "x86_64" ]; then
    ARCH_SUFFIX=""
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

MIRROR_FILE="btwaf_mysql_openresty-latest${ARCH_SUFFIX}.tar.gz"
CLOUDWAF_FILE="cloudwaf-latest${ARCH_SUFFIX}.tar.gz"
BASE_URL="https://download.bt.cn/cloudwaf/package"

rm -rf build-tmp
mkdir -p build-tmp/raw build-tmp/mysql build-tmp/nginx-default build-tmp/admin

echo "=== 1. Downloading official packages ($ARCH) ==="
curl -sSLo "build-tmp/$MIRROR_FILE" "$BASE_URL/$MIRROR_FILE"
curl -sSLo "build-tmp/$CLOUDWAF_FILE" "$BASE_URL/$CLOUDWAF_FILE"

echo "=== 2. Loading base Docker images (btwaf-openresty & btwaf-mysql) ==="
tar -xzf "build-tmp/$MIRROR_FILE" -C build-tmp
docker load -i "build-tmp/btwaf-openresty:latest.tar"
docker load -i "build-tmp/btwaf-mysql:latest.tar"
rm -f "build-tmp/$MIRROR_FILE" "build-tmp/btwaf-openresty:latest.tar" "build-tmp/btwaf-mysql:latest.tar"

echo "=== 3. Extracting CloudWaf package ==="
tar -xzf "build-tmp/$CLOUDWAF_FILE" -C build-tmp/raw
rm -f "build-tmp/$CLOUDWAF_FILE"

# 4. Prepare MySQL build context
python3 -c '
raw = open("build-tmp/raw/mysql/conf/conf.d/my.cnf", "rb").read().decode("utf-8", errors="ignore")
clean_lines = [line for line in raw.splitlines() if not line.strip().startswith("#")]
open("build-tmp/mysql/my.cnf", "w", encoding="utf-8").write("\n".join(clean_lines) + "\n")
'

{
    echo "CREATE DATABASE IF NOT EXISTS btwaf DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
    echo "USE btwaf;"
    cat build-tmp/raw/nginx/conf.d/waf/inc/01_request_total.sql
} > build-tmp/mysql/01_request_total.sql

{
    echo "USE btwaf;"
    cat build-tmp/raw/nginx/conf.d/waf/inc/02_btwaf_black.sql
} > build-tmp/mysql/02_btwaf_black.sql

# 5. Prepare Nginx default template context
cp -rf build-tmp/raw/nginx build-tmp/nginx-default/nginx
cp -rf build-tmp/raw/wwwroot build-tmp/nginx-default/wwwroot
mkdir -p build-tmp/nginx-default/nginx/conf.d/{vhost,user,pass,other,cert,stream,backup,zip}
mkdir -p build-tmp/nginx-default/nginx/conf.d/waf/{logs,data}

python3 -c '
p = "build-tmp/nginx-default/nginx/conf/nginx.conf"
c = open(p, "r", encoding="utf-8").read()
inject = """    resolver 127.0.0.11 valid=10s ipv6=off;
    proxy_http_version 1.1;
    map $http_upgrade $connection_upgrade {
        default upgrade;
        \x27\x27      \x27\x27;
    }
"""
if "resolver 127.0.0.11" not in c:
    c = c.replace("http {\n", "http {\n" + inject, 1)
open(p, "w", encoding="utf-8").write(c)
'

cat << 'EOF' >> build-tmp/nginx-default/nginx/conf.d/vhost/0.default.conf

server {
    listen 10251;
    access_log off;
    error_log /dev/null;
    rewrite_by_lua_block { return }
    access_by_lua_block { return }
    log_by_lua_block { return }
    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host 127.0.0.251;
    }
}
EOF

echo "{}" > build-tmp/nginx-default/nginx/conf.d/other/siteid.json

cat << 'EOF' > build-tmp/nginx-default/nginx/conf.d/other/oauth.inc
# Optional OAuth2 / OIDC Pre-Authentication (requires cloudwaf_oauth2 service)
set $oauth_proto $scheme;
if ($http_x_forwarded_proto) {
    set $oauth_proto $http_x_forwarded_proto;
}

auth_request /oauth2/auth;
error_page 401 = @oauth2_signin;

location = /oauth2/auth {
    internal;
    auth_request off;
    rewrite_by_lua_block { return }
    access_by_lua_block { return }
    log_by_lua_block { return }
    access_log off;
    set $oauth_upstream "http://cloudwaf_oauth2:4180";
    proxy_pass $oauth_upstream;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $oauth_proto;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

location /oauth2/ {
    auth_request off;
    rewrite_by_lua_block { return }
    access_by_lua_block { return }
    set $oauth_upstream "http://cloudwaf_oauth2:4180";
    proxy_pass $oauth_upstream;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $oauth_proto;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Auth-Request-Redirect $request_uri;
}

location @oauth2_signin {
    internal;
    auth_request off;
    rewrite_by_lua_block { return }
    access_by_lua_block { return }
    return 302 $oauth_proto://$http_host/oauth2/start?rd=$request_uri;
}
EOF

# 6. Prepare Admin context
cp -rf build-tmp/raw/console build-tmp/admin/console
cp -rf build-tmp/raw/wwwroot build-tmp/admin/wwwroot

WAF_VER=$(cat build-tmp/raw/console/.ver 2>/dev/null | tr -d '\r\n' || echo "latest")
echo "$WAF_VER" > build-tmp/VERSION
rm -rf build-tmp/raw
echo "=== Build context prepared successfully (CloudWaf version: $WAF_VER) ==="
