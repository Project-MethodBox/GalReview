namespace KnowledgeService.API.Contracts;

public sealed record ApiError(
    string Code,
    string Message,
    IReadOnlyDictionary<string, object?> Details);
