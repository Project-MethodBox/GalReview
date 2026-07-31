using System.Text.Json.Serialization;

namespace KnowledgeService.Persistence.Materials;

internal sealed class MaterialTextBlockResponse
{
    [JsonPropertyName("kind")]
    public string? Kind { get; init; }

    [JsonPropertyName("level")]
    public int? Level { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }

    [JsonPropertyName("source")]
    public MaterialTextSourceSpanResponse? Source { get; init; }
}
