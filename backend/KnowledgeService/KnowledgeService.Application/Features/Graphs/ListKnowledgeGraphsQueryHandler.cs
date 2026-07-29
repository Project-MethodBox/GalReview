using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed class ListKnowledgeGraphsQueryHandler
    : IRequestHandler<ListKnowledgeGraphsQuery, IReadOnlyList<KnowledgeGraphSummary>>
{
    private readonly IKnowledgeRepository _repository;

    public ListKnowledgeGraphsQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public Task<IReadOnlyList<KnowledgeGraphSummary>> Handle(
        ListKnowledgeGraphsQuery request,
        CancellationToken cancellationToken) =>
        _repository.ListGraphsAsync(
            request.MaterialId,
            request.OwnerUserId,
            cancellationToken);
}
