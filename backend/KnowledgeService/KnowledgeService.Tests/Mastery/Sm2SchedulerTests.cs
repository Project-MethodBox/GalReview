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

        Assert.Equal(35, updated.Score);
        Assert.Equal(2.6, updated.EasinessFactor);
        Assert.Equal("DIRECT:ASSESSMENT:quality=5", updated.Reason);
    }
}
