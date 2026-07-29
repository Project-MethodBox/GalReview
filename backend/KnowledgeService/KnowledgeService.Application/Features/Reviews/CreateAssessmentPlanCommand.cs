using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed record CreateAssessmentPlanCommand(
    Guid GraphId,
    Guid OwnerUserId,
    AssessmentPlanOptions Options) : IRequest<ReviewPlanGraph>;
