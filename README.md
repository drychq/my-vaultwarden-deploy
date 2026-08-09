# Vaultwarden 部署与运维工具(Debian 12/13)

单文件管理工具 `vaultwardenctl`,架构:Docker Compose + Vaultwarden + Caddy 自动 HTTPS。Vaultwarden 不直接发布宿主机端口,只由 Caddy 对外提供 TCP 80/443 与 UDP 443(HTTP/3)。

## 设计原则

本版本由早期「一个功能一个脚本」的方案重构而来:

- **单一配置来源**:全部部署参数只存于 `/opt/vaultwarden/.env`(域名只存 `VW_HOST` 一处,完整 URL 由它派生);`compose.yaml` 与 `Caddyfile` 只引用变量,不写死任何值。
- **统一入口**:所有运维动作都是 `vaultwardenctl` 的子命令,不再按功能散落成多个互相耦合的脚本。
- **统一变更流水线**:每次配置修改都走同一条路径——备份 → 修改 → 校验 → 重建 → 健康检查 → 失败自动回滚。
- **可扩展**:未来新增可变配置项(SMTP、`ADMIN_TOKEN` 等)只需在脚本顶部的配置注册表加一行,自动获得同一条变更流水线。

## 0. 部署前准备

1. 给域名添加 A 记录,例如 `vault.example.com -> 服务器 IPv4`。密码管理器域名建议直接 DNS 解析,不经过不必要的 CDN 代理。
2. 在 VPS 云防火墙和系统防火墙中放行:当前 SSH 端口(先确认,勿误删)、TCP 80、TCP 443、UDP 443(仅 HTTP/3,可不开)。

## 1. 首次安装

```bash
scp vaultwardenctl 用户名@服务器IP:~/
ssh 用户名@服务器IP
chmod +x vaultwardenctl
sudo ./vaultwardenctl install vault.example.com admin@example.com
```

安装会:装好 Docker 官方仓库版 Engine 与 Compose 插件;创建 `/opt/vaultwarden`;启动 Vaultwarden 和 Caddy;把自身安装到 `/usr/local/sbin/vaultwardenctl`;启用每日本地备份定时器。

首次部署默认开启网页端和注册,仅用于创建第一个账户。打开 `https://vault.example.com` 创建账户后**立即执行**:

```bash
sudo vaultwardenctl config set signups off
```

## 2. 日常配置

```bash
sudo vaultwardenctl config show                    # 查看当前配置
sudo vaultwardenctl config set signups off         # 关闭注册
sudo vaultwardenctl config set web off signups off # 关闭网页端并禁止注册(可一次改多项)
sudo vaultwardenctl config set email new@example.com
```

可用键:`domain`(访问域名)、`email`(ACME 证书邮箱)、`web`(网页端 on/off)、`signups`(注册 on/off)。

注意:「关闭网页端」不等于「关闭注册」,二者是独立参数。长期公开部署务必保持 `signups off`。关闭网页端后,桌面端、移动端和浏览器扩展仍可通过 API 正常同步。

### 更换域名

先给新域名配好 DNS 并等待生效,然后:

```bash
sudo vaultwardenctl config set domain vault-new.example.com
```

脚本会:检查新域名解析(并尽力比对本机地址)→ 在线备份 → 修改 `.env` → 校验 → 重建 Vaultwarden 与 Caddy → 等待新证书签发与 `/alive` 通过;任何一步失败自动回滚到旧域名。

切换成功后:所有 Bitwarden 客户端需把服务器地址改为新域名(部分客户端要先注销再登录);旧域名 DNS 建议保留一两天再删除。

## 3. 一键更新

```bash
sudo vaultwardenctl update
```

流程:一致性冷备份 → 拉取 Vaultwarden/Caddy 新镜像 → 重建容器 → 检测 `/alive`;失败自动回滚到更新前镜像。不会自动删除旧镜像,以便手动回滚。不要用 Watchtower 对密码管理器做无人值守自动更新。

## 4. 备份与恢复

```bash
sudo vaultwardenctl backup --online   # SQLite 在线备份,基本无停机(默认;每日定时器也用此模式)
sudo vaultwardenctl backup --cold     # 短暂停止服务后完整复制,适合更新/迁移前
sudo vaultwardenctl restore /opt/vaultwarden/backups/vaultwarden-backup-时间-cold.tar.gz
```

备份位于 `/opt/vaultwarden/backups`,默认保留 14 天;每日约 03:30 由 systemd 定时器执行(`systemctl list-timers vaultwarden-backup.timer`)。恢复只替换 `vw-data` 数据,不覆盖域名与 Compose/Caddy 配置,且恢复前会再做一次安全冷备份、要求输入 `RESTORE` 确认。

同机备份不能抵御磁盘损坏或账号被入侵,务必另用 restic/rclone 等把备份加密复制到异地,并定期演练恢复。

## 5. 状态与日志

```bash
sudo vaultwardenctl status            # 容器/配置/HTTPS/证书/备份定时器/最近日志总览
sudo vaultwardenctl logs -f           # 跟随日志
sudo vaultwardenctl logs --tail 200 caddy
```

## 6. 常用原生命令

`.env` 会被 Docker Compose 自动加载,所以在部署目录里直接用原生命令也可以:

```bash
cd /opt/vaultwarden
sudo docker compose ps
sudo docker compose restart
sudo docker compose down && sudo docker compose up -d
```

配置文件:`/opt/vaultwarden/.env`(唯一配置来源)、`compose.yaml`、`Caddyfile`;持久化数据:`/opt/vaultwarden/vw-data`。这些路径默认仅 root 可访问。

## 7. 部署后安全清单

1. `sudo vaultwardenctl config set signups off`;
2. 在账户安全设置中启用 TOTP 两步验证,恢复代码保存到 Vaultwarden 之外;
3. 在桌面端、浏览器扩展和手机端测试登录与同步;
4. 创建并下载一次个人加密导出,作为客户端层面的额外备份;
5. 把服务器备份复制到异地;
6. 全部确认后,再决定是否 `config set web off`。

当前方案未配置 SMTP 与 `/admin` 管理后台(未设 `ADMIN_TOKEN` 时后台不会启用);单用户部署可直接使用,后续需要邮件通知时在配置注册表中扩展即可。
