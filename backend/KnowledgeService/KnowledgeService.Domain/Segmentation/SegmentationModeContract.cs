namespace KnowledgeService.Domain.Segmentation;

public static class SegmentationModeContract
{
    public static string ToContractValue(this SegmentationMode mode) =>
        mode switch
        {
            SegmentationMode.Auto => "AUTO",
            SegmentationMode.HeadingRules => "HEADING_RULES",
            SegmentationMode.Markdown => "MARKDOWN",
            SegmentationMode.Delimiter => "DELIMITER",
            SegmentationMode.FixedWindow => "FIXED_WINDOW",
            _ => throw new ArgumentOutOfRangeException(
                nameof(mode),
                mode,
                "未知章节分割模式。")
        };
}
