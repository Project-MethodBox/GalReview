using KnowledgeService.Domain.Builds;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    public async Task<(GraphBuildJob Job, bool Created)> CreateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(job);
        cancellationToken.ThrowIfCancellationRequested();

        const string query =
            """
            MERGE (job:GraphBuildJob {
                ownerUserId: $ownerUserId,
                idempotencyKey: $idempotencyKey
            })
            ON CREATE SET
                job += $properties,
                job.__creationToken = $creationToken
            WITH job,
                 coalesce(job.__creationToken = $creationToken, false) AS created
            REMOVE job.__creationToken
            RETURN job, created
            """;

        var parameters = new Dictionary<string, object?>
        {
            ["ownerUserId"] = Neo4jParameterMapper.Id(job.OwnerUserId),
            ["idempotencyKey"] = job.IdempotencyKey,
            ["properties"] = Neo4jParameterMapper.BuildJob(job),
            ["creationToken"] = Guid.NewGuid().ToString("N")
        };

        await using var session = OpenSession(AccessMode.Write);
        var result = await session.ExecuteWriteAsync(async transaction =>
        {
            var cursor = await transaction.RunAsync(query, parameters);
            var record = await cursor.SingleAsync();
            return (
                Job: Neo4jDomainMapper.BuildJob(record["job"].As<INode>()),
                Created: record["created"].As<bool>());
        });

        return result;
    }

    public async Task<GraphBuildJob?> GetBuildJobAsync(
        Guid buildId,
        Guid? ownerUserId,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        const string query =
            """
            MATCH (job:GraphBuildJob {buildId: $buildId})
            WHERE $ownerUserId IS NULL OR job.ownerUserId = $ownerUserId
            RETURN job
            """;

        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            query,
            new
            {
                buildId = Neo4jParameterMapper.Id(buildId),
                ownerUserId = ownerUserId is null
                    ? null
                    : Neo4jParameterMapper.Id(ownerUserId.Value)
            });
        var records = await cursor.ToListAsync();
        return records.Count == 0
            ? null
            : Neo4jDomainMapper.BuildJob(records[0]["job"].As<INode>());
    }

    public async Task UpdateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(job);
        cancellationToken.ThrowIfCancellationRequested();
        const string query =
            """
            MATCH (stored:GraphBuildJob {
                buildId: $buildId,
                ownerUserId: $ownerUserId
            })
            FOREACH (_ IN CASE
                WHEN stored.status = 'Succeeded'
                 AND $nextStatus <> 'Succeeded'
                THEN []
                ELSE [1]
            END |
                SET stored += $properties
            )
            RETURN stored.buildId AS buildId
            """;

        await using var session = OpenSession(AccessMode.Write);
        var found = await session.ExecuteWriteAsync(async transaction =>
        {
            var cursor = await transaction.RunAsync(
                query,
                new Dictionary<string, object?>
                {
                    ["buildId"] = Neo4jParameterMapper.Id(job.BuildId),
                    ["ownerUserId"] =
                        Neo4jParameterMapper.Id(job.OwnerUserId),
                    ["nextStatus"] = job.Status.ToString(),
                    ["properties"] = Neo4jParameterMapper.BuildJob(job)
                });
            var records = await cursor.ToListAsync();
            return records.Count != 0;
        });

        if (!found)
        {
            throw NotFound(
                "GRAPH_BUILD_NOT_FOUND",
                "图谱构建任务不存在或不属于当前用户。");
        }
    }

}
