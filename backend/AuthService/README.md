#  AuthService

AuthService 是 千知万理 的认证与账户治理服务。本地开发时默认监听 `http://localhost:5101`；生产环境应通过 `ASPNETCORE_URLS` 或宿主服务器配置监听地址。它的权威数据库是 **MySQL**，负责凭证、密码哈希、会话、访问令牌、刷新令牌、密码恢复、管理员会话、邀请码和管理员审计记录。

浏览器不得直接访问本服务。所有浏览器请求必须先到 API Gateway，再由 Gateway 转发并注入受信任的身份头。用户展示资料和学习偏好由 UserService 管理；AuthService 不得直接访问 UserService 的数据表。

## 1. 职责边界

| AuthService 负责 | AuthService 不负责 |
| --- | --- |
| 注册、登录、退出、会话读取与刷新令牌轮换 | 用户展示资料、头像、地区和学习偏好 |
| 密码哈希、修改密码、邮件验证码重置密码 | 知识图谱、文件、剧情、复习记录 |
| 管理员登录、用户认证账户治理、邀请码 | 直接读写 UserService 的 MySQL 表 |
| 管理员高风险操作审计 | 浏览器鉴权头的最终可信判定（由 Gateway 注入） |

当前管理员能力属于 AuthService 的内部模块，并不单独部署 Admin Service。

## 2. 运行依赖

- .NET 8 SDK / Runtime
- MySQL 8.x
- Gateway：默认 `http://localhost:5000`
- UserService：注册、管理员用户查询与删除资料时需要经 Gateway 调用
- 可选：SMTP 服务。仅密码恢复邮件需要。

本地启动：

```powershell
dotnet run --project .\AuthService\GalGame.AuthService.csproj
```

健康检查：

```text
GET http://localhost:5101/healthz  # 进程存活
GET http://localhost:5101/readyz  # 当前返回 MySQL 就绪状态
```

## 3. 配置

本地开发配置位于 `appsettings.Development.json`。该文件只能保存本机占位配置，不能提交真实数据库密码、SMTP 授权码或生产管理员密码。

生产环境建议使用 Windows 服务环境变量、IIS 配置或受管密钥服务。ASP.NET Core 的分层键使用双下划线，例如 `Gateway__ServiceKey` 对应 `Gateway:ServiceKey`。普通 `dotnet run` **不会自动读取 `.env` 文件**。

### 监听地址与端口

`Properties/launchSettings.json` 中的 `applicationUrl` 仅在本地开发执行 `dotnet run` 时生效；其中的 `http://localhost:5101` 不是生产环境固定地址，也不是由 Gateway 决定的。

生产环境中，AuthService 自身通过 `ASPNETCORE_URLS` 决定 Kestrel 的监听地址；Gateway 只需把认证路由转发到这个实际地址。若在 Windows Server 使用 NSSM 或其他服务管理器，应将该变量配置到 **AuthService 这一项服务** 的进程环境中，而不是写成全局系统变量。每项服务必须使用不同端口，避免端口冲突。

| 配置键 | 必填 | 说明 |
| --- | ---: | --- |
| `ConnectionStrings__AuthDatabase` | 是 | AuthService 的 MySQL 连接串 |
| `Gateway__ServiceKey` | 是 | 与 Gateway、UserService 完全相同的内部共享密钥 |
| `Gateway__BaseUrl` | 否 | Gateway 内部地址；默认 `http://localhost:5000` |
| `Admin__Username` | 是 | 管理员用户名，仅服务端保存 |
| `Admin__Password` | 是 | 管理员密码，仅服务端保存 |
| `Email__SmtpHost` | 密码恢复需要 | SMTP 主机 |
| `Email__SmtpPort` | 否 | 默认 `465` |
| `Email__UseSsl` | 否 | 默认 `true`；为真时使用 SSL 直连 |
| `Email__Username` | 密码恢复需要 | SMTP 登录名 |
| `Email__Password` | 密码恢复需要 | 邮箱授权码，不是邮箱登录密码 |
| `Email__FromAddress` | 密码恢复需要 | 发件邮箱 |
| `Email__FromName` | 否 | 发件人显示名，默认“千知万理” |

生产环境变量示例（均为占位符）：

```powershell
$env:ASPNETCORE_ENVIRONMENT = "Production"
$env:ASPNETCORE_URLS = "http://127.0.0.1:5101"
$env:ConnectionStrings__AuthDatabase = "Server=127.0.0.1;Port=3306;Database=moonstone_auth;User ID=moonstone_auth;Password=REPLACE_ME;SslMode=Required;"
$env:Gateway__BaseUrl = "http://127.0.0.1:5000"
$env:Gateway__ServiceKey = "REPLACE_WITH_ONE_LONG_RANDOM_SHARED_KEY"
$env:Admin__Username = "REPLACE_ADMIN_USERNAME"
$env:Admin__Password = "REPLACE_ADMIN_PASSWORD"
```

临时验证时，可在同一个 PowerShell 窗口设置变量后启动服务：

```powershell
$env:ASPNETCORE_URLS = "http://127.0.0.1:5101"
dotnet .\GalGame.AuthService.dll
```

## 4. 数据库与初始化

AuthService 在 `moonstone_auth` 中拥有以下表：

| 表 | 用途 |
| --- | --- |
| `auth_credentials` | 用户 ID、邮箱和 PBKDF2 密码哈希 |
| `auth_sessions` | 会话、Access/Refresh Token 的 SHA-256 哈希、过期与撤销状态 |
| `auth_password_resets` | 六位验证码的哈希、过期时间和已使用状态 |
| `admin_invitations` | 邀请码类型、次数和有效期 |
| `admin_audit_logs` | 管理员删除用户、重置密码、创建/删除邀请码的审计记录 |
| `admin_user_overrides` | 兼容保留的管理员用户覆盖数据 |

服务启动时会执行建表与旧 `users` 表的兼容迁移。当前兼容迁移面向已有本地开发数据；部署全新数据库前，应先验证旧表迁移逻辑已被移除或准备好相应迁移方案，避免把运行时建表逻辑当作正式数据库版本管理。

## 5. 浏览器 API

下列地址均以 Gateway 的 `/api/v1` 为准。成功响应为 `{ "data": ..., "meta": {}, "traceId": "..." }`；失败响应为 `{ "data": null, "error": { ... }, "traceId": "..." }`。

| 方法 | 地址 | 鉴权 | 用途 | 常见状态 |
| --- | --- | --- | --- | --- |
| `POST` | `/api/v1/auth/registrations` | 公开 | 注册、创建资料和初始会话 | `201/400/409/422/503` |
| `POST` | `/api/v1/auth/sessions` | 公开 | 邮箱密码登录 | `201/400/401` |
| `GET` | `/api/v1/auth/sessions/{sessionId}` | Bearer | 读取自己的会话 | `200/401/404` |
| `DELETE` | `/api/v1/auth/sessions/{sessionId}` | Bearer | 撤销自己的会话，即退出登录 | `204/401/404` |
| `POST` | `/api/v1/auth/tokens` | 公开 | 使用 Refresh Token 轮换会话 | `201/401` |
| `POST` | `/api/v1/auth/password-changes` | Bearer | 使用当前密码修改密码 | `204/400/401/404` |
| `POST` | `/api/v1/auth/password-reset-requests` | 公开 | 请求发送密码恢复验证码 | `202/400/404` |
| `POST` | `/api/v1/auth/password-resets` | 公开 | 使用验证码设置新密码 | `204/422` |

### 注册

邀请码是注册的必填项。服务会将邀请码统一去除首尾空白并转换为大写后校验。

```json
{
  "email": "student@example.com",
  "password": "at-least-8-characters",
  "displayName": "学习者",
  "invitationCode": "MS-ABCDE12345",
  "deviceName": "Chrome on Windows"
}
```

- 邮箱最大 320 字符，必须包含 `@`；显示名去除首尾空白后为 1–64 字符；密码至少 8 个字符。
- 创建凭证、锁定邀请码、校验有效期/使用次数、递增 `usedCount` 在同一 MySQL 事务中完成。
- `single-use` 仅能使用一次；`multi-use` 不得超过 `maxUses`；`time-window` 仅在 `validFrom` 至 `validTo`（含边界）有效。
- 重复邮箱返回 `409 STATE_CONFLICT`；无效、过期或用尽的邀请码返回 `422 BUSINESS_RULE_VIOLATION`。
- 资料创建或初始会话创建失败时，会删除刚创建的凭证并归还邀请码次数。

### 登录、会话与令牌

登录请求：

```json
{ "email": "student@example.com", "password": "at-least-8-characters", "deviceName": "Chrome on Windows" }
```

成功后 `data` 包含：

```json
{
  "session": {
    "sessionId": "uuid",
    "userId": "uuid",
    "status": "ACTIVE",
    "createdAt": "2026-07-28T00:00:00Z",
    "expiresAt": "2026-08-04T00:00:00Z"
  },
  "tokens": {
    "accessToken": "...",
    "refreshToken": "...",
    "tokenType": "Bearer",
    "expiresInSeconds": 900
  }
}
```

- Access Token 有效期为 15 分钟。
- Refresh Token 有效期为 7 天。
- 数据库只保存令牌的 SHA-256 哈希，不保存令牌明文。
- 刷新成功会撤销旧会话并创建新会话；退出、修改密码、管理员重置密码或密码恢复后都会撤销相应用户的全部会话。

刷新请求：

```json
{ "refreshToken": "..." }
```

### 修改与恢复密码

已登录用户修改密码：

```json
{ "currentPassword": "old-password", "newPassword": "new-password-at-least-8" }
```

密码恢复分两步：

1. `POST /api/v1/auth/password-reset-requests`

   ```json
   { "email": "student@example.com" }
   ```

   已注册邮箱返回 `202` 并发送邮件；当前产品要求未注册邮箱返回 `404`。

2. `POST /api/v1/auth/password-resets`

   ```json
   { "resetToken": "628340", "newPassword": "new-password-at-least-8" }
   ```

验证码是六位数字，有效期 10 分钟；数据库仅保存 SHA-256 哈希。新请求会使该用户先前未使用的验证码失效。确认重置接口按来源 IP 限制为每分钟最多 5 次。

## 6. SMTP 与密码恢复邮件

使用 126 邮箱时，推荐端口 `465` 与 `Email__UseSsl=true`。密码必须使用邮箱后台生成的 SMTP 授权码，不能使用邮箱网页登录密码。

```powershell
$env:Email__SmtpHost = "smtp.126.com"
$env:Email__SmtpPort = "465"
$env:Email__UseSsl = "true"
$env:Email__Username = "your-sender@126.com"
$env:Email__Password = "YOUR_SMTP_AUTHORIZATION_CODE"
$env:Email__FromAddress = "your-sender@126.com"
$env:Email__FromName = "千知万理"
```

邮件主题为“您的重置验证码”。邮件发送失败时，服务会删除刚创建的验证码并记录关联 ID；日志不得记录收件人、验证码、密码或 SMTP 授权码。

常见排查：

- 返回 `202` 但未收到邮件：检查垃圾箱、SMTP 授权码、服务器到 SMTP 端口的出站网络策略和 AuthService 日志中的 `traceId`。
- 返回 `404`：该邮箱尚未注册。
- 请求返回 `202` 但邮件未送达：当前实现会删除刚创建的验证码并保留 `202` 响应；以 AuthService 日志中的 `traceId` 为准排查 SMTP 失败原因。
- 请求返回 `503` 或 `500`：优先检查 MySQL、Gateway 与 UserService 的连通性；SMTP 配置缺失或投递失败通常不直接改变该接口的响应码。

## 7. 管理员 API

管理员先登录：

```json
POST /api/v1/admin/sessions
{ "username": "admin", "password": "REPLACE_ME" }
```

成功后使用返回的 Access Token 访问以下接口：

| 方法 | 地址 | 用途 | 常见状态 |
| --- | --- | --- | --- |
| `GET` | `/api/v1/admin/users` | 列出注册用户和显示名 | `200/403/503` |
| `DELETE` | `/api/v1/admin/users/{userId}` | 删除资料与认证数据 | `204/403/404/503` |
| `POST` | `/api/v1/admin/users/{userId}/password` | 重置密码并撤销该用户会话 | `204/400/403/404` |
| `GET` | `/api/v1/admin/invitations` | 列出邀请码 | `200/403` |
| `POST` | `/api/v1/admin/invitations` | 创建邀请码 | `201/400/403` |
| `DELETE` | `/api/v1/admin/invitations/{code}` | 删除邀请码 | `204/403/404` |

创建多次邀请码示例：

```json
{ "type": "multi-use", "maxUses": 10, "validFrom": null, "validTo": null }
```

创建限时邀请码示例：

```json
{
  "type": "time-window",
  "maxUses": 100,
  "validFrom": "2026-08-01T00:00:00Z",
  "validTo": "2026-08-31T23:59:59Z"
}
```

用户删除时，AuthService 经 Gateway 调用 UserService 的内部删除接口，再删除认证凭证与会话；它不会直连 UserService 数据表。用户删除、密码重置、邀请码创建和邀请码删除会写入 `admin_audit_logs`，记录操作者、目标、结果、时间和 `traceId`。

## 8. 内部接口与信任模型

| 方法 | 地址 | 调用方 | 用途 |
| --- | --- | --- | --- |
| `POST` | `/internal/v1/auth/introspections` | Gateway | 内省 Access Token 的有效状态与用户上下文 |

Gateway 调用内部接口时使用 `X-Gateway-Key`；服务间调用 Gateway 的内部路由时使用 `X-Service-Name` 与 `X-Service-Key`。浏览器传入的同名头不可信，Gateway 必须丢弃或覆盖。

## 9. 安全与运维要求

- 密码使用 ASP.NET Core `PasswordHasher`（PBKDF2）哈希，禁止存储明文。
- 不在日志、异常详情、审计消息或前端存储中输出密码、刷新令牌、验证码或 SMTP 授权码。
- 生产环境中的 Gateway、AuthService、UserService 必须使用同一个高强度随机 `Gateway__ServiceKey`，且只监听内网或回环地址。
- 生产数据库使用专用低权限账号，不使用 MySQL `root`。
- 管理员账号不得写入前端资源或版本库中的生产配置。
- 发布前执行 `dotnet build .\AuthService\GalGame.AuthService.csproj`，并至少验证 `/healthz`、`/readyz`、注册、登录、密码恢复和管理员邀请码流程。
