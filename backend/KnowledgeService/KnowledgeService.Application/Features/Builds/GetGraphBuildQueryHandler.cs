using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Builds;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed class GetGraphBuildQueryHandler
    : IRequestHandler<GetGraphBuildQuery, GraphBuildJob>
{
    private readonly IKnowledgeRepository _repository;

    public GetGraphBuildQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public async Task<GraphBuildJob> Handle(
        GetGraphBuildQuery request,
        CancellationToken cancellationToken) =>
        await _repository.GetBuildJobAsync(
            request.BuildId,
            request.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "GRAPH_BUILD_NOT_FOUND",
                "图谱构建任务不存在。");
}
