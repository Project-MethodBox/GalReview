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
| `POST` | `/internal/v1/game-package-validations` | 校验游戏包（服务间） | `200/400/403` |
| `GET` | `/healthz` | 存活探针 | `200` |
| `GET` | `/readyz` | 就绪探针 | `200` |

## 文件结构

```
GalGameService/
├── Program.cs                  # 服务入口：中间件链 + 5 个端点
├── Contracts.cs                # 数据类型（GamePackage、Scene、Choice 等）
├── GameGenerator.cs            # 游戏包生成器（3 风格 × 3 难度）
├── GamePackageValidator.cs     # 校验器（12 类规则 + SHA-256 checksum）
├── InMemoryGameStore.cs        # Mock 内存存储 + 黄金游戏包
├── PlanGraphClient.cs          # PlanGraph 读取客户端（§7.3.1 URGENT）
├── GalGame.GalGameService.csproj
├── Dockerfile
├── appsettings.json
├── appsettings.Development.json
└── Tests/
    ├── GalGame.GalGameService.Tests.csproj
    ├── GamePackageValidatorTests.cs   # 14 个校验器测试
    ├── GameGeneratorTests.cs          # 16 个生成器测试
    └── PlanGraphClientTests.cs        # 4 个 PlanGraph 客户端测试
```

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
- `questionId` 使用 UUID v5 确定性生成（相同 pointId + seed → 相同 questionId）
- 3 种剧情风格：CAMPUS（校园）、FANTASY（奇幻）、SCIENCE（科幻）
- 3 种难度：BASIC（4 选项）、STANDARD（4 选项）、ADVANCED（3 选项）
- 场景序列：开场 → 知识点讲解 → 题目 → 结束

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

# 服务地址
http://localhost:5105/readyz
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

### Mock 测试数据

| 参数 | 值 |
|---|---|
| reviewPlanId | `8e812950-3311-40a7-93ab-636409df8cc2` |
| snapshotVersion | `plan-graph-1.0:3da5f48f` |
| goldenPackageId | `f2561bb2-b88c-47ef-b0ae-8f283ff64f1b` |
| goldenQuestionId | `6428a20a-66dd-44c9-944f-d7b36fa9c95a` |
| knowledgePointId | `d1adc45a-52db-4de2-9cf7-02e1ac0d53cb` |
| ownerUserId | `7bc4918a-9079-4ea2-9e8e-369ad79a9f20` |

## 冒烟测试示例

```bash
# 读取黄金游戏包清单
curl -s http://localhost:5105/api/v1/game-packages/f2561bb2-b88c-47ef-b0ae-8f283ff64f1b \
  -H "X-Gateway-Key: moonstone-local-gateway-key" \
  -H "X-User-Id: 7bc4918a-9079-4ea2-9e8e-369ad79a9f20"

# 创建生成任务（Mock 模式）
curl -s -X POST http://localhost:5105/api/v1/game-generations \
  -H "X-Gateway-Key: moonstone-local-gateway-key" \
  -H "X-User-Id: 7bc4918a-9079-4ea2-9e8e-369ad79a9f20" \
  -H "Content-Type: application/json" \
  -d '{
    "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
    "snapshotVersion": "plan-graph-1.0:3da5f48f",
    "style": "CAMPUS",
    "difficulty": "STANDARD",
    "locale": "zh-CN",
    "seed": 42
  }'

# 校验游戏包（服务间）
curl -s -X POST http://localhost:5105/internal/v1/game-package-validations \
  -H "X-Gateway-Key: moonstone-local-gateway-key" \
  -H "X-Service-Name: RenderService" \
  -H "Content-Type: application/json" \
  -d '{"package": { ... }}'
```
