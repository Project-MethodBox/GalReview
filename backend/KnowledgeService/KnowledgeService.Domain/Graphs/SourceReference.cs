namespace KnowledgeService.Domain.Graphs;

public sealed record SourceReference(
    Guid MaterialId,
    int StartOffset,
    int EndOffset,
    string Location,
    string? Quote);
