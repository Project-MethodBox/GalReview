using System.Text.Json.Serialization;

namespace KnowledgeService.Persistence.Materials;

internal sealed class MaterialTextResponse
{
    [JsonPropertyName("materialId")]
    public Guid? MaterialId { get; init; }

    [JsonPropertyName("ownerUserId")]
    public Guid? OwnerUserId { get; init; }

    [JsonPropertyName("status")]
    public string? Status { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }

    [JsonPropertyName("encoding")]
    public string? Encoding { get; init; }

    [JsonPropertyName("normalization")]
    public string? Normalization { get; init; }

    [JsonPropertyName("lineEnding")]
    public string? LineEnding { get; init; }

    [JsonPropertyName("textChecksum")]
    public string? TextChecksum { get; init; }

    [JsonPropertyName("textLength")]
    public long? TextLength { get; init; }

    [JsonPropertyName("parserVersion")]
    public string? ParserVersion { get; init; }

    [JsonPropertyName("sourceMapVersion")]
    public string? SourceMapVersion { get; init; }

    [JsonPropertyName("sourceMap")]
    public IReadOnlyList<MaterialTextSourceSpanResponse>? SourceMap { get; init; }

    [JsonPropertyName("blocks")]
    public IReadOnlyList<MaterialTextBlockResponse>? Blocks { get; init; }

    [JsonPropertyName("language")]
    public string? Language { get; init; }

    [JsonPropertyName("createdAt")]
    public DateTimeOffset? CreatedAt { get; init; }
}
