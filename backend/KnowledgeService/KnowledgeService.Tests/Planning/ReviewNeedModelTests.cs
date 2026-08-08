using KnowledgeService.Application.Planning;
using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.Tests.Planning;

public sealed class ReviewNeedModelTests
{
    [Fact]
    public void Due_need_is_a_direct_projection_of_the_sm2_schedule()
    {
        var now = DateTimeOffset.Parse("2026-08-08T08:00:00Z");
        var initial = MasteryState.Initial(Guid.NewGuid(), Guid.NewGuid(), now);
        var future = initial with
        {
            Score = 100,
            Repetitions = 2,
            IntervalDays = 6,
            LastReviewedAt = now.AddDays(-1),
            NextReviewAt = now.AddDays(5)
        };
        var due = future with { NextReviewAt = now };
        var lapsed = future with { Repetitions = 0 };

        Assert.Equal(1, ReviewNeedModel.DueNeed(initial, now));
        Assert.Equal(0, ReviewNeedModel.DueNeed(future, now));
        Assert.Equal(1, ReviewNeedModel.DueNeed(due, now));
        Assert.Equal(1, ReviewNeedModel.DueNeed(lapsed, now));
    }
}
