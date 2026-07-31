namespace KnowledgeService.API.Contracts;

public sealed record KnowledgeAnswerEvidenceRequest(
    Guid? AttemptId,
    Guid? QuestionId,
    Guid? KnowledgePointId,
    string? AnswerKind,
    bool? Correct,
    int? Quality,
    long? ResponseTimeMs,
    int? HintsUsed,
    int? AttemptNumber,
    DateTimeOffset? OccurredAt);
