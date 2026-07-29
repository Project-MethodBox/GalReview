using KnowledgeService.Application.Segmentation;
using KnowledgeService.Domain.Graphs;

namespace KnowledgeService.Application.Extraction;

public interface IKnowledgeExtractor
{
    KnowledgeGraph Extract(
        Guid graphId,
        Guid materialId,
        Guid ownerUserId,
        string textChecksum,
        string subjectCode,
        IReadOnlyList<ChapterSegment> segments,
        DateTimeOffset now);
}
