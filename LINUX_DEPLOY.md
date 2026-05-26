# unpub 部署手册（Linux）

## 交付物

| 文件 | 说明 |
|------|------|
| `unpub-1.0.1-linux.tar.gz` | Docker 镜像（x86_64） |
| `LINUX_DEPLOY.md` | 本文档 |

## 环境要求

- Linux（x86_64），Docker >= 1.12 已安装并开机自启
- 操作用户在 `docker` 组（避免用 root）

### 一次性准备（如未就绪）

```bash
# 1. 当前用户加入 docker 组
sudo usermod -aG docker $USER
# 退出重新登录生效

# 2. 创建数据目录
sudo mkdir -p /data/unpub
sudo chown $USER:$USER /data/unpub
```

## 部署步骤

### 1. 加载镜像

```bash
docker load < unpub-1.0.1-linux.tar.gz
```

### 2. 启动服务

```bash
mkdir -p /data/unpub

docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:1.0.1-linux
```

### 3. 验证

```bash
# 确认容器运行中
docker ps --filter name=unpub

# 健康检查（返回 "ok" 即正常）
curl http://localhost:4000/healthz
```

### 4. 防火墙

```bash
# firewalld（CentOS/RHEL）
sudo firewall-cmd --add-port=4000/tcp --permanent
sudo firewall-cmd --reload

# ufw（Ubuntu/Debian）
sudo ufw allow 4000/tcp
```
