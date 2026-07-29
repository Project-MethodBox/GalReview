namespace KnowledgeService.API.Contracts;

public sealed record CreateLearningPlanRequest(
    Guid GraphId,
    IReadOnlyList<Guid> ChapterIds,
    int? MaxPoints,
    int? MaximumDependencyDepth);
