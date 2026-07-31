namespace KnowledgeService.Domain.Materials;

public sealed record MaterialSourceSpan(
    long StartOffset,
    long EndOffset,
    int? PageNumber,
    int? ParagraphIndex,
    string? SourceLabel);
