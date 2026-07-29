using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.API.Contracts;

public sealed record GraphBuildJobResponse(
    Guid BuildId,
    Guid MaterialId,
    GraphBuildStatus Status,
    int Progress,
    Guid? GraphId,
    string? SourceTextChecksum,
    SegmentationMode SegmentationMode,
    string SegmenterVersion,
    string ExtractorVersion,
    ApiError? Error,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static GraphBuildJobResponse From(GraphBuildJob job) =>
        new(
            job.BuildId,
            job.MaterialId,
            job.Status,
            job.Progress,
            job.GraphId,
            job.SourceTextChecksum,
            job.Segmentation.Mode,
            KnowledgeAlgorithmVersions.Segmenter,
            job.ExtractorVersion,
            job.ErrorCode is null
                ? null
                : new ApiError(
                    job.ErrorCode,
                    job.ErrorMessage ?? "图谱构建失败。",
                    new Dictionary<string, object?>()),
            job.CreatedAt,
            job.UpdatedAt);
}
