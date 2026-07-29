using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Application.Segmentation;

public interface IChapterSegmenter
{
    IReadOnlyList<ChapterSegment> Segment(
        string text,
        SegmentationOptions options);
}
