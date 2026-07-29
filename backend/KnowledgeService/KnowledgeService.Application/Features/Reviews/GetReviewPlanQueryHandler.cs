using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed class GetReviewPlanQueryHandler
    : IRequestHandler<GetReviewPlanQuery, ReviewPlanGraph>
{
    private readonly IKnowledgeRepository _repository;

    public GetReviewPlanQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public async Task<ReviewPlanGraph> Handle(
        GetReviewPlanQuery request,
        CancellationToken cancellationToken) =>
        await _repository.GetReviewPlanAsync(
            request.ReviewPlanId,
            request.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "REVIEW_PLAN_NOT_FOUND",
                "复习计划不存在。");
}
