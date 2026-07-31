namespace KnowledgeService.Domain.Materials;

public sealed record MaterialTextBlock(
    string Kind,
    int? Level,
    string Text,
    MaterialSourceSpan Source);
