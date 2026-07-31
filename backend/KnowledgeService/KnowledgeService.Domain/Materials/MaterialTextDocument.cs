namespace KnowledgeService.Domain.Materials;

public sealed record MaterialTextDocument(
    Guid MaterialId,
    Guid OwnerUserId,
    string Text,
    string TextChecksum,
    string ParserVersion,
    string Language,
    IReadOnlyList<MaterialSourceSpan> SourceMap,
    IReadOnlyList<MaterialTextBlock> Blocks,
    DateTimeOffset ExtractedAt);
