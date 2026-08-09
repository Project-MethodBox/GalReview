# PracticeService

PracticeService 承载产品主线的 ReciteHelper 复习内核，负责研习册、五类题目、章节/智能练习、计时试卷、答案判分、项目包与共享资源。GalReview 的知识图谱、SM-2 与故事生成作为研习册内的识网计划和故事回响接入，不反转主从关系。跨服务契约以 `docs/contract.md` 第 14 节为准，迁移决策与状态以 `docs/recitehelper-migration.md` 为准。

## 四层与 CQRS

- `PracticeService.API`：HTTP、Gateway 身份、请求/响应 DTO 和统一信封；只向 MediatR 发送 Command/Query。
- `PracticeService.Application`：MediatR Handler、应用端口、所有权校验和跨资源编排。
- `PracticeService.Domain`：聚合、值对象、题型/组卷/规范化不变量；零基础设施依赖。
- `PracticeService.Persistence`：MongoDB repository、共享包 GridFS 与 Gateway client；本进程不装载模型。

引用方向由项目引用固定：API → Application/Domain/Persistence，Persistence → Application/Domain，Application → Domain。Domain 不引用其他层；API 不直接访问 repository、Mongo、模型或 Gateway client。

## 边界

- MongoDB `qzwl_practice` 只保存 Practice 聚合；不保存文件正文、知识图谱、mastery 或 GamePackage。
- 读取 PlanGraph、提交证据都携带 `PracticeService` 身份经 Gateway。
- 主观题按已核对标准答案拆分必要事实，经 Gateway 调用 ModelService，由固定多语种 NLI 逐项给出蕴含、遗漏、矛盾或不确定；Practice Domain 的离散状态机才产生 correct/quality。SBERT 只保留兼容诊断，XGBoost q 已退出生产。
- 填空题使用 Domain 的版本化确定性等价规则：接受数值、结构空白/全半角和封闭专业别名的等价写法，不调用 NLI、不做编辑距离或任意相似度；多空数量与位置仍必须一致。
- NLI 置信不足、模型未配置/损坏或推理失败时自动 `ABSTAINED`，`correct/quality` 均为空，不写 KnowledgeService evidence。用户无需自评、对照标准答案或标注 q。
- `/readyz` 只报告 Practice 存储状态和 `gateway:model-service` 依赖标识；逐模型资产状态归 ModelService `/readyz`。拒判响应 `meta.degraded=true`；严禁降级为编辑距离后判错。KnowledgeService 仍是 SM-2 唯一写入方。
- `.rhproj`、`.rhp` 与 `.qzwlp` 导入要求映射到当前用户自己的 READY material；旧包不会变成脱离资料库的第二套聚合。
- 题目生成在读取资料和 PlanGraph 后，通过 Gateway 向 CreditService 预授权；成功按实际输入与生成内容结算，失败或无产物释放 held。credits 不足的 `402` 与详情原样交给前端处理。
- 图谱归研习册而不是归藏书阁资料。浏览器先创建 `graphId=null` 的新册，再以 `studyProjectId + materialId` 请求 KnowledgeService 为本册识网，最后通过乐观并发 PATCH 绑定返回图谱；PracticeService 会反查 `studyProjectId` 与资料范围，拒绝跨册或旧 material-scoped 图谱。
- 绑定本册 READY 识网后立即为全部章节创建 OPEN Learning Plan（最多 1000 点）并自动成题，不能建立空册后要求用户再找首次成题入口。首次生成省略 `targetCount`，由通过校验的唯一原题/知识原子决定规模；自动题型仅为单选、填空、名词解释、简答，判断题只来自整卷导入或人工题录。
- `recite-question-v2` 先区分显式题库、半结构化讲义和普通教材正文。原题/答案/选项与“术语：定义”“问题标题：分点答案”优先忠实提取；普通正文再按本册 PlanGraph 的知识点与连续原文形成答案原子，调用 OpenAI-compatible 模型生成并进行与生成调用分离的第二遍来源约束 QA 回验。
- READY 是全布尔门禁：题型 schema、逐字 offset/quote/checksum、同一证据支持标准答案、第二遍回验答案一致、题干不泄露答案、唯一 pointId 必须全部成立。名词解释焦点、标题/标签、同资料来源区间和来源文本按离散顺序自动绑定；历史草稿也可经现有 PATCH 或会话入口自动修复，但来源失效或多候选时仍保留 DRAFT。单选必须恰有 A-D 四项且只有一个最佳答案；禁止按数组序号、随机词或模糊位置猜签。
- 未配置 `QuestionGeneration:ApiKey` 时，显式题库与可核对半结构化问答仍可生成；普通正文返回 `QUESTION_MODEL_NOT_CONFIGURED`，不会回退为“请概括下述内容”、机械填空或随机干扰项。模型实际结算只接受供应商 `usage.total_tokens`；缺失 usage 作为上游契约错误处理。
- SMART 与模拟试卷严格按 PlanGraph 目标顺序“一点一题”；计划内缺题点被跳过并继续扫描后续已覆盖点，不以计划外题目凑数，只有计划与 READY 题库零交集才返回 `QUESTION_COVERAGE_GAP`。普通答题、试卷和故事回响都通过同一 KnowledgeService evidence 入口更新 mastery。
- PracticeService 不复制 SM-2 或图谱排序。`sm2-graph-v2` 由 KnowledgeService 先用 SM-2 的 `nextReviewAt` 形成到期集合，再用图谱次模覆盖选点，不存在“SM-2 百分比 + 图谱百分比”的混合分。

## 模型服务依赖

PracticeService 不持有 `Resources`。开发主观题判分或构建完整 Compose 前，按
`backend/ModelService/README.md` 运行 `scripts/download-model-resources.ps1`，再启动独立
ModelService。模型、tokenizer、许可证、哈希清单、NLI 门禁和资产就绪检查全部归该服务；
PracticeService 只通过 Gateway 的 INTERNAL 接口消费逐事实 verdict。

## 运行

```powershell
dotnet run --project backend\PracticeService\PracticeService.API\PracticeService.API.csproj -- --urls http://127.0.0.1:5107 --Gateway:ServiceKey moonstone-local-gateway-key --PracticeStore:Provider Memory
```

持久化运行使用 `ConnectionStrings:PracticeDatabase` 与 `MongoDb:Database=qzwl_practice`。生成计费还要求 Gateway 可达且 `Gateway:ServiceName=PracticeService`、`Gateway:ServiceKey` 与部署配置一致。浏览器不得直连 5107。

题目模型配置可写入 `PracticeService.API/appsettings*.json`，生产环境优先使用环境变量，避免提交密钥：

| 配置 | 环境变量 | 默认/限制 |
|---|---|---|
| `QuestionGeneration:ApiKey` | `QuestionGeneration__ApiKey`（Compose 由 `DEEPSEEK_API_KEY` 注入） | 空值表示只运行可核对的结构化提取 |
| `QuestionGeneration:Endpoint` | `QuestionGeneration__Endpoint` | `https://api.deepseek.com/chat/completions` |
| `QuestionGeneration:Model` | `QuestionGeneration__Model` | `deepseek-v4-flash` |
| `QuestionGeneration:Parallelism` | `QuestionGeneration__Parallelism` | 1-8，默认 4 |

Gateway 与前端的题库生成超时均为 600 秒。适用资料暂限农学、社科、人文等事实、概念、关系、
比较、步骤和论述型内容；计算题、公式推导和复杂理工科题不属于 v2 自动生成范围。
