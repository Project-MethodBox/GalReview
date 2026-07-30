using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using MySqlConnector;

var builder = WebApplication.CreateBuilder(args);
var isMockMode = string.Equals(Environment.GetEnvironmentVariable("MOONSTONE_MODE"), "Mock", StringComparison.OrdinalIgnoreCase);
var connectionString = builder.Configuration.GetConnectionString("AuthDatabase");
if (!isMockMode && string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("ConnectionStrings:AuthDatabase must be configured.");
var gatewayKey = builder.Configuration["Gateway:ServiceKey"] ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
var gatewayBaseUrl = builder.Configuration["Gateway:BaseUrl"] ?? "http://localhost:5000";
var adminUsername = builder.Configuration["Admin:Username"] ?? throw new InvalidOperationException("Admin:Username must be configured.");
var adminPassword = builder.Configuration["Admin:Password"] ?? throw new InvalidOperationException("Admin:Password must be configured.");
var isDevelopment = builder.Environment.IsDevelopment();
var storageName = isMockMode ? "memory" : "mysql";
builder.Services.AddSingleton<PasswordResetEmailSender>();
builder.Services.AddSingleton<IPasswordHasher<Credential>>(_ => new PasswordHasher<Credential>());
if (isMockMode)
{
    builder.Services.AddSingleton<MockAuthStore>();
    builder.Services.AddSingleton<IAuthRepository, InMemoryAuthRepository>();
    builder.Services.AddSingleton<IAdminRepository, InMemoryAdminRepository>();
    builder.Services.AddSingleton<IAdminAuditRepository, InMemoryAdminAuditRepository>();
}
else
{
    builder.Services.AddSingleton(new AuthDatabase(connectionString!));
    builder.Services.AddSingleton<IAuthRepository, MySqlAuthRepository>();
    builder.Services.AddSingleton<IAdminRepository, MySqlAdminRepository>();
    builder.Services.AddSingleton<IAdminAuditRepository, MySqlAdminAuditRepository>();
}
builder.Services.AddHttpClient("gateway", client => client.BaseAddress = new Uri(gatewayBaseUrl));
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("password-reset-confirmation", context =>
        RateLimitPartition.GetFixedWindowLimiter(
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 5,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0,
                AutoReplenishment = true
            }));
});

var app = builder.Build();
if (!isMockMode) app.Services.GetRequiredService<AuthDatabase>().EnsureCreated();
app.Use(async (context, next) =>
{
    var correlationId = context.Request.Headers["X-Correlation-Id"].FirstOrDefault();
    context.TraceIdentifier = string.IsNullOrWhiteSpace(correlationId) ? Guid.NewGuid().ToString("N") : correlationId;
    context.Response.Headers["X-Correlation-Id"] = context.TraceIdentifier;
    await next();
});
app.UseExceptionHandler(error => error.Run(context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("AuthService")
        .LogError(exception, "Unhandled AuthService error. CorrelationId: {CorrelationId}; Path: {Path}", context.TraceIdentifier, context.Request.Path);
    object details = isDevelopment ? new { exception = exception?.GetType().Name, message = exception?.Message } : new { };
    return Results.Json(new ApiFailure(null, new ApiError("INTERNAL_ERROR", "认证服务暂时不可用", details), context.TraceIdentifier), statusCode: 500).ExecuteAsync(context);
}));
app.Use(async (context, next) =>
{
    if (context.Request.Path == "/healthz" || context.Request.Path == "/readyz")
    {
        await next();
        return;
    }

    if (!IsGateway(context, gatewayKey))
    {
        await Failure(context, 403, "FORBIDDEN", "该服务仅接受经 API Gateway 转发的请求").ExecuteAsync(context);
        return;
    }

    await next();
});
app.UseRateLimiter();

app.MapGet("/healthz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "live" }, c.TraceIdentifier)));
app.MapGet("/readyz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "ready", storage = storageName }, c.TraceIdentifier)));

app.MapPost("/api/v1/auth/registrations", async (RegistrationRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher, IHttpClientFactory clients) =>
{
    var invitationCode = NormalizeInvitationCode(request.InvitationCode);
    if (!ValidEmail(request.Email) || !ValidName(request.DisplayName) || !ValidPassword(request.Password) || invitationCode is null) return Failure(c, 400, "VALIDATION_ERROR", "邮箱、显示名、密码或邀请码格式不正确");
    var credential = Credential.New(request.Email.Trim().ToLowerInvariant());
    credential = credential with { PasswordHash = hasher.HashPassword(credential, request.Password) };
    var registration = repository.TryCreateCredentialWithInvitation(credential, invitationCode);
    if (registration == RegistrationOutcome.EmailAlreadyRegistered) return Failure(c, 409, "STATE_CONFLICT", "该邮箱已注册");
    if (registration == RegistrationOutcome.InvitationUnavailable) return Failure(c, 422, "BUSINESS_RULE_VIOLATION", "邀请码无效、已过期或使用次数已达上限");
    var profileCreated = await CreateProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, credential.UserId, request.DisplayName.Trim(), c.RequestAborted);
    if (!profileCreated) { repository.RollbackRegistration(credential.UserId, invitationCode); return Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用"); }
    StoredSession session;
    try { session = repository.CreateSession(credential.UserId, request.DeviceName); }
    catch
    {
        await DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, credential.UserId, c.RequestAborted);
        repository.RollbackRegistration(credential.UserId, invitationCode);
        throw;
    }
    return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
});

app.MapPost("/api/v1/auth/sessions", (LoginRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
{
    if (!ValidEmail(request.Email) || string.IsNullOrEmpty(request.Password)) return Failure(c, 400, "VALIDATION_ERROR", "邮箱和密码不能为空");
    var credential = repository.FindCredential(request.Email.Trim().ToLowerInvariant());
    if (credential is null || !PasswordMatches(hasher, credential, request.Password)) return Failure(c, 401, "AUTH_REQUIRED", "邮箱或密码错误");
    var session = repository.CreateSession(credential.UserId, request.DeviceName);
    return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
});
app.MapPost("/api/v1/admin/sessions", (AdminLoginRequest request, HttpContext c, IAuthRepository repository) =>
{
    if (!FixedTimeEquals(request.Username.Trim(), adminUsername) || !FixedTimeEquals(request.Password, adminPassword))
        return Failure(c, 401, "AUTH_REQUIRED", "管理员账号或密码错误");
    var session = repository.CreateSession("00000000-0000-0000-0000-000000000001", "MoonStone admin");
    return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
});
app.MapGet("/api/v1/admin/users", async (HttpContext c, IAdminRepository admin, IHttpClientFactory clients) =>
{
    if (!IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "需要管理员权限");
    var accounts = admin.ListUsers();
    var displayNames = await LookupProfileDisplayNamesAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, accounts.Select(account => account.Id).ToArray(), c.RequestAborted);
    if (displayNames is null) return Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用");
    var users = accounts.Select(account => new AdminUser(account.Id, account.Email, displayNames.GetValueOrDefault(account.Id, account.Email), true)).ToArray();
    return Results.Ok(ApiSuccess.Create(users, c.TraceIdentifier));
});
app.MapDelete("/api/v1/admin/users/{userId}", async (string userId, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit, IHttpClientFactory clients) =>
{
    if (!IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "需要管理员权限");
    var actorUserId = GetGatewayUser(c, gatewayKey)!;
    if (!admin.UserExists(userId))
    {
        audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, "NOT_FOUND", c.TraceIdentifier));
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
    }
    if (!await DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, userId, c.RequestAborted))
    {
        audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, "PROFILE_DELETE_FAILED", c.TraceIdentifier));
        return Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用");
    }
    var deleted = admin.DeleteAuthUser(userId);
    audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
    return deleted ? Results.NoContent() : Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
});
app.MapPost("/api/v1/admin/users/{userId}/password", (string userId, AdminResetPasswordRequest request, HttpContext c, IAuthRepository repository, IAdminAuditRepository audit, IPasswordHasher<Credential> hasher) =>
{
    if (!IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "需要管理员权限");
    if (!ValidPassword(request.NewPassword)) return Failure(c, 400, "VALIDATION_ERROR", "新密码至少需要 8 个字符");
    var credential = repository.FindCredentialById(userId);
    if (credential is null)
    {
        audit.Write(AdminAuditRecord.Create(GetGatewayUser(c, gatewayKey)!, "USER_PASSWORD_RESET", userId, null, "NOT_FOUND", c.TraceIdentifier));
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
    }
    repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword) });
    repository.RevokeAllSessions(userId);
    audit.Write(AdminAuditRecord.Create(GetGatewayUser(c, gatewayKey)!, "USER_PASSWORD_RESET", userId, null, "SUCCEEDED", c.TraceIdentifier));
    return Results.NoContent();
});
app.MapPost("/api/v1/auth/password-changes", (PasswordChangeRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
{
    var userId = GetGatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
    if (!ValidPassword(request.NewPassword)) return Failure(c, 400, "VALIDATION_ERROR", "新密码至少需要 8 个字符");
    var credential = repository.FindCredentialById(userId);
    if (credential is null) return Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
    if (!PasswordMatches(hasher, credential, request.CurrentPassword)) return Failure(c, 401, "AUTH_REQUIRED", "当前密码错误");
    repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword) });
    repository.RevokeAllSessions(userId);
    return Results.NoContent();
});
app.MapDelete("/api/v1/auth/account", async ([FromBody] AccountDeletionRequest request, HttpContext c, IAuthRepository repository, IAdminAuditRepository audit, IPasswordHasher<Credential> hasher, IHttpClientFactory clients) =>
{
    var userId = GetGatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "登陆状态已失效");
    if (IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "管理员不能通过此接口注销");
    if (string.IsNullOrWhiteSpace(request.CurrentPassword)) return Failure(c, 400, "VALIDATION_ERROR", "请输入当前登录密码以确认注销");

    var credential = repository.FindCredentialById(userId);
    if (credential is null) return Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
    if (!PasswordMatches(hasher, credential, request.CurrentPassword)) return Failure(c, 401, "AUTH_REQUIRED", "当前密码错误");
    if (!await DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, userId, c.RequestAborted))
    {
        audit.Write(AdminAuditRecord.Create(userId, "ACCOUNT_SELF_DELETE", userId, null, "PROFILE_DELETE_FAILED", c.TraceIdentifier));
        return Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用，注销失败");
    }

    var deleted = repository.DeleteAccount(userId);
    audit.Write(AdminAuditRecord.Create(userId, "ACCOUNT_SELF_DELETE", userId, null, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
    return deleted ? Results.NoContent() : Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
});
app.MapGet("/api/v1/admin/invitations", (HttpContext c, IAdminRepository admin) =>
    IsAdmin(c, gatewayKey) ? Results.Ok(ApiSuccess.Create(admin.ListInvitations(), c.TraceIdentifier)) : Failure(c, 403, "FORBIDDEN", "需要管理员权限"));
app.MapPost("/api/v1/admin/invitations", (CreateInvitationRequest request, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit) =>
{
    if (!IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "需要管理员权限");
    var invitation = admin.CreateInvitation(request);
    if (invitation is null) return Failure(c, 400, "VALIDATION_ERROR", "请填写邀请码");
    audit.Write(AdminAuditRecord.Create(GetGatewayUser(c, gatewayKey)!, "INVITATION_CREATE", null, invitation.Code, "SUCCEEDED", c.TraceIdentifier));
    return Results.Created($"/api/v1/admin/invitations/{invitation.Code}", ApiSuccess.Create(invitation, c.TraceIdentifier));
});
app.MapDelete("/api/v1/admin/invitations/{code}", (string code, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit) =>
{
    if (!IsAdmin(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "需要管理员权限");
    var deleted = admin.DeleteInvitation(code);
    audit.Write(AdminAuditRecord.Create(GetGatewayUser(c, gatewayKey)!, "INVITATION_DELETE", null, code, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
    return deleted ? Results.NoContent() : Failure(c, 404, "RESOURCE_NOT_FOUND", "邀请码不存在");
});

app.MapGet("/api/v1/auth/sessions/{sessionId}", (string sessionId, HttpContext c, IAuthRepository repository) =>
{
    var caller = GetGatewayUser(c, gatewayKey); if (caller is null) return Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
    var session = repository.FindSession(sessionId); return session is null || session.UserId != caller ? Failure(c, 404, "RESOURCE_NOT_FOUND", "会话不存在") : Results.Ok(ApiSuccess.Create(session.ToContract(), c.TraceIdentifier));
});
app.MapDelete("/api/v1/auth/sessions/{sessionId}", (string sessionId, HttpContext c, IAuthRepository repository) =>
{
    var caller = GetGatewayUser(c, gatewayKey); if (caller is null) return Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
    return repository.RevokeSession(sessionId, caller) ? Results.NoContent() : Failure(c, 404, "RESOURCE_NOT_FOUND", "会话不存在");
});
app.MapPost("/api/v1/auth/tokens", (RefreshTokenRequest request, HttpContext c, IAuthRepository repository) =>
{
    var session = repository.Rotate(request.RefreshToken); return session is null ? Failure(c, 401, "AUTH_REQUIRED", "刷新令牌无效") : Results.Created("/api/v1/auth/tokens", ApiSuccess.Create(session.ToTokenPair(), c.TraceIdentifier));
});
app.MapPost("/api/v1/auth/password-reset-requests", async (PasswordResetRequest request, HttpContext c, IAuthRepository repository, PasswordResetEmailSender emailSender) =>
{
    if (!ValidEmail(request.Email)) return Failure(c, 400, "VALIDATION_ERROR", "请输入有效的邮箱地址");
    var credential = repository.FindCredential(request.Email.Trim().ToLowerInvariant());
    if (credential is null) return Failure(c, 404, "RESOURCE_NOT_FOUND", "该邮箱未注册");
    var resetToken = repository.CreatePasswordReset(credential.UserId);
    var delivered = await emailSender.SendAsync(credential.Email, resetToken, c.TraceIdentifier, c.RequestAborted);
    if (!delivered) repository.DeletePasswordReset(resetToken);
    return Results.Accepted();
});
app.MapPost("/api/v1/auth/password-resets", (PasswordResetConfirmation request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
{
    if (!ValidPassword(request.NewPassword)) return Failure(c, 422, "BUSINESS_RULE_VIOLATION", "新密码不符合安全要求");
    var credential = repository.ConsumePasswordReset(request.ResetToken); if (credential is null) return Failure(c, 422, "BUSINESS_RULE_VIOLATION", "重置令牌无效或已过期");
    repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword) }); repository.RevokeAllSessions(credential.UserId); return Results.NoContent();
}).RequireRateLimiting("password-reset-confirmation");
app.MapPost("/internal/v1/auth/introspections", (TokenIntrospectionRequest request, HttpContext c, IAuthRepository repository) =>
{
    if (!IsGateway(c, gatewayKey)) return Failure(c, 403, "FORBIDDEN", "仅允许 Gateway 调用令牌内省接口");
    var session = repository.FindByAccessToken(request.Token);
    var result = session is { Status: "ACTIVE" } && session.AccessExpiresAt > DateTimeOffset.UtcNow
        ? new TokenIntrospection(true, session.UserId, session.SessionId, ["user"], session.AccessExpiresAt)
        : new TokenIntrospection(false, null, null, [], null);
    return Results.Ok(ApiSuccess.Create(result, c.TraceIdentifier));
});
app.Run();

static async Task<bool> CreateProfileAsync(HttpClient client, string key, string correlationId, string userId, string displayName, CancellationToken cancellation)
{
    using var request = new HttpRequestMessage(HttpMethod.Post, "/internal/v1/users") { Content = JsonContent.Create(new { userId, displayName, locale = "zh-CN" }) };
    request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
    try { using var response = await client.SendAsync(request, cancellation); return response.IsSuccessStatusCode || response.StatusCode == System.Net.HttpStatusCode.Conflict; } catch (HttpRequestException) { return false; }
}
static async Task<Dictionary<string, string>?> LookupProfileDisplayNamesAsync(HttpClient client, string key, string correlationId, string[] userIds, CancellationToken cancellation)
{
    if (userIds.Length == 0) return new Dictionary<string, string>(StringComparer.Ordinal);
    using var request = new HttpRequestMessage(HttpMethod.Post, "/internal/v1/users/profile-lookups") { Content = JsonContent.Create(new { userIds }) };
    request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
    try
    {
        using var response = await client.SendAsync(request, cancellation);
        if (!response.IsSuccessStatusCode) return null;
        var envelope = await response.Content.ReadFromJsonAsync<ApiEnvelope<AdminProfileSummary[]>>(cancellationToken: cancellation);
        return envelope?.Data?.ToDictionary(profile => profile.UserId, profile => profile.DisplayName, StringComparer.Ordinal) ?? new Dictionary<string, string>(StringComparer.Ordinal);
    }
    catch (HttpRequestException) { return null; }
}
static async Task<bool> DeleteUserProfileAsync(HttpClient client, string key, string correlationId, string userId, CancellationToken cancellation)
{
    using var request = new HttpRequestMessage(HttpMethod.Delete, $"/internal/v1/users/{Uri.EscapeDataString(userId)}");
    request.Headers.Add("X-Service-Name", "AuthService"); request.Headers.Add("X-Service-Key", key); request.Headers.Add("X-Correlation-Id", correlationId);
    try
    {
        using var response = await client.SendAsync(request, cancellation);
        return response.IsSuccessStatusCode || response.StatusCode == System.Net.HttpStatusCode.NotFound;
    }
    catch (HttpRequestException) { return false; }
}
static bool IsGateway(HttpContext c, string key)
{
    var values = c.Request.Headers["X-Gateway-Key"];
    return values.Count == 1 && FixedTimeEquals(values[0]!, key);
}
static string? GetGatewayUser(HttpContext c, string key) => IsGateway(c, key) && !string.IsNullOrWhiteSpace(c.Request.Headers["X-User-Id"]) ? c.Request.Headers["X-User-Id"].ToString() : null;
static bool ValidEmail(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 320 && value.Contains('@');
static bool ValidName(string? value) => !string.IsNullOrWhiteSpace(value) && value.Trim().Length is >= 1 and <= 64;
static bool ValidPassword(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length >= 8;
static string? NormalizeInvitationCode(string? value) => string.IsNullOrWhiteSpace(value) || value.Trim().Length > 32 ? null : value.Trim().ToUpperInvariant();
static bool PasswordMatches(IPasswordHasher<Credential> hasher, Credential credential, string password)
{
    try { return hasher.VerifyHashedPassword(credential, credential.PasswordHash, password) is not PasswordVerificationResult.Failed; }
    catch (FormatException) { return false; }
    catch (ArgumentException) { return false; }
}
static IResult Failure(HttpContext c, int status, string code, string message) => Results.Json(ApiFailure.Create(code, message, c.TraceIdentifier), statusCode: status);
static bool FixedTimeEquals(string left, string right)
{
    var leftBytes = System.Text.Encoding.UTF8.GetBytes(left);
    var rightBytes = System.Text.Encoding.UTF8.GetBytes(right);
    var length = Math.Max(leftBytes.Length, rightBytes.Length);
    var paddedLeft = new byte[length];
    var paddedRight = new byte[length];
    leftBytes.CopyTo(paddedLeft, 0);
    rightBytes.CopyTo(paddedRight, 0);
    return CryptographicOperations.FixedTimeEquals(paddedLeft, paddedRight) && leftBytes.Length == rightBytes.Length;
}
static bool IsAdmin(HttpContext c, string key) => GetGatewayUser(c, key) == "00000000-0000-0000-0000-000000000001";

public sealed record RegistrationRequest(string Email, string Password, string DisplayName, string InvitationCode, string? DeviceName);
public sealed record LoginRequest(string Email, string Password, string? DeviceName);
public sealed record AdminLoginRequest(string Username, string Password);
public sealed record AdminResetPasswordRequest(string NewPassword);
public sealed record PasswordChangeRequest(string CurrentPassword, string NewPassword);
public sealed record AccountDeletionRequest(string CurrentPassword);
public sealed record CreateInvitationRequest(string Type, int? MaxUses, DateTimeOffset? ValidFrom, DateTimeOffset? ValidTo);
public sealed record AdminUser(string Id, string Email, string DisplayName, bool IsActive);
public sealed record AdminInvitation(string Code, string Type, int MaxUses, int UsedCount, DateTimeOffset? ValidFrom, DateTimeOffset? ValidTo, DateTimeOffset CreatedAt);
public sealed record AdminAccount(string Id, string Email);
public sealed record AdminProfileSummary(string UserId, string DisplayName);
public sealed record ApiEnvelope<T>(T Data);
public sealed record RefreshTokenRequest(string RefreshToken); public sealed record PasswordResetRequest(string Email); public sealed record PasswordResetConfirmation(string ResetToken, string NewPassword); public sealed record TokenIntrospectionRequest(string Token);
public sealed record AuthSession(string SessionId, string UserId, string Status, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt);
public sealed record TokenPair(string AccessToken, string RefreshToken, string TokenType, int ExpiresInSeconds);
public sealed record AuthSessionResponse(AuthSession Session, TokenPair Tokens);
public sealed record TokenIntrospection(bool Active, string? UserId, string? SessionId, string[] Scopes, DateTimeOffset? ExpiresAt);
public sealed record ApiError(string Code, string Message, object Details); public sealed record ApiSuccess(object Data, object Meta, string TraceId) { public static ApiSuccess Create(object data, string id) => new(data, new { }, id); } public sealed record ApiFailure(object? Data, ApiError Error, string TraceId) { public static ApiFailure Create(string code, string message, string id) => new(null, new ApiError(code, message, new { }), id); }
public sealed record AdminAuditRecord(string AuditId, string ActorUserId, string Action, string? TargetUserId, string? TargetInvitationCode, string Outcome, string TraceId, DateTimeOffset CreatedAt)
{
    public static AdminAuditRecord Create(string actorUserId, string action, string? targetUserId, string? targetInvitationCode, string outcome, string traceId) =>
        new(Guid.NewGuid().ToString(), actorUserId, action, targetUserId, targetInvitationCode, outcome, traceId, DateTimeOffset.UtcNow);
}
public enum RegistrationOutcome { Created, EmailAlreadyRegistered, InvitationUnavailable }
public sealed record Credential(string UserId, string Email, string PasswordHash) { public static Credential New(string email) => new(Guid.NewGuid().ToString(), email, string.Empty); }
public sealed record StoredSession(string SessionId, string UserId, string AccessToken, string RefreshToken, DateTimeOffset CreatedAt, DateTimeOffset AccessExpiresAt, DateTimeOffset RefreshExpiresAt, DateTimeOffset? RevokedAt)
{
    public string Status => RevokedAt is not null ? "REVOKED" : RefreshExpiresAt <= DateTimeOffset.UtcNow ? "EXPIRED" : "ACTIVE";
    public AuthSession ToContract() => new(SessionId, UserId, Status, CreatedAt, RefreshExpiresAt);
    public TokenPair ToTokenPair() => new(AccessToken, RefreshToken, "Bearer", Math.Max(0, (int)(AccessExpiresAt - DateTimeOffset.UtcNow).TotalSeconds));
    public AuthSessionResponse ToResponse() => new(ToContract(), ToTokenPair());
}

public sealed class MySqlAuthRepository(AuthDatabase database) : IAuthRepository
{
    public RegistrationOutcome TryCreateCredentialWithInvitation(Credential value, string invitationCode)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT type,max_uses,used_count,valid_from,valid_to FROM admin_invitations WHERE code=@code LIMIT 1 FOR UPDATE;";
        command.Parameters.AddWithValue("@code", invitationCode);
        var foundInvitation = false;
        string? type = null;
        var maxUses = 0;
        var usedCount = 0;
        DateTime? validFrom = null;
        DateTime? validTo = null;
        using (var reader = command.ExecuteReader())
        {
            if (reader.Read())
            {
                foundInvitation = true;
                type = reader.GetString(0);
                maxUses = reader.GetInt32(1);
                usedCount = reader.GetInt32(2);
                validFrom = reader.IsDBNull(3) ? null : reader.GetDateTime(3);
                validTo = reader.IsDBNull(4) ? null : reader.GetDateTime(4);
            }
        }

        if (!foundInvitation) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        var now = DateTime.UtcNow;
        var timeWindowIsValid = type != "time-window" || (validFrom is not null && validTo is not null && validFrom <= now && validTo >= now);
        if (usedCount >= maxUses || !timeWindowIsValid) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        try
        {
            command.Parameters.Clear();
            command.CommandText = "INSERT INTO auth_credentials (user_id,email,password_hash) VALUES (@id,@email,@hash);";
            command.Parameters.AddWithValue("@id", value.UserId); command.Parameters.AddWithValue("@email", value.Email); command.Parameters.AddWithValue("@hash", value.PasswordHash);
            command.ExecuteNonQuery();
        }
        catch (MySqlException exception) when (exception.Number == 1062)
        {
            transaction.Rollback();
            return RegistrationOutcome.EmailAlreadyRegistered;
        }
        command.Parameters.Clear();
        command.CommandText = "UPDATE admin_invitations SET used_count=used_count+1 WHERE code=@code AND used_count<max_uses;";
        command.Parameters.AddWithValue("@code", invitationCode);
        if (command.ExecuteNonQuery() != 1) { transaction.Rollback(); return RegistrationOutcome.InvitationUnavailable; }
        transaction.Commit();
        return RegistrationOutcome.Created;
    }
    public void RollbackRegistration(string userId, string invitationCode)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM auth_credentials WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", userId);
        var deleted = command.ExecuteNonQuery();
        if (deleted == 1)
        {
            command.Parameters.Clear();
            command.CommandText = "UPDATE admin_invitations SET used_count=used_count-1 WHERE code=@code AND used_count>0;";
            command.Parameters.AddWithValue("@code", invitationCode);
            command.ExecuteNonQuery();
        }
        transaction.Commit();
    }
    public void DeleteCredential(string id) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",id);q.ExecuteNonQuery(); }
    public bool DeleteAccount(string userId)
    {
        using var connection = database.OpenConnection(); using var transaction = connection.BeginTransaction(); using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT CAST(user_id AS CHAR) FROM auth_credentials WHERE user_id=@id LIMIT 1 FOR UPDATE;";
        command.Parameters.AddWithValue("@id", userId);
        if (command.ExecuteScalar() is null) { transaction.Rollback(); return false; }
        command.Parameters.Clear();
        command.CommandText = "DELETE FROM auth_sessions WHERE user_id=@id; DELETE FROM auth_password_resets WHERE user_id=@id; DELETE FROM admin_user_overrides WHERE user_id=@id; DELETE FROM auth_credentials WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", userId);
        command.ExecuteNonQuery();
        transaction.Commit();
        return true;
    }
    public Credential? FindCredential(string email) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE email=@email;";q.Parameters.AddWithValue("@email",email);using var r=q.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null; }
    public Credential? FindCredentialById(string userId) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);using var r=q.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null; }
    public StoredSession CreateSession(string userId,string? deviceName) { var now=DateTimeOffset.UtcNow;var s=new StoredSession(Guid.NewGuid().ToString(),userId,Token(),Token(),now,now.AddMinutes(15),now.AddDays(7),null); InsertSession(s);return s; }
    public StoredSession? FindSession(string id) => FindSession("session_id",id,false); public StoredSession? FindByAccessToken(string token)=>FindSession("access_hash",Hash(token),true);
    public bool RevokeSession(string sessionId,string userId) { using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE session_id=@id AND user_id=@user AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",sessionId);q.Parameters.AddWithValue("@user",userId);return q.ExecuteNonQuery()==1; }
    public StoredSession? Rotate(string refresh) { var old=FindSession("refresh_hash",Hash(refresh),true); if(old is null||old.Status!="ACTIVE")return null;using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE session_id=@id AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",old.SessionId);q.ExecuteNonQuery();return CreateSession(old.UserId,null); }
    public void RevokeAllSessions(string userId){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_sessions SET revoked_at=UTC_TIMESTAMP(6) WHERE user_id=@id AND revoked_at IS NULL;";q.Parameters.AddWithValue("@id",userId);q.ExecuteNonQuery();}
    public void UpdatePassword(Credential credential){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="UPDATE auth_credentials SET password_hash=@hash WHERE user_id=@id;";q.Parameters.AddWithValue("@id",credential.UserId);q.Parameters.AddWithValue("@hash",credential.PasswordHash);q.ExecuteNonQuery();}
    public string CreatePasswordReset(string userId)
    {
        var token = PasswordResetToken();
        using var c = database.OpenConnection();
        using var tx = c.BeginTransaction();
        using var q = c.CreateCommand();
        q.Transaction = tx;
        q.CommandText = "DELETE FROM auth_password_resets WHERE user_id=@user AND used_at IS NULL;";
        q.Parameters.AddWithValue("@user", userId);
        q.ExecuteNonQuery();
        q.Parameters.Clear();
        q.CommandText = "INSERT INTO auth_password_resets (token_hash,user_id,expires_at,used_at) VALUES (@hash,@user,@expires,NULL);";
        q.Parameters.AddWithValue("@hash", Hash(token));
        q.Parameters.AddWithValue("@user", userId);
        q.Parameters.AddWithValue("@expires", DateTime.UtcNow.AddMinutes(10));
        q.ExecuteNonQuery();
        tx.Commit();
        return token;
    }
    public void DeletePasswordReset(string token){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM auth_password_resets WHERE token_hash=@hash AND used_at IS NULL;";q.Parameters.AddWithValue("@hash",Hash(token));q.ExecuteNonQuery();}
    public Credential? ConsumePasswordReset(string token){if(token.Length!=6||token.Any(character=>!char.IsAsciiDigit(character)))return null;using var c=database.OpenConnection();using var tx=c.BeginTransaction();using var q=c.CreateCommand();q.Transaction=tx;q.CommandText="SELECT CAST(user_id AS CHAR) FROM auth_password_resets WHERE token_hash=@hash AND used_at IS NULL AND expires_at>UTC_TIMESTAMP(6) LIMIT 1 FOR UPDATE;";q.Parameters.AddWithValue("@hash",Hash(token));var rawUser=q.ExecuteScalar();var user=rawUser is null?null:DbText(rawUser);if(user is null){tx.Rollback();return null;}q.Parameters.Clear();q.CommandText="UPDATE auth_password_resets SET used_at=UTC_TIMESTAMP(6) WHERE token_hash=@hash;";q.Parameters.AddWithValue("@hash",Hash(token));q.ExecuteNonQuery();tx.Commit();using var q2=c.CreateCommand();q2.CommandText="SELECT CAST(user_id AS CHAR),email,password_hash FROM auth_credentials WHERE user_id=@id;";q2.Parameters.AddWithValue("@id",user);using var r=q2.ExecuteReader();return r.Read()?new Credential(DbText(r.GetValue(0)),r.GetString(1),r.GetString(2)):null;}
    private void InsertSession(StoredSession s){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="INSERT INTO auth_sessions (session_id,user_id,access_hash,refresh_hash,created_at,access_expires_at,refresh_expires_at,revoked_at) VALUES (@id,@user,@access,@refresh,@created,@accessExpires,@refreshExpires,NULL);";q.Parameters.AddWithValue("@id",s.SessionId);q.Parameters.AddWithValue("@user",s.UserId);q.Parameters.AddWithValue("@access",Hash(s.AccessToken));q.Parameters.AddWithValue("@refresh",Hash(s.RefreshToken));q.Parameters.AddWithValue("@created",s.CreatedAt.UtcDateTime);q.Parameters.AddWithValue("@accessExpires",s.AccessExpiresAt.UtcDateTime);q.Parameters.AddWithValue("@refreshExpires",s.RefreshExpiresAt.UtcDateTime);q.ExecuteNonQuery();}
    private StoredSession? FindSession(string column,string value,bool hashed){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText=$"SELECT CAST(session_id AS CHAR),CAST(user_id AS CHAR),created_at,access_expires_at,refresh_expires_at,revoked_at FROM auth_sessions WHERE {column}=@value LIMIT 1;";q.Parameters.AddWithValue("@value",value);using var r=q.ExecuteReader();return r.Read()?new StoredSession(DbText(r.GetValue(0)),DbText(r.GetValue(1)),string.Empty,string.Empty,AsUtc(r.GetDateTime(2)),AsUtc(r.GetDateTime(3)),AsUtc(r.GetDateTime(4)),r.IsDBNull(5)?null:AsUtc(r.GetDateTime(5))):null;}
    private static string Token()=>Convert.ToBase64String(RandomNumberGenerator.GetBytes(48)).Replace('+','-').Replace('/','_').TrimEnd('='); private static string PasswordResetToken()=>RandomNumberGenerator.GetInt32(1_000_000).ToString("D6"); private static string Hash(string value)=>Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value)));private static string DbText(object value)=>value is Guid guid?guid.ToString():Convert.ToString(value)!;private static DateTimeOffset AsUtc(DateTime value)=>new(DateTime.SpecifyKind(value,DateTimeKind.Utc));
}

public sealed class MySqlAdminRepository(AuthDatabase database) : IAdminRepository
{
    public List<AdminAccount> ListUsers()
    {
        using var c = database.OpenConnection(); using var q = c.CreateCommand();
        q.CommandText = "SELECT CAST(user_id AS CHAR), email FROM auth_credentials ORDER BY email;";
        using var r = q.ExecuteReader(); var result = new List<AdminAccount>();
        while (r.Read()) result.Add(new AdminAccount(DbText(r.GetValue(0)), DbText(r.GetValue(1))));
        return result;
    }
    public bool UserExists(string userId)
    {
        using var c = database.OpenConnection(); using var q = c.CreateCommand();
        q.CommandText = "SELECT COUNT(*) FROM auth_credentials WHERE user_id=@id;";
        q.Parameters.AddWithValue("@id", userId);
        return Convert.ToInt32(q.ExecuteScalar()) == 1;
    }
    public bool DeleteAuthUser(string userId)
    {
        using var c=database.OpenConnection();using var tx=c.BeginTransaction();using var q=c.CreateCommand();q.Transaction=tx;
        q.CommandText="SELECT COUNT(*) FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);if(Convert.ToInt32(q.ExecuteScalar())==0){tx.Rollback();return false;}
        q.Parameters.Clear();q.CommandText="DELETE FROM auth_sessions WHERE user_id=@id; DELETE FROM auth_password_resets WHERE user_id=@id; DELETE FROM admin_user_overrides WHERE user_id=@id; DELETE FROM auth_credentials WHERE user_id=@id;";q.Parameters.AddWithValue("@id",userId);q.ExecuteNonQuery();tx.Commit();return true;
    }
    public List<AdminInvitation> ListInvitations()
    {
        using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="SELECT code,type,max_uses,used_count,valid_from,valid_to,created_at FROM admin_invitations ORDER BY created_at DESC;";using var r=q.ExecuteReader();var result=new List<AdminInvitation>();
        while(r.Read())result.Add(new AdminInvitation(r.GetString(0),r.GetString(1),r.GetInt32(2),r.GetInt32(3),r.IsDBNull(4)?null:Utc(r.GetDateTime(4)),r.IsDBNull(5)?null:Utc(r.GetDateTime(5)),Utc(r.GetDateTime(6))));return result;
    }
    public AdminInvitation? CreateInvitation(CreateInvitationRequest request)
    {
        var type=request.Type?.Trim().ToLowerInvariant();if(type is not ("single-use" or "multi-use" or "time-window"))return null;var max=type=="single-use"?1:request.MaxUses.GetValueOrDefault(10);if(max is <1 or >10000||(type=="time-window"&&(!request.ValidFrom.HasValue||!request.ValidTo.HasValue||request.ValidTo<=request.ValidFrom)))return null;
        for(var i=0;i<3;i++){var value=new AdminInvitation("MS-"+Convert.ToHexString(RandomNumberGenerator.GetBytes(5)),type,max,0,request.ValidFrom,request.ValidTo,DateTimeOffset.UtcNow);try{using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="INSERT INTO admin_invitations (code,type,max_uses,used_count,valid_from,valid_to,created_at) VALUES (@code,@type,@max,0,@from,@to,@created);";q.Parameters.AddWithValue("@code",value.Code);q.Parameters.AddWithValue("@type",value.Type);q.Parameters.AddWithValue("@max",value.MaxUses);q.Parameters.AddWithValue("@from",value.ValidFrom?.UtcDateTime??(object)DBNull.Value);q.Parameters.AddWithValue("@to",value.ValidTo?.UtcDateTime??(object)DBNull.Value);q.Parameters.AddWithValue("@created",value.CreatedAt.UtcDateTime);q.ExecuteNonQuery();return value;}catch(MySqlException ex)when(ex.Number==1062){}}return null;
    }
    public bool DeleteInvitation(string code){using var c=database.OpenConnection();using var q=c.CreateCommand();q.CommandText="DELETE FROM admin_invitations WHERE code=@code;";q.Parameters.AddWithValue("@code",code);return q.ExecuteNonQuery()==1;}
    private static string DbText(object value)=>value is Guid guid?guid.ToString():Convert.ToString(value)!;private static DateTimeOffset Utc(DateTime value)=>new(DateTime.SpecifyKind(value,DateTimeKind.Utc));
}

public sealed class MySqlAdminAuditRepository(AuthDatabase database) : IAdminAuditRepository
{
    public void Write(AdminAuditRecord record)
    {
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO admin_audit_logs (audit_id,actor_user_id,action,target_user_id,target_invitation_code,outcome,trace_id,created_at) VALUES (@auditId,@actorUserId,@action,@targetUserId,@targetInvitationCode,@outcome,@traceId,@createdAt);";
        command.Parameters.AddWithValue("@auditId", record.AuditId);
        command.Parameters.AddWithValue("@actorUserId", record.ActorUserId);
        command.Parameters.AddWithValue("@action", record.Action);
        command.Parameters.AddWithValue("@targetUserId", record.TargetUserId ?? (object)DBNull.Value);
        command.Parameters.AddWithValue("@targetInvitationCode", record.TargetInvitationCode ?? (object)DBNull.Value);
        command.Parameters.AddWithValue("@outcome", record.Outcome);
        command.Parameters.AddWithValue("@traceId", record.TraceId);
        command.Parameters.AddWithValue("@createdAt", record.CreatedAt.UtcDateTime);
        command.ExecuteNonQuery();
    }
}
