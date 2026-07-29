using KnowledgeService.Domain.Builds;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed record ProcessGraphBuildCommand(
    Guid BuildId,
    string CorrelationId) : IRequest<GraphBuildJob>;
