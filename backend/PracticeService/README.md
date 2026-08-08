# PracticeService

PracticeService 承载产品主线的 ReciteHelper 复习内核，负责研习册、五类题目、章节/智能练习、计时试卷、答案判分、项目包与共享资源。GalReview 的知识图谱、SM-2 与故事生成作为研习册内的识网计划和故事回响接入，不反转主从关系。跨服务契约以 `docs/contract.md` 第 14 节为准，迁移决策与状态以 `docs/recitehelper-migration.md` 为准。

## 四层与 CQRS

- `PracticeService.API`：HTTP、Gateway 身份、请求/响应 DTO 和统一信封；只向 MediatR 发送 Command/Query。
- `PracticeService.Application`：MediatR Handler、应用端口、所有权校验和跨资源编排。
- `PracticeService.Domain`：聚合、值对象、题型/组卷/规范化不变量；零基础设施依赖。
- `PracticeService.Persistence`：MongoDB repository、共享包 GridFS、Gateway client、SBERT/XGBoost 推理与资产状态。

引用方向由项目引用固定：API → Application/Domain/Persistence，Persistence → Application/Domain，Application → Domain。Domain 不引用其他层；API 不直接访问 repository、Mongo、模型或 Gateway client。

## 边界

- MongoDB `qzwl_practice` 只保存 Practice 聚合；不保存文件正文、知识图谱、mastery 或 GamePackage。
- 读取 PlanGraph、提交证据都携带 `PracticeService` 身份经 Gateway。
- 本地 SBERT/XGBoost 模型只参与答案相似度和 quality 估计；KnowledgeService 仍是 SM-2 唯一写入方。
- 未配置/损坏的模型显式降级，`/readyz` 返回逐资产状态，答题响应 `meta.degraded=true`。
- `.rhproj`、`.rhp` 与 `.qzwlp` 导入要求映射到当前用户自己的 READY material；旧包不会变成脱离资料库的第二套聚合。
- 题目生成在读取资料和 PlanGraph 后，通过 Gateway 向 CreditService 预授权；成功按实际输入与生成内容结算，失败或无产物释放 held。credits 不足的 `402` 与详情原样交给前端处理。
- 图谱归研习册而不是归藏书阁资料。浏览器先创建 `graphId=null` 的新册，再以 `studyProjectId + materialId` 请求 KnowledgeService 为本册识网，最后通过乐观并发 PATCH 绑定返回图谱；PracticeService 会反查 `studyProjectId` 与资料范围，拒绝跨册或旧 material-scoped 图谱。
- 绑定本册 READY 识网后立即为全部章节创建 OPEN PlanGraph 并自动成题，不能建立空册后要求用户再找首次成题入口。首次生成沿用 ReciteHelper 的单选、填空、名词解释、简答四类；生成器先轮转覆盖请求的四种题型并同步轮换知识点，再重复题型，不能因知识点数量先达到目标数而把首批题全部生成为单选。判断题只来自整卷导入或人工题录。
- 自动成题必须按目标知识点的标题或唯一标签在原文中找到证据后才贴签，禁止按数组序号轮转。当前确定性生成器只有在答案、唯一知识点和精确原文出处均成立时才创建题目，因此结果直接 READY；整卷导入及未来不能机械校验的模型结果仍保持 DRAFT。
- SMART 与模拟试卷严格按 PlanGraph 目标顺序“一点一题”；缺题返回 `QUESTION_COVERAGE_GAP`，不以计划外题目凑数。普通答题、试卷和故事回响都通过同一 KnowledgeService evidence 入口更新 mastery。
- PracticeService 不复制 SM-2 或图谱排序。`sm2-graph-v2` 由 KnowledgeService 先用 SM-2 的 `nextReviewAt` 形成到期集合，再用图谱次模覆盖选点，不存在“SM-2 百分比 + 图谱百分比”的混合分。

## 本地资产（开发前必做）

`Resources` 中的 ONNX 模型、tokenizer、词表和 Jieba 数据不进入 Git。新检出仓库后，开发、测试、发布或构建 PracticeService 镜像之前，必须先安装 AWS CLI v2，并直接运行仓库内的下载脚本。脚本顶部已配置仅能读取和列举 `20277-gal-res` 的凭据，不能访问其他储桶或写入对象：

```powershell
.\scripts\download-practice-resources.ps1
```

下载脚本和哈希清单受版本控制，开发者无需另行配置凭据。若云端权限策略发生扩大，必须先重新评估该凭据是否仍适合随仓库分发。

下载脚本使用 OSCA 的 S3 兼容 endpoint、Path-Style 和 `us-east-1`，默认将 `20277-gal-res` 储桶根目录同步到 `backend\PracticeService\Resources`，不会删除目标目录中的额外文件。若云端保留了顶层 `Resources/` 目录，则加 `-RemotePrefix Resources`；若要下载到其他位置，则传 `-DestinationPath <目录>`。下载完成后会按 `resources.manifest.json` 对全部 14 个文件校验长度和 SHA-256，任一缺失或不一致都会失败。

维护者可在没有云存储的受信本机使用下列离线回退，但它不是开发者默认流程：

```powershell
.\scripts\import-recitehelper-assets.ps1 -ReciteHelperRoot D:\Projects\ReciteHelper
```

只有资源目标目录被 Git 忽略；下载脚本必须随仓库保留。不得通过 `-SkipHashVerification` 为正常开发或部署绕过校验。

## 运行

```powershell
dotnet run --project backend\PracticeService\PracticeService.API\PracticeService.API.csproj -- --urls http://127.0.0.1:5107 --Gateway:ServiceKey moonstone-local-gateway-key --PracticeStore:Provider Memory
```

持久化运行使用 `ConnectionStrings:PracticeDatabase` 与 `MongoDb:Database=qzwl_practice`。生成计费还要求 Gateway 可达且 `Gateway:ServiceName=PracticeService`、`Gateway:ServiceKey` 与部署配置一致。浏览器不得直连 5107。
