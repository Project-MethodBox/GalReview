using KnowledgeService.API.Background;
using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Features.Builds;
using KnowledgeService.Domain.Segmentation;
using MediatR;

namespace KnowledgeService.API.Endpoints;

internal static class GraphBuildEndpoints
{
    public static IEndpointRouteBuilder MapGraphBuildEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        var group = endpoints.MapGroup("/api/v1/knowledge-graph-builds");

        group.MapPost(
            "/",
            async (
                GraphBuildRequest request,
                HttpContext context,
                ISender sender,
                IGraphBuildQueue queue,
                CancellationToken cancellationToken) =>
            {
                var command = new CreateGraphBuildCommand(
                    request.MaterialId,
                    RequestIdentity.RequireUserId(context),
                    request.SubjectHint,
                    new SegmentationOptions(
                        request.SegmentationMode ?? SegmentationMode.Auto,
                        request.Delimiter,
                        request.MinChapterCharacters ?? 120,
                        request.MaxChapterCharacters ?? 60_000,
                        request.FixedWindowCharacters ?? 8_000),
                    request.ExtractorVersion,
                    RequestIdentity.IdempotencyKey(context),
                    request.StudyProjectId);
                var result = await sender.Send(command, cancellationToken);
                if (result.Created ||
                    result.Job.Status == Domain.Builds.GraphBuildStatus.Queued)
                {
                    await queue.EnqueueAsync(
                        new GraphBuildWorkItem(
                            result.Job.BuildId,
                            context.TraceIdentifier),
                        cancellationToken);
                }

                return ApiResults.Success(
                    context,
                    GraphBuildJobResponse.From(result.Job),
                    StatusCodes.Status202Accepted);
            });

        group.MapGet(
            "/{buildId:guid}",
            async (
                Guid buildId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var job = await sender.Send(
                    new GetGraphBuildQuery(
                        buildId,
                        RequestIdentity.RequireUserId(context)),
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    GraphBuildJobResponse.From(job));
            });

        return endpoints;
    }
}
