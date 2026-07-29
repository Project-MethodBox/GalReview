namespace KnowledgeService.Domain.Reviews;

public sealed record ReviewResultSubmission(
    Guid SubmissionId,
    Guid IdempotencyKey,
    Guid UserId,
    string SnapshotVersion,
    IReadOnlyList<ReviewAnswer> Answers,
    DateTimeOffset CompletedAt,
    Guid ReviewPlanId = default,
    Guid SessionId = default,
    Guid PackageId = default,
    int DurationSeconds = 0);
