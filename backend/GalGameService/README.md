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
- 使用 MiMo v2.5 TTS 为非玩家角色生成逐句语音，并随游戏包持久化

## 端点

| 方法 | 路由 | 用途 | 状态码 |
|---|---|---|---|
| `POST` | `/api/v1/game-generations` | 创建游戏包生成任务 | `202/400/401/422/503` |
| `GET` | `/api/v1/game-generations/{generationId}` | 查询生成任务 | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}` | 读取游戏包清单 | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}/content` | 下载完整 JSON | `200/304/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}/audio/{assetId}` | 读取游戏包内的角色语音（支持 Range） | `200/206/400/401/404/416` |
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
├── Voice/                      # 角色语音合成
│   ├── MiMoTtsClient.cs                 # MiMo v2.5 TTS HTTP 客户端
│   ├── PackageVoiceService.cs           # 逐句合成、资源编号与失败降级
│   └── VoiceSynthesisOptions.cs         # TTS 配置选项
├── character-voice-config.json # 剧情角色、声线、情绪与说话风格配置
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
    ├── MiMoTtsClientTests.cs             # MiMo 请求、响应、重试与边界测试
    ├── PackageVoiceServiceTests.cs       # 角色过滤、资源编号与部分失败测试
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

### 4. MiMo v2.5 TTS 角色语音

非 Mock 模式下，游戏包完成叙事生成后会进入 `PackageVoiceService`。服务按场景、对白顺序为符合条件的台词调用
`mimo-v2.5-tts`，输出 WAV 音频并写入当前 `IGameStore`：Memory Provider 保存在进程内存中，MongoDB Provider
保存在 `game_audio` 集合中。音频字节不会内嵌到游戏包 JSON，包内只保存资源引用。

语音生成流程：

1. 遍历 `scenes[].dialogue[]`，忽略空台词和 `excludedSpeakers` 中的说话人。
2. 从 `character-voice-config.json` 解析角色的 MiMo 预设声线与提示词，并叠加当前对白的 `emotion` 指令。
3. 调用 MiMo 的 OpenAI 兼容端点，读取 `choices[0].message.audio.data` 中的 Base64 WAV。
4. 使用确定性编号 `voice-{sceneIndex:000}-{lineIndex:000}` 保存音频，并向 `assets[]` 追加 `AUDIO` 引用。
5. 前端按同一编号找到当前对白的音频资源，经 Gateway 携带 Bearer Token 下载，并使用 Blob URL 播放。

游戏包中的资源示例：

```json
{
  "assetId": "voice-001-003",
  "type": "AUDIO",
  "uri": "/api/v1/game-packages/4c8f72f8-0ddd-4f65-81e3-a245488ecdee/audio/voice-001-003"
}
```

语音资源沿用游戏包的用户归属校验：未认证返回 `401`，无权访问与资源不存在统一返回 `404`，避免泄露包是否存在。
响应为 `audio/wav`，支持字节范围请求，并使用 `private, max-age=31536000, immutable` 缓存策略。

单句合成失败不会让整个游戏包生成失败。网络错误、超时、`429`、服务端错误、无效 JSON/Base64 或音频超限会按配置重试；
最终仍失败时记录 Warning 并跳过该句，因此一个成功的游戏包可能只有部分语音或完全没有语音。调用方必须把语音视为可选增强，
没有匹配的 `AUDIO` 资源时继续显示文字。

#### 角色声音设置

所有角色声音与说话风格统一维护在 `character-voice-config.json`：

- `styles`：每种剧情风格允许出现的角色、引导角色和玩家对白约束。
- `excludedSpeakers`：不合成语音的说话人，当前包括玩家“你”、旁白和 `narrator`。
- `characters.<角色名>.voice`：传给 MiMo 的预设声线，例如 `茉莉`、`苏打`、`冰糖`、`白桃`。
- `characters.<角色名>.direction`：仅用于 TTS 的音色、年龄、语速和气质描述。
- `characters.<角色名>.narrativeDirection`：用于剧情模型保持角色说话风格，不直接作为语音文本朗读。
- `emotionDirections`：将对白中的情绪标记转换成语速、语气和节奏提示。
- `fallbackVoice`：遇到未配置角色时使用的默认声线；角色名仅参与提示，不会被朗读。

配置文件在启动时严格校验，并由项目文件复制到构建与发布目录。`styles` 中所有需要语音的角色都必须同时存在有效的
`voice` 和 `narrativeDirection`，否则服务会在启动阶段失败，避免生成过程中静默使用错误角色设定。

## 配置

### MiMo TTS

`VoiceSynthesis` 支持写入 `appsettings.json`、`appsettings.Development.json`，也支持标准 .NET 环境变量。
当 `VoiceSynthesis:ApiKey` 为空时，程序还会回退读取 `MIMO_API_KEY`。共享仓库与生产环境建议使用环境变量或 Secret，
不要提交真实密钥。

```json
{
  "VoiceSynthesis": {
    "Enabled": true,
    "Endpoint": "https://api.xiaomimimo.com/v1/chat/completions",
    "Model": "mimo-v2.5-tts",
    "ApiKey": "<mimo-api-key>",
    "TimeoutSeconds": 90,
    "MaxConcurrency": 2,
    "MaxAttempts": 3,
    "RetryBaseDelayMilliseconds": 500,
    "MaxTextCharacters": 2000,
    "MaxAudioBytes": 8388608
  }
}
```

| 配置项 | 默认值 | 说明 |
|---|---:|---|
| `Enabled` | `true` | 是否请求外部 TTS；Mock 模式会强制关闭 |
| `Endpoint` | MiMo Chat Completions 地址 | 必须是 HTTPS |
| `Model` | `mimo-v2.5-tts` | 当前实现只启用该模型名 |
| `ApiKey` | 空 | 可直接配置；为空时读取 `MIMO_API_KEY` |
| `TimeoutSeconds` | `90` | 单次请求超时，运行时限制在 10–300 秒 |
| `MaxConcurrency` | `2` | 同一游戏包的并发合成数，运行时限制在 1–6 |
| `MaxAttempts` | `3` | 每句最大尝试次数，运行时限制在 1–4 |
| `RetryBaseDelayMilliseconds` | `500` | 指数退避基础延迟，最大单次延迟 5 秒 |
| `MaxTextCharacters` | `2000` | 单句文本长度上限，运行时最大 10000 |
| `MaxAudioBytes` | `8388608` | 单句解码后音频大小上限，运行时最大 12 MiB |

TTS 只有在 `Enabled=true`、密钥非空、模型名为 `mimo-v2.5-tts` 且 Endpoint 为 HTTPS 时才会启用。
启动日志会输出最终启用状态和并发数；配置不完整时服务仍可启动，但游戏包不会包含语音。

Compose 使用以下环境变量映射上述配置：

| 环境变量 | 对应配置 |
|---|---|
| `GALGAME_VOICE_ENABLED` | `VoiceSynthesis:Enabled` |
| `MIMO_API_KEY` | `VoiceSynthesis:ApiKey` |
| `MIMO_TTS_ENDPOINT` | `VoiceSynthesis:Endpoint` |
| `MIMO_TTS_MAX_CONCURRENCY` | `VoiceSynthesis:MaxConcurrency` |

也可以直接使用标准 .NET 双下划线形式，例如 `VoiceSynthesis__ApiKey`、`VoiceSynthesis__TimeoutSeconds`。

## 本地运行

### 开发模式

```bash
# 设置环境变量
export MOONSTONE_MODE=Mock
export Gateway__ServiceKey=moonstone-local-gateway-key

# 运行
dotnet run --project backend/GalGameService/GalGame.GalGameService.csproj
```

上面的 Mock 模式会强制关闭外部叙事模型和 MiMo TTS。需要验证真实语音链路时，应启动完整的非 Mock 服务依赖，并提供密钥：

```powershell
$env:Gateway__ServiceKey = "moonstone-local-gateway-key"
$env:MIMO_API_KEY = "<mimo-api-key>"
$env:VoiceSynthesis__Enabled = "true"
dotnet run --project backend/GalGameService/GalGame.GalGameService.csproj
```

也可以将 `ApiKey` 写入本机的 `appsettings.Development.json`。如果使用共享配置文件，请确认不会把真实密钥提交到版本库。

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
- Mock 强制关闭 MiMo TTS，不生成或保存角色语音资源；验证语音必须使用非 Mock 模式。

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

# 下载游戏包中 assets[] 引用的一条角色语音
export PACKAGE_ID='<package-id>'
export AUDIO_ASSET_ID='voice-001-003'
curl -s \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$GATEWAY_BASE_URL/api/v1/game-packages/$PACKAGE_ID/audio/$AUDIO_ASSET_ID" \
  --output dialogue.wav

# 校验游戏包（服务间）
curl -s -X POST "$GATEWAY_BASE_URL/internal/v1/game-package-validations" \
  -H "X-Service-Name: RenderService" \
  -H "X-Service-Key: $RENDER_SERVICE_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @game-package-validation.json
```

若只启动单个 GalGameService 并使用 `MOONSTONE_MODE=Mock`，可以直接访问 `localhost:5105`
排查服务内部行为；这种方式绕过 Gateway，仅限本机调试，不是集成或部署调用方式。
