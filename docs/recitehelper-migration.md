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
| 语义判分 | SBERT + 字符重合 + 编辑距离兜底 | PracticeService 本地 ONNX 推理；分数统一为 `[0,1]` 后再映射 quality |
| 个性化记忆 | XGBoost 估计 quality、EF 排序 | XGBoost 只估计 `quality`；SM-2 与 mastery 仍由 KnowledgeService 写入 |
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
- 旧视觉小说路径执行模型生成的 C#。迁移后禁止动态编译和执行生成代码，统一复用 GalGame `schema 1.0` 和 Render runtime ABI。
- 旧 Resource Center 的 HTTP 接口没有随仓库提供服务端契约，且默认配置为明文 HTTP。迁移后不调用该地址，改成本项目内有契约、有鉴权的共享包资源。
- ReciteHelper WPF 的 Hosted Activation 属于独立部署能力，且本机配置已禁用；它不属于学习领域，首版不迁移到浏览器应用。

## 3. 目标架构

产品内核是 ReciteHelper 的“用户复习资料库”聚合：学习项目、题库、练习、试卷和复习调度构成默认主线。GalReview 的知识图谱、SM-2 和视觉小说不是并列产品，也不是把 ReciteHelper 附加到 GalReview；它们分别作为该聚合的知识组织/调度能力与故事复习模式。技术上新增一个领域服务而不是把原 WPF 单体整体塞入现有服务。该服务与 KnowledgeService 一样采用四层项目并用 MediatR 落实 CQRS：

```text
PracticeService.API          HTTP、Gateway 身份、DTO、统一信封
        | MediatR
PracticeService.Application  Command/Query Handler、应用端口、事务编排
        |
PracticeService.Domain       聚合、值对象、领域不变量（零基础设施依赖）
        ^
PracticeService.Persistence  Mongo、Gateway client、ONNX、模型资产状态
```

API 不直接注入仓储或模型实现；Persistence 不引用 API；Domain 不引用 MediatR、Mongo、HTTP 或 ONNX。

```text
                         +-----------------------+
Browser -> Gateway ----> | PracticeService :5107 | ---- MongoDB qzwl_practice
                         +-----------+-----------+
                                     |
                    only via Gateway /internal/v1
                 +-------------------+-------------------+
                 |                   |                   |
                 v                   v                   v
          FileService        KnowledgeService     GalGameService
       normalized text       PlanGraph / SM-2      GamePackage
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

1. 用户在 FileService 上传一个或多个资料并等待规范化文本 `READY`。
2. 用户可让 KnowledgeService 对主资料构图。
3. 用户创建 `StudyProject`，只保存 material ID、可选 graph ID，不复制文本或图谱。
4. PracticeService 经 Gateway 读取每份资料的规范化文本，生成题库；生成结果必须保留 source range。
5. 人工可编辑题目、答案、分值、难度和知识点绑定后发布题库。

### 4.2 普通练习与智能复习

1. 创建 `ASSESSMENT` 或 `LEARNING` PlanGraph；无图谱项目可创建普通随机练习。
2. PracticeService 按 PlanGraph 的知识点范围选择绑定题目，并按“到期/薄弱/新题”组合排序。
3. 客观题确定性判分；解释题由本地语义模型评分，并保留相似度与规则版本。
4. 完成会话后，PracticeService 使用现有 `PUT /internal/v1/review-evidence/{resultId}` 提交证据。
5. 对 PracticeService 调用，该契约的 `packageId` 表示 `questionBankId`，`sessionId` 表示 PracticeSession；KnowledgeService 仍校验 plan、snapshot、用户、题目知识点范围和幂等键。

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

- 整卷文件先进入 FileService；PracticeService 的导入任务读取规范化文本并生成 `DRAFT` 试卷，必须由用户确认后才可考试。
- `.rhproj` / `.rhp` 只作为兼容导入格式，不成为内部存储格式；ZIP 条目必须拒绝绝对路径、`..`、符号链接和解压后超限。
- 共享包默认 `PRIVATE`；显式发布后为 `UNLISTED` 或 `PUBLIC`。下载仍经 Gateway 用户鉴权，不暴露 GridFS URL。

## 5. API 和数据不变量

- 所有 ID 使用 UUID；时间使用 UTC RFC 3339；分页使用 opaque cursor。
- 题型：`SINGLE_CHOICE | FILL_BLANK | TRUE_FALSE | TERM_DEFINITION | ESSAY`。
- 题库状态：`DRAFT | GENERATING | READY | FAILED | ARCHIVED`。
- 会话状态：`CREATED | ACTIVE | COMPLETED | ABANDONED`。
- 自动生成/导入的题库必须先是 `DRAFT`；用户确认后才能 `READY`。
- `similarity` 取值 `[0,1]`；`quality` 为整数 `[0,5]`；`responseTimeMs >= 0`。
- 客观题不调用 LLM 判分。主观题即使调用解释模型，最终证据也必须保存本地模型分数、规则版本与正确答案摘要，保证可审计。
- PracticeService 不允许客户端上传 `userId` 冒充他人；用户身份只接受 Gateway 注入的 `X-User-Id`。
- PracticeService 调用内部接口使用 `X-Service-Name: PracticeService` 和独立密钥，密钥只在 Gateway 验证，转发前剥离。

具体端点和 JSON 类型以 `docs/contract.md` 第 14 节为准。

## 6. UI 重绘规则

ReciteHelper 的功能信息架构迁移到 GalReview，而不是复刻 WPF 外观：

- 主导航以学习项目和复习资料库为中心；练习、试卷、图谱计划与故事复习从项目上下文进入；
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
| `sbert.onnx` | `994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b` | 中文答案向量 | 与 `tokenizer.json` 成对校验；推理失败时显式降级 |
| `xgboost_qvalue.onnx` | `53b563e2df2c6026f7a996b4d8f63e83c63bbf64d1dde5e03a3c7f9dbf688ea0` | quality 估计 | 输入固定为 `[relativeRate, similarityPercent]`，输出类别 0-5 |
| `vocab.txt` | `45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c` | SBERT WordPiece 词表（21,128 行） | 从完整运行时目录迁移；必须与 SBERT 一起进入镜像 |

模型与词表来自 ReciteHelper 完整本机副本，其中 `vocab.txt` 由运行时输出目录补齐。这些大文件不进入 Git，而是按原目录结构保存于 OSCA 私有储桶 `20277-gal-res`；开发和部署必须先运行仓库内的 `scripts/download-practice-resources.ps1`，再按受版本控制的 `backend/PracticeService/resources.manifest.json` 校验全部 14 个文件。下载器顶部凭据的权限由储桶策略限制为 `20277-gal-res` 的读取和列举，不能访问其他储桶或写入对象，因此下载器与清单一并进入仓库。构建不得静默从其他 URL 下载模型；缺失或哈希不符时 Docker 构建前置检查失败，运行时 `/readyz` 报告降级状态，服务仍可用确定性规则判分，但不能宣称 SBERT 已启用。

ReciteHelper 使用 AGPL-3.0。迁移的源代码、提示词、模型和兼容格式必须保留来源、版权与许可证说明；本项目的分发方式需要由维护者确认整体许可证兼容性。本文记录事实，不替代法律意见。

## 8. 变更台账

| 日期 | 范围 | 变更 | 原因 | 验证 | 状态 |
|---|---|---|---|---|---|
| 2026-08-08 | 架构 | ReciteHelper 复习资料库定为产品内核；故事生成为项目内复习模式；共享包留在同一聚合 | 保持业务主从和资料聚合一致，避免纳米服务/跨库事务 | contract 与 UI 路由审阅 | IMPLEMENTED |
| 2026-08-08 | Practice | 按 API/Application/Domain/Persistence 四层重构，并使用 MediatR CQRS | 与 KnowledgeService 对齐，隔离 HTTP、用例、领域和基础设施 | solution build 0 warning；14 tests pass | VERIFIED |
| 2026-08-08 | Practice | 实现五类题目、资料生成、整卷导入、判分、帮助、随机/智能/试卷会话 | 完整承接 ReciteHelper 复习主线 | PracticeService tests 14/14 | VERIFIED |
| 2026-08-08 | Practice | 兼容 `.rhproj`/`.rhp`，新增哈希包、ZIP 安全校验与 GridFS 共享目录 | 保留旧项目并替代未冻结的外部资源中心 | legacy/round-trip/traversal tests pass | VERIFIED |
| 2026-08-08 | Practice | MongoDB.Driver 3.x 全局 Guid 表示固定为 Standard | 防止项目/题目/会话首次持久化触发 Unspecified 序列化异常 | BSON UUID Standard 测试通过；真实 Mongo 容器待运行 | VERIFIED |
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
| 2026-08-08 | Practice/Deploy | `Resources` 改为 Git 忽略的 OSCA S3 构建前资产；仓库内单文件下载器配置仅限 `20277-gal-res` 读取/列举的凭据，并保留 14 文件哈希清单与 Docker 缺失门禁 | 避免约 105 MiB 模型和字典进入 Git，同时让任意开发环境一键、可重复恢复 | PowerShell parser、下载器可跟踪状态、资源 Git ignore、14/14 本地哈希校验通过；真实 OSCA 下载待安装 AWS CLI 后验证 | IMPLEMENTED |

状态只使用 `SPECIFIED | IMPLEMENTED | VERIFIED | BLOCKED`。代码合入后必须逐项更新，测试未运行或失败时不得写 `VERIFIED`。

## 9. 完成定义

- [x] 五类题目可创建、编辑、练习、判分和回看来源；
- [ ] PDF/DOCX/PPTX/TXT/Markdown/HTML/MHTML 可经 FileService 形成规范化文本；
- [ ] 资料可生成题库，失败项可见且可重试；
- [x] PDF/TXT/HTML/MHTML 整卷可导入草稿并经题目修改接口人工确认；
- [x] 智能复习读取 PlanGraph/mastery，完成后幂等回写 KnowledgeService；
- [x] 随机组卷、计时考试、分值和结果复盘可用；
- [x] 错题帮助只引用项目资料/知识点证据；
- [x] `.rhproj` / `.rhp` 兼容导入与新版项目包导入导出通过安全测试；
- [x] 共享项目包的搜索、上传、下载和权限可用；
- [x] 视觉小说入口完整复用 GalGame/Render，不执行生成代码；
- [ ] 前端以 ReciteHelper 功能为主，并通过桌面/移动端视觉与可访问性检查；
- [ ] Gateway、相关 .NET 服务、Render、Frontend 的单元/集成/build 全部有真实结果记录在 `docs/test_report.md`。
