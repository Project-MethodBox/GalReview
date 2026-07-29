using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Mastery;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed class SubmitReviewResultCommandHandler
    : IRequestHandler<SubmitReviewResultCommand, ReviewResultReceipt>
{
    private readonly IKnowledgeRepository _repository;
    private readonly MasteryEvidenceUpdater _updater;
    private readonly ISystemClock _clock;

    public SubmitReviewResultCommandHandler(
        IKnowledgeRepository repository,
        MasteryEvidenceUpdater updater,
        ISystemClock clock)
    {
        _repository = repository;
        _updater = updater;
        _clock = clock;
    }

    public async Task<ReviewResultReceipt> Handle(
        SubmitReviewResultCommand request,
        CancellationToken cancellationToken)
    {
        var plan = await _repository.GetReviewPlanAsync(
            request.ReviewPlanId,
            null,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "REVIEW_PLAN_NOT_FOUND",
                "复习计划不存在。");
        if (request.Submission.UserId != plan.OwnerUserId)
        {
            throw new KnowledgeServiceException(
                422,
                "REVIEW_EVIDENCE_USER_MISMATCH",
                "结果中的 userId 与计划所有者不一致。");
        }

        var payloadChecksum = ReviewSubmissionChecksum.Compute(
            request.Submission);
        var duplicate = await _repository.IsReviewSubmissionDuplicateAsync(
            plan.ReviewPlanId,
            plan.OwnerUserId,
            request.Submission.SubmissionId,
            request.Submission.IdempotencyKey,
            payloadChecksum,
            cancellationToken);
        if (duplicate)
        {
            return new ReviewResultReceipt(
                request.Submission.SubmissionId,
                plan.ReviewPlanId,
                true,
                Array.Empty<AppliedMasteryChange>(),
                _clock.UtcNow);
        }

        var graph = await _repository.GetGraphAsync(
            plan.GraphId,
            plan.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                409,
                "PLAN_GRAPH_SNAPSHOT_MISSING",
                "复习计划绑定的知识图谱快照不存在。");
        var mastery = await _repository.GetMasteryAsync(
            graph.GraphId,
            plan.OwnerUserId,
            cancellationToken);
        var now = _clock.UtcNow;
        var batch = _updater.Calculate(
            plan,
            graph,
            mastery,
            request.Submission,
            now);

        try
        {
            duplicate = await _repository.ApplyMasteryUpdatesAsync(
                plan.ReviewPlanId,
                plan.OwnerUserId,
                request.Submission.SubmissionId,
                request.Submission.IdempotencyKey,
                payloadChecksum,
                batch.States,
                cancellationToken);
            return new ReviewResultReceipt(
                request.Submission.SubmissionId,
                plan.ReviewPlanId,
                duplicate,
                duplicate ? Array.Empty<AppliedMasteryChange>() : batch.Changes,
                now);
        }
        catch (MasteryConcurrencyException exception)
        {
            throw new KnowledgeServiceException(
                409,
                "MASTERY_VERSION_CONFLICT",
                "掌握度已被其它结果更新，请重试。",
                innerException: exception);
        }
    }
}
