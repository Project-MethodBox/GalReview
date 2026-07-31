using KnowledgeService.API.Contracts;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.API.Infrastructure;

internal static class ReviewEvidenceMapper
{
    private static readonly HashSet<string> AnswerKinds =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "CHOICE",
            "FILL_BLANK",
            "TRUE_FALSE",
            "SHORT_ANSWER",
            "OTHER"
        };

    public static ReviewResultSubmission Map(
        Guid routeResultId,
        ReviewEvidenceRequest? request)
    {
        if (!HasRequiredFields(request))
        {
            throw Invalid(
                "复习结果缺少契约要求的标识、快照、完成时间、时长或答案字段。");
        }

        var resultId = request!.ResultId!.Value;
        var idempotencyKey = request.IdempotencyKey!.Value;
        var reviewPlanId = request.ReviewPlanId!.Value;
        var sessionId = request.SessionId!.Value;
        var packageId = request.PackageId!.Value;
        var userId = request.UserId!.Value;
        var completedAt = request.CompletedAt!.Value;
        var durationSeconds = request.DurationSeconds!.Value;
        var answers = request.AnswerResults!
            .Select(answer => answer!)
            .ToArray();

        if (routeResultId != resultId)
        {
            throw Invalid("路由 resultId 与请求体不一致。");
        }

        if (resultId == Guid.Empty ||
            idempotencyKey == Guid.Empty ||
            reviewPlanId == Guid.Empty ||
            sessionId == Guid.Empty ||
            packageId == Guid.Empty ||
            userId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.SnapshotVersion) ||
            answers.Length is < 1 or > 100)
        {
            throw Invalid("复习结果的标识、快照或答案数量无效。");
        }

        if (answers.Any(answer =>
                answer.AttemptId!.Value == Guid.Empty ||
                answer.QuestionId!.Value == Guid.Empty ||
                answer.KnowledgePointId!.Value == Guid.Empty ||
                !AnswerKinds.Contains(answer.AnswerKind ?? string.Empty) ||
                string.IsNullOrWhiteSpace(answer.AnswerKind)))
        {
            throw Invalid("答案证据的标识或类型无效。");
        }

        if (durationSeconds is < 0 or > 86_400 ||
            answers.Any(answer =>
                answer.ResponseTimeMs!.Value is < 0 or > 86_400_000 ||
                answer.HintsUsed!.Value is < 0 or > 100 ||
                answer.AttemptNumber!.Value is < 1 or > 100 ||
                answer.OccurredAt!.Value > completedAt.AddMinutes(5)))
        {
            throw BusinessInvalid(
                "复习时长、答案耗时、提示次数、尝试次数或发生时间超出允许范围。");
        }

        return new ReviewResultSubmission(
            resultId,
            idempotencyKey,
            userId,
            request.SnapshotVersion!,
            answers
                .Select(answer => new ReviewAnswer(
                    answer.KnowledgePointId!.Value,
                    answer.AttemptId!.Value.ToString("D"),
                    answer.Correct!.Value,
                    answer.Quality!.Value,
                    checked((int)(
                        answer.ResponseTimeMs!.Value / 1000)),
                    answer.HintsUsed!.Value > 0,
                    answer.QuestionId!.Value,
                    answer.AnswerKind!.Trim().ToUpperInvariant(),
                    answer.ResponseTimeMs.Value,
                    answer.HintsUsed.Value,
                    answer.AttemptNumber!.Value,
                    answer.OccurredAt!.Value))
                .ToArray(),
            completedAt,
            reviewPlanId,
            sessionId,
            packageId,
            durationSeconds);
    }

    private static bool HasRequiredFields(ReviewEvidenceRequest? request) =>
        request is not null &&
        request.ResultId.HasValue &&
        request.IdempotencyKey.HasValue &&
        request.ReviewPlanId.HasValue &&
        request.SnapshotVersion is not null &&
        request.SessionId.HasValue &&
        request.PackageId.HasValue &&
        request.UserId.HasValue &&
        request.CompletedAt.HasValue &&
        request.DurationSeconds.HasValue &&
        request.AnswerResults is not null &&
        request.AnswerResults.All(answer =>
            answer is not null &&
            answer.AttemptId.HasValue &&
            answer.QuestionId.HasValue &&
            answer.KnowledgePointId.HasValue &&
            answer.AnswerKind is not null &&
            answer.Correct.HasValue &&
            answer.Quality.HasValue &&
            answer.ResponseTimeMs.HasValue &&
            answer.HintsUsed.HasValue &&
            answer.AttemptNumber.HasValue &&
            answer.OccurredAt.HasValue);

    private static KnowledgeServiceException Invalid(string message) =>
        new(
            400,
            "REVIEW_EVIDENCE_INVALID",
            message);

    private static KnowledgeServiceException BusinessInvalid(
        string message) =>
        new(
            422,
            "REVIEW_EVIDENCE_INVALID",
            message);
}
