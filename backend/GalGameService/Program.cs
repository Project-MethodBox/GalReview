using System.Text.Json.Serialization;
using GalGameService.Background;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;

// ============================================================================
// GalGameService — 游戏生成任务、游戏包与 schema（F15EX 负责）
//
// 端点（§7.1）：
//   POST   /api/v1/game-generations              创建生成任务 (202/422)
//   GET    /api/v1/game-generations/{id}          查询生成任务 (200/404)
//   GET    /api/v1/game-packages/{id}             读取游戏包清单 (200/404)
//   GET    /api/v1/game-packages/{id}/content     下载完整 JSON (200/304/404)
//   POST   /internal/v1/game-package-validations  校验游戏包 (200/422)
// ============================================================================

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();

builder.Services.Configure<Microsoft.AspNetCore.Routing.RouteHandlerOptions>(
    options => options.ThrowOnBadRequest = true);

// 枚举序列化为 JSON 字符串（契约要求字符串 token，整数返回 400）
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter(allowIntegerValues: false));
    options.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase;
});

var gatewayKey = builder.Configuration["Gateway:ServiceKey"]
    ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
var isMockMode = string.Equals(
    builder.Configuration["MOONSTONE_MODE"] ?? Environment.GetEnvironmentVariable("MOONSTONE_MODE"),
    "Mock", StringComparison.OrdinalIgnoreCase);
var useMongoStore = !string.Equals(
    builder.Configuration["GalGameStore:Provider"] ?? Environment.GetEnvironmentVariable("GalGameStore__Provider"),
    "Memory", StringComparison.OrdinalIgnoreCase);
var storageName = (isMockMode, useMongoStore) switch
{
    (true, true) => "mock-mongodb",
    (true, false) => "mock-memory",
    (false, true) => "mongodb",
    (false, false) => "ephemeral-memory",
};

// 叙事生成配置（§7.3.2）
var narrativeSection = builder.Configuration.GetSection(NarrativeGenerationOptions.SectionName);
var narrativeOptions = narrativeSection.Get<NarrativeGenerationOptions>() ?? new NarrativeGenerationOptions();
// Mock 模式强制关闭外部模型调用
if (isMockMode)
    narrativeOptions.Enabled = false;
// 注册为单例供 DeepSeekNarrativeClient 和 NarrativeGenerationService 直接注入
builder.Services.AddSingleton(narrativeOptions);

var narrativeEnabled = narrativeOptions.CanCallProvider;
var narrativeModel = narrativeOptions.Model;
var narrativePromptVersion = narrativeOptions.PromptVersion;

var validationAllowedServices = InternalServiceAccessPolicy.CreateAllowlist(
    builder.Configuration.GetSection("InternalAccess:ValidationAllowedServices"),
    "RenderService");
var packageReaderAllowedServices = InternalServiceAccessPolicy.CreateAllowlist(
    builder.Configuration.GetSection("InternalAccess:PackageReaderAllowedServices"),
    "RenderService");

// HttpClient：经 Gateway 调用 KnowledgeService
builder.Services.AddHttpClient("gateway", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["Gateway:BaseUrl"] ?? "http://localhost:5000");
    client.Timeout = TimeSpan.FromSeconds(45);
});

// HttpClient：叙事生成模型调用（DeepSeek 等 OpenAI 兼容端点）
builder.Services.AddHttpClient("narrative", client =>
{
    client.Timeout = TimeSpan.FromSeconds(Math.Clamp(narrativeOptions.TimeoutSeconds, 10, 300));
    client.MaxResponseContentBufferSize = 2 * 1024 * 1024; // 2 MiB 安全上限
});

// DI 注册
builder.Services.AddSingleton<GamePackageValidator>();
builder.Services.AddSingleton<NarrativePromptBuilder>();
builder.Services.AddSingleton<NarrativeDraftValidator>();
builder.Services.AddSingleton<INarrativeModelClient>(sp => new DeepSeekNarrativeClient(
    sp.GetRequiredService<IHttpClientFactory>(),
    narrativeOptions));
builder.Services.AddSingleton<NarrativeGenerationService>();
if (useMongoStore)
{
    builder.Services.AddSingleton<IGameStore>(sp => new MongoGameStore(
        sp.GetRequiredService<IConfiguration>(),
        sp.GetRequiredService<ILoggerFactory>().CreateLogger<MongoGameStore>(),
        seedGoldenPackage: isMockMode));
}
else
{
    builder.Services.AddSingleton<IGameStore>(_ => new InMemoryGameStore(isMockMode));
}
builder.Services.AddSingleton<PlanGraphClient>(sp => new PlanGraphClient(
    sp.GetRequiredService<IHttpClientFactory>(),
    sp.GetRequiredService<ILoggerFactory>().CreateLogger<PlanGraphClient>(),
    sp.GetRequiredService<IConfiguration>(),
    isMockMode));
builder.Services.AddSingleton<GameGenerator>();
// 后台生成队列 + worker：替换原 fire-and-forget Task.Run。
builder.Services.AddSingleton<GameGenerationQueue>();
builder.Services.AddHostedService<GameGenerationWorker>();

var app = builder.Build();

// ============================================================================
// 启动恢复：将因服务重启而卡在 RUNNING/QUEUED 的生成任务标记为 FAILED
// ============================================================================
if (useMongoStore)
{
    try
    {
        var store = app.Services.GetRequiredService<IGameStore>();
        var recovered = store.RecoverStaleJobs();
        if (recovered > 0)
        {
            var startupLogger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("GalGameService");
            startupLogger.LogWarning("Startup recovery: {Count} stale job(s) marked as FAILED", recovered);
        }
    }
    catch (Exception ex)
    {
        var startupLogger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("GalGameService");
        startupLogger.LogWarning(ex, "Startup recovery failed; stale jobs may remain in RUNNING/QUEUED state");
    }
}

// ============================================================================
// 中间件
// ============================================================================

// X-Correlation-Id：校验格式并截断长度，防止头注入和日志注入
app.Use(async (context, next) =>
{
    const int MaxCorrelationIdLength = 64;
    var rawCorrelationId = context.Request.Headers["X-Correlation-Id"].FirstOrDefault();

    string correlationId;
    if (!string.IsNullOrWhiteSpace(rawCorrelationId)
        && rawCorrelationId.Length <= MaxCorrelationIdLength
        && rawCorrelationId.All(c => char.IsLetterOrDigit(c) || c == '-' || c == '_'))
    {
        correlationId = rawCorrelationId;
    }
    else
    {
        correlationId = Guid.NewGuid().ToString("N");
    }

    context.TraceIdentifier = correlationId;
    context.Response.Headers["X-Correlation-Id"] = correlationId;
    await next();
});

// 异常处理
app.UseExceptionHandler(error => error.Run(context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    var logger = context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("GalGameService");

    if (exception is UpstreamContractException)
    {
        logger.LogError(exception, "KnowledgeService returned an invalid contract. CorrelationId: {CorrelationId}; Path: {Path}",
            context.TraceIdentifier, context.Request.Path);
        return Results.Json(
            ApiFailure.Create("UPSTREAM_CONTRACT_INVALID", "知识图谱服务响应不符合契约", context.TraceIdentifier),
            statusCode: StatusCodes.Status502BadGateway).ExecuteAsync(context);
    }
    if (exception is BadHttpRequestException or System.Text.Json.JsonException)
    {
        logger.LogWarning(exception, "Invalid GalGameService request. CorrelationId: {CorrelationId}; Path: {Path}",
            context.TraceIdentifier, context.Request.Path);
        return Results.Json(
            ApiFailure.Create("VALIDATION_ERROR", "请求 JSON、参数或字段格式错误", context.TraceIdentifier),
            statusCode: StatusCodes.Status400BadRequest).ExecuteAsync(context);
    }
    logger.LogError(exception, "Unhandled GalGameService error. CorrelationId: {CorrelationId}; Path: {Path}",
        context.TraceIdentifier, context.Request.Path);
    // 未预期异常不向调用方泄露内部实现细节；对外统一为可重试的上游不可用。
    return Results.Json(
        ApiFailure.Create("SERVICE_UNAVAILABLE", "游戏生成服务暂时不可用", context.TraceIdentifier),
        statusCode: StatusCodes.Status503ServiceUnavailable).ExecuteAsync(context);
}));

// Gateway 密钥验证（/healthz、/readyz 豁免）
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

// ============================================================================
// 健康检查
// ============================================================================

app.MapGet("/healthz", (HttpContext c) =>
    Results.Ok(ApiSuccess.Create(new { status = "live" }, c.TraceIdentifier)));
app.MapGet("/readyz", (HttpContext c, IGameStore store) =>
{
    if (useMongoStore && store is MongoGameStore mongoStore)
    {
        var ready = mongoStore.IsReady();
        if (!ready)
            return Results.Json(ApiFailure.Create("NOT_READY", "MongoDB 未就绪", c.TraceIdentifier), statusCode: 503);
    }
    return Results.Ok(ApiSuccess.Create(new
    {
        status = "ready",
        storage = storageName,
        narrativeEnabled,
        narrativeModel,
        narrativePromptVersion,
    }, c.TraceIdentifier));
});

// ============================================================================
// 端点 1：POST /api/v1/game-generations — 创建游戏包生成任务
// 契约 §7.3.1 URGENT：同步经 Gateway 读取 PlanGraph 并校验 snapshotVersion。
//   - snapshot 不匹配 → 422 REVIEW_PLAN_SNAPSHOT_MISMATCH
//   - reviewPlan 不存在 → 422 REVIEW_PLAN_NOT_FOUND
//   - 上游不可用 → 503 SERVICE_UNAVAILABLE
//   - 校验通过 → 202 Accepted，后台异步生成
// ============================================================================

app.MapPost("/api/v1/game-generations", async (GameGenerationRequest request, HttpContext c, IGameStore store, PlanGraphClient planClient, GameGenerationQueue generationQueue) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");

    // 请求验证
    if (!IsUuidV4(request.ReviewPlanId))
        return Failure(c, 400, "VALIDATION_ERROR", "reviewPlanId 必须为 UUID v4。");
    if (string.IsNullOrWhiteSpace(request.SnapshotVersion))
        return Failure(c, 400, "VALIDATION_ERROR", "snapshotVersion 不能为空。");
    if (string.IsNullOrWhiteSpace(request.Locale))
        return Failure(c, 400, "VALIDATION_ERROR", "locale 不能为空。");

    var traceId = c.TraceIdentifier;
    var logger = c.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("GalGameService.Generation");
    if (!Guid.TryParse(userId, out var ownerUserId))
        return Failure(c, 401, "AUTH_REQUIRED", "用户身份格式无效。");

    // §7.3.1 URGENT：同步经 Gateway 读取不可变 PlanGraph，校验 snapshotVersion
    PlanGraphFetchResult fetchResult;
    try
    {
        fetchResult = await planClient.GetGraphAsync(
            request.ReviewPlanId, request.SnapshotVersion, traceId, c.RequestAborted, mockOwnerUserId: ownerUserId);
    }
    catch (OperationCanceledException) when (c.RequestAborted.IsCancellationRequested)
    {
        return Failure(c, 499, "CLIENT_CLOSED_REQUEST", "客户端断开连接");
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Unable to read PlanGraph. CorrelationId: {CorrelationId}; ReviewPlanId: {ReviewPlanId}",
            traceId, request.ReviewPlanId);
        return Failure(c, 503, "SERVICE_UNAVAILABLE", "知识图谱服务暂时不可用");
    }

    if (fetchResult.Status == PlanGraphFetchStatus.SnapshotMismatch)
        return Failure(c, 422, "REVIEW_PLAN_SNAPSHOT_MISMATCH", fetchResult.Detail ?? "snapshot 不匹配");
    if (fetchResult.Status == PlanGraphFetchStatus.NotFound)
        return Failure(c, 422, "REVIEW_PLAN_NOT_FOUND", fetchResult.Detail ?? "复习计划不存在");
    if (fetchResult.Status == PlanGraphFetchStatus.InvalidRequest)
        return Failure(c, 400, "VALIDATION_ERROR", fetchResult.Detail ?? "复习计划图请求不符合契约");
    if (fetchResult.Status == PlanGraphFetchStatus.UpstreamContractInvalid)
        throw new UpstreamContractException(fetchResult.Detail ?? "KnowledgeService 响应不符合契约");
    if (fetchResult.Status == PlanGraphFetchStatus.Unavailable)
        return Failure(c, 503, "SERVICE_UNAVAILABLE", fetchResult.Detail ?? "知识图谱服务不可用");
    if (fetchResult.Status != PlanGraphFetchStatus.Success || fetchResult.Graph is null)
        throw new UpstreamContractException("PlanGraph 读取结果状态不完整");

    var graph = fetchResult.Graph;
    if (graph.OwnerUserId != ownerUserId)
        return Failure(c, 422, "REVIEW_PLAN_NOT_FOUND", "复习计划不存在或不可用于当前用户。");

    // PlanGraph 已校验且属于当前用户，创建生成任务
    GameGenerationJob job;
    try
    {
        job = store.CreateJob(userId, request);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Unable to create generation job. CorrelationId: {CorrelationId}; ReviewPlanId: {ReviewPlanId}",
            traceId, request.ReviewPlanId);
        return Failure(c, 503, "SERVICE_UNAVAILABLE", "游戏生成任务暂时不可用");
    }

    // 入队后台 worker 处理，替换原 fire-and-forget Task.Run。
    // PlanGraph 已确认可用，worker 不再重复获取；携带全部上下文避免使用已释放的 HttpContext。
    await generationQueue.EnqueueAsync(new GameGenerationWorkItem(job.GenerationId, userId, request, graph, traceId), c.RequestAborted);

    return Results.Accepted($"/api/v1/game-generations/{job.GenerationId}", ApiSuccess.Create(job, c.TraceIdentifier));
});

// ============================================================================
// 端点 2：GET /api/v1/game-generations/{generationId} — 查询生成任务
// ============================================================================

app.MapGet("/api/v1/game-generations/{generationId}", (string generationId, HttpContext c, IGameStore store) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");
    if (!TryParseUuidV4(generationId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "generationId 必须为 UUID v4。");
    var job = store.GetJob(id);
    if (job is null || job.OwnerUserId != userId)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "生成任务不存在。");
    return Results.Ok(ApiSuccess.Create(job, c.TraceIdentifier));
});

// ============================================================================
// 端点 3：GET /api/v1/game-packages/{packageId} — 读取游戏包清单
// ============================================================================

app.MapGet("/api/v1/game-packages/{packageId}", (string packageId, HttpContext c, IGameStore store) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");
    if (!TryParseUuidV4(packageId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "packageId 必须为 UUID v4。");
    var manifest = store.GetManifest(id);
    if (manifest is null || manifest.OwnerUserId != userId)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");
    return Results.Ok(ApiSuccess.Create(manifest, c.TraceIdentifier));
});

// ============================================================================
// 端点 4：GET /api/v1/game-packages/{packageId}/content — 下载完整 JSON 游戏包
// 支持 ETag / 304 协商缓存 + Cache-Control 防止中间代理缓存私有内容
// ============================================================================

app.MapGet("/api/v1/game-packages/{packageId}/content", (string packageId, HttpContext c, IGameStore store) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");
    if (!TryParseUuidV4(packageId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "packageId 必须为 UUID v4。");

    var owner = store.GetPackageOwner(id);
    if (owner is null || owner != userId)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");

    var manifest = store.GetManifest(id);
    var package = store.GetPackage(id);
    if (manifest is null || package is null)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");

    // ETag / 304 协商缓存
    var etag = $"\"{manifest.Checksum}\"";
    c.Response.Headers.ETag = etag;
    // 游戏包是用户私有的，禁止共享缓存
    c.Response.Headers.CacheControl = "private, no-cache";
    c.Response.Headers.XContentTypeOptions = "nosniff";
    if (IfNoneMatchMatches(c.Request.Headers.IfNoneMatch, etag))
        return Results.StatusCode(304);

    return Results.Text(
        GamePackageValidator.SerializeCanonical(package),
        "application/json; charset=utf-8");
});

// ============================================================================
// INTERNAL：RenderService 按当前会话用户读取权威游戏包。
// ownerUserId 必须来自 RenderService 收到的 Gateway 可信 X-User-Id，不能取浏览器自报值。
// ============================================================================

app.MapGet("/internal/v1/game-packages/{packageId}", (
    string packageId,
    string? ownerUserId,
    HttpContext c,
    IGameStore store) =>
{
    if (!InternalServiceAccessPolicy.IsTrusted(
            c.Request.Headers, gatewayKey, packageReaderAllowedServices))
        return Failure(c, 403, "FORBIDDEN", "需要经 Gateway 转发的可信 RenderService 身份。");

    if (!TryParseUuidV4(packageId, out var id)
        || !TryParseUuidV4(ownerUserId, out _))
        return Failure(c, 400, "VALIDATION_ERROR", "packageId 与 ownerUserId 必须为 UUID v4。");

    var owner = store.GetPackageOwner(id);
    var package = store.GetPackage(id);
    if (owner is null || package is null
        || !string.Equals(owner, ownerUserId, StringComparison.OrdinalIgnoreCase))
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");

    return Results.Ok(ApiSuccess.Create(package, c.TraceIdentifier));
});

// ============================================================================
// 端点 5：POST /internal/v1/game-package-validations — 校验游戏包（服务间）
// ============================================================================

app.MapPost("/internal/v1/game-package-validations", (GamePackageValidationRequest request, HttpContext c, GamePackageValidator validator) =>
{
    // 服务身份验证：X-Gateway-Key + X-Service-Name
    if (!InternalServiceAccessPolicy.IsTrusted(
            c.Request.Headers, gatewayKey, validationAllowedServices))
        return Failure(c, 403, "FORBIDDEN", "需要经 Gateway 转发的可信服务身份。");

    if (request.Package is null)
        return Failure(c, 400, "VALIDATION_ERROR", "package 不能为空。");

    var result = validator.Validate(request.Package);
    return Results.Json(
        ApiSuccess.Create(result, c.TraceIdentifier),
        statusCode: result.Valid ? StatusCodes.Status200OK : StatusCodes.Status422UnprocessableEntity);
});

app.Run();

// ============================================================================
// 辅助函数
// ============================================================================

static bool IsGateway(HttpContext context, string key)
    => context.Request.Headers.TryGetValue("X-Gateway-Key", out var values)
       && values.Count == 1
       && FixedTimeEqualsHeader(values[0], key);

static string? GatewayUser(HttpContext context, string key)
{
    if (!context.Request.Headers.TryGetValue("X-Gateway-Key", out var gwValues)
        || gwValues.Count != 1
        || !FixedTimeEqualsHeader(gwValues[0], key))
        return null;

    if (!context.Request.Headers.TryGetValue("X-User-Id", out var userIdValues)
        || userIdValues.Count != 1
        || !TryParseUuidV4(userIdValues[0], out _))
        return null;

    return userIdValues[0];
}

/// <summary>
/// 使用固定时间比较防止时序侧信道攻击。
/// </summary>
static bool FixedTimeEqualsHeader(string? headerValue, string expected)
{
    if (headerValue is null) return false;
    var left = System.Text.Encoding.UTF8.GetBytes(headerValue);
    var right = System.Text.Encoding.UTF8.GetBytes(expected);
    var length = Math.Max(left.Length, right.Length);
    var paddedLeft = new byte[length];
    var paddedRight = new byte[length];
    left.CopyTo(paddedLeft, 0);
    right.CopyTo(paddedRight, 0);
    return System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(paddedLeft, paddedRight) && left.Length == right.Length;
}

static IResult Failure(HttpContext context, int status, string code, string message)
    => Results.Json(ApiFailure.Create(code, message, context.TraceIdentifier), statusCode: status);

static bool TryParseUuidV4(string? value, out Guid id)
    => Guid.TryParse(value, out id) && IsUuidV4(id);

static bool IsUuidV4(Guid id)
{
    if (id == Guid.Empty) return false;
    var value = id.ToString("D");
    return value[14] == '4' && value[19] is '8' or '9' or 'a' or 'b';
}

static bool IfNoneMatchMatches(Microsoft.Extensions.Primitives.StringValues values, string currentEtag)
{
    foreach (var rawValue in values)
    {
        if (rawValue is null) continue;
        foreach (var rawTag in rawValue.Split(','))
        {
            var tag = rawTag.Trim();
            if (tag == "*") return true;
            if (tag.StartsWith("W/", StringComparison.OrdinalIgnoreCase))
                tag = tag[2..].TrimStart();
            if (string.Equals(tag, currentEtag, StringComparison.Ordinal))
                return true;
        }
    }
    return false;
}

// 暴露 partial class 供 WebApplicationFactory 集成测试使用
public partial class Program { }
