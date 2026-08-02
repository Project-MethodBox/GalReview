using System.Diagnostics;
using System.Text.Json;

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
    /// <summary>上游按契约拒绝了请求参数（映射为 400）</summary>
    InvalidRequest,
    /// <summary>上游返回不可解析或违反服务契约的数据（映射为 502）</summary>
    UpstreamContractInvalid,
    /// <summary>上游服务或依赖暂不可用（映射为 503）</summary>
    Unavailable,
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
    public static PlanGraphFetchResult InvalidRequestResult(string detail) =>
        new(null, PlanGraphFetchStatus.InvalidRequest, detail);
    public static PlanGraphFetchResult UpstreamContractInvalidResult(string detail) =>
        new(null, PlanGraphFetchStatus.UpstreamContractInvalid, detail);
    public static PlanGraphFetchResult UnavailableResult(string detail) =>
        new(null, PlanGraphFetchStatus.Unavailable, detail);
}

public sealed class PlanGraphClient
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<PlanGraphClient> _logger;
    private readonly string _gatewayKey;
    private readonly string _serviceName = "GalGameService";
    private readonly bool _isMockMode;
    private readonly bool _acceptAnyPlanWithMockStory;

    // 额外超时：与 Gateway HttpClient 的 45 秒超时保持一致。
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(45);

    // Mock 模式使用 contract.md §6.7 的固定 reviewPlanId / snapshotVersion
    public static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    public const string MockSnapshotVersion = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
    };

    private static readonly string[] SuccessEnvelopeProperties = ["data", "meta", "traceId"];
    private static readonly string[] FailureEnvelopeProperties = ["data", "error", "traceId"];
    private static readonly string[] ApiErrorProperties = ["code", "message", "details"];
    private static readonly string[] PlanGraphProperties =
    [
        "schemaVersion", "reviewPlanId", "type", "status", "graphId", "graphVersion",
        "ownerUserId", "selectedChapterIds", "snapshotVersion", "algorithmVersion",
        "nodes", "edges", "rootPointIds", "estimatedQuestionCount", "estimatedCoverage",
        "totalWeight", "createdAt", "expiresAt",
    ];
    private static readonly string[] PlanNodeProperties =
    [
        "pointId", "chapterId", "title", "summary", "tags", "masteryScore", "role",
        "weight", "selectionReason", "dependencyDepth", "questionTarget",
        "outsideRequestedChapters", "coversPointIds", "supportsPointIds",
    ];
    private static readonly string[] PlanEdgeProperties =
    [
        "fromPointId", "toPointId", "type", "confidence", "influenceWeight",
    ];

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
        _acceptAnyPlanWithMockStory = bool.TryParse(configuration["GalGameMock:UseFixedStory"], out var enabled)
            && enabled;
    }

    /// <summary>
    /// 读取不可变 PlanGraph。
    /// Mock 模式下返回内置数据；生产模式经 Gateway 调用 KnowledgeService。
    /// </summary>
    public async Task<PlanGraphFetchResult> GetGraphAsync(
        Guid reviewPlanId,
        string snapshotVersion,
        string traceId,
        CancellationToken cancellationToken,
        Guid? mockOwnerUserId = null)
    {
        // Mock 模式：每次构造独立快照，避免可变数组污染后续读取。
        if (_isMockMode)
        {
            // 仅供本地“GalGame Mock + 其余服务真实”联调使用。
            // 仍用内置图谱的节点和边生成固定剧情，但将其归属和溯源绑定到当前真实请求。
            if (_acceptAnyPlanWithMockStory && mockOwnerUserId is not null)
                return PlanGraphFetchResult.Ok(BuildMockPlanGraph(mockOwnerUserId, reviewPlanId, snapshotVersion));

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

            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linkedCts.Token);

            switch ((int)response.StatusCode)
            {
                case 200:
                    return await HandleSuccessResponse(response, reviewPlanId, snapshotVersion, linkedCts.Token);

                case 400:
                    var badRequest = await ReadFailureResponse(response, linkedCts.Token);
                    if (badRequest is null || badRequest.Code != "VALIDATION_ERROR")
                    {
                        return PlanGraphFetchResult.UpstreamContractInvalidResult(
                            "KnowledgeService 返回的 400 错误响应不符合契约");
                    }
                    _logger.LogWarning("PlanGraph fetch returned 400. CorrelationId: {TraceId}, Detail: {Detail}, Elapsed: {Elapsed}ms",
                        traceId, badRequest.Message, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.InvalidRequestResult(badRequest.Message);

                case 403:
                    var forbidden = await ReadFailureResponse(response, linkedCts.Token);
                    if (forbidden is null)
                    {
                        return PlanGraphFetchResult.UpstreamContractInvalidResult(
                            "KnowledgeService 返回的 403 错误响应不符合契约");
                    }
                    _logger.LogError("GalGameService service identity rejected by Gateway. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UnavailableResult(forbidden.Message);

                case 404:
                    var notFound = await ReadFailureResponse(response, linkedCts.Token);
                    if (notFound is null || notFound.Code != "REVIEW_PLAN_NOT_FOUND")
                    {
                        return PlanGraphFetchResult.UpstreamContractInvalidResult(
                            "KnowledgeService 返回的 404 错误响应不符合契约");
                    }
                    _logger.LogInformation("PlanGraph not found for reviewPlanId={ReviewPlanId}. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        reviewPlanId, traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.NotFoundResult(notFound.Message);

                case 409:
                    var conflict = await ReadFailureResponse(response, linkedCts.Token);
                    if (conflict is null || conflict.Code != "SNAPSHOT_VERSION_CONFLICT")
                    {
                        return PlanGraphFetchResult.UpstreamContractInvalidResult(
                            "KnowledgeService 返回的 409 错误响应不符合契约");
                    }
                    _logger.LogInformation("Snapshot version mismatch for reviewPlanId={ReviewPlanId}, snapshotVersion={SnapshotVersion}. CorrelationId: {TraceId}",
                        reviewPlanId, snapshotVersion, traceId);
                    return PlanGraphFetchResult.SnapshotMismatchResult(conflict.Message);

                case 502:
                    _logger.LogError("KnowledgeService or Gateway reported an upstream contract failure. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UpstreamContractInvalidResult(
                        "KnowledgeService 上游响应不符合契约");

                case >= 500:
                case 408:
                case 429:
                    var unavailable = await ReadFailureResponse(response, linkedCts.Token);
                    if (unavailable is null)
                    {
                        return PlanGraphFetchResult.UpstreamContractInvalidResult(
                            $"KnowledgeService 返回的 {(int)response.StatusCode} 错误响应不符合契约");
                    }
                    _logger.LogError("KnowledgeService unavailable with status {Status}. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        response.StatusCode, traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UnavailableResult(unavailable.Message);

                default:
                    _logger.LogError("Unexpected status {Status} from KnowledgeService. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                        response.StatusCode, traceId, sw.ElapsedMilliseconds);
                    return PlanGraphFetchResult.UpstreamContractInvalidResult(
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
            return PlanGraphFetchResult.UnavailableResult($"KnowledgeService 请求超时（{RequestTimeout.TotalSeconds:F0}s）");
        }
        catch (HttpRequestException ex)
        {
            _logger.LogError(ex, "Cannot reach KnowledgeService via Gateway. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                traceId, sw.ElapsedMilliseconds);
            return PlanGraphFetchResult.UnavailableResult("无法连接 KnowledgeService");
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException)
        {
            _logger.LogError(ex, "PlanGraph response is not valid JSON. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                traceId, sw.ElapsedMilliseconds);
            return PlanGraphFetchResult.UpstreamContractInvalidResult("KnowledgeService 响应不可解析");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unexpected failure while fetching PlanGraph. CorrelationId: {TraceId}, Elapsed: {Elapsed}ms",
                traceId, sw.ElapsedMilliseconds);
            return PlanGraphFetchResult.UnavailableResult("读取知识图谱失败");
        }
    }

    /// <summary>处理 200 响应：严格解析 ApiSuccess 信封及其中的 PlanGraph。</summary>
    private static async Task<PlanGraphFetchResult> HandleSuccessResponse(
        HttpResponseMessage response, Guid reviewPlanId, string snapshotVersion, CancellationToken ct)
    {
        var json = await response.Content.ReadAsStringAsync(ct);

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return PlanGraphFetchResult.UpstreamContractInvalidResult("KnowledgeService 返回的 200 响应不是有效 JSON");
        }

        using (document)
        {
            var root = document.RootElement;
            if (!HasRequiredProperties(root, SuccessEnvelopeProperties)
                || !root.TryGetProperty("meta", out var meta)
                || meta.ValueKind != JsonValueKind.Object
                || meta.EnumerateObject().Any()
                || !root.TryGetProperty("traceId", out var responseTraceId)
                || responseTraceId.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(responseTraceId.GetString())
                || !root.TryGetProperty("data", out var data)
                || !HasValidPlanGraphJsonShape(data))
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult(
                    "KnowledgeService 返回的成功响应信封或 PlanGraph 结构不符合契约");
            }

            PlanGraph? graphData;
            try
            {
                graphData = data.Deserialize<PlanGraph>(JsonOptions);
            }
            catch (Exception exception) when (exception is JsonException or NotSupportedException)
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult(
                    "KnowledgeService 返回的 data 字段无法解析为 PlanGraph");
            }

            if (graphData is null)
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult("KnowledgeService 返回空数据");
            }

            if (graphData.ReviewPlanId != reviewPlanId)
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult(
                    $"KnowledgeService 返回的 reviewPlanId({graphData.ReviewPlanId}) 与请求的({reviewPlanId})不一致");
            }

            if (!string.Equals(graphData.SnapshotVersion, snapshotVersion, StringComparison.Ordinal))
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult(
                    $"KnowledgeService 返回的 snapshotVersion({graphData.SnapshotVersion}) 与请求的({snapshotVersion})不一致");
            }

            if (!HasValidPlanGraph(graphData))
            {
                return PlanGraphFetchResult.UpstreamContractInvalidResult(
                    "KnowledgeService 返回的 PlanGraph 关键字段或引用关系不符合契约");
            }

            return PlanGraphFetchResult.Ok(graphData);
        }
    }

    private static async Task<ValidatedFailure?> ReadFailureResponse(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var json = await response.Content.ReadAsStringAsync(cancellationToken);
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!HasRequiredProperties(root, FailureEnvelopeProperties)
                || !root.TryGetProperty("data", out var data)
                || data.ValueKind != JsonValueKind.Null
                || !root.TryGetProperty("traceId", out var traceId)
                || traceId.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(traceId.GetString())
                || !root.TryGetProperty("error", out var error)
                || !HasRequiredProperties(error, ApiErrorProperties)
                || !error.TryGetProperty("code", out var code)
                || code.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(code.GetString())
                || !error.TryGetProperty("message", out var message)
                || message.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(message.GetString())
                || !error.TryGetProperty("details", out var details)
                || details.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            return new ValidatedFailure(code.GetString()!, message.GetString()!);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool HasValidPlanGraphJsonShape(JsonElement data)
    {
        if (!HasRequiredProperties(data, PlanGraphProperties)
            || !HasContractUuid(data, "reviewPlanId")
            || !HasContractUuid(data, "graphId")
            || !HasContractUuid(data, "ownerUserId")
            || !HasContractUuidArray(data, "selectedChapterIds")
            || !HasContractUuidArray(data, "rootPointIds")
            || !data.TryGetProperty("nodes", out var nodes)
            || nodes.ValueKind != JsonValueKind.Array
            || !data.TryGetProperty("edges", out var edges)
            || edges.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var node in nodes.EnumerateArray())
        {
            if (!HasRequiredProperties(node, PlanNodeProperties)
                || !HasContractUuid(node, "pointId")
                || !HasContractUuid(node, "chapterId")
                || !HasContractUuidArray(node, "coversPointIds")
                || !HasContractUuidArray(node, "supportsPointIds"))
            {
                return false;
            }
        }

        foreach (var edge in edges.EnumerateArray())
        {
            if (!HasRequiredProperties(edge, PlanEdgeProperties)
                || !HasContractUuid(edge, "fromPointId")
                || !HasContractUuid(edge, "toPointId"))
            {
                return false;
            }
        }

        return true;
    }

    private static bool HasRequiredProperties(JsonElement element, IReadOnlyCollection<string> requiredProperties)
    {
        if (element.ValueKind != JsonValueKind.Object)
            return false;

        var required = requiredProperties.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (required.Contains(property.Name) && !seen.Add(property.Name))
                return false;
        }

        return seen.Count == required.Count;
    }

    private static bool HasContractUuid(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var value)
            && IsContractUuid(value);
    }

    private static bool HasContractUuidArray(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var values)
            || values.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        return values.EnumerateArray().All(IsContractUuid);
    }

    private static bool IsContractUuid(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.String)
            return false;

        var raw = value.GetString();
        return raw is { Length: 36 }
            && raw[14] == '4'
            && raw[19] is '8' or '9' or 'a' or 'b'
            && Guid.TryParseExact(raw, "D", out var parsed)
            && parsed != Guid.Empty
            && string.Equals(raw, parsed.ToString("D"), StringComparison.Ordinal);
    }

    private static bool HasValidPlanGraph(PlanGraph graph)
    {
        if (!string.Equals(graph.SchemaVersion, "1.0", StringComparison.Ordinal)
            || graph.ReviewPlanId == Guid.Empty
            || graph.GraphId == Guid.Empty
            || graph.GraphVersion < 1
            || graph.OwnerUserId == Guid.Empty
            || graph.SelectedChapterIds is null
            || graph.SelectedChapterIds.Any(id => id == Guid.Empty)
            || graph.SelectedChapterIds.Distinct().Count() != graph.SelectedChapterIds.Length
            || string.IsNullOrWhiteSpace(graph.SnapshotVersion)
            || graph.Nodes is null
            || graph.Nodes.Length == 0
            || graph.Edges is null
            || graph.RootPointIds is null
            || graph.RootPointIds.Length == 0
            || graph.EstimatedQuestionCount < 0
            || !IsUnitInterval(graph.EstimatedCoverage)
            || graph.TotalWeight != 1d
            || graph.CreatedAt == default
            || graph.ExpiresAt == default
            || graph.CreatedAt.Offset != TimeSpan.Zero
            || graph.ExpiresAt.Offset != TimeSpan.Zero
            || graph.ExpiresAt <= graph.CreatedAt
            || graph.Status is not ("OPEN" or "COMPLETED" or "EXPIRED"))
        {
            return false;
        }

        var expectedAlgorithmVersion = graph.Type switch
        {
            "ASSESSMENT" => "assessment-planner-v1",
            "LEARNING" => "learning-planner-v1",
            _ => null,
        };
        if (expectedAlgorithmVersion is null
            || !string.Equals(graph.AlgorithmVersion, expectedAlgorithmVersion, StringComparison.Ordinal))
        {
            return false;
        }

        var pointIds = new HashSet<Guid>();
        var totalWeight = 0d;
        foreach (var node in graph.Nodes)
        {
            if (node is null
                || node.PointId == Guid.Empty
                || node.ChapterId == Guid.Empty
                || !pointIds.Add(node.PointId)
                || string.IsNullOrWhiteSpace(node.Title)
                || node.Summary is null
                || node.Tags is null
                || node.Tags.Any(tag => tag is null)
                || !double.IsFinite(node.MasteryScore)
                || node.MasteryScore is < 0 or > 100
                || node.Role is not ("TARGET" or "PREREQUISITE" or "CONTEXT")
                || !IsUnitInterval(node.Weight)
                || string.IsNullOrWhiteSpace(node.SelectionReason)
                || node.DependencyDepth < 0
                || node.CoversPointIds is null
                || node.SupportsPointIds is null
                || node.CoversPointIds.Any(id => id == Guid.Empty)
                || node.SupportsPointIds.Any(id => id == Guid.Empty))
            {
                return false;
            }

            totalWeight += node.Weight;
        }

        if (Math.Abs(totalWeight - 1d) > 0.000001d)
            return false;

        if (graph.Nodes.Any(node =>
                node.CoversPointIds.Any(id => !pointIds.Contains(id))
                || node.SupportsPointIds.Any(id => !pointIds.Contains(id))))
        {
            return false;
        }

        if (graph.RootPointIds.Any(id => id == Guid.Empty || !pointIds.Contains(id))
            || graph.RootPointIds.Distinct().Count() != graph.RootPointIds.Length)
        {
            return false;
        }

        if (graph.Type == "ASSESSMENT")
        {
            var questionTargetIds = graph.Nodes
                .Where(node => node.QuestionTarget)
                .Select(node => node.PointId)
                .ToHashSet();
            if (!questionTargetIds.SetEquals(graph.RootPointIds))
                return false;
        }

        var edgeKeys = new HashSet<(Guid From, Guid To, string Type)>();
        foreach (var edge in graph.Edges)
        {
            if (edge is null
                || edge.FromPointId == Guid.Empty
                || edge.ToPointId == Guid.Empty
                || edge.FromPointId == edge.ToPointId
                || !pointIds.Contains(edge.FromPointId)
                || !pointIds.Contains(edge.ToPointId)
                || edge.Type is not ("PREREQUISITE" or "RELATED" or "CONTRASTS")
                || !IsUnitInterval(edge.Confidence)
                || !IsUnitInterval(edge.InfluenceWeight)
                || !edgeKeys.Add((edge.FromPointId, edge.ToPointId, edge.Type)))
            {
                return false;
            }
        }

        if (!HasAcyclicPrerequisiteGraph(pointIds, graph.Edges))
            return false;

        if (graph.Type == "LEARNING" && !HasValidLearningStructure(graph))
            return false;

        return true;
    }

    private static bool HasAcyclicPrerequisiteGraph(
        IReadOnlySet<Guid> pointIds,
        IEnumerable<PlanEdge> edges)
    {
        var indegree = pointIds.ToDictionary(pointId => pointId, _ => 0);
        var adjacency = new Dictionary<Guid, List<Guid>>();
        foreach (var edge in edges.Where(edge => edge.Type == "PREREQUISITE"))
        {
            if (!adjacency.TryGetValue(edge.FromPointId, out var nextIds))
            {
                nextIds = [];
                adjacency[edge.FromPointId] = nextIds;
            }

            nextIds.Add(edge.ToPointId);
            indegree[edge.ToPointId]++;
        }

        var ready = new Queue<Guid>(indegree.Where(pair => pair.Value == 0).Select(pair => pair.Key));
        var visitedCount = 0;
        while (ready.TryDequeue(out var current))
        {
            visitedCount++;
            if (!adjacency.TryGetValue(current, out var nextIds))
                continue;

            foreach (var nextId in nextIds)
            {
                indegree[nextId]--;
                if (indegree[nextId] == 0)
                    ready.Enqueue(nextId);
            }
        }

        return visitedCount == pointIds.Count;
    }

    private static bool HasValidLearningStructure(PlanGraph graph)
    {
        if (graph.SelectedChapterIds.Length == 0)
            return false;

        var selectedChapters = graph.SelectedChapterIds.ToHashSet();
        var targets = graph.Nodes
            .Where(node => node.Role == "TARGET")
            .Select(node => node.PointId)
            .ToHashSet();
        if (targets.Count == 0)
            return false;

        var outsideWeight = 0d;
        foreach (var node in graph.Nodes)
        {
            var isOutsideSelectedChapters = !selectedChapters.Contains(node.ChapterId);
            if (node.OutsideRequestedChapters != isOutsideSelectedChapters
                || (node.Role == "TARGET" && isOutsideSelectedChapters)
                || (isOutsideSelectedChapters && node.Role != "PREREQUISITE"))
            {
                return false;
            }

            if (isOutsideSelectedChapters)
                outsideWeight += node.Weight;
        }

        if (outsideWeight > 0.300001d)
            return false;

        if (graph.RootPointIds.Any(rootId =>
                !targets.Contains(rootId)
                || !selectedChapters.Contains(graph.Nodes.Single(node => node.PointId == rootId).ChapterId)))
        {
            return false;
        }

        var prerequisiteAdjacency = graph.Edges
            .Where(edge => edge.Type == "PREREQUISITE")
            .GroupBy(edge => edge.FromPointId)
            .ToDictionary(group => group.Key, group => group.Select(edge => edge.ToPointId).ToArray());

        foreach (var prerequisite in graph.Nodes.Where(node => node.Role == "PREREQUISITE"))
        {
            if (prerequisite.SupportsPointIds.Length == 0
                || prerequisite.SupportsPointIds.Any(targetId =>
                    !targets.Contains(targetId)
                    || !CanReachPoint(prerequisite.PointId, targetId, prerequisiteAdjacency)))
            {
                return false;
            }
        }

        return true;
    }

    private static bool CanReachPoint(
        Guid start,
        Guid target,
        IReadOnlyDictionary<Guid, Guid[]> adjacency)
    {
        var pending = new Stack<Guid>();
        var visited = new HashSet<Guid> { start };
        pending.Push(start);

        while (pending.TryPop(out var current))
        {
            if (!adjacency.TryGetValue(current, out var nextIds))
                continue;

            foreach (var nextId in nextIds)
            {
                if (nextId == target)
                    return true;
                if (visited.Add(nextId))
                    pending.Push(nextId);
            }
        }

        return false;
    }

    private static bool IsUnitInterval(double value) =>
        double.IsFinite(value) && value is >= 0d and <= 1d;

    private sealed record ValidatedFailure(string Code, string Message);

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

        return PlanGraphFetchResult.Ok(BuildMockPlanGraph());
    }

    /// <summary>
    /// 构造内置 Mock PlanGraph（逐字段对应 contract.md §6.7 PlanGraph Mock）。
    /// 包含 1 个 questionTarget=true 的 TARGET 节点和 1 个 PREREQUISITE 节点。
    /// </summary>
    private static PlanGraph BuildMockPlanGraph(
        Guid? ownerUserIdOverride = null,
        Guid? reviewPlanIdOverride = null,
        string? snapshotVersionOverride = null)
    {
        var targetPointId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");
        var prereqPointId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
        var chapterId = Guid.Parse("7623c5ae-f377-4247-aaf5-bf73378e74ef");
        var graphId = Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0");
        var ownerUserId = Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20");

        var nodes = new PlanNode[]
        {
            new(
                PointId: prereqPointId,
                ChapterId: chapterId,
                Title: "作物群体与个体关系",
                Summary: "群体数量与单株生长之间存在资源竞争和补偿关系。",
                Tags: new[] { "群体结构", "基础" },
                MasteryScore: 0,
                Role: "PREREQUISITE",
                Weight: 0.5,
                SelectionReason: "MAX_PRODUCT_PREREQUISITE_PATH",
                DependencyDepth: 1,
                QuestionTarget: false,
                OutsideRequestedChapters: false,
                CoversPointIds: new[] { prereqPointId, targetPointId },
                SupportsPointIds: new[] { targetPointId }),
            new(
                PointId: targetPointId,
                ChapterId: chapterId,
                Title: "水稻分蘖期管理目标",
                Summary: "协调群体数量与个体生长，形成合理群体结构。",
                Tags: new[] { "水稻", "分蘖期" },
                MasteryScore: 0,
                Role: "TARGET",
                Weight: 0.5,
                SelectionReason: "REQUESTED_CHAPTER_FORGETTING_RISK",
                DependencyDepth: 0,
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
            ReviewPlanId: reviewPlanIdOverride ?? MockReviewPlanId,
            Type: "LEARNING",
            Status: "OPEN",
            GraphId: graphId,
            GraphVersion: 1,
            OwnerUserId: ownerUserIdOverride ?? ownerUserId,
            SelectedChapterIds: new[] { chapterId },
            SnapshotVersion: snapshotVersionOverride ?? MockSnapshotVersion,
            AlgorithmVersion: "learning-planner-v1",
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
