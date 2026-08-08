namespace PracticeService.Domain;

public enum PracticeQuestionKind { SingleChoice, FillBlank, TrueFalse, TermDefinition, Essay }
public enum ProjectStatus { Active, Archived }
public enum QuestionStatus { Draft, Ready, Deleted }
public enum PracticeSessionMode { Random, SmartReview, Exam }
public enum PracticeSessionStatus { Created, Active, Completed, Abandoned }
public enum PracticeJobKind { QuestionGeneration, ExamImport }
public enum PracticeJobStatus { Queued, Running, Succeeded, PartiallySucceeded, Failed }
public enum PackageVisibility { Private, Unlisted, Public }

public sealed record StudyProject(
    Guid ProjectId, Guid OwnerUserId, string Name, string? SubjectCode,
    IReadOnlyList<Guid> MaterialIds, Guid? GraphId, Guid QuestionBankId,
    ProjectStatus Status, int Version, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

public sealed record SourceReference(
    Guid MaterialId, long StartOffset, long EndOffset,
    string SourceMapVersion, string ExcerptChecksum);

public sealed record QuestionOption(string Id, string Text);

public sealed record PracticeQuestion(
    Guid QuestionId, Guid ProjectId, Guid QuestionBankId, PracticeQuestionKind Kind,
    string Prompt, IReadOnlyList<QuestionOption> Options, IReadOnlyList<string> CorrectAnswers,
    string? Explanation, decimal Score, int Difficulty, Guid? KnowledgePointId,
    IReadOnlyList<SourceReference> SourceReferences, QuestionStatus Status, int Version,
    DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

public sealed record PracticeAnswer(
    Guid AttemptId, Guid QuestionId, Guid IdempotencyKey, IReadOnlyList<string> Answer,
    bool Correct, double? Similarity, int Quality, decimal AwardedScore,
    int ResponseTimeMs, int AttemptNumber, string AnswerJudgeVersion, DateTimeOffset AnsweredAt);

public sealed record PracticeSession(
    Guid SessionId, Guid OwnerUserId, Guid ProjectId, Guid QuestionBankId,
    PracticeSessionMode Mode, Guid? ReviewPlanId, string? SnapshotVersion, Guid? ExamPaperId,
    IReadOnlyList<Guid> QuestionIds, IReadOnlyList<PracticeAnswer> Answers,
    int? DurationSeconds, int Seed, PracticeSessionStatus Status,
    Guid? CompletionIdempotencyKey, Guid? ResultId,
    DateTimeOffset CreatedAt, DateTimeOffset? StartedAt, DateTimeOffset? CompletedAt);

public sealed record ExamPaper(
    Guid ExamPaperId, Guid OwnerUserId, Guid ProjectId, string Title,
    IReadOnlyList<Guid> QuestionIds, int DurationSeconds, int Seed,
    decimal TotalScore, DateTimeOffset CreatedAt);

public sealed record PlanGraphPoint(Guid KnowledgePointId, string Title);
public sealed record PlanGraphSnapshot(Guid ReviewPlanId, string SnapshotVersion, IReadOnlyList<PlanGraphPoint> Points);
public sealed record ModelState(string Name, string Status, string ExpectedSha256, string? ActualSha256, string? Detail);
public sealed record PracticeJobDiagnostic(Guid? MaterialId, string Code, string Message, bool Retryable);
public sealed record PracticeJob(
    Guid JobId, Guid OwnerUserId, Guid ProjectId, Guid IdempotencyKey, string PayloadHash, PracticeJobKind Kind,
    PracticeJobStatus Status, double Progress, int CreatedCount, IReadOnlyList<PracticeJobDiagnostic> Diagnostics,
    DateTimeOffset CreatedAt, DateTimeOffset? StartedAt, DateTimeOffset? FinishedAt);
public sealed record MaterialText(Guid MaterialId, Guid OwnerUserId, string Text, string TextChecksum, string SourceMapVersion);
public sealed record SharedPracticePackage(
    Guid PackageId, Guid OwnerUserId, Guid SourceProjectId, string Version, string Title, string? SubjectCode,
    PackageVisibility Visibility, string ContentSha256, long SizeBytes, long DownloadCount,
    DateTimeOffset CreatedAt, DateTimeOffset? WithdrawnAt);

public sealed class PracticeDomainException(int statusCode, string code, string message, object? details = null) : Exception(message)
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;
    public object Details { get; } = details ?? new { };
}
