using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Reviews;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    public async Task SaveReviewPlanAsync(
        ReviewPlanGraph plan,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateReviewPlan(plan);

        await using var session = OpenSession(AccessMode.Write);
        await session.ExecuteWriteAsync(async transaction =>
        {
            var existing = await ReadStoredPlanNodeAsync(
                transaction,
                plan.ReviewPlanId);
            if (existing is not null)
            {
                var stored = Neo4jDomainMapper.ReviewPlan(
                    existing,
                    [],
                    []);
                if (stored.OwnerUserId == plan.OwnerUserId &&
                    stored.GraphId == plan.GraphId &&
                    stored.GraphVersion == plan.GraphVersion &&
                    string.Equals(
                        stored.SnapshotVersion,
                        plan.SnapshotVersion,
                        StringComparison.Ordinal))
                {
                    return true;
                }

                throw Conflict(
                    "REVIEW_PLAN_SNAPSHOT_CONFLICT",
                    "复习计划标识已用于不同的图谱快照。");
            }

            await ValidatePlanGraphReferenceAsync(transaction, plan);
            await CreatePlanAsync(transaction, plan);
            return true;
        });
    }

    public async Task<ReviewPlanGraph?> GetReviewPlanAsync(
        Guid reviewPlanId,
        Guid? ownerUserId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var session = OpenSession(AccessMode.Read);
        return await session.ExecuteReadAsync(async transaction =>
        {
            var planCursor = await transaction.RunAsync(
                """
                MATCH (plan:ReviewPlan {reviewPlanId: $reviewPlanId})
                WHERE $ownerUserId IS NULL
                   OR plan.ownerUserId = $ownerUserId
                RETURN plan
                """,
                new
                {
                    reviewPlanId =
                        Neo4jParameterMapper.Id(reviewPlanId),
                    ownerUserId = ownerUserId is null
                        ? null
                        : Neo4jParameterMapper.Id(ownerUserId.Value)
                });
            var planRecords = await planCursor.ToListAsync();
            if (planRecords.Count == 0)
            {
                return null;
            }

            var nodeCursor = await transaction.RunAsync(
                """
                MATCH (:ReviewPlan {reviewPlanId: $reviewPlanId})
                      -[:HAS_NODE]->
                      (node:ReviewPlanNode)
                RETURN node
                ORDER BY node.ordinal, node.pointId
                """,
                new
                {
                    reviewPlanId =
                        Neo4jParameterMapper.Id(reviewPlanId)
                });
            var nodeRecords = await nodeCursor.ToListAsync();
            var nodes = nodeRecords
                .Select(record => Neo4jDomainMapper.PlanNode(
                    record["node"].As<INode>()))
                .ToArray();

            var edgeCursor = await transaction.RunAsync(
                """
                MATCH (:ReviewPlan {reviewPlanId: $reviewPlanId})
                      -[:HAS_NODE]->
                      (:ReviewPlanNode)
                      -[edge:PLAN_EDGE]->
                      (:ReviewPlanNode)
                RETURN DISTINCT edge
                ORDER BY edge.fromPointId, edge.toPointId
                """,
                new
                {
                    reviewPlanId =
                        Neo4jParameterMapper.Id(reviewPlanId)
                });
            var edgeRecords = await edgeCursor.ToListAsync();
            var edges = edgeRecords
                .Select(record => Neo4jDomainMapper.PlanEdge(
                    record["edge"].As<IRelationship>()))
                .ToArray();

            return Neo4jDomainMapper.ReviewPlan(
                planRecords[0]["plan"].As<INode>(),
                nodes,
                edges);
        });
    }

    private static async Task<INode?> ReadStoredPlanNodeAsync(
        IAsyncQueryRunner transaction,
        Guid reviewPlanId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (plan:ReviewPlan {reviewPlanId: $reviewPlanId})
            RETURN plan
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId)
            });
        var records = await cursor.ToListAsync();
        return records.Count == 0
            ? null
            : records[0]["plan"].As<INode>();
    }

    private static async Task ValidatePlanGraphReferenceAsync(
        IAsyncQueryRunner transaction,
        ReviewPlanGraph plan)
    {
        var graphCursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {
                graphId: $graphId,
                ownerUserId: $ownerUserId,
                version: $graphVersion
            })
            RETURN count(graph) = 1 AS valid
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(plan.GraphId),
                ownerUserId = Neo4jParameterMapper.Id(plan.OwnerUserId),
                graphVersion = plan.GraphVersion
            });
        var graphRecord = await graphCursor.SingleAsync();
        if (!graphRecord["valid"].As<bool>())
        {
            throw NotFound(
                "KNOWLEDGE_GRAPH_NOT_FOUND",
                "复习计划引用的图谱版本不存在或不属于当前用户。");
        }

        var chapterIds = plan.RequestedChapterIds
            .Distinct()
            .Select(Neo4jParameterMapper.Id)
            .ToArray();
        if (chapterIds.Length != 0)
        {
            var chapterCursor = await transaction.RunAsync(
                """
                UNWIND $chapterIds AS chapterId
                MATCH (chapter:Chapter {
                    chapterId: chapterId,
                    graphId: $graphId
                })
                RETURN count(DISTINCT chapter) AS matched
                """,
                new
                {
                    graphId = Neo4jParameterMapper.Id(plan.GraphId),
                    chapterIds
                });
            var record = await chapterCursor.SingleAsync();
            if (record["matched"].As<long>() != chapterIds.LongLength)
            {
                throw new KnowledgeServiceException(
                    422,
                    "REVIEW_PLAN_CHAPTER_INVALID",
                    "复习计划包含不属于目标图谱的章节。");
            }
        }

        var pointIds = plan.Nodes
            .Select(node => Neo4jParameterMapper.Id(node.PointId))
            .ToArray();
        var pointCursor = await transaction.RunAsync(
            """
            UNWIND $pointIds AS pointId
            MATCH (point:KnowledgePoint {
                pointId: pointId,
                graphId: $graphId
            })
            RETURN count(DISTINCT point) AS matched
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(plan.GraphId),
                pointIds
            });
        var pointRecord = await pointCursor.SingleAsync();
        if (pointRecord["matched"].As<long>() != pointIds.LongLength)
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_PLAN_POINT_INVALID",
                "复习计划包含不属于目标图谱的知识点。");
        }
    }

    private static async Task CreatePlanAsync(
        IAsyncQueryRunner transaction,
        ReviewPlanGraph plan)
    {
        var planCursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {graphId: $graphId})
            CREATE (stored:ReviewPlan)
            SET stored += $properties
            CREATE (stored)-[:SNAPSHOT_OF]->(graph)
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(plan.GraphId),
                properties = Neo4jParameterMapper.ReviewPlan(plan)
            });
        await planCursor.ConsumeAsync();

        var nodes = plan.Nodes
            .Select((node, ordinal) =>
                Neo4jParameterMapper.PlanNode(
                    plan.ReviewPlanId,
                    node,
                    ordinal))
            .ToArray();
        if (nodes.Length != 0)
        {
            var nodeCursor = await transaction.RunAsync(
                """
                MATCH (plan:ReviewPlan {reviewPlanId: $reviewPlanId})
                UNWIND $nodes AS properties
                MATCH (point:KnowledgePoint {
                    pointId: properties.pointId,
                    graphId: $graphId
                })
                CREATE (node:ReviewPlanNode)
                SET node += properties
                CREATE (plan)-[:HAS_NODE]->(node)
                CREATE (node)-[:REFERS_TO]->(point)
                """,
                new
                {
                    reviewPlanId =
                        Neo4jParameterMapper.Id(plan.ReviewPlanId),
                    graphId = Neo4jParameterMapper.Id(plan.GraphId),
                    nodes
                });
            await nodeCursor.ConsumeAsync();
        }

        var edges = plan.Edges
            .Select(edge => Neo4jParameterMapper.PlanEdge(
                plan.ReviewPlanId,
                edge))
            .ToArray();
        if (edges.Length != 0)
        {
            var edgeCursor = await transaction.RunAsync(
                """
                UNWIND $edges AS properties
                MATCH (from:ReviewPlanNode {
                    planNodeKey: properties.fromPlanNodeKey
                })
                MATCH (to:ReviewPlanNode {
                    planNodeKey: properties.toPlanNodeKey
                })
                CREATE (from)-[edge:PLAN_EDGE]->(to)
                SET edge += properties
                """,
                new { edges });
            await edgeCursor.ConsumeAsync();
        }
    }

    private static void ValidateReviewPlan(ReviewPlanGraph plan)
    {
        var nodeIds = plan.Nodes
            .Select(node => node.PointId)
            .ToHashSet();
        var edgeKeys = plan.Edges
            .Select(edge => (
                edge.FromPointId,
                edge.ToPointId,
                edge.Type))
            .ToHashSet();
        var totalWeight = plan.Nodes.Sum(node => node.Weight);
        var outsideWeight = plan.Nodes
            .Where(node => node.IsOutsideRequestedChapters)
            .Sum(node => node.Weight);
        var invalid =
            plan.ReviewPlanId == Guid.Empty ||
            plan.GraphId == Guid.Empty ||
            plan.OwnerUserId == Guid.Empty ||
            plan.GraphVersion < 1 ||
            plan.Status != ReviewPlanStatus.Open ||
            !plan.SnapshotVersion.StartsWith(
                "plan-graph-1.0:",
                StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(plan.AlgorithmVersion) ||
            plan.RequestedChapterIds.Count == 0 ||
            plan.RequestedChapterIds.Distinct().Count() !=
            plan.RequestedChapterIds.Count ||
            plan.Nodes.Count == 0 ||
            nodeIds.Count != plan.Nodes.Count ||
            Math.Abs(totalWeight - 1) > 1e-5 ||
            !double.IsFinite(plan.EstimatedCoverage) ||
            plan.EstimatedCoverage is < 0 or > 1 ||
            plan.ExpiresAt <= plan.CreatedAt ||
            plan.Nodes.Any(node =>
                node.PointId == Guid.Empty ||
                node.ChapterId == Guid.Empty ||
                string.IsNullOrWhiteSpace(node.Title) ||
                string.IsNullOrWhiteSpace(node.Summary) ||
                !double.IsFinite(node.MasteryScore) ||
                node.MasteryScore is < 0 or > 100 ||
                !double.IsFinite(node.Weight) ||
                node.Weight is < 0 or > 1 ||
                node.DependencyDepth < 0 ||
                node.CoversPointIds.Any(pointId =>
                    !nodeIds.Contains(pointId)) ||
                node.SupportsPointIds.Any(pointId =>
                    !nodeIds.Contains(pointId))) ||
            plan.Purpose == ReviewPlanPurpose.Learning &&
            outsideWeight > 0.300001 ||
            edgeKeys.Count != plan.Edges.Count ||
            plan.Edges.Any(edge =>
                !nodeIds.Contains(edge.FromPointId) ||
                !nodeIds.Contains(edge.ToPointId) ||
                edge.FromPointId == edge.ToPointId ||
                !double.IsFinite(edge.Confidence) ||
                edge.Confidence is < 0 or > 1 ||
                !double.IsFinite(edge.InfluenceWeight) ||
                edge.InfluenceWeight is < 0 or > 1);
        if (invalid)
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_PLAN_INVALID",
                "复习计划包含空标识、重复知识点或悬空边。");
        }
    }
}
