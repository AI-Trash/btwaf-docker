# btwaf-docker (堡塔云 WAF 纯容器版)

基于官方 [堡塔云 WAF (aaPanel/aaWAF)](https://github.com/aaPanel/aaWAF) 构建的**零宿主机污染、免特权模式、免 `--net=host`、免挂载 `docker.sock`** 的纯 Docker Compose 部署方案。

GitHub Actions 每日定时拉取宝塔官方最新构建包并自动推送镜像至 GHCR（`ghcr.io/ai-trash/btwaf-docker/*`），支持真正的一键 `docker compose up -d` 开箱即用与平滑升级。

---

## 核心特性

1. **零宿主机污染**：不在宿主机安装任何二进制服务、不改宿主机 `apt`/`yum`、不写 `systemd`、不修改宿主机防火墙。
2. **最小权限与网络隔离**：
   - 无需 `--net=host`，无需 `--privileged` 特权容器，无需挂载宿主机 `/var/run/docker.sock`。
   - 仅通过 `pid: "service:cloudwaf_nginx"` 实现控制台对 OpenResty 的 `SIGHUP` 热重载信号发送。
3. **打通全部底层硬编码限制**：
   - 内置 `127.0.0.251:80` $\rightarrow$ `cloudwaf_nginx:10251` $\rightarrow$ `127.0.0.1:80` 探活与状态桥接，完美解决独立网络命名空间下控制台每 60 秒误判 Nginx 宕机并重启 Worker 导致的断连问题，实时 QPS 与流量报表完整显示。
   - 内置轻量级 `ipfilter.py` 接管 `/etc/nginx/ip_filter.sock` 套接字，无需宿主机内核 `ipset`/`iptables` 权限。
   - 内置 `/usr/local/bin/docker` 垫片与 `vhost/site_json` 影子配置同步，后台添加站点、修改规则、自定义配置 100% 正常可用。
   - 全局注入 `proxy_http_version 1.1` 与动态 WebSocket `$connection_upgrade` 映射，长连接与 WebSocket 稳定不断连。
4. **内置 OAuth2 / OIDC 前置认证模板**：预置 `/etc/nginx/other/oauth.inc`，配合 `oauth2-proxy` 即可在后台【自定义配置】中通过一行 `include /etc/nginx/other/oauth.inc;` 开启类雷池的统一身份认证网关。

---

## 快速开始（一键启动）

在任意空目录下创建 `docker-compose.yml`：

```yaml
services:
  cloudwaf_nginx:
    image: ghcr.io/ai-trash/btwaf-docker/nginx:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./data/nginx/conf:/usr/local/openresty/nginx/conf
      - ./data/nginx/conf.d:/etc/nginx
      - ./data/nginx/logs:/usr/local/openresty/nginx/logs
      - ./data/nginx/logs:/www/wwwlogs
      - ./data/wwwroot:/www/wwwroot
      - /etc/localtime:/etc/localtime:ro
    ulimits:
      nofile:
        soft: 65535
        hard: 65535

  cloudwaf_mysql:
    image: ghcr.io/ai-trash/btwaf-docker/mysql:latest
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-WafDbPass2026}
    volumes:
      - ./data/mysql:/var/lib/mysql
      - /etc/localtime:/etc/localtime:ro

  cloudwaf_admin:
    image: ghcr.io/ai-trash/btwaf-docker/admin:latest
    restart: unless-stopped
    pid: "service:cloudwaf_nginx"
    ports:
      - "8379:8379"
    environment:
      - WAF_PORT=8379
      - DB_HOST=cloudwaf_mysql
      - DB_PORT=3306
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-WafDbPass2026}
      - ADMIN_USER=${ADMIN_USER:-admin}
      - ADMIN_PASS=${ADMIN_PASS:-WafAdmin@2026}
      - ADMIN_PATH=${ADMIN_PATH:-wafadmin}
    volumes:
      - ./data/console/data:/www/cloud_waf/console/data
      - ./data/console/ssl:/www/cloud_waf/console/ssl
      - ./data/nginx/conf.d:/www/cloud_waf/nginx/conf.d
      - ./data/nginx/logs:/www/cloud_waf/nginx/logs
      - ./data/wwwroot:/www/wwwroot
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - cloudwaf_nginx
      - cloudwaf_mysql
```

启动服务：

```bash
docker compose up -d
```

启动后直接访问控制台：
- **访问地址**：`https://<服务器IP>:8379/wafadmin`
- **默认账号**：`admin`（可通过 `ADMIN_USER` 环境变量修改）
- **默认密码**：`WafAdmin@2026`（可通过 `ADMIN_PASS` 环境变量修改）

---

## 平滑升级

本仓库通过 GitHub Actions 每天自动同步官方最新包并构建推送镜像。升级时只需执行：

```bash
docker compose pull
docker compose up -d
```

容器启动时会自动增量更新 OpenResty Lua 核心脚本、语义分析动态库（`.so`）与内置特征字典，**自动保留**现有的全部站点配置（`site.json` / `domains.json` / `vhost`）与自定义黑白名单规则。

---

## 可选：接入 OAuth2 / OIDC 前置登录（如 Keycloak）

在 `docker-compose.yml` 中增加 `cloudwaf_oauth2` 服务：

```yaml
  cloudwaf_oauth2:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
    restart: unless-stopped
    environment:
      - OAUTH2_PROXY_PROVIDER=oidc
      - OAUTH2_PROXY_OIDC_ISSUER_URL=https://sso.example.com/realms/myrealm
      - OAUTH2_PROXY_CLIENT_ID=waf-client
      - OAUTH2_PROXY_CLIENT_SECRET=your-client-secret
      - OAUTH2_PROXY_COOKIE_SECRET=0123456789abcdef0123456789abcdef
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_UPSTREAMS=static://202
      - OAUTH2_PROXY_REVERSE_PROXY=true
      - OAUTH2_PROXY_EMAIL_DOMAINS=*
      - OAUTH2_PROXY_OIDC_EMAIL_CLAIM=preferred_username
      - OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL=true
      - OAUTH2_PROXY_COOKIE_DOMAINS=.example.com
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.example.com
      - OAUTH2_PROXY_COOKIE_SECURE=false
      - OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true
```

然后在宝塔云 WAF 网页后台点开需要开启前置登录的站点 $\rightarrow$ **【配置】 $\rightarrow$ 【自定义配置】**，填入一行即可开启：

```nginx
include /etc/nginx/other/oauth.inc;
```

---

## 本地自行构建镜像

如果需要本地自行从宝塔官方源拉包并构建镜像：

```bash
chmod +x scripts/*.sh scripts/*.init scripts/*.py
./scripts/prepare-build.sh
docker build -f Dockerfile.mysql -t ghcr.io/ai-trash/btwaf-docker/mysql:latest .
docker build -f Dockerfile.nginx -t ghcr.io/ai-trash/btwaf-docker/nginx:latest .
docker build -f Dockerfile.admin -t ghcr.io/ai-trash/btwaf-docker/admin:latest .
```

## License

遵循上游项目 [aaPanel/aaWAF](https://github.com/aaPanel/aaWAF) 的 **GNU Affero General Public License v3.0 (AGPL-3.0)** 协议。
