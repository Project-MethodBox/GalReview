using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.Application.Planning;

internal static class ReviewNeedModel
{
    // SM-2 schedules the next review around a desired 90% retention point.
    private const double DesiredRetentionAtDue = 0.90;

    /// <summary>
    /// Returns the modeled probability that the learner cannot currently recall
    /// a point. The formula has one meaning throughout planning; it is not a
    /// weighted blend of unrelated heuristics.
    /// </summary>
    public static double ForgettingRisk(
        MasteryState? mastery,
        DateTimeOffset now)
    {
        if (mastery is null ||
            mastery.LastReviewedAt is null ||
            mastery.Score <= 0)
        {
            return 1;
        }

        var elapsedDays = Math.Max(
            0,
            (now - mastery.LastReviewedAt.Value).TotalDays);
        var stabilityDays = Math.Max(1, mastery.IntervalDays);
        var retentionSinceReview = Math.Exp(
            Math.Log(DesiredRetentionAtDue) *
            elapsedDays /
            stabilityDays);
        var recallProbability =
            Math.Clamp(mastery.Score / 100d, 0, 1) *
            retentionSinceReview;
        return Math.Clamp(1 - recallProbability, 0, 1);
    }
}
