using System.Text.Json.Serialization;
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

// 请求体大小限制：防止异常大请求导致 OOM（2 MB 足以容纳任何合法游戏包）
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = 2 * 1024 * 1024; // 2 MB
});

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
var storageName = isMockMode ? "memory" : "persistent";

// HttpClient：经 Gateway 调用 KnowledgeService
builder.Services.AddHttpClient("gateway", client =>
{
    client.BaseAddress = new Uri(builder.Configuration["Gateway:BaseUrl"] ?? "http://localhost:5000");
    client.Timeout = TimeSpan.FromSeconds(30);
});

// DI 注册
builder.Services.AddSingleton<GamePackageValidator>();
builder.Services.AddSingleton<IGameStore, InMemoryGameStore>();
builder.Services.AddSingleton<PlanGraphClient>(sp => new PlanGraphClient(
    sp.GetRequiredService<IHttpClientFactory>(),
    sp.GetRequiredService<ILoggerFactory>().CreateLogger<PlanGraphClient>(),
    sp.GetRequiredService<IConfiguration>(),
    isMockMode));
builder.Services.AddSingleton<GameGenerator>();

var app = builder.Build();

// ============================================================================
// 中间件
// ============================================================================

// X-Correlation-Id
app.Use(async (context, next) =>
{
    var correlationId = context.Request.Headers["X-Correlation-Id"].FirstOrDefault();
    context.TraceIdentifier = string.IsNullOrWhiteSpace(correlationId)
        ? Guid.NewGuid().ToString("N")
        : correlationId;
    context.Response.Headers["X-Correlation-Id"] = context.TraceIdentifier;
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
    return Results.Json(
        ApiFailure.Create("INTERNAL_ERROR", "游戏生成服务暂时不可用", context.TraceIdentifier),
        statusCode: StatusCodes.Status500InternalServerError).ExecuteAsync(context);
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
app.MapGet("/readyz", (HttpContext c) =>
    Results.Ok(ApiSuccess.Create(new { status = "ready", storage = storageName }, c.TraceIdentifier)));

// ============================================================================
// 端点 1：POST /api/v1/game-generations — 创建游戏包生成任务
// 契约 §7.3.1 URGENT：同步经 Gateway 读取 PlanGraph 并校验 snapshotVersion。
//   - snapshot 不匹配 → 422 REVIEW_PLAN_SNAPSHOT_MISMATCH
//   - reviewPlan 不存在 → 422 REVIEW_PLAN_NOT_FOUND
//   - 上游不可用 → 503 SERVICE_UNAVAILABLE
//   - 校验通过 → 202 Accepted，后台异步生成
// 幂等性：Idempotency-Key 相同时返回同一 job（§2.1 契约要求）
// ============================================================================

// 幂等键缓存：Idempotency-Key → GenerationId（Mock 内存模式）
var idempotencyCache = new Dictionary<string, Guid>(StringComparer.Ordinal);
var idempotencyLock = new object();

app.MapPost("/api/v1/game-generations", async (GameGenerationRequest request, HttpContext c, IGameStore store, PlanGraphClient planClient, GameGenerator generator) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");

    // 请求验证
    if (request.ReviewPlanId == Guid.Empty)
        return Failure(c, 400, "VALIDATION_ERROR", "reviewPlanId 不能为空。");
    if (string.IsNullOrWhiteSpace(request.SnapshotVersion))
        return Failure(c, 400, "VALIDATION_ERROR", "snapshotVersion 不能为空。");
    if (string.IsNullOrWhiteSpace(request.Locale))
        return Failure(c, 400, "VALIDATION_ERROR", "locale 不能为空。");

    // 幂等性检查：相同 Idempotency-Key 返回同一 job
    var idempotencyKey = c.Request.Headers["Idempotency-Key"].FirstOrDefault();
    if (!string.IsNullOrWhiteSpace(idempotencyKey))
    {
        lock (idempotencyLock)
        {
            if (idempotencyCache.TryGetValue(idempotencyKey, out var existingGenId))
            {
                var existingJob = store.GetJob(existingGenId);
                if (existingJob is not null)
                {
                    return Results.Accepted(
                        $"/api/v1/game-generations/{existingJob.GenerationId}",
                        ApiSuccess.Create(existingJob, c.TraceIdentifier));
                }
            }
        }
    }

    var traceId = c.TraceIdentifier;
    var logger = c.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("GalGameService.Generation");

    // §7.3.1 URGENT：同步经 Gateway 读取不可变 PlanGraph，校验 snapshotVersion
    PlanGraphFetchResult fetchResult;
    try
    {
        fetchResult = await planClient.GetGraphAsync(
            request.ReviewPlanId, request.SnapshotVersion, traceId, c.RequestAborted);
    }
    catch (OperationCanceledException) when (c.RequestAborted.IsCancellationRequested)
    {
        return Failure(c, 499, "CLIENT_CLOSED_REQUEST", "客户端断开连接");
    }

    if (fetchResult.Status == PlanGraphFetchStatus.SnapshotMismatch)
        return Failure(c, 422, "REVIEW_PLAN_SNAPSHOT_MISMATCH", fetchResult.Detail ?? "snapshot 不匹配");
    if (fetchResult.Status == PlanGraphFetchStatus.NotFound)
        return Failure(c, 422, "REVIEW_PLAN_NOT_FOUND", fetchResult.Detail ?? "复习计划不存在");
    if (fetchResult.Status != PlanGraphFetchStatus.Success || fetchResult.Graph is null)
        return Failure(c, 503, "SERVICE_UNAVAILABLE", fetchResult.Detail ?? "知识图谱服务不可用");

    // PlanGraph 已校验通过，创建生成任务
    var job = store.CreateJob(userId, request);
    var graph = fetchResult.Graph;

    // 记录幂等键
    if (!string.IsNullOrWhiteSpace(idempotencyKey))
    {
        lock (idempotencyLock)
        {
            idempotencyCache[idempotencyKey] = job.GenerationId;
        }
    }

    // 后台异步生成（PlanGraph 已确认可用，不再重复获取）
    // 使用 _ = 丢弃 Task 但内部有完整异常处理，不会静默吞异常
    _ = Task.Run(async () =>
    {
        try
        {
            // 原子状态转换：QUEUED → RUNNING
            if (store.TryTransitionJob(job.GenerationId, JobStatus.QUEUED,
                j => j with { Status = JobStatus.RUNNING, Progress = 50 }) is null)
            {
                logger.LogWarning("Job {GenerationId} was not in QUEUED state, skipping generation", job.GenerationId);
                return;
            }

            logger.LogInformation("Job {GenerationId} started generating. Style={Style}, Difficulty={Difficulty}",
                job.GenerationId, request.Style, request.Difficulty);

            // 生成游戏包
            var package = generator.Generate(graph, request, userId);
            var checksum = GamePackageValidator.ComputeChecksum(package);
            var manifest = new GamePackageManifest(
                package.PackageId, package.SchemaVersion, package.GeneratorVersion,
                package.ReviewPlanId, package.SnapshotVersion, package.EntrySceneId,
                package.Scenes.Length, checksum,
                $"/api/v1/game-packages/{package.PackageId}/content",
                userId, DateTimeOffset.UtcNow);

            store.SavePackage(package, manifest, userId);

            // 原子状态转换：RUNNING → SUCCEEDED
            store.TryTransitionJob(job.GenerationId, JobStatus.RUNNING,
                j => j with { Status = JobStatus.SUCCEEDED, Progress = 100, PackageId = package.PackageId });

            logger.LogInformation("Job {GenerationId} succeeded. PackageId={PackageId}, Scenes={SceneCount}",
                job.GenerationId, package.PackageId, package.Scenes.Length);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Job {GenerationId} failed during generation", job.GenerationId);
            store.TryTransitionJob(job.GenerationId, JobStatus.RUNNING,
                j => j with { Status = JobStatus.FAILED, Error = new ApiError("INTERNAL_ERROR", ex.Message, new { }) });
        }
    });

    return Results.Accepted($"/api/v1/game-generations/{job.GenerationId}", ApiSuccess.Create(job, c.TraceIdentifier));
});

// ============================================================================
// 端点 2：GET /api/v1/game-generations/{generationId} — 查询生成任务
// ============================================================================

app.MapGet("/api/v1/game-generations/{generationId}", (string generationId, HttpContext c, IGameStore store) =>
{
    var userId = GatewayUser(c, gatewayKey);
    if (userId is null) return Failure(c, 401, "AUTH_REQUIRED", "需要网关认证的用户身份。");
    if (!Guid.TryParse(generationId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "generationId 格式不正确。");
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
    if (!Guid.TryParse(packageId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "packageId 格式不正确。");
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
    if (!Guid.TryParse(packageId, out var id))
        return Failure(c, 400, "VALIDATION_ERROR", "packageId 格式不正确。");

    var owner = store.GetPackageOwner(id);
    if (owner is null || owner != userId)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");

    var manifest = store.GetManifest(id);
    var package = store.GetPackage(id);
    if (manifest is null || package is null)
        return Failure(c, 404, "RESOURCE_NOT_FOUND", "游戏包不存在。");

    // ETag / 304 协商缓存
    var etag = $"\"{manifest.Checksum}\"";
    if (c.Request.Headers.IfNoneMatch == etag)
        return Results.StatusCode(304);

    c.Response.Headers.ETag = etag;
    // 游戏包是用户私有的，禁止共享缓存
    c.Response.Headers.CacheControl = "private, no-cache";
    c.Response.Headers.XContentTypeOptions = "nosniff";
    c.Response.ContentType = "application/json; charset=utf-8";
    return Results.Json(package);
});

// ============================================================================
// 端点 5：POST /internal/v1/game-package-validations — 校验游戏包（服务间）
// ============================================================================

app.MapPost("/internal/v1/game-package-validations", (GamePackageValidationRequest request, HttpContext c, GamePackageValidator validator) =>
{
    // 服务身份验证：X-Gateway-Key + X-Service-Name
    if (!InternalServiceAccessPolicy.IsTrusted(c.Request.Headers, gatewayKey))
        return Failure(c, 403, "FORBIDDEN", "需要经 Gateway 转发的可信服务身份。");

    if (request.Package is null)
        return Failure(c, 400, "VALIDATION_ERROR", "package 不能为空。");

    var result = validator.Validate(request.Package);
    return Results.Ok(ApiSuccess.Create(result, c.TraceIdentifier));
});

app.Run();

// ============================================================================
// 辅助函数
// ============================================================================

static bool IsGateway(HttpContext context, string key)
    => context.Request.Headers.TryGetValue("X-Gateway-Key", out var values)
       && values.Count == 1
       && string.Equals(values[0], key, StringComparison.Ordinal);

static string? GatewayUser(HttpContext context, string key)
{
    if (!context.Request.Headers.TryGetValue("X-Gateway-Key", out var gwValues)
        || gwValues.Count != 1
        || !string.Equals(gwValues[0], key, StringComparison.Ordinal))
        return null;

    if (!context.Request.Headers.TryGetValue("X-User-Id", out var userIdValues)
        || userIdValues.Count != 1
        || !Guid.TryParse(userIdValues[0], out _))
        return null;

    return userIdValues[0];
}

static IResult Failure(HttpContext context, int status, string code, string message)
    => Results.Json(ApiFailure.Create(code, message, context.TraceIdentifier), statusCode: status);

// 暴露 partial class 供 WebApplicationFactory 集成测试使用
public partial class Program { }
