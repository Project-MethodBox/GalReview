using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed record CreateLearningPlanCommand(
    Guid GraphId,
    Guid OwnerUserId,
    LearningPlanOptions Options) : IRequest<ReviewPlanGraph>;
