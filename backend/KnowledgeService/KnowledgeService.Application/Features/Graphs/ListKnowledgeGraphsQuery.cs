using KnowledgeService.Domain.Graphs;
using MediatR;

namespace KnowledgeService.Application.Features.Graphs;

public sealed record ListKnowledgeGraphsQuery(
    Guid StudyProjectId,
    Guid OwnerUserId) : IRequest<IReadOnlyList<KnowledgeGraphSummary>>;
