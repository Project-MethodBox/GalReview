# GalGameService Mock 数据确认文档

> 负责人：`@F15EX`
> 更新时间：2026-08-01
> 契约依据：`docs/contract.md` §7.4 最小游戏包 Mock

## 1. 文档目的

本文档确认 GalGameService 的 Mock 游戏包数据已生成并通过校验，可供 RenderService、前端适配器和端到端测试直接使用。

## 2. Mock 数据清单

所有 JSON 文件位于 `backend/GalGameService/mocks/` 目录：

| 文件 | 风格 | 难度 | 场景数 | 说明 |
|---|---|---|---|---|
| `golden.json` | — | — | 1 | 黄金游戏包（§7.4 契约 Mock，最小化） |
| `campus-standard.json` | CAMPUS | STANDARD | 4 | 校园风格，标准难度 |
| `fantasy-advanced.json` | FANTASY | ADVANCED | 4 | 奇幻风格，高级难度 |
| `science-basic.json` | SCIENCE | BASIC | 4 | 科幻风格，基础难度 |

## 3. 数据来源

- 生成器版本：`gala-0.1.0`
- PlanGraph 来源：Mock 模式内置（`reviewPlanId=8e812950-3311-40a7-93ab-636409df8cc2`，`snapshotVersion=plan-graph-1.0:3da5f48f`）
- 知识点：水稻基本生长周期（前置）+ 水稻分蘖期管理（目标）

## 4. 场景结构

每个完整游戏包包含 4 个场景，按以下顺序排列：

```
scene-001  开场场景（Entry）
  ├─ 对话：引导角色介绍复习主题
  ├─ 选项：「准备好了，开始吧！」→ scene-002
  └─ 绑定：FEEDBACK

scene-002  知识点讲解（Explain）
  ├─ 对话：回顾前置知识点
  ├─ 选项：「了解了，继续。」→ scene-003
  └─ 绑定：EXPLAIN

scene-003  复习题（Question）
  ├─ 对话：出题引导 + 题干
  ├─ 选项：1 个正确 + 2~3 个干扰项 → scene-004
  └─ 绑定：QUESTION（计分）

scene-004  结束场景（Ending）
  ├─ 对话：总结 + 鼓励
  ├─ 选项：无
  └─ 绑定：无
```

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

### 7.2 选项（Choice）

```json
{
  "choiceId": "c-scene-003-correct",
  "questionId": "0aeb0c5d-4e43-885e-9af0-79e0ddc902a0",
  "text": "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖",
  "nextSceneId": "scene-004",
  "scoreDelta": 1,
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
}
```

### 7.3 知识绑定（KnowledgeBinding）

```json
{
  "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
  "questionId": "0aeb0c5d-4e43-885e-9af0-79e0ddc902a0",
  "purpose": "QUESTION"
}
```

## 8. 校验状态

所有 mock 游戏包均已通过 `GamePackageValidator` 校验（`valid: true`）：

- [x] `schemaVersion = "1.0"`
- [x] `packageId` 非空 GUID
- [x] `entrySceneId` 指向存在的场景
- [x] 场景 ID 唯一
- [x] 对话字段非空
- [x] 选项字段非空
- [x] `nextSceneId` 引用有效
- [x] `questionId` 跨场景一致
- [x] 每题恰好 1 个 `scoreDelta > 0` 的正确选项
- [x] `QUESTION` 绑定的 `questionId` 在 choices 中出现
- [x] `ScoreDelta` 只为 0 或 1

## 9. 使用方式

### 渲染器预览

```bash
# 用浏览器打开渲染器
open backend/GalGameService/mocks/preview.html
```

### API 获取

```bash
# 启动服务后获取游戏包内容
curl http://localhost:5105/api/v1/game-packages/{packageId}/content \
  -H "X-Gateway-Key: moonstone-local-gateway-key" \
  -H "X-User-Id: 7bc4918a-9079-4ea2-9e8e-369ad79a9f20"
```

### 渲染器集成

RenderService 或前端适配器可直接加载 JSON 文件，按 `entrySceneId` 进入，通过 `choice.nextSceneId` 导航，按 `choice.scoreDelta` 计分。
