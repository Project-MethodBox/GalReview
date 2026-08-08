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

public sealed record ScoreResult(bool Correct, double? Similarity, int Quality, decimal AwardedScore, string JudgeVersion, bool Degraded);
public interface IAnswerScorer
{
    Task<ScoreResult> ScoreAsync(PracticeQuestion question, IReadOnlyList<string> answer, int responseTimeMs, CancellationToken cancellationToken);
}
public interface IPracticeGateway
{
    Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken);
    Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId, Guid idempotencyKey, CancellationToken cancellationToken);
    Task<MaterialText> GetMaterialTextAsync(Guid materialId, CancellationToken cancellationToken);
}
public interface ICreditBilling
{
    Task ReserveAsync(Guid userId, Guid operationId, string operationType, long estimatedTokenUnits, CancellationToken cancellationToken);
    Task SettleAsync(Guid operationId, long actualTokenUnits, CancellationToken cancellationToken);
    Task ReleaseAsync(Guid operationId, CancellationToken cancellationToken);
}
public interface IModelStatusReader { IReadOnlyList<ModelState> Inspect(); }

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
