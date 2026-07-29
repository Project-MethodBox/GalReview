using KnowledgeService.Application.Persistence;
using MediatR;

namespace KnowledgeService.Application.Features.Health;

public sealed class GetReadinessQueryHandler
    : IRequestHandler<GetReadinessQuery, bool>
{
    private readonly IKnowledgeRepository _repository;

    public GetReadinessQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public Task<bool> Handle(
        GetReadinessQuery request,
        CancellationToken cancellationToken) =>
        _repository.IsReadyAsync(cancellationToken);
}
