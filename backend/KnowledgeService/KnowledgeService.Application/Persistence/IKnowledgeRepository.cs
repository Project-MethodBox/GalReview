using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Persistence;

public interface IKnowledgeRepository
{
    Task InitializeSchemaAsync(CancellationToken cancellationToken);

    Task<bool> IsReadyAsync(CancellationToken cancellationToken);

    Task<(GraphBuildJob Job, bool Created)> CreateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken);

    Task<GraphBuildJob?> GetBuildJobAsync(
        Guid buildId,
        Guid? ownerUserId,
        CancellationToken cancellationToken);

    Task UpdateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken);

    Task<KnowledgeGraph> SaveGraphAsync(
        KnowledgeGraph graph,
        Guid buildId,
        CancellationToken cancellationToken);

    Task<KnowledgeGraph?> GetGraphAsync(
        Guid graphId,
        Guid? ownerUserId,
        CancellationToken cancellationToken);

    Task<KnowledgePoint?> GetPointAsync(
        Guid pointId,
        Guid ownerUserId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<KnowledgeGraphSummary>> ListGraphsAsync(
        Guid materialId,
        Guid ownerUserId,
        CancellationToken cancellationToken);

    Task<IReadOnlyDictionary<Guid, MasteryState>> GetMasteryAsync(
        Guid graphId,
        Guid userId,
        CancellationToken cancellationToken);

    Task SaveReviewPlanAsync(
        ReviewPlanGraph plan,
        CancellationToken cancellationToken);

    Task<ReviewPlanGraph?> GetReviewPlanAsync(
        Guid reviewPlanId,
        Guid? ownerUserId,
        CancellationToken cancellationToken);

    Task<bool> IsReviewSubmissionDuplicateAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        CancellationToken cancellationToken);

    /// <summary>
    /// Applies every mastery update and records the submission in one transaction.
    /// Returns true when the submission was already applied.
    /// </summary>
    Task<bool> ApplyMasteryUpdatesAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        IReadOnlyList<MasteryState> updates,
        CancellationToken cancellationToken);
}
