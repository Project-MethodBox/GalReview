# GalReview API Gateway

Gateway 是浏览器和服务间调用的唯一入口，负责路由、认证、可信身份头、
限流、超时、CORS 与链路 ID，不保存领域数据。

## 本地运行

```powershell
pnpm install
pnpm run build
pnpm test
pnpm start
```

默认监听 `http://localhost:5000`，默认下游地址如下：

- UserService：`http://localhost:5101`
- AuthService：`http://localhost:5102`
- FileService：`http://localhost:5103`
- KnowledgeService：`http://localhost:5104`
- GalGameService：`http://localhost:5105`
- RenderService：`http://localhost:5106`
- PracticeService：`http://localhost:5107`
- CreditService：`http://localhost:5108`

完整配置见 [`.env.example`](./.env.example)。

- `*_SERVICE_KEY` 用于验证该服务作为 INTERNAL 调用方时携带的
  `X-Service-Key`，也用于向该目标服务注入 `X-Gateway-Key`。
- `UPLOAD_TIMEOUT_MS` 控制资料上传和 Practice 项目包导入的代理超时。
- `READINESS_SERVICES` 指定 `/readyz` 必须可达的核心服务。默认包含
  默认配置可包含 User、Auth、File、Knowledge、GalGame、Render、Practice、Credit；
  Compose 基线将八个领域服务全部列入就绪检查。

Practice 路由按契约细分限流：题库生成与整卷导入使用 `generation`，项目包上传使用
`upload`，项目/题目/会话/共享包读取使用 `general`。Gateway 不承载题目或判分规则。
项目包文件上限为 50 MiB，Gateway 为 multipart 预留 1 MiB，因此只对
`POST /api/v1/practice-packages/imports` 使用 51 MiB 请求体上限；资料上传仍维持原有
10 MiB 文件和 11 MiB multipart 请求上限。

`/api/v1/credits` 和 `/api/v1/admin/credit-codes` 以用户身份路由至 CreditService；
`/internal/v1/credits` 以服务身份路由。管理员兑换码路由必须位于通用
`/api/v1/admin` AuthService 路由之前，避免被前缀规则截获。

Gateway 不读取 OCR 或模型供应商密钥。`DEEPSEEK_API_KEY`、`BitchSDAU` 等密钥不得进入
Gateway 配置、请求头或日志。

## 信任边界

- 浏览器请求中的 `X-User-Id`、`X-Service-Name`、`X-Service-Key` 和
  `X-Gateway-Key` 会被清除。
- 用户路由通过 AuthService
  `POST /internal/v1/auth/introspections` 验证 Bearer Token，再注入
  `X-User-Id`。
- INTERNAL 路由验证调用方的 `X-Service-Name + X-Service-Key`。转发时
  移除调用方密钥，注入目标服务的 `X-Gateway-Key`，并保留已验证的
  `X-Service-Name`。
- `Authorization` 不透传给业务服务，`Idempotency-Key` 和
  `X-Correlation-Id` 按契约保留。

## 容器

```powershell
docker build -t galreview-gateway .
docker run --rm -p 5000:5000 --env-file .env galreview-gateway
```

在 Compose 网络中，各 `*_SERVICE_URL` 应使用服务 DNS 名和容器端口，例如
`http://knowledge-service:8080`，不能使用容器内的 `localhost`。根目录 Compose 通过
`GATEWAY_HOST_PORT` 把 Gateway 的 `5000` 发布到宿主，默认仍为 `5000`。防火墙的
`5000-5300` 范围只约束这个 published 侧；下游 `*_SERVICE_URL` 是容器内部地址，不受该
范围限制。
