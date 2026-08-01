using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

// ============================================================================
// PlanGraph 读取客户端（§7.3.1 URGENT 跨服务阻塞项）
//
// GalGameService 必须经 Gateway 调用 KnowledgeService 的
//   GET /internal/v1/review-plans/{reviewPlanId}/graph?snapshotVersion=...
// 以返回的不可变 PlanGraph 为唯一知识输入。
//
// Mock 模式下返回内置 PlanGraph，使 GalGameService 可独立运行。
//
// 优化项：
// - 请求耗时日志（Stopwatch）
// - 超时保护（链接级 CancellationTokenSource）
// - 响应体大小限制（防止上游返回异常大响应）
// - Mock PlanGraph 静态缓存（只构造一次）
// ============================================================================

/// <summary>PlanGraph 读取结果状态</summary>
public enum PlanGraphFetchStatus
{
    /// <summary>成功读取</summary>
    Success,
    /// <summary>复习计划不存在</summary>
    NotFound,
    /// <summary>snapshotVersion 不匹配（409 SNAPSHOT_VERSION_CONFLICT）</summary>
    SnapshotMismatch,
    /// <summary>上游服务不可用或返回非契约数据</summary>
    UpstreamError,
}

/// <summary>PlanGraph 读取结果</summary>
public sealed record PlanGraphFetchResult(
    PlanGraph? Graph,
    PlanGraphFetchStatus Status,
    string? Detail)
{
    public static PlanGraphFetchResult Ok(PlanGraph graph) => new(graph, PlanGraphFetchStatus.Success, null);
    public static PlanGraphFetchResult NotFoundResult(string detail) => new(null, PlanGraphFetchStatus.NotFound, detail);
    public static PlanGraphFetchResult SnapshotMismatchResult(string detail) => new(null, PlanGraphFetchStatus.SnapshotMismatch, detail);
    public static PlanGraphFetchResult UpstreamErrorResult(string detail) => new(null, PlanGraphFetchStatus.UpstreamError, detail);
}

public sealed class PlanGraphClient
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<PlanGraphClient> _logger;
    private readonly string _gatewayKey;
    private readonly string _serviceName = "GalGameService";
    private readonly bool _isMockMode;

    // 额外超时：在 HttpClient 30s 超时基础上，增加 CancellationTokenSource 保护
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);

    // Mock 模式使用的固定 reviewPlanId / snapshotVersion（与 contract.md §7.4 一致）
    public static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    public const string MockSnapshotVersion = "plan-graph-1.0:3da5f48f";

    // 响应体大小上限：PlanGraph 通常 < 1 MB，10 MB 是防御性上限
    private const long MaxResponseBytes = 10 * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    // Mock PlanGraph 只构造一次（静态缓存）
    private static readonly PlanGraph CachedMockPlanGraph = BuildMockPlanGraph();

    public PlanGraphClient(
        IHttpClientFactory httpClientFactory,
        ILogger<PlanGraphClient> logger,
        IConfiguration configuration,
        bool isMockMode)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
        _gatewayKey = configuration["Gateway:ServiceKey"]
            ?? throw new InvalidOperationException("Gateway:ServiceKey must be configured.");
        _isMockMode = isMockMode;
    }

    /// <summary>
    /// 读取不可变 PlanGraph。
    /// Mock 模式下返回内置数据；生产模式经 Gateway 调用 KnowledgeService。
    /// </summary>
    public async Task<PlanGraphFetchResult> GetGraphAsync(
        Guid reviewPlanId,
        string snapshotVersion,
        string traceId,
        CancellationToken cancellationToken)
    {
        // Mock 模式：返回内置 PlanGraph（零分配，使用静态缓存）
        if (_isMockMode)
        {
            return GetMockGraph(reviewPlanId, snapshotVersion);
        }

        // 生产模式：经 Gateway 调用 KnowledgeService
        var sw = Stopwatch.StartNew();

        try
        {
            var client = _httpClientFactory.CreateClient("gateway");
            var relativeUrl = $"internal/v1/review-plans/{reviewPlanId}/graph?snapshotVersion={Uri.EscapeDataString(snapshotVersion)}";

            var request = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
            request.Headers.Add("X-Service-Name", _serviceName);
            request.Headers.Add("X-Service-Key", _gatewayKey);
            request.Headers.Add("X-Correlation-Id", traceId);

            // 链接级超时保护：组合外部 CancellationToken + 内部超时
            using var timeoutCts = new CancellationTokenSource(RequestTimeout);
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linkedCts.Token);

            switch ((int)response.StatusCode)
            {
                case 200:
                    return await HandleSuccessResponse(response, reviewPlanId, traceId, sw, linkedCts.Token);

                case 400:
                    var badRequest = await response.Content.ReadFromJsonAsync<ApiFailure>(JsonOptions, linkedCts.Token);
                    _logger.LogWarning("PlanGraph fetch returned 400. CorrelationId: {TraceId}, Detail: {Detail}, Elapsed: {Elapsed}ms",
                        traceId, badRequest?.Error.Message, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UpstreamErrorResult(
                        badRequest?.Error.Message ?? "请求参数错误");

                case 403:
                    _logger.LogError("GalGameService service identity rejected by Gateway. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UpstreamErrorResult("服务身份被 Gateway 拒绝");

                case 404:
                    _logger.LogInformation("PlanGraph not found for reviewPlanId={ReviewPlanId}. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        reviewPlanId, traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.NotFoundResult($"复习计划 {reviewPlanId} 不存在");

                case 409:
                    _logger.LogInformation("Snapshot version mismatch for reviewPlanId={ReviewPlanId}, snapshotVersion={SnapshotVersion}. CorrelationId: {TraceId}",
                        reviewPlanId, snapshotVersion, traceId);
                    return PlanGraphFetchResult.SnapshotMismatchResult(
                        $"snapshotVersion \"{snapshotVersion}\" 与 KnowledgeService 中的 PlanGraph 不一致");

                default:
                    _logger.LogError("Unexpected status {Status} from KnowledgeService. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        response.StatusCode, traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UpstreamErrorResult(
                        $"KnowledgeService 返回意外状态码 {(int)response.StatusCode}");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw; // 外部取消，向上传播
        }
        catch (OperationCanceledException)
        {
            _logger.LogError("PlanGraph fetch timed out after {Timeout}s. CorrelationId: {TraceId}", RequestTimeout.TotalSeconds, traceId);
            return PlanGraphFetchResult.UpstreamErrorResult($"KnowledgeService 请求超时（{RequestTimeout.TotalSeconds:F0}s）");
        }
        catch (HttpRequestException ex)
        {
            _logger.LogError(ex, "Cannot reach KnowledgeService via Gateway. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                traceId, sw.ElapsedMilliseconds);
            return PlanGraphFetchResult.UpstreamErrorResult("无法连接 KnowledgeService");
        }
        catch (JsonException ex)
        {
            _logger.LogError(ex, "PlanGraph response is not valid JSON. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                traceId, sw.ElapsedMilliseconds);
            return PlanGraphFetchResult.UpstreamErrorResult("KnowledgeService 响应不可解析");
        }
    }

    /// <summary>处理 200 响应：解析 ApiSuccess 信封中的 data 字段</summary>
    private static async Task<PlanGraphFetchResult> HandleSuccessResponse(
        HttpResponseMessage response, Guid reviewPlanId, string traceId, Stopwatch sw, CancellationToken ct)
    {
        // 检查 Content-Length 防止异常大响应
        if (response.Content.Headers.ContentLength is { } contentLength && contentLength > MaxResponseBytes)
        {
            return PlanGraphFetchResult.UpstreamErrorResult(
                $"KnowledgeService 响应体过大（{contentLength} bytes > {MaxResponseBytes} bytes 上限）");
        }

        var json = await response.Content.ReadAsStringAsync(ct);

        // 二次检查：实际读取的字节数（Content-Length 可能缺失）
        if (json.Length > MaxResponseBytes)
        {
            return PlanGraphFetchResult.UpstreamErrorResult(
                $"KnowledgeService 响应体过大（{json.Length} chars > {MaxResponseBytes} chars 上限）");
        }

        PlanGraph? graphData;
        try
        {
            var node = JsonNode.Parse(json);
            graphData = node?["data"]?.Deserialize<PlanGraph>(JsonOptions);
        }
        catch (JsonException)
        {
            return PlanGraphFetchResult.UpstreamErrorResult("KnowledgeService 返回的 data 字段无法解析为 PlanGraph");
        }

        if (graphData is null)
        {
            return PlanGraphFetchResult.UpstreamErrorResult("KnowledgeService 返回空数据");
        }

        // 校验返回的 PlanGraph 关键字段
        if (graphData.ReviewPlanId != reviewPlanId)
        {
            return PlanGraphFetchResult.UpstreamErrorResult(
                $"KnowledgeService 返回的 reviewPlanId({graphData.ReviewPlanId}) 与请求的({reviewPlanId})不一致");
        }

        return PlanGraphFetchResult.Ok(graphData);
    }

    /// <summary>
    /// 返回内置 Mock PlanGraph。
    /// 当请求的 reviewPlanId/snapshotVersion 与内置 Mock 一致时返回成功；
    /// snapshotVersion 不一致时返回 SnapshotMismatch（模拟 URGENT 校验逻辑）；
    /// reviewPlanId 不一致时返回 NotFound。
    /// </summary>
    private static PlanGraphFetchResult GetMockGraph(Guid reviewPlanId, string snapshotVersion)
    {
        if (reviewPlanId != MockReviewPlanId)
            return PlanGraphFetchResult.NotFoundResult($"Mock 模式下仅支持 reviewPlanId={MockReviewPlanId}");

        if (snapshotVersion != MockSnapshotVersion)
            return PlanGraphFetchResult.SnapshotMismatchResult(
                $"Mock 模式下仅支持 snapshotVersion={MockSnapshotVersion}");

        return PlanGraphFetchResult.Ok(CachedMockPlanGraph);
    }

    /// <summary>
    /// 构造内置 Mock PlanGraph（数据对应 contract.md §7.4 最小游戏包 Mock 的来源计划）。
    /// 包含 1 个 questionTarget=true 的 TARGET 节点和 1 个 PREREQUISITE 节点。
    /// </summary>
    private static PlanGraph BuildMockPlanGraph()
    {
        var targetPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
        var prereqPointId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
        var chapterId = Guid.Parse("a1b2c3d4-e5f6-7890-abcd-ef1234567890");
        var graphId = Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0");
        var ownerUserId = Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20");

        var nodes = new PlanNode[]
        {
            new(
                PointId: prereqPointId,
                ChapterId: chapterId,
                Title: "水稻基本生长周期",
                Summary: "水稻从播种到成熟的完整生长周期，包括幼苗期、分蘖期、拔节期、抽穗期和成熟期。",
                Tags: new[] { "水稻", "生长周期" },
                MasteryScore: 0,
                Role: "PREREQUISITE",
                Weight: 0.5,
                SelectionReason: "PREREQUISITE_FOR_REQUESTED_TARGET",
                DependencyDepth: 0,
                QuestionTarget: false,
                OutsideRequestedChapters: false,
                CoversPointIds: Array.Empty<Guid>(),
                SupportsPointIds: new[] { targetPointId }),
            new(
                PointId: targetPointId,
                ChapterId: chapterId,
                Title: "水稻分蘖期管理",
                Summary: "水稻分蘖期最关键的管理目标是协调群体数量与个体生长，通过水肥调控促进有效分蘖。",
                Tags: new[] { "水稻", "分蘖期" },
                MasteryScore: 0,
                Role: "TARGET",
                Weight: 0.5,
                SelectionReason: "REQUESTED_CHAPTER_FORGETTING_RISK",
                DependencyDepth: 1,
                QuestionTarget: true,
                OutsideRequestedChapters: false,
                CoversPointIds: new[] { targetPointId },
                SupportsPointIds: new[] { targetPointId }),
        };

        var edges = new PlanEdge[]
        {
            new(
                FromPointId: prereqPointId,
                ToPointId: targetPointId,
                Type: "PREREQUISITE",
                Confidence: 0.91,
                InfluenceWeight: 0.91),
        };

        return new PlanGraph(
            SchemaVersion: "1.0",
            ReviewPlanId: MockReviewPlanId,
            Type: "ASSESSMENT",
            Status: "OPEN",
            GraphId: graphId,
            GraphVersion: 1,
            OwnerUserId: ownerUserId,
            SelectedChapterIds: new[] { chapterId },
            SnapshotVersion: MockSnapshotVersion,
            AlgorithmVersion: "assessment-planner-v1",
            Nodes: nodes,
            Edges: edges,
            RootPointIds: new[] { targetPointId },
            EstimatedQuestionCount: 1,
            EstimatedCoverage: 0.82,
            TotalWeight: 1.0,
            CreatedAt: DateTimeOffset.Parse("2026-07-27T08:50:00Z"),
            ExpiresAt: DateTimeOffset.Parse("2026-08-03T08:50:00Z"));
    }
}
