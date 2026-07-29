using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed record GetKnowledgeGraphQuery(
    Guid GraphId,
    Guid? OwnerUserId) : IRequest<KnowledgeGraph>;
