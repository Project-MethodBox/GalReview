using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed record ListKnowledgeGraphsQuery(
    Guid MaterialId,
    Guid OwnerUserId) : IRequest<IReadOnlyList<KnowledgeGraphSummary>>;
