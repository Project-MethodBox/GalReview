using System.Text.Json.Serialization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Primitives;

// ============================================================================
// 公共响应类型（与 FileService/Contracts.cs 保持一致）
// ============================================================================

public sealed record ApiError(string Code, string Message, object Details);
public sealed record ApiSuccess(object Data, object Meta, string TraceId)
{
    public static ApiSuccess Create(object data, string traceId) => new(data, new { }, traceId);
}
public sealed record ApiFailure(object? Data, ApiError Error, string TraceId)
{
    public static ApiFailure Create(string code, string message, string traceId)
        => new(null, new ApiError(code, message, new { }), traceId);
}

// ============================================================================
// §7.2 生成任务数据类型
// ============================================================================

/// <summary>游戏剧情风格</summary>
public enum GameStyle { CAMPUS, FANTASY, SCIENCE }

/// <summary>题目难度</summary>
public enum Difficulty { BASIC, STANDARD, ADVANCED }

/// <summary>异步任务状态（与 KnowledgeService JobStatus 一致）</summary>
public enum JobStatus { QUEUED, RUNNING, SUCCEEDED, FAILED }

/// <summary>POST /api/v1/game-generations 请求体</summary>
public sealed record GameGenerationRequest(
    [property: JsonRequired] Guid ReviewPlanId,
    [property: JsonRequired] string SnapshotVersion,
    [property: JsonRequired] GameStyle Style,
    [property: JsonRequired] Difficulty Difficulty,
    [property: JsonRequired] string Locale,
    long? Seed);

/// <summary>生成任务（GET/POST /api/v1/game-generations 响应）</summary>
public sealed record GameGenerationJob(
    Guid GenerationId,
    [property: JsonIgnore] string OwnerUserId,
    JobStatus Status,
    int Progress,
    Guid? PackageId,
    string GeneratorVersion,
    ApiError? Error,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

/// <summary>游戏包清单（GET /api/v1/game-packages/{packageId} 响应）</summary>
public sealed record GamePackageManifest(
    Guid PackageId,
    string SchemaVersion,
    string GeneratorVersion,
    Guid ReviewPlanId,
    string SnapshotVersion,
    string EntrySceneId,
    int SceneCount,
    string Checksum,
    string ContentUrl,
    [property: JsonIgnore] string OwnerUserId,
    DateTimeOffset CreatedAt);

// ============================================================================
// §7.3 游戏包 schema 1.0
// ============================================================================

/// <summary>完整游戏包（GET /api/v1/game-packages/{packageId}/content 响应）</summary>
public sealed record GamePackage(
    string SchemaVersion,
    Guid PackageId,
    string GeneratorVersion,
    Guid ReviewPlanId,
    string SnapshotVersion,
    string EntrySceneId,
    Scene[] Scenes,
    AssetRef[] Assets);

/// <summary>场景</summary>
public sealed record Scene(
    string SceneId,
    string? Title,
    DialogueLine[] Dialogue,
    Choice[] Choices,
    KnowledgeBinding[] KnowledgeBindings);

/// <summary>对话行</summary>
public sealed record DialogueLine(string SpeakerId, string Text, string? Emotion);

/// <summary>选项（关联一道计分题）</summary>
public sealed record Choice(
    string ChoiceId,
    Guid QuestionId,
    string Text,
    string? NextSceneId,
    [property: JsonRequired] double ScoreDelta,
    Guid KnowledgePointId,
    AnswerKind? AnswerKind = null,
    bool? Correct = null);

/// <summary>作答类型；与 KnowledgeService/RenderService 的 AnswerResult 契约一致。</summary>
public enum AnswerKind { CHOICE, FILL_BLANK, TRUE_FALSE, SHORT_ANSWER, OTHER }

/// <summary>知识绑定用途</summary>
public enum KnowledgePurpose { EXPLAIN, QUESTION, FEEDBACK }

/// <summary>知识绑定（将场景/题目与知识点关联）</summary>
public sealed record KnowledgeBinding(
    Guid KnowledgePointId,
    Guid? QuestionId,
    KnowledgePurpose? Purpose);

/// <summary>资源类型</summary>
public enum AssetType { BACKGROUND, CHARACTER, AUDIO, OTHER }

/// <summary>资源引用</summary>
public sealed record AssetRef(string AssetId, AssetType? Type, string Uri);

/// <summary>Package-scoped synthesized dialogue audio stored outside the JSON package.</summary>
public sealed record GameAudioAsset(
    Guid PackageId,
    string AssetId,
    string ContentType,
    byte[] Data,
    DateTimeOffset CreatedAt);

// ============================================================================
// 校验类型
// ============================================================================

/// <summary>POST /internal/v1/game-package-validations 请求体</summary>
public sealed record GamePackageValidationRequest(GamePackage? Package);

/// <summary>校验问题</summary>
public sealed record ValidationIssue(string Path, string Code, string Message);

/// <summary>校验结果</summary>
public sealed record ValidationResult(bool Valid, ValidationIssue[] Errors)
{
    public static ValidationResult Ok() => new(true, Array.Empty<ValidationIssue>());
    public static ValidationResult Fail(params ValidationIssue[] errors) => new(false, errors);
}

// ============================================================================
// §6.3 PlanGraph 消费类型（GalGameService 从 KnowledgeService 读取）
// ============================================================================

public sealed record PlanGraph(
    string SchemaVersion,
    Guid ReviewPlanId,
    string Type,
    string Status,
    Guid GraphId,
    int GraphVersion,
    Guid OwnerUserId,
    Guid[] SelectedChapterIds,
    string SnapshotVersion,
    string AlgorithmVersion,
    PlanNode[] Nodes,
    PlanEdge[] Edges,
    Guid[] RootPointIds,
    int EstimatedQuestionCount,
    double EstimatedCoverage,
    double TotalWeight,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt);

public sealed record PlanNode(
    Guid PointId,
    Guid ChapterId,
    string Title,
    string Summary,
    string[] Tags,
    double MasteryScore,
    string Role,
    double Weight,
    string SelectionReason,
    int DependencyDepth,
    bool QuestionTarget,
    bool OutsideRequestedChapters,
    Guid[] CoversPointIds,
    Guid[] SupportsPointIds);

public sealed record PlanEdge(
    Guid FromPointId,
    Guid ToPointId,
    string Type,
    double Confidence,
    double InfluenceWeight);

// ============================================================================
// 上游异常
// ============================================================================

/// <summary>上游服务（KnowledgeService）返回不符合契约的数据时抛出</summary>
public sealed class UpstreamContractException : Exception
{
    public UpstreamContractException(string message) : base(message) { }
    public UpstreamContractException(string message, Exception innerException) : base(message, innerException) { }
}

// ============================================================================
// §10.2 事件类型（GamePackageReady v1，首版定义但不发布）
// ============================================================================

public sealed record GamePackageReadyData(
    Guid PackageId,
    string SchemaVersion,
    Guid ReviewPlanId,
    string SnapshotVersion,
    string ContentRef,
    string Checksum);

// ============================================================================
// 服务间访问策略（复刻 FileService/InternalServiceAccessPolicy.cs）
// ============================================================================

/// <summary>
/// INTERNAL 路由的服务身份验证：验证 X-Gateway-Key + X-Service-Name。
/// 用于 POST /internal/v1/game-package-validations 端点。
/// </summary>
public static class InternalServiceAccessPolicy
{
    public static IReadOnlySet<string> CreateAllowlist(IConfigurationSection section, params string[] defaults)
    {
        var configured = section.GetChildren()
            .Select(child => child.Value)
            .Concat(SplitScalar(section.Value))
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .ToArray();

        return new HashSet<string>(
            section.Exists() ? configured : defaults,
            StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>验证请求来自经 Gateway 转发的可信服务</summary>
    public static bool IsTrusted(
        IHeaderDictionary headers,
        string gatewayKey,
        IReadOnlySet<string>? allowedServices = null)
    {
        if (!HasSingleExactValue(headers, "X-Gateway-Key", gatewayKey, StringComparison.Ordinal))
            return false;

        if (!headers.TryGetValue("X-Service-Name", out var serviceNames) || serviceNames.Count != 1)
            return false;

        var serviceName = serviceNames[0]?.Trim();
        if (string.IsNullOrWhiteSpace(serviceName))
            return false;

        return allowedServices is null || allowedServices.Contains(serviceName);
    }

    private static bool HasSingleExactValue(
        IHeaderDictionary headers,
        string headerName,
        string expected,
        StringComparison comparison)
    {
        return headers.TryGetValue(headerName, out StringValues values)
            && values.Count == 1
            && string.Equals(values[0], expected, comparison);
    }

    private static IEnumerable<string?> SplitScalar(string? value)
    {
        return value?.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            ?? Array.Empty<string?>();
    }
}
