# Vaultwarden 分阶段部署脚本（Debian 12/13）

架构：Docker Compose + Vaultwarden + Caddy 自动 HTTPS。Vaultwarden 不直接发布宿主机端口，只由 Caddy 对外提供 TCP 80/443 与 UDP 443。

## 0. 执行前

先给域名添加 A 记录，例如 `vault.example.com -> 服务器 IPv4`。建议密码管理器域名直接 DNS 解析，不经过不必要的 CDN 代理。

在 VPS 提供商防火墙和系统防火墙中允许：

- 当前 SSH 端口（先确认，不能误删）
- TCP 80
- TCP 443
- UDP 443（仅用于 HTTP/3，可不开放）

## 1. 上传并安装

```bash
unzip vaultwarden-deploy.zip
cd vaultwarden-deploy
chmod +x 01-install-vaultwarden.sh vaultwarden-*
sudo ./01-install-vaultwarden.sh vault.example.com admin@example.com
```

安装脚本会：

- 安装 Docker Engine 官方仓库版本与 Compose 插件；
- 创建 `/opt/vaultwarden`；
- 启动 Vaultwarden 和 Caddy；
- 安装管理命令到 `/usr/local/sbin`；
- 启用每日本地在线备份定时器。

## 2. 创建账户后立即关闭注册

首次部署默认开启网页端和注册，仅用于创建第一个账户。打开：

```text
https://vault.example.com
```

创建账户后执行：

```bash
sudo vaultwarden-config --web on --signups off
```

不要把“关闭网页端”和“关闭注册”混为一件事。关闭网页端只是不提供内置网页 UI；是否允许新账户创建由 `SIGNUPS_ALLOWED` 单独控制。

## 3. 关闭或重新开启网页端

保持网页端、禁止注册：

```bash
sudo vaultwarden-config --web on --signups off
```

关闭网页端、禁止注册：

```bash
sudo vaultwarden-config --web off --signups off
```

临时重新开放注册：

```bash
sudo vaultwarden-config --signups on
```

查看当前值：

```bash
sudo vaultwarden-config --show
```

无参数执行会进入交互模式：

```bash
sudo vaultwarden-config
```

## 4. 一键更新

```bash
sudo vaultwarden-update
```

更新脚本会先做一致性冷备份，再拉取 Vaultwarden 和 Caddy 新镜像、重建容器并检测 `/alive`。健康检查失败时会尝试恢复更新前镜像。它不会自动删除旧镜像。

## 5. 备份、状态与恢复

在线备份：

```bash
sudo vaultwarden-backup --online
```

一致性冷备份：

```bash
sudo vaultwarden-backup --cold
```

查看状态、证书和最近日志：

```bash
sudo vaultwarden-status
```

恢复：

```bash
sudo vaultwarden-restore /opt/vaultwarden/backups/vaultwarden-backup-时间-cold.tar.gz
```

本地备份位于 `/opt/vaultwarden/backups`。同机备份不能抵御 VPS 磁盘损坏、供应商故障或账号被入侵，应另外使用 restic、rclone 等工具将备份加密复制到异地，并定期验证恢复。

## 6. 常用原生命令

```bash
cd /opt/vaultwarden
sudo docker compose ps
sudo docker compose logs -f --tail=100
sudo docker compose restart
sudo docker compose down
sudo docker compose up -d
```

配置文件：

```text
/opt/vaultwarden/.env
/opt/vaultwarden/compose.yaml
/opt/vaultwarden/Caddyfile
```

持久化数据：

```text
/opt/vaultwarden/vw-data
```
