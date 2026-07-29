namespace KnowledgeService.API.Contracts;

public sealed record ApiSuccess<T>(
    T Data,
    object Meta,
    string TraceId);
