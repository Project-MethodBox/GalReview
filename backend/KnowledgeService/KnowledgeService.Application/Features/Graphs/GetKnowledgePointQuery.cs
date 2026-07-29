using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed record GetKnowledgePointQuery(
    Guid PointId,
    Guid OwnerUserId) : IRequest<KnowledgePoint>;
