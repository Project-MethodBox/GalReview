# KnowledgeService

本目录只实现 GalReview 的 KnowledgeService。FileService、Gateway、
GalGameService 与 RenderService 的阻塞契约在
[`docs/contract.md`](../../docs/contract.md) 中以 **URGENT** 标注，不在本服务内实现。

## 本地运行

需要 .NET 10；真实运行还需要 Neo4j 和 FileService 的规范化纯文本接口。

```powershell
dotnet test .\KnowledgeService.slnx
docker compose up --build
```

若直接使用 `dotnet run`，先通过环境变量提供
`Neo4j__Password`。`Gateway__ServiceKey` 必须与 Gateway 转发给本服务的
`KNOWLEDGE_SERVICE_KEY` 一致；`GatewayMaterialText__ServiceKey` 是本服务调用
Gateway 时使用的同一服务身份密钥。开发配置使用
`moonstone-local-gateway-key`，生产环境必须覆盖。

默认地址：

- KnowledgeService：`http://localhost:5080`
- Neo4j Browser：`http://localhost:7474`
- Neo4j Bolt：`bolt://localhost:7687`

生产环境必须覆盖 `Neo4j__Password`、`GatewayMaterialText__BaseUrl` 和
`GatewayMaterialText__ServiceKey`，不要使用 compose 的开发默认值。
镜像内置 `/readyz` 健康检查；只有 Neo4j 可查询且 schema 初始化成功后才会
进入 healthy。

## 调用边界

- `/api/v1` 与 `/internal/v1` 首先以固定时间摘要比较验证 Gateway 注入的
  `X-Gateway-Key`。
- 用户接口在网关验证通过后只信任 Gateway 注入的 `X-User-Id`。
- 内部接口在网关验证通过后只信任 Gateway 注入的 `X-Service-Name`。
- 图谱构建还要求非空 UUID D 格式的 `Idempotency-Key`；服务会规范化为
  小写连字符形式后持久化。同键同请求返回既有任务，同键不同请求返回
  `409 IDEMPOTENCY_KEY_REUSED`。
- 读取 FileService 纯文本时会验证 `ownerUserId` 与构图任务用户相同，并校验
  `sourceMapVersion=1`、UTF-16 `sourceMap` 和 `blocks` 的范围与文本一致性。
- FileService 的来源标签、页码或段落会投影为知识点的可读来源位置。
- KnowledgeService 只消费 FileService 已完成的纯文本结果，不调用
  OCRService，也不持有 OCR/API 模型密钥。
- KnowledgeService 只选择测试/学习目标和依赖图，不生成题目或 GalGame 内容。
- INTERNAL PlanGraph 只允许 `GalGameService` 读取；掌握度 evidence 只允许
  `RenderService` 写入。两者均使用 Gateway 重新注入的精确服务名。

关键入口：

- `POST /api/v1/knowledge-graph-builds`
- `POST /api/v1/assessment-plans`
- `POST /api/v1/learning-plans`
- `GET /internal/v1/review-plans/{reviewPlanId}/graph`
- `PUT /internal/v1/review-evidence/{resultId}`

## Gateway → 构图 → Neo4j 联调

FileService 完成上传和文本提取、获得用户 Access Token 与 `materialId` 后，可运行：

```powershell
$env:GALREVIEW_ACCESS_TOKEN = "<access-token>"
$env:NEO4J_PASSWORD = "<neo4j-password>"
.\scripts\Test-KnowledgeFlow.ps1 `
  -MaterialId "<material-id>" `
  -VerifyNeo4j `
  -ReportPath ".\TestResults\knowledge-flow.json"
```

脚本只通过 Gateway 创建并轮询构图任务，随后校验章节、知识点、关系端点、
初始掌握度、来源位置和 `PREREQUISITE` DAG；启用 `-VerifyNeo4j` 时还会通过
Neo4j 事务 HTTP 接口交叉核对实际节点和关系数量。它不会测试或调用 OCR，
可由仓库级“注册 → 登录 → 上传 → 提取”测试在取得 `materialId` 后直接调用。

## 算法约束

- 当前 `chapter-segmenter-v2` 可识别分页提取文本中的行内中文章标题；
  `knowledge-extractor-v2` 可在题库型章节中连续解析编号题项。章节响应的
  `segmentationMode` 固定使用
  `AUTO/HEADING_RULES/MARKDOWN/DELIMITER/FIXED_WINDOW`。
- 图谱指纹覆盖最终 `subjectCode`，以及构图 API 已暴露的 mode、delimiter、
  min/max chapter characters 和 fixed-window characters；这些输入变化不会
  错误复用旧学科或旧切分结果。
- 测试选题优化单调次模覆盖函数，使用最大未覆盖依赖影响做贪心选择。
- 学习节点的原始优先级固定为
  `max_target(forgettingRisk(target) * maxProductInfluence(node,target))`；
  不混合多个经验权重，也不按 hub 出度求和。
- 学习依赖按完整路径包选择；章节外节点数量与总权重均不超过 30%。
- 权重通过带单点上限和外部组上限的约束投影归一化。
- 直接证据使用 SM-2 调度；共享祖先在一次提交内只采用最大实际正向增量。
