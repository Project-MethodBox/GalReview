using PracticeService.Domain;

namespace PracticeService.Application;

public interface IPracticeRepository
{
    StudyProject CreateProject(StudyProject value);
    StudyProject? GetProject(Guid id);
    IReadOnlyList<StudyProject> ListProjects(Guid owner);
    void SaveProject(StudyProject value);
    PracticeQuestion CreateQuestion(PracticeQuestion value);
    PracticeQuestion? GetQuestion(Guid id);
    IReadOnlyList<PracticeQuestion> ListQuestions(Guid projectId);
    void SaveQuestion(PracticeQuestion value);
    PracticeSession CreateSession(PracticeSession value);
    PracticeSession? GetSession(Guid id);
    void SaveSession(PracticeSession value);
    ExamPaper CreateExamPaper(ExamPaper value);
    ExamPaper? GetExamPaper(Guid id);
    PracticeJob CreateJob(PracticeJob value);
    PracticeJob? GetJob(Guid id);
    PracticeJob? FindJob(Guid ownerUserId, Guid projectId, Guid idempotencyKey);
    void SaveJob(PracticeJob value);
}

public sealed record ReferenceFacet(string Claim);
public sealed record FacetAdjudication(
    string Claim,
    FacetVerdict Verdict,
    double EntailmentProbability,
    double NeutralProbability,
    double ContradictionProbability);
public sealed record FacetAdjudicationBatch(
    bool Available,
    string ModelVersion,
    IReadOnlyList<FacetAdjudication> Facets,
    string? FailureReason);
public interface IFacetAdjudicator
{
    Task<FacetAdjudicationBatch> AdjudicateAsync(
        string answer,
        IReadOnlyList<ReferenceFacet> facets,
        CancellationToken cancellationToken);
}

public sealed record ScoreResult(
    GradingStatus Status,
    RecallOutcome Outcome,
    bool? Correct,
    double? Similarity,
    int? Quality,
    decimal? AwardedScore,
    string JudgeVersion,
    string? AbstainReason,
    IReadOnlyList<FacetAssessment> Facets,
    bool Degraded);
public interface IAnswerScorer
{
    Task<ScoreResult> ScoreAsync(PracticeQuestion question, IReadOnlyList<string> answer, int responseTimeMs, CancellationToken cancellationToken);
}
public interface IPracticeGateway
{
    Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken);
    Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId, Guid idempotencyKey, CancellationToken cancellationToken);
    Task<MaterialText> GetMaterialTextAsync(Guid materialId, CancellationToken cancellationToken);
    Task<KnowledgeGraphScope> GetGraphScopeAsync(Guid graphId, Guid ownerUserId, CancellationToken cancellationToken);
}
public sealed record KnowledgeGraphScope(
    Guid GraphId,
    Guid MaterialId,
    Guid? StudyProjectId,
    Guid OwnerUserId,
    IReadOnlyList<PlanGraphPoint> Points);
public interface ICreditBilling
{
    Task ReserveAsync(Guid userId, Guid operationId, string operationType, long estimatedTokenUnits, CancellationToken cancellationToken);
    Task SettleAsync(Guid operationId, long actualTokenUnits, CancellationToken cancellationToken);
    Task ReleaseAsync(Guid operationId, CancellationToken cancellationToken);
}

public sealed record QuestionGenerationInput(
    IReadOnlyList<MaterialText> Materials,
    IReadOnlyList<PracticeQuestionKind> Kinds,
    int? RequestedTargetCount,
    IReadOnlyList<PlanGraphPoint> Points,
    string GeneratorVersion);

public sealed record QuestionGenerationEstimate(
    int ResolvedTargetCount,
    long MaximumTokenUnits,
    string Mode);

public sealed record QuestionGenerationOutput(
    IReadOnlyList<QuestionDraft> Drafts,
    IReadOnlyList<PracticeJobDiagnostic> Diagnostics,
    long ActualTokenUnits,
    string Mode);

public interface IPracticeQuestionGenerator
{
    QuestionGenerationEstimate Estimate(QuestionGenerationInput input);
    Task<QuestionGenerationOutput> GenerateAsync(QuestionGenerationInput input, CancellationToken cancellationToken);
}
public sealed record DecodedPracticePackage(string Name, string? SubjectCode, string ImportedFromSchema,
    IReadOnlyList<QuestionDraft> Questions, IReadOnlyList<string> Diagnostics);
public sealed record PracticePackageContent(string FileName, string ContentType, byte[] Content);
public interface IPracticePackageCodec
{
    DecodedPracticePackage Decode(string fileName, byte[] content);
    PracticePackageContent Encode(StudyProject project, IReadOnlyList<PracticeQuestion> questions);
}
public interface ISharedPracticePackageStore
{
    SharedPracticePackage Save(SharedPracticePackage package, byte[] content);
    SharedPracticePackage? Get(Guid packageId);
    SharedPracticePackage? FindVersion(Guid ownerUserId, Guid sourceProjectId, string version);
    IReadOnlyList<SharedPracticePackage> Search(Guid requesterUserId, string? query, string? subjectCode);
    byte[]? ReadContent(Guid packageId);
    void SaveMetadata(SharedPracticePackage package);
}

public static class PracticeOwnership
{
    public static StudyProject Project(Guid id, Guid owner, IPracticeRepository repository)
    {
        var value = repository.GetProject(id);
        return value is null || value.OwnerUserId != owner || value.Status == ProjectStatus.Archived
            ? throw NotFound() : value;
    }
    public static PracticeSession Session(Guid id, Guid owner, IPracticeRepository repository)
    {
        var value = repository.GetSession(id);
        return value is null || value.OwnerUserId != owner ? throw NotFound() : value;
    }
    public static PracticeDomainException NotFound() => new(404, "RESOURCE_NOT_FOUND", "资源不存在。");
}
