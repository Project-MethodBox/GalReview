using KnowledgeService.Domain.Builds;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed record GetGraphBuildQuery(
    Guid BuildId,
    Guid OwnerUserId) : IRequest<GraphBuildJob>;
