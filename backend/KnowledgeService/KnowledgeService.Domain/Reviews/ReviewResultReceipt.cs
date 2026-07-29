namespace KnowledgeService.Domain.Reviews;

public sealed record ReviewResultReceipt(
    Guid SubmissionId,
    Guid ReviewPlanId,
    bool Duplicate,
    IReadOnlyList<AppliedMasteryChange> Changes,
    DateTimeOffset AppliedAt);
