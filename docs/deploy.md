# 部署指南

本文说明如何使用仓库根目录的 `compose.integration.yaml` 在本机或 Linux 服务器启动 GalReview。接口、鉴权头和跨服务调用以 [`contract.md`](contract.md) 为准；本文只记录部署方式，不另行定义接口。

当前 Compose 是联调与单机部署基线，不是高可用集群方案。AuthService、UserService 和 CreditService 分别接入独立 MySQL 容器；仓库本地 Auth/User 默认值仍是 `Mock`，服务器 `.env` 模板则使用 `MySql`，CreditService 始终使用 MySQL。File、GalGame 与 PracticeService 使用同一 MongoDB 实例中的独立数据库。宿主发布端口的调整不改变接口路径、鉴权头、请求/响应结构或容器内部协议。

## 1. 部署范围

默认 Compose 启动以下组件：

| 组件 | Compose 服务名 | 容器端口 | 宿主机暴露 | 数据 |
|---|---|---:|---|---|
| API Gateway | `gateway` | `5000` | `127.0.0.1:5000`（默认） | 无状态 |
| UserService | `user-service` | `5101` | 不暴露 | 本地默认内存；服务器模板使用独立 MySQL |
| AuthService | `auth-service` | `5102` | 不暴露 | 本地默认内存；服务器模板使用独立 MySQL |
| FileService | `file-service` | `5103` | 不暴露 | MongoDB / GridFS |
| KnowledgeService | `knowledge-service` | `8080` | `5104`（`KNOWLEDGE_HOST_PORT`），仅诊断 | Neo4j |
| GalGameService | `galgame-service` | `5105` | 不暴露 | MongoDB；可选 DeepSeek 叙事生成 |
| RenderService | `render-service` | `5106` | 不暴露 | C++/WASM runtime 与 TypeScript 会话/证据服务 |
| PracticeService | `practice-service` | `5107` | 不暴露 | MongoDB `qzwl_practice`；复习业务与离散判分决策，不装载模型 |
| CreditService | `credit-service` | `5108` | 不暴露 | 独立 MySQL `qzwl_credit`；credits、兑换码、预授权与账本 |
| ModelService | `model-service` | `5109` | 不暴露 | 无数据库；本地多语种 NLI、模型资产与选择性推理 |
| Frontend | `frontend` | `8080` | `5120`（`FRONTEND_HOST_PORT`） | Node 静态站点；同源代理 `/api` 到 Gateway |
| User MySQL | `user-mysql` | `3306` | 不暴露 | `user-mysql-data` 卷 |
| Auth MySQL | `auth-mysql` | `3306` | 不暴露 | `auth-mysql-data` 卷 |
| Credit MySQL | `credit-mysql` | `3306` | 不暴露 | `credit-mysql-data` 卷 |
| MongoDB | `mongo` | `27017` | 不暴露 | `file-mongo-data` 卷；承载 `qzwl_file`、`qzwl_galgame`、`qzwl_practice` 独立数据库 |
| Neo4j | `neo4j` | Browser `7474` / Bolt `7687` | `5254/5255`（`NEO4J_*_HOST_PORT`），仅诊断 | `knowledge-neo4j-data` 卷 |

OCRService 使用 `ocr` profile，可按需加入：

| 组件 | Compose 服务名 | 容器端口 | 宿主机暴露 | 说明 |
|---|---|---:|---|---|
| OCRService | `ocr-service` | `5110` | 不暴露 | 仅供 FileService 调用；不经过 Gateway |

服务器防火墙的 `5000-5300` 约束只作用于 Docker 发布到宿主机的端口。默认发布值为
Gateway `5000`、KnowledgeService 诊断 `5104`、Frontend `5120`、Neo4j Browser `5254`
和 Bolt `5255`；它们分别由 `.env` 中的五个 `*_HOST_PORT` 变量覆盖。修改时仍应选择该
范围内且未被操作系统保留或占用的端口。

容器内部保留各组件的原生语义：KnowledgeService 与 Frontend 监听 `8080`，两套 MySQL
监听 `3306`，MongoDB 监听 `27017`，Neo4j 使用 `7474/7687`。这些 target 没有因为宿主
防火墙而改写；数据库也不发布到宿主机。Dockerfile `EXPOSE` 只是镜像元数据，不等于
防火墙入口。

服务间 URL、数据库连接串、SMTP 供应商端口、系统 HTTP(S)/SOCKS 代理以及测试进程的
临时端口同样不属于 `5000-5300`。例如 SMTP 默认仍为 `465`，测试监听由操作系统分配；
不得为了通过端口检查而改写第三方协议标准或预留一段固定测试端口。

## 2. 前置条件

- Docker Engine 24 或更新版本，或已启用 Linux 容器的 Docker Desktop。
- Docker Compose v2；使用 `docker compose version` 检查。
- PowerShell 7（`pwsh`）与 AWS CLI v2，用于在构建 ModelService 前从 OSCA 恢复本地模型和字典。
- 能够访问项目使用的基础镜像与 NuGet、npm、PyPI 软件源。
- 服务器部署建议使用独立数据盘保存 Docker 镜像和卷，并在首次构建前配置好 Docker 数据目录。
- 若启用 OCR，需要为 PaddleOCR 镜像、模型和运行内存预留额外空间；首次构建和首次识别通常较慢。

宿主机不需要另行安装 .NET、Node.js、Python、MongoDB 或 Neo4j。它们都在容器中构建或运行；`pwsh` 与 AWS CLI 是构建前资产恢复工具，不进入运行容器。

### Docker 数据目录

Compose 不能决定 Docker Desktop 把镜像存在哪个磁盘。Windows 上应先在 Docker Desktop 中设置磁盘镜像位置，再执行构建；Linux 上可在 Docker daemon 配置中把 `data-root` 指向数据盘。修改现有 Docker 数据目录涉及停机和数据迁移，应由服务器管理员完成。

可用以下命令确认实际位置：

```bash
docker info --format '{{.DockerRootDir}}'
docker system df
```

## 3. 准备部署变量

仓库只提供不含真实凭据的模板。不要直接修改模板，也不要把生成的 `.env` 提交到版本库。

Linux：

```bash
cp .env.deploy.example .env
chmod 600 .env
```

PowerShell：

```powershell
Copy-Item .\.env.deploy.example .\.env
```

至少替换所有 `CHANGE_ME`。服务密钥应分别生成，不能在服务器继续使用仓库中的本地默认值。MySQL 应用密码会被插入连接串，因此应使用不含分号的高熵值。可以使用密码管理器或服务器密钥服务生成、保存和注入这些值；不要把密钥放进镜像构建参数、Shell 历史或部署日志。

主要变量如下：

| 变量 | 用途 |
|---|---|
| `COMPOSE_PROJECT_NAME` | Compose 项目名，也会作为网络和卷名称前缀 |
| `GATEWAY_KEY` | Gateway 回退密钥；已配置逐服务密钥时不用于代替它们 |
| `USER_SERVICE_KEY` | Gateway 与 UserService 的目标服务密钥 |
| `AUTH_SERVICE_KEY` | Gateway 与 AuthService 的目标服务密钥 |
| `FILE_SERVICE_KEY` | Gateway 与 FileService 的目标服务密钥 |
| `KNOWLEDGE_SERVICE_KEY` | Gateway、KnowledgeService 及其回调 Gateway 的服务密钥 |
| `GALGAME_SERVICE_KEY` | Gateway、GalGameService 及其回调 Gateway 的服务密钥 |
| `RENDER_SERVICE_KEY` | Gateway 转发到 RenderService 的目标密钥；未来 INTERNAL 回调继续复用该身份 |
| `PRACTICE_SERVICE_KEY` | Gateway 与 PracticeService 的目标密钥；Practice 经 Gateway 读取资料/PlanGraph 与提交证据时复用该身份 |
| `CREDIT_SERVICE_KEY` | Gateway 与 CreditService 的目标密钥；Auth、Practice、GalGame 经 Gateway 调用 credits INTERNAL 接口时分别使用自己的调用方密钥 |
| `MODEL_SERVICE_KEY` | Gateway 与 ModelService 的目标密钥；Practice 经 Gateway 调用推理 INTERNAL 接口时仍使用自己的调用方身份 |
| `DEEPSEEK_API_KEY` | GalGameService 与 PracticeService 共享的 DeepSeek API key；Compose 分别注入两个容器，不得写入日志、镜像或版本控制文件 |
| `PRACTICE_QUESTION_ENDPOINT` | PracticeService 的 OpenAI-compatible Chat Completions endpoint，默认 DeepSeek |
| `PRACTICE_QUESTION_MODEL` | PracticeService 题目生成模型，默认 `deepseek-v4-flash` |
| `PRACTICE_QUESTION_PARALLELISM` | 普通正文分片并行度，范围 1-8，默认 4 |
| `MODEL_NLI_MIN_TOP_PROBABILITY` | ModelService NLI 自动决定的 top probability 门禁，冻结默认 `0.75`；修改须升级算法版本并重跑金标集 |
| `MODEL_NLI_MIN_MARGIN` | ModelService NLI 前两类概率差门禁，冻结默认 `0.20`；修改须升级算法版本并重跑金标集 |
| `GALGAME_NARRATIVE_ENABLED` | 是否启用模型叙事；关闭或 key 缺失时使用确定性回退 |
| `GALGAME_NARRATIVE_ENDPOINT` | DeepSeek Chat Completions HTTPS endpoint |
| `GALGAME_NARRATIVE_MODEL` | 叙事模型，默认 `deepseek-v4-pro` |
| `NEO4J_PASSWORD` | Neo4j 的 `neo4j` 用户密码 |
| `USER_MYSQL_ROOT_PASSWORD` | UserService 专用 MySQL 实例的 root 密码，仅数据库容器使用 |
| `USER_MYSQL_PASSWORD` | UserService 连接其 MySQL 的应用用户密码 |
| `AUTH_MYSQL_ROOT_PASSWORD` | AuthService 专用 MySQL 实例的 root 密码，仅数据库容器使用 |
| `AUTH_MYSQL_PASSWORD` | AuthService 连接其 MySQL 的应用用户密码 |
| `CREDIT_MYSQL_ROOT_PASSWORD` | CreditService 专用 MySQL 实例的 root 密码，仅数据库容器使用 |
| `CREDIT_MYSQL_PASSWORD` | CreditService 连接 `qzwl_credit` 的应用用户密码 |
| `GALREVIEW_ADMIN_USERNAME` | 初始管理员用户名 |
| `GALREVIEW_ADMIN_PASSWORD_HASH` | 初始管理员密码的 ASP.NET Core Identity V3 哈希；用 `scripts/new-admin-password-hash.ps1` 生成，禁止填写明文 |
| `SMTP_HOST`、`SMTP_PORT`、`SMTP_USE_SSL` | AuthService 密码重置邮件的 SMTP 连接配置 |
| `SMTP_USERNAME`、`SMTP_PASSWORD` | SMTP 认证信息；`SMTP_PASSWORD` 通常是授权码 |
| `SMTP_FROM_ADDRESS`、`SMTP_FROM_NAME` | 密码重置邮件的发件地址和显示名 |
| `ACCOUNT_FRONTEND_BASE_URL` | 注入 AuthService 的账户前端公开基址；应与实际站点一致 |
| `AUTH_SERVICE_MODE` | AuthService 运行模式；服务器模板使用 `MySql`，本地默认值为 `Mock` |
| `USER_SERVICE_MODE` | UserService 运行模式；服务器模板使用 `MySql`，本地默认值为 `Mock` |
| `GATEWAY_BIND_ADDRESS` | Gateway 在宿主机的绑定地址，默认 `127.0.0.1`，禁止生产公网设为 `0.0.0.0` |
| `GATEWAY_HOST_PORT` | Gateway 宿主发布端口，默认 `5000` |
| `FRONTEND_BIND_ADDRESS` | Frontend 在宿主机的绑定地址 |
| `FRONTEND_HOST_PORT` | Frontend 宿主发布端口，默认 `5120` |
| `DIAGNOSTIC_BIND_ADDRESS` | KnowledgeService 与 Neo4j 诊断端口的绑定地址 |
| `KNOWLEDGE_HOST_PORT` | KnowledgeService 诊断宿主端口，默认 `5104` |
| `NEO4J_BROWSER_HOST_PORT` | Neo4j Browser 诊断宿主端口，默认 `5254` |
| `NEO4J_BOLT_HOST_PORT` | Neo4j Bolt 诊断宿主端口，默认 `5255` |
| `CORS_ORIGINS` | 允许访问 Gateway 的前端 Origin，多个值用逗号分隔 |
| `TRUST_PROXY` | Gateway 是否按 `X-Forwarded-For` 还原客户端 IP。默认留空＝不采信该头，匿名限流按 socket 对端计量；只有当 Gateway 端口仅经可信反向代理对外时，才填该代理的地址或网段（如 `172.18.0.0/16`），否则任何客户端都能靠轮换该头刷新匿名配额 |

建议服务器只把 Frontend 或现有反向代理暴露给外部。Frontend 在容器网络内把 `/api` 转发到 Gateway；KnowledgeService 与 Neo4j 的诊断端口应保持 `127.0.0.1`，不应开放到公网。

Compose 内的三套 MySQL 连接使用 `caching_sha2_password`，并在隔离的容器网络中启用
`AllowPublicKeyRetrieval=True`；MySQL 端口不得映射到公网。若改接 Compose 网络之外的
数据库，应改用受信 CA 的 TLS 连接串，不要沿用当前的 `SslMode=Disabled`。

启用密码重置邮件时，必须完整配置 SMTP 主机、供应商实际端口、认证信息和发件地址；
模板端口 `465` 不是 Docker 宿主发布端口，也不受项目防火墙端口窗口限制。若刻意留空，
注册和登录仍可使用，但邮件重置功能不可用。`ACCOUNT_FRONTEND_BASE_URL` 与
`CORS_ORIGINS` 都应使用用户实际访问的 HTTPS 前端地址，后者只写 Origin，不带路径。

配置完成后先做静态校验。`--quiet` 不会把插值后的密钥打印到终端：

```bash
docker compose --env-file .env -f compose.integration.yaml config --quiet
docker compose --env-file .env -f compose.integration.yaml config --services
docker compose --env-file .env -f compose.integration.yaml config --profiles
```

## 4. 本机启动

### ModelService 模型资产（首次构建前必做）

`backend/ModelService/Resources` 不进入 Git。每次在新的检出目录构建、部署或开发 ModelService 前，必须先运行统一下载器；缺少关键文件时 Dockerfile 会在发布阶段之前直接失败。下载器先从 OSCA 私有储桶恢复资源；所需凭据必须由维护者通过受控渠道分发，并限制为读取和列举 `20277-gal-res`，不能访问其他储桶或写入对象。在仓库根目录执行：

```powershell
$env:OSCA_ACCESS_KEY_ID = '<read-only access key>'
$env:OSCA_SECRET_ACCESS_KEY = '<read-only secret key>'
.\scripts\download-model-resources.ps1
Remove-Item Env:OSCA_ACCESS_KEY_ID, Env:OSCA_SECRET_ACCESS_KEY
```

下载脚本与哈希清单受版本控制，但访问凭据不受版本控制。CI 在检出仓库并安装 AWS CLI v2 后，必须从 secret store 注入 `OSCA_ACCESS_KEY_ID` 与 `OSCA_SECRET_ACCESS_KEY` 再运行脚本；脚本只参与构建前资产恢复，不进入 ModelService 运行容器。不得把凭据写回脚本、`.env` 模板、构建参数或日志；权限边界若发生扩大，应立即轮换凭据。

下载器固定使用 OSCA S3 兼容 endpoint `https://fgws3-ocloud.ihep.ac.cn`、Path-Style、区域 `us-east-1` 和私有储桶 `20277-gal-res`。对象目录树与 `Resources` 一致，当前 `Models/multilingual-minilm-nli` 及其模型、SentencePiece 和配置文件均已镜像到 OSCA。默认认为对象直接位于储桶根目录；如果上传时保留了 `Resources/` 顶层目录，执行 `download-model-resources.ps1 -RemotePrefix Resources`。

资源恢复按确定的容灾顺序执行：先接受已通过 manifest 的本地缓存；缓存不完整时尝试 OSCA 主镜像；OSCA 无凭据、无法列举、同步失败、对象缺失或文件校验失败时，再逐文件使用 `-FallbackSourcePath` 指定的受信离线副本，最后才访问 manifest 白名单中的固定远端版本。NLI 五个文件固定到 Hugging Face revision `0a71e92a985b6e1ad1828cf67ce9c459639c1dca`；旧 `sbert.onnx`、`xgboost_qvalue.onnx`、tokenizer 和词典固定到 ReciteHelper 审计提交 `21288821229eb8a1da7f5a38d248fdfd10104f80`，`vocab.txt` 固定到仍含该文件的提交 `7f0fefb68e92311d297c558a35a2a72557031d41`。脚本仅允许这些 HTTPS 主机与精确提交路径，并对全部 19 个文件重新校验长度和 SHA-256；使用灾备会明确输出警告及来源统计，不会用未经校验的文件掩盖镜像故障。`-SkipHashVerification` 仅为命令兼容保留，实际不会关闭完整性校验。

维护者在 OSCA 不可达时可从用户确认的完整副本离线恢复：

```powershell
.\scripts\import-recitehelper-assets.ps1 -ReciteHelperRoot D:\Projects\ReciteHelper
.\scripts\download-model-resources.ps1 `
  -FallbackSourcePath D:\TrustedBackups\GalReview-ModelService-Resources
```

导入脚本只会从 `ReciteHelper.Wpf\bin\Debug\net10.0-windows7.0\Resources` 导入旧模型、`vocab.txt`、tokenizer 和 Jieba 资源，不包含新的 NLI；第二条命令可从一份完整、同构的 `Resources` 离线备份逐文件补齐。完全离线环境必须准备含 NLI 的完整备份。无论使用哪条路径，文件只有在与 manifest 完全一致时才会被接纳。目标仍被 Git 忽略；不得把恢复后的二进制资源提交到源码仓库。
ModelService publish 与容器镜像同时包含 `THIRD_PARTY_LICENSES/ReciteHelper.LICENSE`、
`THIRD_PARTY_LICENSES/MultilingualMiniLMNli.LICENSE` 和
`NOTICE.md`；部署裁剪镜像时不得只复制 DLL/模型而移除许可证文件。

### 经典复习项目主线更新的部署顺序

本版新增无数据库的 ModelService 容器与内部端口 `5109`，将答案 NLI、模型资产和门禁从 PracticeService 移出；同时收紧 PracticeService 与 KnowledgeService 的业务契约，把
KnowledgeService mastery 算法升级为 `sm2-graph-v2`，并把前端入口
从全局 GalReview 计划切到研习册上下文。图谱所有权同时由 material 改为 StudyProject，新增
KnowledgeService ↔ PracticeService 的两条受信作用域核验路由；Gateway 路由表也随之更新。四者必须
作为一个发布单元。推荐顺序：

```bash
docker compose --env-file .env -f compose.integration.yaml build knowledge-service model-service practice-service gateway frontend
docker compose --env-file .env -f compose.integration.yaml up -d --wait knowledge-service model-service practice-service gateway frontend
```

兼容与回滚边界：

- 新建研习册先以 `graphId=null` 落库，再用 `studyProjectId + materialId` 构建本册图谱、PATCH 绑定并自动成题。
  藏书阁不得提前构图。中断态与旧包的 `graphId=null` 数据不迁移、不删除；本册“恢复自动成题”会先恢复识网。
- KnowledgeService 启动时删除旧 `(ownerUserId, materialId, version)` 唯一约束，创建
  `(ownerUserId, studyProjectId, version)` 约束与索引。旧图不改写、不删除，缺少 `studyProjectId` 时只按
  既有 graphId 兼容读取，不能绑定给新册。回滚到旧 KnowledgeService 前必须停止新立册写入，否则旧服务
  会把同资料不同研习册错误视为同一版本序列。
- 图谱项目中历史 `DRAFT` 且 `knowledgePointId=null` 的题目不会直接进入计分会话；新版本会在研习册页面、
  SMART 会话和组卷前自动重跑来源校验与唯一补签，成功后原地写为带版本递增的 READY。来源失效或多义题
  仍保留草稿。Mongo 不需要离线 schema migration。
- 自动成题必须携带 OPEN plan/snapshot；滚动发布期间旧前端仍发送无 plan 请求时会得到
  `400 PLAN_REQUIRED`，因此不要长时间混跑新 PracticeService 与旧前端。
- 每次章节练习、模拟试卷与故事回响都创建新 PlanGraph。已完成或过期计划不得因重启、回滚或恢复
  localStorage 再次使用；遇到 `REVIEW_PLAN_NOT_OPEN` 应回到研习册重新开始。
- `sm2-graph-v2` 不迁移既有 mastery 行：下一次直接作答会把展示 score 更新为本次 quality 的
  直接投影，并继续推进原有 SM-2 interval/easiness/repetitions。新旧 KnowledgeService 实例不得
  长时间混跑，否则同一用户会看到两种 score 语义；滚动发布应先停止新会话结果提交，再整体替换。
- `sm2-graph-v2` 不再为未作答的前置或后继知识点写入推断分。发布后，图谱继续参与到期目标覆盖，
  但只有明确绑定该知识点的普通练习、试卷或故事作答可以改变该点 mastery。
- 2026-08-09 的前端顺序调整不改变 API、路由、容器或环境变量；只需重新构建并替换 `frontend`。
  发布后确认侧栏与首页均为“藏书阁”先于“研习册”，且 `/projects` 的“立册”表单随页面正常滚动，
  不再 sticky 覆盖其下方的项目包导入区。
- 同日的研习入口可用性修正仍是纯前端发布：无 READY 题时显示“题库待成”，入口点击后在调用
  assessment-plan API 前给出成题/核对指引。验收时需确认普通不可用按钮使用 `not-allowed`，只有
  `aria-busy=true` 的真实进行中操作显示等待光标。
- 恢复“立册即成题”需要同时发布 `gateway`、`knowledge-service`、`practice-service` 与 `frontend`：前端在创建册后
  先调用现有构图接口并绑定项目，再复用章节、learning-plan 和 question-generation 接口完成编排；首次建库
  使用整册 Learning Plan、请求四类题并省略 `targetCount`。`recite-question-v2` 只有在来源、答案、第二遍回验和唯一
  pointId 门禁均成立时才写 READY；显式题库/半结构化讲义优先忠实提取，普通正文才调用 DeepSeek。只替换前端无法获得这一保证，
  发布时必须重建并替换 `practice-service`。
  滚动发布时先替换 Gateway、PracticeService、KnowledgeService，再替换 Frontend；旧前端的资料级构图请求会因缺少
  `studyProjectId` 得到 400，故部署窗口内应暂停售新立册。新前端遇到
  credits 不足或生成失败会保留已建立的册并引导到同册重试，不会重复立册。
- Gateway 的 question-generation 路由和前端请求超时均为 600 秒；反向代理的读取超时不得低于该值。
  这只允许长任务完成，不代表 UI 的百分比可伪造；进度仍以服务端任务状态为准。
- `DEEPSEEK_API_KEY` 为空时 PracticeService 不调用模型：可直接核对的结构化题仍可生成，需要模型的普通正文会留下
  `QUESTION_MODEL_NOT_CONFIGURED` 诊断。上线前应以真实普通教材验证 provider JSON、第二遍来源约束回验和
  `usage.total_tokens` 结算；不得通过恢复旧模板兜底来掩盖配置缺失。
- 回滚应用镜像不会回滚已经写入的题目绑定和 mastery。需要回滚时先停止新会话入口，等待活动会话
  完成或明确放弃，再回滚 `practice-service` 与 `frontend`；不得回滚 Neo4j/Mongo 数据卷来撤销学习记录。

### 默认服务

```bash
docker compose --env-file .env -f compose.integration.yaml build
docker compose --env-file .env -f compose.integration.yaml up -d --wait
docker compose --env-file .env -f compose.integration.yaml ps
```

如果 Docker Compose 版本不支持 `--wait`，先执行 `up -d`，再通过 `ps` 等待所有带健康检查的容器进入 `healthy`。

### 启用 OCR

```bash
docker compose --env-file .env -f compose.integration.yaml --profile ocr build
docker compose --env-file .env -f compose.integration.yaml --profile ocr up -d --wait
```

不启用 `ocr` profile 时，普通文本、Markdown、HTML、DOCX 和带文本层的 PDF 仍由 FileService 解析；扫描 PDF 与图片不能据此声称已完成 OCR。

### 停止

```bash
docker compose --env-file .env -f compose.integration.yaml down
```

普通 `down` 会移除容器和网络，但保留命名卷。不要在日常停止或更新时使用 `down -v`；它会删除 MySQL、MongoDB、Neo4j 等卷中的数据。

## 5. 健康检查

先查看容器状态：

```bash
docker compose --env-file .env -f compose.integration.yaml ps
```

再检查外部入口。下面以模板默认端口为例；修改端口后应使用 `.env` 中的实际值：

```bash
curl --fail http://127.0.0.1:5000/healthz
curl --fail http://127.0.0.1:5000/readyz
curl --fail http://127.0.0.1:5104/healthz
curl --fail http://127.0.0.1:5104/readyz
curl --fail http://127.0.0.1:5120/healthz
```

PowerShell 可使用：

```powershell
Invoke-WebRequest http://127.0.0.1:5000/healthz
Invoke-WebRequest http://127.0.0.1:5000/readyz
Invoke-WebRequest http://127.0.0.1:5120/healthz
```

`/healthz` 只表示进程存活；`/readyz` 才表示 Gateway 配置中的关键依赖可用。内部服务未映射到宿主机时，以容器的 `healthy` 状态为准，也可查看具体结果：

当前 Compose 的 Gateway readiness 会检查 UserService、AuthService、FileService、KnowledgeService、GalGameService、RenderService、PracticeService、CreditService 和 ModelService；Frontend 自身通过容器 `/healthz` 检查。CreditService `/readyz` 必须报告 `storage=MySQL`，其镜像通过端口 `5108` 的 readiness healthcheck 后，Auth/Practice/GalGame 才启动。ModelService `/readyz` 列出 NLI ONNX、SentencePiece、严格同义词词典，以及仅用于兼容诊断的 SBERT/vocab 的 `READY/MISSING/HASH_MISMATCH/LOAD_FAILED` 状态；任一必需资产不可用时返回 `503`。PracticeService 不重复装载或扫描模型，模型调用失败时主观题自动拒判。OCRService 是可选 profile，不进入 Gateway readiness。

```bash
docker inspect --format '{{json .State.Health}}' "$(docker compose --env-file .env -f compose.integration.yaml ps -q file-service)"
```

## 6. Linux 服务器部署

### 6.1 网络边界

Frontend 镜像以非 root Node 进程提供静态文件，并把 `/api` 同源代理到 Gateway。推荐让 Gateway 继续绑定服务器回环地址，由现有 Nginx、Caddy、Traefik 或云负载均衡把域名与 HTTPS 转发到 Frontend：

```dotenv
GATEWAY_BIND_ADDRESS=127.0.0.1
DIAGNOSTIC_BIND_ADDRESS=127.0.0.1
FRONTEND_BIND_ADDRESS=0.0.0.0
```

如果暂时没有反向代理，可通过 Frontend 的宿主端口访问页面；直接暴露 HTTP 不具备 TLS，不能作为正式公网方案。只有调试 API 时才需要把 `GATEWAY_BIND_ADDRESS` 改为服务器网卡地址或 `0.0.0.0`，并用防火墙限制来源。

外部反向代理转发时应保留请求体、`Authorization`、`Content-Type`、`X-Correlation-Id` 和 ETag 相关头，并把上传超时设置得不低于 Gateway 的 `UPLOAD_TIMEOUT_MS`。API 路径仍以 `contract.md` 为准。

仓库提供了可直接调整的 Nginx 示例 `deploy/nginx/galreview.conf.example`。其中请求体上限为
52 MiB（Practice 项目包文件仍限制 50 MiB，资料文件仍限制 10 MiB），并关闭上传请求缓冲、把读写超时设为 190 秒。
部署后先检查配置再重载：

```bash
sudo cp deploy/nginx/galreview.conf.example /etc/nginx/conf.d/galreview.conf
sudo nginx -t
sudo systemctl reload nginx
```

若域名上传返回纯文本或 HTML 的 `413/502/504`，且请求没有出现在 Frontend、Gateway 或
FileService 日志中，错误来自该仓库之外的云负载均衡或上一层代理；该层也必须使用不小于
52 MiB 的请求体限制和不短于 190 秒的上传超时。

### 6.2 构建并启动

把仓库检出到固定发布目录，在该目录准备 `.env`，然后执行：

```bash
docker compose --env-file .env -f compose.integration.yaml config --quiet
docker compose --env-file .env -f compose.integration.yaml build --pull
docker compose --env-file .env -f compose.integration.yaml up -d --wait
docker compose --env-file .env -f compose.integration.yaml ps
```

启用 OCR 时，在 `build` 和 `up` 命令中加入 `--profile ocr`。

部署完成后只开放用户真正需要的 Frontend HTTP/HTTPS 端口。Gateway 的宿主端口可留作回环诊断；MongoDB、MySQL、Neo4j Bolt、各后端服务端口和 OCRService 都应留在 Compose 网络内，诊断端口仅绑定回环地址。

### 6.3 开机恢复

Compose 中的服务使用 `restart: unless-stopped`。Docker daemon 启动后会自动恢复容器。服务器重启后仍应执行以下检查：

```bash
docker compose --env-file .env -f compose.integration.yaml ps
curl --fail http://127.0.0.1:5000/readyz
```

## 7. 单独构建或更新服务

日常修改单个服务时，不必重建全部镜像：

```bash
docker compose --env-file .env -f compose.integration.yaml build <service-name>
docker compose --env-file .env -f compose.integration.yaml up -d --no-deps --wait <service-name>
```

只有确认依赖已经运行且配置未变时才使用 `--no-deps`。首次部署应启动完整 Compose。

| 服务 | 构建上下文 / Dockerfile | 运行依赖与注意事项 |
|---|---|---|
| `gateway` | `gateway/Dockerfile` | 依赖其 `READINESS_SERVICES` 中列出的服务；浏览器与服务间请求的唯一入口 |
| `user-service` | `backend/UserService/Dockerfile` | 本地默认 Mock；服务器模板使用 `user-mysql`，权威用户资料只写入该实例 |
| `auth-service` | `backend/AuthService/Dockerfile` | 本地默认 Mock；服务器模板使用 `auth-mysql`，无邀请码注册时经 Gateway 访问 UserService 并幂等创建 CreditService 账户 |
| `file-service` | `backend/FileService/Dockerfile` | 依赖 `mongo`；启用图片/扫描件识别时还依赖 `ocr-service` |
| `knowledge-service` | `backend/KnowledgeService/KnowledgeService.API/Dockerfile` | 依赖 `neo4j`，构图时经 Gateway 读取 FileService 文本；向 PracticeService 的既有图谱 scope 响应附带本册补签候选点 |
| `galgame-service` | `backend/GalGameService/Dockerfile` | 经 Gateway 读取 KnowledgeService PlanGraph，并在生成前后调用 CreditService 预授权/结算；任务和包持久化到 `qzwl_galgame` |
| `render-service` | `backend/RenderService/Dockerfile` | 编译并自检 `cpp-wasm-0.2.0` runtime，公开 WASM 与 JS Adapter，并提供 ReviewSession、进度快照、作答和同步证据提交 |
| `practice-service` | `backend/PracticeService/Dockerfile` | 发布 `PracticeService.API`；内部为 API/Application/Domain/Persistence 四层并由 MediatR CQRS 解耦；依赖 `mongo`、Gateway、File/Knowledge/Credit/Model 内部契约，但不装载模型；按 PlanGraph 目标生成带知识点/原文证据的 READY 题，并自动修复来源可验证的旧草稿绑定；SMART/EXAM 只选择计划内已覆盖点但不被单个缺口阻断；章节练习和试卷完成后提交 mastery；题库生成预授权并按实际内容结算；共享 `.qzwlp` 存 GridFS |
| `credit-service` | `backend/CreditService/Dockerfile` | API/Application/Domain/Persistence 四层，Application 使用 MediatR CQRS；依赖 `credit-mysql`，内部端口 `5108`，不向宿主发布 |
| `model-service` | `backend/ModelService/ModelService.API/Dockerfile` | API/Application/Domain/Persistence 四层，Application 使用 MediatR CQRS；无数据库，独占本地模型资产，内部端口 `5109`，只接受 PracticeService 经 Gateway 调用 |
| `frontend` | `frontend/Dockerfile` | 生产静态构建；容器内 Node 服务通过 `GATEWAY_UPSTREAM` 同源代理 `/api` |
| `ocr-service` | `backend/OCRService/Dockerfile` | `ocr` profile；只允许 FileService 在内部网络调用 |
| `user-mysql` | `mysql:8.4` | 只供 UserService；使用独立数据卷，不映射宿主端口 |
| `auth-mysql` | `mysql:8.4` | 只供 AuthService；使用独立数据卷，不映射宿主端口 |
| `credit-mysql` | `mysql:8.4` | 只供 CreditService；`qzwl_credit` 及账本使用独立数据卷，不映射宿主端口 |
| `mongo` | `mongo:8.0` | 供 FileService、GalGameService、PracticeService 使用；各自只访问 `qzwl_file`、`qzwl_galgame`、`qzwl_practice` 权威数据库 |
| `neo4j` | `neo4j:2026.06.0` | 只由 KnowledgeService 写入；Browser/Bolt 宿主映射仅用于受限诊断 |

### Knowledge/Practice v3 题库升级

`chapter-segmenter-v3` / `knowledge-extractor-v3` 与 Practice 的长文分片、精确题干绑定必须作为同一
兼容批次部署：至少重新构建并替换 `knowledge-service`、`practice-service` 和 `frontend`。本次不增加
容器、不修改 Neo4j/Mongo schema；算法版本已经进入图谱指纹，因此既有 v2 READY 图继续只读，不会被
原地补写。需要应用修复的研习册应在原 `StudyProject` 内用新的 `Idempotency-Key` 重建 v3 图、重新绑定
项目并自动成题；不得复用历史 build ID、graph ID 或另建资料级共享图。部署后应以新建测试用户和资料
验证图谱响应的 `segmenterVersion=chapter-segmenter-v3`、`extractorVersion=knowledge-extractor-v3`，并
核对 READY 题均有唯一 `knowledgePointId`。回滚应用镜像不会删除 v3 图；旧版本客户端不支持 v3 构图，
故回滚时应同时回滚这三个组件，且不要把 v3 图重新绑定给只接受 v2 的旧前端流程。

### 自动补签与部分题库覆盖修复

该修复不增加容器、端口、环境变量或数据库 schema，但同时修改 `knowledge-service` 的既有内部 scope
响应、`practice-service` 的题目 PATCH/会话选择逻辑和 `frontend` 的自动触发行为，因此至少按以下顺序
重建替换：

```bash
docker compose --env-file .env -f compose.integration.yaml build knowledge-service practice-service frontend
docker compose --env-file .env -f compose.integration.yaml up -d --wait knowledge-service practice-service frontend
```

先发布 KnowledgeService，保证 scope 响应已有 `points[]`；旧 PracticeService 会忽略新增字段。随后发布
PracticeService，最后发布 Frontend。新 PracticeService 在暂时连接旧 KnowledgeService 时仍可用 PlanGraph
修复当前复习目标，但页面自动补签会因 scope 不含点而返回明确上游错误，因此不要长期混跑。

部署后使用新建或现有测试册验证：

1. 准备一条带可校验 source range/checksum、题干为 `请解释“第二性比”。`、知识点为空的 DRAFT；打开
   研习册后应自动绑定本册唯一“第二性比”知识点并成为 READY，版本加一。
2. 构造至少三个按优先级排列的 PlanGraph 目标，使首个目标缺题、后两个目标各有 READY 题；开始温习应
   创建含后两个计划内知识点的会话，不得返回覆盖错误，也不得选入计划外题。
3. 当所有计划目标均无 READY 题时仍应返回 `422 QUESTION_COVERAGE_GAP`；当来源 checksum 错误或两个
   知识点同样匹配时，草稿必须保持 DRAFT。

回滚时 Frontend、PracticeService、KnowledgeService 逆序整体回滚。自动补签已写入 Mongo 的题目只是
增加合法 pointId、READY 状态和版本，不应删除；旧版本可继续读取。不要回滚 Mongo/Neo4j 数据卷。

### Practice 主观题 NLI 判分升级

本升级新增无数据库的 ModelService 与内部端口 `5109`，并把 `PracticeAnswer.correct/quality/awardedScore` 扩宽为 nullable，
并新增 `gradingStatus/outcome/abstainReason/facets`。旧前端会把 `correct=null` 误绘成错题，因此
PracticeService 与 Frontend 必须在暂停新答题会话的短维护窗口内作为一个发布单元替换：

```bash
pwsh ./scripts/download-model-resources.ps1
docker compose --env-file .env -f compose.integration.yaml build model-service practice-service gateway frontend
docker compose --env-file .env -f compose.integration.yaml up -d --wait model-service practice-service gateway frontend
```

发布后先查看 ModelService `/readyz`，确认 `nli-model.onnx`、`nli-sentencepiece.model` 与
`nli-synonym-lexicon` 都为 `READY`。随后至少用一题真实名词解释验证三条路径：完整同义改写形成
`DECIDED + quality=5`；明显矛盾形成 `DECIDED + quality=1`；临时使模型不可用时形成
`ABSTAINED + correct=null + quality=null`，完成会话后该题不得出现在 Knowledge evidence 中。前端不得显示
相似度、quality 技术值或任何用户自评按钮；拒判文案必须明确“不影响掌握度与复习时间”。

填空等价规则升级只需重新构建并滚动替换 PracticeService，不新增容器、环境变量、模型资产或数据库
迁移。发布后至少验证 `两个/二/2`、`(1, 3)/(1,3)`、`G+/革兰氏阳性` 判为正确，同时验证
`G+/G-`、`(1,3)/(3,1)` 和圆括号/方括号不会被合并。

回滚应用前应暂停新会话并等待活动提交完成。已有 `ABSTAINED` 记录可被旧后端反序列化为 nullable 字段，
但旧前端无法正确表达三态，因此 Practice 与 Frontend 必须一同回滚；不得用数据库脚本把拒判记录改成错题。

### PR #18 安全批次与兼容部署

Auth、OCR、File 与 GalGame 的安全修改必须作为同一发布批次验证：

- AuthService 新部署只注入 `Admin__PasswordHash` / `GALREVIEW_ADMIN_PASSWORD_HASH`。在受控终端运行
  `.\scripts\new-admin-password-hash.ps1` 生成 Identity V3 hash；不要把管理员明文写入 `.env`、命令行或
  `Admin__Password`。旧明文键仅为短期兼容保留。
- OCRService 除 `/healthz` 外要求 `X-Gateway-Key`；Compose 使用 `FILE_SERVICE_KEY` 同时注入 OCR 的
  `GATEWAY_KEY` 和 FileService 的调用端。更新时应一起重建 `ocr-service` 与 `file-service`，先验证无密钥
  401、正确密钥 200，再开放扫描件入口。
- GalGameService 在 replica set 上用事务保存 package/manifest/owner；仓库默认 standalone Mongo 不支持
  事务，服务会记录 warning 并使用相同 packageId 的幂等顺序 upsert。credits 只有在音频与包持久化成功
  后结算；若日志出现 package persistence 失败，应确认 reservation 已释放，不能手工重复扣费。
- 密码重置码改为 8 位无歧义大写字母/数字；消费端仍接受迁移窗口内已签发的旧 6 位码。未注册邮箱请求
  与已注册邮箱统一返回 202，运维排障不得恢复可枚举的 404。

发布后至少执行管理员正确/错误密码、密码重置不存在邮箱、OCR 双路径、standalone Mongo 故事生成与
最终 held=0 的冒烟。回滚不得回滚数据库卷；若回滚到无 OCR 鉴权的旧镜像，应同时停止 OCR profile，
不能把未鉴权服务继续留在容器网络中。

基础设施可以单独恢复：

```bash
docker compose --env-file .env -f compose.integration.yaml up -d --wait user-mysql auth-mysql credit-mysql mongo neo4j
```

查看单个服务日志：

```bash
docker compose --env-file .env -f compose.integration.yaml logs --tail=200 <service-name>
docker compose --env-file .env -f compose.integration.yaml logs -f <service-name>
```

共享日志前应清除令牌、邮箱、连接串、服务密钥和上传资料内容。

## 8. 更新与回滚

### 更新

1. 记录当前 Git commit 和镜像状态。
2. 备份三套 MySQL、MongoDB 与 Neo4j。
3. 拉取或切换到待部署版本。
4. 校验配置并重新构建。
5. 只替换发生变化的容器，最后检查 `/readyz` 和全流程。

```bash
git rev-parse HEAD
docker compose --env-file .env -f compose.integration.yaml config --quiet
docker compose --env-file .env -f compose.integration.yaml build --pull
docker compose --env-file .env -f compose.integration.yaml up -d --remove-orphans --wait
docker compose --env-file .env -f compose.integration.yaml ps
```

### 回滚

切回已验证的 commit 后重新构建和启动即可。若新版本已经修改持久化数据结构，回滚代码前必须先确认数据向后兼容，必要时恢复更新前备份。

```bash
git checkout <known-good-commit>
docker compose --env-file .env -f compose.integration.yaml build
docker compose --env-file .env -f compose.integration.yaml up -d --remove-orphans --wait
```

回滚不要删除卷。服务器模板中的 AuthService、UserService 与 CreditService 数据分别保存在 MySQL 卷中，
FileService 与 GalGameService 数据保存在 MongoDB 卷中；仅显式使用 memory provider 时，
GalGameService 的生成状态无法通过卷恢复。

## 9. 数据备份

先创建仅管理员可读的备份目录，并确保磁盘空间充足。

### AuthService / UserService / CreditService MySQL

三项服务使用不同的 MySQL 实例和数据卷，必须分别备份。credits 账本与兑换审计不可由 Auth/User 备份替代。下面的密码只在数据库容器内部从环境变量读取，不会被展开到宿主机的命令文本中；备份期间仍应限制对容器进程和日志的读取权限：

```bash
mkdir -p backups
docker compose --env-file .env -f compose.integration.yaml exec -T auth-mysql \
  sh -c 'exec mysqldump -ugalreview_auth -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers galreview_auth' \
  > "backups/galreview_auth-$(date -u +%Y%m%dT%H%M%SZ).sql"

docker compose --env-file .env -f compose.integration.yaml exec -T user-mysql \
  sh -c 'exec mysqldump -ugalreview_user -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers galreview_user' \
  > "backups/galreview_user-$(date -u +%Y%m%dT%H%M%SZ).sql"

docker compose --env-file .env -f compose.integration.yaml exec -T credit-mysql \
  sh -c 'exec mysqldump -uqzwl_credit -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers qzwl_credit' \
  > "backups/qzwl_credit-$(date -u +%Y%m%dT%H%M%SZ).sql"
```

数据库 root 密码、应用密码和备份文件都属于敏感数据。恢复前应停止对应应用服务，并先在隔离环境确认 SQL 备份可导入。

### MongoDB / FileService、GalGameService、PracticeService

MongoDB 可以在线分别导出三个权威数据库；不能只备份文件库后声称学习项目和题库已备份：

```bash
mkdir -p backups
docker compose --env-file .env -f compose.integration.yaml exec -T mongo \
  mongodump --db qzwl_file --archive --gzip \
  > "backups/qzwl_file-$(date -u +%Y%m%dT%H%M%SZ).archive.gz"

docker compose --env-file .env -f compose.integration.yaml exec -T mongo \
  mongodump --db qzwl_galgame --archive --gzip \
  > "backups/qzwl_galgame-$(date -u +%Y%m%dT%H%M%SZ).archive.gz"

docker compose --env-file .env -f compose.integration.yaml exec -T mongo \
  mongodump --db qzwl_practice --archive --gzip \
  > "backups/qzwl_practice-$(date -u +%Y%m%dT%H%M%SZ).archive.gz"
```

三个备份分别包含资料/解析/GridFS、剧情包，以及学习项目/题库/练习、考试会话与共享项目包 GridFS。恢复会改写数据，应先停止对应服务并在隔离环境验证；不要直接对唯一生产副本试恢复。

### Neo4j / KnowledgeService

Neo4j dump 需要数据库离线。以下命令会短暂停止构图与图谱查询：

```bash
GALREVIEW_BACKUP_DIR="$(pwd)/backups/neo4j-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$GALREVIEW_BACKUP_DIR"
docker compose --env-file .env -f compose.integration.yaml stop knowledge-service neo4j
docker compose --env-file .env -f compose.integration.yaml run --rm --no-deps \
  --volume "$GALREVIEW_BACKUP_DIR:/backups" \
  neo4j neo4j-admin database dump neo4j --to-path=/backups
docker compose --env-file .env -f compose.integration.yaml up -d --wait neo4j knowledge-service
```

执行备份前后都应检查命令退出码和容器健康状态。备份文件应加密后复制到另一台主机或对象存储，不能只留在同一块磁盘。

## 10. 常见问题

### Gateway `/readyz` 返回 503

先查看 Gateway 的 readiness 结果，再逐个检查 `READINESS_SERVICES` 中的容器：

```bash
docker compose --env-file .env -f compose.integration.yaml ps
docker compose --env-file .env -f compose.integration.yaml logs --tail=200 gateway
```

最常见原因是下游容器尚未 healthy、目标 URL 写错，或 Gateway 和目标服务使用了不同的服务密钥。

### 接口返回 401 或 403

- 浏览器请求只应携带 `Authorization: Bearer ...`，不要自行发送内部身份头。
- 服务间请求必须先经过 Gateway，并使用调用服务自己的 `*_SERVICE_KEY`。
- 检查 `.env` 中 Gateway 侧密钥与目标容器接收的 `Gateway__ServiceKey` 是否对应。

不要通过关闭 Gateway 鉴权来绕过密钥错配。

### 宿主端口无法绑定

先检查 `.env` 中的 `GATEWAY_HOST_PORT`、`KNOWLEDGE_HOST_PORT`、
`FRONTEND_HOST_PORT`、`NEO4J_BROWSER_HOST_PORT` 和 `NEO4J_BOLT_HOST_PORT`。若默认端口被
占用或落入 Windows WinNAT 等系统保留段，可把对应变量改为 `5000-5300` 内的其他可用值，
然后重新执行 `docker compose ... config` 和 `up -d --force-recreate`。只修改宿主 published
侧，不要同步改容器 target、数据库原生端口或服务间 URL。

### FileService 不就绪

检查 `mongo` 是否 healthy、命名卷是否可写，以及 FileService 日志中的 MongoDB 连接错误。OCRService 不属于 FileService `/readyz` 的必要条件；只有显式发起 OCR 时才需要启动 `ocr` profile。

### KnowledgeService 不就绪

检查 `neo4j` 健康状态、`NEO4J_PASSWORD` 是否一致以及卷权限。修改密码后，已有 Neo4j 数据卷不会自动重置旧密码；应使用原密码迁移或在确认数据可删除后重新初始化，不能直接删除未知卷。

### ModelService 模型显示降级

先查看 `model-service` 的 `/readyz` 或容器日志，区分 `MISSING`、`HASH_MISMATCH` 与
`LOAD_FAILED`。重新执行仓库内的 `scripts/download-model-resources.ps1`，确认清单
验证通过再重建镜像；OSCA 不稳定时按上文使用受信离线副本或固定提交灾备。不要把哈希检查改成警告，也不要用空模型占位。降级时客观题仍可确定性判分，主观题返回 `ABSTAINED`、不写 mastery 或 SM-2；严禁恢复 Levenshtein fallback。只有 NLI 模型、SentencePiece 与同义词词典均为 `READY` 才能宣称主观题自动判分启用。

### MySQL 密码修改后服务无法启动

`MYSQL_ROOT_PASSWORD` 和 `MYSQL_PASSWORD` 只在空数据卷首次初始化时创建账号。直接修改 `.env` 不会更改已有卷中的数据库密码，还会让 AuthService、UserService 或 CreditService 的连接串与数据库失配。应先使用现有凭据在数据库内修改账号密码，再同步 `.env` 并重启对应服务；不要通过删除数据卷来“重置”正式环境密码。

### credits 不足或兑换失败

- `402 CREDITS_INSUFFICIENT` 是正常业务结果：检查响应 details 的 credits 数值，前端应在用户确认后才打开购买页。
- 兑换码明文只在管理员批量创建响应中返回一次；后续列表只有掩码，不能从数据库恢复明文。生成后应立即通过受控渠道交付。
- 兑换码无效、已兑换、已撤销或过期统一返回 `422 REDEMPTION_CODE_UNAVAILABLE`，不要通过数据库直接改余额绕过账本。
- 若生成任务失败，检查对应预授权是否为 `RELEASED`；成功任务应为 `SETTLED`。`CREDIT_ESTIMATE_EXCEEDED` 需要人工核对估算和模型 usage，不得手工制造负余额。
- 2026-08-08 之前的 CreditService 镜像可能假定 MySQL UUID 一定返回字符串，在当前 MySqlConnector 下会表现为预授权成功、结算或释放 500。更新时必须同时替换 CreditService 镜像，并以真实 MySQL 完成一次 `HELD -> SETTLED` 和一次 `HELD -> RELEASED`，不能只看 `/readyz`。

### OCR 启动慢或识别失败

OCR 镜像较大，首次加载模型也需要时间。检查容器资源、模型下载网络和 `ocr-service` 日志。OCRService 不应映射到公网，也不应由前端直接调用。

### 前端页面可打开但 API 失败

确认 `frontend` 容器的 `GATEWAY_UPSTREAM` 指向 Compose 网络内的 `http://gateway:5000`，并检查 Gateway 的 `/readyz`。生产构建的 API 基址应保持相对路径 `/api/v1`，不要把某台开发机的 `localhost` 编译进静态文件。`CORS_ORIGINS` 应包含用户实际访问页面的 Origin。

### RenderService runtime 或证据提交异常

当前 RenderService 已使用 `cpp-wasm-0.2.0` 完整 ABI、TypeScript 会话层和同步 evidence
提交，不再是返回 501 的基础壳。检查 manifest 版本/checksum、WASM 自检、
`Gateway__ServiceName=RenderService` 与独立密钥，并确认 KnowledgeService 只接受精确的
`RenderService`/`PracticeService` evidence writer 身份。异步 `ReviewCompleted v2` 消息总线
仍未实现，不能用同步提交成功冒充事件发布成功。

## 11. 发布后检查

每次部署或更新至少完成以下检查：

- `docker compose ps` 中所有本次启用的服务均为 running/healthy；
- Gateway `/healthz` 与 `/readyz` 返回成功；
- 前端只调用 Gateway，不出现后端服务直连地址；
- 无邀请码注册、初始 1 credit、余额查询、兑换码单次兑换、批量创建/撤销，以及登录、文件上传、文本提取、构图、计划生成按 `contract.md` 返回；
- Practice 题目生成与 GalGame 游戏生成在开始前预授权，credits 不足时返回 402；成功按实际用量扣除，失败释放 held，页面不展示内部 token 换算；
- PracticeService 与 ModelService 四层项目分别构建和测试通过；ModelService `/readyz` 模型哈希状态与镜像内资产一致，PracticeService 进程中不存在 ONNX/SentencePiece 依赖；
- 普通 Practice 会话和 Render 视觉小说会话都只能经受信身份向 KnowledgeService 提交证据，重复提交不二次更新 mastery；
- 一次完成会关闭对应评估计划；若同一研习册先做普通练习再做故事复习，应从该册 graph 新建第二个不可变评估计划，不能复用已完成计划，否则应得到 `REVIEW_PLAN_NOT_OPEN`；相同资料建立的另一研习册必须使用自己的 graph；
- RenderService 检查 C++/WASM 自检、manifest、会话、同步证据与掌握度更新；异步消息总线未实现时明确标注未测；
- 未启动 `ocr` profile 时，测试结论不包含 OCR；
- 日志和配置输出不含密码、令牌、服务密钥或第三方 API key；
- 三套 MySQL（含 `qzwl_credit` 账本）、MongoDB 与 Neo4j 备份文件可以在隔离环境读取。

具体测试结果记录在 [`test_report.md`](test_report.md)，不能用本部署文档代替实际测试。

2026-08-10 的发布候选应在新增 ModelService 后的 16 容器持久化栈上重新完成注册、初始 credits、上传、解析、构图、
PlanGraph 题目生成、SMART_REVIEW、SM-2 回写、批量制码、兑换、故事生成、Render 事件/进度/
结果幂等和第二次 mastery 回写。部署基线还包含 Practice Mongo `_id` 兼容、Credit MySQL UUID
读取兼容、GalGame credits 错误持久化修复；三项必须随对应镜像一起发布，不应只更新 Gateway。
