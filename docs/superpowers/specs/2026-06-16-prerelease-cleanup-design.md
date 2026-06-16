# unpub 测试版本清理设计

## 背景

组件发布到 unpub 时，希望支持测试期间的预发布版本，例如 `1.0.1-beta.1`、`1.0.1-beta.2`。正式发布 `1.0.1` 后，可以清理这些测试版本，只保留正式版本。

当前 unpub 的版本元数据存储在 MongoDB 包文档的 `versions` 数组中，包文件由 `PackageStore` 抽象存储。现有读路径中，`latest`、Web 列表、详情页和 badge 存在直接取 `versions.last` 或使用所有版本计算最高版本的逻辑，预发布版本可能会被错误当作 latest。

## 目标

- 允许正常发布语义化预发布版本，例如 `1.0.1-beta.1`。
- 正式版本发布后，客户端和 Web UI 默认把正式版本视为 latest。
- 提供显式清理能力，删除指定正式版本对应的 beta 版本。
- 清理过程幂等、可重试，避免元数据和包文件长期不一致。
- 避免误删其他正式版本、其他预发布标签或其他 base version 的版本。

## 非目标

- 不改变 `dart pub publish` 的基础流程。
- 不做自动发布正式版时立即删除 beta 的强绑定流程。
- 不引入复杂的版本生命周期状态机。
- 不支持删除任意正式版本。

## 推荐方案

采用“读路径隔离 prerelease + 显式清理 prerelease”的两层设计。

第一层是读路径稳定化：统一使用一个 helper 选择 latest。规则为：

- 优先选择最高正式版本。
- 如果没有正式版本，才选择最高预发布版本。
- 所有面向客户端或 Web 的 latest 语义都使用这个 helper。

第二层是显式清理：新增一个受控接口或管理命令，清理指定正式版本对应的测试版本。例如清理 `1.0.1` 的 beta，只匹配：

- `1.0.1-beta.1`
- `1.0.1-beta.2`

不匹配：

- `1.0.2-beta.1`
- `1.0.1-rc.1`
- `1.0.0-beta.1`
- `1.0.1`

## API 设计

建议新增管理接口：

```http
DELETE /api/packages/<name>/versions/prereleases?base=1.0.1&tag=beta
```

参数：

- `name`：包名。
- `base`：正式版本号，必须是合法 semver 且不能带 prerelease。
- `tag`：预发布标签，默认 `beta`。第一阶段只允许 `beta`，以后可扩展到 `rc` 等。
- 可选 `dryRun=true`：只返回会被清理的版本，不实际删除。

成功响应示例：

```json
{
  "success": true,
  "package": "example_package",
  "base": "1.0.1",
  "tag": "beta",
  "removed": ["1.0.1-beta.1", "1.0.1-beta.2"],
  "storageFailures": []
}
```

如果部分 tarball 删除失败，接口仍返回 200，并在 `storageFailures` 中列出失败版本。再次调用应继续尝试删除残留文件。

## 数据与存储接口

扩展 `MetaStore`：

```dart
Future<List<UnpubVersion>> removeVersions(String name, List<String> versions);
```

语义：

- 原子地从 `versions` 数组中移除匹配版本。
- 返回实际移除的版本元数据，供后续删除 tarball。
- 如果版本已不存在，返回空列表。
- 更新包的 `updatedAt`。

扩展 `PackageStore`：

```dart
Future<void> delete(String name, String version);
```

语义：

- 删除指定版本 tarball。
- 文件不存在视为成功，保证幂等。
- `FileStore` 删除本地文件。
- `S3Store` 删除对象。

## 清理流程

1. 查询包元数据；包不存在返回 404。
2. 解析并验证 `base` 和 `tag`。
3. 筛选同 base version 且 prerelease tag 为 `tag` 的版本。
4. 如果 `dryRun=true`，直接返回匹配列表。
5. 从 MongoDB 中移除匹配版本。
6. 逐个删除 tarball。
7. 返回已移除版本和 tarball 删除失败列表。

删除顺序选择“先元数据、后 tarball”。理由是客户端读路径以元数据为准，先移除元数据可以最快避免客户端拿到即将删除的版本。tarball 删除失败时不会影响正式版本解析，后续可重试清理。

## 稳定性约束

- 清理接口必须幂等；重复调用不会报错。
- 不允许清理当前唯一版本，除非当前包同时存在正式 `base` 版本。
- 清理前必须确认正式 `base` 版本已经存在，防止误删还未正式发布的测试版本。
- 下载接口应先确认请求版本存在于元数据中；不存在则返回 404，而不是直接读 tarball。
- latest 计算不能依赖 MongoDB 数组顺序。
- 所有 semver 判断使用 `pub_semver`，不做字符串前缀匹配。

## 需要调整的读路径

- `/api/packages/<name>` 的 `latest`。
- `/webapi/packages` 列表里的展示版本、描述和 tag。
- `/webapi/package/<name>/latest`。
- `/badge/v/<name>`。

`/packages/<name>.json` 可以继续返回所有未清理版本，供 Web UI 展示完整历史；清理后自然不再返回已删除版本。

## 测试计划

新增或调整测试覆盖：

- `1.0.0`、`1.0.1-beta.1`、`1.0.1-beta.2` 并存时，latest 仍是 `1.0.0`。
- 发布 `1.0.1` 后，latest 是 `1.0.1`。
- 清理 `base=1.0.1&tag=beta` 只删除 `1.0.1-beta.*`。
- 清理后 `/api/packages/<name>`、详情页、badge 都不再显示 beta。
- 清理后 beta 版本 API 和 tarball 下载返回 404。
- 重复调用清理接口成功且返回空 removed。
- tarball 删除失败时，元数据已清理，响应包含 `storageFailures`。

## 后续实施顺序

1. 增加 semver helper，统一 latest 和 prerelease 匹配逻辑。
2. 修复读路径 latest 行为。
3. 扩展 `MetaStore` 和 `PackageStore` 删除接口。
4. 实现 `MongoStore`、`FileStore`、`S3Store` 删除。
5. 增加清理 API。
6. 补齐测试。
