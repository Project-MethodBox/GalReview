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
- **生产密钥与生产数据库未测试**：本轮使用本地开发配置。`DEEPSEEK_API_KEY` 和 `BitchSDAU`
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
- 浏览器端已完成操作验证：真实登录后经 `/review` 生成 CAMPUS 游戏包、创建服务端
  会话（页面显示 cpp-wasm-0.2.0）、UI 点击作答 2 题并提交，页面提示"本次复习结果
  已提交，共记录 2 条作答证据"，控制台错误为 0，API 复核对应知识点 mastery 0→35
  （`DIRECT:ASSESSMENT:quality=5`，version 1）；TS 迁移后复测；
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

## 17. 2026-08-02 文件上传 Bad Gateway 排查与修复

运行态检查确认 Frontend、Gateway、FileService 和 MongoDB 均 healthy，Gateway 容器访问
FileService readiness 为 HTTP 200。10 MiB multipart 探针可以完整通过 Frontend 和 Gateway，
仓库内两层代理的请求体限制不是故障点；失败现场也没有 `POST /api/v1/materials` 到达
FileService，因此界面所见的纯文本/HTML Bad Gateway 来源于仓库外层反向代理。

同时发现浏览器客户端在检查 HTTP 状态前无条件解析 JSON，导致外层代理返回的 HTML/纯文本
`413/502/504` 被统一改写成客户端 `502 UPSTREAM_CONTRACT_INVALID`。本轮修复后，客户端保留
真实 HTTP 状态、响应类型和 `X-Correlation-Id`；上传、文字提取、已有图谱读取和构图错误也
分别标明阶段。Frontend 与 Gateway 代理增加了不记录凭证的结构化错误日志。接口路径、请求、
成功响应和服务错误信封均未改变。

| 复验项 | 结果 |
|---|---:|
| Frontend TypeScript + Vite production build | 通过，110 modules |
| Gateway TypeScript build | 通过 |
| Gateway 自动化测试 | 176 / 176 |
| Nginx 上传反代示例 `nginx -t` | 通过 |
| 浏览器代理非 JSON 错误保真 | 413 与 502 均保留真实状态和对应提示 |
| 修复后 Gateway / Frontend 容器 | healthy |
| 2.38 MiB 真实 PDF 经 Frontend `:5120` 上传 | HTTP 201 |
| 1.53 MiB PDF 上传、非 OCR 提取与构图 | 7 章、243 点、207 条关系，DAG 合法 |
| Frontend 入口完整注册至 mastery 闭环 | 通过，3 / 3 掌握度更新 |

部署侧新增 `deploy/nginx/galreview.conf.example`：外层请求体允许 12 MiB，上传读写超时为
190 秒并关闭请求缓冲。应用仍按契约拒绝超过 10 MiB 的单文件。

## 18. 2026-08-02 GalGame 叙事提示词重构

### 18.1 变更边界

本轮没有改变 Gateway 路由、请求体、异步任务状态、GamePackage schema 1.0 或 RenderService
读取方式。原 `GameGenerator` 继续负责确定性骨架；新增 `galgame-narrative-v2` 叙事层，只能
重写 scene title、dialogue 与 choice 显示文本。所有 ID、跳转、知识绑定、`correct`、
`scoreDelta`、assets、reviewPlanId 和 snapshotVersion 均由代码锁定。

提示词按“整包共同主线”工作，要求知识作为线索、规则、工具、争议或行动依据改变剧情，禁止
退化为“知识点讲解—来看看这道题—本轮复习结束”。内部草稿使用 `groundingQuotes` 核对事实
出处，使用 `knowledgeUse` 说明知识怎样改变当前局面；两者在最终 GamePackage 中删除。

### 18.2 自动化与真实模型验证

| 项目 | 结果 |
|---|---:|
| GalGameService 全量测试 | 348 / 348 |
| 新增叙事单元/集成测试 | 15 个，全部通过 |
| DeepSeek `deepseek-v4-pro` 真实 JSON Output | 通过 |
| GalGameService build | 通过，0 warning / 0 error |
| `docker compose config --quiet` | 通过 |
| `scripts/Test-PortPolicy.ps1` | 通过 |
| GalGameService 镜像重建 | 未执行；本机 Docker Linux engine 未运行，Compose 静态解析已通过 |

真实模型测试使用仓库测试 PlanGraph（CAMPUS / STANDARD），以
`GALGAME_RUN_LIVE_LLM_TEST=1` 显式启用，API key 只从宿主 `DEEPSEEK_API_KEY` 读取。最终草稿通过：

- sceneId/choiceId 集合完整且无新增；
- EXPLAIN/QUESTION 的依据可逐字回溯到绑定节点；
- 对白包含对应概念锚点，且没有暴露权重、掌握度或内部 ID；
- 装配前后所有锁定字段保持不变；
- 最终 GamePackage 通过现有跨字段校验器。

第一次校准暴露出“强迫对白逐字复述依据会重新产生教材腔”的问题，因此最终实现把原文引用
保留为隐藏审计字段，只要求对白自然包含概念锚点，并增加“删除知识后剧情是否仍能原样成立”
与“删除选择后事件是否仍以相同方式推进”两项提示词拒收检查。真实模型复测通过。

### 18.3 异常路径

测试覆盖恶意 summary 提示注入、缺失/伪造 scene 或 choice ID、错误 promptVersion、无依据
题目、知识场景没有 grounding、模板化问答文本、非法草稿整包回退，以及第一次失败后的一次
有界修复。Mock 模式强制关闭外部调用；模型超时、HTTP 错误、空响应、非 JSON、修复后仍非法
时均不保存半成品，继续返回契约有效的确定性包。供应商响应正文、异常详情和 API key 不进入
公开 job error。

本轮没有重新执行文件上传、文本提取、KnowledgeService 构图、浏览器渲染和 mastery 全流程；
这些接口及数据结构未变，沿用本报告前述已通过结果。

## 19. 2026-08-02 GalGameService CI 修复复验

干净还原发现 `GalGame.GalGameService.csproj` 漏写 `MongoDB.Driver` 依赖，本机旧的
`obj/project.assets.json` 曾掩盖该问题；同时，合并提交误删了 `GameGenerator` 已有的资源、
学习模式、讲解深度和语义干扰项实现，却保留了对应测试。本轮恢复显式依赖和被误删的既有实现，
未改变 Gateway 路由、请求响应结构或 GamePackage schema，因此 `contract.md` 无需调整。

| 复验项 | 结果 |
|---|---:|
| `dotnet restore --force --no-cache` | 通过 |
| CI 原命令 `dotnet test ... --nologo` | 348 / 348 通过 |
| `git diff --check` | 通过 |

## 20. 2026-08-02 Gateway CI 缓存与安装修复

Gateway workflow 的 `cache-dependency-path` 正确指向 `gateway/package-lock.json`，但提交
`507b0a2` 删除了该文件并将其加入 `gateway/.gitignore`，导致 `actions/setup-node` 无法计算
npm 缓存键；即使关闭缓存，后续 `npm ci` 也会因缺少 lockfile 失败。本轮恢复原 lockfile 并
解除忽略，workflow 与 Gateway 接口均无需修改。

| 复验项 | 结果 |
|---|---:|
| lockfile v3 与 `package.json` 根依赖一致 | 通过 |
| `npm ci --no-audit --no-fund` | 通过，干净安装 177 packages |
| TypeScript build | 通过 |
| Gateway 自动化测试 | 178 / 178 通过 |
| `git diff --check` | 通过 |

日志中的 Action Node 20/24 与 `punycode` 内容是非致命弃用提示，本次失败点是缺失的缓存依赖
路径。项目测试运行时仍由 workflow 固定为 Node 22。

## 21. 2026-08-03 上传竞态残余根治（vite dev 跳）与全路径压测收官

上一轮修复后 vite dev 路径仍有"已接受残余"。本轮用 socket 级仪器化 vite（记录每个客户端
连接的生命周期与 destroy 调用栈）抓到了两个独立机制并全部根治：

1. **CL 提前完成绕过网关的排空保护。** 网关 bodyDrain 冲刷的错误信封带 `Content-Length`，
   中继跳（vite http-proxy）的 HTTP 客户端凑满 CL 字节即判定响应完成并立刻结束对客户端的
   响应，不等网关排空后的延迟 FIN；此时客户端请求体未上传完、响应又是 `connection: close`
   （http-proxy 无 agent 的默认），Node 在响应 finish 时销毁客户端 socket，RST 冲掉在途
   上传与客户端未读缓冲。仪器化日志中损坏请求均呈现 `PROXYRES 429` 早于 `req-end`、随后
   `res-finish → DESTROY` 的固定序列；服务端（FileService/网关限流器）对这些请求零痕迹。
2. **旧钩子的 unpipe 悬空腿。** 此前 vite 代理钩子在 proxyRes 时 `req.unpipe()` 截断
   "客户端体 → 网关"转发，网关排空等不到剩余字节，10 秒超时后硬毁该连接；销毁事件在 vite
   进程内间歇性殃及无关的在途请求（组合探针中 S3#8 恰在 S2 竞态请求 +10s 时刻死亡，可
   复现）。该钩子是网关修复前的遗物，其"本地排空"作用已由机制 1 的正确修复取代。

修复（`frontend/vite.config.ts`，仅 dev 代理段）：移除 unpipe 钩子，改为与
`frontend/server.mjs` 的 `endAfterDrain`、网关 `bodyDrain` 同构的 **drain-before-end**
包装——响应字节照常立即转发，`res.end` 推迟到客户端请求体收完；不截断上游腿；排空有
12 MiB 上限与 10 秒超时，越界时在响应完成后只断开本连接。接口、构建产物与生产路径行为
均未改变。

| 复验项 | 结果 |
|---|---:|
| vite dev 路径全矩阵 ×12（S1 401 / S2 429 / S3 413 / S4 正常 / S5 恶劣客户端） | 两次独立运行均 PASS，0 mangled |
| vite dev 路径 413 专项 ×8（限流窗清空，直达 FileService） | 8/8 信封完整 |
| 生产代理路径全矩阵 ×12 | PASS，0 mangled（此前"已接受残余" 2 项消失） |
| 生产代理路径 413 专项 ×8 | 8/8 信封完整 |
| keep-alive 头部与 X-Correlation-Id 存活探针（vite + 生产双路径） | 全部回显 |
| frontend `tsc --noEmit` 与 Vite production build | 通过 |
| S5 停滞 12 秒 / 中途撕裂后服务存活 | 双路径均 YES |

对照：修复前基线 vite 路径 14/39 损坏（S3 全灭）；仅移除旧钩子后仍余 5/10（机制 1 暴露）；
drain-before-end 后为 0。所有场景要求响应为完整契约信封且延迟 ≤ 4 秒。dev 路径仍保留一个
文档化边界：单请求体超过网关 12 MiB 排空上限时该连接会被明示断开（生产路径行为一致）。

## 22. 2026-08-03 GalGameService Mongo 持久化 Guid 序列化修复

E2E 闭环回归在"创建游戏生成任务"处失败：网关返回 500 `INTERNAL_ERROR`，GalGameService
日志为 `GuidSerializer cannot serialize a Guid when GuidRepresentation is Unspecified`
（`GameGenerationJob.GenerationId`）。检查发现 `qzwl_galgame` 库的 `game_jobs`、
`game_manifests` 集合均为 0 文档——MongoGameStore 自启用以来从未成功写入：此前全部闭环
验证走的是 InMemoryGameStore，合并启用 Mongo 持久化后首次真实流量即触发。MongoDB.Driver
3.x 起 Guid 序列化必须显式指定表示，类映射对 Guid 成员的 AutoMap 缺少该配置。

修复（`backend/GalGameService/MongoGameStore.cs`）：在 `MongoGameStoreMappings.
EnsureRegistered` 注册 `GuidSerializer(GuidRepresentation.Standard)`，与同文件原生查询
使用的 `BsonBinaryData(..., GuidRepresentation.Standard)` 保持一致；库中无旧表示数据，
无兼容负担。接口、GamePackage schema 与任务状态机均未改变。

| 复验项 | 结果 |
|---|---:|
| CI 原命令 `dotnet test .../GalGame.GalGameService.Tests.csproj --nologo` | 348 / 348 通过 |
| galgame-service 镜像重建与容器重建 | healthy |
| E2E 闭环（注册→提取→构图→计划→游戏包→复习会话→结果→mastery） | PASS，3/3 掌握度 0 → 35 |
| Mongo 持久化实证 | game_jobs / game_packages / game_manifests / game_owners 各 1 文档 |

## 23. 2026-08-03 全组件巡检与缺陷修复

对全部成员组件（Gateway、Frontend、FileService、AuthService、UserService、
KnowledgeService、GalGameService，以及编排/CI/文档横切面）做了一轮以实证为准的缺陷巡检：
每条发现都要求给出"触发条件 → 错误结果"的完整代码级因果链，严重级发现另经一轮以驳倒为
目标的独立复核，未能复推的一律丢弃。本节记录经复核成立并已修复的问题。所有修复均保持
原有接口、请求响应结构与业务语义不变。

### 23.1 安全

**匿名限流可被请求头绕过（Gateway，实测确认）。** `app.set('trust proxy', 1)` 使
`req.ip` 无条件采信客户端自带的 `X-Forwarded-For`，而该头未被 headerSanitizer 剥离，且
Gateway 端口在集成与演示部署中直接对外发布。实测：对 `POST /api/v1/auth/sessions` 连续
请求时，固定 XFF 的 `ratelimit-remaining` 正常递减（19→16），每次轮换 XFF 则恒为 19——
即任何人都能靠改一个请求头无限刷新匿名配额，登录/注册/找回密码的爆破节流完全失效。
修复：新增 `TRUST_PROXY` 配置（`gateway/src/config.ts`、`limits.ts` 与 `app.ts`），
**默认不采信** `X-Forwarded-For`，`req.ip` 取 socket 对端地址；部署在可信反代之后时显式
声明该代理的地址/网段。`frontend/server.mjs` 相应地以真实 socket 对端地址覆盖客户端自带
的 `X-Forwarded-*`，使配置该项后网关拿到的是可信值。已认证路由本就按 userId 计量，不受
影响。

**真实 SMTP 凭据入库（AuthService）。** `appsettings.Development.json` 提交了可用的
126.com 邮箱账号与授权码，且该文件未被 `.dockerignore` 排除、会随 `COPY . .` 进入镜像。
修复：文件内改为 `CHANGE_ME_*` 占位（容器一律经 compose 已支持的 `SMTP_*` → `Email__*`
环境变量注入，机制未变），并在 `.dockerignore` 排除本机开发配置与 launchSettings。
**该凭据须视为已泄露：仓库历史仍包含原值，必须在邮箱侧吊销/更换授权码。**

### 23.2 可用性与状态一致性

| 组件 | 问题 | 修复 |
|---|---|---|
| Frontend | `GET /%` 等畸形百分号路径使 `decodeURIComponent` 抛 URIError，异常逸出为未处理拒绝并终止进程（免认证、单请求即可循环打断服务） | `server.mjs` 就地捕获并回退原始路径，入口再加 `.catch` 兜底返回 400 |
| Frontend | 客户端上传中断时不销毁上游腿，网关连接被占用至 180 秒空闲超时 | 监听 `request` 关闭，未收到响应且请求体未完时销毁上游请求 |
| Frontend | 刷新令牌请求遇到 503/超时也清除本地会话，把仍有效的会话踢下线 | 仅在服务端明确拒绝（401/403 或 AUTH_REQUIRED/TOKEN_EXPIRED）时清除，管理端同理 |
| FileService | 在 Kestrel 监听之前同步 `await` 全量重解析（含最长 20 分钟/次的 OCR），期间 /healthz、/readyz 不可达，容器被判 unhealthy 并阻塞 gateway、frontend 启动 | 恢复改到 `ApplicationStarted` 之后的后台任务；索引创建改为可失败可重试，MongoDB 不可用时按契约由 /readyz 返回 503 而不是构造函数抛出 |
| FileService | 超过 multipart 限制的上传返回 400 VALIDATION_ERROR（契约要求 413） | 异常处理器识别 413 状态与 `InvalidDataException` 链，输出 FILE_TOO_LARGE |
| FileService | 空白文件名触发 `ArgumentException` → 500 | 入口补 400 校验 |
| FileService | 上传补偿删除复用已取消的请求令牌，客户端断连时 GridFS 内容永久孤儿化 | 补偿改用 `CancellationToken.None` 并记录清理失败 |
| FileService | 删除与创建解析任务的 check-then-act 竞态（已删除资料复活 / 活动任务下内容被删） | 两处状态迁移改为条件写（Mongo 过滤器带期望状态、内存实现用 CAS），冲突时按既有 404/409 路径处理 |
| FileService | 崩溃窗口留下"任务 QUEUED 但资料未 PROCESSING"或"任务 FAILED 但资料仍 PROCESSING"，该资料永远 409、既不能重试也不能删除 | 启动恢复补齐这两类残留态的收敛 |
| AuthService | 注册时凭证与邀请码已提交后，`CreateProfileAsync` 只捕获 `HttpRequestException`；超时/客户端断连抛的取消异常绕过补偿，留下孤儿凭证并烧掉 single-use 邀请码 | 该段包入 try/catch 后统一回滚，补偿调用不再使用请求取消令牌 |
| AuthService | `Rotate` 忽略撤销 UPDATE 的受影响行数，同一刷新令牌可被并发兑换出两个有效会话 | 以"撤销影响 1 行"作为原子抢占，未抢到则返回 null |
| AuthService | 畸形收件地址使 `MailboxAddress.Parse` 抛出，密码重置返回 500 且残留有效重置令牌 | 改用 `TryParse`，失败按"发送失败"返回，交由既有补偿删除令牌 |
| UserService | `UpdateProfile` 忽略受影响行数产生"幻影成功"（资料已被并发删除仍返回 200） | 受影响行数不为 1 时返回 null，上层按契约回 404 |
| UserService | 偏好写入撞外键约束（1452）逸出为 500 | 捕获该错误码返回 null，上层回 404 |
| KnowledgeService | 构建队列是纯内存 Channel 且无启动恢复：重启后持久化为 Running 的任务永远不会被处理，GET 永远返回 RUNNING，幂等键也救不回来 | 新增 `ListUnfinishedBuildJobsAsync` 与 `GraphBuildRecoveryService`，启动后把 Queued/Running 任务重新排队（处理器对 Succeeded 短路，重放安全） |
| KnowledgeService | 切分参数越界、DELIMITER 模式缺 delimiter 被 202 受理后异步失败（契约要求同步 400） | `CreateGraphBuildCommandHandler` 补齐与切分器完全一致的同步校验，后台校验保留为防御层 |
| KnowledgeService | 概念去重合并标签无上限，同概念跨约 18 个以上章节时超出 1-20 校验，整份资料构建确定性失败 | 合并后按同一上限截断 |
| GalGameService | MongoDB 不可达时驱动抛 `TimeoutException`，`catch (MongoException)` 接不住，优雅降级失效（每请求阻塞约 30 秒后 500） | 构造函数与 `RecoverStaleJobs` 同时捕获 `TimeoutException` |
| GalGameService | 叙事模型响应对 chunked（无 Content-Length）无实际大小上限，可无界缓冲至 OOM | 改为按上限流式读取，超限即中止 |
| GalGameService | 内存模式下 `_jobLocks` 只增不减 | 淘汰 job 时一并移除锁对象 |
| Gateway | 请求体上限只在有 Content-Length 时生效，chunked 请求可绕过 11 MiB / 10 MB 前置限制 | 阈值抽到 `limits.ts` 共用，代理阶段对无 Content-Length 的 chunked 请求流式计数，超限返回 413 信封 |

### 23.3 复验

| 复验项 | 结果 |
|---|---:|
| Gateway 自动化测试（新增 chunked 上限 2 项、限流分桶 2 项） | 188 / 188 通过 |
| AuthService | 8 / 8 通过 |
| UserService | 32 / 32 通过 |
| KnowledgeService | 105 / 105 通过 |
| GalGameService | 348 / 348 通过 |
| FileService `dotnet build` | 通过，0 warning / 0 error |
| Frontend `tsc --noEmit` 与 Vite production build | 通过 |
| XFF 伪造探针（修复前后对照） | 修复前轮换 XFF 恒得满配额（remaining 恒为 19）；修复后按真实对端稳定递减（19→15） |

容器全部重建后在集成栈上的端到端复验：

| 集成复验项（Gateway :5000 / Frontend :5220 / vite dev :5223） | 结果 |
|---|---:|
| 全部 12 个容器 | healthy |
| 畸形百分号路径 `/%`、`/%E0%A4%A`、`/%zz`、`/a/%` | 均返回 200（SPA 回退），前端进程存活 |
| chunked（无 Content-Length）超限请求 | 413 FILE_TOO_LARGE 信封 |
| 10.5 MB 上传 | 413 FILE_TOO_LARGE（此前多部分限制路径会退化为 400） |
| 空白文件名上传 | 400 VALIDATION_ERROR（此前 500） |
| 正常上传 | 201 |
| E2E 闭环（注册→提取→构图→计划→游戏包→会话→结果→mastery） | PASS，3/3 掌握度 0 → 35 |
| 上传竞态全矩阵 ×12（生产代理 :5220） | PASS，0 mangled |
| 上传竞态全矩阵 ×12（vite dev :5223） | PASS，0 mangled |
| keep-alive 头部与 X-Correlation-Id 存活（双路径） | 全部回显 |

### 23.4 记录但未改动

- `/api/v1/assessment-plans` 与 `/api/v1/learning-plans` 归入 `generation` 限流类别，与
  contract.md §9 "只有 knowledge-graph-builds 与 game-generations 两个 POST 使用
  generation 限流"的枚举不一致。二者确为较昂贵的创建型端点，究竟改代码还是改契约属
  PM 决策，此处仅记录。
- AuthService 的 time-window 邀请码在未指定 maxUses 时被隐式赋予 10 次上限，契约对该类型
  只描述了时间窗。同样属语义待澄清项，未擅自更改既有行为。

## 24. 2026-08-08 ReciteHelper 复习内核迁移验证

本轮把 ReciteHelper 的复习资料库、题库、练习、试卷、项目包与资源中心作为产品主线迁入
四层 PracticeService；GalReview 的知识图谱、SM-2 和故事生成作为 StudyProject 下的复习
能力复用。测试使用本机完整 ReciteHelper 运行时资源，未修改源仓库中的用户工作区改动。

| 验证项 | 结果 |
|---|---:|
| PracticeService solution build | PASS，0 warning / 0 error |
| PracticeService 单元测试 | PASS，15 / 15 |
| 其中旧 `.rhproj` 五题型、`.qzwlp` round-trip、ZIP traversal | PASS |
| 其中资料生成出处、生成幂等冲突、整卷缺答案不猜测 | PASS |
| 其中 MongoDB Guid 表示 | PASS，UUID Standard |
| 其中项目 material 所有权 | PASS，拒绝他人资料并接受本人 READY 文本 |
| KnowledgeService PracticeService allowlist 目标测试 | PASS，12 / 12 |
| Gateway 全量 Vitest | PASS，15 files，199 / 199 |
| Gateway 项目包请求体边界 | PASS，50 MiB 文件 + 1 MiB multipart；资料上传原限制未变 |
| FileService build（含 PPTX/MHTML parser） | PASS，0 warning / 0 error |
| Frontend TypeScript + Vite production build | PASS；仅保留既有 KnowledgeDag >500 kB chunk 警告 |
| `docker compose -f compose.integration.yaml config --quiet` | PASS |
| PracticeService 容器镜像 build | PASS；14 项资源门禁通过后完成 Linux publish |

模型关键资产校验值：SBERT `994a58868f7abacacbf2192aa0aae8f56da8c4505dbde2740c861b24426ede6b`，
XGBoost `53b563e2df2c6026f7a996b4d8f63e83c63bbf64d1dde5e03a3c7f9dbf688ea0`，
`vocab.txt` `45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c`。

本节初次记录时尚未运行全栈容器；现已由第 27 节的真实 Gateway 全链冒烟结果取代。普通题库
复习、故事复习、SM-2 证据回写和 MySQL credits 结算均已有持久化集成结果。

## 25. 2026-08-08 credits 计费制度迁移验证

本轮取消注册邀请码，新增 CreditService，并把 Practice 题目生成与 GalGame 故事生成接入
“生成前预授权、成功后按实际使用量结算、失败释放”的同一计费链路。旧用户通过幂等惰性
建账获得一次初始额度，不执行 Auth/Credit 跨数据库扫描。面向用户的页面只显示 credits，
没有展示内部 token 换算规则。

| 验证项 | 结果 |
|---|---:|
| CreditService 四层 solution build + tests | PASS，6 / 6 |
| 初始额度幂等、旧用户惰性建账、兑换单次使用 | PASS |
| 预授权不足 402、实际结算、失败释放 | PASS |
| AuthService 无邀请码注册与 credits 建账补偿 | PASS，11 / 11 |
| PracticeService 生成计费与现有功能 | PASS，15 / 15 |
| GalGameService usage 累计、计费与现有功能 | PASS，362 / 362 |
| Gateway Credit 路由、配置与全量 Vitest | PASS，15 files，203 / 203 |
| Frontend 注册、设置页、管理员兑换码与不足跳转 production build | PASS；仅既有 KnowledgeDag chunk 警告 |
| `docker compose -f compose.integration.yaml config --quiet` | PASS |
| CreditService / 全栈容器镜像 build 与 MySQL E2E | PASS；真实预授权、结算、兑换及故事生成扣费见第 27 节 |

安全检查结论：兑换码持久化只保存 SHA-256 摘要，完整明文仅在批量创建响应返回；管理员列表
只返回掩码；余额使用整数内部单位；`operationId` 负责计费幂等；Gateway 按目标服务密钥转发。
购买页固定为 `https://pay.ldxp.cn/shop/7CX09W5E`，只有用户在 credits 不足提示中确认后跳转。

第 23.4 节关于 time-window 邀请码的待澄清记录已被本轮决策取代：邀请码接口已撤下且注册不
再读取邀请码。遗留表和 repository 仅作迁移兼容，不是可调用能力。

## 26. 2026-08-08 PracticeService OSCA 资源恢复验证

本轮将 `backend/PracticeService/Resources` 从源码分发范围中移除。仓库保留单文件下载器及
14 文件的路径、长度与 SHA-256 清单；下载器内置的凭据由所有者确认为只能读取和列举
`20277-gal-res`，不能访问其他储桶或执行写入。PracticeService Dockerfile 在 publish 前检查
关键模型、tokenizer 与词表是否已经恢复。

| 验证项 | 结果 |
|---|---:|
| `download-practice-resources.ps1` PowerShell AST parser | PASS，0 syntax error |
| 缺少 AWS CLI 的失败路径 | PASS，联网和文件同步前明确报错 |
| `Resources` Git ignore | PASS，模型与 `vocab.txt` 均命中精确规则 |
| 下载脚本可跟踪状态 | PASS，不命中 `.gitignore`，可随仓库提交 |
| 下载凭据权限 | OWNER-CONFIRMED，仅 `20277-gal-res` 读取/列举；本轮未独立审计云端 IAM 策略 |
| 仓库外恢复备份对 `resources.manifest.json` | PASS，14 / 14 路径、长度、SHA-256 一致 |
| OSCA S3 真实列举、同步与下载后复验 | NOT RUN：当前环境未安装 AWS CLI v2 |
| PracticeService 容器缺失门禁 | PASS；关键模型/词表存在时镜像构建通过 |
| Git 中断恢复 | PASS，本地 `main` 纯 fast-forward 到远端 `feat: Integrate recite helper`，6 个 stash 冲突已逐项解决 |
| Git 暂存与冲突状态 | PASS，unmerged 0、staged 0、冲突标记 0 |
| 仓库工作树资源残留 | PASS；冒烟临时恢复的 14 个文件已再次移到仓库外，源目录不存在 |

未把“脚本语法通过”当作云端下载成功。开发者或部署人员必须安装 AWS CLI v2，运行仓库内
下载脚本并看到 `manifest verification: passed` 后，才能继续开发、测试或执行
`docker compose build`。默认储桶根目录与云端对象布局若不一致，应显式使用
`-RemotePrefix Resources`，不得通过关闭哈希验证掩盖路径错误。

中断恢复时还确认：Git 检出的 `vocab.txt` 因文本换行转换从清单要求的 109,540 字节变为
130,668 字节，原始 SHA-256 随之变化；仓库外备份仍与清单一致。这进一步证明模型、词表和
分词资源不能通过 Git 分发。当前提交历史仍包含此前误提交的资源 blob；普通删除提交只能从
新版本工作树移除它们，若要从远端历史和仓库存储中彻底清除，必须另行确认历史重写与强制推送。

## 27. 2026-08-08 全链复习冒烟测试

本轮在 `compose.integration.yaml` 的真实持久化栈上，以全新普通用户经 Gateway 完成两种复习
方式。题库复习和故事复习共享同一个 material、graph 与 mastery，但各自创建一次性评估计划
快照；完成后的计划按领域规则关闭，不重复接收第二份学习证据。本轮按用户最新要求不修改 UI。

| 验证项 | 结果 |
|---|---:|
| Compose 配置与全部应用镜像构建 | PASS |
| 15 个容器（3 MySQL、MongoDB、Neo4j、8 个领域/边界服务、Gateway、Frontend） | healthy |
| 六个 .NET 服务测试 | PASS，Auth 11 + User 32 + Credit 6 + Practice 15 + Knowledge 109 + GalGame 362 = 535 |
| RenderService 镜像内测试 | PASS，22 passed / 1 skipped |
| Gateway `:5000/readyz` 与 Frontend `:5120` | HTTP 200 |
| 注册、登录、用户资料与初始额度 | PASS，新用户精确获得 1 credit |
| TXT 上传、Mongo 持久化、规范化提取 | PASS |
| Neo4j 知识图谱构建与评估计划 | PASS |
| StudyProject + PlanGraph 题目生成 | PASS，生成 5 题并人工状态推进至 READY |
| SMART_REVIEW 作答 | PASS，首次写入、答案重放去重、完成重放去重 |
| 题目帮助 | PASS，解释 grounded 且包含资料出处匹配 |
| Practice credits | PASS，`1.00000 -> 0.99790`，无 held 余额 |
| 管理员批量制码与普通用户兑换 | PASS，1 个 3-credit 兑换码只走正式 API |
| GalGame credits 不足路径 | PASS，HTTP 402 `CREDITS_INSUFFICIENT`，含购买 URL；失败任务可从 Mongo 读回 |
| 故事生成及实际结算 | PASS，绑定新的不可变 PlanGraph 快照 |
| Render 事件、进度、结果 | PASS，事件重投去重、进度重放幂等、结果 `ACCEPTED -> DUPLICATE` |
| Knowledge evidence / SM-2 回写 | PASS，故事中所有已答知识点均生成递增版本的 mastery record |
| 最终 credits | PASS，`3.92011`，`held = 0` |
| 冒烟临时资源清理 | PASS，14 文件 / 109,930,654 bytes 移至 `D:\Projects\GalReview-resource-recovery-20260808-1930\post-smoke-Resources` |

最终通过样本：user `9636baa5-3fee-4ab2-8d92-36e1c6e04bb1`，material
`3d37eca2-57ed-4637-9a4c-4313fbff988f`，graph `92004435-43a5-4378-9330-96e465f26a95`，
Practice session `4dd4a86d-5a4f-499f-bcf9-a24df615d93f`，GamePackage
`b84a90a5-c96d-4454-a505-5ccb0a7b4fbc`，Render session
`218d2e94-9ef2-457d-a4e3-2017ac7f9c51`。

冒烟首先暴露并随后修复了三个仅在真实持久化链路出现的问题：Practice 聚合无法忽略 MongoDB
自动 `_id`；MySqlConnector 将 `CHAR(36)` 读取为 `Guid` 时 Credit 持久层仍调用 `GetString`；
GalGame 在 credits 不足任务中把 `JsonElement` details 直接写入 Mongo。修复后分别重跑目标测试、
目标镜像和完整 Gateway 链路。故障阶段留下的一笔已知预授权
`400e04bc-febe-46d6-84a7-40e1c4fd1072` 已通过正式 release 接口恢复为 `RELEASED`。

## 28. 2026-08-09 Recite-first 业务纠偏与全链复验

本轮按 ReciteHelper 原始代码、用户手册和领域模型重新冻结业务边界：`StudyProject` 是唯一用户可见
的顶层项目，在界面称为“研习册”；藏书阁只负责资料与识网；章节练习、智能复习、模拟试卷和
故事回响都从同一册内发起。故事不再建立独立项目，也不再从全局 `/review` 恢复旧计划。

### 28.1 自动化与构建

| 验证项 | 结果 |
|---|---:|
| PracticeService 测试 | PASS，21 / 21 |
| KnowledgeService `sm2-graph-v2` 测试 | PASS，111 / 111 |
| RenderService TypeScript + Vitest | PASS，23 / 23 |
| Frontend TypeScript + Vite production build | PASS，1401 modules；仅既有 KnowledgeDag chunk 警告 |
| PracticeService / KnowledgeService / Frontend 镜像 | PASS |
| Compose 运行态 | PASS，15 个容器全部 healthy |
| Gateway `:5000/readyz` / Frontend `:5120/healthz` | HTTP 200 / 200 |
| Practice 资源清单 | 构建前 14 / 14 哈希通过；构建后仓库内 `Resources` 再次移至仓库外 |

### 28.2 经典复习主线

全新用户经 Gateway 完成 TXT 上传、文字提取、三章/三点知识图谱、研习册、评估计划、自动成题、
人工确认入库、SMART_REVIEW、模拟试卷与 mastery 读取。结果如下：

| 验证项 | 结果 |
|---|---:|
| 自动成题 | `SUCCEEDED`，生成 15 题 |
| 知识点贴签 | 15 / 15 非空；没有按序号轮转绑定 |
| SMART_REVIEW | 3 题对应 3 个不同 PlanGraph 目标，`COMPLETED` |
| 模拟试卷 | 3 题对应 3 个不同 PlanGraph 目标，`COMPLETED` |
| mastery | 两类答题都经同一 KnowledgeService evidence 入口更新 |
| Practice credits | `1.00000 -> 0.99600`，held 为 0 |

样本：material `7af9920d-6881-4e69-b782-23b0bc2d7f5a`，graph
`7695e007-3a74-4d01-8c76-100c00a4ce26`，StudyProject
`f1c93fe2-40d8-4ae1-9760-1873f3ea02f4`。

### 28.3 故事回响与 credits

同一用户、同一 graph 的首次故事生成按预估正确返回 `402 CREDITS_INSUFFICIENT`：余额
`0.996`、最低预估 `1.63827`，details 包含固定购买地址。随后只通过管理员正式批量制码 API
生成一枚 3-credit 兑换码，并由普通用户正式兑换；未直接修改数据库余额。

兑换后故事生成 `SUCCEEDED`，产出 5 个场景；Render 会话提交 3 道题，知识点 3 / 3 唯一，
事件接收 3 条，结果首次 `ACCEPTED`、同载荷重放 `DUPLICATE`。三个相同 graph 的 mastery
版本均再次递增，证明普通答题、试卷与故事回响共享掌握记录。最终 credits `3.92482`，held=0。
样本 GamePackage `b275de54-cc39-4b60-b797-db269848aeab`，Render session
`d0ba10fe-87c4-4dc8-b1a0-6f6e40790db8`。

### 28.4 无任意混合权重的 `sm2-graph-v2`

终检发现旧 `sm2-graph-v1` 尚有 `score*0.65 + observed*0.35`，计划侧还额外假定 90% 到期保持率；
另有“答对上层点便给前置点最多增加 5 分”的间接证据。三者都不是原始 SM-2 的一部分，且后者
没有前置点的真实作答证据。本轮升级后：

- `score=quality/5*100`，只解释该知识点最近一次直接观测；
- SM-2 的 easiness、repetitions、interval、lapses 与 nextReviewAt 继续作为唯一纵向调度状态；
- `lastReviewedAt=null`、`repetitions=0` 或 `now>=nextReviewAt` 才进入到期集合；
- 图谱只在该集合上通过最大乘积路径与单调次模覆盖选择题目，不与 SM-2 按百分比相加；
- mastery 只更新题目明确绑定的知识点，不给未作答前置点或后继点推断加减分；
- 没有到期点时只返回一个稳定的探测题。

新 KnowledgeService 镜像部署后，以既有三点 graph 创建计划时确实只得到 1 个探测目标；通过
Practice SMART 会话正确作答后，目标 score 变为 `100`，reason 为
`DIRECT:ASSESSMENT:quality=5`。Gateway 与 Frontend 仍为 HTTP 200，仓库内资源目录不存在。

## 29. 2026-08-09 藏书阁顺序与立册布局复验

- 侧栏顺序调整为“起点 → 藏书阁 → 研习册 → 识网 → 我的”；首页快捷入口同样先展示藏书阁，
  没有旧册时主按钮进入 `/materials`，不再绕过资料解析与识网直接进入立册页。
- `/projects` 的“立册 / 建立经典复习项目”保留在普通文档流中，CSS 明确为
  `.practice-project-create { position: static; }`；题目编辑区原有 sticky 行为不受影响。
- Frontend TypeScript + Vite production build 通过，1401 modules；仅保留既有 KnowledgeDag
  大 chunk 警告。Frontend 镜像重新构建并替换后 `/healthz` 为 HTTP 200，Compose 15 个容器
  全部 healthy。按实测要求，验证后未停止 Docker。

## 30. 2026-08-09 研习入口禁用原因与交互复验

实测用户项目 `4ae99304-7751-497d-8ca1-684070cbf2af` 已绑定 graph，但 MongoDB 中题目数为 0，
且没有题目生成任务。旧前端因此用 `!ready` 同时禁用章节练习、智能复习与模拟试卷；全局
`.button:disabled { cursor: wait; }` 又把业务前置条件错误表现为进行中状态。

修正后，无 READY 题时页面显示“题库待成”及“前往成题”入口；三个按钮保持可点击，并在任何
PlanGraph 或试卷创建请求发出前由 `requireReadyQuestions()` 返回成题、补签和核对入库指引。
普通禁用按钮使用 `not-allowed`，只有显式 `aria-busy=true` 的真实进行中按钮使用等待光标。
“循网”文案也改为 SM-2 到期集合后再按图谱依赖覆盖，不再描述为两种遗忘风险的混合。

Frontend TypeScript + Vite production build 通过，1401 modules；镜像重新构建并替换后
`/healthz` 为 HTTP 200，Compose 15 个容器全部 healthy。Docker 保持运行供人工实测。

## 31. 2026-08-09 恢复 ReciteHelper“立册即成题”

重新核对 `ReciteHelper.Infrastructure/Services/ProjectCreationService.cs` 与中文用户手册后，确认经典
创建流程本来就在一次操作中完成读取文本、知识/题目生成、章节整理和知识库构建；没有生成任何
题目时创建会明确失败。首次生成包含单选、填空、名词解释和简答，判断题只来自导入套卷。

该节首次验证时仍采用了已废止的 material-scoped graph 顺序；第 32 节已按最新边界重新完成真实
全链复验。当前产品级编排为：创建 `graphId=null` 的 StudyProject → 以本册 `projectId` 建图并绑定
→ 读取本册 graph 全部章节 → 创建 OPEN assessment plan → 自动成题 → 进入本册。当前
`recite-question-v1` 只有在答案、唯一知识点和精确
SourceReference 同时成立时才创建题目，因此成功结果直接 READY；独立成题区只负责追加或失败重试。
credits 不足或生成失败时保留已创建的册并显示恢复说明，不重复建立第二册。
修复前已经存在的空册不在页面加载时自动扣费；其成题按钮明确显示“恢复自动成题”，由用户确认后
复用同一生成链路补齐 READY 题目。

验证结果：

| 验证项 | 结果 |
|---|---:|
| PracticeService tests | PASS，21 / 21 |
| Frontend production build | PASS，1401 modules；仅既有 KnowledgeDag chunk 警告 |
| 真实 Gateway 立册编排 | PASS，project `7a2e78c5-a0ce-45d1-bd27-692234990b38` |
| 自动成题任务 | `SUCCEEDED`，4 题 |
| READY / 知识点绑定 | 4 / 4；未绑定 0 |
| 首次题型 | 单选、填空、名词解释、简答；判断题 0 |
| 自动成题后 SMART_REVIEW | PASS，session `99808d97-eb23-4a2c-b7cd-935069447115`，1 题 ACTIVE |
| Gateway / Frontend | HTTP 200 / 200 |
| Compose | 15 个容器全部 healthy，按人工实测要求保持运行 |
| Practice Resources | 构建时从仓库外临时恢复 14 文件；构建后已移回，仓库内目录不存在 |

## 32. 2026-08-09 图谱归属研习册的双册隔离与经典流程复验

本轮纠正聚合边界：藏书阁的 material 只是研习册图谱的来源，`KnowledgeGraph`、版本序列、知识点
身份与 mastery 均归 `StudyProject`。新册先以 `graphId=null` 创建，KnowledgeService 再通过 Gateway
调用 PracticeService 的受信 INTERNAL 查询，核验 `studyProjectId + ownerUserId + materialId` 后构图；
PracticeService 绑定时反向核验图谱作用域。旧 material-scoped 图只保留按 graphId 的兼容读取，不得挂入新册。

### 32.1 自动化、构建与部署

| 验证项 | 结果 |
|---|---:|
| KnowledgeService tests | PASS，112 / 112 |
| PracticeService tests | PASS，24 / 24；包含跨册拒绝、项目指纹隔离与首批题型轮转回归 |
| Gateway Vitest / TypeScript | PASS，203 / 203；TypeScript build 通过 |
| Frontend production build | PASS，1401 modules；仅既有 KnowledgeDag 大 chunk 警告 |
| `knowledge-service` / `practice-service` / `gateway` / `frontend` 镜像 | PASS；按同一发布单元构建并替换 |
| Compose | PASS，15 个容器全部 healthy；Gateway `/readyz`、Frontend `/healthz` 均为 HTTP 200 |
| Practice Resources | PASS，镜像构建时临时恢复 14 文件；构建后仓库内 `Resources` 不存在，109,930,654 bytes 仍在仓库外恢复目录 |

### 32.2 同资料双册隔离

使用全新普通用户上传并解析同一 TXT 后，先后创建甲、乙两本 `graphId=null` 研习册，再分别以相同
material 构图。两次构图均成功，但 graphId、4 个知识点 ID 和各自初始 mastery 记录完全隔离；
按 `studyProjectId` 查询图谱时两册各只返回自己的 1 张图。把甲册图谱 PATCH 到乙册得到
`409 GRAPH_OUTSIDE_PROJECT_SCOPE`，拒绝后乙册版本未被占用，随后可正常绑定乙册自己的图谱。

| 对象 | 研习册 | 图谱 | 知识点 / mastery |
|---|---|---|---:|
| 甲册 | `be9148e2-1303-4c3d-b0ba-394b90a3d859` | `87667298-4dbc-4d11-b457-4dd2745c8066` | 4 / 4 |
| 乙册 | `a5c4e2c7-cdd2-455a-9501-d246db0eea8d` | `e717d8af-b3b9-4270-af64-63ccc834c0bd` | 4 / 4 |

样本 user `ff24f386-08a4-424f-9f74-f172b1d7dfbb`，material
`fd7dc177-0624-4ad8-aadd-25ad9c08dc62`；两图共享知识点 ID 数为 0。

### 32.3 立册即成题与智能复习

首次部署冒烟同时发现：生成器原先按“题型外层、知识点内层”遍历，四个知识点、四道目标题会在
第一种题型达到数量上限，实际得到 4 道单选。修复后改为题型与知识点同步轮转；在不伪造答案、
干扰项或出处的前提下，题数足够时先覆盖全部请求题型，再重复任一题型。

甲册基于本册 graph 创建 assessment plan `0f04d560-08eb-417e-b1bf-4ff6cebe5f07` 后，首次自动成题
得到 4 道 READY 题，精确覆盖单选、填空、名词解释、简答，4 / 4 带本册知识点标签，未绑定为 0；
随后成功创建 SMART_REVIEW session `d024a4d0-a808-42d2-8757-0a5f7d3a6f01` 并取得 1 道计划内题。
credits 从 `1.00000` 结算为 `0.99776`，held 为 0。最终容器保持运行，供人工实测。

## 33. 2026-08-09 `recite-question-v2` 真实 PDF 与题库主链复验

本节只记录本轮实际重新执行的证据，不沿用第 31/32 节的 v1 结论。测试数据统一使用
`recite-v2-*` 前缀；最终完整样本用户为 `1704abfc-25f7-4e6d-a9ca-8dfffc9b3276`。浏览器实际路径
均经公开 Gateway API 完成注册、multipart 上传、解析、先立册、按 `studyProjectId + materialId`
构图、绑定、读取全部章节、创建 `LEARNING` PlanGraph，并在请求中省略 `targetCount` 执行
`recite-question-v2`。内部 extracted-text 接口只在前置定位阶段使用，最终结果未绕过公开归属约束。

### 33.1 静态回归与生产构建

| 验证项 | 结果 |
|---|---:|
| PracticeService | PASS，36 / 36，0 skipped |
| KnowledgeService | PASS，112 / 112，0 skipped |
| Gateway Vitest | PASS，15 files、203 / 203；TypeScript build PASS |
| Frontend | PASS，TypeScript + Vite，1401 modules；保留既有 KnowledgeDag 大 chunk 警告 |
| PracticeService API build | PASS，0 warning / 0 error |

Practice 新增/复验用例覆盖：DeepSeek/OpenAI-compatible JSON 与 `usage.total_tokens` 累计；非 JSON、
缺 usage、非法 pointId、quote 不在原文、答案不受 quote 支持、单选多答案、第二遍回验拒绝；扁平化
PDF 页内题号；农业三道坏题；微生物“名词解释/大题/重要知识点”；答案内部 `1./2./3.` 不截断；
以及当前答案必须在更早的章节/题型边界停止，不能吞入后续章节。

### 33.2 两份真实 PDF

| 项目 | 农业生态学.pdf | 微生物学B.pdf |
|---|---:|---:|
| 规范化文本 | 26,139 UTF-16 chars / 20 source spans | 26,513 UTF-16 chars / 39 source spans |
| 本册图谱章节 / Learning Plan 点 | 7 / 243 | 4 / 15 |
| 自动题数 | 189（不是 30） | 240（不是 30） |
| READY / DRAFT | 172 / 17 | 9 / 231 |
| 已绑定唯一知识点数 | 161 | 7 |
| READY 无 pointId | 0 | 0 |
| SourceReference 校验 | 189 / 189 offset + checksum 通过 | 240 / 240 offset + checksum 通过 |
| 水印/页脚泄漏 | 0 | 0 |
| 跨章节答案泄漏 | 0 | 0 |

农业三道回归题均保留原问题和真实答案：“生态平衡的基本特征有哪些？”保留四个分点；“循环农业
坚持的‘4R原则’是什么？”保留适量化、再循环、再利用、可控化；“解读中国生态农业原理之绿色
发展原理。”的答案与题干不同并保留三个原文分点。修复前，部分带 `【参考答案】` 的题会跨越
“综合题/下一章”吞入远处内容；结束边界改为“下一题标记与结构边界的较早者”后，答案内部编号
仍完整，真实样本的章节/题型栏泄漏为 0。

微生物资料确认为半结构化讲义而非标准题库。v2 直接忠实提取了“术语：定义”和“问题标题：分点
答案”，没有把它们统一重写成模板。该图谱实际只产生 15 个 Learning Plan 点，故 231 道原文问答
无法唯一贴签并按契约保留 DRAFT，9 道通过唯一绑定后 READY；这不是可宣称“240 道可练习题”的
结果。当前本地 `DEEPSEEK_API_KEY` 未配置，且该样本的半结构化范围覆盖了可成题区间，因此普通正文的真实
DeepSeek + 第二遍来源约束回验未发生；该分支只由模拟 provider 单元测试验证，不能据此宣称线上模型质量已验收。

最终完整样本 ID：

| 对象 | 农业生态学 | 微生物学B |
|---|---|---|
| material | `be87269a-47b0-4849-befd-49f6208b1d82` | `35e774a5-b8eb-4ddb-8973-b5a1c9128da6` |
| ingestion job | `05acf178-d4f8-444c-a7c4-7ee8d6326d86` | `dce867f3-90fc-4a1b-8e9e-41815c93f914` |
| StudyProject | `cf80e37a-4249-42aa-8f23-0fa5a959e9dc` | `ba3ad4e4-425e-452f-b6c5-2497ae9ee4db` |
| graph build / graph | `5f148584-0497-4694-9959-02ed63b5ceba` / `b9bc3e62-201f-42cb-8b00-4c2c0a07c3a0` | `87463f3b-c674-4e84-ae42-f7020b6ec5c0` / `ce6cc834-4d4e-444f-a24f-3f7095b72905` |
| Learning Plan | `234195d1-671f-4500-973a-126fbaa6528a` | `e1417683-a1d0-43bf-9035-8690a57994a2` |
| generation job | `c5fa536c-cb3b-44cd-909f-9daf76095802` | `f1cfa24f-772a-48b6-9407-5795d24a34ba` |

### 33.3 credits、练习、试卷与故事回响

为确定性复现余额不足，另建 `recite-v2-credit-1786238134851` 测试册并显式请求 1000 题作为
预授权边界探针；首次请求经 Gateway 返回 `402 CREDITS_INSUFFICIENT`，没有启动生成。随后经公开
管理员登录和 `/admin/credit-codes/batches` 创建 20 credits 兑换码，再由用户通过
`/credits/redemptions` 兑换；重试生成 `PARTIALLY_SUCCEEDED`、创建 240 题，held 最终为 0，余额
`20.99997`。完整兑换码未写入日志或文档。对应 project `8b67786a-e840-4d3c-a121-94895ae77f38`，
graph build `e55d0d9d-8916-407b-986e-80e6d4150bea`，graph
`dc4079f2-80db-4d18-b664-9b1eeb49b186`，Learning Plan
`f5ca19dd-d11b-48c2-a59f-5546ca5d8ebf`，credit code ID
`a9ee3158-8fd2-4cdd-82e7-9981d0da4312`，generation job
`5cf29a00-a416-4385-96b5-eedba2670046`。

同一农业研习册随后完成三条公开 HTTP 闭环：

- SMART_REVIEW：plan `9353c225-e24e-4bb8-9110-464c11f73dda`，session
  `97ad35b7-e23a-4066-948f-2a195f93a94c`；正确作答后目标 mastery score=100，
  `nextReviewAt=2026-08-10T01:18:41.4076626Z`。
- 模拟试卷：plan `868ad704-5bd3-4430-8ebe-7a727cb1b456`，paper
  `22385c18-7661-4af3-955c-38918202e057`，session
  `2d789afc-ac20-43f9-93fb-100a497f8aca`，答题与 completion 成功。
- 故事回响：plan `cbb36522-bcaa-4004-9827-f80de5a4e6d2`，generation
  `ffd90c40-58ab-4619-bd7b-c88f6f6ac04b`，package
  `9d8904cf-cf46-42e8-a189-3c9acd4c5997`，Render session
  `06dfac8b-b295-4c3e-b409-76a22f6758ab`，结果
  `674ae756-f3e9-4b3a-9dec-06c5c444fec2` 为 `ACCEPTED`；1 条游戏题证据写回同一 mastery。

### 33.4 失败样本、运行环境与未验证项

脚本前两次分别因遗漏图谱构建 `Idempotency-Key` 和 Gateway 生成限流失败；修复脚本后未关闭
幂等/限流门禁。为便于精确清理，失败样本记录如下：

- `recite-v2-1786237468840`：user `838f9f31-50b3-4be9-933a-4bd2f2cc8c0f`；materials
  `d40256b6-bb88-41d2-b834-46f384e70755`、`5d5f691c-b51a-41e0-b3c6-0958f1ff4bd3`；空图 project
  `6ecab00f-7167-44e4-a03c-1f49a3ba4ffc`。
- `recite-v2-1786237502214`：user `2b990d6d-8740-47b6-898b-86d2a5872e8b`；materials
  `1b4850fb-5e52-4bf7-b9fc-df58d405399c`、`011a97d2-53e9-4aa2-b8f4-b2a2b0c3faa0`；projects/graphs
  `6c19a884-d99c-43a5-89c3-ba4bb7b59da4` / `67e95939-3003-4bce-965f-bcc225d3b8dd`，
  `11798cdf-9c1c-47fb-a421-0ec9dc3455cc` / `4dcd532c-64a7-4e3a-a473-46fa38e5d5da`。

本机当前没有 `docker.exe`、Docker 服务或 Docker Desktop 进程，题设中的 D 盘资源恢复目录也不存在，
所以本轮不能重建或声称“15 个容器 healthy”。8 个后端服务、Gateway 与 Frontend 使用本地启动栈，
其 `/healthz`、`/readyz` 均为 HTTP 200。Practice 14 个资源文件在本地出现后已按 manifest 对
109,930,654 bytes 完成 14 / 14 长度与 SHA-256 校验；Docker 镜像门禁未运行。OCR、真实 DeepSeek
普通正文质量和容器态回归仍未验证，结论必须与上面的单元测试/本地 HTTP 冒烟分开。

## 34. 2026-08-09 提交后复核与紧凑 PDF 图谱修复

本节是第 33 节之后的增量复核，不改写第 33 节的历史数据。开始时 `main` 与 `origin/main` 同步、工作树
无暂存/未暂存/冲突；最新提交主要覆盖生产部署与 Gateway/Render 安全修复，但第 33.2 节已明确记录的
“微生物 240 题仅 9 READY”仍未解决。审查定位到三条独立原因：

1. PDFPig 会把“第一章…名词解释1.”压成无空格单行，v2 章节、题型栏和题号规则均要求空格或普通
   左边界，导致 26,513 字符退化为 4 个固定窗口和 15 个点；
2. 顶层术语 `6.2μm质粒` 的标题以数字开头，旧题号规则把 `6.` 当成小数前缀并使后续序列全部丢失；
3. Practice 将题干命中和答案中顺带出现的同长度术语一起判为歧义，且普通长文的单行 PDF 不会按
   1400 字符继续切片，可能把整份资料只规划为一个最多 8 题的模型分片。

修复后版本为 `chapter-segmenter-v3` / `knowledge-extractor-v3`。v3 保留绪论，允许表格末词与下一章
粘连但拒绝“见/参见第 X 章”引用，识别裸题型栏和数字起始术语，合并结构块之外的普通段落并移除已确认
的页眉水印。Practice 的唯一绑定改为题干精确相等优先的离散顺序，未引入相似度或混合权重；无唯一
结果仍保留 DRAFT。普通正文按完整句边界拆成至多 1400 UTF-16 字符的连续证据块。

### 34.1 静态验证

| 验证项 | 结果 |
|---|---:|
| KnowledgeService | PASS，115 / 115，0 skipped（原 112，新增紧凑章节、裸题型栏、数字起始术语） |
| PracticeService | PASS，38 / 38，0 skipped（原 36，新增单行长文多分片与题干精确绑定） |
| Gateway | PASS，15 files、203 / 203；TypeScript build PASS（本轮改动前基线，Gateway 源码未改） |
| Frontend | PASS，TypeScript + Vite，1401 modules；仅保留既有 KnowledgeDag 大 chunk 警告 |
| CreditService | PASS，6 / 6，0 skipped |
| FileService | `dotnet test` 返回 0；该 solution 当前没有独立测试项目 |

### 34.2 同款真实 PDF 的进程内复验

输入为 `D:\AppData\微生物学B.pdf`（39 页）。临时探针直接复用 FileService 的 PDFPig、
KnowledgeService 的生产切分/抽取器和 PracticeService 的生产 `ReciteQuestionGenerator`；探针与 PNG
均已删除，未写数据库、未创建可复用 ID，也未把资料内容加入 Git。

| 项目 | v2（第 33.2 节） | v3 本轮 |
|---|---:|---:|
| 规范化文本 | 26,513 UTF-16 chars | 26,513 UTF-16 chars |
| 章节 | 4 个固定窗口 | 10 个结构章节；原文第五章标为“略”，不伪造空章 |
| 图谱点 | 15 | 210 |
| 自动题数 | 240 | 240 |
| READY / DRAFT | 9 / 231 | 220 / 20 |
| 已绑定唯一知识点数 | 7 | 184 |
| 图谱标题/摘要残留 `2019级植科` 水印 | 未专项计数 | 0 |

20 道 DRAFT 中，14 道无同名/包含知识点，6 道仍有多个同长度候选；门禁没有为追求数量而放宽。
本轮没有配置 `DEEPSEEK_API_KEY`，因此普通正文模型生成仍只验证了分片规划和模拟 provider 测试，不能
宣称真实模型质量已验收。Docker CLI 可见但 Linux engine pipe 不可用，未重建容器，也未重复第 33.3
节的公开 HTTP、credits、SM-2、试卷和故事回响链；部署复验必须新建用户/资料/研习册，不依赖第 33 节
的历史 ID。

## 35. 2026-08-09 题目生成研究依据与声明边界审计

本节回答“当前题目生成是否经过研究证明有效”。结论分成两个不能混淆的层级：

- **研究与实现对齐：VERIFIED。** 答案原子先行、生成后第二遍来源约束回验、逐字证据、one-best-answer
  布尔门禁和主动提取复习均能找到直接的论文或专业指南依据，生产代码确实实现了对应职责；
- **千知万理当前组合系统的题目质量与学习效果：NOT VALIDATED。** 现有论文没有测试本项目的中文
  农学/社科/人文资料、当前 provider/model/prompt、知识图谱绑定和门禁组合。本轮也没有执行领域专家
  盲评或延迟学习对照实验，因而不得写成“已经研究证明有效”。

### 35.1 原始来源与实现映射

| 原始来源 | 原来源实际支持的结论 | 生产实现映射 | 不能外推的结论 |
|---|---|---|---|
| [Answer-focused and Position-aware Neural Question Generation](https://aclanthology.org/D18-1427/) | 在论文模型和数据集上，显式答案焦点/位置改进 QG | `ReciteQuestionGenerator` 先识别可独立作答的答案原子，再写题；答案必须受 `sourceQuote` 支持 | 未复现该模型或其实验，不能据此证明当前中文生成质量 |
| [Synthetic QA Corpora Generation with Roundtrip Consistency](https://aclanthology.org/P19-1620/) | 生成与答案抽取回路可筛选合成 QA，并在论文任务上改进结果 | 第一次生成后进行分离的第二次来源约束作答，恢复答案集合必须与标准答案严格相等 | 第二次调用可使用同一 provider/model，不是独立模型或无偏评价者 |
| [Putting the Horse before the Cart](https://aclanthology.org/K19-1076/) | 在 SQuAD 条件下 generator-evaluator 框架的自动与人工评价优于对照 | 生成职责与回验职责分离 | 当前实现没有复现论文架构、奖励函数或实验结果 |
| [QGEval](https://aclanthology.org/2024.emnlp-main.658/) | 人工评价是自动指标的金标准；七个维度的自动指标与人工判断对齐不足 | 拟用流畅、清晰、简洁、相关、一致、可回答、答案一致作为人工黄金集维度 | 自动门禁通过不能替代人工题目质量验收 |
| [Evaluating Rewards for Question Generation Models](https://aclanthology.org/N19-1237/) | 模型会提高被优化的奖励，但奖励可能与人工判断错位并被利用 | 不引入一个合成质量分，不用任意比例混合自动指标 | 不能以内部分数或题量证明质量 |
| [NBME Item-Writing Guide](https://www.nbme.org/sites/default/files/2021-02/NBME_Item%20Writing%20Guide_R_6.pdf) | 专业命题指南要求聚焦 lead-in、同质可信选项并清除形式线索 | 单选恰有 A-D、一个最佳答案、来源不支持干扰项；不可靠就不生成 | 指南不是针对本项目或中文通识材料的随机对照试验 |
| [Test-enhanced learning](https://pubmed.ncbi.nlm.nih.gov/16507066/)；[Retrieval practice and concept mapping](https://pubmed.ncbi.nlm.nih.gov/21252317/) | 在各自实验条件下，主动提取改善延迟保持或概念学习 | 用户作答、反馈、SM-2 后续调度与掌握度回写 | 只支持复习形态，不证明机器生成题达到人工题质量 |

### 35.2 工程参数审计

`ChunkCharacters=1400`、每片至多 8 题、`temperature=0.1`、`max_tokens=6000` 分别控制连续证据边界、
单次输出规模、采样稳定性和响应上限。它们有边界/回归测试和成本约束，但没有上述论文给出的“最优题目
质量”证据；文档已禁止把这些值宣传为科学阈值。知识点绑定采用离散、可解释的优先顺序并在歧义时
进入 `DRAFT`，没有设置 40%/60% 等混合权重。

生产提示词中“独立核验器”已校正为“与生成调用分离的第二次来源约束回验”。该修改保留重新作答、
逐字 evidence 约束和答案集合严格一致三个行为，仅移除对同一模型第二次调用的过度表述。

### 35.3 本轮验证与尚缺验收

| 项目 | 结果 |
|---|---|
| 生产实现—研究职责逐项复核 | PASS |
| PracticeService 回归 | PASS，38 / 38，0 skipped |
| `git diff --check` | PASS |
| 生产 DeepSeek 普通正文样本 | NOT RUN，本轮没有可用 API key |
| 中文领域专家盲评、评审一致性与人工题/ReciteHelper 对照 | NOT RUN |
| 关键组件消融 | NOT RUN |
| 预注册延迟学习效果对照实验 | NOT RUN |

因此本轮允许的最终表述只有：“题目生成不是随意拼装；关键设计有原始研究/专业指南依据，且生产实现
和确定性技术门禁已经核对与回归。”如果要升级为“当前算法经验证有效”，必须先完成
`docs/contract.md` §14.3.1 的版本化中文资料集、盲评、对照、消融和（涉及学习效果声明时）延迟测验；
样本量、主要终点与判定界值必须在看结果前由功效分析和人工基线确定。
