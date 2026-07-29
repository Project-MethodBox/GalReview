using KnowledgeService.Application.Features.Reviews;
using KnowledgeService.Domain.Reviews;

namespace KnowledgeService.Tests.Features;

public sealed class ReviewSubmissionChecksumTests
{
    [Fact]
    public void Canonical_checksum_ignores_answer_order_and_time_offset()
    {
        var submissionId = Guid.NewGuid();
        var idempotencyKey = Guid.NewGuid();
        var userId = Guid.NewGuid();
        var first = Answer(1, quality: 5);
        var second = Answer(2, quality: 4);
        var completedAt =
            DateTimeOffset.Parse("2026-07-29T08:00:00+08:00");
        var left = new ReviewResultSubmission(
            submissionId,
            idempotencyKey,
            userId,
            "snapshot",
            new[] { first, second },
            completedAt);
        var right = left with
        {
            Answers = new[] { second, first },
            CompletedAt = completedAt.ToUniversalTime()
        };

        Assert.Equal(
            ReviewSubmissionChecksum.Compute(left),
            ReviewSubmissionChecksum.Compute(right));
    }

    [Fact]
    public void Canonical_checksum_changes_when_mastery_evidence_changes()
    {
        var submission = new ReviewResultSubmission(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            "snapshot",
            new[] { Answer(1, quality: 4) },
            DateTimeOffset.Parse("2026-07-29T00:00:00Z"));
        var changed = submission with
        {
            Answers = new[] { Answer(1, quality: 5) }
        };

        Assert.NotEqual(
            ReviewSubmissionChecksum.Compute(submission),
            ReviewSubmissionChecksum.Compute(changed));
    }

    [Fact]
    public void Canonical_checksum_covers_session_package_and_question_evidence()
    {
        var occurredAt =
            DateTimeOffset.Parse("2026-07-29T00:01:00Z");
        var submission = new ReviewResultSubmission(
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            "snapshot",
            new[]
            {
                Answer(1, quality: 4) with
                {
                    QuestionId = Guid.NewGuid(),
                    AnswerKind = "SHORT_ANSWER",
                    ResponseTimeMilliseconds = 1_234,
                    HintsUsed = 0,
                    AttemptNumber = 1,
                    OccurredAt = occurredAt
                }
            },
            DateTimeOffset.Parse("2026-07-29T00:02:00Z"),
            Guid.NewGuid(),
            Guid.NewGuid(),
            Guid.NewGuid(),
            120);

        var variants = new[]
        {
            submission with { ReviewPlanId = Guid.NewGuid() },
            submission with { SessionId = Guid.NewGuid() },
            submission with { PackageId = Guid.NewGuid() },
            submission with { DurationSeconds = 121 },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with { QuestionId = Guid.NewGuid() }).ToArray()
            },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with { AnswerKind = "CHOICE" }).ToArray()
            },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with
                    {
                        ResponseTimeMilliseconds =
                            answer.ResponseTimeMilliseconds + 1
                    }).ToArray()
            },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with { HintsUsed = 1 }).ToArray()
            },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with { AttemptNumber = 2 }).ToArray()
            },
            submission with
            {
                Answers = submission.Answers.Select(answer =>
                    answer with
                    {
                        OccurredAt =
                            answer.OccurredAt?.AddMilliseconds(1)
                    }).ToArray()
            }
        };
        var checksum = ReviewSubmissionChecksum.Compute(submission);

        Assert.All(
            variants,
            variant => Assert.NotEqual(
                checksum,
                ReviewSubmissionChecksum.Compute(variant)));
    }

    private static ReviewAnswer Answer(int suffix, int quality) =>
        new(
            Guid.Parse($"50000000-0000-0000-0000-{suffix:D12}"),
            $"attempt-{suffix}",
            true,
            quality,
            10,
            false);
}
