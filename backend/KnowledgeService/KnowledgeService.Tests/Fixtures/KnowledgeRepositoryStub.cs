using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Graphs;
using KnowledgeService.Domain.Mastery;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Tests.Fixtures;

internal sealed class KnowledgeRepositoryStub : IKnowledgeRepository
{
    public required Func<
        GraphBuildJob,
        (GraphBuildJob Job, bool Created)> CreateBuildJob { get; init; }

    public Task<(GraphBuildJob Job, bool Created)> CreateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(CreateBuildJob(job));
    }

    public Task InitializeSchemaAsync(CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<bool> IsReadyAsync(CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<GraphBuildJob?> GetBuildJobAsync(
        Guid buildId,
        Guid? ownerUserId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task UpdateBuildJobAsync(
        GraphBuildJob job,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<IReadOnlyList<GraphBuildJob>> ListUnfinishedBuildJobsAsync(
        int limit,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<KnowledgeGraph> SaveGraphAsync(
        KnowledgeGraph graph,
        Guid buildId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<KnowledgeGraph?> GetGraphAsync(
        Guid graphId,
        Guid? ownerUserId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<KnowledgePoint?> GetPointAsync(
        Guid pointId,
        Guid ownerUserId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<IReadOnlyList<KnowledgeGraphSummary>> ListGraphsAsync(
        Guid materialId,
        Guid ownerUserId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<IReadOnlyDictionary<Guid, MasteryState>> GetMasteryAsync(
        Guid graphId,
        Guid userId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task SaveReviewPlanAsync(
        ReviewPlanGraph plan,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<ReviewPlanGraph?> GetReviewPlanAsync(
        Guid reviewPlanId,
        Guid? ownerUserId,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<bool> IsReviewSubmissionDuplicateAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<bool> ApplyMasteryUpdatesAsync(
        Guid reviewPlanId,
        Guid userId,
        Guid submissionId,
        Guid idempotencyKey,
        string payloadChecksum,
        IReadOnlyList<MasteryState> updates,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException();
}
