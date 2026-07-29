namespace KnowledgeService.Application.Planning;

public sealed record AssessmentPlanOptions(
    IReadOnlyList<Guid> ChapterIds,
    int MaximumQuestions = 12,
    double TargetCoverage = 0.80,
    int MaximumInferenceDepth = 3);
