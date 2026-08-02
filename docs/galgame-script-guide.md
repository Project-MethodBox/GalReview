# GalGame 脚本创作指南

> 基于 `game-package-1.0.schema.json`、`GameGenerator.cs`、`GamePackageValidator.cs` 与 `docs/contract.md` §7 的完整创作规范
> 适用版本：schema 1.0 / generator gala-0.1.0

## 一、项目概述

**千知万理（GalReview）** 是一款游戏化复习应用。用户上传课程讲义、题库等资料，系统根据知识点生成 GalGame 剧情体验，玩家在对话和选择中完成复习。

GalGame 脚本的本质是一份 **JSON 游戏包（GamePackage）**，包含若干场景（Scene），每个场景有对话（Dialogue）和选项（Choice），通过知识绑定（KnowledgeBinding）将游戏内容与学习知识点关联。

### 核心数据流

```
用户上传资料 → OCRService 识别 → KnowledgeService 构建知识图谱(PlanGraph)
  → GalGameService 从 PlanGraph 生成游戏包(JSON)
  → RenderService 加载游戏包 → 玩家在浏览器中体验剧情+答题
  → 作答结果回传 KnowledgeService → 更新知识点掌握度
```

### 生成器工作流（GameGenerator.cs）

`GameGenerator` 从不可变 PlanGraph 生成游戏包，流程如下：

1. **筛选节点**：`QuestionTarget=true` 的节点生成计分题目，其余生成讲解场景
2. **确定性 questionId**：基于 `pointId + seed` 的 SHA-256 哈希，修正为 UUID v4 形状（非 UUID v5）
3. **场景序列**：开场 → (讲解场景 × N) → (题目场景 × M) → 结束
4. **链接场景**：每个场景的 `choice.nextSceneId` 指向下一个场景
5. **自检**：生成后调用 `GamePackageValidator` 验证，失败则抛异常

关键设计：**显式 seed 只保证 questionId、场景顺序与选项顺序稳定**；`packageId` 与 manifest 时间每次重新生成，因此不承诺整个 JSON 或 checksum 字节相同。

## 二、游戏包整体结构

一个游戏包是一个 JSON 文件，顶层字段如下：

```json
{
  "schemaVersion": "1.0",
  "packageId": "UUID v4",
  "generatorVersion": "gala-0.1.0",
  "reviewPlanId": "UUID v4",
  "snapshotVersion": "字符串，知识图谱快照版本",
  "entrySceneId": "scene-001",
  "scenes": [ ... ],
  "assets": [ ... ]
}
```

| 字段 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `schemaVersion` | `"1.0"` | const | 固定值，破坏性变更需升版本 |
| `packageId` | UUID v4 | 非空 GUID | 游戏包唯一标识，空 GUID 被拒绝 |
| `generatorVersion` | string | minLength 1 | 生成器版本，如 `gala-0.1.0` |
| `reviewPlanId` | UUID v4 | 非空 GUID | 来源复习计划 ID |
| `snapshotVersion` | string | minLength 1 | 不可变 PlanGraph 快照版本 |
| `entrySceneId` | string | minLength 1 | 玩家进入的第一个场景 ID，必须指向存在的场景 |
| `scenes` | array | 1~100 | 场景列表 |
| `assets` | array | 可空 | 资源引用列表 |

**`additionalProperties: false`** — 顶层不允许未知字段。所有嵌套对象同样拒绝未知字段。

## 三、场景（Scene）详解

每个场景是剧情的一个"节点"，玩家从 `entrySceneId` 进入，通过选项跳转到下一个场景。

```json
{
  "sceneId": "scene-001",
  "title": "场景标题（可选，可为 null）",
  "dialogue": [ ... ],
  "choices": [ ... ],
  "knowledgeBindings": [ ... ]
}
```

| 字段 | 约束 | 说明 |
|---|---|---|
| `sceneId` | 非空，包内唯一 | 场景标识，如 `scene-001` |
| `title` | string 或 null | 可选标题，格式为 `scene-{序号:D3}` |
| `dialogue` | 1~200 行 | 对话内容，不允许空数组或 null |
| `choices` | 0~6 个 | 选项，空数组表示纯结束场景 |
| `knowledgeBindings` | array | 知识绑定，可空 |

### 场景的五种类型

根据 `knowledgeBindings` 中的 `purpose` 区分：

**1. 开场场景（Entry）** — `purpose: "FEEDBACK"`

引导玩家进入，介绍复习主题。生成器固定生成 2 行对话 + 1 个导航选项。

```
scene-001 开场
  对话：引导角色介绍复习主题
  选项：「准备好了，开始吧！」→ scene-002
  绑定：FEEDBACK
```

**2. 知识讲解场景（Explain）** — `purpose: "EXPLAIN"`

复习前置知识点，不计分。生成器为每个非 `QuestionTarget` 节点生成一个讲解场景。

```
scene-002 讲解
  对话：回顾前置知识点
  选项：「了解了，继续。」→ scene-003
  绑定：EXPLAIN
```

**3. 题目场景（Question）** — `purpose: "QUESTION"`

出题测试，选项计分。这是核心交互场景。生成器为每个 `QuestionTarget` 节点生成一个题目场景。

```
scene-003 题目
  对话：出题引导 + 题干
  选项：1 个正确 + 2~3 个干扰项 → scene-004
  绑定：QUESTION
```

**4. 反馈场景（Feedback）** — `purpose: "FEEDBACK"`（可选）

题目之间的过渡场景，给予玩家反馈和鼓励，不计分。生成器原始流程中不生成此类型，但 schema 支持。完整版脚本中添加了反馈场景以提升体验。

**5. 结束场景（Ending）** — 无绑定

总结复习，无选项，游戏结束。

```
scene-004 结束
  对话：总结 + 鼓励
  选项：空数组
  绑定：空数组
```

## 四、对话行（DialogueLine）

每行对话代表一个角色说的一句话：

```json
{
  "speakerId": "林学姐",
  "text": "水稻从播种到成熟，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。",
  "emotion": "explaining"
}
```

| 字段 | 约束 | 说明 |
|---|---|---|
| `speakerId` | 非空 | 说话人标识 |
| `text` | 非空 | 对话文本，纯空白被拒绝 |
| `emotion` | string 或 null | 可选情绪标签 |

**`additionalProperties: false`** — 不允许未知字段。

### 写对话的要点

- **角色有性格**：林学姐亲切活泼，精灵导师艾莉娅神秘庄重，NEXUS 理性冷静
- **信息融入剧情**：知识点应自然地融入角色对话，而非生硬朗读
- **情绪标签辅助**：`emotion` 帮助渲染引擎切换角色表情/语气
- **对话长度**：生成器为每类场景固定生成 2~3 行对话；手写脚本可适当丰富，但单场景不超过 200 行

常用 `emotion` 值参考（来自 `GameGenerator.cs` 静态模板和 mock 数据）：

| 情境 | emotion 示例 |
|---|---|
| 开心/鼓励 | `cheerful`, `encouraging`, `warm`, `proud` |
| 思考/讲解 | `thoughtful`, `explaining`, `informative` |
| 出题/挑战 | `challenging`, `questioning`, `serious` |
| 神秘/冷静 | `mystical`, `calm`, `serious` |
| 俏皮/轻松 | `playful`, `teasing` |

## 五、选项（Choice）

选项是玩家可点击的按钮。**schema 中所有选项共享相同的必填字段集**，但根据场景类型，`answerKind` 和 `correct` 的使用方式不同。

### 完整字段定义（schema choice 对象）

```json
{
  "choiceId": "c-scene-003-correct",
  "questionId": "UUID v4",
  "text": "选项文本",
  "nextSceneId": "scene-004",
  "scoreDelta": 1,
  "knowledgePointId": "UUID v4",
  "answerKind": "CHOICE",
  "correct": true
}
```

| 字段 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `choiceId` | string | 非空，场景内唯一 | 选项标识 |
| `questionId` | UUID v4 | 非空 | 同题所有选项共享；导航选项也使用确定性 UUID |
| `text` | string | 非空 | 选项文本 |
| `nextSceneId` | string 或 null | — | 目标 sceneId；null 表示结束游戏 |
| `scoreDelta` | number | — | 游戏计分增量；**与 correct 独立** |
| `knowledgePointId` | UUID v4 | 非空 | 绑定知识点 |
| `answerKind` | `"CHOICE"` 或 null | — | QUESTION 场景必须为 `"CHOICE"`；其他场景省略或 null |
| `correct` | boolean 或 null | — | QUESTION 场景必填；其他场景省略或 null |

### 关键规则：scoreDelta 与 correct 的独立性

> **`scoreDelta` 是任意 JSON number，只表示游戏计分。题目选项必须显式携带 `answerKind=CHOICE` 和 `correct`；每题至少有一个 `correct=true`，但不要求恰好一个。**
> **RenderService 和 KnowledgeService 都不得从 `scoreDelta` 推断正确性或掌握度。**

这意味着：
- `scoreDelta` 和 `correct` 是两个独立维度，不能互相推导
- 理论上可以有 `scoreDelta=1, correct=false`（奖励分但不判为正确答案）
- 实际创作中建议保持一致（correct=true → scoreDelta=1, correct=false → scoreDelta=0），避免语义混乱

### 导航选项（非题目场景）

导航选项的 `answerKind` 和 `correct` 省略或为 null。`questionId` 使用生成器的 `NavigationGuid` 函数生成确定性 UUID（基于 sceneId 的 SHA-256 哈希）。

### 题目选项（QUESTION 场景）

- 同一道题的所有选项**共享同一个 `questionId`**
- 每题**至少一个** `correct: true` 的选项
- `choiceId` 在同一场景内唯一，正确选项用 `c-{sceneId}-correct`，干扰项用 `c-{sceneId}-d1`、`c-{sceneId}-d2`...

### 干扰项设计

生成器从两个来源生成干扰项：

1. **其他 PlanNode 的标题**：`ExtractDistractorFromNode(node)` 返回 `node.Title`
2. **通用干扰项池**（按难度）：

| 难度 | 通用干扰项池 |
|---|---|
| BASIC | "以上都不对"、"与题目无关的选项"、"需要更多信息才能判断" |
| STANDARD | "部分正确但不完整"、"方向相反的结论"、"条件不足无法确定" |
| ADVANCED | "看似合理但存在关键缺陷"、"仅适用于特殊情况" |

**创作建议**：手写脚本时，干扰项应使用**实质性的错误知识描述**而非占位文本。好的干扰项应：

1. **来自易混淆知识点**：用前置知识点的错误理解做干扰项
2. **部分正确但不完整**：只说对了一半，遗漏关键条件
3. **方向相反**：管理目标或因果关系颠倒
4. **常见 misconceptions**：学生容易犯的典型错误

示例（分蘖期管理题，STANDARD 难度）：

| 类型 | 选项文本 |
|---|---|
| 正确 | 协调群体数量与个体生长，通过水肥调控促进有效分蘖，控制无效分蘖 |
| 干扰1 | 分蘖期应深水灌溉以促进分蘖芽萌发，水深保持 10cm 以上 |
| 干扰2 | 分蘖期管理的核心是尽早追施大量氮肥，使分蘖数越多越好 |
| 干扰3 | 分蘖期不需要水分管理，保持自然降雨即可 |

## 六、知识绑定（KnowledgeBinding）

知识绑定将场景与知识点关联，是系统追踪学习进度的依据。

```json
{
  "knowledgePointId": "知识点 UUID v4",
  "questionId": "题目 UUID v4（QUESTION 时必填，其他可 null）",
  "purpose": "EXPLAIN | QUESTION | FEEDBACK"
}
```

**`additionalProperties: false`** — 不允许未知字段。

| purpose | 用途 | questionId | 说明 |
|---|---|---|---|
| `EXPLAIN` | 知识点讲解 | 可选 | 标记该场景讲解了哪个知识点 |
| `QUESTION` | 出题测试 | **必填且包内唯一** | 标记该场景测试了哪个知识点 |
| `FEEDBACK` | 反馈/导航 | 可选 | 标记反馈关联的知识点 |

### 关键规则

- 一个场景**至多一个** QUESTION 绑定
- QUESTION 绑定的 `questionId` 必须在该场景的 choices 中出现（孤儿检测）
- `questionId` 在整个游戏包内唯一（跨场景，QUESTION 绑定之间不重复）
- 非 QUESTION 场景的 choices 不能携带 `answerKind`/`correct`
- 导航选项的 `questionId` 使用独立的确定性 UUID，不与题目 UUID 冲突

## 七、场景链接与导航

场景通过 `choices[].nextSceneId` 形成有向图：

```
scene-001 → scene-002 → scene-003 → scene-004
                                      ↓
                                    scene-005 → scene-006 → scene-007 → scene-008(结束)
```

- `nextSceneId` 为 null 表示该选项结束游戏
- `nextSceneId` 非空时必须指向存在的场景（校验器强制）
- 含 QUESTION 绑定的场景必须能从 `entrySceneId` 到达（可达性检测）
- 生成器的 `LinkScenes` 方法将所有场景串成线性链；手写脚本可设计分支

### 典型场景流程

```
最小游戏包（4 场景）：
  Entry → Explain → Question → Ending

标准游戏包（6~8 场景）：
  Entry → Explain → Q1 → Feedback → Q2 → Feedback → Q3 → Ending

高级游戏包（8+ 场景）：
  Entry → Explain1 → Explain2 → Q1 → Q2 → Q3 → Special → Ending
```

## 八、三种剧情风格

风格由 `GameGenerationRequest.Style` 指定，对应 `GameGenerator.cs` 中的 `StyleTemplate` 静态字典。

| 风格 | 引导角色 | 开场场景标题 | 开场情绪 | 语气 |
|---|---|---|---|---|
| CAMPUS | 林学姐 | 图书馆的自习时光 | cheerful | 校园日常，亲切鼓励 |
| FANTASY | 精灵导师艾莉娅 | 魔法学院的试炼 | mystical | 奇幻冒险，神秘庄重 |
| SCIENCE | NEXUS | 空间站知识模块 | calm | 科幻未来，理性冷静 |

### 风格对照（来自 StyleTemplate）

| 场景元素 | CAMPUS | FANTASY | SCIENCE |
|---|---|---|---|
| 开场白 | "嘿，学弟！今天学姐陪你一起复习农业知识吧。" | "勇敢的冒险者，欢迎来到知识之塔。今天我们将一同探索自然法则的奥秘。" | "研究员，欢迎接入 NEXUS 知识系统。今日学习模块已加载完毕。" |
| 出题引导 | "来，看看这道题你掌握得怎么样？" | "魔法的试炼开始了，请回答这个问题：" | "系统已生成评估问题，请作答：" |
| 结束语 | "本轮复习内容已经完成，稍后可以查看学习记录。" | "知识之塔的本轮试炼已经完成！" | "本轮学习内容已完成，作答结果将由复习服务记录。" |

## 九、三种难度级别

难度由 `GameGenerationRequest.Difficulty` 指定，影响选项数量和题干措辞。

| 难度 | 选项总数 | 干扰项数 | 题干措辞（`GetQuestionStem`） |
|---|---|---|---|
| BASIC | 4 | 3 | "关于「{title}」，以下哪个说法是正确的？" |
| STANDARD | 4 | 3 | "根据所学内容，关于「{title}」最准确的描述是？" |
| ADVANCED | 3 | 2 | "在深入理解「{title}」的基础上，以下哪个选项最符合实际？" |

生成器使用 `DeterministicShuffle`（基于 questionId 种子的 Fisher-Yates）打乱选项顺序，保证可复现。

## 十、资源系统（Assets）

资源引用用于背景图、立绘、音频等：

```json
{
  "assetId": "bg-library",
  "type": "BACKGROUND",
  "uri": "https://gateway.example.com/assets/bg-library.png"
}
```

**`additionalProperties: false`** — 不允许未知字段。

| 字段 | 约束 | 说明 |
|---|---|---|
| `assetId` | 非空，包内唯一 | 资源标识 |
| `type` | enum | `BACKGROUND` / `CHARACTER` / `AUDIO` / `OTHER` |
| `uri` | 非空 | 资源 URI，必须经 Gateway 可寻址 |

> **重要**：资源 URI 必须经 Gateway 可寻址，不能是服务直连地址或内嵌 base64。当前 mock 数据中 `assets` 均为空数组。首版不引入独立角色实体，对话使用 `speakerId` 与可选 `emotion`。

## 十一、校验规则总结

`GamePackageValidator` 强制以下规则（违反则校验失败）。校验分两层：**schema（JSON Schema draft-07）** 负责类型、枚举和数量；**validator** 负责跨字段语义规则。

### Schema 层（结构约束）

- `schemaVersion` = "1.0"（const）
- 所有顶层/嵌套对象 `additionalProperties: false`
- `packageId` / `reviewPlanId` 格式为 UUID
- `entrySceneId` minLength 1
- `scenes` 1~100 项
- `dialogue` 1~200 项
- `choices` 0~6 项
- `choice.answerKind` 枚举 `["CHOICE", null]`
- `binding.purpose` 枚举 `["EXPLAIN", "QUESTION", "FEEDBACK"]`
- `asset.type` 枚举 `["BACKGROUND", "CHARACTER", "AUDIO", "OTHER"]`

### Validator 层（跨字段语义）

**标识与引用：**
- `packageId` / `reviewPlanId` 非空 GUID（拒绝 `00000000-0000-0000-0000-000000000000`）
- `entrySceneId` 指向存在的场景
- `sceneId` 包内唯一且非空
- `choiceId` 场景内唯一且非空
- `nextSceneId` 非空时指向存在的场景
- `assetId` 包内唯一且非空

**对话与选项：**
- `speakerId` / `text` 非空（纯空白被拒绝）
- `choiceId` / `text` 非空

**知识绑定：**
- QUESTION 绑定的 `questionId` 必填且包内唯一
- QUESTION 绑定的 `questionId` 必须在同场景 choices 中出现（孤儿检测）
- 每题至少一个 `correct: true` 的选项
- QUESTION 场景的 choices 必须携带 `answerKind="CHOICE"` 和 `correct`
- 非 QUESTION 场景的 choices 不得携带 `answerKind`/`correct`

**可达性：**
- 含 QUESTION 绑定的场景必须能从 `entrySceneId` 到达

**数量限制：**
- 场景：1~100
- 单场景对话：1~200
- 单场景选项：0~6

## 十二、生成任务生命周期

生成任务按 `QUEUED -> RUNNING -> SUCCEEDED | FAILED` 迁移：

- `POST /api/v1/game-generations` 在返回 `202` 前同步读取并校验 PlanGraph
- 计划不存在返回 `422 REVIEW_PLAN_NOT_FOUND`
- 快照不一致返回 `422 REVIEW_PLAN_SNAPSHOT_MISMATCH`
- KnowledgeService 返回违反契约的数据返回 `502 UPSTREAM_CONTRACT_INVALID`
- 依赖不可用返回 `503 SERVICE_UNAVAILABLE`
- 任务接受后原子交付完整游戏包，不提供部分成功结果
- 后台生成失败时 `packageId=null`，错误写入 `GameGenerationJob.error`

## 十三、创作最佳实践

### 1. 剧情设计原则

- **每场复习是一个完整故事**：有开头、发展、高潮、结尾
- **角色有记忆**：引导角色会记得玩家之前的表现
- **知识点融入叙事**：不要让角色像念课文一样说知识点
- **反馈有温度**：答对给鼓励，答错给提示而非打击
- **风格区分度**：三种风格不只是换了角色名字，对话语气、场景氛围、措辞习惯都应不同

### 2. 题目设计原则

- 正确答案应是知识点的核心结论
- 干扰项要有**实质性迷惑性**——使用真实的错误理解，而非"以上都不对"这类占位文本
- 干扰项应覆盖不同错误类型：概念混淆、条件遗漏、因果颠倒、程度极端
- 避免「以上都不对」作为正确答案
- 题干措辞与难度匹配
- 选项顺序应打乱，正确答案不要总在同一位置

### 3. 场景编排建议

```
最小游戏包（4 场景）：
  Entry → Explain → Question → Ending

标准游戏包（6~8 场景）：
  Entry → Explain → Q1 → Feedback → Q2 → Feedback → Q3 → Ending

高级游戏包（8+ 场景）：
  Entry → Explain1 → Explain2 → Q1 → Q2 → Q3 → Special → Ending
```

### 4. 常见错误

| 错误 | 后果 |
|---|---|
| QUESTION 场景的干扰项漏写 `answerKind` | 校验失败 |
| 同题选项用了不同的 `questionId` | 题目绑定断裂 |
| `nextSceneId` 指向不存在的场景 | 校验失败 |
| `correct` 全为 false | 校验失败（至少一个正确） |
| `scoreDelta` 为 1 但 `correct` 为 false | 不违规但语义混乱，应避免 |
| 场景超过 100 个 | 校验失败 |
| 非题目场景的选项携带 `answerKind`/`correct` | 校验失败 |
| 顶层或嵌套对象包含未知字段 | 校验失败（`additionalProperties: false`） |
| 使用空 GUID `00000000-...` | 校验失败 |
| `packageId`/`reviewPlanId` 不是 UUID 格式 | 校验失败 |

## 十四、完整示例

仓库中提供了以下参考文件（位于 `backend/GalGameService/mocks/`）：

| 文件 | 风格 | 难度 | 场景数 | 说明 |
|---|---|---|---|---|
| `golden.json` | — | — | 1 | 黄金游戏包（契约 Mock，最小化） |
| `campus-standard.json` | CAMPUS | STANDARD | 4 | 校园风格标准难度（生成器输出） |
| `fantasy-advanced.json` | FANTASY | ADVANCED | 4 | 奇幻风格高级难度（生成器输出） |
| `science-basic.json` | SCIENCE | BASIC | 4 | 科幻风格基础难度（生成器输出） |
| `campus-standard-full.json` | CAMPUS | STANDARD | 8 | **校园风格完整版（3 道题 + 2 反馈场景）** |
| `fantasy-advanced-full.json` | FANTASY | ADVANCED | 7 | **奇幻风格完整版（3 道题 + 1 反馈场景）** |
| `science-basic-full.json` | SCIENCE | BASIC | 9 | **科幻风格完整版（3 道题 + 2 反馈场景）** |

完整版脚本由 `gen_packages.py` 生成，展示了多知识点、多题目、含反馈场景的完整游戏流程，可直接作为创作模板。

### 工具文件

| 文件 | 说明 |
|---|---|
| `gen_packages.py` | 游戏包生成脚本，用 `uuid.uuid4()` 生成合法 UUID，集中管理剧情内容和干扰项 |
| `validate_packages.py` | 校验脚本，复现 schema 1.0 全部结构规则和跨字段语义规则 |
