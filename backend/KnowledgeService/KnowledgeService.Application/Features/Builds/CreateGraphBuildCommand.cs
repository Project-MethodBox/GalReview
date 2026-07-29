using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Segmentation;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed record CreateGraphBuildCommand(
    Guid MaterialId,
    Guid OwnerUserId,
    string? SubjectHint,
    SegmentationOptions Segmentation,
    string? ExtractorVersion,
    string IdempotencyKey) : IRequest<GraphBuildJobCreation>;
