namespace KnowledgeService.Domain.Graphs;

public sealed record Chapter(
    Guid ChapterId,
    Guid GraphId,
    Guid? ParentChapterId,
    string Title,
    int Ordinal,
    int Depth,
    int StartOffset,
    int EndOffset,
    string SegmentationMode);
