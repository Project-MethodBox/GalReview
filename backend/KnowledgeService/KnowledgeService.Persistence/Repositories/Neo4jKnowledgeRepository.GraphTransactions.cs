using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    private static async Task<GraphBuildJob> GetBuildForGraphAsync(
        IAsyncQueryRunner transaction,
        Guid buildId,
        KnowledgeGraph graph)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (job:GraphBuildJob {
                buildId: $buildId,
                ownerUserId: $ownerUserId,
                materialId: $materialId
            })
            RETURN job
            """,
            new
            {
                buildId = Neo4jParameterMapper.Id(buildId),
                ownerUserId = Neo4jParameterMapper.Id(graph.OwnerUserId),
                materialId = Neo4jParameterMapper.Id(graph.MaterialId)
            });
        var records = await cursor.ToListAsync();
        if (records.Count == 0)
        {
            throw NotFound(
                "GRAPH_BUILD_NOT_FOUND",
                "图谱构建任务不存在或与图谱来源不匹配。");
        }

        var build = Neo4jDomainMapper.BuildJob(
            records[0]["job"].As<INode>());
        if (build.SourceTextChecksum is not null &&
            !string.Equals(
                build.SourceTextChecksum,
                graph.TextChecksum,
                StringComparison.OrdinalIgnoreCase))
        {
            throw Conflict(
                "GRAPH_BUILD_SOURCE_CHANGED",
                "构建任务的源文本 checksum 与待保存图谱不一致。");
        }

        return build;
    }

    private static async Task<(Guid GraphId, bool Created)>
        ClaimFingerprintAsync(
            IAsyncQueryRunner transaction,
            KnowledgeGraph graph,
            string fingerprintKey,
            string creationToken)
    {
        var cursor = await transaction.RunAsync(
            """
            MERGE (fingerprint:GraphFingerprint {
                fingerprintKey: $fingerprintKey
            })
            ON CREATE SET
                fingerprint.graphId = $graphId,
                fingerprint.ownerUserId = $ownerUserId,
                fingerprint.materialId = $materialId,
                fingerprint.textChecksum = $textChecksum,
                fingerprint.segmenterVersion = $segmenterVersion,
                fingerprint.extractorVersion = $extractorVersion,
                fingerprint.segmentationMode = $segmentationMode,
                fingerprint.__creationToken = $creationToken
            WITH fingerprint,
                 coalesce(
                    fingerprint.__creationToken = $creationToken,
                    false) AS created
            REMOVE fingerprint.__creationToken
            RETURN fingerprint.graphId AS graphId, created
            """,
            new
            {
                fingerprintKey,
                graphId = Neo4jParameterMapper.Id(graph.GraphId),
                ownerUserId = Neo4jParameterMapper.Id(graph.OwnerUserId),
                materialId = Neo4jParameterMapper.Id(graph.MaterialId),
                textChecksum = graph.TextChecksum,
                segmenterVersion = graph.SegmenterVersion,
                extractorVersion = graph.ExtractorVersion,
                segmentationMode = graph.SegmentationMode.ToString(),
                creationToken
            });
        var record = await cursor.SingleAsync();
        return (
            Guid.Parse(record["graphId"].As<string>()),
            record["created"].As<bool>());
    }

    private static async Task<bool> GraphExistsAsync(
        IAsyncQueryRunner transaction,
        Guid graphId,
        Guid ownerUserId,
        Guid materialId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {
                graphId: $graphId,
                ownerUserId: $ownerUserId,
                materialId: $materialId
            })
            RETURN count(graph) = 1 AS exists
            """,
            new
            {
                graphId = Neo4jParameterMapper.Id(graphId),
                ownerUserId = Neo4jParameterMapper.Id(ownerUserId),
                materialId = Neo4jParameterMapper.Id(materialId)
            });
        var record = await cursor.SingleAsync();
        return record["exists"].As<bool>();
    }

    private static async Task<int> NextGraphVersionAsync(
        IAsyncQueryRunner transaction,
        Guid ownerUserId,
        Guid materialId)
    {
        var sequenceKey =
            $"{Neo4jParameterMapper.Id(ownerUserId)}:" +
            Neo4jParameterMapper.Id(materialId);
        var cursor = await transaction.RunAsync(
            """
            MERGE (sequence:GraphSequence {sequenceKey: $sequenceKey})
            ON CREATE SET sequence.currentVersion = 0
            SET sequence.currentVersion = sequence.currentVersion + 1
            RETURN sequence.currentVersion AS version
            """,
            new { sequenceKey });
        var record = await cursor.SingleAsync();
        return checked((int)record["version"].As<long>());
    }

    private static async Task SupersedeReadyGraphsAsync(
        IAsyncQueryRunner transaction,
        Guid ownerUserId,
        Guid materialId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (graph:KnowledgeGraph {
                ownerUserId: $ownerUserId,
                materialId: $materialId,
                status: 'Ready'
            })
            SET graph.status = 'Superseded'
            """,
            new
            {
                ownerUserId = Neo4jParameterMapper.Id(ownerUserId),
                materialId = Neo4jParameterMapper.Id(materialId)
            });
        await cursor.ConsumeAsync();
    }
}
