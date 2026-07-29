namespace KnowledgeService.Domain.Reviews;

public sealed record ReviewAnswer(
    Guid KnowledgePointId,
    string AttemptId,
    bool Correct,
    int Quality,
    int DurationSeconds,
    bool UsedHint,
    Guid QuestionId = default,
    string AnswerKind = "OTHER",
    long? ResponseTimeMilliseconds = null,
    int HintsUsed = 0,
    int AttemptNumber = 1,
    DateTimeOffset? OccurredAt = null);
