using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed record GetReviewPlanQuery(
    Guid ReviewPlanId,
    Guid? OwnerUserId) : IRequest<ReviewPlanGraph>;
