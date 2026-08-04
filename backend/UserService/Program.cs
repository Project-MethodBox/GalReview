using System.Text.Json;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Diagnostics;
using MySqlConnector;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(
    options => options.ThrowOnBadRequest = true);
var isMockMode = string.Equals(Environment.GetEnvironmentVariable("MOONSTONE_MODE"), "Mock", StringComparison.OrdinalIgnoreCase);
var connectionString = builder.Configuration.GetConnectionString("UserDatabase");
if (!isMockMode && string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("ConnectionStrings:UserDatabase must be configured.");
// 安全门：MySQL 连接必须启用 SSL（SslMode=Required/VerifyCA/VerifyFull），
// 禁止 AllowPublicKeyRetrieval（明文传输密码的降级攻击面）。
// Mock 模式无需 MySQL，跳过校验。
if (!isMockMode)
{
    var csBuilder = new MySqlConnectionStringBuilder(connectionString!);
    if (csBuilder.AllowPublicKeyRetrieval)
        throw new InvalidOperationException("ConnectionStrings:UserDatabase 禁止启用 AllowPublicKeyRetrieval（明文密码风险）。");
    if (csBuilder.SslMode is not (MySqlSslMode.Required or MySqlSslMode.VerifyCA or MySqlSslMode.VerifyFull))
        throw new InvalidOperationException("ConnectionStrings:UserDatabase 必须启用 SSL（SslMode=Required 或更高）。");
}
var gatewayKey = builder.Configuration["Gateway:ServiceKey"]
    ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
var storageName = isMockMode ? "memory" : "mysql";
if (isMockMode)
{
    builder.Services.AddSingleton<IUserRepository, InMemoryUserRepository>();
}
else
{
    builder.Services.AddSingleton(new UserDatabase(connectionString!));
    builder.Services.AddSingleton<IUserRepository, MySqlUserRepository>();
}
var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);

var app = builder.Build();
if (!isMockMode) app.Services.GetRequiredService<UserDatabase>().EnsureCreated();
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
    if (exception is BadHttpRequestException or JsonException)
    {
        context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("UserService")
            .LogWarning(exception, "Invalid UserService request. CorrelationId: {CorrelationId}", context.TraceIdentifier);
        return Results.Json(
            ApiFailure.Create("VALIDATION_ERROR", "请求 JSON、参数或字段格式错误", context.TraceIdentifier),
            statusCode: StatusCodes.Status400BadRequest).ExecuteAsync(context);
    }
    context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("UserService")
        .LogError(exception, "Unhandled UserService error. CorrelationId: {CorrelationId}", context.TraceIdentifier);
    return Results.Json(ApiFailure.Create("INTERNAL_ERROR", "用户服务暂时不可用", context.TraceIdentifier), statusCode: 500).ExecuteAsync(context);
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

app.MapGet("/healthz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "live" }, c.TraceIdentifier)));
app.MapGet("/readyz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "ready", storage = storageName }, c.TraceIdentifier)));

app.MapPost("/internal/v1/users", (CreateUserProfileRequest request, HttpContext c, IUserRepository users) =>
{
    if (!IsGateway(c, gatewayKey) || !string.Equals(c.Request.Headers["X-Service-Name"], "AuthService", StringComparison.Ordinal))
        return Failure(c, 403, "FORBIDDEN", "仅允许经 Gateway 的 AuthService 创建用户资料");
    if (!Guid.TryParse(request.UserId, out _) || !UserProfileValidation.IsValidDisplayName(request.DisplayName))
        return Failure(c, 400, "VALIDATION_ERROR", "userId 和 displayName 不符合要求");

    var profile = UserProfile.New(request.UserId, request.DisplayName.Trim(), NormalizeLocale(request.Locale));
    return users.TryCreate(profile)
        ? Results.Created($"/api/v1/users/{profile.UserId}", ApiSuccess.Create(profile, c.TraceIdentifier))
        : Failure(c, 409, "STATE_CONFLICT", "用户资料已存在");
});

app.MapPost("/internal/v1/users/profile-lookups", (AdminProfileLookupRequest request, HttpContext c, IUserRepository users) =>
{
    if (!IsAuthService(c, gatewayKey))
        return Failure(c, 403, "FORBIDDEN", "仅允许经 Gateway 的 AuthService 查询用户资料");
    return AdminProfileLookupHandler.Handle(request, c, users);
});

app.MapDelete("/internal/v1/users/{userId}", (string userId, HttpContext c, IUserRepository users) =>
{
    if (!IsAuthService(c, gatewayKey))
        return Failure(c, 403, "FORBIDDEN", "仅允许经 Gateway 的 AuthService 删除用户资料");
    if (!Guid.TryParse(userId, out _))
        return Failure(c, 400, "VALIDATION_ERROR", "userId 不符合要求");
    return users.DeleteProfile(userId)
        ? Results.NoContent()
        : Failure(c, 404, "RESOURCE_NOT_FOUND", "用户资料不存在");
});

app.MapGet("/api/v1/users/me", (HttpContext c, IUserRepository users) =>
{
    var userId = GetUserId(c, gatewayKey);
    return userId is null ? Failure(c, 401, "AUTH_REQUIRED", "需要有效登录状态")
        : users.FindProfile(userId) is { } profile ? Results.Ok(ApiSuccess.Create(profile, c.TraceIdentifier))
        : Failure(c, 404, "RESOURCE_NOT_FOUND", "用户资料不存在");
});

app.MapMethods("/api/v1/users/me", ["PATCH", "PUT"], async (HttpContext c, IUserRepository users) =>
{
    var userId = GetUserId(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要有效登录状态");
    return await UserProfileUpdateHandler.HandleAsync(
        userId,
        c,
        users,
        jsonOptions);
});

app.MapGet("/api/v1/users/me/preferences", (HttpContext c, IUserRepository users) =>
{
    var userId = GetUserId(c, gatewayKey);
    return userId is null ? Failure(c, 401, "AUTH_REQUIRED", "需要有效登录状态")
        : users.FindPreferences(userId) is { } preferences ? Results.Ok(ApiSuccess.Create(preferences, c.TraceIdentifier))
        : Failure(c, 404, "RESOURCE_NOT_FOUND", "用户资料不存在");
});

app.MapPut("/api/v1/users/me/preferences", async (HttpContext c, IUserRepository users) =>
{
    var userId = GetUserId(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要有效登录状态");
    return await UserPreferencesUpdateHandler.HandleAsync(
        userId,
        c,
        users,
        jsonOptions);
});

app.Run();

static bool IsGateway(HttpContext context, string key)
{
    var values = context.Request.Headers["X-Gateway-Key"];
    return values.Count == 1 && FixedTimeEquals(values[0]!, key);
}
static bool IsAuthService(HttpContext context, string key) =>
    IsGateway(context, key) && string.Equals(context.Request.Headers["X-Service-Name"], "AuthService", StringComparison.Ordinal);
static string? GetUserId(HttpContext context, string key)
{
    var userId = context.Request.Headers["X-User-Id"].FirstOrDefault();
    return IsGateway(context, key) && !string.IsNullOrWhiteSpace(userId) ? userId : null;
}
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
static string NormalizeLocale(string? value) => string.IsNullOrWhiteSpace(value) ? "zh-CN" : value.Trim();
static IResult Failure(HttpContext context, int status, string code, string message) => Results.Json(ApiFailure.Create(code, message, context.TraceIdentifier), statusCode: status);

public sealed record CreateUserProfileRequest(string UserId, string DisplayName, string? Locale);
public sealed record AdminProfileLookupRequest(string[]? UserIds);
public sealed record AdminProfileSummary(string UserId, string DisplayName);
public sealed record UpdateUserProfileRequest(string? DisplayName, string? Locale, string[]? PreferredSubjectCodes);
public sealed record UserPreferencesInput(int DailyGoalMinutes, string ContentDifficulty, bool ReducedMotion);
public sealed record UserProfile(string UserId, string DisplayName, string? AvatarUrl, string Locale, string[] PreferredSubjectCodes, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt)
{
    public static UserProfile New(string userId, string displayName, string locale) => new(userId, displayName, null, locale, [], DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
}
public sealed record UserPreferences(int DailyGoalMinutes, string ContentDifficulty, bool ReducedMotion, DateTimeOffset UpdatedAt);
public sealed record ApiError(string Code, string Message, object Details);
public sealed record ApiSuccess(object Data, object Meta, string TraceId) { public static ApiSuccess Create(object data, string traceId) => new(data, new { }, traceId); }
public sealed record ApiFailure(object? Data, ApiError Error, string TraceId) { public static ApiFailure Create(string code, string message, string traceId) => new(null, new ApiError(code, message, new { }), traceId); }

public sealed class UserDatabase(string connectionString)
{
    private readonly string _connectionString = connectionString;
    public MySqlConnection OpenConnection() { var connection = new MySqlConnection(_connectionString); connection.Open(); return connection; }
    public void EnsureCreated()
    {
        var builder = new MySqlConnectionStringBuilder(_connectionString);
        if (string.IsNullOrWhiteSpace(builder.Database) || !builder.Database.All(c => char.IsLetterOrDigit(c) || c == '_'))
            throw new InvalidOperationException("Invalid MySQL database name.");
        var database = builder.Database;
        builder.Database = string.Empty;
        using (var server = new MySqlConnection(builder.ConnectionString))
        {
            server.Open();
            using var create = server.CreateCommand();
            create.CommandText = $"CREATE DATABASE IF NOT EXISTS `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;";
            create.ExecuteNonQuery();
        }
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS user_profiles (
              user_id CHAR(36) PRIMARY KEY, display_name VARCHAR(64) NOT NULL,
              avatar_url VARCHAR(2048) NULL, locale VARCHAR(16) NOT NULL,
              preferred_subject_codes JSON NOT NULL, created_at DATETIME(6) NOT NULL,
              updated_at DATETIME(6) NOT NULL
            );
            CREATE TABLE IF NOT EXISTS user_preferences (
              user_id CHAR(36) PRIMARY KEY, daily_goal_minutes INT NOT NULL,
              content_difficulty VARCHAR(16) NOT NULL, reduced_motion BOOLEAN NOT NULL,
              updated_at DATETIME(6) NOT NULL,
              CONSTRAINT fk_preferences_profile FOREIGN KEY (user_id) REFERENCES user_profiles(user_id) ON DELETE CASCADE
            );
            """;
        command.ExecuteNonQuery();
    }
}

public sealed class MySqlUserRepository(UserDatabase database) : IUserRepository
{
    public bool TryCreate(UserProfile profile)
    {
        try
        {
            using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
            command.CommandText = "INSERT INTO user_profiles (user_id, display_name, avatar_url, locale, preferred_subject_codes, created_at, updated_at) VALUES (@id, @displayName, NULL, @locale, @subjects, @created, @updated);";
            command.Parameters.AddWithValue("@id", profile.UserId); command.Parameters.AddWithValue("@displayName", profile.DisplayName); command.Parameters.AddWithValue("@locale", profile.Locale); command.Parameters.AddWithValue("@subjects", JsonSerializer.Serialize(profile.PreferredSubjectCodes)); command.Parameters.AddWithValue("@created", profile.CreatedAt.UtcDateTime); command.Parameters.AddWithValue("@updated", profile.UpdatedAt.UtcDateTime);
            return command.ExecuteNonQuery() == 1;
        }
        catch (MySqlException ex) when (ex.Number == 1062) { return false; }
    }
    public UserProfile? FindProfile(string userId)
    {
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = "SELECT CAST(user_id AS CHAR), display_name, avatar_url, locale, preferred_subject_codes, created_at, updated_at FROM user_profiles WHERE user_id = @id;"; command.Parameters.AddWithValue("@id", userId);
        using var reader = command.ExecuteReader(); return reader.Read() ? ReadProfile(reader) : null;
    }
    public List<AdminProfileSummary> FindAdminProfiles(IReadOnlyList<string> userIds)
    {
        if (userIds.Count == 0) return [];
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        var parameterNames = new List<string>(userIds.Count);
        for (var index = 0; index < userIds.Count; index++)
        {
            var parameterName = $"@id{index}";
            parameterNames.Add(parameterName);
            command.Parameters.AddWithValue(parameterName, userIds[index]);
        }
        command.CommandText = $"SELECT CAST(user_id AS CHAR), display_name FROM user_profiles WHERE user_id IN ({string.Join(',', parameterNames)});";
        using var reader = command.ExecuteReader();
        var result = new List<AdminProfileSummary>();
        while (reader.Read()) result.Add(new AdminProfileSummary(DbText(reader.GetValue(0)), reader.GetString(1)));
        return result;
    }
    public bool DeleteProfile(string userId)
    {
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM user_profiles WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", userId);
        return command.ExecuteNonQuery() == 1;
    }
    public UserProfile? UpdateProfile(string userId, UpdateUserProfileRequest request)
    {
        var current = FindProfile(userId); if (current is null) return null;
        var updated = current with { DisplayName = request.DisplayName?.Trim() ?? current.DisplayName, Locale = request.Locale?.Trim() ?? current.Locale, PreferredSubjectCodes = request.PreferredSubjectCodes ?? current.PreferredSubjectCodes, UpdatedAt = DateTimeOffset.UtcNow };
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand();
        command.CommandText = "UPDATE user_profiles SET display_name=@name, locale=@locale, preferred_subject_codes=@subjects, updated_at=@updated WHERE user_id=@id;";
        command.Parameters.AddWithValue("@id", updated.UserId); command.Parameters.AddWithValue("@name", updated.DisplayName); command.Parameters.AddWithValue("@locale", updated.Locale); command.Parameters.AddWithValue("@subjects", JsonSerializer.Serialize(updated.PreferredSubjectCodes)); command.Parameters.AddWithValue("@updated", updated.UpdatedAt.UtcDateTime); command.ExecuteNonQuery(); return updated;
    }
    public UserPreferences? FindPreferences(string userId)
    {
        if (FindProfile(userId) is null) return null;
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand(); command.CommandText = "SELECT daily_goal_minutes, content_difficulty, reduced_motion, updated_at FROM user_preferences WHERE user_id=@id;"; command.Parameters.AddWithValue("@id", userId);
        using var reader = command.ExecuteReader(); return reader.Read() ? new(reader.GetInt32(0), reader.GetString(1), reader.GetBoolean(2), AsUtc(reader.GetDateTime(3))) : new UserPreferences(30, "STANDARD", false, DateTimeOffset.UtcNow);
    }
    public UserPreferences? ReplacePreferences(string userId, UserPreferencesInput request)
    {
        if (FindProfile(userId) is null) return null;
        var result = new UserPreferences(request.DailyGoalMinutes, request.ContentDifficulty, request.ReducedMotion, DateTimeOffset.UtcNow);
        using var connection = database.OpenConnection(); using var command = connection.CreateCommand(); command.CommandText = "INSERT INTO user_preferences (user_id, daily_goal_minutes, content_difficulty, reduced_motion, updated_at) VALUES (@id,@goal,@difficulty,@motion,@updated) ON DUPLICATE KEY UPDATE daily_goal_minutes=@goal, content_difficulty=@difficulty, reduced_motion=@motion, updated_at=@updated;";
        command.Parameters.AddWithValue("@id", userId); command.Parameters.AddWithValue("@goal", result.DailyGoalMinutes); command.Parameters.AddWithValue("@difficulty", result.ContentDifficulty); command.Parameters.AddWithValue("@motion", result.ReducedMotion); command.Parameters.AddWithValue("@updated", result.UpdatedAt.UtcDateTime); command.ExecuteNonQuery(); return result;
    }
    private static UserProfile ReadProfile(MySqlDataReader r) => new(DbText(r.GetValue(0)), r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2), r.GetString(3), JsonSerializer.Deserialize<string[]>(r.GetString(4)) ?? [], AsUtc(r.GetDateTime(5)), AsUtc(r.GetDateTime(6)));
    private static string DbText(object value) => value is Guid guid ? guid.ToString() : Convert.ToString(value)!;
    private static DateTimeOffset AsUtc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));
}
