using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Common;
using KnowledgeService.Domain.Segmentation;
using MediatR;

namespace KnowledgeService.Application.Features.Builds;

public sealed partial class CreateGraphBuildCommandHandler
    : IRequestHandler<CreateGraphBuildCommand, GraphBuildJobCreation>
{
    private readonly IKnowledgeRepository _repository;
    private readonly ISystemClock _clock;

    public CreateGraphBuildCommandHandler(
        IKnowledgeRepository repository,
        ISystemClock clock)
    {
        _repository = repository;
        _clock = clock;
    }

    public async Task<GraphBuildJobCreation> Handle(
        CreateGraphBuildCommand request,
        CancellationToken cancellationToken)
    {
        var subject = SubjectCodePolicy.NormalizeOptional(
            request.SubjectHint);
        var idempotencyKey = ValidateAndNormalize(request, subject);
        var now = _clock.UtcNow;
        var extractorVersion = string.IsNullOrWhiteSpace(request.ExtractorVersion)
            ? KnowledgeAlgorithmVersions.Extractor
            : request.ExtractorVersion.Trim();
        var candidate = new GraphBuildJob(
            Guid.NewGuid(),
            request.MaterialId,
            request.OwnerUserId,
            GraphBuildStatus.Queued,
            0,
            null,
            null,
            subject,
            request.Segmentation,
            extractorVersion,
            idempotencyKey,
            null,
            null,
            now,
            now);
        var result = await _repository.CreateBuildJobAsync(
            candidate,
            cancellationToken);

        if (!result.Created &&
            (result.Job.MaterialId != candidate.MaterialId ||
             result.Job.OwnerUserId != candidate.OwnerUserId ||
             result.Job.ExtractorVersion != candidate.ExtractorVersion ||
             result.Job.Segmentation != candidate.Segmentation ||
             result.Job.SubjectHint != candidate.SubjectHint))
        {
            throw new KnowledgeServiceException(
                409,
                "IDEMPOTENCY_KEY_REUSED",
                "Idempotency-Key 已用于不同的图谱构建请求。");
        }

        return new GraphBuildJobCreation(result.Job, result.Created);
    }

    private static string ValidateAndNormalize(
        CreateGraphBuildCommand request,
        string? normalizedSubject)
    {
        if (request.MaterialId == Guid.Empty ||
            request.OwnerUserId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.IdempotencyKey) ||
            !Guid.TryParseExact(
                request.IdempotencyKey.Trim(),
                "D",
                out var parsedIdempotencyKey) ||
            parsedIdempotencyKey == Guid.Empty)
        {
            throw new KnowledgeServiceException(
                400,
                "GRAPH_BUILD_REQUEST_INVALID",
                "materialId、用户身份无效，或 Idempotency-Key 不是非空 UUID D 格式。");
        }

        if (normalizedSubject is not null &&
            !SubjectCodePolicy.IsValid(normalizedSubject))
        {
            throw new KnowledgeServiceException(
                400,
                "SUBJECT_CODE_INVALID",
                "subjectHint 规范化后必须为 1-32 位大写字母开头的字母、数字或下划线。");
        }

        if (!Enum.IsDefined(request.Segmentation.Mode))
        {
            throw new KnowledgeServiceException(
                400,
                "SEGMENTATION_MODE_INVALID",
                "segmentationMode 不是受支持的契约枚举值。");
        }

        // 契约要求切分参数越界与 DELIMITER 缺分隔符在 POST 同步返回 400；此前它们
        // 被推迟到后台切分器，客户端会先拿到 202 再轮询到 FAILED（与同请求内的
        // 枚举校验行为自相矛盾）。后台的同名校验保留为防御层。
        if (request.Segmentation.MinChapterCharacters is < 20 or > 20_000 ||
            request.Segmentation.MaxChapterCharacters is < 500 or > 500_000 ||
            request.Segmentation.FixedWindowCharacters is < 500 or > 100_000 ||
            request.Segmentation.MinChapterCharacters >
                request.Segmentation.MaxChapterCharacters)
        {
            throw new KnowledgeServiceException(
                400,
                "SEGMENTATION_OPTIONS_INVALID",
                "章节分割参数超出允许范围。");
        }

        // 判定与 ChapterSegmenter.SegmentByDelimiter 完全一致（含空白串），
        // 避免同一输入在两层得到不同结论
        if (request.Segmentation.Mode == SegmentationMode.Delimiter &&
            string.IsNullOrWhiteSpace(request.Segmentation.Delimiter))
        {
            throw new KnowledgeServiceException(
                400,
                "SEGMENTATION_DELIMITER_REQUIRED",
                "DELIMITER 模式必须提供非空 delimiter。");
        }

        if (!string.IsNullOrWhiteSpace(request.ExtractorVersion) &&
            !string.Equals(
                request.ExtractorVersion.Trim(),
                KnowledgeAlgorithmVersions.Extractor,
                StringComparison.Ordinal))
        {
            throw new KnowledgeServiceException(
                422,
                "EXTRACTOR_VERSION_UNSUPPORTED",
                $"当前只支持 {KnowledgeAlgorithmVersions.Extractor}。");
        }

        return parsedIdempotencyKey.ToString("D");
    }
}
