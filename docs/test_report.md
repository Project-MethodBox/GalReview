# GalReview 当前全流程集成测试报告

## 1. 2026-07-31 基线结论

本节至第 9 节保留 2026-07-31 非 OCR 链路的原始测试记录。2026-08-01 新增的
GalGameService 集成结果见第 10 节；其中已完成的 GalGame 流程结论取代第 8 节对应的
历史待办状态。

本轮规定的非 OCR 全流程已经通过：

1. 用户可经 Gateway 注册并登录；
2. Gateway 可动态内省 Access Token，重复内省不会延长固定过期时间；
3. 用户可上传含内嵌文字的 PDF；
4. FileService 可在 `enableOcr=false` 时提取并交付规范化纯文本；
5. KnowledgeService 可经 Gateway 读取文本、构建分层知识图谱并写入 Neo4j；
6. Knowledge API 与 Neo4j 的章节、知识点和关系数量一致；
7. 最终容器完成 50 个真实 HTTP 契约断言，覆盖新增的 400/401/404/415/416/
   422/429 分支和统一错误信封。

最终样例得到 7 个真实章节、243 个去重知识点和 207 条
`PREREQUISITE` 关系。所有知识点初始掌握度为 0，先修子图为 DAG，每个知识点至少有
一个可回到原文的来源位置。

本结论不包含 OCR 功能正确性。OCRService 镜像已成功构建，但本轮没有启动 OCR
容器、调用 OCR 接口、下载或运行 OCR 模型，也没有测试识别准确率。

## 2. 测试基线

| 项目 | 值 |
|---|---|
| 执行时间 | 2026-07-31 11:50（Asia/Shanghai） |
| Git 分支 | `main` |
| 基线 HEAD | `2b1b03e82513aa00ef6b5ac1095f97f680915801` |
| 基线提交 | `2b1b03e Remix OCRService Bugs` |
| 测试对象 | 上述 HEAD 加当前工作区的冲突合并、适配及修复；尚未提交 |
| Docker Engine | 29.4.3，`overlayfs` |
| Docker Desktop 数据盘 | `D:\DockerData\DockerDesktopWSL\disk\docker_data.vhdx` |
| 测试资料 | `.artifacts/integration/农业生态学题库.pdf` |
| 文件大小 | 1,528,551 bytes |
| 文件 SHA-256 | `ECDA0AA80E2380564374D0B7373864708446FB5B3EA9E97C0D94E27384E53F0B` |

已确认 `C:\Users\Arabid\AppData\Local\Docker\wsl` 下没有 Docker VHDX；当前镜像和卷数据
位于 `D:\DockerData`。容器内部显示的 `/var/lib/docker` 是 Docker Desktop 虚拟机内
路径，不表示数据重新写回 C 盘。

## 3. 验证层级

为避免把未执行的功能写成“已测试”，本报告采用四种证据：

| 层级 | 含义 |
|---|---|
| E2E | 真实 HTTP、Gateway、服务进程和数据库共同参与 |
| 契约测试 | 进程内测试请求/响应、错误映射、授权或算法不变量 |
| 构建验证 | Release 编译或容器镜像构建成功，不代表功能正确 |
| 未测试 | 本轮明确不启动或缺少上游服务，不能宣称通过 |

`docs/contract.md` 中本轮实际执行的注册、登录、上传、非 OCR 文本提取、构图与图读取
主路径，以及 Gateway 信任边界，均已按下列 E2E 或契约测试回对。未在证据表中列出的
错误状态不宣称逐一经过 E2E。GalGameService、RenderService、事件总线和 OCR 的未来
接口仍保留为 `URGENT`/后续契约，不属于本轮“功能通过”结论。

## 4. 编译、单元测试与容器结果

| 组件 | 命令或证据 | 结果 |
|---|---|---|
| AuthService | `dotnet build GalGame.AuthService.csproj -c Release` | 通过，0 warning / 0 error |
| AuthService | `dotnet test Tests/GalGame.AuthService.Tests.csproj -c Release` | 8/8 通过 |
| UserService | `dotnet test Tests/GalGame.UserService.Tests.csproj -c Release` | 32/32 通过，含主项目 0 warning 构建 |
| FileService | `dotnet build GalGame.FileService.csproj -c Release` | 通过，0 warning / 0 error |
| KnowledgeService | `dotnet test KnowledgeService.Tests/KnowledgeService.Tests.csproj -c Release` | 105/105 通过 |
| Gateway | TypeScript `tsc` | 通过 |
| Gateway | Vitest | 12 files，166/166 通过 |
| 最终 HTTP 契约矩阵 | `.artifacts/integration/Test-ContractNegatives.ps1` | 50 个断言通过，`ocrInvoked=false` |
| Compose | `docker compose -f compose.integration.yaml config --quiet` | 通过 |
| 默认集成栈 | `docker compose ... up -d --wait` | 7 个组件全部 healthy |

已存在并验证可构建的镜像：

- `galreview-integration-auth-service:latest`
- `galreview-integration-user-service:latest`
- `galreview-integration-file-service:latest`
- `galreview-integration-knowledge-service:latest`
- `galreview-integration-gateway:latest`
- `galreview-integration-ocr-service:latest`
- `mongo:8.0`
- `neo4j:2026.06.0`

最终运行组件为 Gateway、AuthService、UserService、FileService、KnowledgeService、
MongoDB 和 Neo4j，均为 healthy。`ocr-service` 运行数量为 0。

Gateway 最终日志未再出现 `MaxListenersExceededWarning`。测试和运行日志仍可见
`http-proxy-middleware` 依赖触发的 Node `DEP0060 util._extend` 弃用提示；它没有造成
测试失败或请求错误，后续应通过升级第三方依赖消除。
针对故意发送的畸形 JSON/query，ASP.NET ExceptionHandlerMiddleware 会先记录通用
“unhandled exception”诊断行，随后自定义处理器明确记录 `Invalid ... request` 并返回
已断言的 400；按各服务自定义未处理错误标记复查为
`NO_UNEXPECTED_SERVICE_LOG_HITS`，不存在启动失败或服务级未处理异常。

## 5. 最终 E2E 结果

入口脚本：

```powershell
backend\FileService\Test-GatewayFileFlow.ps1 `
  -FilePath .artifacts\integration\农业生态学题库.pdf `
  -ContinueKnowledgeGraph `
  -SubjectHint AGRONOMY `
  -VerifyNeo4j
```

密钥由运行中的本地容器环境提供，测试输出和本文均未打印真实值。

### 5.1 用户与认证

| 断言 | 结果 |
|---|---|
| `POST /api/v1/auth/registrations` 创建用户和会话 | 通过 |
| `POST /api/v1/auth/sessions` 使用同一用户登录 | 通过 |
| 返回 Access Token | 通过 |
| 两次 INTERNAL introspection 均为 `active=true` | 通过 |
| 内省用户与注册用户相同 | 通过 |
| 内省前后 `expiresAt` 不变 | 通过 |
| `GET /api/v1/users/me` 返回同一用户资料 | 通过 |
| 管理员登录返回小写 UUID v4，随后访问受保护用户列表 | `201` / `200`，通过 |

最终容器还实际验证：Auth 畸形 JSON、缺失当前密码、null 刷新令牌均返回冻结信封；
管理员 null 用户名返回 401；`multi-use` 邀请缺少 `maxUses` 返回 400；密码重置确认
前五次无效证据返回 422，第六次返回 `429 RATE_LIMITED`。Auth 的 UserService
管理员资料查询响应校验器以 8/8 单测覆盖有效空数组、有效资料、畸形 JSON、缺失/
null data、非空 meta、空 traceId 和越权资料；最终真实管理员列表请求为 200。

资料更新路由的畸形/空值和 SubjectCode 边界均经 Gateway 或 UserService 测试验证，
响应含 `data: null`、空 `details` 和非空 `traceId`，没有落入 500。小写
`agronomy` 被规范化为 `AGRONOMY`，连字符 `bio-chem` 被 400 拒绝；INTERNAL
profile lookup 的缺失/null、空数组和去重前 501 项分别得到 400/400/200/400。

偏好接口在最终容器栈中经 Gateway 验证：畸形 JSON，以及缺失 required
`reducedMotion` 均为 `400 VALIDATION_ERROR`；可解析但越界的目标时长为
`422 BUSINESS_RULE_VIOLATION`。UserService 全量测试为 32/32。

### 5.2 文件上传与纯文本

| 断言 | 观测值 |
|---|---|
| multipart 上传 | 通过 |
| IngestionJob | `SUCCEEDED` |
| `enableOcr` | `false` |
| `ocrUsed` | `false` |
| parser | `files-text-v1` |
| 规范化文本长度 | 26,139 UTF-16 code units |
| 文本 SHA-256 | `5b233c1cb5ea7e7cd0cc37a4958bd9eb7ee8593ef39603a4cc72adeacc86ae1b` |
| `sourceMap` | 20 个有序、非重叠区间 |
| `blocks` | 20 个，文本均与声明区间逐字一致 |
| owner、UTF-8、NFC、LF、checksum、offset | 全部通过 |

FileService 使用 standalone MongoDB，因此完成发布采用：

```text
暂存完整文本且 Material=PROCESSING
→ IngestionJob=SUCCEEDED
→ Material=READY
```

这会允许极短的 `SUCCEEDED + PROCESSING` 可观察窗口，但不会出现
`READY` 早于 `SUCCEEDED`，也不会出现没有完整文本的 `READY`。启动恢复逻辑可从已暂存
文本完成最后发布。

另以未知扩展名 `utf8-fallback.bin` 和 `application/octet-stream` 执行非 OCR
上传/解析：任务为 `SUCCEEDED`，`enableOcr=false`、`ocrUsed=false`，得到 85 个
UTF-16 code unit、1 个来源区间和 1 个块，checksum 与原文重新计算结果一致。这证明
契约中的 UTF-8 文本兜底不是仅有代码分支而未执行。

最终容器还验证了空 multipart 上传和非法 `ocrMode` 均返回
`400 VALIDATION_ERROR`。非法模式请求在创建解析任务前即被拒绝，没有启动或调用
OCRService。

同一矩阵还验证：

- `.json + application/json` 在写入前返回 `415 MEDIA_TYPE_UNSUPPORTED`；
- 上传与列表查询的 `" agronomy "`/`agronomy` 均规范化并命中同一资料；
- 非法整型 query 返回统一 `400 VALIDATION_ERROR`；
- 不可满足的 Binary Range 返回空体 416；
- `application/pdf` 即使上传文件名为 `.bin`，仍按 PDF 解析并在不使用 OCR 时成功；
- 只含 script/style 的 HTML 解析任务进入 FAILED，未发布空的 READY 文档；
- 跨 owner 删除、owner 删除和重复删除依次为 404/204/404。

### 5.3 KnowledgeService 与 Neo4j

最终标识仅用于复现本次本地结果：

| 项目 | 值 |
|---|---|
| materialId | `7a7c9820-cf5a-43ff-a29a-b7aaa1283ad1` |
| buildId | `639b9d21-5f6b-43ae-b37f-59c0e47da44a` |
| graphId | `0bc21eaa-1a67-4bd7-96b6-ca64fad482eb` |
| 构建状态 | `SUCCEEDED` |
| 章节 | 7 |
| 知识点 | 243 |
| 关系 | 207 |
| 先修关系 | 207 |
| 章节切分模式 | `HEADING_RULES` |

章节标题：

1. 第一章 绪论
2. 第二章 种群与群落
3. 第三章 农业生态系统
4. 第四章 农业生态系统的物质循环
5. 第五章 能量流动
6. 第六章 农业生态系统的评价与优化
7. 第七章 生态农业与可持续发展

额外不变量：

- Knowledge API 计数与 Neo4j 计数均为 `1 graph / 7 chapters / 243 points /
  207 relations`；
- `PREREQUISITE` 子图通过拓扑排序，无环；
- 所有初始 mastery score 为 0；
- 每个知识点具有有效、非空来源位置；
- 章节响应只使用 `AUTO / HEADING_RULES / MARKDOWN / DELIMITER /
  FIXED_WINDOW` 契约枚举；
- 相同 UUID D `Idempotency-Key` 和相同请求复用原 build；
- 相同 key 携带不同 `subjectHint` 返回
  `409 IDEMPOTENCY_KEY_REUSED`。

端点级负向验证还覆盖：数字 enum token、畸形 JSON、缺失 mastery `graphId` 和缺失
INTERNAL PlanGraph `snapshotVersion` 均返回统一 400；非法连字符 SubjectCode 返回
`400 SUBJECT_CODE_INVALID`；缺失 review evidence required 字段返回
`400 REVIEW_EVIDENCE_INVALID`。KnowledgeService 最终全量测试为 105/105。

完整机器可读结果位于
`.artifacts/integration/knowledge-flow-report.json`；最终 HTTP 契约矩阵位于
`.artifacts/integration/contract-negative-report.json`，只保存用例名、状态和错误码，
不保存令牌或服务密钥。

## 6. 信任边界负向验证

从 Gateway 容器网络直接向服务发送仅用于验证的请求，结果如下：

| 目标 | 调用身份 | 结果 |
|---|---|---|
| File extracted-text | `KnowledgeService` | `200` |
| File extracted-text | `AuthService` | `403` |
| Knowledge PlanGraph | `GalGameService` | 通过 allowlist，随后因虚构资源返回 `404` |
| Knowledge PlanGraph | `RenderService` | `403` |
| Knowledge review evidence | `RenderService` | 通过 allowlist，随后因合成数据返回领域校验 `400` |
| Knowledge review evidence | `GalGameService` | `403` |

Gateway 契约测试还验证：

- AuthService 连接失败、5 秒超时、任意非 `200`、密钥错配 `403`、`5xx`、
  非 JSON 或畸形 `200` 均映射为 `503 SERVICE_UNAVAILABLE`；
- 只有包含完整字段和正确契约类型的 `active=false` 映射为用户侧
  `401 TOKEN_EXPIRED`；极简 `{active:false}`、非法 UUID 或非法 DateTime 均映射为
  `503`；
- `X-Correlation-Id` 会传给内省请求并保留为响应 `traceId`；
- `POST /api/v1/knowledge-graph-builds` 使用 generation 限流，GET 状态轮询使用
  general 限流；
- 文件本体硬上限为 10 MiB，Gateway/File multipart 整包前置上限为 11 MiB，
  恰好 10 MiB 的文件不会因协议开销被提前拒绝。
- 代理连接、DNS、管道和超时错误统一返回 `503 SERVICE_UNAVAILABLE`；只有不可解析
  的上游 HTTP 消息返回 `502 UPSTREAM_CONTRACT_INVALID`，真实连接拒绝、挂起超时
  和畸形响应测试均通过。

## 7. 本轮发现并修复的问题

| 问题 | 修复与验证 |
|---|---|
| OCR 更新与旧 stash 同路径覆盖，GitHub Desktop 无法恢复 | 按服务语义合并；保留当前 OCR/Mongo FileService；无未解决冲突 |
| GET 构图状态轮询错误消耗 generation 配额并返回 429 | POST 精确使用 generation，GET 使用 general；Gateway 测试和 E2E 通过 |
| PDF 每页仅一行导致 4 个固定窗口、4 点、0 边 | v2 内联章节和连续题号规则；最终 7 章、243 点、207 边 |
| 页眉污染知识点与伪依赖 | 版权页眉清理；真实样例未生成页眉标题或页眉摘要 |
| `HEADINGRULES/FIXEDWINDOW` 不符合契约枚举 | 显式映射为 `HEADING_RULES/FIXED_WINDOW`；单测与 E2E 通过 |
| 构图幂等冲突码被 repository 抢先替换 | 统一为 `IDEMPOTENCY_KEY_REUSED`；单测与 E2E 通过 |
| 图指纹遗漏学科和切分参数 | 纳入最终 subject、全部公开 SegmentationOptions；针对性测试通过 |
| Gateway 把 Auth 配置/上游故障伪装成无效令牌 | 非规范内省统一 503；UUID v4、UTC 时间、成功信封及故障映射正反例均覆盖 |
| Gateway 未分类代理错误返回 `502 INTERNAL_ERROR`，且超时可能先断开 socket | 传输故障统一 `503 SERVICE_UNAVAILABLE`，仅畸形 HTTP 为 `502 UPSTREAM_CONTRACT_INVALID`；Gateway 全量 166/166 通过 |
| Gateway/File 把 multipart 整包和文件本体都限为 10 MiB | 整包 11 MiB，文件本体仍硬限 10 MiB；边界测试通过 |
| File extracted-text 接受任意服务名 | 默认精确 allowlist 仅 KnowledgeService；运行时 200/403 验证通过 |
| File 先发布 READY 后写 SUCCEEDED | 改为暂存文本、SUCCEEDED、READY 的可恢复顺序 |
| Token 内省会滑动延长 Access/Refresh 到期时间 | 改为固定绝对有效期；E2E 两次内省到期时间相同 |
| 固定管理员 ID 不是 UUID v4，严格内省会使管理员路由返回 503 | 改为稳定小写 UUID v4；管理员登录和受保护用户列表经最终 Gateway 容器通过 |
| User PATCH/PUT 的空或畸形 JSON 被全局异常处理器映射为 500 | 独立更新 handler 将解析与字段错误统一映射为 `400 VALIDATION_ERROR`；最终 Gateway 容器请求通过 |
| User 偏好 PUT 的畸形 JSON 落入 500，数字字符串被宽松接收，required bool 缺失不可区分 | 独立偏好 handler 区分 `400` 缺失/传输/类型错误与 `422` 业务越界；User 全量 32/32 和最终 Gateway 请求通过 |
| File 非法 `ocrMode` 使用非统一错误码 | 统一为 `400 VALIDATION_ERROR`；最终容器请求通过且未调用 OCR |
| Gateway 代理数量触发 MaxListeners 警告 | 阈值按有限路由表设置；最终日志不再出现警告 |
| 未知扩展名被入口过滤，无法进入 UTF-8 兜底 | 允许 `text/*` 或 `application/octet-stream` 进入文本解析；真实 E2E 通过 |
| File 仅凭 MIME 接受、却只按扩展名分派解析器 | MIME 与扩展名统一决定解析器；`.bin + application/pdf` 的真实非 OCR 任务成功 |
| File 可把空结构解析结果发布为 READY | 完成态前校验非空 text/sourceMap/blocks 与全部区间；空 HTML 的真实任务进入 FAILED |
| File SubjectCode 与删除接口泄漏/规范化不一致 | 上传和列表统一 Trim+大写；跨 owner、已删除统一 404，活动/竞态为 409 |
| Knowledge 绑定错误可能绕过统一信封 | 启用 `ThrowOnBadRequest`；数字 enum、畸形 JSON、缺失 query 的真实端点均为统一 400 |
| Auth 将畸形 UserService 200 误作空结果或客户端 400 | 严格校验成功信封并映射 `502 UPSTREAM_CONTRACT_INVALID`；8/8 契约测试和真实有效响应通过 |

## 8. 明确未覆盖与 URGENT 项

- **OCR 未测试**：仅证明 Dockerfile 可构建；未启动、未调用、未评估准确率。
- **GalGameService / RenderService 未参加全流程（截至 2026-07-31）**：本轮只验证 KnowledgeService 的
  INTERNAL allowlist 和进程内计划/掌握度测试。题目生成、剧情生成、运行时会话和真实
  evidence 回传仍为对应负责人的 **URGENT** 集成项。GalGameService 后续集成结果见
  第 10 节；RenderService 与真实游玩回传仍未覆盖。
- **异步事件未测试**：当前闭环使用同步 INTERNAL HTTP；消息 broker、重试和 DLQ
  仍是后续统一基础设施契约。
- **File access grant 未测试且不属于当前可执行契约**：现有占位映射没有 grant token
  或服务端过期校验，已从当前接口目录移出；完整短期下载授权由 FileService/Gateway
  负责人作为 **URGENT** 项实现。
- **生产密钥与生产数据库未测试**：本轮使用本地开发配置。`DSAPI` 和 `BitchSDAU`
  没有注入、读取或记录，它们不是确定性提取和构图链路的依赖。
- **Mongo 跨集合原子提交**：standalone 部署没有事务；当前通过固定顺序、条件更新和
  启动恢复避免错误 `READY`。若生产要求完全不可观察的单一完成态，应将 Mongo 部署为
  replica set 并使用事务。

## 9. 最终一致性检查

交付时以下检查均已实际通过：

```powershell
git diff --check
git diff --name-only --diff-filter=U
git stash list
docker compose -f compose.integration.yaml config --quiet
docker compose -f compose.integration.yaml ps
```

原冲突 stash 已在语义合并后清除；其不可变备份保存在分支
`codex/stash-backup-20260731`（`96d4d24d2c9ecfb97408f73a3b5e72810923def0`），
便于需要时审计。`git diff --name-only --diff-filter=U` 和 stash 列表均为空；
Compose 配置校验为 0，七个默认组件全部 healthy，OCR 运行数为 0。

## 10. 2026-08-01 GalGame 全流程补充测试

### 10.1 结论与环境

在保留前一轮注册、登录、上传、非 OCR 提取和 KnowledgeService 构图能力的基础上，
本轮完成了复习计划到 GalGame 游戏包的本地集成验证。Assessment 与 Learning 两条计划
均可经 Gateway 提交生成任务、取得清单及内容，并通过游戏包校验接口。

由于 Windows 排除端口范围与当时的默认映射冲突，本轮曾使用一组仅限主机侧的临时端口。
该临时映射现已废止，不得复制到当前配置；当前宿主 published 默认值以
`contract.md` 第 9.5 节为准，实际值可由 `.env` 的 `*_HOST_PORT` 覆盖：

| 入口 | 当前默认地址 |
|---|---|
| Gateway | 旧临时映射已废止；当前为 `http://127.0.0.1:5000` |
| KnowledgeService 诊断入口 | 旧临时映射已废止；当前为 `http://127.0.0.1:5104` |

当时的默认主机映射在本机无法绑定；当前应在 `5000-5300` 内选择未被保留的宿主端口，
不应为绕过冲突而修改容器 target。
最终 `auth`、`file`、`user`、`knowledge`、`galgame`、`gateway`、`mongo`、`neo4j`
八个容器均为 `healthy`。

最终自动化回归结果：GalGameService Release 测试 `258/258` 通过，Gateway 的
`12/12` 个测试文件、`172/172` 个用例通过，Gateway TypeScript 构建退出码为 0。
Compose 已成功构建全部应用镜像并启动上述八个组件。

Docker Desktop 数据盘已核对为
`D:\DockerData\DockerDesktopWSL\disk\docker_data.vhdx`，本轮镜像和卷未落回 C 盘默认
数据位置。

### 10.2 真实资料桥接结果

真实输入为 `D:\AppData\test\农业生态学题库.pdf`，本轮明确关闭 OCR。注册与登录成功，
随后经 Gateway 完成文件处理和知识图谱构建：

| 项目 | 观测值 |
|---|---|
| IngestionJob | `SUCCEEDED` |
| `ocrRequested` / `ocrUsed` | `false` / `false` |
| parser | `files-text-v1` |
| 规范化文本长度 | 26,139 |
| 文本 SHA-256 | `5b233c1cb5ea7e7cd0cc37a4958bd9eb7ee8593ef39603a4cc72adeacc86ae1b` |
| source spans / blocks | 20 / 20 |
| 图谱规模 | 7 章、243 个知识点、207 条关系 |
| `PREREQUISITE` 关系 | 207 |
| 图性质 | DAG |
| 初始掌握度 | 全部为 0 |
| Neo4j 对账 | 章节、知识点和关系计数均与 API 一致 |

### 10.3 Assessment 游戏包

Assessment 计划包含 9 个节点，其中 3 个为 `questionTarget`，观测覆盖率为 `0.0354`；
生成结果包含 11 个场景。任务生成、manifest 和 content 获取均成功，并验证：

- 游戏包中的 `reviewPlanId` 与完整 `snapshotVersion` 和输入计划一致；
- 每个 `QUESTION` 的知识点绑定与选项处于同一场景；
- 题目选项显式包含 `answerKind` 和 `correct`，题目标识均为 UUID v4；
- 响应内容字节、manifest checksum 与 ETag 的 SHA-256 均为
  `770ebcfc90e2fbacdcadeffe24d31e5379fdcb10a34f1c8772a0bca061172913`；
- 携带对应 `If-None-Match` 再次获取内容返回 `304`；
- 原始游戏包校验返回 `200`；将一个选项的 `correct` 故意置为 `null` 后，校验返回
  `422`。

### 10.4 Learning 游戏包

Learning 计划包含 5 个节点，5 个均为 `questionTarget`，生成结果包含 7 个场景。任务生成
和内部游戏包校验成功。响应内容、manifest 与 ETag 对应的 SHA-256 为
`d7f560452f2573469fd1514b30eff0a8c266314bb70b20ddfd212d9452a8d318`，条件请求返回
`304`。

### 10.5 范围与部署限制

- OCR 不在本轮测试范围内，不能据此判断 OCR 识别效果。
- RenderService 和实际 GalGame runtime 不在当前仓库及 Compose 栈中。本轮仅使用契约中
  可信的 `RenderService` 服务身份调用游戏包校验接口，未执行真实游玩，也未验证最终
  掌握度 evidence 回传闭环。
- GalGameService 当前存储标识为 `ephemeral-memory`；容器重启会丢失生成任务和游戏包，
  只适用于本地集成与预发布环境。
- 远程服务器的 SSH 端口可达，但提供的凭据认证失败；为避免触发锁定已停止重试，远程
  部署未执行。仓库保留 `.env.deploy.example` 与 Compose 配置，可在凭据可用后快速部署。
  本报告不记录服务器地址、账号密码或服务密钥。

## 11. 2026-08-02 前端、Render 与部署闭环（撤销）

> 本节曾使用错误引入的 C# RenderService 原型得出结论。该原型已移除，本节涉及
> ReviewSession、结果提交和 mastery 回写的结论全部作废，不得作为当前实现证据。
> 当前有效结果以第 12 节为准。

### 11.1 结论

第 10 节中“RenderService 不在仓库及 Compose”的限制已经失效。本轮按
`docs/contract.md` 的接口完成并测试了 Frontend、Gateway、GalGameService、RenderService
与 KnowledgeService 的最终结果回写：用户可在页面中上传资料、构图、生成复习计划和
GalGame，逐场景作答后由 RenderService 提交证据，KnowledgeService 实际更新掌握度。

最终默认 Compose 同时运行 12 个 healthy 容器：Frontend、Gateway、UserService、
AuthService、FileService、KnowledgeService、GalGameService、RenderService、两套 MySQL、
MongoDB 和 Neo4j。OCRService 仍只属于可选 `ocr` profile，本轮没有启动或测试 OCR 功能。

Docker Desktop 的数据目录再次核对为 `D:\DockerData\DockerDesktopWSL`；本轮新增的
MySQL 镜像、应用镜像和数据卷没有改回 C 盘默认位置。

### 11.2 自动化回归

| 项目 | 结果 |
|---|---:|
| AuthService Release tests | 8 / 8 |
| UserService Release tests | 32 / 32 |
| KnowledgeService Release tests | 105 / 105 |
| GalGameService Release tests | 285 / 285 |
| RenderService .NET tests | 11 / 11 |
| RenderService JS Adapter tests | 6 / 6 |
| Gateway tests | 176 / 176 |
| Gateway TypeScript build | 通过 |
| Frontend TypeScript + Vite production build | 通过，106 modules |
| Frontend npm audit | 0 vulnerabilities |
| Frontend 代理不可用分支 | `503 SERVICE_UNAVAILABLE`，关联 ID 保持一致 |
| FileService Release build | 0 warning / 0 error |
| FileService NuGet vulnerability scan | 0 vulnerable packages |
| Compose config | 通过 |

FileService 的 `MongoDB.Driver` 从 3.5.0 升级到 3.10.0，消除了原先传递引入的
SharpCompress 和 Snappier 漏洞。Frontend 从存在安全公告的 `react-router-dom 7.18.2`
迁移到 `react-router 8.3.0`，容器中的 `npm ci` 与审计均通过。

Render 契约对照额外覆盖了容易抬高 mastery 的边界：`attemptNumber > 1` 时
`quality <= 3`；结果只覆盖实际作答的分支题目，但每条证据仍必须唯一且与题目、知识点、
选项和正确性绑定一致。Adapter 同时校验数量边界、UUID、引用与可达性，并在启动会话时
冻结核对 `packageId + reviewPlanId + snapshotVersion`。

### 11.3 API 全流程

测试入口使用 Frontend 的同源地址，因此既验证了浏览器部署入口，也验证了 `/api/*` 到
Gateway 的反向代理。真实输入仍为 `D:\AppData\test\农业生态学题库.pdf`，明确使用
`enableOcr=false`。

| 阶段 | 观测结果 |
|---|---|
| 注册、登录、用户资料 | 成功；用户与令牌 owner 一致 |
| 上传与提取 | `SUCCEEDED`，`ocrRequested=false`，`ocrUsed=false` |
| 规范化文本 | 26,139 UTF-16 code units，20 source spans，20 blocks |
| 构图 | 7 章、243 个知识点、207 条关系，Neo4j 对账一致，初始 mastery 全为 0 |
| Assessment Plan | 5 个节点，3 个实际出题点 |
| GalGame | 7 个场景，完整包 checksum 与响应字节一致 |
| Runtime 资源 | manifest、Adapter 和 WASM 均可经 Gateway 读取，WASM SHA-256 一致 |
| Render 会话 | 权威包读取和二次校验成功；事件重投去重、进度重投幂等 |
| 最终结果 | 首次 `ACCEPTED`，相同载荷重试 `DUPLICATE` |
| 冲突载荷 | `409 IDEMPOTENCY_CONFLICT` |
| 掌握度 | 3 个作答知识点由 0 更新为 35，版本同步递增 |

创建 ReviewSession 的成功同时证明了新增
`GET /internal/v1/game-packages/{packageId}?ownerUserId=...` 路由可由精确
`RenderService` 身份调用。测试期间发现 Gateway 最初把该接口注册成无参数静态路径，
真实请求会 404；已改为 `:packageId` 参数路由并加入路由测试。

### 11.4 浏览器端全流程

使用本机 Edge 进行无头浏览器测试，从 `/login` 开始实际操作页面：

1. 登录并进入主页；
2. 在 `/materials` 上传 PDF，等待非 OCR 提取和知识图谱完成；
3. 创建 Assessment Plan 并进入 `/review`；
4. 生成游戏包，加载 manifest、ES module Adapter 和 WASM；
5. 连续点击 8 个场景选择，记录 5 条作答证据；
6. 保存进度并提交最终结果，显示“复习完成”。

浏览器控制台错误为 0，未捕获页面异常为 0。完成页截图保存在忽略版本控制的
`.artifacts/integration/frontend-complete.png`。生产容器的 `/healthz`、根路径与 SPA
fallback `/materials` 均返回 200。

### 11.5 MySQL 服务器模式

首次把 AuthService/UserService 从 Mock 切换到服务器模板使用的 `MySql` 模式时，发现
MySQL 8.4 的 `caching_sha2_password` 会拒绝原连接串。Compose 已在两条内部连接串中补充
`AllowPublicKeyRetrieval=True`，MySQL 端口仍不对宿主或公网开放。

修复后完成了管理员登录、创建一次性邀请码、用户注册、用户登录和资料读取。随后重启
AuthService 与 UserService，再次使用同一账号登录并读取相同用户资料成功；两个 `/readyz`
均明确返回 `storage=mysql`，证明不是回退到内存模式。

Render 最终边界校验修复并重建镜像后，又在该 MySQL 模式下经当时的 Frontend 主机映射
（现已废止）重跑完整
API 与 Edge 浏览器流程。API 仍得到 7 章、243 个知识点、207 条关系和 3 个由 0 更新为
35 的 mastery；浏览器完成 8 次场景选择并提交 5 条作答证据，控制台错误和页面异常均为 0。

### 11.6 当前限制

- RenderService 的会话存储仍是 `ephemeral-memory`，容器重启会丢失进行中的会话；
- 当前执行引擎是 JS Adapter。WASM 响应只有 8 字节的最小可加载模块，`/readyz` 如实返回
  `wasmAbiComplete=false`；C++ ABI、内存所有权和真实帧渲染仍未完成；
- GalGameService 仍使用进程内游戏包存储；
- `ReviewCompleted v2` 消息总线尚未接入，当前闭环使用契约允许的同步 INTERNAL evidence；
- 未执行远程部署；`docs/deploy.md` 和 `.env.deploy.example` 已保留直接在 Linux 服务器启动、
  更新、回滚与备份的步骤，且不包含真实服务器凭据。

## 12. 2026-08-02 RenderService C++ / JS 基础壳复测

### 12.1 纠偏结论

RenderService 当前只是一套供后续负责人继续开发的 C++ / JS 工具链基础壳。错误加入的
ASP.NET Core 项目、C# 领域代码和 .NET 测试已经全部移除；仓库不再把临时 C# 原型当作
RenderService 实现。

当前镜像只完成以下工作：

- 使用 `g++` 编译并执行 `src/main.cpp` 基础壳自检；
- 由 JS 静态层公开 manifest、最小 WASM 和 ES module Adapter；
- `/readyz` 明确返回 `runtimeMode=SHELL`、`reviewSessionsAvailable=false` 和
  `wasmAbiComplete=false`；
- ReviewSession 路径直接返回 `501 RENDER_SESSION_NOT_IMPLEMENTED`。

### 12.2 实际测试

| 项目 | 结果 |
|---|---:|
| C++ 壳容器编译 | 通过，`g++ -std=c++23` |
| C++ 壳容器内执行 | 退出码 0 |
| JS Adapter tests | 6 / 6 |
| Frontend TypeScript + Vite build | 通过，106 modules |
| Gateway readiness | 200 |
| Runtime manifest | 200，`runtimeMode=SHELL` |
| WASM checksum | 与 manifest 一致 |
| ReviewSession 未实现分支 | 501，`RENDER_SESSION_NOT_IMPLEMENTED` |
| 默认 Compose | 12 个容器 healthy |

### 12.3 浏览器链路

Edge 无头浏览器重新执行了登录、上传 PDF、非 OCR 构图、Assessment Plan、GalGame 生成、
Adapter/WASM 加载和本地游玩。结果为 7 章、243 个知识点、207 条关系、8 次场景选择和
5 条浏览器本地作答记录；控制台错误与页面异常均为 0。

本轮没有调用 Render ReviewSession、progress、events 或 result，也没有更新 mastery。
完成页明确提示这是基础壳本地体验，结果未提交。该边界符合当前 RenderService 尚待后续
负责人开发的真实状态。

### 12.4 未完成范围

- ReviewSession、进度、事件、结果幂等与 KnowledgeService evidence 回传；
- 完整 C++ WASM ABI、内存所有权、RuntimeState 与真实帧渲染；
- `ReviewCompleted v2` 消息总线和生产持久化；
- OCR 功能与远程服务器部署。

## 13. 2026-08-02 前端 Prototype 对照与移动端复核

### 13.1 对照范围

`design/Prototype` 只有登录、注册、忘记密码和主页四张 `3456×2234` 静态浅色 PNG，按
2 倍导出还原后的验收视口为 `1728×1117`。原稿没有移动端、深色主题、错误态、加载态或
交互态，因此桌面浅色页面按原稿对照，移动端按同一灰阶、圆角、图标和卡片语言补充设计。

桌面稿的 `1728×1117` 只作为比例和视觉语言基准，不再作为固定画布。认证内容区、字号、
间距和品牌标志使用视口相关尺寸；主页使用 `100dvh` 和两行弹性网格，让功能卡占满标题区
之外的剩余高度。输入框浅色填充保持 `#DBDADA`，主页卡片保持 `#BDBDBD`、外框为
`#C6C6C6`、工具栏为 `#BDBDBD`，但不会把原稿坐标和 414 px 卡片高度无条件套到其他屏幕。

以下差异为有意保留，不能为了静态截图改坏已冻结契约或基本可用性：

- 登录使用邮箱而不是原稿中的用户名；
- 注册使用管理员邀请码而不是原稿中的邮箱验证码；
- 注册/忘记密码保留返回登录入口，主页保留退出登录入口；
- 无自定义头像时按 UserService 契约显示用户名首字符；
- 深色主题没有对应 Prototype，只验证功能和可读性，不宣称与浅色稿一致。

### 13.2 移动端设计

移动端以 `390×844` 为主要检查尺寸：认证页左右留白 20 px、输入框高 58 px、操作按钮高
50 px，并保留右上角紧凑品牌标志；登录主按钮独占一行，次要入口双列排列。主页把“继续”
设为主卡，“知识点/资料上传”为双列快捷卡，“知识图谱”为宽卡；工具栏触控区为 48 px，
用户信息、头像回退和退出操作均可见。`768×1024` 平板宽度也已检查，主页无横向溢出。

### 13.3 本轮修复

- “知识点”改为独立页面，不再与“知识图谱”两个入口显示同一内容；
- 知识点和关系读取持续消费 6.1 分页响应的 `nextCursor`，不再静默截断为前 100 条；
- 删除主页通往假设置占位页的入口，用户胶囊只展示真实用户资料；
- 主题选择写入浏览器本地状态，刷新后保持，并同步浏览器 `theme-color`；
- 默认头像改为用户名首字符，存在 `avatarUrl` 时仍显示真实头像；
- 主页头部在 840 px 以下提前纵向排列，覆盖原先 701--828 px 可能溢出的区间。

`docs/contract.md` 的前端路由说明已补入 `/knowledge`，并明确知识点/图谱页面必须继续读取
`nextCursor`。本轮没有新增或修改任何后端接口。

### 13.4 验证结果

| 项目 | 结果 |
|---|---:|
| Frontend TypeScript + Vite production build | 通过，107 modules |
| Frontend 容器 | healthy |
| 前端冒烟检查 | 36 / 36 |
| 390×844 登录/忘密/主页横向溢出 | 无 |
| 768×1024 主页横向溢出 | 无 |
| 密码显隐、注册/忘密导航 | 通过 |
| 主题即时切换及刷新保持 | 通过 |
| 默认头像首字符 | 通过 |
| 知识点与知识图谱独立路由 | 通过 |
| 知识点/关系两页游标读取 | 通过 |
| 1366×768、1728×1117、2560×1440 桌面满屏与无滚动溢出 | 通过 |
| 三档桌面卡片随视口高度连续放缩 | 通过 |
| 1728×1117 浅色色值断言 | 通过 |

游标测试通过浏览器拦截构造两页合法契约响应，分别确认知识点页面请求两页、图谱页面请求
两页知识点和两页关系；没有重复执行此前已经通过的注册、上传、提取、构图、GalGame 和
Render 基础壳全流程。最终截图保存在忽略版本控制的 `.artifacts/visual-audit/`。

## 14. 宿主发布端口策略与纠偏记录

2026-08-02 复核发现，早先把“服务器防火墙只放行 `5000-5300`”错误扩展到了容器 target、
数据库监听、SMTP、系统代理和测试端口。该做法改变了协议语义，且把 Compose 宿主映射写死，
在 Windows WinNAT 保留段存在时无法通过 `.env` 避让。原端口策略结论自本次纠偏起作废；
接口路径、方法、鉴权与数据契约始终未因宿主端口调整而改变。

正确边界只包含 Docker 发布到宿主机的端口：Gateway `5000`、KnowledgeService `5104`、
Frontend `5120`、Neo4j Browser `5254` 和 Bolt `5255`。五项均为 `.env` 中可覆盖的
`*_HOST_PORT` 默认值，覆盖后仍须处于 `5000-5300`。对应容器 target 分别保持
`5000/8080/8080/7474/7687`；User/Auth MySQL 使用 `3306`、MongoDB 使用 `27017`，均不向
宿主发布。SMTP 默认 `465`，代理端口按系统配置，测试监听由操作系统分配临时端口。

### 14.1 纠偏后的静态检查与历史结果边界

| 检查项 | 结果或适用范围 |
|---|---|
| `Test-PortPolicy.ps1` | 通过；现在只检查 Compose/docker publish 的宿主侧和 `*_HOST_PORT` 默认值，不扫描 target、`EXPOSE`、URI、连接串、SMTP、代理或测试端口 |
| 宿主端口参数化 | `GATEWAY_HOST_PORT`、`KNOWLEDGE_HOST_PORT`、`FRONTEND_HOST_PORT`、`NEO4J_BROWSER_HOST_PORT`、`NEO4J_BOLT_HOST_PORT` 均有范围内默认值 |
| 数据库发布 | User/Auth MySQL 与 MongoDB 均不发布到宿主机；其原生内部端口不属于防火墙策略 |
| 早先 12 容器 healthy、Gateway readiness 与全流程结果 | 仍可证明当时业务链路可运行，但不能证明错误的内部端口迁移合理；纠偏后的容器拓扑必须以本轮后续实际复测为准 |
| 早先 KnowledgeService `105/105`、Gateway `176/176`、Render Adapter `6/6`、Frontend build/UI smoke | 功能回归结果保留；其中固定 `5260-5299` 测试端口的做法已废止 |

### 14.2 非 OCR 主链路

当时的容器环境使用 `D:\AppData\test\农业生态学题库.pdf` 执行过一次真实主链路：

- Gateway 注册、登录、令牌内省和用户资料读取成功；
- 上传和提取任务为 `SUCCEEDED`，`ocrRequested=false`、`ocrUsed=false`；
- 得到 26,139 个 UTF-16 code unit、20 个 source span 和 20 个结构块，checksum 与偏移校验通过；
- KnowledgeService 构建出 7 章、243 个知识点和 207 条先修关系；
- API 与 Neo4j 数量一致，先修子图无环，初始 mastery 全为 0；
- 幂等重放稳定，冲突请求返回 `IDEMPOTENCY_KEY_REUSED`。

此前已经通过的 GalGame 生成业务用例没有重复执行；当时通过镜像重建、Gateway readiness
和既有自动化测试确认业务服务可达。该结论不再用于支持错误的内部端口策略。Render 基础壳的 manifest、Adapter 和
WASM 均再次经 Gateway 读取成功；manifest 如实为 `runtimeMode=SHELL`、
`reviewSessionsAvailable=false`，WASM 为 8 字节最小模块。OCR 功能仍未测试。

## 15. 2026-08-02 Render 会话与掌握度闭环（cpp-wasm-0.2.0）

### 15.1 结论

RenderService 已从基础壳升级为真实实现：§8.3 八个 ABI 函数在 C++ 中实现并经
emcc 4.0.13 编译为 standalone WASM（179 KB），§8.1 五个 ReviewSession 接口与
§8.2.1 学习证据回传上线。默认 12 容器环境中，manifest 经 Gateway 首次如实返回
`runtimeMode=FULL`、`reviewSessionsAvailable=true`、`wasmAbiComplete=true`
（三个标志均由服务端对实际 wasm 产物导出自省与回调配置推导，非硬编码）。

### 15.2 自动化回归

| 项目 | 结果 |
|---|---:|
| C++ 原生自检（JSON/校验器/状态机/ABI） | 129 / 129 |
| JS Adapter 测试（含 JS↔WASM 校验器奇偶校验） | 7 / 7 |
| ReviewSession 领域 + HTTP wire 测试 | 11 / 11 |
| build_support fixture 回归 | 183 / 183 |
| scripts/Test-PortPolicy.ps1 | 通过 |
| 镜像构建门禁（容器内编译 + 自检 + 服务层测试） | 通过 |

奇偶校验将 `backend/GalGameService/mocks/` 全部包同时喂给 JS 与 WASM 两个校验器并
断言 `valid` 与 `(path, code)` 集合一致；期间发现并修复了 C++ 侧对"多 QUESTION 绑定
场景同时触发 SCORING_WITHOUT_QUESTION"的分支遗漏。

### 15.3 集成 E2E（scripts/e2e-session.mjs，经 Gateway :5000）

真实输入为脚本内置的 Markdown 题库（三章、每章 4 条名词解释），`enableOcr=false`：

| 阶段 | 观测结果 |
|---|---|
| 注册、登录（邀请码） | 成功 |
| 上传与提取 | `SUCCEEDED`，`ocrUsed=false` |
| 构图 | 3 章、3 知识点，初始 mastery 全为 0 |
| Assessment Plan | 3 节点、3 个出题点 |
| GalGame 生成 | 5 场景、3 道题，包与计划快照一致 |
| 创建会话 | 权威包 INTERNAL 读取 + 共同校验通过；`reviewPlanId+snapshotVersion` 冻结核对一致 |
| 事件 | 首投 3 条全收，重投 3 条全去重 |
| 进度 | 版本 0→1；相同载荷重投幂等返回原快照 |
| 结果 | 首次 `ACCEPTED`；重放 `DUPLICATE` 且 resultId 不变；篡改载荷 `409 IDEMPOTENCY_CONFLICT` |
| 掌握度 | 3 个作答知识点 0→35（quality=5 首答的 SM-2 期望值），version 递增至 1 |
| 会话终态 | `COMPLETED`，completedAt 非空 |

### 15.4 当前限制

- 会话存储为 ephemeral-memory（/readyz 如实上报），容器重启丢失进行中会话；
- `ReviewCompleted v2` 消息总线仍未接入，本轮闭环使用契约允许的同步 INTERNAL evidence；
- 浏览器端（前端 `/review` 走服务端会话路径）本轮未做人工操作验证，前端逻辑按
  `reviewSessionsAvailable` 自动切换，建议下轮补一次浏览器操作确认；
- OCR 与远程部署仍未测试。

## 16. 2026-08-02 端口纠偏后的容器复验

按“仅约束宿主发布端口”的规则重新构建并启动 `compose.integration.yaml`，12 个容器全部
进入 `healthy`。实际发布结果为 Gateway `5000 -> 5000`、KnowledgeService
`5104 -> 8080`、Frontend `5120 -> 8080`、Neo4j Browser `5254 -> 7474`、Neo4j Bolt
`5255 -> 7687`；五个宿主默认端口均可通过对应的 `*_HOST_PORT` 环境变量覆盖。

| 复验项 | 结果 |
|---|---:|
| `docker compose up -d --build --wait` | 通过，12 / 12 healthy |
| Gateway `http://127.0.0.1:5000/readyz` | HTTP 200 |
| KnowledgeService `http://127.0.0.1:5104/readyz` | HTTP 200 |
| Frontend `http://127.0.0.1:5120/healthz` | HTTP 200 |
| Neo4j Browser `http://127.0.0.1:5254/` | HTTP 200 |
| User/Auth MySQL 容器内 `3306` | `mysqld is alive` |
| MongoDB 容器内 `27017` | ping = 1 |
| Neo4j 容器内 Bolt `7687` | `RETURN 1` 成功 |
| `scripts/Test-PortPolicy.ps1` | 通过 |

MySQL `3306`、MongoDB `27017` 及各微服务内部监听端口没有发布到宿主，因此不会扩大
服务器防火墙放行范围。SMTP 和系统代理端口也不再被项目端口策略改写。
