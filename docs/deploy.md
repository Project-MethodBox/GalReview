# 部署指南

本文说明如何使用仓库根目录的 `compose.integration.yaml` 在本机或 Linux 服务器启动 GalReview。接口、鉴权头和跨服务调用以 [`contract.md`](contract.md) 为准；本文只记录部署方式，不另行定义接口。

当前 Compose 是联调与单机部署基线，不是高可用集群方案。AuthService、UserService 已分别接入独立 MySQL 容器；仓库本地默认值仍是 `Mock`，服务器 `.env` 模板则使用 `MySql`。GalGameService 的任务与游戏包使用进程内存储。RenderService 当前只是 C++ 编译壳、最小 WASM 与 JS Adapter，尚未实现服务端复习会话和原生 WASM ABI。端口迁移不改变接口路径、鉴权头或请求/响应结构。

## 1. 部署范围

默认 Compose 启动以下组件：

| 组件 | Compose 服务名 | 容器端口 | 宿主机暴露 | 数据 |
|---|---|---:|---|---|
| API Gateway | `gateway` | `5000` | `5000` | 无状态 |
| UserService | `user-service` | `5101` | 不暴露 | 本地默认内存；服务器模板使用独立 MySQL |
| AuthService | `auth-service` | `5102` | 不暴露 | 本地默认内存；服务器模板使用独立 MySQL |
| FileService | `file-service` | `5103` | 不暴露 | MongoDB / GridFS |
| KnowledgeService | `knowledge-service` | `5104` | `5104`，仅诊断 | Neo4j |
| GalGameService | `galgame-service` | `5105` | 不暴露 | 当前为进程内临时存储 |
| RenderService | `render-service` | `5106` | 不暴露 | C++ / JS 基础工具链壳；无会话存储 |
| Frontend | `frontend` | `5120` | `5120` | Node 静态站点；同源代理 `/api` 到 Gateway |
| User MySQL | `user-mysql` | `5251` | 不暴露 | `user-mysql-data` 卷 |
| Auth MySQL | `auth-mysql` | `5252` | 不暴露 | `auth-mysql-data` 卷 |
| MongoDB | `mongo` | `5253` | 不暴露 | `file-mongo-data` 卷 |
| Neo4j | `neo4j` | `5254/5255` | `5254/5255`，仅诊断 | `knowledge-neo4j-data` 卷 |

OCRService 使用 `ocr` profile，可按需加入：

| 组件 | Compose 服务名 | 容器端口 | 宿主机暴露 | 说明 |
|---|---|---:|---|---|
| OCRService | `ocr-service` | `5110` | 不暴露 | 仅供 FileService 调用；不经过 Gateway |

固定端口分配为：Gateway `5000`，User/Auth/File/Knowledge/GalGame/Render 分别为
`5101-5106`（其中当前未分配 `5107-5109`），OCR `5110`，Frontend `5120`，Vite 开发与
预览分别为 `5121`、`5122`，User/Auth MySQL 为 `5251`、`5252`，MongoDB `5253`，Neo4j
Browser/Bolt 为 `5254`、`5255`，SMTP 转发入口 `5256`。Render 代理回退只使用
`5257-5259`，测试临时端口只使用 `5260-5299`。

MySQL 和 MongoDB 的上游镜像可能在 `docker compose ps` 中继续显示镜像自带的旧
`EXPOSE` 元数据；它不是活动监听或宿主发布。Compose 已改写数据库进程的真实监听端口，
并关闭未使用的 MySQL X Plugin，数据库也没有宿主端口映射。

上述约束仅覆盖项目服务、项目侧代理和已配置依赖的显式监听端口。Docker 拉取镜像、
NuGet/npm/PyPI 下载及调用外部 HTTPS 服务使用的协议隐式端口不纳入该范围。

## 2. 前置条件

- Docker Engine 24 或更新版本，或已启用 Linux 容器的 Docker Desktop。
- Docker Compose v2；使用 `docker compose version` 检查。
- 能够访问项目使用的基础镜像与 NuGet、npm、PyPI 软件源。
- 服务器部署建议使用独立数据盘保存 Docker 镜像和卷，并在首次构建前配置好 Docker 数据目录。
- 若启用 OCR，需要为 PaddleOCR 镜像、模型和运行内存预留额外空间；首次构建和首次识别通常较慢。

宿主机不需要另行安装 .NET、Node.js、Python、MongoDB 或 Neo4j。它们都在容器中构建或运行。

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
| `NEO4J_PASSWORD` | Neo4j 的 `neo4j` 用户密码 |
| `USER_MYSQL_ROOT_PASSWORD` | UserService 专用 MySQL 实例的 root 密码，仅数据库容器使用 |
| `USER_MYSQL_PASSWORD` | UserService 连接其 MySQL 的应用用户密码 |
| `AUTH_MYSQL_ROOT_PASSWORD` | AuthService 专用 MySQL 实例的 root 密码，仅数据库容器使用 |
| `AUTH_MYSQL_PASSWORD` | AuthService 连接其 MySQL 的应用用户密码 |
| `GALREVIEW_ADMIN_USERNAME` | 初始管理员用户名 |
| `GALREVIEW_ADMIN_PASSWORD` | 初始管理员密码 |
| `SMTP_HOST`、`SMTP_PORT`、`SMTP_USE_SSL` | AuthService 密码重置邮件的 SMTP 连接配置 |
| `SMTP_USERNAME`、`SMTP_PASSWORD` | SMTP 认证信息；`SMTP_PASSWORD` 通常是授权码 |
| `SMTP_FROM_ADDRESS`、`SMTP_FROM_NAME` | 密码重置邮件的发件地址和显示名 |
| `ACCOUNT_FRONTEND_BASE_URL` | 注入 AuthService 的账户前端公开基址；应与实际站点一致 |
| `AUTH_SERVICE_MODE` | AuthService 运行模式；服务器模板使用 `MySql`，本地默认值为 `Mock` |
| `USER_SERVICE_MODE` | UserService 运行模式；服务器模板使用 `MySql`，本地默认值为 `Mock` |
| `GATEWAY_BIND_ADDRESS` | Gateway 在宿主机的绑定地址 |
| `FRONTEND_BIND_ADDRESS` | Frontend 在宿主机的绑定地址 |
| `DIAGNOSTIC_BIND_ADDRESS` | KnowledgeService 与 Neo4j 诊断端口的绑定地址 |
| `CORS_ORIGINS` | 允许访问 Gateway 的前端 Origin，多个值用逗号分隔 |

建议服务器只把 Frontend 或现有反向代理暴露给外部。Frontend 在容器网络内把 `/api` 转发到 Gateway；KnowledgeService 与 Neo4j 的诊断端口应保持 `127.0.0.1`，不应开放到公网。

Compose 内的两套 MySQL 连接使用 `caching_sha2_password`，并在隔离的容器网络中启用
`AllowPublicKeyRetrieval=True`；MySQL 端口不得映射到公网。若改接 Compose 网络之外的
数据库，应改用受信 CA 的 TLS 连接串，不要沿用当前的 `SslMode=Disabled`。

启用密码重置邮件时，必须完整配置 SMTP 主机、认证信息和发件地址；若刻意留空，注册和登录仍可使用，但邮件重置功能不可用。`ACCOUNT_FRONTEND_BASE_URL` 与 `CORS_ORIGINS` 都应使用用户实际访问的 HTTPS 前端地址，后者只写 Origin，不带路径。

配置完成后先做静态校验。`--quiet` 不会把插值后的密钥打印到终端：

```bash
docker compose --env-file .env -f compose.integration.yaml config --quiet
docker compose --env-file .env -f compose.integration.yaml config --services
docker compose --env-file .env -f compose.integration.yaml config --profiles
```

## 4. 本机启动

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

当前 Compose 的 Gateway readiness 会检查 UserService、AuthService、FileService、KnowledgeService、GalGameService 和 RenderService；Frontend 自身通过容器 `/healthz` 检查。OCRService 是可选 profile，不进入 Gateway readiness。

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
| `auth-service` | `backend/AuthService/Dockerfile` | 本地默认 Mock；服务器模板使用 `auth-mysql`，注册时还需经 Gateway 访问 UserService |
| `file-service` | `backend/FileService/Dockerfile` | 依赖 `mongo`；启用图片/扫描件识别时还依赖 `ocr-service` |
| `knowledge-service` | `backend/KnowledgeService/KnowledgeService.API/Dockerfile` | 依赖 `neo4j`，构图时经 Gateway 读取 FileService 文本 |
| `galgame-service` | `backend/GalGameService/Dockerfile` | 经 Gateway 读取 KnowledgeService PlanGraph；当前任务和包为临时内存数据 |
| `render-service` | `backend/RenderService/Dockerfile` | 编译并自检 C++ 空壳，公开最小 WASM 与 JS Adapter；ReviewSession 返回 501 |
| `frontend` | `frontend/Dockerfile` | 生产静态构建；容器内 Node 服务通过 `GATEWAY_UPSTREAM` 同源代理 `/api` |
| `ocr-service` | `backend/OCRService/Dockerfile` | `ocr` profile；只允许 FileService 在内部网络调用 |
| `user-mysql` | `mysql:8.4` | 只供 UserService；使用独立数据卷，不映射宿主端口 |
| `auth-mysql` | `mysql:8.4` | 只供 AuthService；使用独立数据卷，不映射宿主端口 |
| `mongo` | `mongo:8.0` | 只供 FileService；保存元数据、解析结果和 GridFS 文件 |
| `neo4j` | `neo4j:2026.06.0` | 只由 KnowledgeService 写入；Browser/Bolt 宿主映射仅用于受限诊断 |

基础设施可以单独恢复：

```bash
docker compose --env-file .env -f compose.integration.yaml up -d --wait user-mysql auth-mysql mongo neo4j
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
2. 备份两套 MySQL、MongoDB 与 Neo4j。
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

回滚不要删除卷。服务器模板中的 AuthService 与 UserService 数据分别保存在 MySQL 卷中；本地 `Mock` 模式和 GalGameService 的生成状态无法通过卷恢复。RenderService 基础壳当前没有业务数据。

## 9. 数据备份

先创建仅管理员可读的备份目录，并确保磁盘空间充足。

### AuthService / UserService MySQL

两项服务使用不同的 MySQL 实例和数据卷，必须分别备份。下面的密码只在数据库容器内部从环境变量读取，不会被展开到宿主机的命令文本中；备份期间仍应限制对容器进程和日志的读取权限：

```bash
mkdir -p backups
docker compose --env-file .env -f compose.integration.yaml exec -T auth-mysql \
  sh -c 'exec mysqldump -ugalreview_auth -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers galreview_auth' \
  > "backups/galreview_auth-$(date -u +%Y%m%dT%H%M%SZ).sql"

docker compose --env-file .env -f compose.integration.yaml exec -T user-mysql \
  sh -c 'exec mysqldump -ugalreview_user -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers galreview_user' \
  > "backups/galreview_user-$(date -u +%Y%m%dT%H%M%SZ).sql"
```

数据库 root 密码、应用密码和备份文件都属于敏感数据。恢复前应停止对应应用服务，并先在隔离环境确认 SQL 备份可导入。

### MongoDB / FileService

MongoDB 可以在线导出 FileService 的 `qzwl_file` 数据库：

```bash
mkdir -p backups
docker compose --env-file .env -f compose.integration.yaml exec -T mongo \
  mongodump --db qzwl_file --archive --gzip \
  > "backups/qzwl_file-$(date -u +%Y%m%dT%H%M%SZ).archive.gz"
```

备份包含资料元数据、解析结果和 GridFS 文件。恢复会改写数据，应先停掉 FileService，并在隔离环境验证备份；不要直接对唯一生产副本试恢复。

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

当前宿主端口按契约固定，不接受 `.env` 任意改写。先确认 `5000`、`5104`、`5120`、`5254`、`5255` 未被占用且未落入系统保留段；如操作系统保留策略发生变化，应统一修改 Compose、契约和端口策略测试，不能只在单机绕过。

### FileService 不就绪

检查 `mongo` 是否 healthy、命名卷是否可写，以及 FileService 日志中的 MongoDB 连接错误。OCRService 不属于 FileService `/readyz` 的必要条件；只有显式发起 OCR 时才需要启动 `ocr` profile。

### KnowledgeService 不就绪

检查 `neo4j` 健康状态、`NEO4J_PASSWORD` 是否一致以及卷权限。修改密码后，已有 Neo4j 数据卷不会自动重置旧密码；应使用原密码迁移或在确认数据可删除后重新初始化，不能直接删除未知卷。

### MySQL 密码修改后服务无法启动

`MYSQL_ROOT_PASSWORD` 和 `MYSQL_PASSWORD` 只在空数据卷首次初始化时创建账号。直接修改 `.env` 不会更改已有卷中的数据库密码，还会让 AuthService 或 UserService 的连接串与数据库失配。应先使用现有凭据在数据库内修改账号密码，再同步 `.env` 并重启对应服务；不要通过删除数据卷来“重置”正式环境密码。

### OCR 启动慢或识别失败

OCR 镜像较大，首次加载模型也需要时间。检查容器资源、模型下载网络和 `ocr-service` 日志。OCRService 不应映射到公网，也不应由前端直接调用。

### 前端页面可打开但 API 失败

确认 `frontend` 容器的 `GATEWAY_UPSTREAM` 指向 Compose 网络内的 `http://gateway:5000`，并检查 Gateway 的 `/readyz`。生产构建的 API 基址应保持相对路径 `/api/v1`，不要把某台开发机的 `localhost` 编译进静态文件。`CORS_ORIGINS` 应包含用户实际访问页面的 Origin。

### RenderService 就绪但显示 `wasmAbiComplete=false`

这是当前预期状态：镜像只验证 C++ 工具链可编译、JS Adapter 与最小 WASM 可加载，
`/readyz` 会如实报告 `runtimeMode=SHELL`、`executionEngine=cpp-js-shell`、
`reviewSessionsAvailable=false` 和 `wasmAbiComplete=false`。ReviewSession 返回
`501 RENDER_SESSION_NOT_IMPLEMENTED`，不得把浏览器本地体验描述成结果已经回传。

## 11. 发布后检查

每次部署或更新至少完成以下检查：

- `docker compose ps` 中所有本次启用的服务均为 running/healthy；
- Gateway `/healthz` 与 `/readyz` 返回成功；
- 前端只调用 Gateway，不出现后端服务直连地址；
- 注册、登录、文件上传、文本提取、构图、计划生成和游戏包生成按 `contract.md` 返回；
- 当前 RenderService 基础壳只检查 C++ 自检、manifest、WASM checksum、Adapter 加载和浏览器本地游玩；会话、结果与掌握度更新留待后续实现；
- 未启动 `ocr` profile 时，测试结论不包含 OCR；
- 日志和配置输出不含密码、令牌、服务密钥或第三方 API key；
- 两套 MySQL、MongoDB 与 Neo4j 备份文件可以在隔离环境读取。

具体测试结果记录在 [`test_report.md`](test_report.md)，不能用本部署文档代替实际测试。
