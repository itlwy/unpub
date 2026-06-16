# unpub 部署手册（Linux）

## 交付物

- `unpub-2.0.1-linux.tar.gz` — Docker 镜像（x86_64）
- 镜像标签：`unpub:2.0.1-linux`

## 构建交付包

```bash
# 在仓库根目录执行。ARM64 Mac 也可以产出 x86_64 Linux 镜像。
docker buildx build --platform linux/amd64 --load -t unpub:2.0.1-linux .
docker save unpub:2.0.1-linux | gzip > unpub-2.0.1-linux.tar.gz

# 验证镜像架构
docker image inspect unpub:2.0.1-linux --format '{{.Architecture}}'
```

## 部署

```bash
# 1. 加载镜像
docker load < unpub-2.0.1-linux.tar.gz

# 2. 创建数据目录并启动
mkdir -p /data/unpub
docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:2.0.1-linux

# 3. 验证
curl http://localhost:4000/healthz   # 返回 "ok"
```

## 升级

```bash
# 1. 停止旧容器
docker stop unpub || true
docker rm unpub || true

# 2. 加载新镜像
docker load < unpub-2.0.1-linux.tar.gz

# 3. 使用原数据目录启动
docker run -d --name unpub \
  -p 4000:4000 \
  -v /data/unpub/datadb:/data/db \
  --restart always \
  unpub:2.0.1-linux

# 4. 验证
curl http://localhost:4000/healthz
docker inspect unpub --format '{{.State.Health.Status}}'
```

## beta 版本清理

正式版发布后，可以清理同 base version 的 beta 包。示例：正式发布 `1.0.1` 后，清理 `1.0.1-beta.1`、`1.0.1-beta.2`。

```bash
# dry run，确认会清理哪些版本
curl -X DELETE \
  'http://localhost:4000/api/packages/<包名>/versions/prereleases?base=1.0.1&tag=beta&dryRun=true'

# 执行清理
curl -X DELETE \
  'http://localhost:4000/api/packages/<包名>/versions/prereleases?base=1.0.1&tag=beta'

# 验证 beta 已删除，正式版仍可下载
curl -i http://localhost:4000/api/packages/<包名>/versions/1.0.1-beta.1
curl -i http://localhost:4000/packages/<包名>/versions/1.0.1-beta.1.tar.gz
curl -I http://localhost:4000/packages/<包名>/versions/1.0.1.tar.gz
```

清理接口是幂等的，重复执行不会报错；如果已无可清理版本，`removed` 会返回空列表。
