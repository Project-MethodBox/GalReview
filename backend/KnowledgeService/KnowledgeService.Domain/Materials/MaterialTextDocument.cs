namespace KnowledgeService.Domain.Materials;

public sealed record MaterialTextDocument(
    Guid MaterialId,
    string Text,
    string TextChecksum,
    string ParserVersion,
    string Language,
    DateTimeOffset ExtractedAt);
