# UserService

UserService 是 千知万理 的用户资料服务，默认监听 `http://localhost:5101`。采用的数据库是 **MySQL**，只负责用户展示资料与学习偏好；密码、令牌、会话、邀请码和管理员认证均属于 AuthService。

浏览器只能经 Gateway 访问 `/api/v1/users/...`。UserService 不解析浏览器令牌，而是只信任 Gateway 注入并由共享服务密钥保护的用户上下文。

## 1. 职责边界

| UserService 负责 | UserService 不负责 |
| --- | --- |
| 显示名、头像地址、语言地区、学科偏好 | 邮箱、密码哈希、会话与 Token |
| 每日学习目标、内容难度、减少动画偏好 | 注册、登录、退出、密码恢复 |
| 为 AuthService 提供受限的资料创建、批量查询与删除内部接口 | 管理员身份认证与邀请码 |
| 用户资料表及偏好表的持久化 | 直接访问 AuthService 的 MySQL 表 |

虽然 AuthService 与 UserService 当前使用同一个 MySQL 数据库实例，两个服务各自拥有表和数据写入权；跨服务操作必须经过 Gateway 的 `/internal/v1/...` 路由。

## 2. 运行依赖

- .NET 8 SDK / Runtime
- MySQL 8.x
- Gateway：默认 `http://localhost:5000`
- AuthService：注册时通过 Gateway 调用本服务的资料创建接口

本地启动：

```powershell
dotnet run --project .\UserService\GalGame.UserService.csproj
```

健康检查：

```text
GET http://localhost:5101/healthz
GET http://localhost:5101/readyz
```

## 3. 配置

本地开发配置位于 `appsettings.Development.json`。生产环境应通过系统环境变量或受管密钥服务注入配置；`dotnet run` 不会自动加载 `.env` 文件。

### 监听地址与端口

`Properties/launchSettings.json` 的 `applicationUrl` 只用于本地开发，当前本地约定为 `http://localhost:5101`。生产环境中，UserService 应通过其自身进程的 `ASPNETCORE_URLS` 配置监听地址；Gateway 的职责只是将 `/api/v1/users` 和 `/internal/v1/users` 路由指向该地址。

使用 Windows Server 的 NSSM、计划任务或其他服务管理器时，应把 `ASPNETCORE_URLS` 配置为 **UserService 服务专属** 的环境变量，例如 `http://127.0.0.1:5101`。不要把它设为机器级全局变量，因为 AuthService、Gateway 等服务需要各自监听不同端口。

| 配置键 | 必填 | 说明 |
| --- | ---: | --- |
| `ConnectionStrings__UserDatabase` | 是 | UserService 的 MySQL 连接串 |
| `Gateway__ServiceKey` | 是 | 与 Gateway、AuthService 完全相同的内部共享密钥 |

生产环境示例（均为占位符）：

```powershell
$env:ASPNETCORE_ENVIRONMENT = "Production"
$env:ASPNETCORE_URLS = "http://127.0.0.1:5101"
$env:ConnectionStrings__UserDatabase = "Server=127.0.0.1;Port=5251;Database=moonstone_auth;User ID=moonstone_user;Password=REPLACE_ME;SslMode=Required;"
$env:Gateway__ServiceKey = "REPLACE_WITH_ONE_LONG_RANDOM_SHARED_KEY"
```

临时验证时，可在同一个 PowerShell 窗口设置变量后启动服务：

```powershell
$env:ASPNETCORE_URLS = "http://127.0.0.1:5101"
dotnet .\GalGame.UserService.dll
```

## 4. 数据库与初始化

UserService 在 MySQL 中拥有：

| 表 | 用途 |
| --- | --- |
| `user_profiles` | 用户 ID、显示名、头像地址、语言地区、学科偏好、创建与更新时间 |
| `user_preferences` | 每日目标分钟数、内容难度、减少动画偏好；外键关联 `user_profiles`，删除资料时级联删除 |

服务启动时会确保 UserService 所拥有的数据表存在。全新生产库应由受控部署流程管理数据库结构与版本，而不是依赖运行时建表逻辑。

## Mock 模式

设置 `MOONSTONE_MODE=Mock` 后，UserService 使用 InMemory Repository，不连接 MySQL。预置用户 ID 为 `7bc4918a-9079-4ea2-9e8e-369ad79a9f20`，显示名称为 `Arabidopsis`，并带有 `AGRONOMY`、`MEDICINE` 两项学科偏好。

```powershell
$env:MOONSTONE_MODE = "Mock"
dotnet run --project .\UserService\GalGame.UserService.csproj
```

Mock 状态仅在进程运行期间有效，重启服务后会恢复为预置数据；它不应连接或修改 MySQL，也不能用于生产环境。

## 5. 浏览器 API

以下地址均由 Gateway 暴露。受保护请求需要：

```http
Authorization: Bearer <accessToken>
```

| 方法 | Gateway 地址 | 用途 | 常见状态 |
| --- | --- | --- | --- |
| `GET` | `/api/v1/users/me` | 读取当前用户资料 | `200/401/404` |
| `PATCH` / `PUT` | `/api/v1/users/me` | 局部更新当前用户资料 | `200/400/401/404` |
| `GET` | `/api/v1/users/me/preferences` | 读取学习与显示偏好 | `200/401/404` |
| `PUT` | `/api/v1/users/me/preferences` | 完整替换偏好；格式/类型错误为 400，业务范围错误为 422 | `200/400/401/404/422` |

成功响应统一为：

```json
{ "data": {}, "meta": {}, "traceId": "..." }
```

失败响应统一为：

```json
{
  "data": null,
  "error": { "code": "AUTH_REQUIRED", "message": "...", "details": {} },
  "traceId": "..."
}
```

### 读取和更新个人资料

`GET /api/v1/users/me` 返回：

```json
{
  "userId": "uuid",
  "displayName": "学习者",
  "avatarUrl": null,
  "locale": "zh-CN",
  "preferredSubjectCodes": ["MATH", "ENGLISH"],
  "createdAt": "2026-07-28T00:00:00Z",
  "updatedAt": "2026-07-28T00:00:00Z"
}
```

更新资料：

```json
{
  "displayName": "新的显示名",
  "locale": "zh-CN",
  "preferredSubjectCodes": ["MATH", "ENGLISH"]
}
```

- `displayName`：去除首尾空白后 1–64 字符。
- `locale`：2–16 字符，只允许字母、数字、`-` 和 `_`。
- `preferredSubjectCodes`：可省略；传入时每一项不可为空白。
- 请求中未提供的字段保持原值。
- `avatarUrl` 当前由资料结构保留，但没有对外写入接口。

### 学习偏好

读取时，如果用户尚未显式保存偏好，服务返回默认值：

```json
{
  "dailyGoalMinutes": 30,
  "contentDifficulty": "STANDARD",
  "reducedMotion": false
}
```

保存偏好：

```json
{
  "dailyGoalMinutes": 30,
  "contentDifficulty": "STANDARD",
  "reducedMotion": false
}
```

校验规则：

- `dailyGoalMinutes` 必须为 5–180 的整数。
- `contentDifficulty` 仅允许 `BASIC`、`STANDARD` 或 `ADVANCED`。
- `reducedMotion` 为布尔值。

## 6. 内部 API

这些接口不向浏览器公开。调用必须经过 Gateway，并通过 `X-Gateway-Key`、`X-Service-Name: AuthService` 验证服务身份。

| 方法 | 内部地址 | 用途 | 常见状态 |
| --- | --- | --- | --- |
| `POST` | `/internal/v1/users` | 注册成功后创建用户资料 | `201/400/403/409` |
| `POST` | `/internal/v1/users/profile-lookups` | 管理员用户列表批量读取显示名，最多 500 个 ID | `200/400/403` |
| `DELETE` | `/internal/v1/users/{userId}` | 管理员删除账户时删除资料与偏好 | `204/400/403/404` |

创建资料请求：

```json
{ "userId": "uuid", "displayName": "学习者", "locale": "zh-CN" }
```

批量查询请求：

```json
{ "userIds": ["uuid-1", "uuid-2"] }
```

批量查询仅返回 `userId` 与 `displayName`，不返回偏好等无关数据。

## 7. 信任边界与安全要求

- Gateway 验证浏览器 Bearer Token 后，才向 UserService 注入 `X-Gateway-Key`、`X-User-Id`、`X-User-Scopes` 与 `X-Correlation-Id`。
- UserService 只信任拥有正确 `X-Gateway-Key` 的请求；浏览器直接伪造 `X-User-Id` 无效。
- 内部创建、资料批量查询和删除接口额外要求 `X-Service-Name: AuthService`。
- 服务不保存密码、邮箱凭证、Access Token、Refresh Token 或管理员密码。
- 日志不得输出用户令牌、密码或未脱敏的敏感资料。
- 生产环境仅监听回环地址或私有网络，并与 Gateway 使用同一高强度随机服务密钥。

## 8. 常见排查

| 现象 | 优先检查 |
| --- | --- |
| `401 AUTH_REQUIRED` | 请求是否经 Gateway、是否携带有效 Bearer Token、Gateway 是否注入 `X-User-Id` |
| `403 FORBIDDEN`（内部接口） | `Gateway__ServiceKey` 是否三服务一致、`X-Service-Name` 是否由 AuthService 经 Gateway 注入 |
| 注册返回资料服务不可用 | UserService `/readyz`、Gateway `/internal/v1/users` 路由和 MySQL 连通性 |
| `404` 用户资料不存在 | 注册资料创建失败、账户为旧数据或该资料已被管理员删除 |
| `422 BUSINESS_RULE_VIOLATION` | 检查学习目标是否在 5–180，难度值是否为允许枚举 |

发布前至少执行：

```powershell
dotnet build .\UserService\GalGame.UserService.csproj
```

并验证健康检查、读取/更新资料、保存偏好，以及 AuthService 经 Gateway 创建与删除资料的内部流程。
