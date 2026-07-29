using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Mastery;
using MediatR;

namespace KnowledgeService.Application.Features.Mastery;

public sealed class GetMasteryQueryHandler
    : IRequestHandler<GetMasteryQuery, IReadOnlyDictionary<Guid, MasteryState>>
{
    private readonly IKnowledgeRepository _repository;

    public GetMasteryQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public Task<IReadOnlyDictionary<Guid, MasteryState>> Handle(
        GetMasteryQuery request,
        CancellationToken cancellationToken) =>
        _repository.GetMasteryAsync(
            request.GraphId,
            request.OwnerUserId,
            cancellationToken);
}
