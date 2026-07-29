using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Domain.Graphs;

public sealed record KnowledgeGraph(
    Guid GraphId,
    Guid MaterialId,
    Guid OwnerUserId,
    int Version,
    string TextChecksum,
    string SubjectCode,
    KnowledgeGraphStatus Status,
    string SegmenterVersion,
    string ExtractorVersion,
    SegmentationMode SegmentationMode,
    IReadOnlyList<Chapter> Chapters,
    IReadOnlyList<KnowledgePoint> Points,
    IReadOnlyList<KnowledgeRelation> Relations,
    DateTimeOffset CreatedAt);
