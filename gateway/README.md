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

完整配置见 [`.env.example`](./.env.example)。

- `*_SERVICE_KEY` 用于验证该服务作为 INTERNAL 调用方时携带的
  `X-Service-Key`，也用于向该目标服务注入 `X-Gateway-Key`。
- `UPLOAD_TIMEOUT_MS` 控制 `POST /api/v1/materials` 的代理超时。
- `READINESS_SERVICES` 指定 `/readyz` 必须可达的核心服务。默认包含
  注册、上传、提取、构图闭环所需的 User、Auth、File、Knowledge 四个服务；
  尚未参与当前闭环的 GalGame 与 Render 不阻塞就绪。

Gateway 不读取 OCR 或模型供应商密钥。`DSAPI`、`BitchSDAU` 等密钥不得进入
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
`http://knowledge-service:5104`，不能使用容器内的 `localhost`。
