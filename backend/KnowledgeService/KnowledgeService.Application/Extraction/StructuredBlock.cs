namespace KnowledgeService.Application.Extraction;

internal sealed record StructuredBlock(
    string Category,
    int StartOffset,
    int EndOffset,
    string FirstLine,
    string Content);
