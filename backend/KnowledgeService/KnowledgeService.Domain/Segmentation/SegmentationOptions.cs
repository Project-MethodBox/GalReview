namespace KnowledgeService.Domain.Segmentation;

public sealed record SegmentationOptions(
    SegmentationMode Mode = SegmentationMode.Auto,
    string? Delimiter = null,
    int MinChapterCharacters = 120,
    int MaxChapterCharacters = 60_000,
    int FixedWindowCharacters = 8_000);
