# 千知万理 API 接口规范与数据契约

> 版本：v0.1  
> 状态：Draft / 各服务负责人待确认  
> 总负责人：PM & TL `@Arabidopsis`  
> 更新时间：2026-07-27  
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

### 3.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/internal/v1/users` | 注册后创建用户资料 | `CreateUserProfileRequest` | `UserProfile` | `201/409` |
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

- [ ] 头像来源和上传方式；
- [ ] `preferredSubjectCodes` 最大数量；
- [ ] 账户注销是否进入首版。

## 4. AuthService

> 负责人：`@Sleexy`  
> 拥有：凭证、会话、访问令牌、刷新令牌、撤销状态、管理员会话和邀请码。  
> 不拥有：用户展示资料、学习偏好和学习业务数据。

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
| `POST` | `/api/v1/auth/registrations` | 创建凭证和初始会话 | `RegistrationRequest` | `AuthSessionResponse` | `201/409` |
| `POST` | `/api/v1/auth/sessions` | 邮箱与密码登录 | `LoginRequest` | `AuthSessionResponse` | `201/401` |
| `GET` | `/api/v1/auth/sessions/{sessionId}` | 读取会话状态 | - | `AuthSession` | `200/404` |
| `DELETE` | `/api/v1/auth/sessions/{sessionId}` | 退出并撤销会话 | - | - | `204/404` |
| `POST` | `/api/v1/auth/tokens` | 刷新访问令牌 | `RefreshTokenRequest` | `TokenPair` | `201/401` |
| `POST` | `/api/v1/auth/password-reset-requests` | 请求密码恢复 | `PasswordResetRequest` | - | `202/404` |
| `POST` | `/api/v1/auth/password-resets` | 重设密码 | `PasswordResetConfirmation` | - | `204/422` |
| `POST` | `/api/v1/auth/password-changes` | 当前用户修改密码 | `PasswordChangeRequest` | - | `204/400/401` |
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

interface PasswordChangeRequest {
  currentPassword: string;
  newPassword: string;
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
  "password": "local-only-mock",
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

- [ ] 密码强度和哈希算法；
- [ ] Access Token 使用 JWT 还是通过 INTERNAL introspection；
- [ ] 刷新令牌是否每次轮换；
- [ ] Access Token、会话和密码重置令牌有效期；
- [ ] 注册时 AuthService 与 UserService 的一致性方案。

建议首版：Gateway 本地验证 JWT；AuthService 经 Gateway 的 INTERNAL 路由同步创建 UserProfile。

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
```

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
> 拥有：KnowledgeGraph、KnowledgePoint、KnowledgeRelation、ReviewPlan 和 MasteryRecord。  
> 不拥有：原始文件、游戏包和浏览器运行状态。

### 6.1 接口目录

| 方法 | Gateway 路由 | 用途 | 请求 | 响应 | 状态 |
|---|---|---|---|---|---|
| `POST` | `/api/v1/knowledge-graph-builds` | 创建图谱构建任务 | `GraphBuildRequest` | `GraphBuildJob` | `202/409` |
| `GET` | `/api/v1/knowledge-graph-builds/{buildId}` | 查询构建任务 | - | `GraphBuildJob` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs?materialId=...` | 查询资料的图谱版本 | Query | `KnowledgeGraphPage` | `200/400` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}` | 读取图谱摘要 | - | `KnowledgeGraphSummary` | `200/404` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/points` | 分页读取知识点 | Query | `KnowledgePointPage` | `200/400` |
| `GET` | `/api/v1/knowledge-graphs/{graphId}/relations` | 分页读取关系 | Query | `KnowledgeRelationPage` | `200/400` |
| `GET` | `/api/v1/knowledge-points/{pointId}` | 读取知识点详情 | - | `KnowledgePoint` | `200/404` |
| `PATCH` | `/api/v1/knowledge-points/{pointId}` | 人工修正知识点 | `KnowledgePointPatch` | `KnowledgePoint` | `200/409/P1` |
| `POST` | `/api/v1/review-plans` | 生成复习知识点快照 | `CreateReviewPlanRequest` | `ReviewPlan` | `201/422` |
| `GET` | `/api/v1/mastery-records` | 查询当前用户掌握度 | Query | `MasteryPage` | `200/400` |

### 6.2 数据类型

```ts
interface GraphBuildRequest {
  materialId: Uuid;
  subjectHint?: SubjectCode;
  extractorVersion?: string;
}

type JobStatus = "QUEUED" | "RUNNING" | "SUCCEEDED" | "FAILED";

interface GraphBuildJob {
  buildId: Uuid;
  materialId: Uuid;
  status: JobStatus;
  progress: number; // int32, 0-100
  graphId: Uuid | null;
  error: ApiError | null;
  createdAt: DateTime;
  updatedAt: DateTime;
}

type KnowledgeGraphStatus = "DRAFT" | "READY" | "SUPERSEDED";

interface KnowledgeGraphSummary {
  graphId: Uuid;
  materialId: Uuid;
  version: number; // int32，单调递增
  subjectCodes: SubjectCode[];
  pointCount: number;
  relationCount: number;
  status: KnowledgeGraphStatus;
  createdAt: DateTime;
}

interface SourceRef {
  materialId: Uuid;
  location: string;     // 页码、段落或偏移量
  quote: string | null; // 短摘录
}

interface KnowledgePoint {
  pointId: Uuid;
  graphId: Uuid;
  title: string;            // 1-120 字符
  summary: string;
  subjectCode: SubjectCode;
  tags: string[];
  confidence: number;       // 0-1
  sourceRefs: SourceRef[];  // 至少一个
  createdAt: DateTime;
  updatedAt: DateTime;
}

interface KnowledgePointPatch {
  title?: string;
  summary?: string;
  subjectCode?: SubjectCode;
  tags?: string[];
  expectedUpdatedAt: DateTime;
}

type RelationType = "PREREQUISITE" | "RELATED" | "CONTRASTS" | "PART_OF";

interface KnowledgeRelation {
  relationId: Uuid;
  graphId: Uuid;
  fromPointId: Uuid;
  toPointId: Uuid;
  type: RelationType;
  confidence: number; // 0-1
}

type ReviewSelectionMode = "WEAK_FIRST" | "BALANCED" | "MANUAL";

interface CreateReviewPlanRequest {
  graphId: Uuid;
  count: number; // int32，建议 3-20
  selectionMode: ReviewSelectionMode;
  pointIds?: Uuid[]; // MANUAL 时必填
}

interface ReviewPlan {
  reviewPlanId: Uuid;
  graphId: Uuid;
  knowledgePointIds: Uuid[];
  snapshotVersion: string;
  createdAt: DateTime;
}

interface MasteryRecord {
  userId: Uuid;
  pointId: Uuid;
  score: number; // 0-100
  reason: string;
  updatedAt: DateTime;
}
```

分页响应：

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

### 6.3 图谱 Mock

```json
{
  "data": {
    "graphId": "b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0",
    "materialId": "3a7f3d0f-1876-4879-8d6d-01a919d5c935",
    "version": 1,
    "subjectCodes": ["AGRONOMY", "BOTANY"],
    "pointCount": 18,
    "relationCount": 27,
    "status": "READY",
    "createdAt": "2026-07-27T08:45:00Z"
  },
  "meta": {},
  "traceId": "01JKNOW..."
}
```

### 6.4 OWNER-TBD

- [ ] `SubjectCode` 枚举；
- [ ] 关系类型是否需要扩展；
- [ ] 知识点与来源摘录的长度限制；
- [ ] 抽取器和外部模型数据边界；
- [ ] 掌握度初始公式；
- [ ] 人工修正和新图谱版本的冲突策略。

首版必须保证：

- 所有知识点可追溯到原始资料位置；
- 新图谱版本不得覆盖旧版本；
- 游戏包使用的知识点以 `ReviewPlan.snapshotVersion` 为边界。

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
  text: string;
  nextSceneId: string | null;
  scoreDelta: number;
  knowledgePointId: Uuid;
}

type KnowledgePurpose = "EXPLAIN" | "QUESTION" | "FEEDBACK";

interface KnowledgeBinding {
  knowledgePointId: Uuid;
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

### 7.4 最小游戏包 Mock

```json
{
  "schemaVersion": "1.0",
  "packageId": "f2561bb2-b88c-47ef-b0ae-8f283ff64f1b",
  "generatorVersion": "gala-0.1.0",
  "reviewPlanId": "8e812950-3311-40a7-93ab-636409df8cc2",
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
          "text": "协调群体数量与个体生长",
          "nextSceneId": null,
          "scoreDelta": 1,
          "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb"
        }
      ],
      "knowledgeBindings": [
        {
          "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
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
  knowledgePointId: Uuid;
  choiceId: string;
  correct: boolean;
  scoreDelta: number;
}

interface ReviewResultInput {
  expectedProgressVersion: number;
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
  "answerResults": [
    {
      "knowledgePointId": "d1adc45a-52db-4de2-9cf7-02e1ac0d53cb",
      "choiceId": "c1",
      "correct": true,
      "scoreDelta": 1
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
| `/api/v1/knowledge-*`、`/api/v1/review-plans`、`/api/v1/mastery-records` | KnowledgeService | Browser | 用户令牌 |
| `/api/v1/game-*` | GalGameService | Browser / Render | 用户令牌 |
| `/api/v1/render-runtime`、`/api/v1/review-sessions` | RenderService | Browser | 用户令牌；manifest 可公开缓存 |
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
| `MaterialUploaded v1` | FileService | KnowledgeService | `materialId, ownerUserId, mediaType, checksum, contentRef` |
| `KnowledgeGraphReady v1` | KnowledgeService | Gateway 通知 / GalGameService | `graphId, materialId, version, subjectCodes, pointCount` |
| `GamePackageReady v1` | GalGameService | RenderService / Gateway 通知 | `packageId, schemaVersion, reviewPlanId, contentRef, checksum` |
| `ReviewCompleted v1` | RenderService | KnowledgeService | `resultId, sessionId, userId, packageId, answerResults, idempotencyKey` |

### 10.3 事件载荷

```ts
interface MaterialUploadedData {
  materialId: Uuid;
  ownerUserId: Uuid;
  mediaType: string;
  checksum: Sha256;
  contentRef: string;
}

interface KnowledgeGraphReadyData {
  graphId: Uuid;
  materialId: Uuid;
  version: number;
  subjectCodes: SubjectCode[];
  pointCount: number;
}

interface GamePackageReadyData {
  packageId: Uuid;
  schemaVersion: string;
  reviewPlanId: Uuid;
  contentRef: string;
  checksum: Sha256;
}

interface ReviewCompletedData {
  resultId: Uuid;
  sessionId: Uuid;
  userId: Uuid;
  packageId: Uuid;
  answerResults: AnswerResult[];
  idempotencyKey: Uuid;
}
```

### 10.4 事件 Mock

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
    "subjectCodes": ["AGRONOMY", "BOTANY"],
    "pointCount": 18
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
| `@Sleexy` | 注册边界、令牌策略、文件限制、解析任务 | User/Auth/File Markdown + Mock |
| `@Arabidopsis` | SubjectCode、关系类型、抽取器、掌握度、来源结构 | Knowledge Markdown + 图谱 Mock |
| `@F15EX` | game schema 1.0、生成器版本、场景与选择约束 | 黄金包、错误包和校验器 |
| `@Zopiclone` | WASM ABI、RuntimeState、会话状态和结果幂等 | WASM 接口说明 + 状态 Mock |
| `@甲烷` | Gateway 路由、鉴权、CORS、超时和 JS Adapter | 路由表、API Client 和错误映射 |

### 12.2 M0 开放项

| 开放项 | 建议默认值 | 拍板人 |
|---|---|---|
| Access Token 使用 JWT 还是内省 | 首版 JWT，由 Gateway 本地验签 | `@Sleexy + @甲烷` |
| 注册时 Auth 与 User 的一致性 | Auth 经 Gateway INTERNAL 同步创建 UserProfile | `@Sleexy` |
| 首批文件格式和大小 | PDF + DOCX；大小以真实样例压测为准 | `@Sleexy` |
| SubjectCode 与关系枚举 | 只支持真实样例所需的最小集合 | `@Arabidopsis` |
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

后续字段细化进入各服务仓库；本文只维护跨服务边界与团队共同依赖。
