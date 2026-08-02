# GalGameService 冻结项说明

> 负责人：`@F15EX`
> 权威接口来源：`docs/contract.md` §7
> 更新时间：2026-08-02

本文只记录 GalGameService 已经冻结的实现选择，不能覆盖 `contract.md`。字段、状态码或
调用方式发生变化时，必须先更新契约、调用方和测试，再同步本文。

## 游戏包 schema 1.0

结构文件为
`backend/GalGameService/schema/game-package-1.0.schema.json`，使用 JSON Schema
draft-07。顶层与嵌套对象均拒绝未知字段。

当前数量边界：

| 内容 | 下限 | 上限 |
|---|---:|---:|
| 单包场景 | 1 | 100 |
| 单场景对话 | 1 | 200 |
| 单场景选项 | 0 | 6 |

Schema 负责类型、枚举和数量；`GamePackageValidator` 负责入口场景、引用、可达性、
QUESTION 绑定以及正确选项等跨字段规则。当前没有冻结“游戏包最多 2 MiB”的限制，调用方
不得自行添加该约束。

`scoreDelta` 是任意 JSON number，只表示游戏计分。题目选项必须显式携带
`answerKind=CHOICE` 和 `correct`；每题至少有一个 `correct=true`，但不要求恰好一个。
RenderService 和 KnowledgeService 都不得从 `scoreDelta` 推断正确性或掌握度。

## 资源与角色

首版不引入独立角色实体。对话使用 `speakerId` 与可选 `emotion`；背景、立绘、音频等
统一使用 `AssetRef`。资源 URI 必须经 Gateway 可寻址，不能是服务直连地址或内嵌
base64。

## 生成任务

任务按
`QUEUED -> RUNNING -> SUCCEEDED | FAILED` 迁移，并原子交付完整游戏包，不提供部分成功
结果。同步读取 PlanGraph 失败时不创建任务；后台生成失败时 `packageId=null`，错误写入
`GameGenerationJob.error`。

当前生成器版本为 `gala-0.1.0`。显式 seed 只保证 questionId、场景顺序与选项顺序稳定；
`packageId` 与 manifest 时间每次重新生成，因此不承诺整个 JSON 或 checksum 字节相同。
确定性 questionId 使用哈希后修正为公共契约要求的 UUID v4 形状，不是 UUID v5。

## 存储现状

普通模式和 Mock 模式均支持 MongoDB 持久化存储（`MongoGameStore`）。通过
`GalGameStore:Provider` 配置项切换：

| `GalGameStore:Provider` | `MOONSTONE_MODE` | 存储实现 | `readyz` 报告 |
|---|---|---|---|
| `MongoDB`（默认） | `Mock` | MongoDB + 黄金包预置 | `mock-mongodb` |
| `MongoDB`（默认） | 非 Mock | MongoDB（无预置） | `mongodb` |
| `Memory` | `Mock` | 纯内存 + 黄金包预置 | `mock-memory` |
| `Memory` | 非 Mock | 纯内存（无预置） | `ephemeral-memory` |

MongoDB 连接配置：

- `ConnectionStrings:GameDatabase`：MongoDB 连接字符串（默认 `mongodb://127.0.0.1:5253`）
- `MongoDb:Database`：数据库名（默认 `moonstone_galgame`，Docker 环境为 `qzwl_galgame`）

集合设计：

| 集合 | 文档 | `_id` | 用途 |
|---|---|---|---|
| `game_jobs` | `GameGenerationJob` | `GenerationId` | 生成任务状态 |
| `game_packages` | `BsonDocument`（JSON 序列化的 `GamePackage`） | `PackageId` | 完整游戏包 |
| `game_manifests` | `GamePackageManifest` | `PackageId` | 游戏包清单 |
| `game_owners` | `{ PackageId, OwnerUserId }` | `PackageId` | 包-用户归属映射 |

线程安全：

- `TryTransitionJob` 使用 MongoDB `FindOneAndReplace` + 条件过滤器实现 CAS 语义，
  无需应用层锁
- `SavePackage` 使用 `IsUpsert=true` 保证幂等写入
- 已完成 job 通过 TTL 索引自动 30 天过期
- `MaxJobs=10000` 容量限制：超限时清理最旧的 10% 已完成 job

`readyz` 端点在使用 MongoDB 存储时会执行 `ping` 命令检查连接可用性，不可用时返回 503。

## 已完成联调

- GalGameService 经 Gateway 读取并校验 KnowledgeService 的不可变 PlanGraph；
- GalGameService 已预留 RenderService 精确服务身份；后续完整 Render 实现必须据此读取权威游戏包并再次调用校验接口；
- Assessment 游戏包已在容器链路中创建，并通过 C++ / JS 基础壳完成浏览器本地游玩；Render 证据回传尚未实现；
- 完整包 checksum、ETag、QUESTION 绑定、显式正确性和 INTERNAL owner 校验已有自动化或
  集成测试。

仍未完成：`GamePackageReady v1` 消息发布，以及跨副本任务恢复。
