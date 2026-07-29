using KnowledgeService.API.Contracts;

namespace KnowledgeService.API.Infrastructure;

internal static class ApiResults
{
    public static IResult Success<T>(
        HttpContext context,
        T data,
        int statusCode = StatusCodes.Status200OK,
        object? meta = null) =>
        Results.Json(
            new ApiSuccess<T>(
                data,
                meta ?? new Dictionary<string, object?>(),
                context.TraceIdentifier),
            statusCode: statusCode);
}
