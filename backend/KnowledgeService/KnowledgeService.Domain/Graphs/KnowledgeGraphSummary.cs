namespace KnowledgeService.Domain.Graphs;

public sealed record KnowledgeGraphSummary(
    Guid GraphId,
    Guid MaterialId,
    int Version,
    string SubjectCode,
    int ChapterCount,
    int PointCount,
    int RelationCount,
    KnowledgeGraphStatus Status,
    string TextChecksum,
    DateTimeOffset CreatedAt,
    Guid? StudyProjectId = null);
