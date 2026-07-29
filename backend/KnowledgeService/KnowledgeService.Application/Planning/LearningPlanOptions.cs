namespace KnowledgeService.Application.Planning;

public sealed record LearningPlanOptions(
    IReadOnlyList<Guid> ChapterIds,
    int MaximumPoints = 20,
    int MaximumDependencyDepth = 5);
