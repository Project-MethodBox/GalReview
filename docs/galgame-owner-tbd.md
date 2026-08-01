# GalGameService OWNER-TBD 决策冻结

> 负责人：`@F15EX`
> 依据：`docs/contract.md` §7.5
> 状态：M0 基线冻结
> 更新时间：2026-08-01

本文逐条冻结 `docs/contract.md` §7.5 列出的六项 OWNER-TBD，把原本"待确认"的细节变成可执行
基线。每项给出决策值、依据与可验证落点。后续破坏性变更需升级 `schemaVersion` 主版本并同步
调用方与 Mock。

---

## 1. `schemaVersion=1.0` 的完整 JSON Schema

**决策**：已交付 `backend/GalGameService/schema/game-package-1.0.schema.json`（JSON Schema
draft-07）。

**覆盖范围**：
- 顶层必填字段：`schemaVersion / packageId / generatorVersion / reviewPlanId /
  snapshotVersion / entrySceneId / scenes / assets`，`additionalProperties: false`。
- `schemaVersion` 固定为 `"1.0"`（`const`）。
- UUID 格式约束（`packageId / reviewPlanId / questionId / knowledgePointId`）。
- 数量上限（见第 2 项）。
- 枚举：`AssetType`、`KnowledgePurpose`、`scoreDelta ∈ {0,1}`。
- `additionalProperties: false` 贯穿所有对象，禁止未知字段。

**与校验器的边界**：JSON Schema 只做**结构与字段级**约束；跨字段语义（每题恰一个正确选项、
孤儿绑定、`questionId` 跨场景一致性、`nextSceneId` 引用有效性、`entrySceneId` 存在性、纯空白
字符串）由 `GamePackageValidator` 在运行时强制。二者互补，缺一不可：
- Schema 可被 RenderService / CI / 前端在反序列化前做廉价预检；
- 校验器在 `POST /internal/v1/game-package-validations` 端点强制完整语义。

**可验证落点**：`GamePackageSchemaTests.cs` 断言 Schema 为合法 JSON、声明 draft-07、并编码了
冻结的数量上限。

---

## 2. 场景、对话和选择数量上限

**决策**：采纳 `GamePackageValidator` 现有常量，作为 schema 1.0 冻结值：

| 量 | 上限 | 常量 | 依据 |
|---|---:|---|---|
| 场景数 | 100 | `MaxScenes` | 单包覆盖一条完整复习路径，100 场景足够容纳讲解+题目+反馈+多分支；超过意味着生成器把多个独立计划塞进同一包。 |
| 单场景对话行 | 200 | `MaxDialoguePerScene` | 单场景 200 行对话约对应 5–10 分钟剧情；超过通常是生成器循环或拼接异常。 |
| 单场景选项数 | 6 | `MaxChoicesPerScene` | BASIC/STANDARD 4 选项 + ADVANCED 3 选项，6 为分支扩展预留上限，且避免移动端选择面板过密。 |
| 包 JSON 字节数 | 2 MiB | `MaxPackageJsonBytes` | 防止异常大包攻击与 Gateway 传输压力；与 FileService 10 MiB 上限无关，仅约束游戏包。 |

**下限**：
- `scenes` 至少 1 个（空包无意义）。
- 单场景 `dialogue` 至少 1 行（无对话的空场景非法）；`choices` 与 `knowledgeBindings`
  允许空数组（纯讲解/导航场景）。

**可验证落点**：JSON Schema 的 `minItems/maxItems`；`InvalidPackageTests.cs` 的程序化超限
用例（101 场景、201 对话、7 选项）断言 `SCENE_COUNT_OUT_OF_RANGE` /
`DIALOGUE_COUNT_OUT_OF_RANGE` / `CHOICE_COUNT_OUT_OF_RANGE`。

---

## 3. 角色、音频和资源引用结构

**决策**：首版不引入独立"角色"实体，资源统一用 `AssetRef` 表达。

**角色**：由 `DialogueLine.speakerId`（必填、非空）标识，`emotion`（可选字符串）承载情绪
标签。角色立绘、声线等富资源通过 `AssetRef.type=CHARACTER` / `AUDIO` 引用，由前端按
`speakerId` 关联。首版不冻结角色属性表（姓名、立绘映射、声优等），留给前端适配器。

**资源引用 `AssetRef`**：
```text
{ assetId: string (包内唯一, 非空),
  type: "BACKGROUND" | "CHARACTER" | "AUDIO" | "OTHER",
  uri: string (非空, Gateway 控制地址/相对地址/短期签名地址) }
```
- `assetId` 包内唯一，`uri` 不得为空。
- `assets` 可为空数组（黄金包即如此）。
- `uri` 必须是经 Gateway 可寻址的引用，不得是服务直连地址或 base64 内嵌资源。

**可验证落点**：JSON Schema `$defs/asset`；`invalid-assets.json` + 负向测试覆盖
`DUPLICATE_ASSET_ID / EMPTY_ASSET_FIELD / NULL_ELEMENT`。

---

## 4. 生成失败和部分成功语义

**决策**：生成任务**原子交付**，不存在"部分游戏包"。

**状态机**（`GameGenerationJob.status`）：
- `QUEUED` → `RUNNING` → `SUCCEEDED`（`packageId` 非空）或 `FAILED`（`error` 非空）。
- `SUCCEEDED` 与 `FAILED` 是终态；`progress` 单调非递减，`SUCCEEDED` 时为 100。

**失败语义**：
- 任何校验失败（PlanGraph `snapshotVersion` 不匹配 → `422 REVIEW_PLAN_SNAPSHOT_MISMATCH`；
  `reviewPlanId` 不存在 → `422 REVIEW_PLAN_NOT_FOUND`；上游不可达 → `503 SERVICE_UNAVAILABLE`）
  在返回 `202` **之前**即被拒绝，不创建 `FAILED` 任务。
- 后台生成阶段失败时，任务转为 `FAILED` 并写入 `ApiError`，**不写 `packageId`**，**不发布**
  `GamePackageReady v1`；调用方可凭 `generationId` 轮询或等待事件。
- 失败不保留半成品：`InMemoryGameStore` 不会暴露 `packageId=null` 的内容端点；`GET
  /api/v1/game-packages/{packageId}/content` 对未生成的包返回 `404`。

**部分成功**：明确**不允许**。即使 PlanGraph 含 N 个 `questionTarget`，生成器必须产出完整可
游玩的包，或在 `FAILED` 中说明原因；不返回"只有部分题目"的包。

**可验证落点**：`GameGeneratorTests.cs` 断言 `SUCCEEDED` 任务 `packageId` 非空且包通过校验器；
集成测试断言失败任务不产生可读包内容。

---

## 5. `generatorVersion` 与 seed 的可复现范围

**决策**：

- **generatorVersion**：`gala-0.1.0`。算法或题面模板的任何变化必须升级版本号（如
  `gala-0.2.0`），并保证旧版本号仍能复现旧包（版本号是可复现性的入口）。
- **seed**：`GameGenerationRequest.seed`（`int64?`）。`null` 时使用密码学随机源，包不可
  复现；显式提供 `seed` 时生成**确定性可复现**。
- **可复现边界**：相同 `(PlanGraph reviewPlanId + snapshotVersion, style, difficulty,
  locale, seed, generatorVersion)` 六元组 → 字节级等价的 `GamePackage`（含 `packageId`、
  `questionId`、`checksum`）。
- **`questionId` 确定性**：使用 UUID v5（命名空间 + `(pointId, seed)`）生成，保证同一知识点
  在相同 seed 下产生同一 `questionId`，便于跨服务证据比对。
- **不可复现项**：`createdAt` 等时间戳不进入可复现边界（生成器不写时间戳到包内容；
  `GamePackageManifest.createdAt` 是清单元数据，不参与 `checksum`）。

**可验证落点**：`GameGeneratorTests.cs` 含"相同 seed 两次生成 → 相同 checksum"用例。

---

## 6. 游戏包保存位置和清理策略

**决策**：

- **保存位置**：
  - Mock 模式（`MOONSTONE_MODE=Mock`）：`InMemoryGameStore`，进程内字典，重启即失，用于
    本地与集成测试。
  - 生产模式：由 `IGameStore` 抽象的持久化实现承载（首版未实现，OWNER-TBD 升级为 P1），
    候选为 MongoDB（与 FileService 同栈）或对象存储 + 元数据表；`contentUrl` 指向经 Gateway
    的 `/api/v1/game-packages/{packageId}/content`。
- **保留期**：
  - 已生成且 `GameGenerationJob.status=SUCCEEDED` 的包保留**至少至对应 `ReviewPlan` 过期**
    （`PlanGraph.expiresAt`）。
  - `PlanGraph` 过期后，对应包进入**可清理**状态；清理不影响已发起的 `ReviewSession`（由
    RenderService 持有会话期副本）。
- **清理策略**：
  - 后台清理任务按 `expiresAt + 7 天` 宽限期删除包内容与清单，保留任务记录用于审计。
  - `FAILED` 任务的包内容立即可清理（本就不存在）。
  - 清理幂等：重复删除同一 `packageId` 不报错。
- **不清理项**：黄金游戏包（`f2561bb2-...`）在 Mock 模式下常驻，供冒烟与契约测试使用。

**可验证落点**：`InMemoryGameStoreTests.cs` 覆盖存储/读取/缺失返回 404；生产清理策略在
持久化实现落地时补集成测试。

---

## 交付物索引（§12.1 三件套 + 补充）

| 交付物 | 路径 | 状态 |
|---|---|---|
| 黄金游戏包 | `backend/GalGameService/mocks/golden.json` | ✅ |
| 风格包 ×3 | `backend/GalGameService/mocks/{campus-standard,fantasy-advanced,science-basic}.json` | ✅ |
| **故意错误包 ×6** | `backend/GalGameService/mocks/invalid-*.json` | ✅ 新增 |
| **校验器** | `backend/GalGameService/GamePackageValidator.cs` | ✅ |
| **JSON Schema 1.0** | `backend/GalGameService/schema/game-package-1.0.schema.json` | ✅ 新增 |
| 负向测试 | `backend/GalGameService/Tests/InvalidPackageTests.cs` | ✅ 新增 |
| Schema 契约测试 | `backend/GalGameService/Tests/GamePackageSchemaTests.cs` | ✅ 新增 |
| 本决策文档 | `docs/galgame-owner-tbd.md` | ✅ 新增 |

## 未在本阶段处理（仍为 P1 / 跨服务）

- 接入集成 compose 与 Gateway readiness（阶段 B）。
- 真实 PlanGraph 读取 E2E（阶段 C）。
- 生产持久化存储实现（`IGameStore` 持久化分支）。
- `GamePackageReady v1` 事件生产（待统一消息总线基线）。
