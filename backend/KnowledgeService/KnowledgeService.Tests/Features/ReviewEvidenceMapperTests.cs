using KnowledgeService.API.Contracts;
using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.Tests.Features;

public sealed class ReviewEvidenceMapperTests
{
    [Fact]
    public void Rejects_every_missing_top_level_required_field()
    {
        var valid = ValidRequest();
        ReviewEvidenceRequest?[] variants =
        [
            null,
            valid with { ResultId = null },
            valid with { IdempotencyKey = null },
            valid with { ReviewPlanId = null },
            valid with { SnapshotVersion = null },
            valid with { SessionId = null },
            valid with { PackageId = null },
            valid with { UserId = null },
            valid with { CompletedAt = null },
            valid with { DurationSeconds = null },
            valid with { AnswerResults = null }
        ];

        Assert.All(
            variants,
            request => AssertPresenceFailure(valid.ResultId!.Value, request));
    }

    [Fact]
    public void Rejects_every_missing_answer_required_field()
    {
        var valid = ValidRequest();
        var answer = Assert.Single(valid.AnswerResults!)!;
        KnowledgeAnswerEvidenceRequest?[] variants =
        [
            null,
            answer with { AttemptId = null },
            answer with { QuestionId = null },
            answer with { KnowledgePointId = null },
            answer with { AnswerKind = null },
            answer with { Correct = null },
            answer with { Quality = null },
            answer with { ResponseTimeMs = null },
            answer with { HintsUsed = null },
            answer with { AttemptNumber = null },
            answer with { OccurredAt = null }
        ];

        Assert.All(
            variants,
            missingAnswer => AssertPresenceFailure(
                valid.ResultId!.Value,
                valid with { AnswerResults = [missingAnswer] }));
    }

    [Fact]
    public void Explicit_false_and_zero_values_are_present_evidence()
    {
        var request = ValidRequest();

        var submission = ReviewEvidenceMapper.Map(
            request.ResultId!.Value,
            request);

        Assert.Equal(0, submission.DurationSeconds);
        var answer = Assert.Single(submission.Answers);
        Assert.False(answer.Correct);
        Assert.Equal(0, answer.Quality);
        Assert.Equal(0, answer.ResponseTimeMilliseconds);
        Assert.Equal(0, answer.HintsUsed);
        Assert.False(answer.UsedHint);
    }

    [Fact]
    public void Range_violations_remain_422_business_errors()
    {
        var valid = ValidRequest();
        var answer = Assert.Single(valid.AnswerResults!)!;
        ReviewEvidenceRequest[] variants =
        [
            valid with { DurationSeconds = -1 },
            valid with
            {
                AnswerResults =
                [
                    answer with { ResponseTimeMs = -1 }
                ]
            },
            valid with
            {
                AnswerResults =
                [
                    answer with { HintsUsed = -1 }
                ]
            },
            valid with
            {
                AnswerResults =
                [
                    answer with { AttemptNumber = 0 }
                ]
            },
            valid with
            {
                AnswerResults =
                [
                    answer with
                    {
                        OccurredAt =
                            valid.CompletedAt!.Value.AddMinutes(6)
                    }
                ]
            }
        ];

        Assert.All(
            variants,
            request =>
            {
                var exception =
                    Assert.Throws<KnowledgeServiceException>(
                        () => ReviewEvidenceMapper.Map(
                            request.ResultId!.Value,
                            request));
                Assert.Equal(422, exception.StatusCode);
                Assert.Equal(
                    "REVIEW_EVIDENCE_INVALID",
                    exception.Code);
            });
    }

    private static void AssertPresenceFailure(
        Guid routeResultId,
        ReviewEvidenceRequest? request)
    {
        var exception = Assert.Throws<KnowledgeServiceException>(
            () => ReviewEvidenceMapper.Map(routeResultId, request));
        Assert.Equal(400, exception.StatusCode);
        Assert.Equal("REVIEW_EVIDENCE_INVALID", exception.Code);
    }

    private static ReviewEvidenceRequest ValidRequest()
    {
        var completedAt =
            DateTimeOffset.Parse("2026-07-31T08:00:00Z");
        return new ReviewEvidenceRequest(
            Guid.Parse("60000000-0000-0000-0000-000000000001"),
            Guid.Parse("60000000-0000-0000-0000-000000000002"),
            Guid.Parse("60000000-0000-0000-0000-000000000003"),
            "snapshot-v1",
            Guid.Parse("60000000-0000-0000-0000-000000000004"),
            Guid.Parse("60000000-0000-0000-0000-000000000005"),
            Guid.Parse("60000000-0000-0000-0000-000000000006"),
            completedAt,
            0,
            [
                new KnowledgeAnswerEvidenceRequest(
                    Guid.Parse(
                        "60000000-0000-0000-0000-000000000007"),
                    Guid.Parse(
                        "60000000-0000-0000-0000-000000000008"),
                    Guid.Parse(
                        "60000000-0000-0000-0000-000000000009"),
                    "CHOICE",
                    false,
                    0,
                    0,
                    0,
                    1,
                    completedAt.AddSeconds(-1))
            ]);
    }
}
