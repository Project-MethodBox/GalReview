using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Identity;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(
    options => options.ThrowOnBadRequest = true);
var isMockMode = string.Equals(Environment.GetEnvironmentVariable("MOONSTONE_MODE"), "Mock", StringComparison.OrdinalIgnoreCase);
var connectionString = builder.Configuration.GetConnectionString("AuthDatabase");
if (!isMockMode && string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("ConnectionStrings:AuthDatabase must be configured.");
var gatewayKey = builder.Configuration["Gateway:ServiceKey"] ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
var gatewayBaseUrl = builder.Configuration["Gateway:BaseUrl"] ?? "http://localhost:5000";
var gatewayUri = new Uri(gatewayBaseUrl, UriKind.Absolute);
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
builder.Services.AddHttpClient("gateway", client => client.BaseAddress = gatewayUri);
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.OnRejected = async (context, cancellationToken) =>
    {
        context.HttpContext.Response.ContentType = "application/json";
        await context.HttpContext.Response.WriteAsJsonAsync(
            ApiFailure.Create(
                "RATE_LIMITED",
                "请求过于频繁，请稍后重试",
                context.HttpContext.TraceIdentifier),
            cancellationToken);
    };
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
    if (exception is UpstreamContractException)
    {
        context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("AuthService")
            .LogError(exception, "UserService returned an invalid response contract. CorrelationId: {CorrelationId}; Path: {Path}", context.TraceIdentifier, context.Request.Path);
        return Results.Json(
            ApiFailure.Create("UPSTREAM_CONTRACT_INVALID", "用户资料服务响应不符合契约", context.TraceIdentifier),
            statusCode: StatusCodes.Status502BadGateway).ExecuteAsync(context);
    }
    if (exception is BadHttpRequestException or System.Text.Json.JsonException)
    {
        context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("AuthService")
            .LogWarning(exception, "Invalid AuthService request. CorrelationId: {CorrelationId}; Path: {Path}", context.TraceIdentifier, context.Request.Path);
        return Results.Json(
            ApiFailure.Create("VALIDATION_ERROR", "请求 JSON、参数或字段格式错误", context.TraceIdentifier),
            statusCode: StatusCodes.Status400BadRequest).ExecuteAsync(context);
    }
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

    if (!AuthHelpers.IsGateway(context, gatewayKey))
    {
        await AuthHelpers.Failure(context, 403, "FORBIDDEN", "该服务仅接受经 API Gateway 转发的请求").ExecuteAsync(context);
        return;
    }

    await next();
});
app.UseRateLimiter();

app.MapGet("/healthz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "live" }, c.TraceIdentifier)));
app.MapGet("/readyz", (HttpContext c) => Results.Ok(ApiSuccess.Create(new { status = "ready", storage = storageName }, c.TraceIdentifier)));

app.MapAuthEndpoints(gatewayKey, adminUsername, adminPassword);

app.Run();
