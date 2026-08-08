using KnowledgeService.Domain.Segmentation;

namespace KnowledgeService.API.Contracts;

public sealed record GraphBuildRequest(
    Guid MaterialId,
    Guid StudyProjectId,
    string? SubjectHint,
    SegmentationMode? SegmentationMode,
    string? Delimiter,
    int? MinChapterCharacters,
    int? MaxChapterCharacters,
    int? FixedWindowCharacters,
    string? ExtractorVersion);
