namespace KnowledgeService.Domain.Mastery;

public sealed record MasteryState(
    Guid UserId,
    Guid PointId,
    double Score,
    double EasinessFactor,
    int IntervalDays,
    int Repetitions,
    int Lapses,
    DateTimeOffset NextReviewAt,
    DateTimeOffset? LastReviewedAt,
    string Reason,
    long Version)
{
    public static MasteryState Initial(Guid userId, Guid pointId, DateTimeOffset now) =>
        new(
            userId,
            pointId,
            0,
            2.5,
            0,
            0,
            0,
            now,
            null,
            "INITIAL",
            0);
}
