using KnowledgeService.Domain.Mastery;

namespace KnowledgeService.Application.Mastery;

internal static class Sm2Scheduler
{
    internal const int MaximumIntervalDays = 3650;

    public static MasteryState Apply(
        MasteryState current,
        int quality,
        bool correct,
        bool usedHint,
        DateTimeOffset now,
        string purpose)
    {
        // SM-2 already carries the longitudinal state in repetitions,
        // interval and easiness. Score is only the latest direct observation
        // shown to the learner; an uncalibrated exponential moving average
        // would add a second, arbitrary memory model.
        var score = quality / 5d * 100;

        var difference = 5 - quality;
        var easiness = Math.Max(
            1.3,
            current.EasinessFactor +
            (0.1 - difference * (0.08 + difference * 0.02)));

        int repetitions;
        int lapses;
        int intervalDays;
        if (quality < 3)
        {
            repetitions = 0;
            lapses = current.Lapses + 1;
            intervalDays = 1;
        }
        else
        {
            repetitions = current.Repetitions + 1;
            lapses = current.Lapses;
            var nextInterval = repetitions switch
            {
                1 => 1d,
                2 => 6d,
                _ => Math.Round(
                    Math.Max(current.IntervalDays, 1) * easiness,
                    MidpointRounding.AwayFromZero)
            };
            intervalDays = (int)Math.Clamp(
                nextInterval,
                1,
                MaximumIntervalDays);
        }

        return current with
        {
            Score = Math.Round(score, 2),
            EasinessFactor = Math.Round(easiness, 3),
            IntervalDays = intervalDays,
            Repetitions = repetitions,
            Lapses = lapses,
            NextReviewAt = now.AddDays(intervalDays),
            LastReviewedAt = now,
            Reason = $"DIRECT:{purpose}:quality={quality}",
            Version = current.Version + 1
        };
    }
}
