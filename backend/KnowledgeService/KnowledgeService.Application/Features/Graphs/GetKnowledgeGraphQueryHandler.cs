using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed class GetKnowledgeGraphQueryHandler
    : IRequestHandler<GetKnowledgeGraphQuery, KnowledgeGraph>
{
    private readonly IKnowledgeRepository _repository;

    public GetKnowledgeGraphQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public async Task<KnowledgeGraph> Handle(
        GetKnowledgeGraphQuery request,
        CancellationToken cancellationToken) =>
        await _repository.GetGraphAsync(
            request.GraphId,
            request.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "KNOWLEDGE_GRAPH_NOT_FOUND",
                "知识图谱不存在。");
}
