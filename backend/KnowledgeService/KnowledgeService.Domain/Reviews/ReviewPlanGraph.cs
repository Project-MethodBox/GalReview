namespace KnowledgeService.Domain.Reviews;

public sealed record ReviewPlanGraph(
    Guid ReviewPlanId,
    Guid GraphId,
    Guid OwnerUserId,
    int GraphVersion,
    string SnapshotVersion,
    ReviewPlanPurpose Purpose,
    ReviewPlanStatus Status,
    IReadOnlyList<Guid> RequestedChapterIds,
    IReadOnlyList<PlanNode> Nodes,
    IReadOnlyList<PlanEdge> Edges,
    double EstimatedCoverage,
    string AlgorithmVersion,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt);
