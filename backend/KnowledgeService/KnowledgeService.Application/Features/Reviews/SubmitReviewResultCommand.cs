using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed record SubmitReviewResultCommand(
    Guid ReviewPlanId,
    ReviewResultSubmission Submission) : IRequest<ReviewResultReceipt>;
