using System.Text.RegularExpressions;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Application.Time;
using KnowledgeService.Domain.Builds;
using KnowledgeService.Domain.Common;
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
        Validate(request);
        var now = _clock.UtcNow;
        var subject = string.IsNullOrWhiteSpace(request.SubjectHint)
            ? null
            : request.SubjectHint.Trim().ToUpperInvariant();
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
            request.IdempotencyKey.Trim(),
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

    private static void Validate(CreateGraphBuildCommand request)
    {
        if (request.MaterialId == Guid.Empty ||
            request.OwnerUserId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.IdempotencyKey) ||
            request.IdempotencyKey.Trim().Length is < 8 or > 128)
        {
            throw new KnowledgeServiceException(
                400,
                "GRAPH_BUILD_REQUEST_INVALID",
                "materialId、用户身份或 Idempotency-Key 无效。");
        }

        if (!string.IsNullOrWhiteSpace(request.SubjectHint) &&
            !SubjectCodeRegex().IsMatch(request.SubjectHint.Trim()))
        {
            throw new KnowledgeServiceException(
                400,
                "SUBJECT_CODE_INVALID",
                "subjectHint 必须为 1-32 位字母开头的大写字母、数字、下划线或连字符。");
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
    }

    [GeneratedRegex(
        @"^[A-Za-z][A-Za-z0-9_-]{0,31}$",
        RegexOptions.CultureInvariant)]
    private static partial Regex SubjectCodeRegex();
}
