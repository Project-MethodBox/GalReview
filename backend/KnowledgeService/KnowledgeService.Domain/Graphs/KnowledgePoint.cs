namespace KnowledgeService.Domain.Graphs;

public sealed record KnowledgePoint(
    Guid PointId,
    Guid GraphId,
    Guid ChapterId,
    string ConceptKey,
    string Title,
    string Summary,
    string SubjectCode,
    IReadOnlyList<string> Tags,
    double Confidence,
    IReadOnlyList<SourceReference> SourceReferences,
    int Ordinal,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);
