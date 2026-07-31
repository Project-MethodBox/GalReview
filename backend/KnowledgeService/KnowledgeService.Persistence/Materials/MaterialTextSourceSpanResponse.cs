using System.Text.Json.Serialization;

namespace KnowledgeService.Persistence.Materials;

internal sealed class MaterialTextSourceSpanResponse
{
    [JsonPropertyName("startOffset")]
    public long StartOffset { get; init; }

    [JsonPropertyName("endOffset")]
    public long EndOffset { get; init; }

    [JsonPropertyName("pageNumber")]
    public int? PageNumber { get; init; }

    [JsonPropertyName("paragraphIndex")]
    public int? ParagraphIndex { get; init; }

    [JsonPropertyName("sourceLabel")]
    public string? SourceLabel { get; init; }
}
