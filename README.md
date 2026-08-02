<p align="center">
  <img src="./design/banner.png" alt="千知万理：GalGame × 多学科智能复习" />
</p>

# 千知万理 · GalReview

> 把自己的复习资料，变成一场会记住学习进度的 GalGame。

千知万理（GalReview）是一套面向多学科复习的学习应用。用户上传讲义、笔记或题库后，系统将资料解析为结构化文本，构建知识图谱，并围绕选定内容生成可交互的剧情式复习体验。每次选择与作答都会沉淀为学习证据，为之后的复习计划提供依据。

## 核心流程

```text
资料上传 → 文本解析 → 知识图谱构建 → 复习计划 → GalGame 游戏包 → 浏览器运行时 → 学习记录
```

知识图谱只在幕后负责理解章节、概念及其关系；用户面对的是连贯的剧情、对话、选择与复习反馈，而不是复杂的图结构或算法参数。

## 已实现能力

- 注册、登录、令牌刷新、会话校验、找回与重置密码。
- 管理员登录、邀请码生成与用户管理。
- 用户资料、学习偏好、密码修改和账户注销。
- TXT、Markdown、HTML、DOCX、文本型 PDF，以及经 OCR 解析的图片/扫描资料上传。
- MongoDB GridFS 文件保存、资料状态与解析任务跟踪。
- 基于 Neo4j 的知识图谱构建、章节/知识点/关系查询与学习计划接口。
- GalGame 游戏包生成与浏览器端 JS/WASM 运行时资源分发。
- API Gateway 的鉴权、内部服务身份、限流、追踪 ID、代理与统一错误响应。

## 当前边界

项目仍在持续开发中。目前已经可以把上传资料转成带有剧情、对白和选择的复习内容，并记录玩家
在游戏中的作答结果；OCR 作为可选能力按需启用，不影响普通文本资料的使用。

## 服务职责

| 服务 | 本地或宿主默认入口 | 职责 |
| --- | ---: | --- |
| Gateway | 5000 | 浏览器与服务间调用的统一入口；鉴权、代理、限流与追踪。 |
| UserService | 5101 | 用户资料、学习偏好与账户生命周期。 |
| AuthService | 5102 | 注册、登录、密码、令牌、会话、邀请码和管理员账户治理。 |
| FileService | 5103 | 资料上传、GridFS 存储、文本提取与解析任务。 |
| KnowledgeService | 5104（Compose 宿主映射） | 知识图谱、知识点、关系与学习计划。 |
| GalGameService | 5105 | 根据图谱与计划生成游戏包。 |
| RenderService | 5106 | 提供 JS/WASM 运行时资源，供浏览器加载游戏包。 |
| OCRService（可选） | 5110 | 图片与扫描件文字识别。 |
| Frontend（生产） | 5120（Compose 宿主映射） | 对外提供前端静态站点，并同源代理 `/api`。 |
| Frontend（开发） | 5121 | Vite 开发服务器。 |
| Frontend（预览） | 5122 | Vite 预览服务器。 |

> 完整的服务边界、接口、容器内外端口映射和安全要求以 [开发契约](./docs/contract.md) 为准。

## 本地开发依赖

- .NET SDK 10。
- Node.js 22 或更新的 LTS 版本。
- MySQL 8：本地开发配置，目前使用 `127.0.0.1:3306`。
- MongoDB：本地开发配置，目前使用 `127.0.0.1:27017`。
- Neo4j：本机原生端口为 Bolt `7687`、Browser `7474`；Compose 默认向宿主映射为
  `5255/5254`。
- 可选：Python 3.13 与 OCRService 所需依赖。

`5000-5300` 只约束 Docker 发布到宿主机、可能需要配置防火墙的端口。MySQL `3306`、
MongoDB `27017`、Neo4j `7474/7687`、容器 target、服务间 URL、SMTP/代理端口和测试临时
端口都不属于这一限制。宿主 published 端口可通过 `.env` 中的 `*_HOST_PORT` 调整；完整
规划见[部署指南](./docs/deploy.md)。数据库不应向公网发布。

## 快速启动

1. 启动 MySQL、MongoDB 与 Neo4j，并确认 Neo4j Bolt 可访问：

   ```powershell
   # 本机安装的 Neo4j；若使用 Compose 宿主映射则改为实际 NEO4J_BOLT_HOST_PORT（默认 5255）
   Test-NetConnection 127.0.0.1 -Port 7687
   ```

2. 在两个终端安装 Node 依赖：

   ```powershell
   cd gateway
   npm install

   cd ..\frontend
   npm install
   ```

3. 分别启动后端服务。开发时建议每项使用一个终端：

   ```powershell
   dotnet run --project backend\UserService\GalGame.UserService.csproj
   dotnet run --project backend\AuthService\GalGame.AuthService.csproj
   dotnet run --project backend\FileService\GalGame.FileService.csproj
   dotnet run --project backend\KnowledgeService\KnowledgeService.API\KnowledgeService.API.csproj -- --urls http://127.0.0.1:5104
   dotnet run --project backend\GalGameService\GalGame.GalGameService.csproj -- --urls http://127.0.0.1:5105
   node backend\RenderService\Runtime\server.mjs
   ```

4. 启动 Gateway 与前端：

   ```powershell
   cd gateway
   npm run dev

   cd ..\frontend
   npm run dev
   ```

5. 打开 `http://127.0.0.1:5121`。Gateway 健康检查地址为 `http://127.0.0.1:5000/healthz`。

如果仅做前端或接口联调，可按服务说明使用 `MOONSTONE_MODE=Mock`；Mock 数据不写入真实数据库。

## 常用验证命令

```powershell
# 只检查 Compose/docker publish 的宿主侧与 *_HOST_PORT 默认值是否位于 5000–5300。
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-PortPolicy.ps1

# Gateway
cd gateway
npm install
npm run build
npm test

# .NET 服务示例
dotnet test backend\AuthService\Tests\GalGame.AuthService.Tests.csproj
dotnet test backend\UserService\Tests\GalGame.UserService.Tests.csproj
dotnet test backend\GalGameService\Tests\GalGame.GalGameService.Tests.csproj
dotnet test backend\KnowledgeService\KnowledgeService.Tests\KnowledgeService.Tests.csproj
```

GitHub Actions 会执行宿主发布端口策略、.NET 构建与测试，以及 Gateway 构建与测试。

## 目录结构

```text
GalReview/
├── backend/       # Auth、User、File、Knowledge、GalGame、Render、OCR 服务
├── gateway/       # Node.js API Gateway
├── frontend/      # React + Vite 前端
├── docs/          # 开发契约、部署与测试文档
├── design/        # 品牌和设计资源
├── scripts/       # 本地校验脚本
└── .github/       # CI 工作流
```

## 文档入口

- [开发契约与接口规范](./docs/contract.md)
- [部署指南](./docs/deploy.md)
- [集成测试报告](./docs/test_report.md)
- [Gateway 说明](./gateway/README.md)
- [AuthService 说明](./backend/AuthService/README.md)
- [UserService 说明](./backend/UserService/README.md)
- [FileService 说明](./backend/FileService/README.md)
- [KnowledgeService 说明](./backend/KnowledgeService/README.md)
- [GalGameService 说明](./backend/GalGameService/README.md)

## 安全与协作约定

- 不提交真实密码、SMTP 授权码、数据库凭据或生产服务密钥；使用环境变量或本地未跟踪配置提供。
- 浏览器仅调用 Gateway，不直接调用内部服务。
- 服务间调用必须携带服务身份与关联 ID；敏感日志需要脱敏。
- 端口、接口字段与错误码变更前，先更新契约并同步相关测试。
