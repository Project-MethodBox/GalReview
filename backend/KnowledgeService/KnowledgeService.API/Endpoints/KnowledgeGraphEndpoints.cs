using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Features.Graphs;
using KnowledgeService.Application.Features.Mastery;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using MediatR;

namespace KnowledgeService.API.Endpoints;

internal static class KnowledgeGraphEndpoints
{
    public static IEndpointRouteBuilder MapKnowledgeGraphEndpoints(
        this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGet(
            "/api/v1/knowledge-graphs",
            async (
                Guid studyProjectId,
                string? cursor,
                int? limit,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var graphs = await sender.Send(
                    new ListKnowledgeGraphsQuery(
                        studyProjectId,
                        RequestIdentity.RequireUserId(context)),
                    cancellationToken);
                var page = CursorPagination.Page(graphs, cursor, limit ?? 20);
                return ApiResults.Success(
                    context,
                    new PagedData<KnowledgeGraphSummary>(
                        page.Items,
                        page.NextCursor));
            });

        endpoints.MapGet(
            "/api/v1/knowledge-graphs/{graphId:guid}",
            async (
                Guid graphId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var graph = await GetOwnedGraph(
                    graphId,
                    context,
                    sender,
                    cancellationToken);
                return ApiResults.Success(context, ToSummary(graph));
            });

        endpoints.MapGet(
            "/internal/v1/knowledge-graphs/{graphId:guid}/scope",
            async (
                Guid graphId,
                Guid ownerUserId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                if (!string.Equals(RequestIdentity.RequireServiceName(context), "PracticeService", StringComparison.Ordinal))
                    throw new Application.Exceptions.KnowledgeServiceException(403, "FORBIDDEN", "该接口只允许 PracticeService 调用。");
                var graph = await sender.Send(new GetKnowledgeGraphQuery(graphId, ownerUserId), cancellationToken);
                return ApiResults.Success(context, new
                {
                    graph.GraphId,
                    graph.MaterialId,
                    graph.StudyProjectId,
                    graph.OwnerUserId
                });
            });

        endpoints.MapGet(
            "/api/v1/knowledge-graphs/{graphId:guid}/chapters",
            async (
                Guid graphId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var graph = await GetOwnedGraph(
                    graphId,
                    context,
                    sender,
                    cancellationToken);
                return ApiResults.Success(
                    context,
                    graph.Chapters.OrderBy(chapter => chapter.Ordinal).ToArray());
            });

        endpoints.MapGet(
            "/api/v1/knowledge-graphs/{graphId:guid}/points",
            async (
                Guid graphId,
                string? cursor,
                int? limit,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var userId = RequestIdentity.RequireUserId(context);
                var graph = await sender.Send(
                    new GetKnowledgeGraphQuery(graphId, userId),
                    cancellationToken);
                var mastery = await sender.Send(
                    new GetMasteryQuery(graphId, userId),
                    cancellationToken);
                var projected = graph.Points
                    .OrderBy(point => point.Ordinal)
                    .Select(point => KnowledgePointResponse.From(
                        point,
                        mastery.GetValueOrDefault(point.PointId) ??
                        MasteryState.Initial(userId, point.PointId, graph.CreatedAt)))
                    .ToArray();
                var page = CursorPagination.Page(projected, cursor, limit ?? 50);
                return ApiResults.Success(
                    context,
                    new PagedData<KnowledgePointResponse>(
                        page.Items,
                        page.NextCursor));
            });

        endpoints.MapGet(
            "/api/v1/knowledge-graphs/{graphId:guid}/relations",
            async (
                Guid graphId,
                string? cursor,
                int? limit,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var graph = await GetOwnedGraph(
                    graphId,
                    context,
                    sender,
                    cancellationToken);
                var relations = graph.Relations
                    .OrderBy(relation => relation.RelationId)
                    .ToArray();
                var page = CursorPagination.Page(relations, cursor, limit ?? 50);
                return ApiResults.Success(
                    context,
                    new PagedData<KnowledgeRelation>(
                        page.Items,
                        page.NextCursor));
            });

        endpoints.MapGet(
            "/api/v1/knowledge-points/{pointId:guid}",
            async (
                Guid pointId,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var userId = RequestIdentity.RequireUserId(context);
                var point = await sender.Send(
                    new GetKnowledgePointQuery(pointId, userId),
                    cancellationToken);
                var mastery = await sender.Send(
                    new GetMasteryQuery(point.GraphId, userId),
                    cancellationToken);
                var state = mastery.GetValueOrDefault(point.PointId) ??
                            MasteryState.Initial(
                                userId,
                                point.PointId,
                                point.CreatedAt);
                return ApiResults.Success(
                    context,
                    KnowledgePointResponse.From(point, state));
            });

        endpoints.MapGet(
            "/api/v1/mastery-records",
            async (
                Guid graphId,
                string? cursor,
                int? limit,
                HttpContext context,
                ISender sender,
                CancellationToken cancellationToken) =>
            {
                var mastery = await sender.Send(
                    new GetMasteryQuery(
                        graphId,
                        RequestIdentity.RequireUserId(context)),
                    cancellationToken);
                var ordered = mastery.Values
                    .OrderBy(state => state.PointId)
                    .ToArray();
                var page = CursorPagination.Page(ordered, cursor, limit ?? 50);
                return ApiResults.Success(
                    context,
                    new PagedData<MasteryState>(
                        page.Items,
                        page.NextCursor));
            });

        return endpoints;
    }

    private static Task<KnowledgeGraph> GetOwnedGraph(
        Guid graphId,
        HttpContext context,
        ISender sender,
        CancellationToken cancellationToken) =>
        sender.Send(
            new GetKnowledgeGraphQuery(
                graphId,
                RequestIdentity.RequireUserId(context)),
            cancellationToken);

    private static KnowledgeGraphSummary ToSummary(KnowledgeGraph graph) =>
        new(
            graph.GraphId,
            graph.MaterialId,
            graph.Version,
            graph.SubjectCode,
            graph.Chapters.Count,
            graph.Points.Count,
            graph.Relations.Count,
            graph.Status,
            graph.TextChecksum,
            graph.CreatedAt,
            graph.StudyProjectId);
}
