# 千知万理 API 接口规范与数据契约

> 版本：v0.1  
> 状态：Draft / 各服务负责人待确认  
> 总负责人：PM & TL `@Arabidopsis`  
> 更新时间：2026-07-29
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
- `OWNER-TBD`：具体细节由服务负责人在正式编码前确认。
- `P1`：不阻塞首个端到端闭环，可在黑客松时间不足时延后。
- `INTERNAL`：只能由服务身份通过 API Gateway 调用，不向浏览器公开。

## 0.1 服务与负责人

| 模块 | 负责人 | 本文覆盖 | 最终设计责任 |
|---|---|---|---|
| UserService | `@Sleexy` | 用户资料与偏好 | 字段、校验、持久化与迁移 |
| AuthService | `@Sleexy` | 注册、会话、令牌、密码恢复、管理员账号治理与邀请码 | 凭证模型、令牌策略、管理员边界与安全实现 |
| FileService | `@Sleexy` | 上传、GridFS、解析任务与内容访问 | 文件限制、解析器与存储实现 |
| KnowledgeService | `@Arabidopsis` | 图谱、知识点、关系、复习计划与掌握度 | 图谱模型、抽取策略与 Neo4j 查询 |
| GalGameService | `@F15EX` | 游戏生成任务、游戏包与 schema | 生成流程、剧情结构与兼容策略 |
| RenderService | `@Zopiclone` | 复习会话、进度、结果和 WASM 运行时 | C++ / WASM API 与状态机 |
| Frontend / WASM Adapter | `@甲烷` | JS 桥接、页面调用与错误展示 | 前端适配器和运行时集成 |
| API Gateway | `@甲烷` | 路由、鉴权、错误、CORS 与链路头 | Gateway 策略与部署配置 |

### 0.2 当前持久化基线

- **UserService 的数据库为 MySQL**：仅持久化用户展示资料、学习偏好及其关联数据。
- **AuthService 的数据库为 MySQL**：仅持久化凭证密码哈希、会话、令牌撤销状态、密码恢复记录、管理员账号治理、邀请码与管理员审计记录。
- 同一业务事实只能由一个服务及其权威数据库写入；禁止 AuthService 与 UserService 互相直连或读写对方的 MySQL 数据表。
- 后续引入 MongoDB 时，应由对应业务服务独占其文档型数据；不得将上述账户与用户资料数据在 MySQL、MongoDB 中双写作为两个权威来源。

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
| `X-Service-Name` | INTERNAL | 仅允许 Gateway 注入，客户端同名头必须被丢弃 |

### 2.2 公共数据类型

```ts
type Uuid = string;       // UUID v4，输出小写
type DateTime = string;   // ISO 8601 UTC，例如 2026-07-27T08:30:00Z
type Uri = string;        // Gateway 控制地址、相对地址或短期签名地址
type Sha256 = string;     // 64 位小写十六进制
type Cursor = string;     // 不透明分页游标，调用方不得解析
type SubjectCode = string;// 学科代码，由 KnowledgeService 维护
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
| `422` | 语法正确但业务规则不满足 | `BUSINESS_RULE_VIOLATION` |
| `429` | 超过限流 | `RATE_LIMITED` |
| `500` | 服务内部错误 | `INTERNAL_ERROR` |
| `503` | 服务或依赖暂不可用 | `SERVICE_UNAVAILABLE` |

## 3. UserService

> 负责人：`@Sleexy`  
> 拥有：用户资料、偏好与资料更新时间。  
> 不拥有：密码、刷新令牌、图谱、游戏包和复习结果。  
> 数据库：MySQL

### 3.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/internal/v1/users` | 注册后创建用户资料 | `CreateUserProfileRequest` | `UserProfile` | `201/409` |
| `POST` | `/internal/v1/users/profile-lookups` | 管理员查询认证账户对应的展示名 | `AdminProfileLookupRequest` | `AdminProfileSummary[]` | `200/400/403` |
| `DELETE` | `/internal/v1/users/{userId}` | 管理员删除用户资料与偏好 | - | - | `204/400/403/404` |
| `GET` | `/api/v1/users/me` | 读取当前用户资料 | - | `UserProfile` | `200/401` |
| `PATCH` | `/api/v1/users/me` | 部分更新资料 | `UpdateUserProfileRequest` | `UserProfile` | `200/400` |
| `GET` | `/api/v1/users/me/preferences` | 读取学习与显示偏好 | - | `UserPreferences` | `200/401` |
| `PUT` | `/api/v1/users/me/preferences` | 幂等替换偏好 | `UserPreferencesInput` | `UserPreferences` | `200/422` |

### 3.2 数据类型

```ts
interface CreateUserProfileRequest {
  userId: Uuid;           // AuthService 生成
  displayName: string;    // 1-64 字符，禁止纯空白
  locale?: string;        // 默认 zh-CN
}

interface AdminProfileLookupRequest {
  userIds: Uuid[];       // 最多 500 个；仅 AuthService 可经 Gateway 调用
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
- [ √ ] 账户注销是否进入首版。用户调用 `DELETE /api/v1/auth/account` 并输入当前登录密码确认后，AuthService 经 Gateway 删除 UserService 的资料与偏好，再删除认证凭证、会话、密码恢复记录及认证侧关联数据；操作立即生效且不可恢复。

## 4. AuthService

> 负责人：`@Sleexy`  
> 拥有：凭证、会话、访问令牌、刷新令牌、撤销状态、管理员会话和邀请码。  
> 不拥有：用户展示资料、学习偏好和学习业务数据。  
> 数据库：MySQL

### 4.0 管理员模块边界（BASELINE）

管理员能力是 AuthService 的内部模块，当前不单独部署 Admin Service：

- AuthService 负责管理员登录、管理员会话、用户凭证治理（重置密码、撤销会话、删除认证账户）和邀请码管理。
- UserService 仍拥有用户展示资料与偏好。管理员操作如需影响该服务的数据，必须经 Gateway 调用对应的 `/internal/v1/...` 接口；禁止 AuthService 直接读取或修改 UserService 数据库。
- 浏览器只可通过 Gateway 的 `/api/v1/admin/...` 路由访问管理员接口。Gateway 验证 Access Token 并注入可信身份上下文，AuthService 最终判定管理员权限。
- 管理员默认凭据只能用于本地开发，禁止进入浏览器代码、日志、提交到版本控制的生产配置或公开文档。
- 删除用户与重置密码属于高风险操作。生产上线前必须具备可检索的审计记录，至少包含操作者、目标用户、操作类型、结果、时间与 `traceId`。审计表结构为 `OWNER-TBD`。
- 当后台扩展为内容审核、运营、跨服务报表或多角色权限体系时，再评估拆分独立 Admin Service。

### 4.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/auth/registrations` | 校验邀请码后创建凭证和初始会话 | `RegistrationRequest` | `AuthSessionResponse` | `201/400/409/422/503` |
| `POST` | `/api/v1/auth/sessions` | 邮箱与密码登录 | `LoginRequest` | `AuthSessionResponse` | `201/401` |
| `GET` | `/api/v1/auth/sessions/{sessionId}` | 读取会话状态 | - | `AuthSession` | `200/404` |
| `DELETE` | `/api/v1/auth/sessions/{sessionId}` | 退出并撤销会话 | - | - | `204/404` |
| `POST` | `/api/v1/auth/tokens` | 刷新访问令牌 | `RefreshTokenRequest` | `TokenPair` | `201/401` |
| `POST` | `/api/v1/auth/password-reset-requests` | 请求密码恢复 | `PasswordResetRequest` | - | `202/404` |
| `POST` | `/api/v1/auth/password-resets` | 重设密码 | `PasswordResetConfirmation` | - | `204/422` |
| `POST` | `/api/v1/auth/password-changes` | 当前用户修改密码 | `PasswordChangeRequest` | - | `204/400/401` |
| `DELETE` | `/api/v1/auth/account` | 当前用户输入密码后永久注销账户 | `AccountDeletionRequest` | - | `204/400/401/403/404/503` |
| `POST` | `/internal/v1/auth/introspections` | 查询令牌状态 | `TokenIntrospectionRequest` | `TokenIntrospection` | `200/401/P1` |

### 4.1.1 管理员接口（BASELINE）

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/admin/sessions` | 管理员用户名密码登录 | `AdminLoginRequest` | `AuthSessionResponse` | `201/401` |
| `GET` | `/api/v1/admin/users` | 列出已注册用户 | - | `AdminUser[]` | `200/403` |
| `DELETE` | `/api/v1/admin/users/{userId}` | 删除用户认证账户及其关联认证数据 | - | - | `204/403/404` |
| `POST` | `/api/v1/admin/users/{userId}/password` | 管理员重置用户密码并撤销会话 | `AdminPasswordResetRequest` | - | `204/400/403/404` |
| `GET` | `/api/v1/admin/invitations` | 列出邀请码 | - | `AdminInvitation[]` | `200/403` |
| `POST` | `/api/v1/admin/invitations` | 创建邀请码 | `CreateInvitationRequest` | `AdminInvitation` | `201/400/403` |
| `DELETE` | `/api/v1/admin/invitations/{code}` | 删除未使用或不再需要的邀请码 | - | - | `204/403/404` |

### 4.2 数据类型

```ts
interface RegistrationRequest {
  email: string;
  password: string;
  displayName: string;
  invitationCode: string; // 必填；由管理员生成，忽略首尾空白并按大写校验
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

type InvitationType = "single-use" | "multi-use" | "time-window";

interface CreateInvitationRequest {
  type: InvitationType;
  maxUses?: number;        // single-use 固定为 1；multi-use 必填
  validFrom?: DateTime;    // 仅 time-window 使用
  validTo?: DateTime;      // 仅 time-window 使用，且必须晚于 validFrom
}

interface AdminInvitation {
  code: string;
  type: InvitationType;
  maxUses: number;
  usedCount: number;
  validFrom: DateTime | null;
  validTo: DateTime | null;
  createdAt: DateTime;
}

邀请码注册规则：

- `single-use` 只能成功注册一次；`multi-use` 成功次数不得超过 `maxUses`；`time-window` 仅在 `validFrom` 至 `validTo`（含边界）期间有效。
- AuthService 必须在创建凭证的同一数据库事务中锁定邀请码、校验可用性并递增 `usedCount`，避免并发超额使用。
- 若后续创建用户资料或会话失败，AuthService 必须删除本次凭证并归还邀请码使用次数。
- 无效、过期或已用尽的邀请码返回 `422 BUSINESS_RULE_VIOLATION`；邀请码不得出现在日志中。

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
  | Access Token | 15 分钟 | 用于访问受保护接口 |
  | Refresh Token | 7 天 | 用于刷新访问令牌 |
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
| `POST` | `/api/v1/materials` | 上传复习资料 | `multipart MaterialUploadForm` | `Material` | `201/413/415` |
| `GET` | `/api/v1/materials` | 分页查询当前用户资料 | Query | `MaterialPage` | `200/400` |
| `GET` | `/api/v1/materials/{materialId}` | 读取资料元数据 | - | `Material` | `200/404` |
| `DELETE` | `/api/v1/materials/{materialId}` | 删除或标记删除 | - | - | `204/409` |
| `POST` | `/api/v1/materials/{materialId}/ingestion-jobs` | 创建解析任务 | `CreateIngestionJobRequest` | `IngestionJob` | `202/409` |
| `GET` | `/api/v1/ingestion-jobs/{jobId}` | 查询解析进度 | - | `IngestionJob` | `200/404` |
| `POST` | `/api/v1/materials/{materialId}/access-grants` | 创建短期内容授权 | `CreateAccessGrantRequest` | `AccessGrant` | `201/403` |
| `GET` | `/internal/v1/materials/{materialId}/content` | 服务读取原始内容流 | `Range?` | Binary stream | `200/206/404` |
| `GET` | `/internal/v1/materials/{materialId}/extracted-text` | **URGENT（跨服务阻塞项）** 服务读取规范化纯文本及来源映射 | - | `ExtractedTextDocument` | `200/403/404/409/422` |

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
  parserVersion?: string;
  force?: boolean; // 默认 false
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
  createdAt: DateTime;
}

interface TextSourceSpan {
  startOffset: number;          // int64，基于规范化 text 的 UTF-16 code unit，0-based
  endOffset: number;            // int64，半开区间 [startOffset, endOffset)
  pageNumber: number | null;    // PDF/DOCX 可识别页码时从 1 开始
  paragraphIndex: number | null;// 可识别段落时从 0 开始
  sourceLabel: string | null;   // 例如“第 3 页”“幻灯片 8”；不得替代 offset
}
```

### 5.2.1 **URGENT（跨服务阻塞项）** 纯文本交付基线

FileService 必须在最新 `IngestionJob.status="SUCCEEDED"` 后，将 `Material.status` 原子地推进到 `READY`，随后才允许返回 `ExtractedTextDocument` 并发布 `MaterialTextReady v1`。具体规则已经冻结：

- `text` 必须为 UTF-8 可表示的 Unicode 纯文本；先统一为 NFC，再把 `CRLF`/`CR` 统一为 `LF`。禁止把原始 PDF、DOCX、OCR JSON、HTML、Markdown 或 base64 放进 `text`。
- `textChecksum` 对上述规范化结果的精确 UTF-8 字节计算 SHA-256；`textLength` 与所有 offset 均按规范化字符串的 UTF-16 code unit 计数，与 JavaScript/.NET `string.length` 一致。FileService 若使用 Python/Go 等 Unicode 标量索引实现，必须在边界处显式转换。
- `sourceMap` 必须按 `startOffset` 升序、不得重叠、不得越界。解析器无法恢复页码或段落时，对应字段使用 `null`，但 offset 仍为必填。
- `parserVersion`、`sourceMapVersion`、`textChecksum` 是 KnowledgeService 构建幂等键的一部分；同一解析版本重试必须产生相同文本、checksum 和 source map。
- 资料尚未 `READY` 时返回 `409 MATERIAL_TEXT_NOT_READY`；最新解析明确失败时返回 `422 MATERIAL_TEXT_EXTRACTION_FAILED`；调用身份不是经 Gateway 注入的受信服务身份时返回 `403 FORBIDDEN`。
- 响应可使用统一 JSON 成功信封；无论传输包装为何，`text` 字段本身只能是上述纯文本。
- KnowledgeService 只经 Gateway 使用本端点或事件中的 `contentRef` 读取文本，不读取 FileService 数据库，也不把 PDF/DOCX 解析逻辑作为正常生产路径。

本小节及 `MaterialTextReady v1` 是 KnowledgeService 开工和联调的 **URGENT（跨服务阻塞项）**；由 FileService 负责人实现，KnowledgeService 不代为实现。

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

### 5.4 OWNER-TBD

- [ ] 首批 MIME 类型；
- [ ] 单文件大小；
- [ ] OCR 是否进入 MVP；
- [ ] 解析器版本与失败重试策略；
- [ ] 软删除或物理删除；
- [ ] GridFS bucket 和备份策略。

## 6. KnowledgeService

> 负责人：`@Arabidopsis`  
> 拥有：KnowledgeGraph、Chapter、KnowledgePoint、KnowledgeRelation、ReviewPlan、MasteryRecord 和复习结果幂等回执。
> 不拥有：原始文件、游戏包和浏览器运行状态。
> 权威数据库：Neo4j。

### 6.0 边界与 Neo4j 分层模型（BASELINE）

KnowledgeService 只接收 FileService 已规范化的纯文本，先建立章节层级，再在章节内抽取知识点和依赖。首版 Neo4j 逻辑模型固定为：

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

- `KnowledgeGraph`、`Chapter` 和 `KnowledgePoint` 均属于一个不可变图谱版本；READY 图的内容不得原地改写，唯一允许的生命周期变化是 `READY -> SUPERSEDED` 状态迁移。
- `Chapter` 是上层层级节点，允许父子章节；`KnowledgePoint` 是下层叶级知识节点，并且必须有且只有一个主 `chapterId`。
- `MASTERY` 关系按 `(userId, pointId)` 唯一，不能作为所有用户共享的 `KnowledgePoint` 属性。API 中 `KnowledgePoint.mastery` 是针对当前受信用户投影出的值。
- KnowledgeService 可以保存 `userId` 外键值用于隔离数据，但不得复制用户展示名、邮箱或认证事实。
- UUID、图版本、关系端点、ownerUserId 和 plan snapshot 必须由唯一约束或事务校验保护。服务启动时应幂等建立所需 Neo4j constraints/indexes。

跨服务联调阻塞项（均不由 KnowledgeService 实现）：

- **URGENT（FileService / Gateway）**：实现 5.2.1 的规范化纯文本读取、服务身份转发及稳定错误码；未满足时只能测试本服务的纯函数与 mock client，不能完成真实资料构图。
- **URGENT（GalGameService）**：按 `reviewPlanId + snapshotVersion` 读取 6.3 的不可变 PlanGraph，把 `questionTarget`/学习目标转成题目和剧情；不得自行重算知识点权重。
- **URGENT（RenderService / GalGameService）**：按 6.4 提交 `ReviewCompleted v2`/INTERNAL evidence，保留 `resultId`、`idempotencyKey`、`completedAt` 和逐知识点证据；否则 KnowledgeService 不得猜测掌握度。
- **URGENT（Gateway）**：剥离外部伪造的 `X-User-Id`、`X-Service-Name`，完成认证后重新注入可信 Header；KnowledgeService 只消费该内部信任边界。

### 6.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/knowledge-graph-builds` | 创建图谱构建任务 | `GraphBuildRequest` | `GraphBuildJob` | `202/409` |
| `GET` | `/api/v1/knowledge-graph-builds/{buildId}` | 查询构建任务 | - | `GraphBuildJob` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs?materialId=...` | 查询资料的图谱版本 | Query | `KnowledgeGraphPage` | `200/400` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}` | 读取图谱摘要 | - | `KnowledgeGraphSummary` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/chapters` | 读取有序章节树 | - | `Chapter[]` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/points` | 分页读取知识点 | Query | `KnowledgePointPage` | `200/400` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/relations` | 分页读取关系 | Query | `KnowledgeRelationPage` | `200/400` |
| `GET` | `/api/v1/knowledge-points/{pointId}` | 读取知识点详情 | - | `KnowledgePoint` | `200/404` |
| `PATCH` | `/api/v1/knowledge-points/{pointId}` | 人工修正知识点 | `KnowledgePointPatch` | `KnowledgePoint` | `200/409/P1` |
| `POST` | `/api/v1/assessment-plans` | 生成少题量、依赖感知的全面测试图 | `CreateAssessmentPlanRequest` | `PlanGraph` | `201/422` |
| `POST` | `/api/v1/learning-plans` | 按上游指定章节生成加权学习图 | `CreateLearningPlanRequest` | `PlanGraph` | `201/422` |
| `GET` | `/api/v1/review-plans/{reviewPlanId}` | 当前用户读取计划摘要与图 | - | `PlanGraph` | `200/404` |
| `GET` | `/internal/v1/review-plans/{reviewPlanId}/graph` | GalGameService 读取不可变计划图 | `snapshotVersion` Query | `PlanGraph` | `200/403/404/409` |
| `PUT` | `/internal/v1/review-evidence/{resultId}` | 上游幂等提交学习证据并更新掌握度 | `ReviewEvidenceSubmission` | `MasteryUpdateReceipt` | `200/403/409/422` |
| `GET` | `/api/v1/mastery-records` | 查询当前用户掌握度 | Query | `MasteryPage` | `200/400` |

所有 `/api/v1` 资源均以 Gateway 注入的可信 `userId` 做 owner 校验；调用方传入的同名 JSON 字段或浏览器自造 Header 不得覆盖可信身份。INTERNAL 路由只接受 Gateway 注入的受信服务身份。

### 6.2 图谱构建与分层数据类型

```ts
type ChapterSegmentationMode =
  | "AUTO"
  | "HEADING_RULES"
  | "MARKDOWN"
  | "DELIMITER"
  | "FIXED_WINDOW";

interface GraphBuildRequest {
  materialId: Uuid;
  subjectHint?: SubjectCode;
  segmentationMode?: ChapterSegmentationMode; // 默认 AUTO
  delimiter?: string;                          // DELIMITER 模式必填
  minChapterCharacters?: number;               // 默认 120
  maxChapterCharacters?: number;               // 默认 60000
  fixedWindowCharacters?: number;              // 默认 8000
  extractorVersion?: string;                   // 默认 knowledge-extractor-v1
}

type JobStatus = "QUEUED" | "RUNNING" | "SUCCEEDED" | "FAILED";

interface GraphBuildJob {
  buildId: Uuid;
  materialId: Uuid;
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
  version: number; // int32，单调递增
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
  quote: string | null;         // 最多 500 字符的短摘录
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

- `AUTO` 先识别中文“第 X 章/节”、绪论、阿拉伯/罗马数字编号和强标题；显式结构不足时降级为句子/段落边界感知的固定窗口。`HEADING_RULES`、`MARKDOWN`、`DELIMITER` 可由调用方显式选择；`FIXED_WINDOW` 是确定性兜底。该多模式路由只借鉴 ReciteHelper 的“结构化/非结构化资料采用不同分支”思路，未复制其 AGPL-3.0 代码。
- 章节必须先于知识点生成。空标题忽略；重复标题通过父章节和 ordinal 区分；过长章节可产生子章节；不得为了窗口长度把一个段落切成两个来源不明的章节。
- `conceptKey` 在单个图版本内唯一；同一 `materialId` 的后续图版本识别为同一概念时稳定复用。它只用于版本对照和审计；首版不据此继承 mastery。
- 当 `type="PREREQUISITE"` 时，`fromPointId` 是基础/前置知识点，`toPointId` 是依赖它的上层知识点，即 Neo4j 中 `(from)-[:PREREQUISITE_OF]->(to)`；API 领域类型仍为 `PREREQUISITE`。
- 确定性规则抽取器只在“较早知识点标题词项被较晚知识点标题或摘要逐字提及”时提出前置边。设除候选知识点自身外共有 `N` 个文本块，其中 `df` 个提及该词项，则 `confidence = 1-(df+1)/(N+2)`；这是 Beta(1,1) 拉普拉斯平滑后的**词项特异度证据**，不是未经标注数据校准的“依赖正确概率”。标题/摘要位置、是否同章和词长不再通过任意系数混入。高频泛化词另由固定停用表排除，候选并列时按 ordinal、pointId 稳定排序，每个知识点最多保留 4 个规则候选；未来只有在独立标注集上完成校准并提升 extractorVersion 后，才可把模型概率写入该字段。
- PREREQUISITE 子图必须为有向无环图。抽取后若出现强连通分量，构建器按最低 confidence、再按 relationId 稳定排序移除最弱边并将其降级为 `RELATED`，直到 DAG 成立。
- `RELATED` 和 `CONTRASTS` 在领域语义上无方向；持久化时按 pointId 字典序采用唯一方向，API 不允许同一无向点对重复。
- 创建任务使用 `(ownerUserId, Idempotency-Key)` 做请求幂等；同一 key 携带不同参数返回 `409 IDEMPOTENCY_KEY_REUSED`。图谱内容另以 `(ownerUserId, materialId, sourceTextChecksum, segmenterVersion, extractorVersion, segmentationMode)` 做指纹去重；相同指纹返回既有 graph，不创建重复版本。文本 checksum 或算法版本变化才创建递增的新图版本。

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
  algorithmVersion: "sm2-graph-v1";
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

新图版本及首次读取的默认 mastery 固定为：

```text
score=0, repetitions=0, easinessFactor=2.5, intervalDays=0,
nextReviewAt=KnowledgeGraph.createdAt, lastReviewedAt=null, lapses=0,
reason="INITIAL", version=0
```

即使新版本中的 `conceptKey` 与旧版本相同，也必须从 0 开始；首版禁止静默继承或合并旧图 mastery。
图谱进入 READY 的同一事务必须为 `ownerUserId` 的每个知识点建立上述初始 `MASTERY` 关系；读取时若因修复或历史数据缺少状态，仍按同一默认值投影，禁止返回 `null`，持久化补建由独立修复任务完成。

`sm2-graph-v1` 对直接作答知识点执行：

```text
observedScore = quality / 5 * 100
score' = round(clamp(0, 100, score * 0.65 + observedScore * 0.35))

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

质量映射固定为：完全错误 `0`；错误但有有效部分证据 `1-2`；正确但使用提示、重试或明显不流畅 `3`；首次正确但较慢 `4`；首次正确且无提示、流畅完成 `5`。KnowledgeService 校验 `correct=false` 时 `quality` 不得高于 2、`correct=true` 时不得低于 3；`scoreDelta` 属于游戏计分，不参与 mastery。

依赖推断规则：

- 直接作答只强更新被测试的 `knowledgePointId`，并只对该点推进 SM-2 调度。
- 只有 ASSESSMENT 计划中 `quality>=4`、正确且未使用提示的正证据可给最多 3 跳内的前置祖先增加弱推断分。令 `pathInfluence(a,q)` 使用 6.6 的最大乘积路径，`observedScore=quality/5*100`，则 `inferredDelta(a)=min(5, max(0, observedScore-score(a))*pathInfluence(a,q))`。同一会话有多道题、多条路径指向同一祖先时只取最大的**实际增量**，禁止求和；推断不改变祖先的 repetitions、interval 或 nextReviewAt。LEARNING 计划只更新上游明确提交直接证据的计划节点，不因“完成学习路径”自动推断祖先。
- 回答基础点正确不得自动提高任何依赖它的上层点；回答上层点错误不得批量降低其所有前置点。负证据只更新直接作答点，后续由 ASSESSMENT 计划下钻诊断。
- 若祖先已有晚于本次 `completedAt` 的直接复习记录，本次较旧的间接正证据对该祖先直接跳过；若直接作答点已有更晚记录，则整次提交按 `409 STALE_REVIEW_EVIDENCE` 拒绝。

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

遗忘风险：

```text
lastReviewedAt=null or score=0:
  risk(v)=1
otherwise:
  elapsed=max(0, now-lastReviewedAt(v)) in days
  stability=max(1, intervalDays(v))
  retention(v)=score(v)/100 * exp(log(0.9)*elapsed/stability)
  risk(v)=clamp(0,1,1-retention(v))
```

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
F(S) = Σ_v risk(v) * max_{q in S} influence(v,q)
```

`F` 是归一化、单调、次模函数。在题目成本相同且执行固定 `k` 轮时，按真实边际收益贪心相对最优 `k` 题集合具有经典 `1-1/e` 近似保证。若达到 `coverageTarget` 后提前停止，这一保证只相对实际已选题数的最优集合成立，不能冒充相对原 `maxQuestions` 预算最优解的保证。`max` 使重复题及共享前置点自然产生递减收益；同一 hub 无论连接多少候选，在每个被覆盖知识点上都不会被重复求和。

LEARNING 对请求章节目标集合 `T` 定义唯一的原始优先级：

```text
priority(v) = max_{t in T} risk(t) * influence(v,t)
```

因此 `0 <= priority(v) <= 1`，并且给 hub 新增更多上游目标只能改变 `max` 的取值，不能按出度线性放大。完整 path bundle 只有在整条路径同时满足 `maxPoints` 与外部节点数量约束时才可加入；选择过程使用下述独立覆盖目标，而 `priority(v)` 只作为入选节点的最终权重先验。这里不声称该带路径闭包问题的贪心达到全局最优，只保证以下可机械验证的不变量：节点上限、外部节点数量上限、每个外部节点到至少一个已选目标有有向路径、相同输入稳定输出。

为避免把“选哪些路径”和“最终节点权重”混成一个量，path bundle 选择另用覆盖函数。对通向目标 `t_b` 的完整路径束 `b`：

```text
g_b(v) =
  risk(t_b) * influence(v,t_b)  if v is on b
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

- `SubjectCode` 首版不是封闭枚举，必须匹配 `^[A-Z][A-Z0-9_]{0,31}$`；无法可靠分类时使用 `GENERAL`。真实样例允许的首批值至少包括 `GENERAL`、`AGRONOMY` 和 `BOTANY`。
- API 关系类型固定为 `PREREQUISITE`、`RELATED`、`CONTRASTS`；Neo4j 物理关系分别为 `PREREQUISITE_OF`、`RELATED_TO`、`CONTRASTS_WITH`，章节归属使用 `Chapter-[:HAS_POINT]->KnowledgePoint`。
- 长度上限：Chapter title 160、KnowledgePoint title 120、summary 4000、tags 最多 20 个且每个 1-40、SourceRef quote 240。超限抽取结果必须拒绝或确定性截断并记录 warning。
- 首版 `knowledge-extractor-v1` 为确定性规则抽取器，只接收已切分章节文本。未来若接入外部模型，也只能传当前章节、必要父标题和有限相邻上下文，不得发送其他用户资料；输出必须通过结构化 schema、offset、pointId 唯一性和 DAG 校验后才能入库。
- 算法版本首版冻结为：`chapter-segmenter-v1`、`knowledge-extractor-v1`、`graph-weight-v1`、`assessment-planner-v1`、`learning-planner-v1`、`sm2-graph-v1`、`PlanGraph schema 1.0`。
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
| `POST` | `/api/v1/game-generations` | 创建游戏包生成任务 | `GameGenerationRequest` | `GameGenerationJob` | `202/422` |
| `GET` | `/api/v1/game-generations/{generationId}` | 查询生成任务 | - | `GameGenerationJob` | `200/404` |
| `GET` | `/api/v1/game-packages/{packageId}` | 读取游戏包清单 | - | `GamePackageManifest` | `200/404` |
| `GET` | `/api/v1/game-packages/{packageId}/content` | 下载完整 JSON 游戏包 | `If-None-Match?` | JSON | `200/304/404` |
| `POST` | `/internal/v1/game-package-validations` | 校验游戏包 | `GamePackageValidationRequest` | `ValidationResult` | `200/422` |

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
  progress: number; // int32, 0-100
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
  scoreDelta: number;
  knowledgePointId: Uuid;
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

### 7.3.1 **URGENT（跨服务阻塞项）** PlanGraph 消费与证据绑定

GalGameService 在接受 `GameGenerationRequest` 后必须经 Gateway 调用
`GET /internal/v1/review-plans/{reviewPlanId}/graph?snapshotVersion=...`，并以返回的不可变 `PlanGraph` 为唯一知识输入：

- 不得仅凭 `KnowledgeGraphReady` 事件、客户端提交的 pointIds 或旧缓存生成游戏；缓存键至少包含 `reviewPlanId + snapshotVersion`。
- 请求中的 `snapshotVersion` 与 PlanGraph 不一致时停止生成并返回 `422 REVIEW_PLAN_SNAPSHOT_MISMATCH`。
- 只允许为 `PlanNode.questionTarget=true` 的节点生成计分题目；`PREREQUISITE` 和 `CONTEXT` 节点可以用于讲解，但不得在没有显式 question target 时伪造成掌握度证据。
- 每个可作答题必须生成稳定且在包内唯一的 `questionId`，同时绑定准确的 `knowledgePointId`；同一题的所有 Choice 使用相同 `questionId`。
- `GamePackageManifest` 和 `GamePackage` 必须保存 `reviewPlanId + snapshotVersion`。RenderService 回传的 questionId、pointId 和 snapshot 必须能据此校验。
- GalGameService 可以设计题面、选项和剧情，但不得修改 PlanNode.weight、依赖边、mastery snapshot 或 KnowledgeService 的知识事实。

本小节是 GalGameService 的 **URGENT（跨服务阻塞项）**；这里只冻结调用与数据义务，不由 KnowledgeService 实现 GalGameService。

### 7.4 最小游戏包 Mock

```json
{
  "schemaVersion": "1.0",
  "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
  "generatorVersion": "gala-0.1.0",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f",
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
          "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
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

### 7.5 OWNER-TBD

- [ ] `schemaVersion=1.0` 的完整 JSON Schema；
- [ ] 场景、对话和选择数量上限；
- [ ] 角色、音频和资源引用结构；
- [ ] 生成失败和部分成功语义；
- [ ] `generatorVersion` 与 seed 的可复现范围；
- [ ] 游戏包保存位置和清理策略。

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
| `POST` | `/api/v1/review-sessions` | 创建复习会话 | `CreateReviewSessionRequest` | `ReviewSession` | `201/422` |
| `GET` | `/api/v1/review-sessions/{sessionId}` | 读取会话和进度 | - | `ReviewSession` | `200/404` |
| `PUT` | `/api/v1/review-sessions/{sessionId}/progress` | 幂等保存进度 | `ProgressSnapshotInput` | `ProgressSnapshot` | `200/409` |
| `POST` | `/api/v1/review-sessions/{sessionId}/events` | 追加交互事件 | `InteractionEventBatch` | `EventReceipt` | `202/422` |
| `PUT` | `/api/v1/review-sessions/{sessionId}/result` | 幂等提交最终结果 | `ReviewResultInput` | `ReviewResult` | `200/409` |

### 8.2 REST 数据类型

```ts
interface RuntimeManifest {
  wasmVersion: string;
  supportedSchemaVersions: string[];
  wasmUrl: Uri;
  jsAdapterUrl: Uri;
  checksum: Sha256;
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
  answerResults: AnswerResult[];
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
- 没有 `reviewPlanId`、snapshot、questionId、quality 或时间证据的旧 `ReviewCompleted v1` 不足以更新 mastery；KnowledgeService 不得根据 v1 的 `scoreDelta` 猜测掌握度。

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
```

职责：

- `@Zopiclone`：C++ / WASM ABI、状态机、内存、渲染和序列化。
- `@甲烷`：JS Adapter、Gateway 调用、JSON 编解码、WASM 生命周期、错误提示和保存节流。

### 8.4 结果 Mock

```json
{
  "expectedProgressVersion": 4,
  "idempotencyKey": "eac9acb9-b96c-43a9-a6ff-6e7dfa885b09",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
  "snapshotVersion": "plan-graph-1.0:3da5f48f",
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

### 8.5 OWNER-TBD

- [ ] WASM 函数的内存所有权和字符串释放规则；
- [ ] `RuntimeState` schema；
- [ ] 保存进度的频率和最大尺寸；
- [ ] JS Adapter 与 WASM 的版本兼容策略；
- [ ] 页面刷新、断网和重复提交结果的恢复行为。

## 9. API Gateway 与前端

> 负责人：`@甲烷`  
> 拥有：路由、鉴权、CORS、限流、超时、错误映射和 JS API Client。  
> 不拥有：业务数据库和领域规则。

### 9.1 路由归属

| 路由前缀 | 目标服务 | 调用方 | 鉴权 |
|---|---|---|---|
| `/api/v1/users` | UserService | Browser | 用户令牌 |
| `/api/v1/auth` | AuthService | Browser | 登录和注册公开，其余按接口 |
| `/api/v1/admin` | AuthService | Browser（管理员后台） | 管理员登录公开，其余管理员令牌 |
| `/api/v1/materials`、`/api/v1/ingestion-jobs` | FileService | Browser | 用户令牌 |
| `/api/v1/knowledge-*`、`/api/v1/assessment-plans`、`/api/v1/learning-plans`、`/api/v1/review-plans`、`/api/v1/mastery-records` | KnowledgeService | Browser | 用户令牌 |
| `/api/v1/game-*` | GalGameService | Browser / Render | 用户令牌 |
| `/api/v1/render-runtime`、`/api/v1/review-sessions` | RenderService | Browser | 用户令牌；manifest 可公开缓存 |
| `/internal/v1/materials/*/extracted-text` | FileService | KnowledgeService | **URGENT（跨服务阻塞项）** 服务身份 |
| `/internal/v1/review-plans/*/graph`、`/internal/v1/review-evidence/*` | KnowledgeService | GalGameService / RenderService | **URGENT（跨服务阻塞项）** 服务身份 |
| `/internal/v1/*` | 对应服务 | Service only | 服务身份；用户委托身份可选 |

### 9.2 Gateway 行为

- 丢弃客户端传入的 `X-Service-Name`、`X-User-Id` 等内部身份头。
- 从已验证令牌重新注入可信用户上下文。
- 写操作不在 Gateway 层盲目重试。
- GET 只有在确认幂等且无副作用时才能有限重试。
- 保持下游 `error.code`，统一响应结构和 `traceId`。
- 不允许用 HTTP 200 包装业务失败。
- CORS 只允许明确的前端源。
- 限流至少区分匿名登录、上传、生成任务和普通读取。
- 不在 Gateway 保存业务状态或访问服务数据库。

### 9.3 健康检查

| 方法 | 路由 | 响应 | 说明 |
|---|---|---|---|
| `GET` | `/healthz` | `200 HealthStatus` | Gateway 进程存活 |
| `GET` | `/readyz` | `200/503 ReadinessStatus` | 路由配置和关键依赖就绪 |

### 9.4 前端适配原则

- 页面只依赖 Gateway 路由和公共响应结构。
- WASM 只依赖 JS Adapter。
- 前端不得拼接服务直连地址。
- 前端不得根据 HTTP 500 的 message 猜测业务状态。
- 所有稳定分支判断使用 `error.code` 或显式状态字段。

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
| `KnowledgeGraphReady v1` | KnowledgeService | Gateway 通知 / GalGameService | `graphId, materialId, version, subjectCode, chapterCount, pointCount` |
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
    "snapshotVersion": "plan-graph-1.0:3da5f48f",
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

## 12. 开工清单

### 12.1 负责人交付

| 负责人 | 必须确认 | 最小交付物 |
|---|---|---|
| `@Sleexy` | 注册边界、令牌策略、文件限制、解析任务；**URGENT** 规范化纯文本与 `MaterialTextReady v1` | User/Auth/File Markdown + Mock |
| `@Arabidopsis` | Neo4j 分层图、章节切分、PlanGraph、hub 权重、SM-2 与结果幂等 | Knowledge Markdown + 图谱/计划 Mock |
| `@F15EX` | game schema 1.0、生成器版本、场景与选择约束；**URGENT** PlanGraph 读取与 question 绑定 | 黄金包、错误包和校验器 |
| `@Zopiclone` | WASM ABI、RuntimeState、会话状态和结果幂等；**URGENT** `ReviewCompleted v2` 证据 | WASM 接口说明 + 状态 Mock |
| `@甲烷` | Gateway 路由、鉴权、CORS、超时和 JS Adapter | 路由表、API Client 和错误映射 |

### 12.2 M0 开放项与已决策基线

| 项目 | 建议默认值或当前决策 | 拍板人 |
|---|---|---|
| Access Token 使用 JWT 还是内省 | 首版 JWT，由 Gateway 本地验签 | `@Sleexy + @甲烷` |
| 注册时 Auth 与 User 的一致性 | Auth 经 Gateway INTERNAL 同步创建 UserProfile | `@Sleexy` |
| 首批文件格式和大小 | PDF + DOCX；大小以真实样例压测为准 | `@Sleexy` |
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
- [ ] GalGameService 与 RenderService 共同通过黄金游戏包；
- [ ] JS Adapter 可使用 Mock 完成 WASM 初始化、加载、游玩、保存和结果提交；
- [ ] Gateway 路由表、鉴权方式和统一错误响应完成确认；
- [ ] 所有服务确认不进行服务间直连。
- [ ] **URGENT** FileService 可返回符合 5.2.1 的纯文本并发布 `MaterialTextReady v1`；
- [ ] KnowledgeService 可从同一文本稳定构建章节 DAG，并生成不可变 ASSESSMENT/LEARNING PlanGraph；
- [ ] **URGENT** GalGameService 可按 snapshot 读取 PlanGraph，RenderService 可提交 `ReviewCompleted v2`，重复结果只更新一次 mastery。

后续字段细化进入各服务仓库；本文只维护跨服务边界与团队共同依赖。
