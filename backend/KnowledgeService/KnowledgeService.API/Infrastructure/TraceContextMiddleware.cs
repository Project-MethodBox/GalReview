namespace KnowledgeService.API.Infrastructure;

public sealed class TraceContextMiddleware
{
    private readonly RequestDelegate _next;

    public TraceContextMiddleware(RequestDelegate next)
    {
        _next = next;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var incoming = context.Request.Headers["X-Correlation-Id"].ToString();
        if (!string.IsNullOrWhiteSpace(incoming) && incoming.Length <= 128)
        {
            context.TraceIdentifier = incoming;
        }

        context.Response.Headers["X-Correlation-Id"] = context.TraceIdentifier;
        await _next(context);
    }
}
