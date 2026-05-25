# unpub 私有 Dart Pub 服务器 — 部署与开发说明

## 项目概述

- **unpub**: 字节跳动开源的自建 Dart Pub 服务器，基于 shelf + MongoDB
- **Fork 仓库**: pd4d10/unpub（含 `unpub_web` 前端源码）
- **本地改动**: 跳过 Google OAuth2 鉴权 + Docker 容器化部署 + GFM Markdown 渲染 + 自恢复机制

## 项目结构

```
unpub/
├── unpub/                     ← 服务端 Dart 源码
│   ├── lib/src/
│   │   ├── app.dart           ← 核心路由和 API
│   │   ├── mongo_store.dart   ← MongoDB 元数据存储
│   │   ├── file_store.dart    ← 文件系统包存储
│   │   └── static/            ← Web 前端编译产物（嵌入为 Dart 字符串常量）
│   ├── bin/unpub.dart         ← 入口文件
│   └── pubspec.yaml
├── unpub_web/                 ← Web 前端源码（AngularDart 6，需要 Dart 2.x 编译）
├── unpub_auth/                ← 鉴权插件（可选）
├── unpub_aws/                 ← AWS S3 存储插件（可选）
├── Dockerfile                 ← Docker 镜像定义
├── docker-entrypoint.sh       ← 容器入口脚本（mongod + 看门狗 + unpub）
├── Makefile
└── DEPLOY.md                  ← 本文档
```

## 关键版本约束

| 组件 | 版本要求 | 原因 |
|------|----------|------|
| Dart SDK（编译前端） | **2.17.x** | `unpub_web` 是 AngularDart 6，不兼容 Dart 3.x |
| Dart SDK（仅跑后端） | 2.12.x ~ 2.19.x | `pubspec.yaml` 约束 `<3.0.0`，无法在 Dart 3.x 下运行 |
| MongoDB | **5.0**（不能更高） | `mongo_dart 0.7.x` 使用旧版 OP_QUERY 协议，MongoDB 6.0+ 已移除支持 |
| Docker（Mac 打包机） | colima + docker CLI | 轻量替代 Docker Desktop |

> **注意**: 前端编译产物已预编译嵌入在 `unpub/lib/src/static/` 中。如果你不需要修改 Web 界面，可以跳过前端编译步骤，后端代码也可以用 Docker 内的 Dart 2.17 来编译运行。

---

# 第一部分：本地开发、编译与发布测试

## 1.1 环境准备

### 安装 MongoDB 5.0

本地开发需要 MongoDB 5.0 运行在 `localhost:27017`：

```bash
# 方式一：Homebrew 安装（如果还支持）
brew install mongodb-community@5.0
brew services start mongodb-community@5.0

# 方式二：Docker 运行一个 MongoDB 5.0 容器（推荐，无需安装）
docker run -d --name mongodb-unpub \
  -p 27017:27017 \
  -v $(pwd)/data/datadb:/data/db \
  mongo:5.0

# 验证
mongosh --eval "db.adminCommand('ping')"
```

### Dart SDK（仅跑后端，不编译前端）

后端代码依赖 `sdk: ">=2.12.0 <3.0.0"`，用 **Dart 2.17.x**：

```bash
# 使用 FVM 管理 Dart 版本
fvm install 2.17.1
fvm use 2.17.1

# 或者直接用 Docker 里的 Dart
docker run --rm -v $(pwd):/src -w /src/unpub \
  --entrypoint dart \
  unpub:dev \
  pub get
```

## 1.2 本地启动服务

```bash
cd unpub/unpub

# 安装依赖
dart pub get

# 设置包存储目录
export UNPUB_PACKAGE_DIR=$(pwd)/unpub-packages

# 启动（确保 MongoDB 已在 localhost:27017 运行）
dart run bin/unpub.dart

# 指定端口和数据库
dart run bin/unpub.dart -p 8080 -d mongodb://localhost:27017/dart_pub
```

启动后访问 http://localhost:4000 查看 Web 管理界面。

### 可用命令行参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-h, --host` | `0.0.0.0` | 监听地址 |
| `-p, --port` | `4000` | 监听端口 |
| `-d, --database` | `mongodb://localhost:27017/dart_pub` | MongoDB 连接串 |
| `-o, --proxy-origin` | 空 | 反向代理时设置前端访问地址 |

## 1.3 发布测试包验证

```bash
# 创建一个测试 Dart 包
dart create -t package test_pkg
cd test_pkg

# 在 pubspec.yaml 中设置发布目标
# publish_to: http://localhost:4000

# 发布
dart pub publish --server=http://localhost:4000

# 验证已发布
curl http://localhost:4000/api/packages/test_pkg
```

> **不需要** `ax_publish` 或 Google OAuth token。`dart pub publish --server=<URL>` 对非 pub.dev 的第三方服务器不会触发 Google 鉴权。

### 常用 API 测试

```bash
# 健康检查
curl http://localhost:4000/healthz                          # 返回 "ok"

# 查询包信息
curl http://localhost:4000/api/packages/<包名>

# Web 管理界面
curl http://localhost:4000/webapi/packages?size=20&page=0

# 下载包
curl -O http://localhost:4000/packages/<包名>/versions/<版本>.tar.gz
```

## 1.4 修改服务端代码

```bash
# 编辑核心文件
# vim unpub/lib/src/app.dart       ← 路由、API 处理
# vim unpub/lib/src/mongo_store.dart ← MongoDB 元数据
# vim unpub/lib/src/file_store.dart  ← 文件存储

# 验证语法
cd unpub
dart analyze

# 如果修改了路由（带 @Route 注解），需要重新生成代码
dart run build_runner build

# 重启服务
dart run bin/unpub.dart
```

## 1.5 修改 Web 前端并重新编译

**仅在需要修改 Web 管理界面时才需要此步骤。** 前端是 AngularDart 6，必须用 Dart 2.x 编译，用 Docker 最方便：

```bash
# 方式一：用 Docker 编译（推荐，不污染本地环境）
docker run --rm \
  -v $(pwd):/src \
  -w /src/unpub_web \
  google/dart:2.17 \
  bash -c "
    dart pub get && \
    dart pub global activate webdev 2.7.4 && \
    dart pub global run webdev build
  "

# 方式二：用项目 Docker 镜像内的 Dart 2.17
docker build -t unpub:dev .
docker run --rm \
  -v $(pwd):/src \
  --entrypoint bash \
  unpub:dev \
  -c "
    cd /src/unpub_web && \
    dart pub get && \
    dart pub global activate webdev 2.7.4 && \
    dart pub global run webdev build
  "

# 将编译产物转换为嵌入的 Dart 字符串常量
cd unpub
dart run tool/pre_publish.dart
```

编译后 `unpub/lib/src/static/` 下的 `index.html.dart` 和 `main.dart.js.dart` 会被更新。提交这些文件即可，其他开发者无需重新编译前端。

## 1.6 一键重建前端（Makefile 修正版）

原 Makefile 有 bug，修正后：

```makefile
build-web:
	cd unpub_web && \
	dart pub get && \
	dart pub global activate webdev 2.7.4 && \
	dart pub global run webdev build && \
	cd ../unpub && \
	dart tool/pre_publish.dart
```

---

# 第二部分：Docker 镜像构建与生产部署

## 2.1 构建镜像

### 确认 CPU 架构

```bash
# 查看当前机器架构
uname -m
# arm64 → Apple Silicon (M1/M2/M3)
# x86_64 → Intel Mac
```

### 修改 Dockerfile 中的 Dart SDK URL

Dockerfile 第 29-31 行，根据目标部署机器架构选择：

```dockerfile
# Apple Silicon (ARM64) — 默认
ENV DART_SDK_ZIP_URL https://storage.flutter-io.cn/dart-archive/channels/stable/release/2.17.1/sdk/dartsdk-linux-arm64-release.zip

# Intel / x86_64 服务器
# ENV DART_SDK_ZIP_URL https://storage.flutter-io.cn/dart-archive/channels/stable/release/2.17.1/sdk/dartsdk-linux-x64-release.zip
```

### 构建

```bash
cd unpub
docker build -t unpub:1.0.1 .
```

> **注意**: 基础镜像 `mongo:5.0` 也是多架构的，Docker 会自动拉取匹配当前平台的版本。如果在 ARM64 Mac 上构建 x86_64 镜像供 Intel 服务器使用，需要加 `--platform linux/amd64`。

## 2.2 启动容器

```bash
# 创建数据目录（如果使用卷挂载）
mkdir -p ./data

# 启动
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1

# 查看日志确认启动成功
docker logs unpub
# 看到 "Serving at http://0.0.0.0:4000" 即表示成功
```

### 数据目录说明

| 容器路径 | 宿主机挂载 | 内容 |
|----------|-----------|------|
| `/data/db` | `./data/datadb` | MongoDB 数据文件 + unpub 包文件 |
| `/data/db/unpub-packages` | `./data/datadb/unpub-packages` | 上传的 package tarball 文件 |

> `data/` 目录在 `.gitignore` 中，不会被提交到 Git。

## 2.3 验证部署

```bash
# 健康检查
curl http://localhost:4000/healthz
# 返回 "ok"

# Docker 健康状态
docker inspect unpub --format '{{.State.Health.Status}}'
# 返回 "healthy"

# Web 界面
open http://localhost:4000
```

## 2.4 发布包到已部署的 unpub

```bash
# 在要发布的 Dart/Flutter 项目中
dart pub publish --server=http://<打包机IP或域名>:4000
```

项目的 `pubspec.yaml` 中设置：

```yaml
name: my_package
publish_to: http://<打包机IP或域名>:4000
```

## 2.5 部署到远程打包机（SSH + scp）

如果另一台 Mac 打包机没有 Docker Registry，可以通过 scp 直接分发镜像。

### 远程机前置条件

```bash
# SSH 到远程机，先装好 Docker 运行时
ssh user@<打包机IP>
brew install colima docker
colima start -f
```

### 本机构建 + 导出

```bash
# 构建镜像（确认架构匹配远程机，参考 2.1 节）
docker build -t unpub:1.0.1 .

# 导出为压缩包
docker save unpub:1.0.1 | gzip > unpub-1.0.1.tar.gz
```

### 拷贝到远程机并启动

```bash
# scp 拷贝
scp unpub-1.0.1.tar.gz user@<打包机IP>:~/

# SSH 到远程机
ssh user@<打包机IP>

# 加载镜像
docker load < unpub-1.0.1.tar.gz

# 启动（数据目录按需调整）
mkdir -p ~/unpub-data
docker run -d --name unpub \
  -p 4000:4000 \
  -v ~/unpub-data/datadb:/data/db \
  --restart always \
  unpub:1.0.1

# 验证
curl http://localhost:4000/healthz
```

> **架构注意**：`uname -m` 确认远程机架构。ARM64 Mac 用 `dartsdk-linux-arm64-release.zip`（默认），Intel Mac 需先改 Dockerfile 为 `dartsdk-linux-x64-release.zip` 再构建。或者在 ARM64 本机用 `docker build --platform linux/amd64` 交叉编译。

### 后续更新

改源码后重新构建镜像，用同样流程分发更新版本：

```bash
# 本机打包新版本
docker build -t unpub:1.0.2 .
docker save unpub:1.0.2 | gzip > unpub-1.0.2.tar.gz
scp unpub-1.0.2.tar.gz user@<打包机IP>:~/

# 远程机更新
ssh user@<打包机IP>
docker load < unpub-1.0.2.tar.gz
docker stop unpub && docker rm unpub
docker run -d --name unpub \
  -p 4000:4000 \
  -v ~/unpub-data/datadb:/data/db \
  --restart always \
  unpub:1.0.2

# 数据目录 ~/unpub-data/datadb 保持不变，已发布包不丢失
```

## 2.6 远程机开机自启与健康监控

部署到远程打包机后，需要确保重启机器后服务自动恢复，并且异常时能自愈。

### 开机自启

有两层依赖：colima 先启动 → Docker 拉起容器。

`docker run --restart always` 只保证 Docker 运行后自动启动容器，不保证 colima 开机自启。需要在远程机上创建 LaunchAgent：

```bash
# SSH 到远程机
ssh user@<打包机IP>

# 创建 colima 自启任务
cat > ~/Library/LaunchAgents/com.unpub.colima.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.unpub.colima</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/colima</string>
        <string>start</string>
        <string>-f</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.unpub.colima.plist
```

> Intel Mac 远程机注意路径：colima 可能在 `/usr/local/bin/colima`，`which colima` 确认后修改 plist。

重启后的链路：**macOS 启动 → LaunchAgent 拉起 colima → Docker 启动 → `--restart always` 拉起 unpub 容器**。

### 健康监控与自动恢复

无需额外安装监控工具，系统已内置两套独立机制：

| 机制 | 工作原理 | 触发条件 | 动作 |
|------|----------|----------|------|
| Docker HEALTHCHECK | 容器内每 30s 执行 `curl /healthz` | 连续 3 次失败（即 90s 内服务不可达）| Docker 自动重启容器 |
| `--restart always` | Docker daemon 监听容器状态 | 容器进程退出（crash/OOM）| Docker 自动拉起新容器 |

叠加效果：无论 unpub 进程崩溃、MongoDB 不可达、还是容器整体僵死，最多 90s 内都会自动恢复。

如果想从外部（比如 CI 或监控面板）主动探测，直接挂 `/healthz` 端点：

```bash
# 外部健康探测
curl -f http://<打包机IP>:4000/healthz
# 返回 "ok" 且 HTTP 200 = 正常
# 返回 "unhealthy" 或连接失败 = 需要关注
```

容器内部还有进程级自愈（看门狗守护 mongod、DB 断连自动重连），详见第三部分 3.5 节。

---

# 第三部分：运维手册

## 3.1 容器管理

```bash
docker start unpub     # 启动
docker stop unpub      # 停止
docker restart unpub   # 重启
docker rm -f unpub     # 删除容器
docker logs unpub      # 查看日志
docker logs -f unpub   # 实时跟踪日志
docker logs unpub --tail 100  # 最近 100 行
```

## 3.2 镜像更新

修改代码后重新构建和部署：

```bash
# 一键重建
docker build -t unpub:1.0.1 . && \
docker stop unpub && \
docker rm unpub && \
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1 && \
docker logs unpub | tail -10
```

> 数据目录 `./data/datadb` 保持不变，包数据不会丢失。

## 3.3 数据备份与恢复

```bash
# 备份（容器运行中也可以执行）
tar czf unpub-backup-$(date +%Y%m%d).tar.gz ./data/datadb

# 恢复到新机器
tar xzf unpub-backup-20250525.tar.gz
# 然后启动容器，-v 挂载到恢复的数据目录
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1
```

## 3.4 开机自启（Mac 打包机）

Docker 容器的 `--restart always` 只有在 Docker 运行时才生效。Mac 打包机需要让 colima 开机自启：

```bash
# 创建 colima 自启 LaunchAgent
cat > ~/Library/LaunchAgents/com.unpub.colima.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.unpub.colima</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/colima</string>
        <string>start</string>
        <string>-f</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

# 加载
launchctl load ~/Library/LaunchAgents/com.unpub.colima.plist
```

colima 启动后，Docker 会自动重启带 `--restart always` 的容器，unpub 随之恢复运行。

## 3.5 自动恢复机制

系统内置多层自恢复，无需人工介入：

| 层 | 机制 | 触发条件 | 恢复方式 |
|---|------|----------|----------|
| 进程内 | 错误中间件 | 任意路由异常 | 捕获异常，返回 500 JSON，进程不崩 |
| 进程内 | DB 重连 | DB 操作时发现连接断开 | 自动 `close()` + `open()` |
| 进程内 | DB 心跳 | 每 5 分钟 | ping MongoDB，防止空闲超时断开 |
| 进程内 | 下载统计容错 | 下载计数写入失败 | 打印警告日志，不阻塞响应 |
| 进程内 | 优雅关闭 | SIGTERM / SIGINT | 关闭 HTTP 服务 + DB 连接 |
| 容器内 | 启动等待 | 容器冷启动 | 等待 mongod 就绪后再启动 Dart 应用 |
| 容器内 | mongod 看门狗 | mongod 进程崩溃 | 5 秒内自动重启 mongod |
| Docker | HEALTHCHECK | 连续 3 次 `/healthz` 失败 | 自动重启容器 |

### 验证自恢复

```bash
# 模拟 mongod 崩溃
docker exec unpub pkill -9 mongod

# 6 秒后检查（看门狗应已自动重启）
sleep 6
docker exec unpub mongosh --quiet --eval "db.adminCommand('ping')"
# 应返回 {"ok":1}

# 服务仍然正常
curl http://localhost:4000/healthz
# 应返回 "ok"
```

### 诊断日志关键字

```bash
docker logs unpub | grep "mongod died"               # 看门狗检测到崩溃
docker logs unpub | grep "cannot increment downloads" # DB 写入容错
docker logs unpub | grep "Unhandled error"            # 路由异常捕获
docker logs unpub | grep "shutting down gracefully"   # 优雅关闭
```

## 3.6 MongoDB 版本兼容性

`mongo_dart 0.7.x` 使用旧版 **OP_QUERY** 有线协议，MongoDB 6.0+ 已移除支持。

| MongoDB 版本 | 兼容性 |
|-------------|--------|
| 5.0 | ✅ 兼容（Dockerfile 已固定） |
| 6.0+ | ❌ 不兼容（count/find 操作全部失败） |

**不要升级基础镜像到 `mongo:latest`（目前是 7.x）**，除非同步升级 `mongo_dart` 到 0.10.x（需要大量代码改动）。

## 3.7 colima 管理（仅 macOS）

```bash
colima start           # 启动 Docker 运行时
colima stop            # 停止
colima status          # 查看状态
colima delete          # 完全清除（会丢失所有容器和数据）
```

---

# 附录

## A. Dockerfile 关键参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 基础镜像 | `mongo:5.0` | 必须 5.0 |
| Dart SDK | 2.17.1 | 从 Flutter CN 镜像下载 |
| 源码 | `COPY ./unpub /src/unpub` | 直接从仓库复制 |
| 端口 | 4000 | pub API + Web 管理界面 |
| 数据目录 | `/data/db` | MongoDB 数据 |
| 健康检查 | 每 30s | `/healthz` 端点，3 次失败重启 |
| 入口 | `docker-entrypoint.sh` | 启动 mongod + 看门狗 + unpub |

## B. 本地改动汇总

| 改动 | 文件 | 说明 |
|------|------|------|
| 跳过 Google 鉴权 | `unpub/lib/src/app.dart` | upload 接口不再验证 Google OAuth2 token |
| 跳过 uploader 鉴权 | `unpub/lib/src/app.dart` | addUploader/removeUploader 跳过操作者身份验证 |
| Docker 路径适配 | `unpub/bin/unpub.dart` | 包存储路径改用环境变量 `UNPUB_PACKAGE_DIR` |
| Dockerfile 钉 MongoDB 5.0 | `Dockerfile` | `mongo_dart 0.7.x` 不兼容 MongoDB 6.0+ |
| GFM Markdown 渲染 | `unpub/lib/src/app.dart` | README/CHANGELOG 使用 GitHub Flavored Markdown 渲染 |
| 自恢复机制 | `docker-entrypoint.sh`, `app.dart` 等 | 多层自动恢复，详见 3.5 节 |
