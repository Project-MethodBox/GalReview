using KnowledgeService.Application.Mastery;
using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.Tests.Mastery;

public sealed class Sm2SchedulerTests
{
    [Fact]
    public void Apply_uses_the_submitted_quality_without_hint_downgrade()
    {
        var now = DateTimeOffset.Parse("2026-07-29T08:00:00Z");
        var current = MasteryState.Initial(
            Guid.NewGuid(),
            Guid.NewGuid(),
            now.AddDays(-1));

        var updated = Sm2Scheduler.Apply(
            current,
            quality: 5,
            correct: true,
            usedHint: true,
            now,
            purpose: "ASSESSMENT");

        Assert.Equal(100, updated.Score);
        Assert.Equal(2.6, updated.EasinessFactor);
        Assert.Equal("DIRECT:ASSESSMENT:quality=5", updated.Reason);
    }

    [Fact]
    public void Apply_replaces_the_display_score_with_the_latest_observation_instead_of_mixing_weights()
    {
        var now = DateTimeOffset.Parse("2026-07-29T08:00:00Z");
        var current = MasteryState.Initial(Guid.NewGuid(), Guid.NewGuid(), now.AddDays(-1)) with
        {
            Score = 100,
            Repetitions = 2,
            IntervalDays = 6,
            NextReviewAt = now,
            LastReviewedAt = now.AddDays(-6)
        };

        var updated = Sm2Scheduler.Apply(current, quality: 3, correct: true, usedHint: false, now, "ASSESSMENT");

        Assert.Equal(60, updated.Score);
        Assert.Equal(3, updated.Repetitions);
    }
}
