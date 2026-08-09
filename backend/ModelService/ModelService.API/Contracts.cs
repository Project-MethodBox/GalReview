namespace ModelService.API;

public sealed record AdjudicateFacetsRequest(
    string? Answer,
    IReadOnlyList<string>? Facets);

public sealed record ApiError(
    string Code,
    string Message,
    object Details);

public sealed record ApiFailure(
    object? Data,
    ApiError Error,
    string TraceId)
{
    public static ApiFailure Create(
        string code,
        string message,
        string traceId,
        object? details = null) =>
        new(null, new(code, message, details ?? new { }), traceId);
}

public sealed record ApiSuccess<T>(
    T Data,
    object Meta,
    string TraceId);
