# ReciteHelper 迁移架构与变更台账

> 状态：BASELINE（实现必须与本文及 `docs/contract.md` 同步）  
> 基线日期：2026-08-08  
> 来源：`ArabidopsisDev/ReciteHelper`，本机完整副本 `D:\Projects\ReciteHelper`  
> 来源提交：`21288821229eb8a1da7f5a38d248fdfd10104f80`  
> 目标：以 ReciteHelper 的学习、题库与考试功能为主流程，保留并有机接入 GalReview 的知识图谱和视觉小说复习。

## 1. 文档优先级与修改纪律

1. 跨服务 HTTP、身份、数据所有权和错误响应以 `docs/contract.md` 为最高优先级。
2. 本文冻结迁移映射、服务边界、差异决策和实施状态；实现变化必须先改本文或与代码在同一变更中修改。
3. 各服务 README 说明服务内部实现；与跨服务契约冲突时必须先修正文档漂移，不能靠调用方猜测。
4. 浏览器只能访问 API Gateway；领域服务之间只能携带受信服务身份经 Gateway 的 `/internal/v1` 调用。
5. 不读取其他服务数据库、不复制其他服务的权威事实、不动态编译模型生成的代码。

## 2. 审计基线

### 2.1 GalReview 当前架构

```text
React 19 / Vite frontend
          |
          v
Node.js / TypeScript API Gateway
          |
          +-- AuthService -------- MySQL（凭证、会话、邀请、审计）
          +-- UserService -------- MySQL（资料、偏好）
          +-- FileService -------- MongoDB + GridFS（资料、解析文本）
          |      `-- OCRService -- 无状态 OCR 执行器（唯一允许的服务直连例外）
          +-- KnowledgeService --- Neo4j（章节、知识点、PlanGraph、SM-2）
          +-- GalGameService ----- MongoDB（剧情生成任务、GamePackage、语音资产）
          +-- RenderService ------ C++/WASM + TypeScript（视觉小说会话、证据提交）
```

跨服务事实只有一个所有者。FileService 交付可追溯的规范化文本；KnowledgeService 是知识关系、掌握度和复习调度的唯一写入方；GalGameService 是剧情包的唯一写入方；RenderService 只提交作答证据，不自行改写掌握度。

### 2.2 ReciteHelper 已核对功能

| 原功能 | 已核对实现 | 迁移目标 |
|---|---|---|
| 学习项目 | `Project`、章节、题目、本地知识库 | PracticeService `StudyProject`，引用资料、图谱和题库 |
| 五类题目 | 单选、填空、判断、名词解释、简答 | 原样保留类型；公共枚举改为大写稳定值 |
| 资料导入 | PDF、DOCX、PPTX、TXT、MEG 合并 | FileService 增补 PPTX/MHTML；多资料通过项目引用组合，不复制文件 |
| 题目生成 | 分章、并发生成、失败重放、规范化 | PracticeService 异步生成任务；输入只取 FileService 规范化文本 |
| 语义判分 | SBERT + 字符重合 + 编辑距离兜底 | 逐必要事实的本地多语种 NLI；低置信自动 `ABSTAINED`，不产生学习证据 |
| 个性化记忆 | XGBoost 估计 quality、EF 排序 | XGBoost 退出生产；Domain 由离散可观察内容状态产生 q，KnowledgeService 忠实推进 SM-2 |
| 智能复习 | 按 EF/新题比例选题 | 按 KnowledgeService 到期/薄弱点 + PracticeService 未作答题组合 |
| 错题帮助 | 向量 Top 3 + 受材料约束的解释 | 优先检索题目关联知识点和出处；可选解释不得脱离检索证据 |
| 整卷导入 | PDF/TXT/HTML/MHTML，识别题目与答案 | FileService 负责文本；PracticeService 负责试卷结构化和人工校对状态 |
| 随机组卷 | 类别比例、按难度加权抽样 | 保留确定性种子和分值配置，生成可重放 ExamSession |
| 旧项目包 | `.rhproj` JSON、`.rhp` ZIP | 兼容导入；新导出为 `qzwl-practice-package-1.0`，保留来源版本 |
| 资源中心 | 搜索、上传、下载项目包 | PracticeService 共享包目录；不调用原程序未验证的远端地址 |
| 视觉小说 | 模型生成 C#，Roslyn 动态编译 | 改为现有 PlanGraph → GalGameService → GamePackage → RenderService |

### 2.3 已发现且必须修正的原仓库问题

- `SbertModelJudge` 查找 `Resources/vocab.txt`；该文件没有出现在源码资源目录，却存在于用户指出的完整运行时目录 `ReciteHelper.Wpf/bin/Debug/net10.0-windows7.0/Resources`。迁移必须同时带入并校验 `vocab.txt`，不能只按 Git 跟踪文件清单判断模型不可用；`tokenizer.json` 作为同一模型的可复核 tokenizer 资产保留。
- 旧 `QuizService` 混用了 `[0,1]` 与 `[0,100]` 的相似度尺度，存在 `Math.Max(similarity, 83)` 和再次乘以 100 的路径。新契约只接受 `[0,1]`，边界处一次性换算。
- 旧 XGBoost 可恢复的明示训练样本仅约 40 条、来自单个用户且类别失衡；训练速度是字符/分钟，生产输入却是字符/秒，另外还存在相似度 `0..1`、`0..100` 与 `8300` 三重尺度。它不能被修补为可靠 q 预测器，已从生产判分链移除。
- 原实现只更新 EF 并按 EF 排序，没有 SM-2 的 repetitions、interval 和 next due date；迁移只保留 ReciteHelper 的答题用户故事，调度统一由 KnowledgeService 的完整 SM-2 状态负责。
- 旧视觉小说路径执行模型生成的 C#。迁移后禁止动态编译和执行生成代码，统一复用 GalGame `schema 1.0` 和 Render runtime ABI。
- 旧 Resource Center 的 HTTP 接口没有随仓库提供服务端契约，且默认配置为明文 HTTP。迁移后不调用该地址，改成本项目内有契约、有鉴权的共享包资源。
- ReciteHelper WPF 的 Hosted Activation 属于独立部署能力，且本机配置已禁用；它不属于学习领域，首版不迁移到浏览器应用。

### 2.4 原版用户故事与严格业务边界

本轮重新以 `D:\Projects\ReciteHelper` 的 `README.md`、`docs/manual-cn.md`、`Project` 聚合、
`MainWindow`、`SelectChapterWindow`、`QuizWindow`、`ExamSettingWindow`、`KnowledgePointWindow`、
`ReviewGenerator`、`QuizService` 和 `ProjectFileService` 为准核对，而不是从 GalReview 旧页面反推业务。
原版可观察到的主路径固定如下：

```text
最近项目 / 创建 / 导入
        -> 经典复习项目
        -> 章节工作台（章节数、题量、掌握度）
        -> 章节答题 / 智能复习 / 模拟考试 / 知识点学习
        -> 追加资料 / 导入套卷 / 项目包导入导出 / 资源中心
        `-> 可选：从本项目运行游戏
```

因此新版“用起来就是 ReciteHelper，但多出知识图谱和生成游戏”的边界为：

| 用户能力 | 用户所属上下文 | 权威事实所有者 | 掌握度行为 |
|---|---|---|---|
| 建立/续读研习册、追加资料引用 | 经典复习项目 | PracticeService；原文仍属 FileService | 不更新 |
| 生成、导入、补签、核对五类题目 | 项目题库 | PracticeService；知识点 ID 引用 KnowledgeService | 不更新 |
| 章节练习、智能复习 | 项目 + 本次章节范围 | PracticeSession；选点/SM-2 属 KnowledgeService | 完成后更新 |
| 模拟试卷与回顾 | 项目题库 + 本次 PlanGraph | PracticeService | 交卷后更新 |
| 浏览知识点与“识网” | 当前项目引用的图谱 | KnowledgeService | 浏览不更新 |
| 故事生成与游玩 | 当前项目内“故事回响” | GalGameService + RenderService | 完成后更新 |
| `.rhproj/.rhp/.qzwlp` 与共享包 | 当前项目 | PracticeService | 不更新 |

`StudyProject` 是用户可见的唯一顶层项目概念。技术微服务边界不拆散用户聚合：界面不得出现
“GalGame 项目”，不得要求用户先在资料页建立一个游离的全局复习计划，也不得从主页直接进入
无项目上下文的 `/review`。故事包、Render 会话和 PlanGraph 虽由各自服务保存，但只通过
`projectId -> graphId -> reviewPlanId` 从研习册发起。

## 3. 目标架构

产品内核是 ReciteHelper 的“用户复习资料库”聚合：学习项目、题库、练习、试卷和复习调度构成默认主线。GalReview 的知识图谱、SM-2 和视觉小说不是并列产品，也不是把 ReciteHelper 附加到 GalReview；它们分别作为该聚合的知识组织/调度能力与故事复习模式。技术上新增一个领域服务而不是把原 WPF 单体整体塞入现有服务。该服务与 KnowledgeService 一样采用四层项目并用 MediatR 落实 CQRS：

```text
PracticeService.API          HTTP、Gateway 身份、DTO、统一信封
        | MediatR
PracticeService.Application  Command/Query Handler、应用端口、事务编排
        |
PracticeService.Domain       聚合、值对象、领域不变量（零基础设施依赖）
        ^
PracticeService.Persistence  Mongo、Gateway client
```

模型能力另由同样四层的 ModelService 承载：API 只暴露 INTERNAL 契约，Application 用 MediatR
发送推理命令与 readiness 查询，Domain 定义输入/verdict 边界，Persistence 独占 ONNX、
SentencePiece、词典与资产校验且不使用数据库。两服务的 API 都不直接注入仓储或推理实现；
Persistence 不引用 API；Domain 不引用 MediatR、Mongo、HTTP 或 ONNX。

```text
                         +-----------------------+
Browser -> Gateway ----> | PracticeService :5107 | ---- MongoDB qzwl_practice
                         +-----------+-----------+
                                     |
                    only via Gateway /internal/v1
                 +-------------------+-------------------+
                 |                   |                   |                 |
                 v                   v                   v                 v
          FileService        KnowledgeService     GalGameService   ModelService :5109
       normalized text       PlanGraph / SM-2      GamePackage      facet NLI only
                 |                   ^                   |
                 |                   | evidence          v
                 +-------------------+------------ RenderService
```

### 3.1 PracticeService 所有权

PracticeService 是下列事实的唯一写入方：

- `StudyProject`：名称、科目、所引用的 material/graph、项目状态；
- `QuestionBank`、`Question`、答案、解析、来源引用和知识点绑定；
- `QuestionGenerationJob`、`ExamImportJob` 的状态与诊断；
- `PracticeSession` / `ExamSession`、题目顺序、提交答案、评分明细；
- 可分享的学习包元数据、版本、可见性和包二进制；
- 题目级历史统计与检索向量（不等同于知识掌握度）。

PracticeService 不拥有：

- 原文件与规范化文本（FileService）；
- 章节/知识点/关系/PlanGraph/mastery/SM-2（KnowledgeService）；
- 剧情生成任务和 GamePackage（GalGameService）；
- 视觉小说运行时会话与渲染证据（RenderService）；
- 用户资料、凭证和授权（User/Auth）。

这些数据所有权边界是同一复习资料库聚合的服务化实现，不表示多个互相竞争的产品聚合。用户从 StudyProject 发起普通练习、图谱计划复习、试卷或故事复习；各服务只维护自己已经冻结的权威事实，通过 materialId、graphId、reviewPlanId、questionBankId 和证据契约组成同一学习闭环。

### 3.2 为什么不单拆 LibraryService

共享资源是版本化的 Practice 项目包，与题库 schema、导入兼容性和权限检查强耦合；当前没有独立生命周期或其他领域消费者。把它拆为独立服务会产生跨库事务和重复包校验，因此首版由 PracticeService 承担。出现独立审核、计费或多产品消费后再用事件拆分。

## 4. 主流程

### 4.1 建立学习项目

1. 用户在“藏书阁”上传一个或多个资料并等待 FileService 规范化文本 `READY`；藏书阁不拥有或创建图谱。
2. 用户先创建 `StudyProject`，只保存 material ID；KnowledgeService 以 `studyProjectId` 为作用域、以 material 为来源建立本册独立图谱。
3. 客户端绑定图谱前后分别由 KnowledgeService 与 PracticeService 经受信接口核验项目、用户和资料范围；同一资料用于两本册时不得复用 graph、point 或 mastery。
4. 立册编排立即从本册全部章节创建 OPEN `LEARNING` PlanGraph（`maxPoints` 可到 1000）并省略
   `targetCount` 调用 `recite-question-v2`。Assessment Plan 只负责后续某一次练习/试卷的选点，
   30 题等小题量限制不得反向限制首次建库。
5. 生成器按“显式题库 → 半结构化讲义 → 普通正文”分流：原题/原答案优先忠实提取；术语定义与
   问题标题—分点答案从答案原子形成题面；剩余正文才按本册知识点、连续证据和答案原子调用模型。
6. 每道 `READY` 题同时保存唯一 point ID 与逐字可回源的 source range/checksum，并通过与生成调用
   分离的第二次 QA 回验。回验可使用同一 provider/model，不得误称独立模型。不能唯一绑定或不能由
   同一证据还原答案的原题保留 `DRAFT` 并给出诊断，禁止猜签。

### 4.2 普通练习与智能复习

1. 用户从研习册选择章节；页面为该次章节练习、智能复习或模拟试卷创建新的 `ASSESSMENT` PlanGraph。
2. KnowledgeService 用第 6.6 节唯一算法选点：SM-2 的 `nextReviewAt` 形成到期集合，图谱形成依赖覆盖，再按
   次模边际收益选择目标；禁止任意设置“SM-2 60% + 图谱 40%”之类混合权重。
3. PracticeService 按 PlanGraph 目标顺序，每个知识点确定性选择一道 READY 题；缺题点被跳过并继续扫描
   后续计划点，不换入计划外题，也不在同次计分会话重复同一知识点。只有计划与题库零交集时才报错。
4. 客观题确定性判分；解释题按标准答案必要事实做方向性 NLI。只有全部必要事实可靠蕴含才算完整掌握；遗漏、矛盾与空白由 Domain 离散映射 q，低置信/模型故障自动拒判且不写掌握度。用户不承担自评、答案对照或 q 标注。
5. 完成会话后，PracticeService 使用现有 `PUT /internal/v1/review-evidence/{resultId}` 提交证据。
6. 对 PracticeService 调用，该契约的 `packageId` 表示 `questionBankId`，`sessionId` 表示 PracticeSession；KnowledgeService 仍校验 plan、snapshot、用户、题目知识点范围和幂等键。

### 4.3 视觉小说复习

视觉小说是 StudyProject 内的一种复习模式。学习项目选择图谱范围后继续复用现有链路：

```text
Practice UI -> Knowledge assessment/learning plan
            -> GalGame game-generation
            -> Render review-session
            -> Knowledge review-evidence
```

PracticeService 不代理、不复制也不转换 GamePackage。这样普通刷题和故事复习共享同一 PlanGraph 与 mastery，题目表现会影响下一次故事选点，故事作答也会影响下一次智能练习。UI 入口必须位于学习项目的“复习方式”中，不能再把故事生成表达为比 ReciteHelper 复习主线更高一级的产品入口。

### 4.4 整卷与共享包

- 整卷文件先进入 FileService；PracticeService 的导入任务读取规范化文本并生成 `DRAFT` 试卷。具有逐字
  来源、答案支持且能唯一对应本册知识点的草稿由既有 PATCH/会话入口自动补签为 `READY`；只有来源失效
  或确有多义的剩余题才需要人工处理。
- `.rhproj` / `.rhp` 只作为兼容导入格式，不成为内部存储格式；ZIP 条目必须拒绝绝对路径、`..`、符号链接和解压后超限。
- 共享包默认 `PRIVATE`；显式发布后为 `UNLISTED` 或 `PUBLIC`。下载仍经 Gateway 用户鉴权，不暴露 GridFS URL。

## 5. API 和数据不变量

- 所有 ID 使用 UUID；时间使用 UTC RFC 3339；分页使用 opaque cursor。
- 题型：`SINGLE_CHOICE | FILL_BLANK | TRUE_FALSE | TERM_DEFINITION | ESSAY`。
- 题库状态：`DRAFT | GENERATING | READY | FAILED | ARCHIVED`。
- 会话状态：`CREATED | ACTIVE | COMPLETED | ABANDONED`。
- `recite-question-v2` 自动支持 `SINGLE_CHOICE | FILL_BLANK | TERM_DEFINITION | ESSAY`；
  `TRUE_FALSE` 只保留人工题录或导入。`targetCount` 可空，显式范围 1-1000；省略时以通过校验的
  唯一原题/知识原子决定题数，不能为了达到固定数量制造重复题。
- 只有 schema、逐字来源、答案支持、分离的第二次回验、题型约束和唯一知识点绑定全部通过才进入 `READY`。
  单选必须是 A-D 四项 one-best-answer；任何门禁失败都拒绝或进入 `DRAFT`，不自动修成“看起来像题”。
- 名词解释先提取引号内或“请解释/什么是/何谓”之后的术语焦点，再按精确标题、精确标签、最长唯一标题、
  唯一包含关系、同资料唯一来源区间重叠和来源文本的离散顺序自动补签，不使用相似度混合分。旧草稿也在页面载入、智能复习和组卷
  前重跑同一规则；来源/checksum/答案支持不成立时禁止自动转 READY。
- PlanGraph 是复习目标的优先顺序，不是“任一点缺题就整次失败”的全有或全无清单。PracticeService 按
  顺序跳过缺题点并选择后续有 READY 题的计划点；只有计划与题库完全没有交集时才返回覆盖错误。
- `similarity` 只保留为可空兼容诊断字段，不参与判分或 SM-2；`quality` 在 `DECIDED` 时为整数 `[0,5]`，在 `ABSTAINED` 时必须为空；`responseTimeMs >= 0` 但不参与 q。
- 客观题不调用模型。主观题保存模型/规则版本、逐事实标签与置信诊断；概率只作为拒判门禁，不做加权分数。任何不确定、模型缺失或推理失败均自动 `ABSTAINED`，不得用编辑距离降级判错。
- PracticeService 不允许客户端上传 `userId` 冒充他人；用户身份只接受 Gateway 注入的 `X-User-Id`。
- PracticeService 调用内部接口使用 `X-Service-Name: PracticeService` 和独立密钥，密钥只在 Gateway 验证，转发前剥离。

具体端点和 JSON 类型以 `docs/contract.md` 第 14 节为准。

### 5.1 为什么不复制机械切块主链

旧式“每 500/800 字切一段，再轮转知识点和题型”的实现会切断多行答案、把章节标题/页脚混入题面，
并诱发“请概括下述内容”“10. ____？”和随机干扰项。v2 的 1400 字窗口只用于普通正文模型调用的
传输边界；它不是知识原子，也不能直接决定题数、题型或 pointId。结构化边界、连续原文证据与
PlanGraph 唯一绑定先于窗口，窗口生成结果仍要逐字回源并通过第二遍回验。

研究依据与工程映射：

- [Answer-focused and Position-aware Neural Question Generation](https://aclanthology.org/D18-1427/)：支持答案焦点先行，映射为 `EvidenceBundle/KnowledgeAtom → 题面`。
- [Synthetic QA Corpora Generation with Roundtrip Consistency](https://aclanthology.org/P19-1620/)：支持用答案抽取回路筛选合成 QA，映射为第二遍回验必须还原同一标准答案。
- [Putting the Horse before the Cart: A Generator-Evaluator Framework for Question Generation from Text](https://aclanthology.org/K19-1076/)：支持分离生成与评价职责；当前实现只迁移该设计原则，不复现论文模型或 SQuAD 结论。
- [QGEval](https://aclanthology.org/2024.emnlp-main.658/)：记录流畅、清晰、简洁、相关、一致、可回答、答案一致七个人工维度；论文同时显示自动指标不能替代人工判断，因此项目仍需真实资料黄金集。
- [Evaluating Rewards for Question Generation Models](https://aclanthology.org/N19-1237/)：自动奖励可能与人工判断错位并被模型利用，因此不设置合成质量分或拍脑袋混合权重作为有效性证明。
- [NBME Item-Writing Guide](https://www.nbme.org/sites/default/files/2021-02/NBME_Item%20Writing%20Guide_R_6.pdf)：支持聚焦 lead-in、同质可信选项和排除形式线索，映射为 A-D one-best-answer 布尔门禁；干扰项不可靠就不生成单选。
- [Test-enhanced learning: taking memory tests improves long-term retention](https://pubmed.ncbi.nlm.nih.gov/16507066/) 与 [Retrieval practice produces more learning than elaborative studying with concept mapping](https://pubmed.ncbi.nlm.nih.gov/21252317/)：支持主动提取复习形态，不证明自动生成题目的内容质量。

证据声明边界：当前算法只能称为“研究依据支持且通过项目技术门禁”，不能称为“本项目已经研究证明
有效”。1400 字符、每片至多 8 题、温度和 token 上限是吞吐/上下文运行参数，不是论文得出的学习质量
参数。升级为“已验证有效”前，必须按 `docs/contract.md` §14.3.1 使用版本化中文领域资料集，完成领域
专家盲评、评审一致性、人工题与原 ReciteHelper 对照、关键组件消融；若声明学习增益，还必须完成预注册
的延迟测验对照实验。样本量与优效/非劣界值由前瞻功效分析和人工基线决定，不得事后指定比例或权重。

## 6. UI 重绘规则

ReciteHelper 的功能信息架构迁移到 GalReview，而不是复刻 WPF 外观：

- 主导航以“研习册”承载经典复习项目；保留“起点、藏书阁、识网、回响”等 GalReview 文艺但可理解的命名，练习、试卷、图谱计划与故事复习从项目上下文进入；
- 产品名称始终为“千知万理”，不得在界面中以 ReciteHelper 替换产品名；GalReview 只保留为现有实现标识；
- 公开首页与登录后主页必须介绍“文件解析/文字识别、AI 辅助语义整理、题库确认、知识图谱与 SM-2 调度、结果回写”的实际流程；不得把所有确定性处理笼统宣传为 AI；
- 继续使用 GalReview 的浅灰画布、克制蓝色行动色、圆角分组、中文无衬线字体和真实数据表格；
- 不使用霓虹渐变、发光边框、机器人头像、聊天气泡作为普通表单容器，也不把每个动作包装成“AI”；
- 页面文案、导航、按钮、状态和空态禁止使用 emoji；图标只复用 GalReview 现有的中性 SVG 体系；
- “生成”显示为普通后台任务，明确输入资料、范围、题型、进度、失败原因和重试入口；
- 题目页优先可读性：题干、选项/输入、来源、解释分区稳定，键盘操作和移动端都可完成；
- 视觉小说仅在用户主动选择剧情复习时出现，不侵占日常刷题和试卷工作流。

## 7. 模型与第三方资产

| 资产 | 本机 SHA-256 | 用途 | 迁移规则 |
|---|---|---|---|
| `Models/multilingual-minilm-nli/model.onnx` | `79f8cda2b1230585a95ea0514a6f1bd21c5c986ba0529bb3261213a3e195fa6e` | 逐事实中文 NLI 主判器 | 固定上游 revision 与 SHA-256；和 SentencePiece、严格同义词词典共同通过 readiness |
| `Models/multilingual-minilm-nli/sentencepiece.bpe.model` | `cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865` | XLM-R tokenizer | 原始 SentencePiece ID 必须按 XLM-R/fairseq 约定整体 `+1`；已有回归测试锁定 |
| `cn_synonym.txt` | `de0d4c74e18633cc758f3d35d9479cb63d2e80abe77f2a7f49dba30fed2a482e` | 严格同义词二次复核 | 只读取 `=` 组；只允许把 `OMITTED` 复核为 `ENTAILED`，不覆盖矛盾 |
| `sbert.onnx` / `vocab.txt` | `994a…26ede6b` / `45bb…b291c` | 兼容与离线诊断 | 不参与 correct、quality 或 SM-2 |
| `xgboost_qvalue.onnx` | `53b5…88ea0` | 旧资产兼容 | 生产禁用，不加载、不作为当前算法证据 |

ReciteHelper 兼容模型与词表来自完整本机副本，其中 `vocab.txt` 由运行时输出目录补齐。新 NLI 来自 MIT 许可的 `MoritzLaurer/multilingual-MiniLMv2-L6-mnli-xnli` 固定 revision `0a71e92a985b6e1ad1828cf67ce9c459639c1dca`。这些大文件统一归 `backend/ModelService/Resources`，不进入 Git。OSCA 私有储桶 `20277-gal-res` 当前按 `Resources` 同构目录保存完整 `Models/multilingual-minilm-nli`；`scripts/download-model-resources.ps1` 以该镜像为主源，但不把 OSCA 可用性当成构建单点：旧模型及词典固定到 ReciteHelper 审计提交，`vocab.txt` 固定到历史提交，新 NLI 固定到 Hugging Face revision，并可先从受信同构离线副本逐文件恢复。所有来源最终统一校验大小与 SHA-256。全部灾备均失败时 ModelService Docker 构建前置检查失败；运行时主观题自动 `ABSTAINED`，绝不退回编辑距离判错。

ReciteHelper 使用 AGPL-3.0。迁移的源代码、提示词、模型和兼容格式必须保留来源、版权与许可证说明；本项目的分发方式需要由维护者确认整体许可证兼容性。本文记录事实，不替代法律意见。

## 8. 变更台账

| 日期 | 范围 | 变更 | 原因 | 验证 | 状态 |
|---|---|---|---|---|---|
| 2026-08-08 | 架构 | ReciteHelper 复习资料库定为产品内核；故事生成为项目内复习模式；共享包留在同一聚合 | 保持业务主从和资料聚合一致，避免纳米服务/跨库事务 | contract 与 UI 路由审阅 | IMPLEMENTED |
| 2026-08-08 | Practice | 按 API/Application/Domain/Persistence 四层重构，并使用 MediatR CQRS | 与 KnowledgeService 对齐，隔离 HTTP、用例、领域和基础设施 | solution build 0 warning；15 tests pass | VERIFIED |
| 2026-08-08 | Practice | 实现五类题目、资料生成、整卷导入、判分、帮助、随机/智能/试卷会话 | 完整承接 ReciteHelper 复习主线 | PracticeService tests 15/15；全链 SMART_REVIEW 完成 | VERIFIED |
| 2026-08-08 | Practice | 兼容 `.rhproj`/`.rhp`，新增哈希包、ZIP 安全校验与 GridFS 共享目录 | 保留旧项目并替代未冻结的外部资源中心 | legacy/round-trip/traversal tests pass | VERIFIED |
| 2026-08-08 | Practice | MongoDB.Driver 3.x 全局 Guid 表示固定为 Standard，并忽略 Mongo 自动 `_id` 元数据 | 防止 UUID 表示不确定，以及创建后的首次聚合读取因 `_id` 无领域属性而失败 | BSON 专项 2/2；真实 Mongo 全链通过 | VERIFIED |
| 2026-08-08 | Practice/File | 项目创建、资料映射修改和旧包导入逐项复用 File extracted-text 读取校验 owner/READY | 防止只校验 UUID 形状后引用他人或未就绪资料 | 所有权拒绝/接受测试通过；跨服务 E2E 待容器 | VERIFIED |
| 2026-08-08 | Knowledge | PlanGraph reader 与 evidence writer 允许精确身份 PracticeService | 普通练习共享 PlanGraph/SM-2 | 目标测试 12/12 | VERIFIED |
| 2026-08-08 | File | 补齐 PPTX、MHTML 解析 | 覆盖 ReciteHelper 资料与整卷输入 | build 通过；专项解析测试待补 | IMPLEMENTED |
| 2026-08-08 | File | `CreateJob` 契约改为可空并在入口处理并发状态变化 | Mongo 条件写本来可能返回 null，旧接口会产生空引用 | FileService build 0 warning | VERIFIED |
| 2026-08-08 | GalGame/Render | 拒绝迁移 Roslyn 动态编译，复用 GamePackage/runtime | 保持安全和现有架构 | 复用现有黄金包测试 | SPECIFIED |
| 2026-08-08 | Gateway | 加入 PracticeService 路由、密钥、限流和健康检查 | 统一鉴权和服务身份 | route/config tests 44/44 | VERIFIED |
| 2026-08-08 | Gateway/Deploy | 项目包精确路由使用 51 MiB multipart 上限，Nginx 示例为 52 MiB | 允许 contract 的 50 MiB 包且不放大其他 API | Gateway full suite 199/199；Compose config pass | VERIFIED |
| 2026-08-08 | Frontend | 以项目为顶层入口，故事复习降为项目内模式；使用既有 GalReview tokens 和组件 | 功能主次调整和视觉一致性 | TypeScript 与 production build 通过 | VERIFIED |
| 2026-08-08 | Frontend | 产品名保持“千知万理”；公开首页和登录后主页说明 AI 辅助解析、题库确认、图谱/SM-2 调度与反馈闭环 | 首页表达与新的 Recite-first 产品内核一致，同时避免 AI 风格包装和能力夸大 | production build 通过 | VERIFIED |
| 2026-08-08 | Billing/Auth | 取消邀请码注册；新增四层 CreditService 与 MediatR CQRS，新用户和旧用户惰性迁移均只获得一次初始 1 credit | 将准入机制替换为可审计的生成用量制度，不跨服务写余额 | Credit 6/6、Auth 11/11 | VERIFIED |
| 2026-08-08 | Practice/Credit | 复习题目生成按资料与目标题数预授权，成功按实际输入和产物结算，失败释放 | 计费围绕 ReciteHelper 复习主线，不改变 StudyProject 聚合 | Practice 14/14、Credit 6/6 | VERIFIED |
| 2026-08-08 | GalGame/Credit | 故事复习按 PlanGraph 和最大草稿估算，累计供应商实际 usage 后结算 | 故事生成作为复习功能共享同一 credits 账户 | GalGame 362/362 | VERIFIED |
| 2026-08-08 | Frontend/Admin | 设置页增加余额、兑换与确认购买；管理员支持兑换码批量生成、状态与撤销；不足提示不展示内部换算 | 延续 GalReview 视觉与中性文案，禁止 AI 风格和 emoji | production build 通过 | VERIFIED |
| 2026-08-08 | Gateway/Deploy | CreditService 路由、独立密钥、MySQL、healthcheck、readiness、备份与部署变量写入容器基线 | 新服务与现有服务变更必须可部署、可恢复 | Gateway 203/203；Compose config pass | VERIFIED |
| 2026-08-08 | Credit/Deploy | 健康检查鉴权旁路由 `PathString` 常量模式改为显式 `PathString` 相等比较 | 修复 Linux .NET 10 容器编译的 `CS9135`，保持仅 `/healthz`、`/readyz` 无 Gateway key 可访问 | Credit tests 6/6；Linux 镜像构建与 healthcheck 通过 | VERIFIED |
| 2026-08-08 | GalGame/Deploy | Docker 构建上下文显式纳入 `Voice/**` 与 `character-voice-config.json` | 修复语音实现和角色配置被白名单式 `.dockerignore` 排除、容器发布无法编译的问题 | GalGame tests 362/362；Linux 镜像构建与故事全链通过 | VERIFIED |
| 2026-08-08 | Practice/Deploy | `Resources` 改为 Git 忽略的 OSCA S3 构建前资产；仓库内单文件下载器配置仅限 `20277-gal-res` 读取/列举的凭据，并保留 14 文件哈希清单与 Docker 缺失门禁 | 避免约 105 MiB 模型和字典进入 Git，同时让任意开发环境一键、可重复恢复 | 14/14 本地哈希、容器资源门禁与镜像构建通过；真实 OSCA 下载仍待安装 AWS CLI | VERIFIED |
| 2026-08-08 | Credit/Persistence | MySQL UUID 列统一兼容驱动返回的 `Guid`、字符串或 16-byte 值 | MySqlConnector 可把 `CHAR(36)` 直接物化为 `Guid`，旧代码 `GetString` 使预授权成功后结算/释放 500 | Credit 6/6；MySQL 预授权、实际结算、释放、制码兑换全链通过 | VERIFIED |
| 2026-08-08 | GalGame/Persistence | credits 拒绝时任务只持久化稳定错误码/消息，即时 402 响应继续返回完整购买 details | Mongo 安全 ObjectSerializer 拒绝把上游 `JsonElement` 写入 `object Details`，原行为会把正确的 402 放大为 503 | GalGame 362/362；不足路径返回 402，后续完整故事链通过 | VERIFIED |
| 2026-08-08 | Full chain | 题库复习与故事复习共享 material/graph/mastery，但一次完成各自关闭独立评估计划快照 | 遵守 `REVIEW_PLAN_NOT_OPEN`，防止向已完成计划重复写学习证据 | 15 容器 healthy；Gateway 全链含 SM-2 与 Render 结果回写通过 | VERIFIED |
| 2026-08-08 | Product boundary | 重新按 ReciteHelper 原始窗口、领域模型与用户手册冻结用户故事；删除全局 GalReview workflow 的顶层地位，`StudyProject` 成为唯一用户项目，故事回响降为册内功能 | 修复“GalGame 项目/复习项目/资料计划”三套入口混成一锅的业务反转 | 原始代码审计；前端 production build 通过 | VERIFIED |
| 2026-08-08 | Practice/Knowledge | 自动成题改为 PlanGraph 目标知识点先行与精确原文绑定；拒绝序号轮转贴签；智能练习/试卷每点一道并报告题库覆盖缺口 | 保证题目标签有证据，并满足 KnowledgeService 单次 evidence 知识点唯一性 | Practice tests 21/21；真实栈 15/15 题有标签 | VERIFIED |
| 2026-08-08 | Frontend | 主页改为最近研习册与 ReciteHelper 主功能；章节练习、智能复习、试卷和故事均从册内创建新计划 | 恢复 ReciteHelper 使用顺序，同时保留 GalReview 设计系统与“识网/回响”等文案风格 | TypeScript + Vite production build 通过 | VERIFIED |
| 2026-08-08 | Knowledge | mastery 升级为 `sm2-graph-v2`：展示 score 直接投影最近 quality；SM-2 只以 `nextReviewAt` 形成到期集合，图谱再做次模覆盖；删除 65/35 平滑、假设保持率曲线和未作答前置点的推断加分 | 掌握度只接受点级真实作答证据，避免任意混合或推断权重，同时保留 SM-2 调度与可证明的图谱覆盖 | Knowledge tests 111/111；容器复验见 test_report | VERIFIED |
| 2026-08-09 | Frontend | 导航与首页快捷入口将“藏书阁”置于“研习册”之前；无旧册时首页主按钮先进入藏书阁；“立册”表单取消 sticky，恢复普通文档流 | 界面顺序与“资料解析 → 立册 → 温习”业务顺序一致，并避免立册表单滚动时遮挡下方导入区 | Frontend production build 1401 modules；容器健康与 HTTP 验证见 test_report | VERIFIED |
| 2026-08-09 | Frontend | 研习册无 READY 题时不再静默禁用温故、循网、试锋入口；页面明确提示先到“成题”区，点击入口也会在创建计划前返回可理解的原因；禁用按钮仅在真实 busy 时使用等待光标 | 保留“必须先有 READY 题才可形成作答证据”的领域约束，同时消除无解释的灰色按钮和假加载光标 | Frontend production build 1401 modules；容器健康与 HTTP 验证见 test_report | VERIFIED |
| 2026-08-09 | Practice/Frontend | 恢复 ReciteHelper 立册编排：创建 StudyProject 后立即用全部章节建立生成计划并自动生成单选、填空、名词解释、简答四类题；精确原文/知识点绑定的确定性结果直接 READY；成题区降为追加与恢复入口 | 修复“空册创建成功后还要用户手动找成题按钮”的业务断裂，恢复立册即成题，同时保留 credits 失败后的可恢复册 | Practice 21/21、Frontend production build 1401 modules；真实立册成题与 SMART 会话见 test_report | VERIFIED |
| 2026-08-09 | Knowledge/Practice/Gateway/Frontend | 将 KnowledgeGraph 所有权从 Material 改为 StudyProject：新册先创建，再以 `studyProjectId + materialId` 经双向内部核验构图和绑定；版本、指纹、SUPERSEDED 与 mastery 均按册隔离；藏书阁仅解析资料，识网页按册选择；失败重试从本册恢复 | 修复同一资料建立多册时共享图谱身份与掌握度的聚合越界，保证“资料是来源、研习册拥有图谱” | Knowledge 112/112、Practice 24/24、Gateway 203/203、Frontend 1401 modules；容器与双册隔离实测见 test_report | VERIFIED |
| 2026-08-09 | Practice | `recite-question-v1` 从“题型外层、知识点内层”改为题型与知识点同步轮转；题数足够时先覆盖所有请求题型，再重复任一题型 | 修复四个知识点、四道首发题时达到数量上限而全部生成为单选的真实链路缺陷，同时保留干扰项不足时不伪造单选的安全降级 | 新回归测试复现旧序列并通过；Practice 24/24；真实首批 4 题覆盖单选、填空、名词解释、简答 | VERIFIED |
| 2026-08-09 | Practice/Gateway/Frontend | 主链升级为 `recite-question-v2`：整册 Learning Plan、可空 targetCount、显式/半结构化/普通正文分流、答案原子、分离的第二次 QA 回验、provider usage 结算与 600 秒超时 | 修复扁平 PDF 行内题无法识别、答案跨章节、固定 30 题、机械模板与猜签问题 | Practice 36/36、Gateway 203/203、Frontend build；两份真实 PDF 与公开 HTTP 闭环见 test_report §33 | VERIFIED |
| 2026-08-09 | Knowledge/Practice/Frontend/Deploy | 图谱切分与抽取升级为 `chapter-segmenter-v3` / `knowledge-extractor-v3`：识别无空格章节、裸题型栏、数字起始术语和真实绪论；普通长文按完整句切成不超过 1400 字符的模型证据块；题目绑定使用离散的题干精确优先级而非混合权重；前端显式请求 v3 | 修复微生物 PDF 仅 15 个图谱点导致 240 题中 231 题不可练，以及单行长文只形成一个 8 题模型分片；保持 DRAFT/READY 证据门禁 | Knowledge 115/115、Practice 38/38、Frontend build；同款 26,513 字符 PDF 本地探针得到 10 章、210 点、240 题中 220 READY，见 test_report §34 | VERIFIED |
| 2026-08-09 | Practice/Docs | 将“独立 QA”校正为同一 provider/model 也可执行的“分离第二遍来源回验”；按原始论文、命题指南与 retrieval-practice 研究补齐证据等级、运行参数边界和项目级盲评/学习实验验收协议 | 防止把研究启发、自动门禁或单元测试夸大为当前中文领域组合系统已被证明有效 | 实现—文献映射复核；Practice 回归与结论见 test_report §35 | VERIFIED |
| 2026-08-09 | Knowledge/Practice/Frontend/Deploy | 复用题目 PATCH 和图谱 scope 接口自动修复来源可验证的无签草稿；名词解释增加焦点/别名与唯一来源区间离散绑定；SMART/EXAM 跳过计划内缺题点并继续取后续已覆盖点，只有零交集才报错 | 消除“请解释第二性比仍待补签”和单个覆盖缺口使温习永久不可进入的问题，同时保留逐字来源、唯一点和计划内证据边界 | Practice 44/44、Knowledge 115/115、Frontend production build；见 test_report §36 | VERIFIED |
| 2026-08-09 | Practice/Frontend/Deploy/Docs | 旧混合相似度与 XGBoost q 退出生产；新增必要事实 NLI、严格同义词复核、选择性拒判、nullable evidence 与三态结果 UI；拒判不写 SM-2，用户无需自评或标注 | 修复完整释义被低相似度误判与错误 q 污染复习日程，同时把模型不确定性留给系统 | Practice 54/54；3 份真实 PDF、60 金标样本中决定 42、决定性误判 0，未见土壤集决定 15/20 且误判 0；Frontend build 与全链结果见 test_report §37 | VERIFIED |
| 2026-08-10 | Git/Integration | 识别远端从已推送 `3fc0d9d` 到 `7ae0fd7` 的 forced-update；以 tree 身份确认旧 130 提交仅被改 committer/GPG 后整体重写，从保护分支将被丢弃的自动绑题提交精确重放到 PR #18 之后，再恢复判分 WIP | 消除 130 ahead / 131 behind 和零共同祖先，避免 unrelated-histories 双历史合并 | 修复后 `main...origin/main [ahead 1]`，新提交 `65e1248` 直接以 `7ae0fd7` 为父；无 unmerged path | VERIFIED |
| 2026-08-10 | Auth/File/OCR/Deploy | 合入 PR #18 的密码哈希、重置码、固定时序密钥比较、OCR 网关鉴权和 PDF 页数门禁；修复 PR 中无效 Identity 哈希、空 Compose 默认、重置码模偏差与 FastAPI 中间件 500；OSCA 凭据改为环境注入并同步当前部署文档 | 保留安全改进，同时保证干净部署、管理员登录和 OCR 错误语义可用 | Auth 18/18；File Release build；管理员登录 201/错密 401；OCR health 200、无密钥 401、带密钥 200；Compose config PASS | VERIFIED |
| 2026-08-10 | GalGame/Persistence/Credit | Mongo 包写入优先使用事务，standalone 的 `NotSupportedException`/已知 Mongo 错误码自动降为幂等顺序 upsert；credits 结算移至音频和包持久化之后 | 修复 PR #18 在默认 standalone Mongo 上使所有故事生成失败且持久化失败后仍可能先扣费的问题 | GalGame 362/362；standalone Mongo 全链生成 3 题、故事包、Render 回写及 credits 结算通过，见 test_report §38 | VERIFIED |
| 2026-08-10 | Practice/Deploy | 填空从逐字相等升级为 `deterministic-fill-equivalence-v1`，离散处理数值、数值元组格式与封闭专业别名；NLI 补充下载进一步锁定模型仓库和固定 revision | 接受 `两个/二/2`、坐标空白差异和 `G+/革兰氏阳性`，同时避免模糊相似度放过反义、换序或区间边界错误 | 填空专项 27/27；完整 Practice 回归见 test_report §40；下载脚本 AST、固定来源与本地 19 文件哈希门禁通过 | VERIFIED |
| 2026-08-10 | Model/Practice/Gateway/Deploy | 新增四层 ModelService，以 MediatR CQRS 承载 NLI、SentencePiece、词典、哈希就绪与 `5109` INTERNAL 接口；Practice 只保留 rubric 与离散判分，通过 Gateway 消费 verdict；资源、清单和下载器迁至 ModelService | 模型运行时不属于研习册/练习聚合，继续置于 PracticeService 会扩大其边界并耦合部署 | Model 8/8、Practice 68/68、Gateway 204/204；16 个默认容器 healthy；真实主观题与填空 HTTP 见 test_report §41 | VERIFIED |
| 2026-08-10 | Model/Deploy | 模型资源恢复升级为本地缓存、OSCA、受信离线副本、固定远端版本四级容灾；19 个文件全部有固定灾备，覆盖旧 SBERT、旧 q 模型、词典、vocab 与新 NLI，且不能关闭最终哈希门禁 | 避免不稳定对象存储成为开发和部署单点，同时不以未校验下载或算法降级换取可用性 | 本地缓存 19/19；空目录离线恢复 19/19；ReciteHelper 与 Hugging Face 固定源真实下载探针通过；两份大模型 URL/长度 HEAD 通过，见 test_report §41 | VERIFIED |
| 2026-08-10 | Wiki/Frontend/Deploy | 新增根目录 15 页静态 Wiki 与真实界面截图；Frontend 构建将 Markdown 生成 `/wiki/`，产品首页顶部、首屏和页脚均提供入口；Wiki UI 使用 GalReview 中性文档风格 | 让不了解研习册、藏书阁、识网、故事回响和 credits 的用户能按页面完成操作，同时避免再部署一个动态文档服务 | Frontend typecheck/Vite/Wiki build PASS；完整 npm audit 0；16 个页面入口、16 个资源逐一 HTTP 200；见 test_report §42 | VERIFIED |

状态只使用 `SPECIFIED | IMPLEMENTED | VERIFIED | BLOCKED`。代码合入后必须逐项更新，测试未运行或失败时不得写 `VERIFIED`。

## 9. 完成定义

- [x] 五类题目可创建、编辑、练习、判分和回看来源；
- [ ] PDF/DOCX/PPTX/TXT/Markdown/HTML/MHTML 可经 FileService 形成规范化文本；
- [x] 资料可生成题库，失败项可见且可重试；
- [x] PDF/TXT/HTML/MHTML 整卷可导入草稿并经题目修改接口人工确认；
- [x] 智能复习读取 PlanGraph/mastery，完成后幂等回写 KnowledgeService；
- [x] 随机组卷、计时考试、分值和结果复盘可用；
- [x] 错题帮助只引用项目资料/知识点证据；
- [x] `.rhproj` / `.rhp` 兼容导入与新版项目包导入导出通过安全测试；
- [x] 共享项目包的搜索、上传、下载和权限可用；
- [x] 视觉小说入口完整复用 GalGame/Render，不执行生成代码；
- [ ] 前端以 ReciteHelper 功能为主，并通过桌面/移动端视觉与可访问性检查；
- [ ] Gateway、相关 .NET 服务、Render、Frontend 的单元/集成/build 全部有真实结果记录在 `docs/test_report.md`。
