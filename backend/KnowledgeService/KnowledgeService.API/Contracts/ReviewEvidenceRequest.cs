namespace KnowledgeService.API.Contracts;

public sealed record ReviewEvidenceRequest(
    Guid? ResultId,
    Guid? IdempotencyKey,
    Guid? ReviewPlanId,
    string? SnapshotVersion,
    Guid? SessionId,
    Guid? PackageId,
    Guid? UserId,
    DateTimeOffset? CompletedAt,
    int? DurationSeconds,
    IReadOnlyList<KnowledgeAnswerEvidenceRequest?>? AnswerResults);
