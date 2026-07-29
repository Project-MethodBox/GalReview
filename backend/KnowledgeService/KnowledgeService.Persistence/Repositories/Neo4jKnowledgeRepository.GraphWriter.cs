using KnowledgeService.Domain.Graphs;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    private static async Task CreateGraphNodesAsync(
        IAsyncQueryRunner transaction,
        KnowledgeGraph graph,
        int version,
        string fingerprintKey)
    {
        var graphCursor = await transaction.RunAsync(
            """
            CREATE (stored:KnowledgeGraph)
            SET stored += $properties
            """,
            new
            {
                properties = Neo4jParameterMapper.Graph(
                    graph,
                    version,
                    fingerprintKey)
            });
        await graphCursor.ConsumeAsync();

        var chapters = graph.Chapters
            .Select(Neo4jParameterMapper.Chapter)
            .ToArray();
        var chapterCursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {graphId: $graphId})
            UNWIND $chapters AS properties
            CREATE (chapter:Chapter)
            SET chapter += properties
            CREATE (graph)-[:HAS_CHAPTER]->(chapter)
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                chapters
            });
        await chapterCursor.ConsumeAsync();

        var hierarchyCursor = await transaction.RunAsync(
            """
            UNWIND $chapters AS properties
            WITH properties
            WHERE properties.parentChapterId IS NOT NULL
            MATCH (child:Chapter {
                chapterId: properties.chapterId,
                graphId: $graphId
            })
            MATCH (parent:Chapter {
                chapterId: properties.parentChapterId,
                graphId: $graphId
            })
            CREATE (parent)-[:HAS_CHILD]->(child)
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                chapters
            });
        await hierarchyCursor.ConsumeAsync();

        var points = graph.Points
            .Select(Neo4jParameterMapper.Point)
            .ToArray();
        var pointCursor = await transaction.RunAsync(
            """
            UNWIND $points AS properties
            MATCH (chapter:Chapter {
                chapterId: properties.chapterId,
                graphId: $graphId
            })
            CREATE (point:KnowledgePoint)
            SET point += properties
            CREATE (chapter)-[:HAS_POINT]->(point)
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                points
            });
        await pointCursor.ConsumeAsync();
    }

    private static async Task CreateGraphRelationsAsync(
        IAsyncQueryRunner transaction,
        KnowledgeGraph graph)
    {
        await CreateRelationsOfTypeAsync(
            transaction,
            graph,
            KnowledgeRelationType.Prerequisite,
            "PREREQUISITE_OF");
        await CreateRelationsOfTypeAsync(
            transaction,
            graph,
            KnowledgeRelationType.Related,
            "RELATED_TO");
        await CreateRelationsOfTypeAsync(
            transaction,
            graph,
            KnowledgeRelationType.Contrasts,
            "CONTRASTS_WITH");
    }

    private static async Task CreateRelationsOfTypeAsync(
        IAsyncQueryRunner transaction,
        KnowledgeGraph graph,
        KnowledgeRelationType type,
        string relationshipType)
    {
        var relations = graph.Relations
            .Where(relation => relation.Type == type)
            .Select(Neo4jParameterMapper.Relation)
            .ToArray();
        if (relations.Length == 0)
        {
            return;
        }

        var query =
            $$"""
            UNWIND $relations AS properties
            MATCH (from:KnowledgePoint {
                pointId: properties.fromPointId,
                graphId: $graphId
            })
            MATCH (to:KnowledgePoint {
                pointId: properties.toPointId,
                graphId: $graphId
            })
            CREATE (from)-[relation:{{relationshipType}}]->(to)
            SET relation += properties
            """;
        var cursor = await transaction.RunAsync(
            query,
            new
            {
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                relations
            });
        await cursor.ConsumeAsync();
    }

    private static async Task CreateInitialMasteryAsync(
        IAsyncQueryRunner transaction,
        KnowledgeGraph graph)
    {
        var initial = new Dictionary<string, object?>
        {
            ["userId"] = Neo4jParameterMapper.Id(graph.OwnerUserId),
            ["score"] = 0d,
            ["easinessFactor"] = 2.5d,
            ["intervalDays"] = 0,
            ["repetitions"] = 0,
            ["lapses"] = 0,
            ["nextReviewAt"] =
                Neo4jParameterMapper.Timestamp(graph.CreatedAt),
            ["lastReviewedAt"] = null,
            ["reason"] = "INITIAL",
            ["version"] = 0L
        };
        var cursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {graphId: $graphId})
                  -[:HAS_CHAPTER]->
                  (:Chapter)
                  -[:HAS_POINT]->
                  (point:KnowledgePoint)
            MERGE (user:User {userId: $ownerUserId})
            MERGE (user)-[mastery:MASTERY]->(point)
            ON CREATE SET
                mastery += $initial,
                mastery.pointId = point.pointId
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                ownerUserId = Neo4jParameterMapper.Id(graph.OwnerUserId),
                initial
            });
        await cursor.ConsumeAsync();
    }

    private static async Task LinkFingerprintAsync(
        IAsyncQueryRunner transaction,
        string fingerprintKey,
        Guid graphId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (fingerprint:GraphFingerprint {
                fingerprintKey: $fingerprintKey
            })
            MATCH (graph:KnowledgeGraph {graphId: $graphId})
            MERGE (fingerprint)-[:RESOLVES_TO]->(graph)
            """,
            new
            {
                fingerprintKey,
                graphId = Neo4jParameterMapper.Id(graphId)
            });
        await cursor.ConsumeAsync();
    }

    private static async Task MarkBuildSucceededAsync(
        IAsyncQueryRunner transaction,
        Guid buildId,
        Guid graphId,
        DateTimeOffset updatedAt)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (job:GraphBuildJob {buildId: $buildId})
            SET job.status = 'Succeeded',
                job.progress = 100,
                job.graphId = $graphId,
                job.errorCode = null,
                job.errorMessage = null,
                job.updatedAt = $updatedAt
            """,
            new
            {
                buildId = Neo4jParameterMapper.Id(buildId),
                graphId = Neo4jParameterMapper.Id(graphId),
                updatedAt = Neo4jParameterMapper.Timestamp(updatedAt)
            });
        await cursor.ConsumeAsync();
    }
}
