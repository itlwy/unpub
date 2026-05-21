# unpub 私有 Dart Pub 服务器 — 部署说明

## 项目概述

- **unpub**: 字节跳动开源的自建 Dart Pub 服务器，基于 shelf + MongoDB
- **Fork 仓库**: pd4d10/unpub（含 `unpub_web` 前端源码）
- **本地改动**: 跳过 Google OAuth2 鉴权 + Docker 容器化部署

## 项目结构

```
unpub/
├── unpub/                  ← 核心服务端 Dart 代码
│   ├── lib/src/            ← 服务端源码
│   │   ├── app.dart        ← 核心路由和 API（已跳过 Google 鉴权）
│   │   └── static/         ← Web 前端编译产物（嵌入为 Dart 字符串）
│   ├── bin/unpub.dart      ← 入口文件
│   └── pubspec.yaml
├── unpub_web/              ← Web 前端源码（AngularDart 6）
├── unpub_auth/             ← 鉴权插件（可选）
├── unpub_aws/              ← AWS S3 存储插件（可选）
├── Dockerfile              ← Docker 镜像定义
├── docker-entrypoint.sh    ← 容器入口脚本
├── DEPLOY.md               ← 本文档
└── Makefile
```

## 环境要求

| 环境 | 说明 |
|------|------|
| macOS (本机测试) | colima + docker CLI |
| Linux 服务器 (正式部署) | 原生 Docker Engine |

## 本地改动说明

基于 pd4d10/unpub 的 fork，做了以下关键改动：

| 改动 | 文件 | 说明 |
|------|------|------|
| 跳过 Google 鉴权 | `unpub/lib/src/app.dart` | upload 接口不再验证 Google OAuth2 token |
| 跳过 uploader 鉴权 | `unpub/lib/src/app.dart` | addUploader/removeUploader 跳过操作者身份验证 |
| Docker 路径适配 | `unpub/bin/unpub.dart` | 包存储路径改为 `/data/db/unpub-packages` |
| Dockerfile 钉 MongoDB 5.0 | `Dockerfile` | mongo_dart 0.7.x 不兼容 MongoDB 6.0+ |

---

## 一、macOS 本地测试环境

### 安装 Docker 运行时

```bash
# 安装 colima（轻量 Docker 运行时）+ docker CLI
brew install colima docker

# 启动 colima
colima start -f

# 验证
docker info
```

### 构建镜像

```bash
cd unpub

# Apple Silicon (ARM64)
docker build -t unpub:1.0.1 .

# x86_64 服务器：先修改 Dockerfile 中 DART_SDK_ZIP_URL 为 x64 版本，再构建
```

### 启动容器

```bash
mkdir -p ./data
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1
```

### 验证

```bash
# 查看日志，确认 "Serving at http://0.0.0.0:4000"
docker logs unpub

# 测试 Web 界面
curl http://localhost:4000/

# 测试 API
curl http://localhost:4000/api/packages/test
```

---

## 二、Linux 服务器部署

### 安装 Docker

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh

# CentOS/RHEL
yum install -y docker
systemctl enable docker && systemctl start docker
```

### 注意：修改 Dockerfile 架构

部署到 x86_64 服务器前，将 Dockerfile 中 Dart SDK URL 改回 x64 版本：

```dockerfile
# x86_64 服务器用这个
ENV DART_SDK_ZIP_URL https://storage.flutter-io.cn/dart-archive/channels/stable/release/2.17.1/sdk/dartsdk-linux-x64-release.zip

# Apple Silicon 用这个
# ENV DART_SDK_ZIP_URL https://storage.flutter-io.cn/dart-archive/channels/stable/release/2.17.1/sdk/dartsdk-linux-arm64-release.zip
```

### 构建并启动

```bash
cd unpub

# 构建
docker build -t unpub:1.0.1 .

# 启动（数据持久化到 ./data/datadb）
mkdir -p ./data
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1
```

---

## 三、常用操作命令

### 容器管理

```bash
docker start unpub     # 启动
docker stop unpub      # 停止
docker restart unpub   # 重启
docker rm -f unpub     # 删除容器
docker logs unpub      # 查看日志
docker logs -f unpub   # 实时跟踪日志
```

### colima 管理（仅 macOS）

```bash
colima start           # 启动 Docker 运行时
colima stop            # 停止
colima status          # 查看状态
```

### 发布 Dart 包到 unpub

直接使用 Dart 官方内置的 pub 工具即可，无需旧版 ax_publish：

```bash
# 在你的 Dart 项目中
dart pub publish --server=http://<unpub服务器地址>:4000
```

注意：`pubspec.yaml` 中需要设置 `publish_to` 字段：

```yaml
name: my_package
publish_to: http://<unpub服务器地址>:4000
```

---

## 四、关于 ax_publish（pub 发布器）

`pub/` 目录下的 `ax_publish` 是旧版 Dart pub 工具的定制 fork，用于跳过 Google OAuth2 鉴权发布到私有仓库。

**不需要使用它**。现代 Dart SDK 内置的 `dart pub publish --server=<URL>` 对非 pub.dev 的第三方服务器不会走 Google OAuth2，直接用就行。

---

## 五、已知问题：MongoDB 版本兼容性

### 问题现象

Web 管理界面正常打开，但 `/webapi/packages` 接口返回 **500 Internal Server Error**，浏览器控制台报：

```
FormatException: SyntaxError: Unexpected token 'I', "Internal S"... is not valid JSON
```

容器日志中报：

```
Unsupported OP_QUERY command: count. The client driver may require an upgrade.
```

### 原因

`unpub` 使用的 `mongo_dart: 0.7.4+1` 是 2022 年的老版本，底层使用 MongoDB 的 **OP_QUERY** 旧版有线协议进行数据库操作。MongoDB 6.0+ 已经**移除了对旧版 OP_QUERY 命令的支持**（参见 [MongoDB Legacy Opcode Removal](https://dochub.mongodb.org/core/legacy-opcode-removal)）。

而 Dockerfile 中写的是 `FROM mongo:latest`，会拉取最新的 MongoDB 7.x，导致 `count`、`find` 等操作全部失败。

### 修复

将 Dockerfile 基础镜像从 `mongo:latest` 钉到 `mongo:5.0`：

```dockerfile
# 错误 ❌
FROM mongo:latest

# 正确 ✅
FROM mongo:5.0
```

MongoDB 5.0 是最后一个完整支持 OP_QUERY 协议的版本，与 `mongo_dart 0.7.x` 完全兼容。

### 注意事项

- **不要随意升级 `mongo:latest`**，除非同步升级 `unpub.zip` 中的 `mongo_dart` 到 0.10.x 版本（需要大量代码改动）
- **MongoDB 大版本之间数据不兼容**，如果之前用 mongo:latest 跑过，重建容器前需要删除数据目录 `rm -rf ./data`
- 完整升级路径（如果未来需要）：升级 mongo_dart → 0.10.x → 修改 `mongo_store.dart` 中的 API 调用 → 更新 `pubspec.yaml` 依赖 → 重新打包 `unpub.zip` → 更新 Dockerfile 中 `mongo:7.0`

---

## 六、开发构建流程

### 项目结构关系

```
unpub/
├── unpub/                     ← 服务端源码（开发主要在这里）
│   ├── lib/
│   │   ├── src/
│   │   │   ├── app.dart       ← 核心：路由、API 处理
│   │   │   ├── app.g.dart     ← shelf_router 生成的路由代码
│   │   │   ├── mongo_store.dart ← MongoDB 元数据存储
│   │   │   ├── file_store.dart  ← 文件系统包存储
│   │   │   ├── models.dart/models.g.dart ← 数据模型
│   │   │   ├── utils.dart     ← YAML 解析等工具函数
│   │   │   └── static/        ← Web 前端编译产物（嵌入为 Dart 字符串）
│   │   └── unpub_api/         ← Web API 数据模型子包
│   ├── bin/unpub.dart         ← 入口文件
│   └── pubspec.yaml
├── unpub_web/                 ← Web 前端源码（AngularDart 6）
│   ├── web/
│   └── lib/
├── Dockerfile                 ← Docker 镜像定义
├── docker-entrypoint.sh       ← 容器入口脚本
└── DEPLOY.md                  ← 本文档
```

### 修改服务端代码

```bash
# 修改 Dart 代码
# 例如：vim unpub/lib/src/app.dart

# 验证语法（需要本地 Dart 2.17.x）
# dart analyze unpub/
```

### 修改 Web 前端代码

`unpub_web/` 是 AngularDart 6 项目。修改后需要重新编译并生成嵌入式 Dart 文件：

```bash
cd unpub_web
dart pub get
dart run build_runner build --output web:build

# 然后运行 pre_publish 工具将编译产物转为 Dart 字符串常量
cd ../unpub
dart tool/pre_publish.dart
```

### 构建并更新 Docker 容器

```bash
# 1. 构建新镜像
docker build -t unpub:1.0.1 .

# 2. 更新容器
docker stop unpub && docker rm unpub
mkdir -p ./data
docker run -d --name unpub \
  -p 4000:4000 \
  -v $(pwd)/data/datadb:/data/db \
  --restart always \
  unpub:1.0.1

# 3. 查看日志
docker logs -f unpub
```

### 一键重建脚本

```bash
#!/bin/bash
set -e
echo "=== 1. 构建镜像 ==="
docker build -t unpub:1.0.1 .

echo "=== 2. 更新容器 ==="
docker stop unpub 2>/dev/null || true
docker rm unpub 2>/dev/null || true
mkdir -p ./data
docker run -d --name unpub \
  -p 4000:4000 \
  -v "$(pwd)/data/datadb:/data/db" \
  --restart always \
  unpub:1.0.1

echo "=== 完成 ==="
docker logs unpub | tail -5
```

---

## 七、Dockerfile 关键信息

| 组件 | 说明 |
|------|------|
| 基础镜像 | `mongo:5.0`（必须 5.0，不能 latest！mongo_dart 0.7.x 使用旧版 OP_QUERY 协议，MongoDB 6.0+ 已移除支持） |
| Dart SDK | 2.17.1（从 Flutter CN 镜像下载） |
| unpub 源码 | 通过 `COPY ./unpub /src/unpub` 直接从仓库复制 |
| 端口 | 4000（pub API + Web 管理界面） |
| 数据目录 | `/data/db`（MongoDB 数据，挂载到宿主机） |
| 入口脚本 | 先启动 mongod → 执行 dart pub get → 启动 unpub |

---

## 八、本机当前状态

| 项 | 状态 |
|----|------|
| Docker 运行时 | colima 0.10.1 + docker 29.5.1 |
| colima 是否开机自启 | 否（需手动 `colima start`） |
| unpub 容器 | 已启动，端口 4000，自动重启 |
| 数据目录 | `cicd/docker/unpub/data/datadb/` |
| 访问地址 | http://localhost:4000 |
