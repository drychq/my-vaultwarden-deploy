#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/vaultwarden"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法：
  sudo ./01-install-vaultwarden.sh <域名> <ACME邮箱>

示例：
  sudo ./01-install-vaultwarden.sh vault.example.com admin@example.com

前提：
  1. Debian 12/13 新服务器；
  2. 域名 A 记录已指向服务器公网 IPv4；
  3. 云防火墙和系统防火墙已允许 TCP 80/443（可选 UDP 443）；
  4. SSH 端口已经确认可用。
USAGE
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "错误：请使用 sudo 或 root 执行。" >&2
    exit 1
  fi
}

validate_domain() {
  local value=$1
  [[ $value =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_email() {
  local value=$1
  [[ $value =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg jq sqlite3 tar gzip unzip openssl iproute2 util-linux

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker Engine 与 Compose 已存在，跳过安装。"
    systemctl enable --now docker
    return
  fi

  echo "安装 Docker 官方仓库版本……"
  apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc 2>/dev/null || true
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

check_ports() {
  local listeners
  listeners=$(ss -ltnH 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /:443$/ {print}' || true)
  if [[ -n $listeners ]]; then
    echo "错误：80 或 443 端口已被占用：" >&2
    echo "$listeners" >&2
    echo "请先处理端口冲突，再重新执行。" >&2
    exit 1
  fi
}

install_management_scripts() {
  local name
  for name in vaultwarden-config vaultwarden-backup vaultwarden-update vaultwarden-status vaultwarden-restore; do
    if [[ ! -f "$SCRIPT_DIR/$name" ]]; then
      echo "错误：脚本包不完整，缺少 $name。" >&2
      exit 1
    fi
    install -m 0750 "$SCRIPT_DIR/$name" "/usr/local/sbin/$name"
  done
}

install_backup_timer() {
  cat > /etc/systemd/system/vaultwarden-backup.service <<'SERVICE'
[Unit]
Description=Vaultwarden local backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vaultwarden-backup --online --keep 14
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE

  cat > /etc/systemd/system/vaultwarden-backup.timer <<'TIMER'
[Unit]
Description=Daily Vaultwarden local backup

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable --now vaultwarden-backup.timer
}

main() {
  require_root

  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    echo "错误：无法识别操作系统。" >&2
    exit 1
  fi

  if [[ ${ID:-} != "debian" ]]; then
    echo "错误：此脚本只针对 Debian 12/13，当前系统 ID=${ID:-unknown}。" >&2
    exit 1
  fi

  local domain=${1:-}
  local email=${2:-}

  if [[ -z $domain ]]; then
    read -r -p "Vaultwarden 域名（例如 vault.example.com）：" domain
  fi
  if [[ -z $email ]]; then
    read -r -p "用于证书签发通知的邮箱：" email
  fi

  domain=${domain#http://}
  domain=${domain#https://}
  domain=${domain%/}

  if ! validate_domain "$domain"; then
    echo "错误：域名格式无效：$domain" >&2
    exit 1
  fi
  if ! validate_email "$email"; then
    echo "错误：邮箱格式无效：$email" >&2
    exit 1
  fi

  if [[ -e $APP_DIR ]]; then
    echo "错误：$APP_DIR 已存在。为避免覆盖现有数据，安装脚本已停止。" >&2
    exit 1
  fi

  install_docker
  check_ports
  install_management_scripts

  umask 077
  install -d -m 0700 "$APP_DIR" "$APP_DIR/vw-data" "$APP_DIR/caddy-data" \
    "$APP_DIR/caddy-config" "$APP_DIR/backups"

  cat > "$APP_DIR/.env" <<ENV
VW_HOST=${domain}
VW_URL=https://${domain}
ACME_EMAIL=${email}
WEB_VAULT_ENABLED=true
SIGNUPS_ALLOWED=true
ENV
  chmod 0600 "$APP_DIR/.env"

  cat > "$APP_DIR/compose.yaml" <<'COMPOSE'
name: vaultwarden

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "${VW_URL}"
      WEB_VAULT_ENABLED: "${WEB_VAULT_ENABLED}"
      SIGNUPS_ALLOWED: "${SIGNUPS_ALLOWED}"
      INVITATIONS_ALLOWED: "false"
      SHOW_PASSWORD_HINT: "false"
      IP_HEADER: "X-Real-IP"
      LOG_LEVEL: "info"
    volumes:
      - ./vw-data:/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  caddy:
    image: caddy:2
    container_name: vaultwarden-caddy
    restart: unless-stopped
    depends_on:
      - vaultwarden
    environment:
      VW_HOST: "${VW_HOST}"
      ACME_EMAIL: "${ACME_EMAIL}"
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE
  chmod 0600 "$APP_DIR/compose.yaml"

  cat > "$APP_DIR/Caddyfile" <<'CADDY'
{
    email {$ACME_EMAIL}
}

{$VW_HOST} {
    encode zstd gzip

    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "same-origin"
        -Server
    }

    reverse_proxy vaultwarden:80 {
        header_up X-Real-IP {remote_host}
    }
}
CADDY
  chmod 0600 "$APP_DIR/Caddyfile"

  cd "$APP_DIR"
  docker compose config --quiet
  docker compose pull
  docker compose run --rm --no-deps --entrypoint caddy caddy \
    validate --config /etc/caddy/Caddyfile --adapter caddyfile
  docker compose up -d

  install_backup_timer

  echo
  echo "等待 HTTPS 与 Vaultwarden 就绪……"
  local ready=0
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 5 "https://${domain}/alive" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done

  echo
  docker compose ps
  echo
  if [[ $ready -eq 1 ]]; then
    echo "部署完成：https://${domain}"
    echo "现在先打开网页创建唯一账户，然后立即执行："
    echo "  sudo vaultwarden-config --web on --signups off"
  else
    echo "容器已启动，但 HTTPS 尚未通过检测。常见原因是 DNS 未生效、80/443 未放行或端口被上游拦截。"
    echo "检查命令："
    echo "  sudo vaultwarden-status"
    echo "  sudo docker compose -f ${APP_DIR}/compose.yaml --env-file ${APP_DIR}/.env logs --tail=100 caddy vaultwarden"
  fi

  echo
  echo "每日本地备份定时器已启用："
  systemctl list-timers vaultwarden-backup.timer --no-pager || true
  echo "注意：同机备份不能代替异地加密备份。"
}

main "$@"
