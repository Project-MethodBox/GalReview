using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.Domain.Builds;

public sealed record GraphBuildJob(
    Guid BuildId,
    Guid MaterialId,
    Guid OwnerUserId,
    GraphBuildStatus Status,
    int Progress,
    Guid? GraphId,
    string? SourceTextChecksum,
    string? SubjectHint,
    SegmentationOptions Segmentation,
    string ExtractorVersion,
    string IdempotencyKey,
    string? ErrorCode,
    string? ErrorMessage,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);
