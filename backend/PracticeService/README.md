# PracticeService

PracticeService 承载产品主线的 ReciteHelper 复习内核，负责学习项目、五类题目、普通/智能练习、计时试卷、答案判分、项目包与共享资源。GalReview 的知识图谱、SM-2 与故事生成作为该复习内核的图谱计划和故事复习模式接入，不反转主从关系。跨服务契约以 `docs/contract.md` 第 14 节为准，迁移决策与状态以 `docs/recitehelper-migration.md` 为准。

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

## 本地资产

```powershell
.\scripts\import-recitehelper-assets.ps1
```

脚本默认从用户确认的完整运行时目录导入全部 `Resources`，并校验 SBERT、XGBoost、vocab 和 tokenizer 的 SHA-256。构建不联网下载模型。

## 运行

```powershell
dotnet run --project backend\PracticeService\PracticeService.API\PracticeService.API.csproj -- --urls http://127.0.0.1:5107 --Gateway:ServiceKey moonstone-local-gateway-key --PracticeStore:Provider Memory
```

持久化运行使用 `ConnectionStrings:PracticeDatabase` 与 `MongoDb:Database=qzwl_practice`。生成计费还要求 Gateway 可达且 `Gateway:ServiceName=PracticeService`、`Gateway:ServiceKey` 与部署配置一致。浏览器不得直连 5107。
