using System.Globalization;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Persistence.Mapping;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository
{
    public async Task<bool> IsReviewSubmissionDuplicateAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            """
            MATCH (receipt:ReviewResultReceipt)
            WHERE receipt.submissionId = $submissionId
               OR receipt.idempotencyKey = $idempotencyKey
            RETURN receipt
            """,
            new
            {
                submissionId = Neo4jParameterMapper.Id(submissionId),
                idempotencyKey = Neo4jParameterMapper.Id(idempotencyKey)
            });
        var records = await cursor.ToListAsync();
        if (records.Count == 0)
        {
            return false;
        }

        if (records.Count != 1)
        {
            throw ReceiptConflict();
        }

        EnsureMatchingReceipt(
            records[0]["receipt"].As<INode>(),
            reviewPlanId,
            userId,
            submissionId,
            idempotencyKey,
            payloadChecksum);
        return true;
    }

    public async Task<IReadOnlyDictionary<Guid, MasteryState>>
        GetMasteryAsync(
            Guid graphId,
            Guid userId,
            CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        const string query =
            """
            MATCH (graph:KnowledgeGraph {
                graphId: $graphId,
                ownerUserId: $userId
            })
                  -[:HAS_CHAPTER]->
                  (:Chapter)
                  -[:HAS_POINT]->
                  (point:KnowledgePoint)
            OPTIONAL MATCH (user:User {userId: $userId})
                          -[mastery:MASTERY]->
                          (point)
            RETURN point.pointId AS pointId,
                   mastery,
                   graph.createdAt AS graphCreatedAt
            ORDER BY point.ordinal, point.pointId
            """;

        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            query,
            new
            {
                graphId = Neo4jParameterMapper.Id(graphId),
                userId = Neo4jParameterMapper.Id(userId)
            });
        var records = await cursor.ToListAsync();
        return records.ToDictionary(
            record => Guid.Parse(record["pointId"].As<string>()),
            record => record["mastery"] is IRelationship relationship
                ? Neo4jDomainMapper.Mastery(relationship)
                : MasteryState.Initial(
                    userId,
                    Guid.Parse(record["pointId"].As<string>()),
                    DateTimeOffset.Parse(
                        record["graphCreatedAt"].As<string>(),
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.RoundtripKind)));
    }

    public async Task<bool> ApplyMasteryUpdatesAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        IReadOnlyList<MasteryState> updates,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(updates);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateMasterySubmission(
            reviewPlanId,
            userId,
            submissionId,
            idempotencyKey,
            payloadChecksum,
            updates);

        var appliedAt = DateTimeOffset.UtcNow;
        var creationToken = Guid.NewGuid().ToString("N");
        try
        {
            await using var session = OpenSession(AccessMode.Write);
            return await session.ExecuteWriteAsync(async transaction =>
            {
                await EnsureOwnedPlanExistsAsync(
                    transaction,
                    reviewPlanId,
                    userId);
                var receipt = await ClaimSubmissionReceiptAsync(
                    transaction,
                    reviewPlanId,
                    userId,
                    submissionId,
                    idempotencyKey,
                    payloadChecksum,
                    appliedAt,
                    creationToken);
                if (!receipt.Created)
                {
                    EnsureMatchingReceipt(
                        receipt.Node,
                        reviewPlanId,
                        userId,
                        submissionId,
                        idempotencyKey,
                        payloadChecksum);
                    return true;
                }

                await EnsurePlanOpenAsync(
                    transaction,
                    reviewPlanId,
                    userId);
                var updated = await ApplyMasteryRowsAsync(
                    transaction,
                    reviewPlanId,
                    userId,
                    updates,
                    appliedAt);
                if (updated != updates.Count)
                {
                    throw new MasteryConcurrencyException(
                        "至少一个知识点不属于计划，或掌握度版本已变化。");
                }

                await CompleteReceiptAndPlanAsync(
                    transaction,
                    reviewPlanId,
                    userId,
                    submissionId,
                    appliedAt);
                return false;
            });
        }
        catch (Neo4jException exception)
            when (IsConstraintFailure(exception))
        {
            return await ResolveReceiptConstraintRaceAsync(
                reviewPlanId,
                userId,
                submissionId,
                idempotencyKey,
                payloadChecksum,
                cancellationToken);
        }
    }

    private static async Task EnsureOwnedPlanExistsAsync(
        IAsyncQueryRunner transaction,
        Guid reviewPlanId,
        Guid userId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (plan:ReviewPlan {
                reviewPlanId: $reviewPlanId,
                ownerUserId: $userId
            })
            RETURN count(plan) = 1 AS exists
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId),
                userId = Neo4jParameterMapper.Id(userId)
            });
        var record = await cursor.SingleAsync();
        if (!record["exists"].As<bool>())
        {
            throw NotFound(
                "REVIEW_PLAN_NOT_FOUND",
                "复习计划不存在或不属于当前用户。");
        }
    }

    private static async Task EnsurePlanOpenAsync(
        IAsyncQueryRunner transaction,
        Guid reviewPlanId,
        Guid userId)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (plan:ReviewPlan {
                reviewPlanId: $reviewPlanId,
                ownerUserId: $userId
            })
            RETURN plan.status = 'Open' AS isOpen
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId),
                userId = Neo4jParameterMapper.Id(userId)
            });
        var record = await cursor.SingleAsync();
        if (!record["isOpen"].As<bool>())
        {
            throw Conflict(
                "REVIEW_PLAN_NOT_OPEN",
                "复习计划已结束或过期。");
        }
    }

    private static async Task<(INode Node, bool Created)>
        ClaimSubmissionReceiptAsync(
            IAsyncQueryRunner transaction,
            Guid reviewPlanId,
            Guid userId,
            Guid submissionId,
            Guid idempotencyKey,
            string payloadChecksum,
            DateTimeOffset appliedAt,
            string creationToken)
    {
        var cursor = await transaction.RunAsync(
            """
            MERGE (receipt:ReviewResultReceipt {
                submissionId: $submissionId
            })
            ON CREATE SET
                receipt.reviewPlanId = $reviewPlanId,
                receipt.userId = $userId,
                receipt.idempotencyKey = $idempotencyKey,
                receipt.payloadChecksum = $payloadChecksum,
                receipt.applied = false,
                receipt.createdAt = $createdAt,
                receipt.__creationToken = $creationToken
            WITH receipt,
                 coalesce(
                    receipt.__creationToken = $creationToken,
                    false) AS created
            REMOVE receipt.__creationToken
            RETURN receipt, created
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId),
                userId = Neo4jParameterMapper.Id(userId),
                submissionId = Neo4jParameterMapper.Id(submissionId),
                idempotencyKey = Neo4jParameterMapper.Id(idempotencyKey),
                payloadChecksum,
                createdAt = Neo4jParameterMapper.Timestamp(appliedAt),
                creationToken
            });
        var record = await cursor.SingleAsync();
        return (
            record["receipt"].As<INode>(),
            record["created"].As<bool>());
    }

    private static async Task<int> ApplyMasteryRowsAsync(
        IAsyncQueryRunner transaction,
        Guid reviewPlanId,
        Guid userId,
        IReadOnlyList<MasteryState> updates,
        DateTimeOffset now)
    {
        if (updates.Count == 0)
        {
            return 0;
        }

        var rows = updates
            .Select(Neo4jParameterMapper.Mastery)
            .ToArray();
        var cursor = await transaction.RunAsync(
            """
            UNWIND $updates AS update
            MATCH (plan:ReviewPlan {
                reviewPlanId: $reviewPlanId,
                ownerUserId: $userId
            })
                  -[:HAS_NODE]->
                  (planNode:ReviewPlanNode {
                      pointId: update.pointId
                  })
                  -[:REFERS_TO]->
                  (point:KnowledgePoint {
                      pointId: update.pointId
                  })
            MERGE (user:User {userId: $userId})
            MERGE (user)-[mastery:MASTERY]->(point)
            ON CREATE SET
                mastery.userId = $userId,
                mastery.pointId = point.pointId,
                mastery.score = 0.0,
                mastery.easinessFactor = 2.5,
                mastery.intervalDays = 0,
                mastery.repetitions = 0,
                mastery.lapses = 0,
                mastery.nextReviewAt = $now,
                mastery.lastReviewedAt = null,
                mastery.reason = 'INITIAL',
                mastery.version = 0
            WITH mastery, update
            WHERE mastery.version = update.expectedVersion
            SET mastery.userId = update.userId,
                mastery.pointId = update.pointId,
                mastery.score = update.score,
                mastery.easinessFactor = update.easinessFactor,
                mastery.intervalDays = update.intervalDays,
                mastery.repetitions = update.repetitions,
                mastery.lapses = update.lapses,
                mastery.nextReviewAt = update.nextReviewAt,
                mastery.lastReviewedAt = update.lastReviewedAt,
                mastery.reason = update.reason,
                mastery.version = mastery.version + 1
            WITH mastery, update
            WHERE mastery.version = update.version
            RETURN count(*) AS updated
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId),
                userId = Neo4jParameterMapper.Id(userId),
                now = Neo4jParameterMapper.Timestamp(now),
                updates = rows
            });
        var record = await cursor.SingleAsync();
        return checked((int)record["updated"].As<long>());
    }

    private static async Task CompleteReceiptAndPlanAsync(
        IAsyncQueryRunner transaction,
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        DateTimeOffset appliedAt)
    {
        var cursor = await transaction.RunAsync(
            """
            MATCH (receipt:ReviewResultReceipt {
                submissionId: $submissionId,
                reviewPlanId: $reviewPlanId,
                userId: $userId
            })
            MATCH (plan:ReviewPlan {
                reviewPlanId: $reviewPlanId,
                ownerUserId: $userId
            })
            SET receipt.applied = true,
                receipt.appliedAt = $appliedAt,
                plan.status = 'Completed',
                plan.completedAt = $appliedAt
            """,
            new
            {
                reviewPlanId = Neo4jParameterMapper.Id(reviewPlanId),
                userId = Neo4jParameterMapper.Id(userId),
                submissionId = Neo4jParameterMapper.Id(submissionId),
                appliedAt = Neo4jParameterMapper.Timestamp(appliedAt)
            });
        await cursor.ConsumeAsync();
    }

    private async Task<bool> ResolveReceiptConstraintRaceAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var session = OpenSession(AccessMode.Read);
        var cursor = await session.RunAsync(
            """
            MATCH (receipt:ReviewResultReceipt)
            WHERE receipt.submissionId = $submissionId
               OR receipt.idempotencyKey = $idempotencyKey
            RETURN receipt
            """,
            new
            {
                submissionId = Neo4jParameterMapper.Id(submissionId),
                idempotencyKey = Neo4jParameterMapper.Id(idempotencyKey)
            });
        var records = await cursor.ToListAsync();
        if (records.Count == 1)
        {
            EnsureMatchingReceipt(
                records[0]["receipt"].As<INode>(),
                reviewPlanId,
                userId,
                submissionId,
                idempotencyKey,
                payloadChecksum);
            return true;
        }

        throw ReceiptConflict();
    }

    private static void EnsureMatchingReceipt(
        INode receipt,
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum)
    {
        var properties = receipt.Properties;
        var matches =
            Neo4jPropertyReader.Guid(properties, "reviewPlanId") ==
                reviewPlanId &&
            Neo4jPropertyReader.Guid(properties, "userId") == userId &&
            Neo4jPropertyReader.Guid(properties, "submissionId") ==
                submissionId &&
            Neo4jPropertyReader.Guid(properties, "idempotencyKey") ==
                idempotencyKey &&
            string.Equals(
                Neo4jPropertyReader.String(
                    properties,
                    "payloadChecksum"),
                payloadChecksum,
                StringComparison.OrdinalIgnoreCase) &&
            Neo4jPropertyReader.Boolean(properties, "applied");
        if (!matches)
        {
            throw ReceiptConflict();
        }
    }

    private static KnowledgeServiceException ReceiptConflict() =>
        Conflict(
            "IDEMPOTENCY_CONFLICT",
            "提交标识或幂等键已用于不同的复习结果。");

    private static bool IsConstraintFailure(Neo4jException exception) =>
        exception.Code.Contains(
            "Constraint",
            StringComparison.OrdinalIgnoreCase);

    private static void ValidateMasterySubmission(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        IReadOnlyList<MasteryState> updates)
    {
        var pointIds = updates
            .Select(update => update.PointId)
            .ToHashSet();
        var invalid =
            reviewPlanId == Guid.Empty ||
            userId == Guid.Empty ||
            submissionId == Guid.Empty ||
            idempotencyKey == Guid.Empty ||
            string.IsNullOrWhiteSpace(payloadChecksum) ||
            pointIds.Count != updates.Count ||
            updates.Any(update =>
                update.UserId != userId ||
                update.PointId == Guid.Empty ||
                update.Version <= 0 ||
                !double.IsFinite(update.Score) ||
                update.Score is < 0 or > 100 ||
                !double.IsFinite(update.EasinessFactor) ||
                update.EasinessFactor < 1.3 ||
                update.IntervalDays is < 0 or > 3650 ||
                update.Repetitions < 0 ||
                update.Lapses < 0 ||
                string.IsNullOrWhiteSpace(update.Reason));
        if (invalid)
        {
            throw new KnowledgeServiceException(
                422,
                "MASTERY_UPDATE_INVALID",
                "掌握度提交包含空标识、重复知识点或无效版本。");
        }
    }
}
