using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Planning;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Reviews;
using MediatR;

namespace KnowledgeService.Application.Features.Reviews;

public sealed class CreateAssessmentPlanCommandHandler
    : IRequestHandler<CreateAssessmentPlanCommand, ReviewPlanGraph>
{
    private readonly IKnowledgeRepository _repository;
    private readonly AssessmentPlanner _planner;
    private readonly ISystemClock _clock;

    public CreateAssessmentPlanCommandHandler(
        IKnowledgeRepository repository,
        AssessmentPlanner planner,
        ISystemClock clock)
    {
        _repository = repository;
        _planner = planner;
        _clock = clock;
    }

    public async Task<ReviewPlanGraph> Handle(
        CreateAssessmentPlanCommand request,
        CancellationToken cancellationToken)
    {
        var graph = await _repository.GetGraphAsync(
            request.GraphId,
            request.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "KNOWLEDGE_GRAPH_NOT_FOUND",
                "知识图谱不存在。");
        var mastery = await _repository.GetMasteryAsync(
            graph.GraphId,
            request.OwnerUserId,
            cancellationToken);
        var plan = _planner.Create(
            graph,
            mastery,
            request.Options,
            _clock.UtcNow);
        await _repository.SaveReviewPlanAsync(plan, cancellationToken);
        return plan;
    }
}
