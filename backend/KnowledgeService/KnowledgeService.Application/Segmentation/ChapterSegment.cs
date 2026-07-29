using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Application.Segmentation;

public sealed record ChapterSegment(
    string Title,
    int Ordinal,
    int StartOffset,
    int ContentStartOffset,
    int EndOffset,
    string Content,
    SegmentationMode AppliedMode);
