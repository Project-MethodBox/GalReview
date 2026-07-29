using KnowledgeService.Application.Features.Health;
using MediatR;

namespace KnowledgeService.API.Endpoints;

internal static class HealthEndpoints
{
    public static IEndpointRouteBuilder MapHealthEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGet(
            "/healthz",
            () => Results.Ok(new
            {
                status = "healthy",
                service = "KnowledgeService"
            }));

        endpoints.MapGet(
            "/readyz",
            async (ISender sender, CancellationToken cancellationToken) =>
            {
                var ready = await sender.Send(
                    new GetReadinessQuery(),
                    cancellationToken);
                return ready
                    ? Results.Ok(new
                    {
                        status = "ready",
                        dependencies = new { neo4j = "ready" }
                    })
                    : Results.Json(
                        new
                        {
                            status = "not_ready",
                            dependencies = new { neo4j = "unavailable" }
                        },
                        statusCode: StatusCodes.Status503ServiceUnavailable);
            });

        return endpoints;
    }
}
