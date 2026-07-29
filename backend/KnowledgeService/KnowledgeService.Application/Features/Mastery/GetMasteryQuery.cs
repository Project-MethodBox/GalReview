using KnowledgeService.Domain.Mastery;
using MediatR;

namespace KnowledgeService.Application.Features.Mastery;

public sealed record GetMasteryQuery(
    Guid GraphId,
    Guid OwnerUserId) : IRequest<IReadOnlyDictionary<Guid, MasteryState>>;
