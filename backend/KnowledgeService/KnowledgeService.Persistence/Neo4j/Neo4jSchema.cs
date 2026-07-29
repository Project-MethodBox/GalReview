using Neo4j.Driver;

namespace KnowledgeService.Persistence.Neo4j;

internal static class Neo4jSchema
{
    private static readonly string[] Statements =
    [
        """
        CREATE CONSTRAINT knowledge_graph_id_unique IF NOT EXISTS
        FOR (graph:KnowledgeGraph) REQUIRE graph.graphId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT knowledge_graph_version_unique IF NOT EXISTS
        FOR (graph:KnowledgeGraph)
        REQUIRE (graph.ownerUserId, graph.materialId, graph.version) IS UNIQUE
        """,
        """
        CREATE CONSTRAINT graph_fingerprint_unique IF NOT EXISTS
        FOR (fingerprint:GraphFingerprint) REQUIRE fingerprint.fingerprintKey IS UNIQUE
        """,
        """
        CREATE CONSTRAINT graph_sequence_unique IF NOT EXISTS
        FOR (sequence:GraphSequence) REQUIRE sequence.sequenceKey IS UNIQUE
        """,
        """
        CREATE CONSTRAINT graph_build_id_unique IF NOT EXISTS
        FOR (job:GraphBuildJob) REQUIRE job.buildId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT graph_build_idempotency_unique IF NOT EXISTS
        FOR (job:GraphBuildJob)
        REQUIRE (job.ownerUserId, job.idempotencyKey) IS UNIQUE
        """,
        """
        CREATE CONSTRAINT chapter_id_unique IF NOT EXISTS
        FOR (chapter:Chapter) REQUIRE chapter.chapterId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT point_id_unique IF NOT EXISTS
        FOR (point:KnowledgePoint) REQUIRE point.pointId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT graph_concept_key_unique IF NOT EXISTS
        FOR (point:KnowledgePoint)
        REQUIRE (point.graphId, point.conceptKey) IS UNIQUE
        """,
        """
        CREATE CONSTRAINT user_id_unique IF NOT EXISTS
        FOR (user:User) REQUIRE user.userId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT review_plan_id_unique IF NOT EXISTS
        FOR (plan:ReviewPlan) REQUIRE plan.reviewPlanId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT review_plan_node_key_unique IF NOT EXISTS
        FOR (node:ReviewPlanNode) REQUIRE node.planNodeKey IS UNIQUE
        """,
        """
        CREATE CONSTRAINT review_receipt_submission_unique IF NOT EXISTS
        FOR (receipt:ReviewResultReceipt) REQUIRE receipt.submissionId IS UNIQUE
        """,
        """
        CREATE CONSTRAINT review_receipt_idempotency_unique IF NOT EXISTS
        FOR (receipt:ReviewResultReceipt)
        REQUIRE receipt.idempotencyKey IS UNIQUE
        """,
        """
        CREATE INDEX knowledge_graph_owner_material IF NOT EXISTS
        FOR (graph:KnowledgeGraph) ON (graph.ownerUserId, graph.materialId)
        """,
        """
        CREATE INDEX chapter_graph IF NOT EXISTS
        FOR (chapter:Chapter) ON (chapter.graphId)
        """,
        """
        CREATE INDEX point_graph IF NOT EXISTS
        FOR (point:KnowledgePoint) ON (point.graphId)
        """,
        """
        CREATE INDEX review_plan_owner IF NOT EXISTS
        FOR (plan:ReviewPlan) ON (plan.ownerUserId)
        """
    ];

    public static async Task InitializeAsync(
        IDriver driver,
        string database,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var session = driver.AsyncSession(
            config => config.WithDatabase(database));

        foreach (var statement in Statements)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var cursor = await session.RunAsync(statement);
            await cursor.ConsumeAsync();
        }
    }
}
