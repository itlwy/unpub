# unpub 部署手册（Linux）

## 交付物

| 文件 | 说明 |
|------|------|
| `unpub-1.0.1-linux.tar.gz` | Docker 镜像（x86_64） |
| `LINUX_DEPLOY.md` | 本文档 |

## 环境要求

| 条件 | 说明 |
|------|------|
| 操作系统 | Linux（Ubuntu 20.04+ / CentOS 7+ / Debian 11+） |
| Docker | 已安装并开机自启（`systemctl is-enabled docker`） |
| CPU 架构 | x86_64 |
| 端口 | 4000（可改） |
| 磁盘 | >= 5GB 空闲（用于 Docker 镜像 + 包数据） |

---

## 一、部署

### 1.1 加载镜像

```bash
docker load < unpub-1.0.1-linux.tar.gz
```

验证：

```bash
docker images unpub:1.0.1-linux
```

### 1.2 启动服务

```bash
mkdir -p /data/unpub

docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:1.0.1-linux
```

参数说明：

| 参数 | 作用 |
|------|------|
| `-d` | 后台运行 |
| `--name unpub` | 容器名称 |
| `-p 4000:4000` | 端口映射（宿主机:容器），改端口改前面的数字即可 |
| `-v /data/unpub/datadb:/data/db` | 数据持久化到宿主机 `/data/unpub/datadb` |
| `--restart always` | 容器崩溃自动重启，Docker 启动后自动拉起 |

> 容器内同时运行 MongoDB 5.0 和 unpub 服务，无需单独安装数据库。

### 1.3 验证

```bash
# 查看启动日志（看到 "Serving at http://0.0.0.0:4000" 表示成功）
docker logs unpub

# 健康检查
curl http://localhost:4000/healthz
# 返回 "ok" = 正常

# Docker 健康状态
docker inspect unpub --format '{{.State.Health.Status}}'
# 返回 "healthy"
```

### 1.4 开机自启

无需额外配置。`--restart always` 确保 Docker 启动后自动拉起容器，Docker 本身随 systemd 开机启动。

验证：

```bash
# 确认 Docker 开机自启
systemctl is-enabled docker

# 如果不是 enabled，执行：
sudo systemctl enable docker
```

可选：显式用 systemd 管理容器（更规范，但非必需）：

```bash
sudo tee /etc/systemd/system/unpub.service << 'EOF'
[Unit]
Description=Unpub Docker Container
Requires=docker.service
After=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a unpub
ExecStop=/usr/bin/docker stop -t 10 unpub

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now unpub
```

---

## 二、健康监控与自动恢复

### 内置机制（无需外部监控工具）

| 层 | 机制 | 触发条件 | 恢复动作 | 恢复时间 |
|---|------|----------|----------|----------|
| 容器内 | mongod 看门狗 | mongod 进程崩溃 | 5 秒内重启 mongod | < 10s |
| 容器内 | DB 断连重连 | MongoDB 连接不可达 | 下次操作自动 `close()` + `open()` | 即时 |
| Docker | HEALTHCHECK | `/healthz` 连续 3 次异常 | Docker 重启容器 | < 90s |
| Docker | restart policy | 容器进程退出 | Docker 拉起新容器 | < 10s |
| systemd | Docker daemon | Docker 进程退出 | systemd 重启 Docker | < 10s |

### 外部健康探测

外部监控系统（如 Prometheus、Nagios、CI 定时任务）可以直接探测：

```bash
curl -f http://<服务器IP>:4000/healthz
```

- HTTP 200 + 返回 `ok` = 正常
- 其他 = 需要关注

### 手动检查容器内部

```bash
# 容器运行状态
docker ps --filter name=unpub

# 容器内 MongoDB 是否存活
docker exec unpub mongosh --quiet --eval "db.adminCommand('ping')"
# 返回 {"ok":1} = 正常

# 模拟 mongod 崩溃测试自愈（看门狗 5 秒内自动重启）
docker exec unpub pkill -9 mongod
sleep 6
docker exec unpub mongosh --quiet --eval "db.adminCommand('ping')"
# 应返回 {"ok":1}，表示看门狗已重启 mongod
```

---

## 三、日常运维

### 3.1 容器管理

```bash
docker stop unpub      # 停止
docker start unpub     # 启动
docker restart unpub   # 重启
docker logs unpub      # 查看日志
docker logs -f unpub   # 实时跟踪日志
docker logs unpub --tail 200   # 最近 200 行
```

### 3.2 防火墙

确保 4000 端口对内网可访问：

```bash
# firewalld（CentOS/RHEL）
sudo firewall-cmd --add-port=4000/tcp --permanent
sudo firewall-cmd --reload

# ufw（Ubuntu/Debian）
sudo ufw allow 4000/tcp
```

### 3.3 数据备份

```bash
# 备份（容器运行中也可执行）
tar czf unpub-backup-$(date +%Y%m%d).tar.gz /data/unpub/datadb

# 建议加入 crontab 定期备份，例如每天凌晨 3 点
# 0 3 * * * tar czf /backup/unpub-$(date +\%Y\%m\%d).tar.gz /data/unpub/datadb
```

### 3.4 数据恢复

```bash
# 停止容器
docker stop unpub

# 恢复数据（注意会覆盖现有数据）
rm -rf /data/unpub/datadb
tar xzf unpub-backup-20250525.tar.gz -C /

# 重启
docker start unpub
```

---

## 四、版本更新

运维拿到新版本镜像后：

```bash
# 1. 加载新镜像
docker load < unpub-1.0.2-linux.tar.gz

# 2. 替换容器（数据目录不变，已发布包不丢失）
docker stop unpub && docker rm unpub
docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:1.0.2-linux

# 3. 验证
curl http://localhost:4000/healthz
docker logs unpub | tail -5
```

如果用了 systemd service（1.4 节可选步骤），更新后执行 `sudo systemctl restart unpub` 即可。

---

## 五、使用 unpub

### Dart/Flutter 项目发布包

在项目的 `pubspec.yaml` 中设置：

```yaml
name: your_package
publish_to: http://<服务器IP>:4000
```

发布命令：

```bash
dart pub publish --server=http://<服务器IP>:4000
```

无需 Google OAuth token。

### 作为依赖拉取

在 `pubspec.yaml` 中配置 unpub 为源：

```yaml
dependency_overrides:
  your_package:
    hosted:
      name: your_package
      url: http://<服务器IP>:4000
    version: ^1.0.0
```

---

## 六、故障排查

| 现象 | 排查命令 | 常见原因 |
|------|----------|----------|
| 容器无法启动 | `docker logs unpub` | 端口占用、磁盘满 |
| `/healthz` 返回 `unhealthy` | `docker exec unpub mongosh --eval "db.adminCommand('ping')"` | MongoDB 异常，等待 HEALTHCHECK 自愈 |
| 发布包失败 | `curl http://localhost:4000/healthz` | 服务不可达或磁盘满 |
| 客户端 502/连接拒绝 | `docker ps --filter name=unpub` | 容器未运行，检查 `systemctl status docker` |

### 关键日志关键字

```bash
docker logs unpub | grep "mongod died"        # 看门狗检测到 mongod 崩溃
docker logs unpub | grep "Unhandled error"      # 路由异常被中间件捕获
docker logs unpub | grep "shutting down"        # 优雅关闭
docker logs unpub | grep "cannot increment"     # 下载统计写入失败（无影响）
```

---

## 附录：技术栈

| 组件 | 版本 | 说明 |
|------|------|------|
| MongoDB | 5.0 | 内嵌在容器中，数据持久化到 `/data/unpub/datadb` |
| Dart SDK | 2.17.1 | 服务端运行时 |
| unpub | 0.1.0-dev | 基于 shelf 框架 |
| 端口 | 4000 | pub API + Web 管理界面 |

> MongoDB 版本锁定 5.0，不可升级到 6.0+（`mongo_dart` 驱动使用旧版 OP_QUERY 协议，不兼容新版本）。
