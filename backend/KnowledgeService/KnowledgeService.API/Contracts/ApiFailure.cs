namespace KnowledgeService.API.Contracts;

public sealed record ApiFailure(
    object? Data,
    ApiError Error,
    string TraceId);
