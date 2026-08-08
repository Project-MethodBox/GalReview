using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.Application.Planning;

internal static class ReviewNeedModel
{
    /// <summary>
    /// Projects the SM-2 schedule into a due/not-due need. The planner then
    /// applies graph coverage to that due set. No guessed retention curve or
    /// cross-signal mixing coefficient is introduced.
    /// </summary>
    public static double DueNeed(
        MasteryState? mastery,
        DateTimeOffset now)
    {
        if (mastery is null ||
            mastery.LastReviewedAt is null ||
            mastery.Repetitions == 0)
        {
            return 1;
        }

        return now >= mastery.NextReviewAt ? 1 : 0;
    }
}
