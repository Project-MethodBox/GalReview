using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.API.Contracts;

public sealed record PlanGraphResponse(
    string SchemaVersion,
    Guid ReviewPlanId,
    ReviewPlanPurpose Type,
    ReviewPlanStatus Status,
    Guid GraphId,
    int GraphVersion,
    Guid OwnerUserId,
    IReadOnlyList<Guid> SelectedChapterIds,
    string SnapshotVersion,
    string AlgorithmVersion,
    IReadOnlyList<PlanNodeResponse> Nodes,
    IReadOnlyList<PlanEdge> Edges,
    IReadOnlyList<Guid> RootPointIds,
    int EstimatedQuestionCount,
    double EstimatedCoverage,
    double TotalWeight,
    DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt)
{
    public static PlanGraphResponse From(ReviewPlanGraph plan)
    {
        var rootPointIds = plan.Nodes
            .Where(node => node.IsQuestionTarget)
            .Select(node => node.PointId)
            .ToArray();
        return new PlanGraphResponse(
            "1.0",
            plan.ReviewPlanId,
            plan.Purpose,
            plan.Status,
            plan.GraphId,
            plan.GraphVersion,
            plan.OwnerUserId,
            plan.RequestedChapterIds,
            plan.SnapshotVersion,
            plan.AlgorithmVersion,
            plan.Nodes.Select(PlanNodeResponse.From).ToArray(),
            plan.Edges,
            rootPointIds,
            rootPointIds.Length,
            plan.EstimatedCoverage,
            Math.Round(plan.Nodes.Sum(node => node.Weight), 6),
            plan.CreatedAt,
            plan.ExpiresAt);
    }
}

public sealed record PlanNodeResponse(
    Guid PointId,
    Guid ChapterId,
    string Title,
    string Summary,
    IReadOnlyList<string> Tags,
    double MasteryScore,
    string Role,
    double Weight,
    string SelectionReason,
    int DependencyDepth,
    bool QuestionTarget,
    bool OutsideRequestedChapters,
    IReadOnlyList<Guid> CoversPointIds,
    IReadOnlyList<Guid> SupportsPointIds)
{
    public static PlanNodeResponse From(PlanNode node) =>
        new(
            node.PointId,
            node.ChapterId,
            node.Title,
            node.Summary,
            node.Tags,
            node.MasteryScore,
            node.IsQuestionTarget
                ? "TARGET"
                : node.SupportsPointIds.Count > 0
                    ? "PREREQUISITE"
                    : "CONTEXT",
            node.Weight,
            node.Reason,
            node.DependencyDepth,
            node.IsQuestionTarget,
            node.IsOutsideRequestedChapters,
            node.CoversPointIds,
            node.SupportsPointIds);
}
