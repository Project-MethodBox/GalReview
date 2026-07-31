using System.Text.Json;
using KnowledgeService.API.Contracts;
using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

public sealed class ApiExceptionMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<ApiExceptionMiddleware> _logger;

    public ApiExceptionMiddleware(
        RequestDelegate next,
        ILogger<ApiExceptionMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            throw;
        }
        catch (KnowledgeServiceException exception)
        {
            await WriteFailure(
                context,
                exception.StatusCode,
                exception.Code,
                exception.Message,
                exception.Details);
        }
        catch (BadHttpRequestException exception)
        {
            await WriteFailure(
                context,
                400,
                "VALIDATION_ERROR",
                exception.Message,
                new Dictionary<string, object?>());
        }
        catch (JsonException exception)
        {
            await WriteFailure(
                context,
                400,
                "VALIDATION_ERROR",
                exception.Message,
                new Dictionary<string, object?>());
        }
        catch (Exception exception)
        {
            _logger.LogError(
                exception,
                "Unhandled KnowledgeService error. TraceId={TraceId}",
                context.TraceIdentifier);
            await WriteFailure(
                context,
                500,
                "INTERNAL_ERROR",
                "KnowledgeService 处理请求时发生内部错误。",
                new Dictionary<string, object?>());
        }
    }

    private static async Task WriteFailure(
        HttpContext context,
        int statusCode,
        string code,
        string message,
        IReadOnlyDictionary<string, object?> details)
    {
        if (context.Response.HasStarted)
        {
            return;
        }

        context.Response.StatusCode = statusCode;
        context.Response.ContentType = "application/json; charset=utf-8";
        await context.Response.WriteAsJsonAsync(
            new ApiFailure(
                null,
                new ApiError(code, message, details),
                context.TraceIdentifier));
    }
}
