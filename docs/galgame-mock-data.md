# GalGameService Mock 数据确认文档

> 负责人：`@F15EX`  
> 更新时间：2026-08-02  
> 契约依据：`docs/contract.md` §7.3、§7.3.1、§7.4；`docs/galgame-owner-tmd.md`（决策冻结）；`backend/GalGameService/schema/game-package-1.0.schema.json`

## 1. 文档目的

确认 GalGameService 的 Mock 游戏包数据已按当前冻结契约生成，**已通过校验器与 JSON Schema 双重校验**，可供 RenderService（`@Zopiclone`）、前端适配器（`@甲烷`）和端到端测试直接使用。

## 2. Mock 数据清单

| 文件 | 风格 | 难度 | 场景数 | packageId | 说明 |
|---|---|---|---|---|---|
| `mocks/golden.json` | — | — | 1 | `f2561bb2-…` | 黄金包（§7.4 契约最小 Mock） |
| `mocks/campus-standard.json` | CAMPUS | STANDARD | 4 | `6a21ca47-…` | 校园风格，标准难度 |
| `mocks/fantasy-advanced.json` | FANTASY | ADVANCED | 4 | `868d08a0-…` | 奇幻风格，高级难度 |
| `mocks/science-basic.json` | SCIENCE | BASIC | 4 | `60689f72-…` | 科幻风格，基础难度 |
| `mocks/invalid-*.json` × 6 | — | — | — | — | 故意错误的负向测试夹具，预期校验失败 |

## 3. 数据来源

| 字段 | 值 | 说明 |
|---|---|---|
| 生成器版本 | `gala-0.1.0` | 与 golden 及内部默认相同 |
| reviewPlanId | `8e812950-3311-40a7-93ab-636409df8cc2` | Mock 模式内置 |
| snapshotVersion | `plan-graph-1.0:3da5f48f` | 不变计划快照 |
| 目标知识点 (TARGET) | `d1adc45a-52db-4de2-9cf7-02e1ac0d53cb` | 水稻分蘖期管理（`questionTarget=true`） |
| 前置知识点 (PREREQUISITE) | `84f7d873-e573-4689-b18d-6f82c745d1bf` | 水稻基本生长曲线 |

三个风格包从同一知识来源生成；`QUESTION` 场景的 `questionId` 与黄金包一致（`6428a20a-…`），便于跨包证据比对。

## 4. 场景结构与 questionId 语义

每个完整包按 4 场景线性推进，绑定/选项的 `questionId` 规则如下：

```
scene-001 开场（Entry）
  ├─ 选项：导航 → scene-002（questionId 为 UUID v4，但不绑定为 QUESTION）
  ├─ knowledgeBindings: FEEDBACK（questionId = null）
  └─ 说明：入场引导，题干尚未出现，绑定仅标记知识点预告

scene-002 讲解（EXPLAIN）
  ├─ 选项：导航 → scene-003
  ├─ knowledgeBindings: EXPLAIN（questionId = null）
  └─ 说明：回顾前置，不构造可控答题证据

scene-003 计分题（QUESTION）
  ├─ 选项：1 个 scoreDelta=1 正确项 + 干扰项（scoreDelta=0）→ scene-004
  ├─ knowledgeBindings: QUESTION（questionId 必填为 UUID v4，包内唯一）
  └─ 同一题的所有 choices 使用相同 questionId

scene-004 结束（Ending）
  ├─ 选项：无
  └─ knowledgeBindings：无
```

**questionId 绑定规则**（contract §7.3）：
- `purpose=QUESTION` → `questionId` 必填，包内唯一且稳定；同一题的多个 choices 共用同一个 `questionId`。
- `purpose=EXPLAIN` / `FEEDBACK` → `questionId = null`；对应的场景/讲解与知识点仅做叙述关联，不参与计分题的证据链。

## 5. 风格差异

| 风格 | 引导角色 | 开场场景 | 场景主题 |
|---|---|---|---|
| CAMPUS | 林学姐 | 图书馆的自习时光 | 校园日常，亲切鼓励 |
| FANTASY | 精灵导师艾莉娅 | 魔法学院的试炼 | 奇幻冒险，神秘庄重 |
| SCIENCE | NEXUS | 空间站知识模块 | 科幻未来，理性冷静 |

## 6. 难度差异

| 难度 | 选项总数 | 干扰项数 | 题干措辞 |
|---|---|---|---|
| BASIC | 4 | 3 | 「以下哪个说法是正确的？」 |
| STANDARD | 4 | 3 | 「最准确的描述是？」 |
| ADVANCED | 3 | 2 | 「最符合实际的？」 |

## 7. 关键字段示例

### 7.1 对话行（DialogueLine）

```json
{
  "speakerId": "林学姐",
  "text": "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。",
  "emotion": "explaining"
}
```

### 7.2 导航选项（非计分，如 scene-001）

```json
{
  "choiceId": "c-scene-001-1",
  "questionId": "3f8b1a9e-5c7d-4a2f-8b6e-c9d1e2f3a495",
  "text": "准备好了，开始吧！",
  "nextSceneId": "scene-002",
  "scoreDelta": 0,
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
}
```

导航选项的 `questionId` 是功能合规的 `Uuid`（UUID v4 格式，结构必需），但 `scoreDelta=0` 起导航作用，不记入学习证据。

### 7.3 计分题正确选项（如 scene-003）

```json
{
  "choiceId": "c-scene-003-correct",
  "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
  "text": "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖",
  "nextSceneId": "scene-004",
  "scoreDelta": 1,
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
}
```

### 7.4 知识绑定 — QUESTION（必填 questionId）

```json
{
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
  "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
  "purpose": "QUESTION"
}
```

### 7.5 知识绑定 — EXPLAIN / FEEDBACK（questionId = null）

```json
{
  "knowledgePointId": "84f7d873-e573-4689-b18d-6f82c745d1bf",
  "questionId": null,
  "purpose": "EXPLAIN"
}
```

## 8. 校验状态

全部 4 个有效包通过 [JSON Schema draft-07](schema/game-package-1.0.schema.json) 与 `GamePackageValidator` 的运行时校验（`valid: true`）。

校验器对结构字段和跨场景语义的检查（`ValidationIssue.code` 顺序与实现对应）：

**顶层结构**
- [x] `schemaVersion === "1.0"`
- [x] `packageId` / `reviewPlanId` 非空 GUID
- [x] `generatorVersion`、`snapshotVersion` 非空
- [x] `entrySceneId` 指向存在的场景
- [x] `scenes.length` ≥ 1 且 ≤ 100

**场景**
- [x] `sceneId` 非空白且包内唯一
- [x] `dialogue` 非空数组（1–200 行），行内 `speakerId`/`text` 非空白
- [x] `choices` 0–6 个

**选项**
- [x] `choiceId`/`text`/`questionId`/`knowledgePointId` 非空
- [x] `scoreDelta` ∈ `{0, 1}`
- [x] `nextSceneId` 若非空则指向存在的场景

**跨场景一致性**
- [x] 同一 `questionId` 在不同 choices 中绑定的 `knowledgePointId` 一致
- [x] `QUESTION` 绑定的 `questionId` 至少出现在一个 choice 中（无孤儿绑定）
- [x] 每个计分题恰好 1 个 `scoreDelta > 0` 的选项（`MULTIPLE_CORRECT_CHOICES` / `NO_CORRECT_CHOICE`）

**知识绑定**
- [x] `knowledgePointId` 非空 GUID
- [x] `purpose=QUESTION` 的绑定必须提供 `questionId`；`EXPLAIN`/`FEEDBACK` 允许 `questionId=null`

**资源**
- [x] `assetId` 包内唯一
- [x] `uri` 非空

**负向测试**：`invalid-*.json` 六个夹具预期校验失败，覆盖场景结构、选项、对话、知识绑定和资源引用的缺陷场景。

## 9. scoreDelta 与掌握度证据的边界

`scoreDelta` 是**游戏内计分**（contract §6.4、§8.2.1）：0（干扰/导航）或 1（正确）。运行时（RenderService / WASM）通过用户交互后的 `correct` 和 `quality(0-5)` 判断答题正确性，**不得从 scoreDelta 推导掌握度**。掌握度证据的正确域由 `AnswerResult`（RenderService）按 §8.2.1 独立提交，由 KnowledgeService 按 §6.4 校验。

## 10. 使用方式

### 预览（仅本地调试）

```bash
# 直接浏览器打开静态预览页（不进 Gateway、不连后端）
# 或者把 mock JSON 交给 RenderService 的热载入口

open mocks/preview.html
```

### 通过 API Gateway 调用（生产/集成链路）

经 Gateway `GET /api/v1/game-packages/{packageId}/content` 读取游戏包内容。**仅用于联调验证**；`localhost:5105` 直连是本地调试便利，不代表生产路径（生产路由走 Gateway，禁止拼接服务直连地址）。

```bash
curl "http://localhost:5105/api/v1/game-packages/6a21ca47-a7c1-4eac-b8cf-a4a5d8d63784/content" \
  -H "X-Gateway-Key: moonstone-local-gateway-key" \
  -H "X-User-Id: 7bc4918a-9079-4ea2-9e8e-369ad79a9f20"
```

## 11. 后续维护约束

- 修改 mock 后必须同步通过 `GamePackageValidator`、`MockDataTests`、`GamePackageSchemaTests`。
- Mock 数据结构变化需同步更新 `schema/game-package-1.0.schema.json` 的同名字段约束。
- `questionId` 规则变化需同步本文档 §4 语义描述。
