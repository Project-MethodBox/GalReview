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
`Neo4j__Password`；FileService 要求服务密钥时再提供
`GatewayMaterialText__ServiceKey`。仓库中的 appsettings 不保存密钥。

默认地址：

- KnowledgeService：`http://localhost:5080`
- Neo4j Browser：`http://localhost:7474`
- Neo4j Bolt：`bolt://localhost:7687`

生产环境必须覆盖 `Neo4j__Password`、`GatewayMaterialText__BaseUrl` 和
`GatewayMaterialText__ServiceKey`，不要使用 compose 的开发默认值。

## 调用边界

- 用户接口只信任 Gateway 注入的 `X-User-Id`。
- 内部接口只信任 Gateway 注入的 `X-Service-Name`。
- 图谱构建还要求 `Idempotency-Key`。
- KnowledgeService 只选择测试/学习目标和依赖图，不生成题目或 GalGame 内容。

关键入口：

- `POST /api/v1/knowledge-graph-builds`
- `POST /api/v1/assessment-plans`
- `POST /api/v1/learning-plans`
- `GET /internal/v1/review-plans/{reviewPlanId}/graph`
- `PUT /internal/v1/review-evidence/{resultId}`

## 算法约束

- 测试选题优化单调次模覆盖函数，使用最大未覆盖依赖影响做贪心选择。
- 学习节点的原始优先级固定为
  `max_target(forgettingRisk(target) * maxProductInfluence(node,target))`；
  不混合多个经验权重，也不按 hub 出度求和。
- 学习依赖按完整路径包选择；章节外节点数量与总权重均不超过 30%。
- 权重通过带单点上限和外部组上限的约束投影归一化。
- 直接证据使用 SM-2 调度；共享祖先在一次提交内只采用最大实际正向增量。
