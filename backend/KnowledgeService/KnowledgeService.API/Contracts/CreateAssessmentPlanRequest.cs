namespace KnowledgeService.API.Contracts;

public sealed record CreateAssessmentPlanRequest(
    Guid GraphId,
    IReadOnlyList<Guid>? ChapterIds,
    int? MaxQuestions,
    double? CoverageTarget,
    int? MaximumInferenceDepth);
