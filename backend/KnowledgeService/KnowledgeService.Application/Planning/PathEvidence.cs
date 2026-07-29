namespace KnowledgeService.Application.Planning;

internal sealed record PathEvidence(
    double Strength,
    int Depth,
    IReadOnlyList<Guid> PathPointIds);
