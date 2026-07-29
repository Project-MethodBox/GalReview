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
        ReviewEvidenceRequest request)
    {
        if (routeResultId != request.ResultId)
        {
            throw Invalid("路由 resultId 与请求体不一致。");
        }

        if (request.ResultId == Guid.Empty ||
            request.IdempotencyKey == Guid.Empty ||
            request.ReviewPlanId == Guid.Empty ||
            request.SessionId == Guid.Empty ||
            request.PackageId == Guid.Empty ||
            request.UserId == Guid.Empty ||
            string.IsNullOrWhiteSpace(request.SnapshotVersion) ||
            request.DurationSeconds is < 0 or > 86_400 ||
            request.AnswerResults is null ||
            request.AnswerResults.Count is < 1 or > 100)
        {
            throw Invalid("复习结果的标识、时长、快照或答案数量无效。");
        }

        if (request.AnswerResults.Any(answer =>
                answer.AttemptId == Guid.Empty ||
                answer.QuestionId == Guid.Empty ||
                answer.KnowledgePointId == Guid.Empty ||
                !AnswerKinds.Contains(answer.AnswerKind ?? string.Empty) ||
                answer.ResponseTimeMs is < 0 or > 86_400_000 ||
                answer.HintsUsed is < 0 or > 100 ||
                answer.AttemptNumber is < 1 or > 100 ||
                answer.OccurredAt > request.CompletedAt.AddMinutes(5)))
        {
            throw Invalid("答案证据的标识、类型、耗时、提示次数或发生时间无效。");
        }

        return new ReviewResultSubmission(
            request.ResultId,
            request.IdempotencyKey,
            request.UserId,
            request.SnapshotVersion,
            request.AnswerResults
                .Select(answer => new ReviewAnswer(
                    answer.KnowledgePointId,
                    answer.AttemptId.ToString("D"),
                    answer.Correct,
                    answer.Quality,
                    checked((int)(answer.ResponseTimeMs / 1000)),
                    answer.HintsUsed > 0,
                    answer.QuestionId,
                    answer.AnswerKind.Trim().ToUpperInvariant(),
                    answer.ResponseTimeMs,
                    answer.HintsUsed,
                    answer.AttemptNumber,
                    answer.OccurredAt))
                .ToArray(),
            request.CompletedAt,
            request.ReviewPlanId,
            request.SessionId,
            request.PackageId,
            request.DurationSeconds);
    }

    private static KnowledgeServiceException Invalid(string message) =>
        new(
            400,
            "REVIEW_EVIDENCE_INVALID",
            message);
}
