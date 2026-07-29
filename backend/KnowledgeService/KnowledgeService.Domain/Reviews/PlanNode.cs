namespace KnowledgeService.Domain.Reviews;

public sealed record PlanNode(
    Guid PointId,
    Guid ChapterId,
    string Title,
    string Summary,
    IReadOnlyList<string> Tags,
    double MasteryScore,
    double Weight,
    bool IsQuestionTarget,
    bool IsOutsideRequestedChapters,
    int DependencyDepth,
    IReadOnlyList<Guid> CoversPointIds,
    IReadOnlyList<Guid> SupportsPointIds,
    string Reason);
