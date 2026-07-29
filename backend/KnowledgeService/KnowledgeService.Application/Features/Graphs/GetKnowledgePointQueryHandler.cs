using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed class GetKnowledgePointQueryHandler
    : IRequestHandler<GetKnowledgePointQuery, KnowledgePoint>
{
    private readonly IKnowledgeRepository _repository;

    public GetKnowledgePointQueryHandler(IKnowledgeRepository repository)
    {
        _repository = repository;
    }

    public async Task<KnowledgePoint> Handle(
        GetKnowledgePointQuery request,
        CancellationToken cancellationToken) =>
        await _repository.GetPointAsync(
            request.PointId,
            request.OwnerUserId,
            cancellationToken) ?? throw new KnowledgeServiceException(
                404,
                "KNOWLEDGE_POINT_NOT_FOUND",
                "知识点不存在。");
}
