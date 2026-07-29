using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Planning;

internal static class PlanGraphFactory
{
    public static IReadOnlyList<PlanEdge> EdgesFor(
        KnowledgeGraph graph,
        IReadOnlySet<Guid> includedPointIds)
    {
        var prerequisiteCounts = graph.Relations
            .Where(relation => relation.Type == KnowledgeRelationType.Prerequisite)
            .GroupBy(relation => relation.ToPointId)
            .ToDictionary(
                group => group.Key,
                group => group
                    .Select(relation => relation.FromPointId)
                    .Distinct()
                    .Count());

        return graph.Relations
            .Where(relation =>
                includedPointIds.Contains(relation.FromPointId) &&
                includedPointIds.Contains(relation.ToPointId))
            .Select(relation => new PlanEdge(
                relation.FromPointId,
                relation.ToPointId,
                relation.Type,
                relation.Confidence,
                relation.Type == KnowledgeRelationType.Prerequisite
                    ? Math.Round(
                        relation.Confidence /
                        Math.Max(
                            1,
                            prerequisiteCounts.GetValueOrDefault(
                                relation.ToPointId)),
                        6)
                    : relation.Confidence))
            .OrderBy(edge => edge.FromPointId)
            .ThenBy(edge => edge.ToPointId)
            .ToArray();
    }

    public static string SnapshotVersion(
        Guid reviewPlanId,
        KnowledgeGraph graph,
        ReviewPlanPurpose purpose,
        string algorithmVersion,
        IReadOnlyList<Guid> requestedChapterIds,
        IReadOnlyList<PlanNode> nodes,
        IReadOnlyList<PlanEdge> edges,
        double estimatedCoverage,
        DateTimeOffset createdAt,
        DateTimeOffset expiresAt)
    {
        var canonical = JsonSerializer.Serialize(new
        {
            schemaVersion = "1.0",
            reviewPlanId = reviewPlanId.ToString("D"),
            graphId = graph.GraphId.ToString("D"),
            graphVersion = graph.Version,
            ownerUserId = graph.OwnerUserId.ToString("D"),
            purpose = purpose.ToString(),
            algorithmVersion,
            estimatedCoverage,
            createdAt = createdAt
                .ToUniversalTime()
                .ToString("O", CultureInfo.InvariantCulture),
            expiresAt = expiresAt
                .ToUniversalTime()
                .ToString("O", CultureInfo.InvariantCulture),
            requestedChapterIds = requestedChapterIds
                .OrderBy(chapterId => chapterId)
                .Select(chapterId => chapterId.ToString("D"))
                .ToArray(),
            nodes = nodes
                .OrderBy(node => node.PointId)
                .Select(node => new
                {
                    pointId = node.PointId.ToString("D"),
                    chapterId = node.ChapterId.ToString("D"),
                    node.Title,
                    node.Summary,
                    tags = node.Tags
                        .OrderBy(tag => tag, StringComparer.Ordinal)
                        .ToArray(),
                    node.MasteryScore,
                    node.Weight,
                    node.IsQuestionTarget,
                    node.IsOutsideRequestedChapters,
                    node.DependencyDepth,
                    coversPointIds = node.CoversPointIds
                        .OrderBy(pointId => pointId)
                        .Select(pointId => pointId.ToString("D"))
                        .ToArray(),
                    supportsPointIds = node.SupportsPointIds
                        .OrderBy(pointId => pointId)
                        .Select(pointId => pointId.ToString("D"))
                        .ToArray(),
                    node.Reason
                })
                .ToArray(),
            edges = edges
                .OrderBy(edge => edge.FromPointId)
                .ThenBy(edge => edge.ToPointId)
                .Select(edge => new
                {
                    fromPointId = edge.FromPointId.ToString("D"),
                    toPointId = edge.ToPointId.ToString("D"),
                    type = edge.Type.ToString(),
                    edge.Confidence,
                    edge.InfluenceWeight
                })
                .ToArray()
        });
        var checksum = Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        return $"plan-graph-1.0:{checksum}";
    }
}
