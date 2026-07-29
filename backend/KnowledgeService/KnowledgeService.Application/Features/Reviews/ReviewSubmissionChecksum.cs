using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Application.Features.Reviews;

internal static class ReviewSubmissionChecksum
{
    public static string Compute(ReviewResultSubmission submission)
    {
        var canonical = JsonSerializer.Serialize(new
        {
            submissionId = submission.SubmissionId.ToString("D"),
            idempotencyKey = submission.IdempotencyKey.ToString("D"),
            userId = submission.UserId.ToString("D"),
            reviewPlanId = submission.ReviewPlanId.ToString("D"),
            sessionId = submission.SessionId.ToString("D"),
            packageId = submission.PackageId.ToString("D"),
            submission.SnapshotVersion,
            completedAt = submission.CompletedAt
                .ToUniversalTime()
                .ToString("O"),
            submission.DurationSeconds,
            answers = submission.Answers
                .OrderBy(answer => answer.KnowledgePointId)
                .ThenBy(answer => answer.AttemptId, StringComparer.Ordinal)
                .ThenBy(answer => answer.QuestionId)
                .Select(answer => new
                {
                    knowledgePointId =
                        answer.KnowledgePointId.ToString("D"),
                    answer.AttemptId,
                    questionId = answer.QuestionId.ToString("D"),
                    answer.AnswerKind,
                    answer.Correct,
                    answer.Quality,
                    answer.DurationSeconds,
                    answer.ResponseTimeMilliseconds,
                    answer.UsedHint,
                    answer.HintsUsed,
                    answer.AttemptNumber,
                    occurredAt = answer.OccurredAt?
                        .ToUniversalTime()
                        .ToString("O")
                })
                .ToArray()
        });
        return Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))
            .ToLowerInvariant();
    }
}
