# 千知万理 API 接口规范与数据契约

> 版本：v0.3
> 状态：BASELINE / ReciteHelper 主线与 credits 计费已落地
> 总负责人：PM & TL `@Arabidopsis`  
> 更新时间：2026-08-08
> 依据：《千知万理 产品需求与技术方案》v0.2

## 0. 文档定位

本文用于冻结团队并行开发所需的最小契约：

- RESTful 资源与端点；
- 请求、响应和公共数据类型；
- 状态码与稳定错误码；
- RabbitMQ / MassTransit 事件载荷；
- 可供调用方直接开发的 Mock 样例。

本文不是最终 OpenAPI，也不是数据库模型。各服务负责人需要在本规范基础上继续设计字段约束、持久化结构和实现方式。

约束强度：

- `BASELINE`：调用方可据此开发，变更必须同步调用方和 Mock。
- `URGENT`：属于当前端到端链路的跨服务义务，必须由标注的服务负责人处理；该标记不扩大 KnowledgeService 的实现范围。
- `OWNER-TBD`：具体细节由服务负责人在正式编码前确认。
- `P1`：不阻塞首个端到端闭环，可在黑客松时间不足时延后。
- `INTERNAL`：只能由服务身份通过 API Gateway 调用，不向浏览器公开。

## 0.1 服务与负责人

| 模块 | 负责人 | 本文覆盖 | 最终设计责任 |
|---|---|---|---|
| UserService | `@Sleexy` | 用户资料与偏好 | 字段、校验、持久化与迁移 |
| AuthService | `@Sleexy` | 注册、会话、令牌、密码恢复与管理员账号治理 | 凭证模型、令牌策略、管理员边界与安全实现 |
| FileService | `@Sleexy` | 上传、GridFS、解析任务与内容访问 | 文件限制、解析器与存储实现 |
| KnowledgeService | `@Arabidopsis` | 图谱、知识点、关系、复习计划与掌握度 | 图谱模型、抽取策略与 Neo4j 查询 |
| GalGameService | `@F15EX` | 游戏生成任务、游戏包与 schema | 生成流程、剧情结构与兼容策略 |
| RenderService | `@Zopiclone` | 复习会话、进度、结果和 WASM 运行时 | C++ / WASM API 与状态机 |
| PracticeService | `@Arabidopsis` | 学习项目、题库、练习、考试、项目包与共享资源 | 题目模型、判分、组卷、导入兼容与 MongoDB 持久化 |
| CreditService | `@Arabidopsis` | credits 账户、预授权、实际结算、兑换码与账本 | 计量规则、CQRS、兑换码安全与 MySQL 持久化 |
| Frontend / WASM Adapter | `@甲烷` | JS 桥接、页面调用与错误展示 | 前端适配器和运行时集成 |
| API Gateway | `@甲烷` | 路由、鉴权、错误、CORS 与链路头 | Gateway 策略与部署配置 |

### 0.2 当前持久化基线

- **UserService 的数据库为 MySQL**：仅持久化用户展示资料、学习偏好及其关联数据。
- **AuthService 的数据库为 MySQL**：仅持久化凭证密码哈希、会话、令牌撤销状态、密码恢复记录、管理员账号治理与管理员审计记录；遗留邀请码表只作迁移兼容，不再提供接口，也不参与注册。
- 同一业务事实只能由一个服务及其权威数据库写入；禁止 AuthService 与 UserService 互相直连或读写对方的 MySQL 数据表。
- **FileService 的数据库为 MongoDB + GridFS**：文件二进制、资料元数据、解析任务和规范化文本只由 FileService 写入。
- **KnowledgeService 的数据库为 Neo4j**：章节、知识点、关系、计划和掌握度只由 KnowledgeService 写入。
- **GalGameService 的数据库为 MongoDB**：生成任务和游戏包存储在 MongoDB 中，容器重启后数据保留；支持 4 种运行模式（`mock-mongodb` / `mock-memory` / `mongodb` / `ephemeral-memory`），通过 `GalGameStore:Provider` 配置项切换。服务启动时自动将因重启而卡在 `RUNNING` 或 `QUEUED` 的生成任务标记为 `FAILED`。
- **RenderService 使用 C++/WASM runtime ABI 与 TypeScript 服务层**：持久化运行时会话、进度与结果，并经 Gateway INTERNAL 提交同步学习证据；异步 `ReviewCompleted v2` 消息仍未实现。
- **PracticeService 的数据库为 MongoDB + GridFS**：学习项目、题库、生成/导入任务、练习与考试会话、兼容项目包和共享包只由 PracticeService 写入；知识掌握度仍只由 KnowledgeService 写入。
- **CreditService 的数据库为独立 MySQL `qzwl_credit`**：credits 账户、兑换码、生成预授权与不可变账本只由 CreditService 写入。服务采用 API、Application、Domain、Persistence 四层，Application 通过 MediatR 实现 CQRS。
- 不得将同一事实跨 MySQL、MongoDB、Neo4j 双写为多个权威来源。

## 1. 架构级调用约束

### 1.1 同步调用

```text
Browser
  -> API Gateway
    -> Target Service

Source Service
  -> API Gateway /internal/v1
    -> Target Service
```

- 禁止浏览器绕过 Gateway 访问业务服务。
- 禁止服务保存其他服务的直连地址。
- 禁止服务直接读取其他服务的数据库。
- 服务间同步调用仍然使用 Gateway 的 RESTful 路由。
- OCRService 是 FileService 的无状态解析执行依赖，不是浏览器或其他领域服务的公共 API；`FileService -> OCRService` 是本规则的受限例外，OCRService 不注册 Gateway 路由且不得暴露公网。
- Gateway 只负责鉴权、路由、超时、错误映射和链路信息，不承载领域规则。

### 1.2 异步调用

- 长流程使用 RabbitMQ + MassTransit。
- 事件只描述已经发生的事实，名称使用过去式。
- 大对象只传引用、摘要和 checksum，不把文件、完整图谱或游戏包放进消息。
- 消费者必须依据 `eventId` 幂等。

### 1.3 路由版本

- 浏览器 API：`/api/v1/...`
- 服务 API：`/internal/v1/...`
- 破坏性变更升级主版本。
- 新增可选字段属于兼容变更，但必须同步更新 Mock。

## 2. 公共 HTTP 契约

### 2.1 请求头

| Header | 必填 | 说明 |
|---|---:|---|
| `Authorization: Bearer <token>` | 受保护路由 | Gateway 验证，业务服务不信任浏览器传入的身份字段 |
| `X-Correlation-Id` | 建议 | 缺失时由 Gateway 生成并回传 |
| `Idempotency-Key` | 指定写接口 | UUID；相同键返回同一业务结果 |
| `Content-Type` | 是 | JSON 使用 `application/json`；上传使用 `multipart/form-data` |
| `X-Service-Name` | INTERNAL 服务调用 Gateway | 与 `X-Service-Key` 一同提交；Gateway 验证后在下游请求中重新注入，浏览器同名头必须被丢弃 |
| `X-Service-Key` | INTERNAL 服务调用 Gateway | 仅用于 Gateway 校验调用服务；转发前必须剥离，不得交给目标业务服务 |
| `X-User-Id` | Gateway -> 业务服务 | 由已通过内省的用户令牌产生；外部同名头必须被丢弃 |
| `X-Gateway-Key` | Gateway -> 业务服务 | 使用目标服务独立密钥（缺省才回退全局密钥）；浏览器和源服务不得自行注入 |

### 2.2 公共数据类型

```ts
type Uuid = string;       // UUID v4，输出小写
type DateTime = string;   // ISO 8601 UTC，例如 2026-07-27T08:30:00Z
type Uri = string;        // Gateway 控制地址、相对地址或短期签名地址
type Sha256 = string;     // 64 位小写十六进制
type Cursor = string;     // 不透明分页游标，调用方不得解析
type SubjectCode = string;// 输入先 Trim + 大写；输出匹配 ^[A-Z][A-Z0-9_]{0,31}$
type JsonObject = Record<string, unknown>;

interface PageMeta {
  nextCursor: Cursor | null;
}
```

### 2.3 统一成功响应

```ts
interface ApiSuccess<T, M = Record<string, never>> {
  data: T;
  meta: M;
  traceId: string;
}
```

```json
{
  "data": {
    "id": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20"
  },
  "meta": {},
  "traceId": "01J..."
}
```

### 2.4 统一错误响应

```ts
interface ApiError {
  code: string;
  message: string;
  details: JsonObject;
}

interface ApiFailure {
  data: null;
  error: ApiError;
  traceId: string;
}
```

AuthService、UserService、FileService、KnowledgeService 与 GalGameService 的 JSON/路由绑定失败均必须返回
上述 `ApiFailure`：畸形 JSON、字段类型错误、缺失 required 标量、非法 Guid 或无法解析的
查询参数统一为 `400 VALIDATION_ERROR`，不得返回框架默认空体或落入 500。唯一的传输级
例外是明确声明为 Binary stream 的
`GET /internal/v1/materials/{materialId}/content`：不可满足的 `Range` 由文件流处理器直接
返回空体 `416`，不包装 JSON 错误信封。

```json
{
  "data": null,
  "error": {
    "code": "MATERIAL_FORMAT_UNSUPPORTED",
    "message": "当前文件格式不受支持",
    "details": {
      "supported": ["pdf", "docx"]
    }
  },
  "traceId": "01J..."
}
```

### 2.5 状态码

| HTTP | 场景 | 错误码示例 |
|---:|---|---|
| `200` | 成功读取或更新 | - |
| `201` | 资源创建成功 | - |
| `202` | 异步任务已接收 | - |
| `204` | 删除、撤销或无响应体更新成功 | - |
| `400` | JSON、查询参数或字段格式错误 | `VALIDATION_ERROR` |
| `401` | 无令牌或令牌失效 | `AUTH_REQUIRED`、`TOKEN_EXPIRED` |
| `403` | 身份有效但无权访问 | `FORBIDDEN` |
| `404` | 资源不存在或对用户不可见 | `RESOURCE_NOT_FOUND` |
| `409` | 状态、版本或幂等冲突 | `STATE_CONFLICT`、`VERSION_CONFLICT` |
| `413` | 文件过大 | `FILE_TOO_LARGE` |
| `415` | 媒体类型不支持 | `MEDIA_TYPE_UNSUPPORTED` |
| `416` | Binary stream 的 `Range` 不可满足；响应为空体 | - |
| `422` | 语法正确但业务规则不满足 | `BUSINESS_RULE_VIOLATION` |
| `429` | 超过限流 | `RATE_LIMITED` |
| `500` | 服务内部错误 | `INTERNAL_ERROR` |
| `502` | 上游返回不可解析或违反服务契约的数据 | `UPSTREAM_CONTRACT_INVALID` |
| `503` | 服务或依赖暂不可用 | `SERVICE_UNAVAILABLE` |

各服务接口表优先列出该端点直接产生的领域状态；经 Gateway 暴露的受保护路由还统一
适用 `401/403/429/502/503`。测试报告必须区分“端点领域分支已验证”和“公共
Gateway 分支由中间件契约测试验证”，不能因表格省略公共状态而宣称它们不存在。

## 3. UserService

> 负责人：`@Sleexy`  
> 拥有：用户资料、偏好与资料更新时间。  
> 不拥有：密码、刷新令牌、图谱、游戏包和复习结果。  
> 数据库：MySQL

### 3.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/internal/v1/users` | 注册后创建用户资料 | `CreateUserProfileRequest` | `UserProfile` | `201/400/403/409` |
| `POST` | `/internal/v1/users/profile-lookups` | 管理员查询认证账户对应的展示名 | `AdminProfileLookupRequest` | `AdminProfileSummary[]` | `200/400/403` |
| `DELETE` | `/internal/v1/users/{userId}` | 管理员删除用户资料与偏好 | - | - | `204/400/403/404` |
| `GET` | `/api/v1/users/me` | 读取当前用户资料 | - | `UserProfile` | `200/401/404` |
| `PATCH` | `/api/v1/users/me` | 部分更新资料 | `UpdateUserProfileRequest` | `UserProfile` | `200/400/404` |
| `PUT` | `/api/v1/users/me` | 兼容性更新资料；当前语义与 PATCH 相同 | `UpdateUserProfileRequest` | `UserProfile` | `200/400/404` |
| `GET` | `/api/v1/users/me/preferences` | 读取学习与显示偏好 | - | `UserPreferences` | `200/401/404` |
| `PUT` | `/api/v1/users/me/preferences` | 幂等替换偏好 | `UserPreferencesInput` | `UserPreferences` | `200/400/404/422` |

### 3.2 数据类型

```ts
interface CreateUserProfileRequest {
  userId: Uuid;           // AuthService 生成
  displayName: string;    // 1-64 字符，禁止纯空白
  locale?: string;        // 默认 zh-CN
}

interface AdminProfileLookupRequest {
  userIds: Uuid[];       // 原始数组最多 500 项（去重前计数）；仅 AuthService 可经 Gateway 调用
}

interface AdminProfileSummary {
  userId: Uuid;
  displayName: string;
}

interface UserProfile {
  userId: Uuid;
  displayName: string;
  avatarUrl: Uri | null;
  locale: string;
  preferredSubjectCodes: SubjectCode[];
  createdAt: DateTime;
  updatedAt: DateTime;
}

interface UpdateUserProfileRequest {
  displayName?: string;
  locale?: string;
  preferredSubjectCodes?: SubjectCode[];
}

type ContentDifficulty = "BASIC" | "STANDARD" | "ADVANCED";

interface UserPreferencesInput {
  dailyGoalMinutes: number;       // int32，建议 5-180
  contentDifficulty: ContentDifficulty;
  reducedMotion: boolean;
}

interface UserPreferences extends UserPreferencesInput {
  updatedAt: DateTime;
}
```

### 3.3 Mock

```json
{
  "data": {
    "userId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
    "displayName": "Arabidopsis",
    "avatarUrl": null,
    "locale": "zh-CN",
    "preferredSubjectCodes": ["AGRONOMY", "MEDICINE"],
    "createdAt": "2026-07-27T08:00:00Z",
    "updatedAt": "2026-07-27T08:00:00Z"
  },
  "meta": {},
  "traceId": "01JUSER..."
}
```

### 3.4 OWNER-TBD

- [ √ ] 头像来源和上传方式：头像暂不支持用户自定义，由前端实现，默认头像为用户名首字符
- [ √ ] `preferredSubjectCodes` 最大数量为10项，超过 10 项或包含空白项时，UserService 返回 400 VALIDATION_ERROR。
- [ √ ] 每个 `preferredSubjectCodes` 输入先 Trim、再执行 invariant 大写；规范化后必须匹配 `SubjectCode`，连字符不合法，响应和持久化只保留规范值。
- [ √ ] `PATCH/PUT /api/v1/users/me` 共享同一更新语义；空请求体、畸形 JSON、JSON `null`、字段类型错误、纯空白 `displayName` 或其他字段校验失败均返回 `400 VALIDATION_ERROR`，不得落入 `500 INTERNAL_ERROR`。
- [ √ ] `PUT /api/v1/users/me/preferences` 的 `dailyGoalMinutes`、`contentDifficulty`、`reducedMotion` 均为 required；任一缺失/null，以及空请求体、畸形 JSON、JSON `null` 或字段类型错误，返回 `400 VALIDATION_ERROR`。三项均存在但目标时长越界或难度不在枚举内时返回 `422 BUSINESS_RULE_VIOLATION`。数字字符串不得按数字宽松接收。
- [ √ ] 账户注销是否进入首版。用户调用 `DELETE /api/v1/auth/account` 并输入当前登录密码确认后，AuthService 经 Gateway 删除 UserService 的资料与偏好，再删除认证凭证、会话、密码恢复记录及认证侧关联数据；操作立即生效且不可恢复。

## 4. AuthService

> 负责人：`@Sleexy`  
> 拥有：凭证、会话、访问令牌、刷新令牌、撤销状态和管理员会话。
> 不拥有：用户展示资料、学习偏好和学习业务数据。  
> 数据库：MySQL

### 4.0 管理员模块边界（BASELINE）

管理员能力是 AuthService 的内部模块，当前不单独部署 Admin Service：

- AuthService 负责管理员登录、管理员会话和用户凭证治理（重置密码、撤销会话、删除认证账户）。credits 与兑换码由 CreditService 独占。
- UserService 仍拥有用户展示资料与偏好。管理员操作如需影响该服务的数据，必须经 Gateway 调用对应的 `/internal/v1/...` 接口；禁止 AuthService 直接读取或修改 UserService 数据库。
- 浏览器只可通过 Gateway 的 `/api/v1/admin/...` 路由访问管理员接口。Gateway 验证 Access Token 并注入可信身份上下文，AuthService 最终判定管理员权限。
- 管理员默认凭据只能用于本地开发，禁止进入浏览器代码、日志、提交到版本控制的生产配置或公开文档。
- 删除用户与重置密码属于高风险操作。生产上线前必须具备可检索的审计记录，至少包含操作者、目标用户、操作类型、结果、时间与 `traceId`。审计表结构为 `OWNER-TBD`。
- 当后台扩展为内容审核、运营、跨服务报表或多角色权限体系时，再评估拆分独立 Admin Service。

### 4.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/auth/registrations` | 创建凭证、credits 账户和初始会话 | `RegistrationRequest` | `AuthSessionResponse` | `201/400/409/503` |
| `POST` | `/api/v1/auth/sessions` | 邮箱与密码登录 | `LoginRequest` | `AuthSessionResponse` | `201/400/401` |
| `GET` | `/api/v1/auth/sessions/{sessionId}` | 读取会话状态 | - | `AuthSession` | `200/404` |
| `DELETE` | `/api/v1/auth/sessions/{sessionId}` | 退出并撤销会话 | - | - | `204/404` |
| `POST` | `/api/v1/auth/tokens` | 刷新访问令牌 | `RefreshTokenRequest` | `TokenPair` | `201/401` |
| `POST` | `/api/v1/auth/password-reset-requests` | 请求密码恢复 | `PasswordResetRequest` | - | `202/400/404` |
| `POST` | `/api/v1/auth/password-resets` | 重设密码 | `PasswordResetConfirmation` | - | `204/422/429` |
| `POST` | `/api/v1/auth/password-changes` | 当前用户修改密码 | `PasswordChangeRequest` | - | `204/400/401/404` |
| `DELETE` | `/api/v1/auth/account` | 当前用户输入密码后永久注销账户 | `AccountDeletionRequest` | - | `204/400/401/403/404/503` |
| `POST` | `/internal/v1/auth/introspections` | 查询令牌状态 | `TokenIntrospectionRequest` | `TokenIntrospection` | `200/403` |

令牌无效、过期或撤销时，AuthService 内省仍返回 `200` 且
`TokenIntrospection.active=false`；浏览器侧的 `401` 由 Gateway 据此生成。内省所用
`X-Gateway-Key` 无效时返回 `403`，Gateway 必须把该服务配置故障转换为 `503`，不能
伪装成用户令牌无效。除表内领域状态外，经 Gateway 暴露的受保护路由还统一适用
`401/403/429/503`。

### 4.1.1 管理员接口（BASELINE）

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/admin/sessions` | 管理员用户名密码登录 | `AdminLoginRequest` | `AuthSessionResponse` | `201/401` |
| `GET` | `/api/v1/admin/users` | 列出已注册用户 | - | `AdminUser[]` | `200/403/502/503` |
| `DELETE` | `/api/v1/admin/users/{userId}` | 删除用户认证账户及其关联认证数据 | - | - | `204/403/404/503` |
| `POST` | `/api/v1/admin/users/{userId}/password` | 管理员重置用户密码并撤销会话 | `AdminPasswordResetRequest` | - | `204/400/403/404` |

`GET /api/v1/admin/users` 只接受 UserService 返回的完整成功信封：`data` 必须是非空引用的
数组（无匹配时使用 `[]`），`meta` 必须为空对象，`traceId` 非空，且数组元素的 UUID、
displayName、唯一性和请求集合归属均有效。上游非成功状态或不可达返回 `503`；上游
`200` 但 JSON/信封/字段违反契约时返回 `502 UPSTREAM_CONTRACT_INVALID`，不得伪装成
客户端 `400` 或静默回退为邮箱。

### 4.2 数据类型

```ts
interface RegistrationRequest {
  email: string;
  password: string;
  displayName: string;
  deviceName?: string;
}

interface LoginRequest {
  email: string;
  password: string;
  deviceName?: string;
}

type SessionStatus = "ACTIVE" | "REVOKED" | "EXPIRED";

interface AuthSession {
  sessionId: Uuid;
  userId: Uuid;
  status: SessionStatus;
  createdAt: DateTime;
  expiresAt: DateTime;
}

interface TokenPair {
  accessToken: string;
  refreshToken: string;
  tokenType: "Bearer";
  expiresInSeconds: number; // int32
}

interface AuthSessionResponse {
  session: AuthSession;
  tokens: TokenPair;
}

interface RefreshTokenRequest {
  refreshToken: string;
}

interface PasswordResetRequest {
  email: string;
}

interface PasswordResetConfirmation {
  resetToken: string; // 六位数字验证码；有效期 10 分钟
  newPassword: string;
}

interface AdminLoginRequest {
  username: string;
  password: string;
}

interface AdminPasswordResetRequest {
  newPassword: string; // 至少 8 个字符
}

interface AdminUser {
  id: Uuid;
  email: string;
  displayName: string;
  isActive: boolean;
}

interface PasswordChangeRequest {
  currentPassword: string;
  newPassword: string;
}
interface AccountDeletionRequest {
  currentPassword: string; // 必填；用于确认立即永久注销
}

interface TokenIntrospectionRequest {
  token: string;
}

interface TokenIntrospection {
  active: boolean;
  userId: Uuid | null;
  sessionId: Uuid | null;
  scopes: string[];
  expiresAt: DateTime | null;
}
```

### 4.3 登录 Mock

```json
{
  "email": "student@example.com",
  "password": "mock114514",
  "deviceName": "Chrome on Windows"
}
```

```json
{
  "data": {
    "session": {
      "sessionId": "6fa43e7f-0383-4c60-b305-8011f4a8cab8",
      "userId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
      "status": "ACTIVE",
      "createdAt": "2026-07-27T08:10:00Z",
      "expiresAt": "2026-08-03T08:10:00Z"
    },
    "tokens": {
      "accessToken": "mock-access-token",
      "refreshToken": "mock-refresh-token",
      "tokenType": "Bearer",
      "expiresInSeconds": 900
    }
  },
  "meta": {},
  "traceId": "01JAUTH..."
}
```

### 4.4 OWNER-TBD

- [ √ ] 密码强度和哈希算法：目前密码要求非空、长度至少为8位字符。加密采用 ASP.NET Core Identity 自带的 PBKDF2 哈希
- [ √ ] Access Token 通过 INTERNAL introspection，token 入库时不是存明文，而是存 SHA256 hash，Gateway 校验 Access Token 时，会调用 AuthService 的内部接口，最后AuthService 通过 token hash 查会话：
- [ √ ] 刷新令牌是否每次轮换：是的，目前刷新令牌是每次刷新都会轮换
- [ √ ] Access Token、Refresh Token和密码重置令牌有效期如下表：
  | 类型 | 有效期 | 说明 |
  |---|---:|---|
  | Access Token | 15 分钟 | 自签发时起的绝对有效期；内省不延长 |
  | Refresh Token | 7 天 | 自签发时起的绝对有效期；使用后轮换新会话 |
  | Reset Password Token | 10 分钟 | 用于忘记密码重设 |


- [ √ ] 注册时 AuthService 与 UserService 的一致性方案。
 #### 注册一致性流程：

 1. AuthService 创建凭证。
 2. AuthService 经 Gateway 调用 `/internal/v1/users`。
 3. UserService 创建 `UserProfile`。
 4. 如果 `UserProfile` 创建失败，AuthService 删除刚创建的凭证。



## 5. FileService

> 负责人：`@Sleexy`  
> 拥有：文件二进制、元数据、checksum、GridFS 和 IngestionJob。  
> 不拥有：知识点语义和剧情生成。

### 5.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/materials` | 上传复习资料 | `multipart MaterialUploadForm` | `Material` | `201/400/413/415` |
| `GET` | `/api/v1/materials` | 分页查询当前用户资料 | Query | `MaterialPage` | `200/400` |
| `GET` | `/api/v1/materials/{materialId}` | 读取资料元数据 | - | `Material` | `200/404` |
| `GET` | `/api/v1/materials/{materialId}/extracted-text-preview` | 当前用户预览已规范化文本 | - | `ExtractedTextDocument` | `200/404/409/422` |
| `DELETE` | `/api/v1/materials/{materialId}` | 删除或标记删除 | - | - | `204/404/409` |
| `POST` | `/api/v1/materials/{materialId}/ingestion-jobs` | 创建解析任务；可显式启用 OCR | `CreateIngestionJobRequest` | `IngestionJob` | `202/400/404/409` |
| `GET` | `/api/v1/ingestion-jobs/{jobId}` | 查询解析进度；OCR 活跃时可附带非权威逐页进度 | - | `IngestionJobResponse` | `200/404` |
| `GET` | `/internal/v1/materials/{materialId}/content` | 服务读取原始内容流 | `Range?` | Binary stream | `200/206/403/404/416` |
| `GET` | `/internal/v1/materials/{materialId}/extracted-text` | **URGENT（跨服务阻塞项）** 服务读取规范化纯文本及来源映射 | - | `ExtractedTextDocument` | `200/403/404/409/422` |

`POST /api/v1/materials/{materialId}/access-grants` 属于
**URGENT（FileService / Gateway，未形成可执行契约、未测试）**。当前 FileService
虽保留同路径占位映射，但它只返回固定 INTERNAL content URL，没有不可伪造 grant
token、服务端过期校验或浏览器可消费的授权链路，因此不得把该映射宣称为“短期内容
授权”。在负责人冻结 token 形状、purpose、TTL、撤销和下载校验语义并完成测试前，
客户端不得调用，当前接口目录也不包含它。

上传入口在写入 GridFS 前验证文件非空、10 MiB 文件本体上限和受支持的扩展名/MIME；
未知扩展名只可在 `text/*` 或 `application/octet-stream` 下走 UTF-8 文本兜底，其他
组合返回 `415 MEDIA_TYPE_UNSUPPORTED`。PDF、DOCX、HTML、Markdown 和图片的解析分派
同时使用规范 MIME 与扩展名：例如 `application/pdf` 即使文件名为 `.bin` 也必须走
PDF 解析，不能把二进制当 UTF-8 文本。

`DELETE /api/v1/materials/{materialId}` 对不存在、已删除或非当前 owner 的资料统一返回
`404 RESOURCE_NOT_FOUND`，不得泄漏其他用户资源是否存在；处于 PROCESSING 或具有
活动任务，以及删除时发生可见状态竞态时返回 `409 STATE_CONFLICT`。Binary content
端点的非法 `Range` 返回空体 `416`，是 2.4 明确的流式响应例外。

列表查询参数：

```ts
interface MaterialListQuery {
  cursor?: Cursor;
  limit?: number;      // 1-100，默认 20
  status?: MaterialStatus;
  subjectCode?: SubjectCode;
}
```

### 5.2 数据类型

```ts
interface MaterialUploadForm {
  file: Blob;
  displayName?: string;
  subjectCode?: SubjectCode;
}

type MaterialStatus =
  | "UPLOADED"
  | "PROCESSING"
  | "READY"
  | "FAILED"
  | "DELETED";

interface Material {
  materialId: Uuid;
  ownerUserId: Uuid;
  displayName: string;
  originalFileName: string;
  mediaType: string;
  sizeBytes: number; // int64
  checksum: Sha256;
  status: MaterialStatus;
  latestIngestionJobId: Uuid | null;
  createdAt: DateTime;
  updatedAt: DateTime;
}

interface MaterialPage {
  items: Material[];
  nextCursor: Cursor | null;
}

interface CreateIngestionJobRequest {
  parserVersion?: string; // 空值使用 files-text-v1
  force?: boolean; // 默认 false
  enableOcr?: boolean; // 默认 false；仅为 true 时允许图片/扫描 PDF 进入 OCR
  ocrMode?: "quick" | "standard"; // 空值默认 standard；其他值返回 400 VALIDATION_ERROR
}

type IngestionJobStatus = "QUEUED" | "RUNNING" | "SUCCEEDED" | "FAILED";

interface IngestionJob {
  jobId: Uuid;
  materialId: Uuid;
  status: IngestionJobStatus;
  progress: number; // int32, 0-100，不可倒退
  parserVersion: string;
  error: ApiError | null;
  createdAt: DateTime;
  updatedAt: DateTime;
  enableOcr: boolean;
  ocrMode: "quick" | "standard";
  ocrUsed: boolean; // 任务完成后表示实际是否调用过 OCR，而不是用户是否允许 OCR
}

interface OcrProgress {
  status: string;
  currentPage: number; // int32
  totalPages: number;   // int32
  phase: string;
}

interface IngestionJobResponse extends IngestionJob {
  ocrProgress?: OcrProgress;
}

interface CreateAccessGrantRequest {
  purpose: "DOWNLOAD" | "SERVICE_READ";
}

interface AccessGrant {
  url: Uri;
  expiresAt: DateTime;
}

interface ExtractedTextDocument {
  materialId: Uuid;
  ownerUserId: Uuid;
  status: "READY";
  text: string;                 // 纯文本，不含 HTML、Markdown、base64 或文件二进制
  encoding: "utf-8";
  normalization: "NFC";
  lineEnding: "LF";
  textChecksum: Sha256;         // 对 NFC + LF 规范化后 text 的精确 UTF-8 字节计算
  textLength: number;           // int64，规范化后 UTF-16 code unit 数量（等于 JS/.NET string.length）
  parserVersion: string;
  sourceMapVersion: "1";
  sourceMap: TextSourceSpan[];
  blocks: TextDocumentBlock[];
  createdAt: DateTime;
}

interface TextSourceSpan {
  startOffset: number;          // int64，基于规范化 text 的 UTF-16 code unit，0-based
  endOffset: number;            // int64，半开区间 [startOffset, endOffset)
  pageNumber: number | null;    // PDF/DOCX 可识别页码时从 1 开始
  paragraphIndex: number | null;// 可识别段落时从 0 开始
  sourceLabel: string | null;   // 例如“第 3 页”“幻灯片 8”；不得替代 offset
}

interface TextDocumentBlock {
  kind: string;                 // 当前解析器可产生 HEADING、PARAGRAPH 等结构类型
  level: number | null;         // 标题级别为 1-6；无层级时为 null
  text: string;                 // 必须与 source 指向的规范化 text 子串逐字一致
  source: TextSourceSpan;       // 必须同时存在于 sourceMap
}
```

### 5.2.1 **URGENT（跨服务阻塞项）** 纯文本交付基线

FileService 必须在最新 `IngestionJob.status="SUCCEEDED"` 后，将 `Material.status` 原子地推进到 `READY`，随后才允许返回 `ExtractedTextDocument` 并发布 `MaterialTextReady v1`。具体规则已经冻结：

- `text` 必须为非空、非纯空白且可由 UTF-8 表示的 Unicode 纯文本；先统一为 NFC，再把 `CRLF`/`CR` 统一为 `LF`。禁止把原始 PDF、DOCX、OCR JSON、HTML、Markdown 或 base64 放进 `text`。
- `textChecksum` 对上述规范化结果的精确 UTF-8 字节计算 SHA-256；`textLength` 与所有 offset 均按规范化字符串的 UTF-16 code unit 计数，与 JavaScript/.NET `string.length` 一致。FileService 若使用 Python/Go 等 Unicode 标量索引实现，必须在边界处显式转换。
- `ownerUserId` 必须是资料真实所有者。`sourceMap` 必须非空、按 `startOffset` 升序、不得重叠或越界；页码若存在须大于 0，段落索引若存在须不小于 0。
- `blocks` 必须非空并按来源区间有序；每个 `source` 必须与 `sourceMap` 中的一项完全相同，`text` 必须与该半开区间的原文逐字相同。解析器无法恢复页码、段落或标题级别时使用 `null`，不得虚构位置。
- FileService 对同一资料、同一 `parserVersion` 的非强制重试必须产生相同文本、`textChecksum` 和来源映射。KnowledgeService 创建构图任务的请求幂等键固定为 `(ownerUserId, Idempotency-Key)`，并校验重复 key 的 `studyProjectId`、`materialId`、切分模式、抽取器版本和学科提示均一致；读取文本后，`studyProjectId` 与 `textChecksum` 都进入持久化图谱指纹，`parserVersion`、`sourceMapVersion` 只作为受校验的来源契约字段，不得误称为创建任务的幂等键。
- 资料尚未 `READY` 时返回 `409 MATERIAL_TEXT_NOT_READY`；最新解析明确失败时返回 `422 MATERIAL_TEXT_EXTRACTION_FAILED`；调用身份不是经 Gateway 注入的受信服务身份时返回 `403 FORBIDDEN`。
- `/internal/v1/materials/{materialId}/extracted-text` 除目标服务 `X-Gateway-Key` 外，还必须要求单值 `X-Service-Name` 命中大小写不敏感的精确 allowlist；当前默认只允许 `KnowledgeService`，FileService 配置项为 `InternalAccess:ExtractedTextAllowedServices`。仅“非空服务名”不构成授权。
- 响应可使用统一 JSON 成功信封；无论传输包装为何，`text` 字段本身只能是上述纯文本。
- KnowledgeService 只经 Gateway 使用本端点或事件中的 `contentRef` 读取文本，不读取 FileService 数据库，也不把 PDF/DOCX 解析逻辑作为正常生产路径。
- `enableOcr=false` 时 FileService 不得调用 OCRService；图片或没有内嵌文本的扫描 PDF 应使任务失败。`enableOcr=true` 只表示允许回退，文本型 PDF 仍优先直接提取，最终是否执行 OCR 以 `ocrUsed` 为准。逐页 `ocrProgress` 查询失败不得覆盖 FileService 自己的任务状态。

当前 standalone MongoDB 不提供跨集合事务，完成态使用可恢复的固定发布顺序：先把完整
文本暂存在仍为 `PROCESSING` 的 Material 文档，再把 IngestionJob 写为
`SUCCEEDED`，最后将 Material 与同一文本一起发布为 `READY`。客户端可能极短暂观察到
`SUCCEEDED + PROCESSING`，但绝不能观察到 `READY` 早于 `SUCCEEDED`，也不能观察到
缺失文本的 `READY`；服务重启时必须从已成功任务和暂存文本完成最后发布，不能重复解析。

本小节的同步 HTTP 数据形状已经作为当前适配基线；其实现、OCR 调度和 `MaterialTextReady v1` 生产仍是 FileService / Gateway 负责的 **URGENT（跨服务义务）**，KnowledgeService 不代为实现。

### 5.3 上传 Mock

```json
{
  "data": {
    "materialId": "3a7f3d0f-1876-4879-8d6d-01a919d5c935",
    "ownerUserId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
    "displayName": "作物栽培学复习资料",
    "originalFileName": "crop-science.pdf",
    "mediaType": "application/pdf",
    "sizeBytes": 1482032,
    "checksum": "8dd9c7e1b91f4bdc184c2c9062ab6a502251ae6a2c4c4fa70cc95b610de60f7f",
    "status": "UPLOADED",
    "latestIngestionJobId": null,
    "createdAt": "2026-07-27T08:20:00Z",
    "updatedAt": "2026-07-27T08:20:00Z"
  },
  "meta": {},
  "traceId": "01JFILE..."
}
```

### 5.4 已决策项与 OWNER-TBD

- [ √ ] 单文件上传上限为 10 MiB，超过返回 `413 FILE_TOO_LARGE`；
- [ √ ] PDF、DOCX、Markdown、HTML 使用专用解析器；TXT，以及未知扩展名且媒体类型为 `text/*` 或 `application/octet-stream` 的输入按 UTF-8 文本兜底；JPG、JPEG、PNG 和无内嵌文字的 PDF 只有显式启用 OCR 才能解析；
- [ ] **URGENT（FileService / OCRService）** 完成 OCR 准确率、资源上限、模型缓存和失败恢复验证；本轮端到端测试不覆盖 OCR 功能；
- [ ] 解析器版本与失败重试策略；
- [ ] 软删除或物理删除；
- [ ] GridFS bucket 和备份策略。

## 6. KnowledgeService

> 负责人：`@Arabidopsis`  
> 拥有：KnowledgeGraph、Chapter、KnowledgePoint、KnowledgeRelation、ReviewPlan、MasteryRecord 和复习结果幂等回执。
> 不拥有：原始文件、游戏包和浏览器运行状态。
> 权威数据库：Neo4j。

### 6.0 边界与 Neo4j 分层模型（BASELINE）

KnowledgeService 只接收 FileService 已规范化的纯文本，先建立章节层级，再在章节内抽取知识点和依赖。`Material` 是来源，不是图谱聚合根；每个图谱版本必须归属于一个 `StudyProject`。同一资料被两本研习册引用时，必须生成两套独立的 graph/chapter/point/mastery 身份，禁止按 `materialId` 复用。首版 Neo4j 逻辑模型固定为：

```text
(:KnowledgeGraph)-[:HAS_CHAPTER]->(:Chapter)
(:Chapter)-[:HAS_CHILD]->(:Chapter)
(:Chapter)-[:HAS_POINT]->(:KnowledgePoint)
(:KnowledgePoint)-[:PREREQUISITE_OF]->(:KnowledgePoint)
(:KnowledgePoint)-[:RELATED_TO|CONTRASTS_WITH]->(:KnowledgePoint)
(:User)-[:MASTERY {score, easinessFactor, intervalDays, repetitions, lapses, nextReviewAt, lastReviewedAt, version}]->(:KnowledgePoint)
(:ReviewPlan)-[:HAS_NODE]->(:ReviewPlanNode)-[:REFERS_TO]->(:KnowledgePoint)
(:ReviewPlanNode)-[:PLAN_EDGE]->(:ReviewPlanNode)
```

- `KnowledgeGraph.studyProjectId` 是所有权作用域，`materialId` 只指向构图来源。图谱版本序列、指纹去重和 `READY -> SUPERSEDED` 均按 `(ownerUserId, studyProjectId)` 隔离；旧图缺少 `studyProjectId` 时只允许按既有 `graphId` 兼容读取，不能绑定给新册。
- `KnowledgeGraph`、`Chapter` 和 `KnowledgePoint` 均属于一个不可变图谱版本；READY 图的内容不得原地改写，唯一允许的生命周期变化是 `READY -> SUPERSEDED` 状态迁移。
- `Chapter` 是上层层级节点，允许父子章节；`KnowledgePoint` 是下层叶级知识节点，并且必须有且只有一个主 `chapterId`。
- `MASTERY` 关系按 `(userId, pointId)` 唯一，不能作为所有用户共享的 `KnowledgePoint` 属性。API 中 `KnowledgePoint.mastery` 是针对当前受信用户投影出的值。
- KnowledgeService 可以保存 `userId` 外键值用于隔离数据，但不得复制用户展示名、邮箱或认证事实。
- UUID、图版本、关系端点、ownerUserId 和 plan snapshot 必须由唯一约束或事务校验保护。服务启动时应幂等建立所需 Neo4j constraints/indexes。

跨服务联调阻塞项（均不由 KnowledgeService 实现）：

- **URGENT（FileService / Gateway）**：持续满足 5.2.1 的规范化纯文本、结构块、所有者信息、服务身份转发和稳定错误码；这些适配属于对应服务，KnowledgeService 只校验和消费。
- **URGENT（GalGameService）**：以精确服务身份按 `reviewPlanId + snapshotVersion` 读取 6.3 的不可变 PlanGraph，把 `questionTarget`/学习目标转成题目和剧情；不得自行重算知识点权重。
- **URGENT（RenderService）**：以精确服务身份按 6.4 提交 `ReviewCompleted v2`/INTERNAL evidence，保留 `resultId`、`idempotencyKey`、`completedAt` 和逐知识点证据；否则 KnowledgeService 不得猜测掌握度。GalGameService 不能代替运行时提交用户作答证据。
- **URGENT（Gateway）**：按 9.2 剥离外部伪造的身份头、完成令牌或服务身份认证，并按目标服务密钥重新注入可信 Header；KnowledgeService 只消费该内部信任边界。

### 6.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/knowledge-graph-builds` | 创建图谱构建任务 | `GraphBuildRequest` | `GraphBuildJob` | `202/400/409/422` |
| `GET` | `/api/v1/knowledge-graph-builds/{buildId}` | 查询构建任务 | - | `GraphBuildJob` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs?studyProjectId=...` | 查询研习册的图谱版本 | Query | `KnowledgeGraphPage` | `200/400` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}` | 读取图谱摘要 | - | `KnowledgeGraphSummary` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/chapters` | 读取有序章节树 | - | `Chapter[]` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/points` | 分页读取知识点 | Query | `KnowledgePointPage` | `200/400/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/relations` | 分页读取关系 | Query | `KnowledgeRelationPage` | `200/400/404` |
| `GET` | `/api/v1/knowledge-points/{pointId}` | 读取知识点详情 | - | `KnowledgePoint` | `200/404` |
| `POST` | `/api/v1/assessment-plans` | 生成少题量、依赖感知的全面测试图 | `CreateAssessmentPlanRequest` | `PlanGraph` | `201/400/404/422` |
| `POST` | `/api/v1/learning-plans` | 按上游指定章节生成加权学习图 | `CreateLearningPlanRequest` | `PlanGraph` | `201/400/404/422` |
| `GET` | `/api/v1/review-plans/{reviewPlanId}` | 当前用户读取计划摘要与图 | - | `PlanGraph` | `200/404` |
| `GET` | `/internal/v1/review-plans/{reviewPlanId}/graph` | 仅 GalGameService 读取不可变计划图 | `snapshotVersion` Query | `PlanGraph` | `200/400/403/404/409` |
| `PUT` | `/internal/v1/review-evidence/{resultId}` | 仅 RenderService 幂等提交学习证据并更新掌握度 | `ReviewEvidenceSubmission` | `MasteryUpdateReceipt` | `200/400/403/404/409/422` |
| `GET` | `/api/v1/mastery-records` | 查询当前用户掌握度 | `MasteryListQuery` | `MasteryPage` | `200/400` |
| `GET` | `/internal/v1/knowledge-graphs/{graphId}/scope` | 仅 PracticeService 核验图谱归属 | `ownerUserId` Query | `graphId, materialId, studyProjectId, ownerUserId` | `200/403/404` |
| `GET` | `/internal/v1/practice-projects/{projectId}/graph-scope` | 仅 KnowledgeService 核验项目与资料成员关系 | `ownerUserId, materialId` Query | `studyProjectId, ownerUserId, materialIds` | `200/403/404/409` |

`PATCH /api/v1/knowledge-points/{pointId}` 人工修正属于 **P1（KnowledgeService，
未实现、未映射、未测试）**，不属于上表当前可执行接口。未来实现前必须冻结
`KnowledgePointPatch` 的可改字段、DRAFT-only 约束、`expectedUpdatedAt` 并发语义和
`200/404/409` 状态，再补契约测试；当前客户端不得调用。

所有 `/api/v1` 与 `/internal/v1` 入口都必须先验证 Gateway 为 KnowledgeService 注入的唯一 `X-Gateway-Key`；`/`、`/healthz` 和 `/readyz` 是仅有的运维例外。用户资源随后以 Gateway 注入的可信 `X-User-Id` 做 owner 校验，INTERNAL 路由随后读取受信 `X-Service-Name`；调用方 JSON 字段或浏览器自造 Header 不得覆盖可信身份。

KnowledgeService 构图时以任务中的 `ownerUserId` 调用 `IMaterialTextClient`，并对 FileService 响应执行以下边界校验：

- `materialId` 必须与请求一致，`ownerUserId` 缺失或为空视为 `502 MATERIAL_TEXT_CONTRACT_INVALID`，与构图用户不一致视为 `403 MATERIAL_ACCESS_DENIED`；
- 文本必须声明 `READY`、UTF-8、NFC、LF，不含 CR、BOM 或 NUL；`textChecksum` 必须等于规范化文本 UTF-8 字节的 SHA-256，`textLength` 必须等于 UTF-16 code unit 数量；
- `sourceMapVersion` 只能为 `"1"`；`sourceMap` 和 `blocks` 均须非空、区间有序且不重叠，范围在文本内，页码为正数、段落索引非负；块级别若存在须在 1-6，块文本须与原文区间逐字一致，块来源须在 `sourceMap` 中；
- 提取器给出的知识点 offset 与来源区间重叠时，`SourceRef.location` 依次采用 `sourceLabel`、页码、段落；没有这些标签时才按块类型投影“标题/列表项/表格/代码块/引用/段落”。机器定位始终使用 offset，展示位置不参与幂等；
- FileService 的 `404/409/422` 分别映射为资料不存在、文本未就绪、提取失败；响应契约损坏为 `502`，超时或不可达为 `503 FILE_SERVICE_UNAVAILABLE`。

KnowledgeService 读取文本时只向 Gateway 发送 `X-Service-Name: KnowledgeService`、对应的 `X-Service-Key` 和原链路 `X-Correlation-Id`，不直连 FileService。它不调用 OCRService，也不读取 `DSAPI` 或 `BitchSDAU`；确定性章节切分、规则抽取和 Neo4j 写入不依赖任何大模型密钥。

### 6.2 图谱构建与分层数据类型

```ts
type ChapterSegmentationMode =
  | "AUTO"
  | "HEADING_RULES"
  | "MARKDOWN"
  | "DELIMITER"
  | "FIXED_WINDOW";

interface MasteryListQuery {
  graphId: Uuid;          // required
  cursor?: Cursor;
  limit?: number;         // 1-100，默认 50
}

interface GraphBuildRequest {
  materialId: Uuid;
  studyProjectId: Uuid;                    // 必填；图谱所有权作用域
  subjectHint?: SubjectCode;
  segmentationMode?: ChapterSegmentationMode; // 默认 AUTO
  delimiter?: string;                          // DELIMITER 模式必填
  minChapterCharacters?: number;               // 20-20000，默认 120
  maxChapterCharacters?: number;               // 500-500000，默认 60000，且不小于 min
  fixedWindowCharacters?: number;              // 500-100000，默认 8000
  extractorVersion?: string;                   // 默认 knowledge-extractor-v2
}

type JobStatus = "QUEUED" | "RUNNING" | "SUCCEEDED" | "FAILED";

interface GraphBuildJob {
  buildId: Uuid;
  materialId: Uuid;
  studyProjectId: Uuid;
  status: JobStatus;
  progress: number; // int32, 0-100
  graphId: Uuid | null;
  sourceTextChecksum: Sha256 | null;
  segmentationMode: ChapterSegmentationMode;
  segmenterVersion: string;
  extractorVersion: string;
  error: ApiError | null;
  createdAt: DateTime;
  updatedAt: DateTime;
}

type KnowledgeGraphStatus = "DRAFT" | "READY" | "SUPERSEDED";

interface KnowledgeGraphSummary {
  graphId: Uuid;
  materialId: Uuid;
  studyProjectId: Uuid | null; // null 只表示升级前的兼容图谱
  version: number; // int32，在研习册内单调递增
  subjectCode: SubjectCode;
  chapterCount: number;
  pointCount: number;
  relationCount: number;
  status: KnowledgeGraphStatus;
  textChecksum: Sha256;
  createdAt: DateTime;
}

interface SourceRef {
  materialId: Uuid;
  startOffset: number;          // int64；与 ExtractedTextDocument 相同的 UTF-16 code unit offset
  endOffset: number;            // int64；半开区间 [startOffset, endOffset)
  location: string;             // 给人阅读的页码/段落说明，不作为机器定位依据
  quote: string | null;         // 最多 240 字符的短摘录
}

interface Chapter {
  chapterId: Uuid;
  graphId: Uuid;
  parentChapterId: Uuid | null;
  title: string;                // 1-160 字符
  ordinal: number;              // int32，同一 parent 下从 0 开始且唯一
  depth: number;                // int32，根章节为 0，首版最大 6
  startOffset: number;
  endOffset: number;
  segmentationMode: ChapterSegmentationMode;
}

interface KnowledgePoint {
  pointId: Uuid;
  graphId: Uuid;
  chapterId: Uuid;
  conceptKey: string;           // 同一 material 的概念谱系键；图内唯一，跨版本可稳定复用
  title: string;            // 1-120 字符
  summary: string;
  subjectCode: SubjectCode;
  tags: string[];
  confidence: number;       // 0-1
  sourceReferences: SourceRef[]; // 至少一个
  mastery: MasteryRecord;   // 当前用户投影；没有持久化状态时仍返回初始值
  createdAt: DateTime;
  updatedAt: DateTime;
}

interface KnowledgePointPatch {
  title?: string;
  summary?: string;
  chapterId?: Uuid;
  subjectCode?: SubjectCode;
  tags?: string[];
  expectedUpdatedAt: DateTime;
}

type RelationType = "PREREQUISITE" | "RELATED" | "CONTRASTS";

interface KnowledgeRelation {
  relationId: Uuid;
  graphId: Uuid;
  fromPointId: Uuid;
  toPointId: Uuid;
  type: RelationType;
  confidence: number; // 0-1
  rationale: string;
}
```

构建与关系语义：

- `AUTO` 先识别中文“第 X 章/节”、绪论、阿拉伯/罗马数字编号和强标题；显式结构不足时降级为句子/段落边界感知的固定窗口。`chapter-segmenter-v2` 还处理 PDF 提取器把整页保留为一行的情况，但只有“第 X 章标题后紧随题型栏”这一强结构成立时才建立内联章节；题型中的知识点只接受每栏从 `1.` 开始连续递增的顶层题号，不把页码、答案内 `(1)` 子项或普通数字当作知识点。`HEADING_RULES`、`MARKDOWN`、`DELIMITER` 可由调用方显式选择；`FIXED_WINDOW` 是确定性兜底。该多模式路由只借鉴 ReciteHelper 的“结构化/非结构化资料采用不同分支”思路，未复制其 AGPL-3.0 代码。
- 章节必须先于知识点生成。空标题忽略；重复标题通过父章节和 ordinal 区分；过长章节可产生子章节；不得为了窗口长度把一个段落切成两个来源不明的章节。
- `conceptKey` 在单个图版本内唯一；同一 `materialId` 的后续图版本识别为同一概念时稳定复用。它只用于版本对照和审计；首版不据此继承 mastery。
- 当 `type="PREREQUISITE"` 时，`fromPointId` 是基础/前置知识点，`toPointId` 是依赖它的上层知识点，即 Neo4j 中 `(from)-[:PREREQUISITE_OF]->(to)`；API 领域类型仍为 `PREREQUISITE`。
- 确定性规则抽取器只在“较早知识点标题词项被较晚知识点标题或摘要逐字提及”时提出前置边。设除候选知识点自身外共有 `N` 个文本块，其中 `df` 个提及该词项，则 `confidence = 1-(df+1)/(N+2)`；这是 Beta(1,1) 拉普拉斯平滑后的**词项特异度证据**，不是未经标注数据校准的“依赖正确概率”。标题/摘要位置、是否同章和词长不再通过任意系数混入。高频泛化词另由固定停用表排除，候选并列时按 ordinal、pointId 稳定排序，每个知识点最多保留 4 个规则候选；未来只有在独立标注集上完成校准并提升 extractorVersion 后，才可把模型概率写入该字段。
- PREREQUISITE 子图必须为有向无环图。抽取后若出现强连通分量，构建器按最低 confidence、再按 relationId 稳定排序移除最弱边并将其降级为 `RELATED`，直到 DAG 成立。
- `RELATED` 和 `CONTRASTS` 在领域语义上无方向；持久化时按 pointId 字典序采用唯一方向，API 不允许同一无向点对重复。
- 创建任务使用 `(ownerUserId, Idempotency-Key)` 做请求幂等；`Idempotency-Key` 必须是非空 UUID D 格式，并按小写连字符形式存储。同一 key 携带不同 `materialId`、`subjectHint`、切分参数或抽取器版本时返回 `409 IDEMPOTENCY_KEY_REUSED`。图谱内容另以 `ownerUserId`、`materialId`、`sourceTextChecksum`、segmenter/extractor version、最终 `subjectCode`、实际切分模式，以及请求的 `segmentationMode`、`delimiter`、`minChapterCharacters`、`maxChapterCharacters`、`fixedWindowCharacters` 的长度前缀规范序列计算 SHA-256 指纹；任一语义输入变化都不得错误复用旧图，相同指纹则返回既有 graph 而不创建重复版本。

### 6.3 测试计划、学习计划与 PlanGraph

```ts
type ReviewPlanType = "ASSESSMENT" | "LEARNING";
type PlanNodeRole = "TARGET" | "PREREQUISITE" | "CONTEXT";

interface CreateAssessmentPlanRequest {
  graphId: Uuid;
  chapterIds?: Uuid[];          // 0-100；省略或空数组表示全图全面测试
  maxQuestions?: number;        // int32，1-50，默认 12
  coverageTarget?: number;      // 0.25-1，默认 0.8；在题量上限内尽量达到
  maximumInferenceDepth?: number; // int32，0-8，默认 3
}

interface CreateLearningPlanRequest {
  graphId: Uuid;
  chapterIds: Uuid[];           // 1-100，由上游明确指定需要复习的章节
  maxPoints?: number;           // int32，1-50，默认 20
  maximumDependencyDepth?: number; // int32，0-8，默认 5
}

interface PlanGraph {
  schemaVersion: "1.0";
  reviewPlanId: Uuid;
  type: ReviewPlanType;
  status: "OPEN" | "COMPLETED" | "EXPIRED";
  graphId: Uuid;
  graphVersion: number;
  ownerUserId: Uuid;
  selectedChapterIds: Uuid[];
  snapshotVersion: string;      // 对不可变计划字段的规范化白名单计算；不含生命周期 status
  algorithmVersion: string;     // assessment-planner-v1 或 learning-planner-v1
  nodes: PlanNode[];
  edges: PlanEdge[];
  rootPointIds: Uuid[];         // ASSESSMENT 为直接出题点；LEARNING 为首要学习目标
  estimatedQuestionCount: number;
  estimatedCoverage: number;    // 0-1
  totalWeight: number;          // 固定为 1；空图不允许创建
  createdAt: DateTime;
  expiresAt: DateTime;
}

interface PlanNode {
  pointId: Uuid;
  chapterId: Uuid;
  title: string;
  summary: string;
  tags: string[];
  masteryScore: number;         // 创建计划时的 0-100 快照
  role: PlanNodeRole;
  weight: number;               // 0-1；所有节点合计为 1
  selectionReason: string;
  dependencyDepth: number;
  questionTarget: boolean;
  outsideRequestedChapters: boolean;
  coversPointIds: Uuid[];
  supportsPointIds: Uuid[];
}

interface PlanEdge {
  fromPointId: Uuid;
  toPointId: Uuid;
  type: RelationType;
  confidence: number;
  influenceWeight: number;      // 0-1，本条边的 confidence / 目标直接前置数量
}
```

PlanGraph 规则：

- 创建后，章节、节点、边、权重、覆盖率、算法版本、owner、创建/过期时间等快照字段不可变；`status` 是唯一不进入 snapshot 的生命周期字段，可由 `OPEN` 单向变为 `COMPLETED` 或 `EXPIRED`。相同 `reviewPlanId + snapshotVersion` 必须始终返回等价的不可变图内容，但调用前后 status 可发生上述单向变化。调用 INTERNAL 读取接口时，query 中的 `snapshotVersion` 不匹配返回 `409 SNAPSHOT_VERSION_CONFLICT`。
- ASSESSMENT 使用 6.6 的单调次模覆盖目标选择少量 `questionTarget`。同一知识点被多道题覆盖时只保留最大覆盖置信度，边际收益自然递减，不再叠加一套不可校准的“章节/标签/结构混合惩罚”。达到 `maxQuestions` 后停止，即使 `coverageTarget` 未完全达到，并在 `estimatedCoverage` 如实返回。
- LEARNING 只把请求 `chapterIds` 内的知识点作为主要目标；前置知识点必须连同到目标的完整最大乘积路径作为 path bundle 加入，禁止返回断开的“依赖点”。章节外前置节点数量最多为 `floor(maxPoints*0.30)`，其总权重最多为 30%。
- GalGameService 负责把 `questionTarget` 转换为具体题目或剧情；KnowledgeService 只选择目标、依赖路径和权重，不生成或持久化游戏包。

### 6.4 掌握度、SM-2 调度与结果幂等

```ts
interface MasteryRecord {
  userId: Uuid;
  pointId: Uuid;
  score: number; // 0-100
  reason: string;
  repetitions: number;         // int32
  easinessFactor: number;      // 初始 2.5，下限 1.3
  intervalDays: number;        // int32
  nextReviewAt: DateTime;
  lastReviewedAt: DateTime | null;
  lapses: number;              // int32
  version: number;             // int64，乐观并发版本
}

type AnswerKind =
  | "CHOICE"
  | "FILL_BLANK"
  | "TRUE_FALSE"
  | "SHORT_ANSWER"
  | "OTHER";

interface KnowledgeAnswerEvidence {
  attemptId: Uuid;
  questionId: Uuid;
  knowledgePointId: Uuid;
  answerKind: AnswerKind;
  correct: boolean;
  quality: number;             // int32，0-5；定义见下方固定映射
  responseTimeMs: number;      // int64，0-86400000
  hintsUsed: number;           // int32，0-100
  attemptNumber: number;       // int32，1-100
  occurredAt: DateTime;         // 不得晚于 completedAt + 5 分钟
}

interface ReviewEvidenceSubmission {
  resultId: Uuid;              // 必须与路由参数一致
  idempotencyKey: Uuid;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  sessionId: Uuid;
  packageId: Uuid;
  userId: Uuid;
  completedAt: DateTime;
  durationSeconds: number;     // int32，0-86400
  answerResults: KnowledgeAnswerEvidence[]; // 1-100 项
}

type MasteryUpdateStatus = "ACCEPTED" | "DUPLICATE";

interface MasteryUpdateReceipt {
  resultId: Uuid;
  reviewPlanId: Uuid;
  status: MasteryUpdateStatus;
  updatedPointIds: Uuid[];
  changes: AppliedMasteryChange[];
  ignoredEvidenceCount: number;
  algorithmVersion: "sm2-graph-v2";
  processedAt: DateTime;
}

interface AppliedMasteryChange {
  pointId: Uuid;
  previousScore: number;
  newScore: number;
  directEvidence: boolean;
  reason: string;
}
```

所有 API 枚举都只接受上表给出的 JSON 字符串 token；整数 token（包括 `0` 和未定义整数）
返回 `400 VALIDATION_ERROR`。`ReviewEvidenceSubmission` 及每个
`KnowledgeAnswerEvidence` 列出的字段全部 required：字段缺失或为 null 返回
`400 REVIEW_EVIDENCE_INVALID`；required 字段均存在后，时长、耗时、提示次数、尝试次数
或时间关系越界返回 `422 REVIEW_EVIDENCE_INVALID`。INTERNAL PlanGraph 的
`snapshotVersion` Query 为 required，缺失返回 `400 VALIDATION_ERROR`。

新图版本及首次读取的默认 mastery 固定为：

```text
score=0, repetitions=0, easinessFactor=2.5, intervalDays=0,
nextReviewAt=KnowledgeGraph.createdAt, lastReviewedAt=null, lapses=0,
reason="INITIAL", version=0
```

即使新版本中的 `conceptKey` 与旧版本相同，也必须从 0 开始；首版禁止静默继承或合并旧图 mastery。
图谱进入 READY 的同一事务必须为 `ownerUserId` 的每个知识点建立上述初始 `MASTERY` 关系；读取时若因修复或历史数据缺少状态，仍按同一默认值投影，禁止返回 `null`，持久化补建由独立修复任务完成。

`sm2-graph-v2` 对直接作答知识点执行：

```text
observedScore = quality / 5 * 100
score' = observedScore

easinessFactor' =
  max(1.3, easinessFactor + 0.1 - (5-quality) * (0.08 + (5-quality) * 0.02))

quality < 3:
  repetitions'=0, intervalDays'=1, lapses'=lapses+1
quality >= 3 and repetitions=0:
  repetitions'=1, intervalDays'=1
quality >= 3 and repetitions=1:
  repetitions'=2, intervalDays'=6
quality >= 3 and repetitions>=2:
  repetitions'=repetitions+1,
  intervalDays'=min(3650, max(1, round(intervalDays * easinessFactor')))

nextReviewAt = completedAt + intervalDays'
```

`score` 只是供界面解释“最近一次直接作答质量”的投影，不再承担第二套记忆模型；纵向调度状态只有
SM-2 的 `repetitions/easinessFactor/intervalDays/nextReviewAt/lapses`。禁止把旧分与本次分按
`65/35`、`60/40` 或其他未经标注集校准的学习率平滑。SM-2 间隔与 easiness 公式沿用
[Wozniak 的原始 SM-2 说明](https://super-memory.org/archive/english/ol/sm2.htm)。

质量映射固定为：完全错误 `0`；错误但有有效部分证据 `1-2`；正确但使用提示、重试或明显不流畅 `3`；首次正确但较慢 `4`；首次正确且无提示、流畅完成 `5`。KnowledgeService 校验 `correct=false` 时 `quality` 不得高于 2、`correct=true` 时不得低于 3；`scoreDelta` 属于游戏计分，不参与 mastery。

证据边界规则：

- 每条直接作答只更新其明确绑定的 `knowledgePointId`，并只对该点推进 SM-2 调度。
- 知识图谱的前置关系只参与第 6.6 节的复习目标检索与覆盖，不把“答对上层点”转换为前置点掌握分，也不把“答对基础点”转换为上层点掌握分。
- 正确、错误、使用提示与否都不得批量更新未作答知识点；否则任何推断增量或衰减上限都会成为未经真实作答校准的第二套掌握模型。
- 若直接作答点已有晚于本次 `completedAt` 的记录，则整次提交按 `409 STALE_REVIEW_EVIDENCE` 拒绝。

结果幂等规则：

- `resultId` 和 `idempotencyKey` 均建立唯一约束。完全相同的重复请求返回不含新 changes 的 `MasteryUpdateReceipt`，状态为 `DUPLICATE`，不得二次更新 mastery。HTTP JSON 的可解析性、字段形状/范围以及目标 plan 的存在性先于 checksum；形成规范化 submission 后，在 plan-open、snapshot、作答范围和 mastery 状态校验前做只读幂等预检，事务内唯一约束再处理并发竞态。规范化 checksum 覆盖 result、plan、session、package、用户、snapshot、总时长、完成时间以及每条答案的 question、answerKind、毫秒耗时、提示次数、attemptNumber 和 occurredAt；只对答案数组顺序与等价 UTC 时区表示归一化。
- 相同 `resultId` 或 `idempotencyKey` 携带不同规范化 payload checksum 时返回 `409 IDEMPOTENCY_CONFLICT`。
- `reviewPlanId` 不存在返回 `404 REVIEW_PLAN_NOT_FOUND`；`userId` 不一致返回 `422 REVIEW_EVIDENCE_USER_MISMATCH`；`snapshotVersion` 不一致返回 `409 SNAPSHOT_VERSION_CONFLICT`；`knowledgePointId` 不在计划可作答范围返回 `422 ANSWER_POINT_NOT_IN_PLAN`。KnowledgeService 校验 `questionId` 非空并纳入幂等审计，但 GalGameService 生成的 `questionId -> knowledgePointId` 映射不在 PlanGraph 中，映射真实性由 GalGameService/RenderService 的 **URGENT** 包校验与可信服务身份负责；KnowledgeService 不虚构自己无法完成的绑定校验。
- SM-2 的时间基准只使用已校验的 `completedAt`：它必须落在计划有效期内，最多允许 5 分钟时钟偏差；若该点已有更晚的直接复习记录，返回 `409 STALE_REVIEW_EVIDENCE`，不得倒序覆盖。
- `hintsUsed>0` 时 `quality` 不得高于 3；不一致证据返回 `422 REVIEW_EVIDENCE_INVALID`，不得静默把 4/5 降为 3。
- 当前可执行基线只接入 `PUT /internal/v1/review-evidence/{resultId}`，并由该入口进入 `SubmitReviewResultCommand` 与幂等存储。团队冻结消息总线、consumer group、重试/DLQ 和服务身份后，`ReviewCompleted v2` 适配器必须调用同一命令，禁止复制 mastery 逻辑；该事件接入属于 **URGENT（平台/RenderService 跨服务阻塞项）**，当前不得声称已经订阅。

### 6.5 分页响应

```ts
interface KnowledgeGraphPage {
  items: KnowledgeGraphSummary[];
  nextCursor: Cursor | null;
}

interface KnowledgePointPage {
  items: KnowledgePoint[];
  nextCursor: Cursor | null;
}

interface KnowledgeRelationPage {
  items: KnowledgeRelation[];
  nextCursor: Cursor | null;
}

interface MasteryPage {
  items: MasteryRecord[];
  nextCursor: Cursor | null;
}
```

### 6.6 可证明的计划目标、权重投影与 hub 防爆炸规则（BASELINE）

算法版本固定为 `assessment-planner-v1`、`learning-planner-v1` 和公共权重核 `graph-weight-v1`。首版禁止把“个人薄弱、到期程度、中心性、标签多样性”等异质量任意线性混合。所有计划只使用以下同一套可解释量。

SM-2 到期需要：

```text
lastReviewedAt=null or repetitions=0 or now>=nextReviewAt(v):
  need(v)=1
otherwise:
  need(v)=0
```

这是对 SM-2 日程的直接投影，不假设额外遗忘曲线、目标保持率或混合系数。若当前作用域没有到期点，
ASSESSMENT 仍按稳定顺序返回一个探测题，而不能伪造非零风险。下文统一使用 `need`。

依赖影响使用最大乘积半环。对前置边 `a -> b`：

```text
edgeInfluence(a,b) =
  confidence(a,b) / max(1, directPrerequisiteCount(b))

influence(v,t) =
  1                                      if v=t
  max over paths v -> ... -> t
    product(edgeInfluence on the path)  otherwise
```

只保留每个 `(node, depth)` 状态的最优值，最大深度由请求参数限制，因此 diamond/层状 DAG 不枚举指数数量的路径。低置信度一跳捷径不会自动压过更可靠的多跳路径。

ASSESSMENT 的候选题集合为 `S`，覆盖宇宙为目标知识点及其有限深度前置闭包：

```text
F(S) = Σ_v need(v) * max_{q in S} influence(v,q)
```

`F` 是归一化、单调、次模函数。在题目成本相同且执行固定 `k` 轮时，按真实边际收益贪心相对最优 `k` 题集合具有经典 `1-1/e` 近似保证；依据为
[Nemhauser、Wolsey 与 Fisher 的基数约束次模最大化结果](https://pubsonline.informs.org/doi/abs/10.1287/moor.3.3.177)。若达到 `coverageTarget` 后提前停止，这一保证只相对实际已选题数的最优集合成立，不能冒充相对原 `maxQuestions` 预算最优解的保证。`max` 使重复题及共享前置点自然产生递减收益；同一 hub 无论连接多少候选，在每个被覆盖知识点上都不会被重复求和。

LEARNING 对请求章节目标集合 `T` 定义唯一的原始优先级：

```text
priority(v) = max_{t in T} need(t) * influence(v,t)
```

因此 `0 <= priority(v) <= 1`，并且给 hub 新增更多上游目标只能改变 `max` 的取值，不能按出度线性放大。完整 path bundle 只有在整条路径同时满足 `maxPoints` 与外部节点数量约束时才可加入；选择过程使用下述独立覆盖目标，而 `priority(v)` 只作为入选节点的最终权重先验。这里不声称该带路径闭包问题的贪心达到全局最优，只保证以下可机械验证的不变量：节点上限、外部节点数量上限、每个外部节点到至少一个已选目标有有向路径、相同输入稳定输出。

为避免把“选哪些路径”和“最终节点权重”混成一个量，path bundle 选择另用覆盖函数。对通向目标 `t_b` 的完整路径束 `b`：

```text
g_b(v) =
  need(t_b) * influence(v,t_b)  if v is on b
  0                             otherwise

G(B) = Σ_v max_{b in B} g_b(v)
```

每轮按 `G` 的真实边际收益除以新增节点数选择可行 bundle；不新增节点但能补充覆盖的 bundle 视为零成本候选并按稳定顺序处理。`G` 对 bundle 集合单调且次模，共享节点的贡献只取最大值；但由于成本是已选节点并集的动态大小，同时还有路径闭包和外部节点约束，本版不声明标准基数贪心近似比。bundle 选定后，最终展示权重仍只使用前述全局固定 `priority(v)`，不使用选择过程中的累计覆盖状态。

对入选节点先令 `q(v)=priority(v)/Σpriority`。最终权重不是再次混合，而是下列约束集合上的 KL/I-projection：

```text
min_w KL(w || q)
subject to:
  Σ_v w(v)=1
  w(v)>=0
  Σ_{v outside requested chapters} w(v)<=0.30
  w(v)<=0.25
```

- 先在全体节点上做仅含单点上限的 capped KL 投影；若所得外部总量不超过 30%，它就是联合最优解。只有外部约束被违反时，该约束才在最优解处取等号，此时把内外总量固定为 70%/30%，再分别做 capped KL 投影。禁止先夹住原始外部占比再分组投影：单点 cap 会改变最优组质量，该做法只能保证可行，不能保证 KL 最优。
- 仅当节点数量使 25% 单点上限在数学上不可行时，才把单点上限确定性放宽到最小可行值；30% 外部组上限不放宽。全组 `priority=0` 时使用该约束下的均匀极限分布。
- 为使含零优先度的投影有有限数值支持，实现只给**恰为零**的先验项加入自适应支持量 `ε0=min(1e-12, minPositive/(2*nodeCount))`；所有正先验保持原比例。若已处于最小 subnormal 量级而 `ε0` 下溢为 0，则使用 `ε→0+` 的极限 water-filling。该数值支持不代表新的业务特征，且不得把较小正先验提升到较大正先验之上。
- 所有浮点总和按稳定 `pointId` 顺序使用补偿求和；water-filling 先计算 `prior/priorTotal` 再乘剩余质量，避免 subnormal 先乘后除而下溢。相同 pointId 到先验值的映射不得因字典插入顺序不同而改变结果。
- 稳定 `pointId` 负责同分与浮点残差归属；权重保留 6 位小数且总和严格为 1。
- 单个/孤立知识点以 `influence(v,v)=1` 正常工作，不依赖 centrality。
- 当候选范围内所有 `risk=0` 时，ASSESSMENT 仍按稳定顺序返回一个低成本探针，LEARNING 返回一个目标；这是零目标函数下的确定性可用性兜底，不引入新的混合分数。

### 6.7 图谱与 PlanGraph Mock

```json
{
  "data": {
    "graphId": "b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0",
    "materialId": "3a7f3d0f-1876-4879-8d6d-01a919d5c935",
    "version": 1,
    "subjectCode": "AGRONOMY",
    "chapterCount": 6,
    "pointCount": 18,
    "relationCount": 27,
    "status": "READY",
    "textChecksum": "da41f4c6f84f6067d62bf87b7bbaf6f4661ad665c9c643c8be2d3c198f0f2d31",
    "createdAt": "2026-07-27T08:45:00Z"
  },
  "meta": {},
  "traceId": "01JKNOW..."
}
```

```json
{
  "data": {
    "schemaVersion": "1.0",
    "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
    "type": "LEARNING",
    "status": "OPEN",
    "graphId": "b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0",
    "graphVersion": 1,
    "ownerUserId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
    "selectedChapterIds": ["7623c5ae-f377-4247-aaf5-bf73378e74ef"],
    "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
    "algorithmVersion": "learning-planner-v1",
    "nodes": [
      {
        "pointId": "84f7d873-e573-4689-b18d-6f82c745d1bf",
        "chapterId": "7623c5ae-f377-4247-aaf5-bf73378e74ef",
        "title": "作物群体与个体关系",
        "summary": "群体数量与单株生长之间存在资源竞争和补偿关系。",
        "tags": ["群体结构", "基础"],
        "masteryScore": 0,
        "role": "PREREQUISITE",
        "weight": 0.5,
        "selectionReason": "MAX_PRODUCT_PREREQUISITE_PATH",
        "dependencyDepth": 1,
        "questionTarget": false,
        "outsideRequestedChapters": false,
        "coversPointIds": [
          "84f7d873-e573-4689-b18d-6f82c745d1bf",
          "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
        ],
        "supportsPointIds": [
          "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
        ]
      },
      {
        "pointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
        "chapterId": "7623c5ae-f377-4247-aaf5-bf73378e74ef",
        "title": "水稻分蘖期管理目标",
        "summary": "协调群体数量与个体生长，形成合理群体结构。",
        "tags": ["水稻", "分蘖期"],
        "masteryScore": 0,
        "role": "TARGET",
        "weight": 0.5,
        "selectionReason": "REQUESTED_CHAPTER_FORGETTING_RISK",
        "dependencyDepth": 0,
        "questionTarget": true,
        "outsideRequestedChapters": false,
        "coversPointIds": [
          "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
        ],
        "supportsPointIds": [
          "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
        ]
      }
    ],
    "edges": [
      {
        "fromPointId": "84f7d873-e573-4689-b18d-6f82c745d1bf",
        "toPointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
        "type": "PREREQUISITE",
        "confidence": 0.91,
        "influenceWeight": 0.91
      }
    ],
    "rootPointIds": ["d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"],
    "estimatedQuestionCount": 1,
    "estimatedCoverage": 0.82,
    "totalWeight": 1,
    "createdAt": "2026-07-27T08:50:00Z",
    "expiresAt": "2026-08-03T08:50:00Z"
  },
  "meta": {},
  "traceId": "01JPLAN..."
}
```

### 6.8 已决策项与算法版本（BASELINE）

- `SubjectCode` 首版不是封闭枚举。服务在输入边界执行 `Trim()` 和 invariant 大写规范化，规范化结果必须匹配 `^[A-Z][A-Z0-9_]{0,31}$`；连字符不合法，无法可靠分类时使用 `GENERAL`。所有响应与持久化值均为规范化结果。真实样例允许的首批值至少包括 `GENERAL`、`AGRONOMY` 和 `BOTANY`。
- API 关系类型固定为 `PREREQUISITE`、`RELATED`、`CONTRASTS`；Neo4j 物理关系分别为 `PREREQUISITE_OF`、`RELATED_TO`、`CONTRASTS_WITH`，章节归属使用 `Chapter-[:HAS_POINT]->KnowledgePoint`。
- 长度上限：Chapter title 160、KnowledgePoint title 120、summary 4000、tags 最多 20 个且每个 1-40、SourceRef quote 240。超限抽取结果必须拒绝或确定性截断并记录 warning。
- 当前 `knowledge-extractor-v2` 为确定性规则抽取器，只接收已切分章节文本，并增加内联题库条目读取与通用版权页眉清理。未来若接入外部模型，也只能传当前章节、必要父标题和有限相邻上下文，不得发送其他用户资料；输出必须通过结构化 schema、offset、pointId 唯一性和 DAG 校验后才能入库。
- 当前算法版本冻结为：`chapter-segmenter-v2`、`knowledge-extractor-v2`、`graph-weight-v1`、`assessment-planner-v1`、`learning-planner-v1`、`sm2-graph-v2`、`PlanGraph schema 1.0`。
- READY 图内容不可变。P1 的 `PATCH /knowledge-points/{pointId}` 只允许修改 DRAFT 图并依赖 `expectedUpdatedAt` 乐观并发；READY/SUPERSEDED 图返回 `409 GRAPH_IMMUTABLE`，修正需构建新版本。READY 仅可在新版本就绪后把生命周期状态迁移为 SUPERSEDED。
- 所有知识点必须至少有一个可回到 `ExtractedTextDocument` offset 的 `SourceRef`；章节自身保存规范化文本的半开 offset 区间。来源不完整时构建失败，不以模型幻觉补齐。
- 新图版本不得覆盖旧版本，且 mastery 固定从 0 开始。游戏包使用的内容严格以 `PlanGraph.snapshotVersion` 为边界。

## 7. GalGameService

> 负责人：`@F15EX`  
> 拥有：GameGenerationJob、GamePackage、剧情结构和 generatorVersion。  
> 不拥有：浏览器运行时、复习会话和掌握度更新。

### 7.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/game-generations` | 读取并校验 PlanGraph 后创建游戏包生成任务 | `GameGenerationRequest` | `GameGenerationJob` | `202/400/401/422/502/503` |
| `GET` | `/api/v1/game-generations/{generationId}` | 查询生成任务 | - | `GameGenerationJob` | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}` | 读取游戏包清单 | - | `GamePackageManifest` | `200/400/401/404` |
| `GET` | `/api/v1/game-packages/{packageId}/content` | 下载完整 JSON 游戏包 | `If-None-Match?` | JSON | `200/304/400/401/404` |
| `POST` | `/internal/v1/game-package-validations` | 由受信服务校验游戏包 | `GamePackageValidationRequest` | `ValidationResult` | `200/400/403/422` |
| `GET` | `/internal/v1/game-packages/{packageId}?ownerUserId=...` | 仅 RenderService 按会话用户读取权威游戏包 | Query | `GamePackage` | `200/400/403/404` |

`POST /api/v1/game-generations` 在返回 `202` 前同步经 Gateway 读取并校验 PlanGraph。计划
不存在或不属于当前用户返回 `422 REVIEW_PLAN_NOT_FOUND`，快照不一致返回
`422 REVIEW_PLAN_SNAPSHOT_MISMATCH`，KnowledgeService 返回违反契约的数据时返回
`502 UPSTREAM_CONTRACT_INVALID`，依赖不可用时返回 `503 SERVICE_UNAVAILABLE`。任务接受后
按 `QUEUED -> RUNNING -> SUCCEEDED | FAILED` 迁移；异步生成失败记录在
`GameGenerationJob.error`，不把已接受任务改写成另一个 HTTP 响应。

游戏包内容端点返回规范化 JSON 字节；`GamePackageManifest.checksum` 与响应 `ETag` 均为
这些字节的 SHA-256，匹配 `If-None-Match` 时返回 `304`。INTERNAL 校验请求只有 JSON
绑定失败或缺少 `package` 时返回 `400 ApiFailure`；包可解析但违反 schema 约束时返回
`422 ApiSuccess<ValidationResult>`，其中 `valid=false` 并列出 `errors`。

RenderService 创建会话时不得伪造或信任浏览器提交的计划快照。它必须以精确
`X-Service-Name: RenderService` 身份经 Gateway 调用 INTERNAL 游戏包读取接口；
`ownerUserId` 取自 RenderService 当前请求中由 Gateway 注入并已校验的 `X-User-Id`。
GalGameService 必须同时校验调用方 allowlist、包所有者和 `packageId`，成功时返回标准
`ApiSuccess<GamePackage>`；所有者不匹配与包不存在统一返回 `404 RESOURCE_NOT_FOUND`。

### 7.2 生成任务数据类型

```ts
type GameStyle = "CAMPUS" | "FANTASY" | "SCIENCE";
type Difficulty = "BASIC" | "STANDARD" | "ADVANCED";

interface GameGenerationRequest {
  reviewPlanId: Uuid;
  snapshotVersion: string;
  style: GameStyle;
  difficulty: Difficulty;
  locale: string;
  seed?: number; // int64，用于可复现生成
}

interface GameGenerationJob {
  generationId: Uuid;
  status: JobStatus;
  progress: number; // int32, 0-100；按骨架、模型调用/修复、校验、封装和持久化实际阶段单调推进
  packageId: Uuid | null;
  generatorVersion: string;
  error: ApiError | null;
  createdAt: DateTime;
  updatedAt: DateTime;
}

interface GamePackageManifest {
  packageId: Uuid;
  schemaVersion: string; // 首版 1.0
  generatorVersion: string;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  entrySceneId: string;
  sceneCount: number;
  checksum: Sha256;
  contentUrl: Uri;
  createdAt: DateTime;
}
```

### 7.3 游戏包 schema 1.0

```ts
interface GamePackage {
  schemaVersion: "1.0";
  packageId: Uuid;
  generatorVersion: string;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  entrySceneId: string;
  scenes: Scene[];
  assets: AssetRef[];
}

interface Scene {
  sceneId: string;
  title?: string;
  dialogue: DialogueLine[];
  choices: Choice[];
  knowledgeBindings: KnowledgeBinding[];
}

interface DialogueLine {
  speakerId: string;
  text: string;
  emotion?: string;
}

interface Choice {
  choiceId: string;
  questionId: Uuid;
  text: string;
  nextSceneId: string | null;
  scoreDelta: number;            // 必填；只用于游戏计分，不表示答案正确性或 mastery
  knowledgePointId: Uuid;
  answerKind?: AnswerKind | null; // 同场景存在 QUESTION binding 时必填且固定为 CHOICE
  correct?: boolean | null;       // 同场景存在 QUESTION binding 时必填；与 scoreDelta 相互独立
}

type KnowledgePurpose = "EXPLAIN" | "QUESTION" | "FEEDBACK";

interface KnowledgeBinding {
  knowledgePointId: Uuid;
  questionId: Uuid | null; // purpose=QUESTION 时必填，并在一个游戏包内唯一
  purpose: KnowledgePurpose;
}

type AssetType = "BACKGROUND" | "CHARACTER" | "AUDIO" | "OTHER";

interface AssetRef {
  assetId: string;
  type: AssetType;
  uri: Uri;
}

interface GamePackageValidationRequest {
  package: GamePackage;
}

interface ValidationIssue {
  path: string;
  code: string;
  message: string;
}

interface ValidationResult {
  valid: boolean;
  errors: ValidationIssue[];
}
```

`schemaVersion=1.0` 的结构文件固定为
`backend/GalGameService/schema/game-package-1.0.schema.json`。一个包包含 1-100 个 Scene；
每个 Scene 包含 1-200 行 dialogue 与 0-6 个 choices。`scoreDelta` 是任意 JSON number，
只表示游戏分数；负值、较大值或零都不得代替 `correct`。Schema 负责字段形状、枚举与
`additionalProperties=false`，`GamePackageValidator` 负责同场景绑定、可达性、引用与正确
选项等跨字段规则。

### 7.3.1 **URGENT（跨服务阻塞项）** PlanGraph 消费与证据绑定

GalGameService 在接受 `GameGenerationRequest` 后必须经 Gateway 调用
`GET /internal/v1/review-plans/{reviewPlanId}/graph?snapshotVersion=...`，并以返回的不可变 `PlanGraph` 为唯一知识输入：

- 不得仅凭 `KnowledgeGraphReady` 事件、客户端提交的 pointIds 或旧缓存生成游戏；缓存键至少包含 `reviewPlanId + snapshotVersion`。
- 请求中的 `snapshotVersion` 与 PlanGraph 不一致时停止生成并返回 `422 REVIEW_PLAN_SNAPSHOT_MISMATCH`。
- 只允许为 `PlanNode.questionTarget=true` 的节点生成计分题目；`PREREQUISITE` 和 `CONTEXT` 节点可以用于讲解，但不得在没有显式 question target 时伪造成掌握度证据。
- 没有任何 `questionTarget` 的纯学习 PlanGraph 是合法输入；此时生成只含讲解和导航的游戏包，不生成 `QUESTION` binding，也不产生可回传的作答证据。
- 每个可作答题必须生成稳定且在包内唯一的 `questionId`，同时绑定准确的 `knowledgePointId`。一个场景至多声明一个 `QUESTION` binding；该 binding 与题目所有 Choice 必须位于同一 Scene，且这些 Choice 使用相同的 `questionId` 和 `knowledgePointId`。
- 含 `QUESTION` binding 的场景必须能从 `entrySceneId` 到达；每题至少有一个 `correct=true` 的选项。该题所有 Choice 必须显式携带 `answerKind="CHOICE"` 与 `correct`；非 QUESTION 场景的 Choice 必须省略这两个字段或使用 `null`。
- `correct` 是作答正确性的唯一游戏包字段，`scoreDelta` 只控制游戏分数，两者不得互相推导。RenderService 也不得用 `scoreDelta` 生成 mastery 证据。
- `GamePackageManifest` 和 `GamePackage` 必须保存 `reviewPlanId + snapshotVersion`。RenderService 回传的 questionId、pointId 和 snapshot 必须能据此校验。
- GalGameService 可以设计题面、选项和剧情，但不得修改 PlanNode.weight、依赖边、mastery snapshot 或 KnowledgeService 的知识事实。

本小节是 GalGameService 的 **URGENT（跨服务阻塞项）**；这里只冻结调用与数据义务，不由 KnowledgeService 实现 GalGameService。

### 7.3.2 叙事生成与提示词契约（`galgame-narrative-v3`）

本次调整不新增或修改 Gateway 路由、`GameGenerationRequest`、`GameGenerationJob`、
`GamePackage schema 1.0` 或 RenderService 调用方式。模型不直接生成最终游戏包；生成过程固定为：

1. `GameGenerator` 先生成通过校验的确定性骨架，锁定全部 package/scene/question/choice ID、
   场景拓扑、`knowledgeBindings`、`correct`、`scoreDelta`、assets、计划与快照字段；
2. `NarrativeGenerationService` 使用整个游戏包的一次上下文生成内部 `NarrativeDraft`，模型只能
   重写 scene title、dialogue 和 choice 显示文本，不能覆盖任何锁定字段；
3. 草稿必须通过 `NarrativeDraftValidator` 和 `GamePackageValidator`。草稿不合法时最多执行
   两次有界修复；JSON Output 空内容、超时、限流和供应商 5xx 最多重试三次。仍不可用时
   丢弃整个草稿并使用确定性骨架，
   不保存半成品，也不把供应商响应或异常详情写入公开 job error；
4. `groundingQuotes` 和 `knowledgeUse` 只存在于内部草稿，用于核对知识依据和“知识如何改变
   当前局面”，装配后必须删除，不能加入 `GamePackage schema 1.0`。

PlanGraph 仍是唯一学科事实源。发给模型的知识字段仅限 `pointId/title/summary/tags/role/
questionTarget` 和不含数值权重的依赖边；不得发送 ownerUserId、mastery、weight、selectionReason、
confidence、服务密钥或其他无关数据。上传资料中的 title、summary 和 tags 一律按不可信数据处理，
其中出现的提示词、角色指令、JSON 模板或索取密钥的文字不得提升为模型指令。

提示词必须以“知识内生于叙事”为首要质量要求：整包先形成共同主线、人物目标与矛盾、场景节拍
和知识账本；每个 EXPLAIN/QUESTION 场景都要让知识作为线索、规则、工具、争议或行动依据改变
事件状态。删除该知识后若剧情仍能原样成立，视为知识贴片并要求重写。QUESTION 选项首先是
情境中的行动或判断，正确项必须由目标节点直接支持，错项只表达同类别的相邻误区；不得编造
资料外事实，也不得把其他节点中的真实陈述直接宣判为错误知识。

`CAMPUS/FANTASY/SCIENCE` 必须改变具体矛盾、人物行为和世界机制，不能只替换人名与名词；
`BASIC/STANDARD/ADVANCED` 分别对应识别、单步应用和多条件迁移，资料不足时应降低认知层级，
不得靠生僻措辞或虚构条件制造难度。对白禁止暴露 weight/mastery/tags 等规划元数据，并拒绝
“知识点讲解”“系统已生成评估问题”“来看看这道题”“本轮复习结束”等模板报幕。

内部草稿必须原样、完整且唯一地返回全部 sceneId/choiceId；speakerId 只能来自所选风格的允许
集合：校园为 `你/林澈/周岚`，幻想为 `你/艾黎/洛恩`，科幻为 `你/NEXUS/姚真`。确定性骨架
与模型草稿共用这份人物目录。EXPLAIN/QUESTION 必须提供可逐字回溯到绑定节点 title/summary 的依据，并在对白中出现
对应概念锚点。ASSESSMENT 在选择前不得逐字泄露正确结论。最终包的 ID、拓扑、绑定、正确性、
计分和快照必须与骨架逐字段相同。

生产默认通过 DeepSeek Chat Completions JSON Output 调用模型，部署配置为：

| 配置 | Compose / 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| 启用叙事模型 | `GALGAME_NARRATIVE_ENABLED` | `true` | `MOONSTONE_MODE=Mock` 时强制关闭外部调用 |
| API 密钥 | `DSAPI` | 无 | 只注入 GalGameService，不写入响应、日志或仓库 |
| Endpoint | `GALGAME_NARRATIVE_ENDPOINT` | `https://api.deepseek.com/chat/completions` | 必须为 HTTPS |
| Model | `GALGAME_NARRATIVE_MODEL` | `deepseek-v4-pro` | 可按供应商兼容模型覆盖 |
| Prompt | `NarrativeGeneration__PromptVersion` | `galgame-narrative-v3` | 当前提示词与草稿合同版本 |

启用外部模型意味着上述最小知识字段会发送给所配置供应商；部署者必须依据资料敏感级别、供应商
条款和本地合规要求决定是否启用。关闭或缺少 `DSAPI` 时服务仍可生成契约有效的确定性包。

### 7.4 最小游戏包 Mock

```json
{
  "schemaVersion": "1.0",
  "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
  "generatorVersion": "gala-0.1.0",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "entrySceneId": "scene-001",
  "scenes": [
    {
      "sceneId": "scene-001",
      "dialogue": [
        {
          "speakerId": "heroine",
          "text": "水稻分蘖期最关键的管理目标是什么？",
          "emotion": "curious"
        }
      ],
      "choices": [
        {
          "choiceId": "c1",
          "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
          "text": "协调群体数量与个体生长",
          "nextSceneId": null,
          "scoreDelta": 1,
          "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
          "answerKind": "CHOICE",
          "correct": true
        }
      ],
      "knowledgeBindings": [
        {
          "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
          "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
          "purpose": "QUESTION"
        }
      ]
    }
  ],
  "assets": []
}
```

### 7.5 已冻结项与剩余 OWNER-TBD

- [x] `schemaVersion=1.0` JSON Schema 及 100/200/6 数量边界；
- [x] 首版角色只使用 `DialogueLine.speakerId`，资源统一使用 `AssetRef`；
- [x] 生成任务原子交付，不返回部分游戏包：后台成功时同时保存 manifest 与完整包，失败时
  `packageId=null` 并在任务中返回 `error`；
- [x] 当前 `generatorVersion="gala-0.1.0"`。显式 seed 会稳定 questionId、场景顺序与
  选项顺序；`packageId` 和 manifest 时间仍在每次生成时新建，因此首版不承诺整个包或
  checksum 字节级相同。`galgame-narrative-v3` 的模型文本同样不承诺逐字确定；seed 省略时
  使用随机值；
- [x] 生产游戏包持久化、跨副本一致性、保留期和清理任务。

`MongoGameStore` 将生成任务和游戏包持久化到 MongoDB，支持 4 种运行模式（`mock-mongodb` /
`mock-memory` / `mongodb` / `ephemeral-memory`），通过 `GalGameStore:Provider` 配置项切换。
MongoDB 模式下服务启动时自动将因重启而卡在 `RUNNING` 或 `QUEUED` 的生成任务标记为 `FAILED`；
已完成 job 通过 TTL 索引 30 天自动过期，`MaxJobs=10000` 容量超限时清理最旧的已完成 job。
`InMemoryGameStore` 仍作为本地开发和集成测试的降级选项保留。

当前 GalGameService 已提供 INTERNAL 游戏包读取与校验端点，并保留 `RenderService` 精确
服务身份允许名单。RenderService 本身只交付 C++ 编译壳、最小 WASM 和 JS Adapter；
会话、结果提交、mastery evidence、完整 WASM ABI 与真实帧渲染均由 `@Zopiclone` 后续实现，
不得用前端本地体验冒充这些服务端能力已经完成。

`@F15EX` 需要交付：

- 一个黄金游戏包；
- 一个故意错误的游戏包；
- 一个可由 GalGameService 和 RenderService 共同运行的校验器。

## 8. RenderService

> 负责人：`@Zopiclone`  
> 拥有：ReviewSession、WASM 状态机、进度和 ReviewResult。  
> JS Adapter、页面调用和 Gateway 对接由 `@甲烷` 负责。

### 8.1 REST 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `GET` | `/api/v1/render-runtime/manifest` | 读取 WASM 与 schema 兼容信息 | - | `RuntimeManifest` | `200/503` |
| `GET` | `/api/v1/render-runtime/runtime.wasm` | 下载 manifest 指定的 WASM 字节 | - | `application/wasm` | `200/503` |
| `GET` | `/api/v1/render-runtime/adapter.js` | 下载浏览器 JS Adapter | - | `application/javascript` | `200/503` |
| `POST` | `/api/v1/review-sessions` | 创建复习会话 | `CreateReviewSessionRequest` | `ReviewSession` | `201/400/401/422/502/503` |
| `GET` | `/api/v1/review-sessions/{sessionId}` | 读取会话和进度 | - | `ReviewSession` | `200/400/401/404` |
| `PUT` | `/api/v1/review-sessions/{sessionId}/progress` | 幂等保存进度 | `ProgressSnapshotInput` | `ProgressSnapshot` | `200/400/401/404/409/422` |
| `POST` | `/api/v1/review-sessions/{sessionId}/events` | 追加交互事件 | `InteractionEventBatch` | `EventReceipt` | `202/400/401/404/409/422` |
| `PUT` | `/api/v1/review-sessions/{sessionId}/result` | 幂等提交最终结果 | `ReviewResultInput` | `ReviewResult` | `200/400/401/404/409/422/503` |

上表中的 ReviewSession 接口已经实现。服务同时满足完整 WASM ABI 且配置
`Gateway__BaseUrl`、`Gateway__ServiceKey` 后，manifest 报告 `runtimeMode=FULL` 与
`reviewSessionsAvailable=true`；缺少回调身份时保持 `SHELL`，访问
`/api/v1/review-sessions*` 返回 `501 RENDER_SESSION_NOT_IMPLEMENTED`，不得虚报证据能力。

### 8.2 REST 数据类型

```ts
interface RuntimeManifest {
  wasmVersion: string;
  supportedSchemaVersions: string[];
  wasmUrl: Uri;
  jsAdapterUrl: Uri;
  checksum: Sha256;
  runtimeMode: "SHELL" | "FULL";
  reviewSessionsAvailable: boolean;
  wasmAbiComplete: boolean;
}

interface CreateReviewSessionRequest {
  packageId: Uuid;
  clientRuntimeVersion: string;
}

type ReviewSessionStatus = "CREATED" | "RUNNING" | "COMPLETED" | "ABANDONED";

interface ReviewSession {
  sessionId: Uuid;
  userId: Uuid;
  packageId: Uuid;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  status: ReviewSessionStatus;
  currentSceneId: string | null;
  progressVersion: number; // int32，乐观并发
  startedAt: DateTime | null;
  completedAt: DateTime | null;
}

interface ProgressSnapshotInput {
  expectedVersion: number;
  currentSceneId: string;
  visitedSceneIds: string[];
  runtimeState: JsonObject;
}

interface ProgressSnapshot {
  sessionId: Uuid;
  version: number;
  currentSceneId: string;
  visitedSceneIds: string[];
  runtimeState: JsonObject;
  savedAt: DateTime;
}

type InteractionEventType =
  | "SCENE_ENTERED"
  | "CHOICE_SELECTED"
  | "RUNTIME_ERROR";

interface InteractionEvent {
  clientEventId: Uuid;
  type: InteractionEventType;
  occurredAt: DateTime;
  payload: JsonObject;
}

interface InteractionEventBatch {
  events: InteractionEvent[];
}

interface EventReceipt {
  accepted: number;
  duplicates: number;
}

interface AnswerResult {
  attemptId: Uuid;
  questionId: Uuid;
  knowledgePointId: Uuid;
  answerKind: AnswerKind;
  choiceId: string | null;
  correct: boolean;
  quality: number;          // int32, 0-5；必须符合 KnowledgeService 的质量映射
  scoreDelta: number;
  responseTimeMs: number;   // int64，>= 0
  hintsUsed: number;        // int32，>= 0
  attemptNumber: number;    // int32，从 1 开始
  occurredAt: DateTime;
}

interface ReviewResultInput {
  expectedProgressVersion: number;
  idempotencyKey: Uuid;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  answerResults: AnswerResult[]; // 题目包 1-100；纯讲解包必须为空
  durationSeconds: number;
}

type ReviewResultStatus = "ACCEPTED" | "DUPLICATE";

interface ReviewResult {
  resultId: Uuid;
  sessionId: Uuid;
  status: ReviewResultStatus;
  submittedAt: DateTime;
}
```

### 8.2.1 **URGENT（跨服务阻塞项）** 学习证据提交

RenderService 完成会话后必须把足够的原始学习证据交给 KnowledgeService：

- 创建会话时从已校验的 `GamePackage` 复制并冻结 `reviewPlanId + snapshotVersion`；不得信任浏览器在结果提交时替换它们。
- 每条 AnswerResult 必须包含 GalGame 绑定的 `questionId + knowledgePointId`、唯一 attemptId、正确性、`quality(0-5)`、响应耗时、提示次数、尝试次数和 UTC occurredAt。
- `scoreDelta` 只用于游戏表现；RenderService 不得把它换算成 mastery。quality 必须遵循 6.4 的固定映射，KnowledgeService 会再次校验。
- 最终接受结果后发布 `ReviewCompleted v2`；启用同步恢复路径时，使用同一 payload 调用
  `PUT /internal/v1/review-evidence/{resultId}`。两条路径必须共享 `resultId + idempotencyKey`，由 KnowledgeService 去重。
- 页面刷新、网络重试或消息重投不得生成新的 resultId。相同 idempotencyKey 的 payload 发生变化时必须作为冲突暴露，不得覆盖第一次结果。
- 同一会话对完全相同的结果载荷重试返回 `200 DUPLICATE` 和原 `resultId`；使用不同幂等键，或复用同一幂等键但改变任何结果字段，返回 `409 IDEMPOTENCY_CONFLICT`。
- 没有 `reviewPlanId`、snapshot、questionId、quality 或时间证据的旧 `ReviewCompleted v1` 不足以更新 mastery；KnowledgeService 不得根据 v1 的 `scoreDelta` 猜测掌握度。
- 对没有任何 `QUESTION` binding 的纯讲解包，`answerResults` 必须为空；RenderService 可以
  完成本地会话，但不得调用要求 1-100 条证据的 KnowledgeService evidence 接口，掌握度
  保持不变。只要包内存在 QUESTION，结果就必须覆盖实际作答题目并走同一 evidence 校验路径；
  未进入的分支场景不得伪造 `AnswerResult`，也不要求覆盖包内所有未访问题目。

本小节是 RenderService 的 **URGENT（跨服务阻塞项）**；这里只冻结提交义务，不由 KnowledgeService 实现 RenderService。

### 8.3 JavaScript ↔ WASM API

WASM 不直接访问 HTTP、数据库或消息队列。

```cpp
// 返回 0 表示成功，非 0 表示错误；详细错误由 getLastError() 获取。
int32_t initialize(const char* configJson);
const char* loadPackage(const char* packageJson);   // ValidationResult JSON
int32_t startSession(const char* sessionJson);
const char* dispatchInput(const char* inputJson);   // RenderEvent[] JSON
void renderFrame(double deltaMs);
const char* serializeState();                       // RuntimeState JSON
const char* getLastError();                         // RuntimeError JSON
void dispose();
```

建议 JS Adapter：

```ts
interface WasmAdapter {
  initialize(config: RuntimeConfig): Promise<void>;
  loadPackage(gamePackage: GamePackage): ValidationResult;
  startSession(bootstrap: SessionBootstrap): void;
  dispatchInput(input: RuntimeInput): RenderEvent[];
  renderFrame(deltaMs: number): void;
  serializeState(): JsonObject;
  dispose(): void;
}

type SessionBootstrap = ReviewSession;

interface WasmAdapterFactoryOptions {
  wasmUrl?: string; // 省略时使用 /api/v1/render-runtime/runtime.wasm
}

export function createWasmAdapter(
  options?: WasmAdapterFactoryOptions
): Promise<WasmAdapter>;
```

`adapter.js` 必须以 ES module 形式导出上述 `createWasmAdapter`；前端只依赖这个工厂和
`WasmAdapter`，不得访问 RenderService 容器直连地址。`SessionBootstrap` 已固定为完整
`ReviewSession`。`RuntimeInput`、`RenderEvent` 与 `RuntimeState` 已按 runtime ABI v1 冻结；
adapter 仍以 JSON 对象传递，调用方不得据此形成新的跨服务证据字段。

当前可执行版本为 `cpp-wasm-0.2.0`，实现 runtime ABI v1 的八个 C++/WASM 导出；
Adapter 负责字符串编解码与生命周期，场景状态机、导航、计分、作答与序列化在 WASM 内。
`/readyz` 必须从实际产物自省 `wasmAbiComplete`；完整产物报告
`executionEngine="cpp-wasm-shell"`。`runtimeMode` 只有在 WASM ABI 完整且服务端会话回调
身份已配置时为 `FULL`，否则为 `SHELL`。Compose 基线配置回调身份，因此应提供服务端
ReviewSession、进度、事件与同步 evidence 提交。

职责：

- `@Zopiclone`：C++ / WASM ABI、状态机、内存、渲染和序列化。
- `@甲烷`：JS Adapter、Gateway 调用、JSON 编解码、WASM 生命周期、错误提示和保存节流。

### 8.4 结果 Mock

```json
{
  "expectedProgressVersion": 4,
  "idempotencyKey": "eac9acb9-b96c-43a9-a6ff-6e7dfa885b09",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "answerResults": [
    {
      "attemptId": "36924035-ec0a-46aa-aa7e-25b86edfa259",
      "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
      "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
      "answerKind": "CHOICE",
      "choiceId": "c1",
      "correct": true,
      "quality": 5,
      "scoreDelta": 1,
      "responseTimeMs": 9200,
      "hintsUsed": 0,
      "attemptNumber": 1,
      "occurredAt": "2026-07-27T09:01:40Z"
    }
  ],
  "durationSeconds": 186
}
```

### 8.5 已冻结的 runtime ABI v1

- [x] WASM 字符串入参由调用方用 `rtAlloc/rtFree` 管理；返回指针由运行时持有，调用方立即拷贝且不得释放；
- [x] `RuntimeState` 使用 `render-runtime-state-1`，冻结会话/计划/场景、计分和作答字段；
- [x] 场景切换或选择后保存，`runtimeState` 最大 256 KiB，使用 `progressVersion` 乐观并发；
- [x] Adapter 只接受 ABI v1；导出缺失或版本不支持时诚实回退 JS shell；
- [x] 刷新读取服务端快照；相同进度和结果重放幂等，载荷冲突返回 `409`，断网不清除仍有效会话。

## 9. API Gateway 与前端

> 负责人：`@甲烷`  
> 拥有：路由、鉴权、CORS、限流、超时、错误映射和 JS API Client。  
> 不拥有：业务数据库和领域规则。

### 9.1 路由归属

| 路由前缀 | 目标服务 | 调用方 | 鉴权 |
|---|---|---|---|
| `/api/v1/users` | UserService | Browser | 用户令牌 |
| `/api/v1/auth` | AuthService | Browser | 登录和注册公开，其余按接口 |
| `/api/v1/admin/credit-codes` | CreditService | Browser（管理员后台） | 管理员令牌；必须先于通用 `/api/v1/admin` 匹配 |
| `/api/v1/admin` | AuthService | Browser（管理员后台） | 管理员登录公开，其余管理员令牌 |
| `/api/v1/credits` | CreditService | Browser | 用户令牌 |
| `/api/v1/materials`、`/api/v1/ingestion-jobs` | FileService | Browser | 用户令牌 |
| `/api/v1/knowledge-*`、`/api/v1/assessment-plans`、`/api/v1/learning-plans`、`/api/v1/review-plans`、`/api/v1/mastery-records` | KnowledgeService | Browser | 用户令牌 |
| `/api/v1/game-*` | GalGameService | Browser / Render | 用户令牌 |
| `/api/v1/render-runtime/manifest`、`/api/v1/render-runtime/runtime.wasm`、`/api/v1/render-runtime/adapter.js` | RenderService | Browser | 公开；可缓存，必须按 manifest checksum 验证 WASM |
| `/api/v1/review-sessions` | RenderService | Browser | 用户令牌 |
| `/api/v1/practice-*`、`/api/v1/question-generation-jobs`、`/api/v1/exam-import-jobs`、`/api/v1/shared-practice-packages` | PracticeService | Browser | 用户令牌 |
| `/internal/v1/materials/*/extracted-text` | FileService | KnowledgeService / PracticeService | 精确服务身份 |
| `/internal/v1/review-plans/*/graph` | KnowledgeService | GalGameService / PracticeService | 精确服务身份 |
| `/internal/v1/review-evidence/*` | KnowledgeService | RenderService / PracticeService | 精确服务身份 |
| `/internal/v1/game-package-validations` | GalGameService | RenderService | 服务身份；当前默认只允许 `RenderService` |
| `/internal/v1/game-packages/*` | GalGameService | RenderService | 服务身份；同时校验请求中的 ownerUserId |
| `/internal/v1/credits/*` | CreditService | AuthService / PracticeService / GalGameService | 精确服务身份；端点分别限制调用方 |
| `/internal/v1/*` | 对应服务 | Service only | 服务身份；用户委托身份可选 |

### 9.2 Gateway 行为与信任头

- 浏览器 `/api` 请求中的 `X-Service-Name`、`X-Service-Key`、`X-User-Id`、`X-Gateway-Key` 全部丢弃。`/internal` 请求只暂留 `X-Service-Name + X-Service-Key` 用于服务身份验证，仍先丢弃外部 `X-User-Id` 与 `X-Gateway-Key`。
- INTERNAL 服务身份通过逐服务密钥验证后，Gateway 转发时剥离 `Authorization` 与 `X-Service-Key`，重新注入可信 `X-Service-Name` 和目标服务的 `X-Gateway-Key`。用户路由则从已验证令牌重新注入 `X-User-Id`。
- 每个目标服务使用自己的 `*_SERVICE_KEY`；只有未配置独立密钥时才回退 `GATEWAY_KEY`。KnowledgeService 的入站 `Gateway__ServiceKey` 必须与 Gateway 的 `KNOWLEDGE_SERVICE_KEY` 一致；GalGameService 对应 `GALGAME_SERVICE_URL`、`GALGAME_SERVICE_KEY`；PracticeService 对应 `PRACTICE_SERVICE_URL`、`PRACTICE_SERVICE_KEY`；CreditService 对应 `CREDIT_SERVICE_URL`、`CREDIT_SERVICE_KEY`，各服务入站 `Gateway__ServiceKey` 必须与目标密钥一致。
- Gateway 验证 Bearer Token 时调用 AuthService `/internal/v1/auth/introspections`，携带 AuthService 的目标密钥作为 `X-Gateway-Key`，并原样传递或生成 `X-Correlation-Id`。只有规范的 `200` `ApiSuccess<TokenIntrospection>` 响应且 `active=false` 能证明令牌无效并返回 `401`；该成功信封必须含对象 `data`、空对象 `meta` 和非空字符串 `traceId`，非空 `userId/sessionId` 必须是小写 UUID v4，非空 `expiresAt` 必须是完整 ISO 8601 UTC 时间。内省超时、连接失败、任意非 `200`（含密钥错配 `403` 和 `5xx`）、非 JSON、缺字段、信封或字段不合规，以及 `active=true` 但数据形状错误，均统一返回 `503 SERVICE_UNAVAILABLE`，不得把认证基础设施或上游契约故障伪装成令牌无效。
- 写操作不在 Gateway 层盲目重试。
- GET 只有在确认幂等且无副作用时才能有限重试。
- 保持下游 `error.code`，统一响应结构和 `traceId`。
- 不允许用 HTTP 200 包装业务失败。
- CORS 只允许明确的前端源。
- 限流至少区分匿名登录、上传、生成任务和普通读取。创建型长任务 `POST /api/v1/knowledge-graph-builds`、`POST /api/v1/game-generations`、Practice 题库生成与整卷导入使用 generation；轮询和普通读取使用 general；项目包导入使用 upload。
- `POST /api/v1/materials` 与 `POST /api/v1/practice-packages/imports` 使用 `UPLOAD_TIMEOUT_MS`，默认 `120000` 毫秒；其他路由使用 `DEFAULT_TIMEOUT_MS`，默认 `30000` 毫秒。上传超时不得隐式套用到服务的所有路由。
- 上传文件本体硬上限为 `10 MiB`。Gateway 和 FileService 的 multipart 整包前置上限均为 `11 MiB`，其中额外 `1 MiB` 只用于 boundary、字段和头部开销；最终仍由 FileService 按 `IFormFile.Length` 拒绝超过 `10 MiB` 的文件。不得把整包与文件本体错误地使用同一个 `10 MiB` 阈值。
- Practice 项目包文件上限为 `50 MiB`，精确导入路由的 multipart 整包上限为 `51 MiB`；不放大其他路由上限。
- Frontend 之前如部署 Nginx、Caddy 或云负载均衡，该外层代理至少允许 `52 MiB` 请求体并提供不短于 `190` 秒的上传读写超时，同时保留请求体、`Authorization`、`Content-Type` 与 `X-Correlation-Id`。外层代理生成的 HTML/纯文本 `413/502/504` 不属于 API 错误信封；浏览器客户端必须保留其真实 HTTP 状态，不得统一伪装成 `502 UPSTREAM_CONTRACT_INVALID`。
- 不在 Gateway 保存业务状态或访问服务数据库。

### 9.3 健康检查

| 方法 | 路由 | 响应 | 说明 |
|---|---|---|---|
| `GET` | `/healthz` | `200 HealthStatus` | Gateway 进程存活 |
| `GET` | `/readyz` | `200/503 ReadinessStatus` | 路由配置和关键依赖就绪 |

`READINESS_SERVICES` 是逗号分隔的服务 key。Gateway 应用默认值为
`userService,authService,fileService,knowledgeService`；根目录集成 Compose 显式追加
`galGameService,renderService,practiceService,creditService`，因此当前完整本地闭环会真实探测八个服务的 `/healthz`。
可选 OCRService 不进入 readiness。配置中出现未知 key
时 Gateway 必须拒绝启动。
KnowledgeService 在宿主机的默认目标为 `http://localhost:5104`；集成容器网络内使用
`http://knowledge-service:8080`。前者是 Docker 发布端口，后者是容器内部监听端口，两者
不得混用。

### 9.4 前端适配原则

- 产品对外名称固定为“千知万理”。ReciteHelper 是迁移来源，GalReview 是既有架构/实现标识，均不得替代产品名。
- 公开首页和登录后主页必须以学习项目、资料解析、题库确认、知识图谱与 SM-2 智能复习为默认主线；视觉小说仅表达为项目内可选复习模式。
- “AI 驱动”只可描述语义整理、候选内容生成和辅助解释。文件解析/OCR、确定性判分、来源校验与复习调度必须按其真实机制表述，并展示人工确认边界。
- 页面只依赖 Gateway 路由和公共响应结构。
- WASM 只依赖 JS Adapter。
- 前端不得拼接服务直连地址。
- 前端不得根据 HTTP 500 的 message 猜测业务状态。
- 所有稳定分支判断使用 `error.code` 或显式状态字段。

当前页面路由为 `/login`、`/register`、`/forgot-password`、`/home`、`/projects`、
`/projects/:projectId`、`/practice/:sessionId`、`/shared-projects`、`/materials`、
`/knowledge`、`/knowledge-graph` 和 `/review`。`/knowledge` 使用 6.1 已有分页接口展示完整知识点列表，
`/knowledge-graph` 展示章节、知识点与关系；两页必须持续读取 `nextCursor`，不得把首个 100 条结果冒充完整图谱。`/materials` 只按 5.2 的非 OCR 请求上传、提取并构图，
随后创建 Assessment 或 Learning Plan；`/review` 依次调用 GalGame 生成、游戏包读取、
Render runtime 资源。manifest 为 `runtimeMode=SHELL` 时只在浏览器本地创建临时会话，
不调用 ReviewSession/progress/events/result，也不更新 mastery；Compose 正常配置应为
`reviewSessionsAvailable=true` 并走完整服务端接口。桌面页面不得把 Prototype 的
固定像素画布直接套到任意屏幕：宽屏主页使用视口高度和弹性网格填满浏览器，认证页的
内容区、字号与间距随视口连续缩放；移动端和平板仍可按断点改为纵向滚动布局。生产容器
在容器内监听 `8080`，默认向宿主发布为 `5120`（由 `FRONTEND_HOST_PORT` 覆盖），并
把相对 `/api/*` 同源代理到 Gateway；构建产物不得包含某台开发机的服务直连地址。代理
无法连接 Gateway 时返回 `503 SERVICE_UNAVAILABLE`，保留合法的 `X-Correlation-Id`，
请求未提供时生成新的关联 ID，并在响应头与 `ApiFailure.traceId` 中返回同一值。

### 9.5 容器化运行基线

当前闭环由根目录 `compose.integration.yaml` 编排。接口路径、请求方法、请求体、响应体和
鉴权方式均保持本契约既有定义；宿主端口调整不改变任何 API 语义，也不得反向改写容器
内部或第三方协议端口。端口和依赖边界如下：

| 组件 | 容器监听 | 宿主默认发布 | 说明 |
|---|---:|---:|---|
| Gateway | `5000` | `5000` | `GATEWAY_HOST_PORT`；浏览器和服务间调用的唯一入口，绑定地址由 `GATEWAY_BIND_ADDRESS` 配置 |
| UserService | `5101` | 不发布 | 集成环境可使用 `MOONSTONE_MODE=Mock` |
| AuthService | `5102` | 不发布 | 集成环境可使用 `MOONSTONE_MODE=Mock` |
| FileService | `5103` | 不发布 | 使用 MongoDB + GridFS；只由 Gateway 访问 |
| KnowledgeService | `8080` | `5104` | `KNOWLEDGE_HOST_PORT`；仅诊断，绑定地址由 `DIAGNOSTIC_BIND_ADDRESS` 配置 |
| GalGameService | `5105` | 不发布 | 只由 Gateway 访问；使用 MongoDB 持久化 |
| RenderService | `5106` | 不发布 | C++ / WASM 运行时与服务适配层，只由 Gateway 访问 |
| PracticeService | `5107` | 不发布 | 四层 MediatR CQRS 复习服务，使用 MongoDB 与本地模型资产 |
| CreditService | `5108` | 不发布 | 四层 MediatR CQRS 计费服务，使用独立 MySQL |
| Frontend | `8080` | `5120` | `FRONTEND_HOST_PORT`；非 root Node 静态站点，同源代理 `/api` 到 Gateway |
| OCRService | `5110` | 不发布 | `ocr` profile 的可选内部依赖，本轮闭环不启动 |
| User MySQL | `3306` | 不发布 | 只供 UserService；独立卷 `user-mysql-data` |
| Auth MySQL | `3306` | 不发布 | 只供 AuthService；独立卷 `auth-mysql-data` |
| Credit MySQL | `3306` | 不发布 | 只供 CreditService；独立卷 `credit-mysql-data` |
| MongoDB | `27017` | 不发布 | 只供 FileService |
| Neo4j Browser | `7474` | `5254` | `NEO4J_BROWSER_HOST_PORT`；仅供受限诊断 |
| Neo4j Bolt | `7687` | `5255` | `NEO4J_BOLT_HOST_PORT`；KnowledgeService 在容器网络内连接 `neo4j:7687` |

`5000-5300` 只约束 Docker/Compose 发布到宿主机的端口及相应 `*_HOST_PORT` 默认值，因为
这些端口才位于本项目的宿主防火墙边界。默认发布端口可通过
`GATEWAY_HOST_PORT`、`KNOWLEDGE_HOST_PORT`、`FRONTEND_HOST_PORT`、
`NEO4J_BROWSER_HOST_PORT` 和 `NEO4J_BOLT_HOST_PORT` 覆盖；覆盖值仍应位于该范围，并避开
操作系统保留段。Frontend 本地开发与预览端口默认为 `5121/5122`。

容器 target、Dockerfile `EXPOSE`、服务间 URL、数据库原生端口、测试进程临时端口以及
SMTP、HTTP(S)、SOCKS 等第三方协议端口不受该范围限制。测试监听应让操作系统分配临时
端口；AuthService 直接使用 `SMTP_PORT` 指定的供应商端口，默认 `465`，仓库不提供虚构的
`5256` SMTP 转发服务；系统代理缺少端口时视为未配置，不得为满足项目端口范围而改写其
协议语义。

容器配置只记录变量名，不在本文或镜像中写真实密钥：

- Gateway 使用 `GATEWAY_KEY`、各服务 `*_SERVICE_KEY`、各服务 `*_SERVICE_URL`、`READINESS_SERVICES`、`DEFAULT_TIMEOUT_MS`、`UPLOAD_TIMEOUT_MS` 和 `CORS_ORIGINS`；GalGameService 的目标配置明确为 `GALGAME_SERVICE_URL` 与 `GALGAME_SERVICE_KEY`；
- FileService 使用 `Gateway__ServiceKey`、`ConnectionStrings__FileDatabase`、`MongoDb__Database`、`InternalAccess__ExtractedTextAllowedServices__0`、`Ocr__BaseUrl`、`Ocr__TimeoutMinutes`；
- KnowledgeService 使用 `Gateway__ServiceKey`、`GatewayMaterialText__BaseUrl`、`GatewayMaterialText__ServiceName`、`GatewayMaterialText__ServiceKey`、`GatewayMaterialText__Timeout` 以及 `Neo4j__Uri`、`Neo4j__Username`、`Neo4j__Password`、`Neo4j__Database`；
- GalGameService 使用 `Gateway__BaseUrl`、`Gateway__ServiceKey`、`InternalAccess__ValidationAllowedServices__0`、`InternalAccess__PackageReaderAllowedServices__0` 和 `NarrativeGeneration__*`；两个 INTERNAL 调用方默认都只允许 `RenderService`，叙事 API key 只从 `DSAPI` 注入；
- PracticeService 使用 `Gateway__BaseUrl`、`Gateway__ServiceName=PracticeService`、`Gateway__ServiceKey`、MongoDB 连接串和本地模型资产；
- CreditService 使用 `Gateway__ServiceKey`、`CreditStore__Provider=MySQL` 与独立 `ConnectionStrings__CreditDatabase`；
- RenderService 基础壳只使用 `PORT`；未来实现 INTERNAL 回调时再启用 `Gateway__BaseUrl`、`Gateway__ServiceName` 与 `Gateway__ServiceKey`；
- AuthService、UserService 与 CreditService 分别使用自己的 `Gateway__ServiceKey`、独立 MySQL 连接串和独立数据卷；Auth/User 服务器模板固定使用 `MySql` 模式，本地可显式覆盖为 `Mock`，CreditService 生产固定使用 MySQL。Compose 内部 MySQL 8.4 的 `caching_sha2_password` 连接串包含 `AllowPublicKeyRetrieval=True` 且端口不外露；改接外部数据库时必须使用受信 CA 的 TLS；
- Frontend 使用 `GATEWAY_UPSTREAM`，AuthService 的可选邮件配置使用 `SMTP_*` 与 `ACCOUNT_FRONTEND_BASE_URL`；
- `DSAPI`（DeepSeek）只用于 §7.3.2 的可选 GalGame 叙事生成；`BitchSDAU`（阿里 API）仍不属于当前主链路。二者都不是“注册/登录 -> 上传 -> 确定性文本提取 -> KnowledgeService 构图 -> Neo4j”的依赖，不能注入 User/Auth/File/Knowledge/Render/Gateway 容器或写入日志。

开发默认密钥只用于本地；生产部署必须通过 secret 管理器覆盖，日志、构建参数、
Compose 文件和接口示例均不得打印真实值。Docker Desktop 的镜像与卷数据位置属于宿主机运维配置，不由业务容器内路径决定。

仓库根目录已有 `.env.deploy.example`，只保存变量名和 `CHANGE_ME` 占位值。未来部署时在
目标主机复制为不提交版本库的 `.env`，替换服务密钥、数据库密码、管理员占位凭据、绑定
地址、宿主端口、SMTP 和 CORS 源后，再由同一 `compose.integration.yaml` 启动。本地已验证
12 个默认容器同时 healthy，并验证 AuthService/UserService 在 MySQL 模式重启后仍可登录
和读取用户资料；尚未执行远程部署。GalGameService 已实现 MongoDB 持久化和启动恢复，RenderService 仅为
基础工具链壳且完整 C++ WASM ABI 未完成，因此这两项不能据此宣称生产就绪。

## 10. 异步事件

本章冻结未来消息契约，不表示各服务当前已接入消息总线。KnowledgeService 的首版可执行路径是 6.1 的同步 INTERNAL HTTP；事件生产/消费只有在团队提供统一 broker、consumer group、重试与 DLQ 基线后才能启用。

### 10.1 事件信封

```ts
interface EventEnvelope<T> {
  eventId: Uuid;
  eventType: string;
  eventVersion: number;
  occurredAt: DateTime;
  correlationId: string;
  causationId: string | null;
  producer: string;
  data: T;
}
```

### 10.2 首批事件

| 事件 | 生产者 | 消费者 | data 最小字段 |
|---|---|---|---|
| `MaterialUploaded v1` | FileService | Gateway 通知 / 审计；**KnowledgeService 明确不消费** | `materialId, ownerUserId, mediaType, checksum, contentRef` |
| `MaterialTextReady v1` | FileService | KnowledgeService | **URGENT（跨服务阻塞项）** `materialId, ownerUserId, textChecksum, textLength, parserVersion, sourceMapVersion, contentRef` |
| `KnowledgeGraphReady v1` | KnowledgeService | Gateway 通知 / GalGameService | `graphId, studyProjectId, materialId, version, subjectCode, chapterCount, pointCount` |
| `GamePackageReady v1` | GalGameService | RenderService / Gateway 通知 | `packageId, schemaVersion, reviewPlanId, snapshotVersion, contentRef, checksum` |
| `ReviewCompleted v2` | RenderService | KnowledgeService | **URGENT（跨服务阻塞项）** `resultId, idempotencyKey, reviewPlanId, snapshotVersion, userId, answerResults, completedAt` |

### 10.3 事件载荷

```ts
interface MaterialUploadedData {
  materialId: Uuid;
  ownerUserId: Uuid;
  mediaType: string;
  checksum: Sha256;
  contentRef: string;           // 原始文件引用；KnowledgeService 不读取
}

interface MaterialTextReadyData {
  materialId: Uuid;
  ownerUserId: Uuid;
  mediaType: string;
  sourceFileChecksum: Sha256;
  textChecksum: Sha256;
  textLength: number;           // int64，规范化后 UTF-16 code unit 数量
  parserVersion: string;
  sourceMapVersion: "1";
  contentRef: string;           // 经 Gateway 的 extracted-text 相对路由或短期授权引用
}

interface KnowledgeGraphReadyData {
  graphId: Uuid;
  studyProjectId: Uuid;
  materialId: Uuid;
  version: number;
  subjectCode: SubjectCode;
  chapterCount: number;
  pointCount: number;
}

interface GamePackageReadyData {
  packageId: Uuid;
  schemaVersion: string;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  contentRef: string;
  checksum: Sha256;
}

interface ReviewCompletedDataV2 {
  resultId: Uuid;
  idempotencyKey: Uuid;
  sessionId: Uuid;
  userId: Uuid;
  packageId: Uuid;
  reviewPlanId: Uuid;
  snapshotVersion: string;
  completedAt: DateTime;
  durationSeconds: number;
  answerResults: KnowledgeAnswerEvidence[];
  evidenceChecksum: Sha256;     // 对规范化学习证据 payload 计算
}
```

`MaterialTextReady v1` 与 `ReviewCompleted v2` 的生产义务及统一消息总线基线均为 **URGENT（跨服务阻塞项）**。当前 KnowledgeService 构图任务经 HTTP 创建后同步读取 FileService 的规范化文本，掌握度结果经 INTERNAL HTTP 提交；尚未注册事件 consumer。未来适配器必须复用现有 MediatR 命令与同一幂等存储。KnowledgeService 永不消费 `MaterialUploaded v1`，也不得在上传事件到达时抢先读取或解析原始文件；`ReviewCompleted v1` 仅保留历史兼容，不得驱动 mastery 更新。

### 10.4 事件 Mock

```json
{
  "eventId": "6f05c7ca-c6e4-4f3f-b27f-b9e92ef106bf",
  "eventType": "MaterialTextReady",
  "eventVersion": 1,
  "occurredAt": "2026-07-27T08:40:00Z",
  "correlationId": "01JFILETEXT...",
  "causationId": "d5063158-ec9f-4b9e-9f65-89a3fc30c00b",
  "producer": "FileService",
  "data": {
    "materialId": "3a7f3d0f-1876-4879-8d6d-01a919d5c935",
    "ownerUserId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
    "mediaType": "application/pdf",
    "sourceFileChecksum": "8dd9c7e1b91f4bdc184c2c9062ab6a502251ae6a2c4c4fa70cc95b610de60f7f",
    "textChecksum": "da41f4c6f84f6067d62bf87b7bbaf6f4661ad665c9c643c8be2d3c198f0f2d31",
    "textLength": 48216,
    "parserVersion": "files-text-v1",
    "sourceMapVersion": "1",
    "contentRef": "/internal/v1/materials/3a7f3d0f-1876-4879-8d6d-01a919d5c935/extracted-text"
  }
}
```

```json
{
  "eventId": "e1a1f0af-034d-4ec6-9f72-3c71dc26c96d",
  "eventType": "KnowledgeGraphReady",
  "eventVersion": 1,
  "occurredAt": "2026-07-27T08:45:00Z",
  "correlationId": "01JKNOW...",
  "causationId": "d5063158-ec9f-4b9e-9f65-89a3fc30c00b",
  "producer": "KnowledgeService",
  "data": {
    "graphId": "b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0",
    "materialId": "3a7f3d0f-1876-4879-8d6d-01a919d5c935",
    "version": 1,
    "subjectCode": "AGRONOMY",
    "chapterCount": 6,
    "pointCount": 18
  }
}
```

```json
{
  "eventId": "ca9db42b-76a0-4a3b-aed8-b222eaad83d8",
  "eventType": "ReviewCompleted",
  "eventVersion": 2,
  "occurredAt": "2026-07-27T09:03:06Z",
  "correlationId": "01JREVIEW...",
  "causationId": "bc98017d-cf5f-44fc-ac09-9604a2a0248b",
  "producer": "RenderService",
  "data": {
    "resultId": "e6d55185-3225-4083-a5c8-aa2d23b64522",
    "idempotencyKey": "eac9acb9-b96c-43a9-a6ff-6e7dfa885b09",
    "sessionId": "bc98017d-cf5f-44fc-ac09-9604a2a0248b",
    "userId": "7bc4918a-9079-4ea2-9e8e-369ad79a9f20",
    "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
    "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
    "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
    "completedAt": "2026-07-27T09:03:06Z",
    "durationSeconds": 186,
    "answerResults": [
      {
        "attemptId": "36924035-ec0a-46aa-aa7e-25b86edfa259",
        "questionId": "6428a20a-66dd-44c9-944f-d7b36fa9c95a",
        "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
        "answerKind": "CHOICE",
        "correct": true,
        "quality": 5,
        "responseTimeMs": 9200,
        "hintsUsed": 0,
        "attemptNumber": 1,
        "occurredAt": "2026-07-27T09:01:40Z"
      }
    ],
    "evidenceChecksum": "876f201f29474785e046d9e2a28515b39ca2d233f123097d6af30180e943dd61"
  }
}
```

### 10.5 消息处理规则

- 按 `eventId` 幂等。
- 重试次数有上限，超过上限进入死信队列。
- 日志和死信记录保留 `correlationId`。
- 事件字段只增不删。
- 破坏性变更使用新的 `eventVersion`。
- 不在消息中传输文件、完整图谱或完整游戏包。
- `contentRef` 必须指向经 Gateway 访问的资源，不得泄露服务直连地址。
- KnowledgeService 对 `MaterialTextReady v1` 同时按 eventId 与图谱构建幂等键去重；对 `ReviewCompleted v2` 同时按 eventId、resultId 和 idempotencyKey 去重。

## 11. Mock 与契约测试

### 11.1 每个端点的最小 Mock

| 文件 | 内容 | 用途 |
|---|---|---|
| `success.json` | 正常字段完整，ID 和时间稳定 | 页面和适配器主流程 |
| `empty.json` | 空列表或可选字段为 `null` | 空状态 |
| `boundary.json` | 最大长度、分页末尾或边界枚举 | 防止硬编码 |
| `validation-error.json` | `400/422` 和稳定 `error.code` | 表单与错误展示 |
| `not-found.json` | `404 RESOURCE_NOT_FOUND` | 失效链接和权限隐藏 |
| `processing.json` | `202` 或 `RUNNING` | 异步等待页面 |

### 11.2 建议仓库结构

```text
docs/
  api/
    endpoints.md
    data-types.md
mocks/
  <resource>/
    success.json
    empty.json
    boundary.json
    validation-error.json
contracts/
  events/
    <EventName>.v1.json
tests/
  contract/
```

### 11.3 轻量确认流程

1. 服务负责人依据本文补齐字段、枚举、限制和 Mock。
2. 调用方用 Mock 启动页面、JS Adapter 或消息消费者。
3. 生产方、调用方快速确认；群聊、PR 评论或短会均有效。
4. 实现完成后，同一组契约测试切换到 Gateway 真实路由。
5. 发现差异时先修改契约与 Mock，再修改双方实现。
6. 只有重大跨服务变更才写简短 ADR，不增加额外审批链。

### 11.4 当前全流程集成验证范围

本轮集成验证一条确定性支撑链路：用户经 Gateway 注册并登录，上传含可直接提取文字的
资料，FileService 生成规范化文本，KnowledgeService 经 Gateway 读取该文本并在 Neo4j
构建章节、知识点和依赖图；随后生成 Assessment Plan 与 GalGame 游戏包，前端经公开
Runtime manifest、JS Adapter 和最小 WASM 完成基础壳本地游玩。Render 会话、作答证据
提交和 mastery 更新不在当前已完成范围。解析任务请求固定为：

```json
{
  "parserVersion": "files-text-v1",
  "force": false,
  "enableOcr": false,
  "ocrMode": "standard"
}
```

`RuntimeManifest.wasmUrl` 与 `jsAdapterUrl` 必须使用上述 Gateway 相对路径，前端不得直连
RenderService。`checksum` 是 `runtime.wasm` 原始响应字节的小写 SHA-256；manifest 与两个
资源端点可公开读取，并必须使用相同 `wasmVersion` 构建产物，部署时不得返回不存在的 URL。

`ocrMode` 在这里仅验证兼容的数据形状；`enableOcr=false` 才是实际执行约束。
集成脚本不得启动 OCR profile、调用 `/v1/ocr`、轮询 OCR 逐页进度或把扫描件作为
成功样例。因此本轮结果无论成功与否，都不能表述为“OCR 已测试”或“OCR 准确率达标”。

闭环通过时还必须核对：FileService 返回的 owner、checksum、UTF-16 offset、
`sourceMap` 与 `blocks` 通过 KnowledgeService 边界校验；构图任务进入
`SUCCEEDED`；Neo4j 中章节、知识点和关系端点可读，知识点初始 mastery 为 0，
每个知识点至少有一个可回到原文的来源位置。注册、内省、上传、纯文本交付和 Gateway
适配分别属于 AuthService、FileService、Gateway 负责的 **URGENT（跨服务义务）**；
KnowledgeService 只负责从受信文本开始的校验、构图、计划和掌握度逻辑。

2026-07-31 的非 OCR 构图基线已经按上述范围完成真实 E2E：26,139 个 UTF-16 code
unit、20 个来源区间和 20 个块通过文本契约校验，`chapter-segmenter-v2` /
`knowledge-extractor-v2` 构建出 7 章、243 个知识点和 207 条先修关系；API 与
Neo4j 计数一致，先修子图无环，初始 mastery 全为 0，同请求构图幂等复用及
`IDEMPOTENCY_KEY_REUSED` 冲突码均通过。逐接口证据、命令、容器状态和未测范围见
`docs/test_report.md`。2026-08-02 又在默认 12 容器环境中验证了 GalGameService 的 PlanGraph
读取与游戏包生成，以及 Render 的公开 runtime 资源、C++ 壳自检、JS Adapter 加载和浏览器
本地游玩。Render 会话、事件、结果幂等、mastery evidence、OCR、消息总线、完整 WASM ABI
和真实帧渲染均未完成集成；逐接口证据和限制以 `docs/test_report.md` 第 11 节为准。

## 12. 开工清单

### 12.1 负责人交付

| 负责人 | 必须确认 | 最小交付物 |
|---|---|---|
| `@Sleexy` | 注册边界、令牌策略、文件限制、OCR 可选解析任务；**URGENT** 规范化纯文本、结构块与 `MaterialTextReady v1` | User/Auth/File Markdown + Mock |
| `@Arabidopsis` | Neo4j 分层图、章节切分、PlanGraph、hub 权重、SM-2 与结果幂等 | Knowledge Markdown + 图谱/计划 Mock |
| `@F15EX` | game schema 1.0、生成器版本、场景与选择约束；**URGENT** PlanGraph 读取与 question 绑定 | 黄金包、错误包和校验器 |
| `@Zopiclone` | WASM ABI、RuntimeState、会话状态和结果幂等；**URGENT** `ReviewCompleted v2` 证据 | WASM 接口说明 + 状态 Mock |
| `@甲烷` | **URGENT** Gateway 信任头、动态内省、Knowledge/File 路由、CORS、超时和 JS Adapter | 路由表、API Client 和错误映射 |

### 12.2 M0 开放项与已决策基线

| 项目 | 建议默认值或当前决策 | 拍板人 |
|---|---|---|
| Access Token 使用 JWT 还是内省 | 首版使用 AuthService INTERNAL 动态内省；Gateway 不本地猜测令牌状态 | `@Sleexy + @甲烷` |
| 注册时 Auth 与 User 的一致性 | Auth 经 Gateway INTERNAL 同步创建 UserProfile | `@Sleexy` |
| 首批文件格式和大小 | 10 MiB；PDF/DOCX/Markdown/HTML 使用专用解析器，未知扩展名且为 `text/*` 或 `application/octet-stream` 时按 UTF-8 文本兜底；图片和扫描 PDF 仅在显式启用 OCR 时解析 | `@Sleexy` |
| **URGENT** FileService 纯文本交付 | 已按 5.2.1 与 `MaterialTextReady v1` 冻结 | `@Sleexy` |
| Knowledge 图谱、关系与算法版本 | 已按 6.0-6.8 冻结，不再是 OWNER-TBD | `@Arabidopsis` |
| 游戏包 schema 1.0 | 本文为字段下限，黄金包冻结 | `@F15EX + @Zopiclone` |
| WASM 状态保存频率 | 场景切换或选择后保存，不逐帧上传 | `@Zopiclone + @甲烷` |
| 事件重试与死信 | 3 次指数退避，保留 correlationId | 各服务负责人 |

## 13. 完成标准

本文 v0.1 达到 M0 的条件：

- [ ] 每位负责人确认所属端点与数据类型；
- [ ] 每个 P0 端点至少存在 `success`、`validation-error` 和 `processing/empty` Mock；
- [ ] 前端可在后端未完成时基于 Mock 开发；
- [ ] GalGameService 与完整 RenderService 共同通过黄金游戏包；当前仅 JS Adapter 壳完成校验；
- [ ] JS Adapter 与完整 WASM 完成初始化、加载、游玩、保存和结果提交；当前只完成本地壳加载与游玩；
- [x] Gateway 路由表、鉴权方式和统一错误响应完成确认；
- [x] 所有领域服务只经 Gateway 调用；仅保留 FileService 到内部 OCR 执行依赖这一受限例外。
- [x] **URGENT** FileService 可返回符合 5.2.1 的纯文本与结构块；
- [ ] **URGENT** FileService 可发布 `MaterialTextReady v1`；同步 HTTP 可用不得冒充事件生产已完成；
- [x] KnowledgeService 可从同一文本稳定构建章节 DAG，并生成不可变 ASSESSMENT/LEARNING PlanGraph；
- [ ] **URGENT** GalGameService 可按 snapshot 读取 PlanGraph，RenderService 可通过同步 INTERNAL evidence 回写结果，重复结果只更新一次 mastery；GalGame 侧已完成，Render 侧待实现；
- [ ] **URGENT** RenderService 发布 `ReviewCompleted v2` 消息并由 KnowledgeService 消费；同步闭环不得冒充消息总线已经完成。

后续字段细化进入各服务仓库；本文只维护跨服务边界与团队共同依赖。

## 14. PracticeService（ReciteHelper 迁移，BASELINE）

PracticeService 承载产品唯一顶层的 ReciteHelper 经典复习项目聚合。用户所见的项目不是 GalGame 项目：资料、章节、题库、章节练习、智能复习、模拟试卷、知识点学习、项目包与复习历史组成同一 `StudyProject`；KnowledgeService 的图谱/SM-2 是该项目的知识组织与调度能力，GalGameService/RenderService 的视觉小说链路只是项目内的“故事回响”复习方式。不得把 ReciteHelper 表达成 GalReview 故事产品的附属功能，也不得把资料页留下的全局 PlanGraph 当成项目。该产品主从关系不改变下述单一事实所有者和跨服务权限边界。

PracticeService 的迁移决策、来源差异、UI 原则和逐项变更状态见
`docs/recitehelper-migration.md`。服务内部固定采用与 KnowledgeService 相同的
API/Application/Domain/Persistence 四层项目；API 通过 MediatR Command/Query 调用应用层，
不得直接访问仓储、MongoDB、模型或 Gateway client。本节只冻结跨服务可见的 HTTP 与数据契约。

### 14.1 接口目录

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| `POST` | `/api/v1/practice-projects` | 用户 | 先创建引用一个或多个 READY 资料、尚未绑定图谱的经典复习项目 |
| `GET` | `/api/v1/practice-projects` | 用户 | 游标分页查询自己的项目 |
| `GET` | `/api/v1/practice-projects/{projectId}` | 用户 | 查询项目详情和统计 |
| `PATCH` | `/api/v1/practice-projects/{projectId}` | 用户 | 修改名称、科目和图谱引用 |
| `DELETE` | `/api/v1/practice-projects/{projectId}` | 用户 | 归档项目；不删除 File/Knowledge 数据 |
| `POST` | `/api/v1/practice-projects/{projectId}/question-generations` | 用户 | 从 FileService 规范化文本异步生成题库 |
| `GET` | `/api/v1/question-generation-jobs/{jobId}` | 用户 | 查询生成状态和逐资料诊断 |
| `GET` | `/api/v1/practice-projects/{projectId}/questions` | 用户 | 查询题目；可按题型、状态、知识点筛选 |
| `POST` | `/api/v1/practice-projects/{projectId}/questions` | 用户 | 人工新增题目 |
| `PATCH` | `/api/v1/practice-questions/{questionId}` | 用户 | 修改题目、答案、解释、分值和绑定 |
| `DELETE` | `/api/v1/practice-questions/{questionId}` | 用户 | 软删除题目 |
| `POST` | `/api/v1/practice-sessions` | 用户 | 创建普通、智能或试卷会话 |
| `GET` | `/api/v1/practice-sessions/{sessionId}` | 用户 | 查询会话、顺序与作答进度 |
| `PUT` | `/api/v1/practice-sessions/{sessionId}/answers/{questionId}` | 用户 | 幂等保存一道答案并判分 |
| `POST` | `/api/v1/practice-sessions/{sessionId}/completion` | 用户 | 完成会话并幂等提交 mastery 证据 |
| `POST` | `/api/v1/practice-questions/{questionId}/help` | 用户 | 返回有出处的 Top 3 帮助，可选生成解释 |
| `POST` | `/api/v1/exam-import-jobs` | 用户 | 从 READY material 异步导入整卷草稿 |
| `GET` | `/api/v1/exam-import-jobs/{jobId}` | 用户 | 查询整卷导入状态与校对问题 |
| `POST` | `/api/v1/practice-projects/{projectId}/exam-papers` | 用户 | 按题型比例、分值和种子随机组卷 |
| `POST` | `/api/v1/practice-packages/imports` | 用户 | 导入 `.rhproj`、`.rhp` 或新版项目包 |
| `GET` | `/api/v1/practice-projects/{projectId}/package` | 用户 | 导出新版项目包 |
| `POST` | `/api/v1/practice-projects/{projectId}/publications` | 用户 | 发布不可变共享包版本 |
| `GET` | `/api/v1/shared-practice-packages` | 用户 | 搜索可见共享包 |
| `GET` | `/api/v1/shared-practice-packages/{packageId}/content` | 用户 | 经鉴权下载共享包 |

所有端点使用第 2 节统一信封。异步创建返回 `202` 和任务资源；资源创建返回
`201`。列表 `limit` 默认 20、范围 1-100，`cursor` 为 opaque 字符串。对非所有者统一
返回 `404 RESOURCE_NOT_FOUND`，避免泄露资源存在性。

### 14.2 基础数据类型

```ts
type PracticeQuestionKind =
  | "SINGLE_CHOICE"
  | "FILL_BLANK"
  | "TRUE_FALSE"
  | "TERM_DEFINITION"
  | "ESSAY";

type StudyProject = {
  projectId: UUID;
  ownerUserId: UUID;
  name: string;                 // 1-120
  subjectCode: string | null;   // 与 FileService SubjectCode 规则一致
  materialIds: UUID[];          // 1-20；仅保存引用
  graphId: UUID | null;         // 新立册编排的中间态也为 null；绑定后必须是本 project 的图谱
  questionBankId: UUID;
  status: "ACTIVE" | "ARCHIVED";
  questionCounts: Partial<Record<PracticeQuestionKind, number>>;
  createdAt: Timestamp;
  updatedAt: Timestamp;
};

type SourceReference = {
  materialId: UUID;
  startOffset: number;          // FileService UTF-16 offset
  endOffset: number;            // end-exclusive
  sourceMapVersion: string;
  excerptChecksum: string;      // lowercase SHA-256
};

type PracticeQuestion = {
  questionId: UUID;
  questionBankId: UUID;
  kind: PracticeQuestionKind;
  prompt: string;               // 1-4000
  options: string[];            // SINGLE_CHOICE 为 2-8；其余为空
  correctAnswers: string[];     // 填空按空位顺序；判断为 "true"/"false"
  explanation: string | null;
  score: number;                // (0, 100]
  difficulty: number;           // [1, 5]
  knowledgePointId: UUID | null;
  sourceReferences: SourceReference[];
  status: "DRAFT" | "READY" | "DELETED";
  version: number;
  createdAt: Timestamp;
  updatedAt: Timestamp;
};
```

`correctAnswers` 只在题库所有者编辑接口、已作答题目的评分结果以及完整考试结束后返回；
活动会话的未作答题不得提前返回答案。题目修改使用 `version` 乐观并发；版本冲突返回
`409 VERSION_CONFLICT`。

### 14.3 创建项目与生成题库

```json
POST /api/v1/practice-projects
{
  "name": "数据结构期末复习",
  "subjectCode": "CS_DS",
  "materialIds": ["62456508-30dd-4284-8144-6ffdc0116e55"],
  "graphId": null
}
```

```json
POST /api/v1/practice-projects/{projectId}/question-generations
{
  "idempotencyKey": "565bb54f-ad63-4a27-a499-753a9bbbd18a",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "kinds": ["SINGLE_CHOICE", "FILL_BLANK", "TERM_DEFINITION", "ESSAY"],
  "targetCount": 30,
  "generatorVersion": "recite-question-v1"
}
```

浏览器新建经典复习项目时禁止提交既有 `graphId`，避免把资料级或他册图谱冒充本册图谱。
创建响应中的 `projectId` 随后作为 `GraphBuildRequest.studyProjectId`；KnowledgeService 必须经受信
INTERNAL 接口核验项目所有者与 `materialId` 成员关系。构图成功后，客户端以项目当前 `version`
PATCH `graphId`，PracticeService 再反查图谱的 `studyProjectId` 和来源资料。任一校验不一致均返回
`409`，不得进入成题。旧 `.rhproj/.rhp` 或中断流程仍可保留 `graphId=null`，并从本册恢复识网。

“立册”不是只写入空 `StudyProject` 的结束动作，而是 ReciteHelper 经典创建流程的产品级编排：客户端
先用 READY material 创建 `StudyProject`，再按该 `projectId` 建图并绑定；随后读取本册图谱全部章节，
创建一次覆盖全部章节的 OPEN assessment plan，再调用同册题目生成接口，最后进入该册。藏书阁
只负责资料上传、OCR、规范化文本与预览，不创建或选择图谱。首次自动成题固定请求
`SINGLE_CHOICE | FILL_BLANK | TERM_DEFINITION | ESSAY`。当 `targetCount` 不少于请求题型数时，
生成器必须先轮转覆盖每种请求题型，再重复任一题型；知识点也同步轮换，不能因知识点数先达到
`targetCount` 而把首批题全部生成为第一种题型。`TRUE_FALSE` 沿用 ReciteHelper 规则，
只从整卷导入或人工题录产生。独立“成题”入口只用于追加或失败重试，不得成为首次建册的正常必经步骤。
若 credits 不足、网络中断或没有任何知识点能与原文精确绑定，已经成功持久化的册必须保留并显示
可恢复状态，不能谎报完整成功，也不能重复创建第二册。

题目生成时 `reviewPlanId` 和 `snapshotVersion` 均必填。PracticeService 必须以
`X-Service-Name: PracticeService` 经 Gateway 读取现有 PlanGraph，并校验 `ownerUserId`、
`graphId`、`status=OPEN` 和不可变 snapshot 均与当前项目一致。服务直接复用 PlanGraph 已有的
`title/summary/tags/weight/coversPointIds`，不新增另一套选点接口，也不得只保留 point ID 后猜测语义。
`targetCount` 范围 1-200。相同所有者、项目和
`idempotencyKey` 必须返回同一任务；载荷不同则返回 `409 IDEMPOTENCY_KEY_REUSED`。

自动绑定采用“知识点先行、原文后成题”，禁止按数组下标、题目序号或随机数轮换贴标签：

1. 按 PlanGraph 已冻结的目标顺序处理 `questionTarget=true` 的知识点；
2. 在项目规范化原文中先查找知识点标题的规范化精确命中；没有标题命中时，只允许使用当前
   PlanGraph 中唯一且长度足够的精确标签；
3. 题目由命中的知识点与原文片段共同生成，保存对应 `knowledgePointId` 与 `SourceReference`；
4. 没有可信原文时不生成、不贴签，并记录 `KNOWLEDGE_POINT_SOURCE_NOT_FOUND`；不得为了凑足
   `targetCount` 把无关段落绑定到该点；
5. 当前 `recite-question-v1` 是确定性原文模板生成器：只有题目、答案、唯一主知识点和精确
   `SourceReference` 同时成立才创建，成功结果直接为 `READY`，以恢复 ReciteHelper “立册即有题”
   的业务语义。未来接入不能满足上述机械校验的模型输出必须先为 `DRAFT`，经用户核对后才能
   `READY`。图谱项目中的 `READY` 题目必须有且只有一个主知识点；多知识点复合题应拆题或人工选择主知识点。

本版本在没有经过标注集校准前，不使用 SBERT 模糊匹配自动写入标签。将来若启用，接受阈值与
第一/第二候选间隔必须由带真值的标注集给出，并冻结算法版本；不能拍脑袋设置混合权重或阈值。

```ts
type PracticeJob = {
  jobId: UUID;
  projectId: UUID;
  kind: "QUESTION_GENERATION" | "EXAM_IMPORT";
  status: "QUEUED" | "RUNNING" | "SUCCEEDED" | "PARTIALLY_SUCCEEDED" | "FAILED";
  progress: number;             // [0, 1]
  createdCount: number;
  diagnostics: Array<{
    materialId: UUID | null;
    code: string;
    message: string;
    retryable: boolean;
  }>;
  createdAt: Timestamp;
  startedAt: Timestamp | null;
  finishedAt: Timestamp | null;
};
```

生成模型只能得到本次项目的规范化文本、选中 PlanGraph 的知识点和固定提示词；返回 JSON
必须经过 schema 校验。模型输出不得作为 HTML、脚本、查询或可执行代码运行。

### 14.4 练习、判分与证据

```json
POST /api/v1/practice-sessions
{
  "projectId": "a81a657a-50e4-44bb-8bb7-3a48ff4cc2a0",
  "mode": "SMART_REVIEW",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620",
  "questionCount": 20,
  "kinds": [],
  "durationSeconds": null,
  "seed": 173344521
}
```

`mode` 为 `RANDOM | SMART_REVIEW | EXAM`。`SMART_REVIEW` 必须提供 plan 和 snapshot；
`EXAM` 还必须提供 `examPaperId`，且组卷和会话均须携带同一个 plan/snapshot。产品 UI 暴露的
章节练习、智能复习和模拟试卷全部使用带计划的计分会话，完成后均写回 mastery；`RANDOM` 只为
无图谱旧项目兼容保留，不得在 UI 中宣称会更新掌握度。服务端保存最终题目 ID 与顺序，重取会话
不得重新随机。

PracticeService 不重新实现“SM-2 多少百分比 + 图谱多少百分比”的混合分。知识点选择完整复用
第 6.6 节 `assessment-planner-v1`：SM-2 的 `nextReviewAt` 先形成到期集合，图谱最大乘积路径形成覆盖关系，
再由单调次模覆盖的真实边际收益选出目标点。题目层严格按 PlanGraph 目标顺序取题；每个目标点
在一次会话中最多取一道 READY 题，同点多题只用 seed 做可重放的确定性择一。任一目标点没有
READY 题时返回 `422 QUESTION_COVERAGE_GAP` 并列出缺失 point ID，不得换成计划外题目。这样既
避免重复知识点证据，也满足 KnowledgeService 对单次提交 `knowledgePointId` 唯一性的校验。

```ts
type PracticeAnswerResult = {
  attemptId: UUID;
  questionId: UUID;
  correct: boolean;
  similarity: number | null;    // [0,1]，主观题使用
  quality: number;              // [0,5]
  awardedScore: number;
  responseTimeMs: number;
  answerJudgeVersion: string;
  answeredAt: Timestamp;
};
```

答案保存请求包含 `answer: string | string[]`、`responseTimeMs`、`attemptNumber` 和
`idempotencyKey`。单选、填空、判断使用确定性规则；名词解释和简答使用本地语义模型与
确定性兜底。模型不可用时 `answerJudgeVersion` 必须显示降级算法，响应 `meta` 中加入
`degraded: true`，不能静默冒充 ONNX 判分。

完成会话时 PracticeService 将每题映射为第 6.4 节已经冻结的
`KnowledgeAnswerEvidence`，并复用：

```text
PUT /internal/v1/review-evidence/{resultId}
X-Service-Name: PracticeService
```

PracticeService 语义下：`packageId = questionBankId`，`sessionId = practiceSessionId`。
KnowledgeService 必须同时允许 `RenderService` 与精确大小写的 `PracticeService` 调用证据
端点；PlanGraph 读取必须同时允许 `GalGameService` 与 `PracticeService`。除此之外的服务名
返回 `403 FORBIDDEN`。这只是扩展调用方 allowlist，不改变 mastery、SM-2、plan snapshot 和
结果幂等规则。

### 14.5 错题帮助

帮助响应只包含当前用户项目中的证据：

```ts
type QuestionHelp = {
  questionId: UUID;
  matches: Array<{
    knowledgePointId: UUID | null;
    title: string;
    excerpt: string;
    sourceReference: SourceReference;
    similarity: number;
  }>;
  generatedExplanation: string | null;
  grounded: boolean;
  generatorVersion: string | null;
};
```

请求的 `generateExplanation` 默认 `false`。为 `true` 时也只能以 `matches` 为上下文；无匹配
证据时必须返回 `generatedExplanation: null, grounded: false`，不得让模型自由补写答案。

### 14.6 整卷、项目包和共享资源安全

- 整卷导入只接受 FileService 中属于当前用户且状态为 `READY` 的 material ID；导入结果
  必须为 `DRAFT` 并返回无法确定答案、题型或分值的诊断。
- `.rhproj` 为 UTF-8 JSON；`.rhp` 与新版包为 ZIP。导入限制：原始包不超过 50 MiB、最多
  2000 个条目、解压后不超过 200 MiB、单条目不超过 20 MiB。
- 包导入使用 `multipart/form-data`，字段 `file` 为包内容，`materialIds` 为 1-20 个重复 UUID
  字段。导入方必须把旧题库映射到自己已有的 READY material；包内旧绝对路径和他人的
  material ID 不获得权威性，也不能据此复制 FileService 数据所有权。
- ZIP 条目路径必须规范化；绝对路径、盘符、UNC、`..`、符号链接和重复规范化路径一律
  返回 `422 PACKAGE_ENTRY_UNSAFE`。
- 新包 manifest 的 `schemaVersion` 固定为 `qzwl-practice-package-1.0`，包含内容 SHA-256；
  导入时逐项校验。旧包记录 `importedFromSchema`，但内部保存时仍转换为当前类型。
- 发布创建不可变版本；`visibility` 为 `PRIVATE | UNLISTED | PUBLIC`。只有所有者可发布、
  撤下；搜索只返回 `PUBLIC` 或当前用户拥有的包。

### 14.7 Gateway 路由与部署

- `/api/v1/practice-projects`、`/api/v1/practice-questions`、
  `/api/v1/practice-sessions`、`/api/v1/exam-import-jobs`、
  `/api/v1/practice-packages` 和 `/api/v1/shared-practice-packages` 归 PracticeService。
- 题库生成、整卷导入和解释生成的 `POST` 使用 `generation` 限流；包导入使用 `upload`
  限流和上传超时；其余使用 `general`。
- 默认本机端口 `5107`，MongoDB 数据库 `qzwl_practice`。
- Gateway 配置键为 `PRACTICE_SERVICE_URL`、`PRACTICE_SERVICE_KEY`；服务到 Gateway 的
  配置为 `Gateway__BaseUrl`、`Gateway__ServiceName=PracticeService`、
  `Gateway__ServiceKey`。
- 生产 readiness 默认包含 PracticeService；模型降级不使 `/healthz` 失败，但 `/readyz`
  必须在响应数据中列出每个模型的 `READY | MISSING | HASH_MISMATCH | LOAD_FAILED`。

### 14.8 错误码

| code | HTTP | 场景 |
|---|---:|---|
| `PROJECT_MATERIALS_REQUIRED` | 400 | 项目没有资料 |
| `QUESTION_KIND_UNSUPPORTED` | 400 | 未知题型 |
| `QUESTION_ANSWER_INVALID` | 422 | 答案形状与题型不匹配 |
| `PLAN_REQUIRED` | 400 | 智能复习缺 plan/snapshot |
| `PROJECT_GRAPH_REQUIRED` | 422 | 项目未绑定图谱却请求自动成题或图谱复习 |
| `PROJECT_PLAN_GRAPH_MISMATCH` | 409 | PlanGraph 与项目绑定图谱不一致 |
| `PLAN_TARGETS_EMPTY` | 422 | PlanGraph 没有可出题目标 |
| `KNOWLEDGE_POINT_SOURCE_NOT_FOUND` | 任务诊断 | 知识点没有可信原文，拒绝自动出题/贴签 |
| `QUESTION_BINDING_REQUIRED` | 422 | 图谱项目的正式题目缺少主知识点 |
| `QUESTION_COVERAGE_GAP` | 422 | 计划目标知识点在正式题库中缺题 |
| `DUPLICATE_KNOWLEDGE_POINT` | 422 | 同一计分会话重复选择同一知识点 |
| `SESSION_NOT_ACTIVE` | 409 | 向非活动会话作答 |
| `SESSION_ALREADY_COMPLETED` | 409 | 完成状态冲突但幂等键不匹配 |
| `MODEL_UNAVAILABLE` | 503 | 调用方明确要求模型且不能降级 |
| `PACKAGE_SCHEMA_UNSUPPORTED` | 422 | 无法迁移的项目包版本 |
| `PACKAGE_ENTRY_UNSAFE` | 422 | ZIP 路径或解压限制违规 |
| `VERSION_CONFLICT` | 409 | 题目乐观并发冲突 |

未列错误继续使用第 2.4 节公共错误码，禁止用 `200` 包裹失败。

## 15. CreditService（credits 计费）

CreditService 是 credits、兑换码、预授权和扣费账本的唯一事实所有者。注册不再要求邀请码；
新注册用户在注册事务链中创建 credits 账户并获得 `1 credit`。在 CreditService 上线前已经存在
的用户，会在首次读取余额、兑换或生成预授权时幂等补建账户并获得一次初始额度，重复调用不
得重复赠送。AuthService 的资料/credits 建账与失败补偿不使用浏览器断开令牌；客户端中断不能
把凭证、资料和 credits 留在半完成状态。

### 15.1 用户与管理员接口

| 方法 | Gateway 路由 | 用途 | 状态 |
|---|---|---|---|
| `GET` | `/api/v1/credits/balance` | 读取总余额、可用余额和预授权占用 | `200/401/503` |
| `POST` | `/api/v1/credits/redemptions` | 使用兑换码增加 credits | `200/400/401/422/503` |
| `GET` | `/api/v1/admin/credit-codes` | 管理员读取兑换码状态，最多返回最近 5000 条 | `200/403/503` |
| `POST` | `/api/v1/admin/credit-codes/batches` | 批量生成 1 至 1000 个兑换码 | `201/400/403/503` |
| `DELETE` | `/api/v1/admin/credit-codes/{codeId}` | 撤销尚未兑换的兑换码 | `204/403/404/503` |

```ts
interface CreditBalance {
  userId: Uuid;
  balance: number;
  available: number;
  held: number;
  updatedAt: DateTime;
}

interface RedeemCreditRequest { code: string; }

interface CreateCreditCodeBatchRequest {
  count: number;             // 1..1000
  creditsPerCode: number;    // > 0，最多 5 位小数
  expiresAt?: DateTime;
}

type CreditCodeStatus = "ACTIVE" | "REDEEMED" | "REVOKED" | "EXPIRED";
interface AdminCreditCode {
  codeId: Uuid;
  code: string;              // 创建响应返回完整值；后续列表仅返回掩码和末 6 位
  credits: number;
  status: CreditCodeStatus;
  redeemedBy: Uuid | null;
  redeemedAt: DateTime | null;
  expiresAt: DateTime | null;
  createdAt: DateTime;
}
```

credits 的常规获得方式只有兑换码兑换；购买页只负责购买兑换码，不直接修改账户。用户确认
前往购买后，前端跳转 `https://pay.ldxp.cn/shop/7CX09W5E`。除首次赠送外，业务服务、前端和
管理员均不得直接增减某个账户余额。完整兑换码只在创建响应中出现一次，持久化只保存
SHA-256 摘要与后缀；兑换、过期、撤销统一返回稳定错误 `REDEMPTION_CODE_UNAVAILABLE`，
避免泄露兑换码存在性。

### 15.2 内部计量、预授权和实际结算

内部计量基线固定为 `1 credit = 100,000 token units`。该换算仅供服务端计算和本契约实现者
使用，禁止在面向用户的页面、提示、营销文字或公开响应字段中展示 token 换算规则；用户只
看到 credits 数值。

| 方法 | INTERNAL 路由 | 调用方 | 用途 |
|---|---|---|---|
| `POST` | `/internal/v1/credits/accounts` | AuthService | 幂等创建账户与初始额度 |
| `DELETE` | `/internal/v1/credits/accounts/{userId}` | AuthService | 仅注册补偿阶段删除未投入使用的账户 |
| `POST` | `/internal/v1/credits/reservations` | PracticeService、GalGameService | 生成前按保守估算预授权 |
| `POST` | `/internal/v1/credits/reservations/{operationId}/settlement` | PracticeService、GalGameService | 成功后按实际使用量结算 |
| `POST` | `/internal/v1/credits/reservations/{operationId}/release` | PracticeService、GalGameService | 失败或无产物时释放预授权 |

`operationId` 同时是计费幂等键。相同键、用户、操作类型和估算重复预授权必须返回原结果；
相同键复用于其他参数返回 `409 IDEMPOTENCY_KEY_REUSED`。预授权只增加 `held`，不立即减少
`balance`；成功结算原子地释放对应 held、按实际值减少 balance 并写入账本；失败或无有效
产物必须释放。结算与释放重复调用均为幂等。

当前计费操作如下：

- `PRACTICE_GENERATION`：PracticeService 生成复习项目题目。生成前按资料文本与目标题数
  估算，成功后按实际输入和已生成题目内容结算。
- `GAME_GENERATION`：GalGameService 从同一 PlanGraph 生成视觉小说复习。生成前按图谱上下文、
  提示固定开销、最大输出、最多草稿次数与供应商重试次数估算，成功后使用模型供应商返回的 `usage.total_tokens`（含已消费但
  未通过响应内容/schema 校验的供应商重试与草稿尝试）结算。供应商成功响应缺少有效 usage
  时按上游契约错误终止并释放预授权，不猜测实际值。确定性 Mock 未调用模型时实际使用量为 0。

余额小于预估值时，CreditService 返回 `402 CREDITS_INSUFFICIENT`，details 固定包含
`balance`、`required` 和 `purchaseUrl`。前端只显示当前/所需 credits，并询问是否前往购买；
不得自动跳转或把内部 token units 展示给用户。若实际值超过预估但扣除其他 held 后余额仍足，
按实际值结算；余额不足则返回 `409 CREDIT_ESTIMATE_EXCEEDED` 并保留待核对状态，禁止产生
负余额。

### 15.3 数据、删除与部署约束

- MySQL 数据库为 `qzwl_credit`；表为 `credit_accounts`、`credit_redemption_codes`、
  `credit_reservations`、`credit_ledger`。余额与 held 使用整数内部单位，避免浮点误差。
- 用户正常注销或管理员删除账户时，认证资料可以删除，但已发生的 credits 账本与兑换审计
  予以保留，不能由跨服务级联删除；`DELETE /internal/v1/credits/accounts/{userId}` 只允许注册
  尚未完成时执行补偿。
- 默认本机端口 `5108`；Gateway 配置为 `CREDIT_SERVICE_URL`、`CREDIT_SERVICE_KEY`，生产
  readiness 包含 `creditService`。
- 管理员列表只返回掩码，不提供兑换码明文恢复接口；撤销只允许 `ACTIVE` 状态。
