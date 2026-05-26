# unpub 部署手册（Linux）

## 交付物

- `unpub-1.0.1-linux.tar.gz` — Docker 镜像（x86_64）

## 部署

```bash
# 1. 加载镜像
docker load < unpub-1.0.1-linux.tar.gz

# 2. 创建数据目录并启动
mkdir -p /data/unpub
docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:1.0.1-linux

# 3. 验证
curl http://localhost:4000/healthz   # 返回 "ok"
```
