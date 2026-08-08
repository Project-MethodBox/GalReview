using PracticeService.Application;
using PracticeService.Domain;

namespace PracticeService.API;

public sealed record ApiError(string Code, string Message, object Details);
public sealed record ApiSuccess(object Data, object Meta, string TraceId)
{
    public static ApiSuccess Create(object data, string traceId, object? meta = null) => new(data, meta ?? new { }, traceId);
}
public sealed record ApiFailure(object? Data, ApiError Error, string TraceId)
{
    public static ApiFailure Create(string code, string message, string traceId, object? details = null) => new(null, new(code, message, details ?? new { }), traceId);
}
public sealed record CreateProjectRequest(string? Name, string? SubjectCode, IReadOnlyList<Guid>? MaterialIds, Guid? GraphId);
public sealed record UpdateProjectRequest(string? Name, string? SubjectCode, IReadOnlyList<Guid>? MaterialIds, Guid? GraphId, int? Version);
public sealed record QuestionOptionRequest(string? Id, string? Text);
public sealed record SourceReferenceRequest(Guid? MaterialId, long? StartOffset, long? EndOffset, string? SourceMapVersion, string? ExcerptChecksum);
public sealed record UpsertQuestionRequest(PracticeQuestionKind Kind, string? Prompt, IReadOnlyList<QuestionOptionRequest>? Options,
    IReadOnlyList<string>? CorrectAnswers, string? Explanation, decimal? Score, int? Difficulty, Guid? KnowledgePointId,
    IReadOnlyList<SourceReferenceRequest>? SourceReferences, QuestionStatus? Status, int? Version);
public sealed record CreateExamPaperRequest(string? Title, int? QuestionCount, int? DurationSeconds, int? Seed, IReadOnlyDictionary<PracticeQuestionKind, int>? KindCounts);
public sealed record CreatePracticeSessionRequest(Guid ProjectId, PracticeSessionMode Mode, Guid? ReviewPlanId, string? SnapshotVersion,
    Guid? ExamPaperId, int? QuestionCount, IReadOnlyList<PracticeQuestionKind>? Kinds, int? DurationSeconds, int? Seed);
public sealed record SaveAnswerRequest(IReadOnlyList<string>? Answer, int? ResponseTimeMs, int? AttemptNumber, Guid? IdempotencyKey);
public sealed record CompleteSessionRequest(Guid? IdempotencyKey);
public sealed record GenerateQuestionsRequest(Guid? IdempotencyKey, Guid? ReviewPlanId, string? SnapshotVersion,
    IReadOnlyList<PracticeQuestionKind>? Kinds, int? TargetCount, string? GeneratorVersion);
public sealed record ImportExamRequest(Guid? IdempotencyKey, Guid? ProjectId, Guid? MaterialId);
public sealed record QuestionHelpRequest(bool? GenerateExplanation);
public sealed record PublishPracticePackageRequest(string? Version, string? Title, PackageVisibility? Visibility);
public sealed record SessionQuestion(Guid QuestionId, PracticeQuestionKind Kind, string Prompt, IReadOnlyList<QuestionOption> Options,
    decimal Score, int Difficulty, Guid? KnowledgePointId, IReadOnlyList<SourceReference> SourceReferences);
public sealed record SessionResponse(Guid SessionId, Guid ProjectId, PracticeSessionMode Mode, Guid? ReviewPlanId, string? SnapshotVersion,
    IReadOnlyList<SessionQuestion> Questions, IReadOnlyList<PracticeAnswer> Answers, int? DurationSeconds, PracticeSessionStatus Status,
    DateTimeOffset CreatedAt, DateTimeOffset? StartedAt, DateTimeOffset? CompletedAt)
{
    public static SessionResponse From(SessionDetails details) => new(details.Session.SessionId, details.Session.ProjectId, details.Session.Mode,
        details.Session.ReviewPlanId, details.Session.SnapshotVersion, details.Session.QuestionIds.Select(id => details.Questions.Single(x => x.QuestionId == id))
            .Select(x => new SessionQuestion(x.QuestionId, x.Kind, x.Prompt, x.Options, x.Score, x.Difficulty, x.KnowledgePointId, x.SourceReferences)).ToArray(),
        details.Session.Answers, details.Session.DurationSeconds, details.Session.Status, details.Session.CreatedAt, details.Session.StartedAt, details.Session.CompletedAt);
}
