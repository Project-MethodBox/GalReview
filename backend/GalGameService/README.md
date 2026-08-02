# GalGameService — 游戏生成服务

> 负责人：`@F15EX`
> 契约：`docs/contract.md` §7
> 端口：5105
> 技术栈：.NET 10 / ASP.NET Core Minimal API

## 职责

- 游戏生成任务管理（创建、查询）
- 游戏包 schema 1.0 实现与校验
- 剧情模板生成（CAMPUS / FANTASY / SCIENCE）
- 难度适配（BASIC / STANDARD / ADVANCED）
- 经 Gateway 读取 KnowledgeService 的不可变 PlanGraph（§7.3.1 URGENT）

## 端点

| 方法 | 路由 | 用途 | 状态码 |
|---|---|---|---|
| `POST` | `/api/v1/game-generations` | 创建游戏包生成任务 | `202/400/401/422/503` |
| `GET` | `/api/v1/game-generations/{generationId}` | 查询生成任务 | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}` | 读取游戏包清单 | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}/content` | 下载完整 JSON | `200/304/400/401/404` |
| `GET` | `/internal/v1/game-packages/{packageId}` | 读取权威游戏包（服务间） | `200/400/403/404` |
| `POST` | `/internal/v1/game-package-validations` | 校验游戏包（服务间） | `200/400/403/422` |
| `GET` | `/healthz` | 存活探针 | `200` |
| `GET` | `/readyz` | 就绪探针（含叙事状态） | `200/503` |

## 文件结构

```
GalGameService/
├── Program.cs                  # 服务入口：中间件链 + 端点 + DI 注册
├── Contracts.cs                # 数据类型（GamePackage、Scene、Choice 等）
├── GameGenerator.cs            # 游戏包生成器（3 风格 × 3 难度）
├── GamePackageValidator.cs     # 校验器（15 类规则 + SHA-256 checksum）
├── InMemoryGameStore.cs        # Mock 内存存储 + 黄金游戏包
├── MongoGameStore.cs           # MongoDB 持久化存储 + 启动恢复
├── PlanGraphClient.cs          # PlanGraph 读取客户端（§7.3.1 URGENT）
├── Narrative/                  # 叙事生成（§7.3.2）
│   ├── NarrativeGenerationService.cs   # 叙事生成编排（骨架 + 模型重写 + 降级）
│   ├── DeepSeekNarrativeClient.cs       # OpenAI 兼容端点调用（DeepSeek）
│   ├── NarrativePromptBuilder.cs        # Prompt 构建 + 修复引导
│   ├── NarrativeDraftValidator.cs       # 草稿校验 + 字段合并
│   └── NarrativeGenerationOptions.cs    # 配置选项
├── GalGame.GalGameService.csproj
├── Dockerfile
├── appsettings.json
├── appsettings.Development.json
├── schema/
│   └── game-package-1.0.schema.json  # schema 1.0 结构契约（draft-07，§7.5 冻结）
├── mocks/
│   ├── golden.json                    # 黄金游戏包（§12.1）
│   ├── campus-standard.json           # 风格包 ×3
│   ├── fantasy-advanced.json
│   ├── science-basic.json
│   ├── invalid-toplevel.json          # 故意错误包 ×6（§12.1 错误包，负向夹具）
│   ├── invalid-scene-structure.json
│   ├── invalid-dialogue.json
│   ├── invalid-choice.json
│   ├── invalid-question-binding.json
│   ├── invalid-assets.json
│   └── preview.html
└── Tests/
    ├── GalGame.GalGameService.Tests.csproj
    ├── GamePackageValidatorTests.cs      # 校验器测试
    ├── GameGeneratorTests.cs             # 生成器测试
    ├── GameGeneratorEnhancementTests.cs   # 生成质量增强测试
    ├── PlanGraphClientTests.cs           # PlanGraph 客户端测试
    ├── MockDataTests.cs                  # mock 数据场景逻辑与计分规则
    ├── UserInteractionSimulationTests.cs # 用户交互模拟与得分验证
    ├── BoundaryTests.cs                  # 边界输入（特殊字符/超长文本）
    ├── GalGameServiceIntegrationTests.cs # WebApplicationFactory 集成测试
    ├── InMemoryGameStoreTests.cs         # 内存存储测试
    ├── MongoGameStoreTests.cs            # MongoDB 存储测试
    ├── InvalidPackageTests.cs            # 错误包负向测试（精确错误码断言）
    └── GamePackageSchemaTests.cs         # JSON Schema 契约测试
```

## 校验夹具与 Schema（§7.5 / §12.1）

`@F15EX` 契约交付三件套：黄金包、错误包、校验器。

- **校验器**：`GamePackageValidator`，15 类规则，可由 GalGameService 和 RenderService 共同运行。
- **JSON Schema**：`schema/game-package-1.0.schema.json`（draft-07）冻结结构与字段级约束
  （数量上限、枚举、UUID 格式、`additionalProperties=false`）。跨字段语义规则由校验器在运行时
  强制，二者互补。Schema 可被 RenderService / CI / 前端在反序列化前做廉价预检。
- **错误包**：`mocks/invalid-*.json` 共 6 个，每个聚焦一类错误聚类，覆盖全部 29 个错误码分支：

| 文件 | 覆盖错误码 |
|---|---|
| `invalid-toplevel.json` | `INVALID_SCHEMA_VERSION` / `INVALID_PACKAGE_ID` / `MISSING_GENERATOR_VERSION` / `INVALID_REVIEW_PLAN_ID` / `MISSING_SNAPSHOT_VERSION` |
| `invalid-scene-structure.json` | `DUPLICATE_SCENE_ID` / `EMPTY_SCENE_ID` / `ENTRY_SCENE_NOT_FOUND` |
| `invalid-dialogue.json` | `EMPTY_DIALOGUE_FIELD` / `NULL_ELEMENT` |
| `invalid-choice.json` | `DUPLICATE_CHOICE_ID` / `INVALID_SCORE_DELTA` / `EMPTY_CHOICE_FIELD` / `INVALID_NEXT_SCENE` / `NULL_ELEMENT` |
| `invalid-question-binding.json` | `MULTIPLE_CORRECT_CHOICES` / `NO_CORRECT_CHOICE` / `ORPHAN_QUESTION_BINDING` / `QUESTION_POINT_MISMATCH` / `QUESTION_BINDING_MISSING_QUESTION_ID` / `EMPTY_BINDING_FIELD` / `NULL_ELEMENT` |
| `invalid-assets.json` | `DUPLICATE_ASSET_ID` / `EMPTY_ASSET_FIELD` / `NULL_ELEMENT` |

数量超限（101 场景 / 201 对话 / 7 选项）与 `null` 包由 `InvalidPackageTests.cs` 程序化构造，
不入静态 JSON。OWNER-TBD 六项决策见 `docs/galgame-owner-tbd.md`。

## 核心设计

### 1. PlanGraph 消费（§7.3.1 URGENT）

`POST /api/v1/game-generations` 在返回 202 之前**同步**经 Gateway 读取 PlanGraph：

- `snapshotVersion` 不匹配 → `422 REVIEW_PLAN_SNAPSHOT_MISMATCH`
- `reviewPlanId` 不存在 → `422 REVIEW_PLAN_NOT_FOUND`
- 上游不可用 → `503 SERVICE_UNAVAILABLE`
- 校验通过 → `202 Accepted`，后台异步生成游戏包

### 2. 游戏包生成

`GameGenerator` 从 PlanGraph 生成符合 schema 1.0 的 GamePackage：

- 仅为 `PlanNode.questionTarget=true` 的节点生成计分题目
- `questionId` 确定性生成并编码为 UUID v4（相同 pointId + seed → 相同 questionId）
- 3 种剧情风格：CAMPUS（校园）、FANTASY（奇幻）、SCIENCE（科幻）
- 3 种难度：BASIC（4 选项）、STANDARD（4 选项）、ADVANCED（3 选项）
- 场景序列：开场 → 知识点讲解 → 题目 → 结束

`purpose=QUESTION` 场景中的选项显式携带题型与正确性。`scoreDelta` 只表示游戏内分数变化，
判题以 `correct` 为准，不能根据分数推断答案正确性或知识点掌握度：

```json
{
  "choiceId": "c-scene-003-correct",
  "questionId": "0aeb0c5d-4e43-485e-9af0-79e0ddc902a0",
  "answerKind": "CHOICE",
  "correct": true,
  "scoreDelta": 1,
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
}
```

### 3. 校验器

`GamePackageValidator` 实现 12 类校验规则，可由 GalGameService 和 RenderService 共同运行：

- schemaVersion / packageId / generatorVersion / reviewPlanId / snapshotVersion
- 场景数量、sceneId 唯一性、entrySceneId 存在性
- 对话字段、选项字段、nextSceneId 引用有效性
- questionId 跨场景唯一性 + 知识点绑定一致性
- QUESTION 绑定的 questionId 必填 + 孤儿检测
- assetId 唯一性

## 本地运行

### 开发模式

```bash
# 设置环境变量
export MOONSTONE_MODE=Mock
export Gateway__ServiceKey=moonstone-local-gateway-key

# 运行
dotnet run --project backend/GalGameService/GalGame.GalGameService.csproj
```

### Docker

```bash
# 启动核心服务（含 GalGameService）
docker compose up -d --build

# 对外入口为 Gateway；GalGameService 在 compose 网络内使用 5105 端口
http://localhost:5000/readyz
```

### 测试

```bash
dotnet test backend/GalGameService/Tests/GalGame.GalGameService.Tests.csproj
```

## Mock 模式

`MOONSTONE_MODE=Mock` 时：

- 使用 `InMemoryGameStore` 存储任务和游戏包
- `PlanGraphClient` 返回内置 PlanGraph（无需 KnowledgeService）
- 启动时预置黄金游戏包（`f2561bb2-b88c-47ef-b0ae-8f283ff64f1b`）
- 默认 Mock 保持下表冻结的 `reviewPlanId`、`snapshotVersion` 与 `ownerUserId` 校验。用于全链路页面联调时，可显式设置 `GalGameMock:UseFixedStory=true`：服务仍校验请求字段和可信用户身份，但以当前请求的计划、快照和用户归属封装内置图谱，忽略上传资料、`style`、`difficulty`、`locale` 与 `seed` 对叙事文本的影响，始终生成同一套原创演示剧情《雾岚町的夏祭前夜》。
- 演示包固定为四个场景：夏祭前夜 → 温室讲解 → 风铃谜题 → 夏祭灯火。每次生成仍创建新的 `packageId`，任务、包所有者与权限校验不会被 Mock 绕过。
- Mock 不调用外部叙事模型，也不读取或依赖前端上传文件、FileService 或 KnowledgeService。

### Mock 测试数据

| 参数 | 值 |
|---|---|
| reviewPlanId | `8e812950-3311-40a7-93ab-636409df8cc2` |
| snapshotVersion | `plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620` |
| goldenPackageId | `f2561bb2-b88c-47ef-b0ae-8f283ff64f1b` |
| goldenQuestionId | `6428a20a-66dd-44c9-944f-d7b36fa9c95a` |
| knowledgePointId | `d1adc45a-52db-4de2-9cf7-02e1ac0d53cb` |
| ownerUserId | `7bc4918a-9079-4ea2-9e8e-369ad79a9f20` |

## 经 Gateway 调用

公共接口使用用户访问令牌；调用方不能自行发送 `X-User-Id` 或 `X-Gateway-Key`。服务间接口同样先进入
Gateway，由 Gateway 校验源服务密钥后再为 GalGameService 注入受信请求头。

```bash
export GATEWAY_BASE_URL=http://localhost:5000
export ACCESS_TOKEN='<access-token>'
export REVIEW_PLAN_ID='<review-plan-id>'
export SNAPSHOT_VERSION='plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620'
export RENDER_SERVICE_KEY='<render-service-key>'

# 创建生成任务
curl -s -X POST "$GATEWAY_BASE_URL/api/v1/game-generations" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewPlanId": "'"$REVIEW_PLAN_ID"'",
    "snapshotVersion": "'"$SNAPSHOT_VERSION"'",
    "style": "CAMPUS",
    "difficulty": "STANDARD",
    "locale": "zh-CN",
    "seed": 42
  }'

# 校验游戏包（服务间）
curl -s -X POST "$GATEWAY_BASE_URL/internal/v1/game-package-validations" \
  -H "X-Service-Name: RenderService" \
  -H "X-Service-Key: $RENDER_SERVICE_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @game-package-validation.json
```

若只启动单个 GalGameService 并使用 `MOONSTONE_MODE=Mock`，可以直接访问 `localhost:5105`
排查服务内部行为；这种方式绕过 Gateway，仅限本机调试，不是集成或部署调用方式。
