using MediatR;

namespace KnowledgeService.Application.Features.Health;

public sealed record GetReadinessQuery : IRequest<bool>;
