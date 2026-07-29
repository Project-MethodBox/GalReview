namespace KnowledgeService.API.Contracts;

public sealed record PagedData<T>(
    IReadOnlyList<T> Items,
    string? NextCursor);
