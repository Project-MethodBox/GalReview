using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    public async Task<KnowledgeGraph> SaveGraphAsync(
        KnowledgeGraph graph,
        Guid buildId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(graph);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateGraph(graph);

        var creationToken = Guid.NewGuid().ToString("N");

        await using var session = OpenSession(AccessMode.Write);
        var persistedGraphId = await session.ExecuteWriteAsync(
            async transaction =>
            {
                var build = await GetBuildForGraphAsync(
                    transaction,
                    buildId,
                    graph);
                if (build.Status == GraphBuildStatus.Succeeded &&
                    build.GraphId is not null)
                {
                    return build.GraphId.Value;
                }

                var fingerprintKey = GraphFingerprint.Create(
                    graph,
                    build.Segmentation);
                var fingerprint = await ClaimFingerprintAsync(
                    transaction,
                    graph,
                    build.Segmentation,
                    fingerprintKey,
                    creationToken);
                if (!fingerprint.Created)
                {
                    if (!await GraphExistsAsync(
                            transaction,
                            fingerprint.GraphId,
                            graph.OwnerUserId,
                            graph.MaterialId,
                            graph.StudyProjectId))
                    {
                        throw IntegrityFailure(
                            "图谱指纹已存在，但其目标图谱不存在。");
                    }

                    await MarkBuildSucceededAsync(
                        transaction,
                        buildId,
                        fingerprint.GraphId,
                        graph.CreatedAt);
                    return fingerprint.GraphId;
                }

                var version = await NextGraphVersionAsync(
                    transaction,
                    graph.OwnerUserId,
                    graph.MaterialId,
                    graph.StudyProjectId);
                await SupersedeReadyGraphsAsync(
                    transaction,
                    graph.OwnerUserId,
                    graph.MaterialId,
                    graph.StudyProjectId);
                await CreateGraphNodesAsync(
                    transaction,
                    graph,
                    version,
                    fingerprintKey);
                await CreateGraphRelationsAsync(transaction, graph);
                await CreateInitialMasteryAsync(transaction, graph);
                await LinkFingerprintAsync(
                    transaction,
                    fingerprintKey,
                    graph.GraphId);
                await MarkBuildSucceededAsync(
                    transaction,
                    buildId,
                    graph.GraphId,
                    graph.CreatedAt);
                return graph.GraphId;
            });

        return await GetGraphAsync(
            persistedGraphId,
            graph.OwnerUserId,
            cancellationToken) ?? throw IntegrityFailure(
            "图谱事务已提交，但无法重新读取保存的图谱。");
    }

    public async Task<KnowledgeGraph?> GetGraphAsync(
        Guid graphId,
        Guid? ownerUserId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var session = OpenSession(AccessMode.Read);
        return await session.ExecuteReadAsync(async transaction =>
        {
            const string graphQuery =
                """
                MATCH (graph:KnowledgeGraph {graphId: $graphId})
                WHERE $ownerUserId IS NULL
                   OR graph.ownerUserId = $ownerUserId
                RETURN graph
                """;
            var graphCursor = await transaction.RunAsync(
                graphQuery,
                new
                {
                    graphId = Neo4jParameterMapper.Id(graphId),
                    ownerUserId = ownerUserId is null
                        ? null
                        : Neo4jParameterMapper.Id(ownerUserId.Value)
                });
            var graphRecords = await graphCursor.ToListAsync();
            if (graphRecords.Count == 0)
            {
                return null;
            }

            var parameters = new
            {
                graphId = Neo4jParameterMapper.Id(graphId)
            };
            var chapterCursor = await transaction.RunAsync(
                """
                MATCH (chapter:Chapter {graphId: $graphId})
                RETURN chapter
                ORDER BY chapter.ordinal, chapter.chapterId
                """,
                parameters);
            var chapterRecords = await chapterCursor.ToListAsync();
            var chapters = chapterRecords
                .Select(record => Neo4jDomainMapper.Chapter(
                    record["chapter"].As<INode>()))
                .ToArray();

            var pointCursor = await transaction.RunAsync(
                """
                MATCH (point:KnowledgePoint {graphId: $graphId})
                RETURN point
                ORDER BY point.ordinal, point.pointId
                """,
                parameters);
            var pointRecords = await pointCursor.ToListAsync();
            var points = pointRecords
                .Select(record => Neo4jDomainMapper.Point(
                    record["point"].As<INode>()))
                .ToArray();

            var relationCursor = await transaction.RunAsync(
                """
                MATCH (from:KnowledgePoint {graphId: $graphId})
                      -[relation]->
                      (to:KnowledgePoint {graphId: $graphId})
                WHERE type(relation) IN [
                    'PREREQUISITE_OF',
                    'RELATED_TO',
                    'CONTRASTS_WITH'
                ]
                RETURN relation
                ORDER BY relation.relationId
                """,
                parameters);
            var relationRecords = await relationCursor.ToListAsync();
            var relations = relationRecords
                .Select(record => Neo4jDomainMapper.Relation(
                    record["relation"].As<IRelationship>()))
                .ToArray();

            return Neo4jDomainMapper.Graph(
                graphRecords[0]["graph"].As<INode>(),
                chapters,
                points,
                relations);
        });
    }

    public async Task<KnowledgePoint?> GetPointAsync(
        Guid pointId,
        Guid ownerUserId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        const string query =
            """
            MATCH (graph:KnowledgeGraph {ownerUserId: $ownerUserId})
                  -[:HAS_CHAPTER]->
                  (:Chapter)
                  -[:HAS_POINT]->
                  (point:KnowledgePoint {pointId: $pointId})
            RETURN point
            """;

        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            query,
            new
            {
                pointId = Neo4jParameterMapper.Id(pointId),
                ownerUserId = Neo4jParameterMapper.Id(ownerUserId)
            });
        var records = await cursor.ToListAsync();
        return records.Count == 0
            ? null
            : Neo4jDomainMapper.Point(records[0]["point"].As<INode>());
    }

    public async Task<IReadOnlyList<KnowledgeGraphSummary>> ListGraphsAsync(
        Guid studyProjectId,
        Guid ownerUserId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        const string query =
            """
            MATCH (graph:KnowledgeGraph {
                studyProjectId: $studyProjectId,
                ownerUserId: $ownerUserId
            })
            RETURN graph
            ORDER BY graph.version DESC
            """;

        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            query,
            new
            {
                studyProjectId = Neo4jParameterMapper.Id(studyProjectId),
                ownerUserId = Neo4jParameterMapper.Id(ownerUserId)
            });
        var records = await cursor.ToListAsync();
        return records
            .Select(record => Neo4jDomainMapper.GraphSummary(
                record["graph"].As<INode>()))
            .ToArray();
    }
}
