using MediatR;
using PracticeService.Domain;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace PracticeService.Application;

public sealed record GetReadinessQuery(string Storage) : IRequest<Readiness>;
public sealed record Readiness(string Status, string Storage, IReadOnlyList<ModelState> Models);
public sealed class GetReadinessHandler(IModelStatusReader models) : IRequestHandler<GetReadinessQuery, Readiness>
{
    public Task<Readiness> Handle(GetReadinessQuery request, CancellationToken cancellationToken) =>
        Task.FromResult(new Readiness("ready", request.Storage, models.Inspect()));
}

public sealed record GenerateQuestionsCommand(Guid OwnerUserId, Guid ProjectId, Guid IdempotencyKey, Guid? ReviewPlanId,
    string? SnapshotVersion, IReadOnlyList<PracticeQuestionKind> Kinds, int? TargetCount, string GeneratorVersion) : IRequest<PracticeJob>;
public sealed record ImportExamCommand(Guid OwnerUserId, Guid ProjectId, Guid MaterialId, Guid IdempotencyKey) : IRequest<PracticeJob>;
public sealed record GetPracticeJobQuery(Guid OwnerUserId, Guid JobId) : IRequest<PracticeJob>;
public sealed record GetQuestionHelpQuery(Guid OwnerUserId, Guid QuestionId, bool GenerateExplanation) : IRequest<QuestionHelp>;
public sealed record QuestionHelpMatch(Guid? KnowledgePointId, string Title, string Excerpt, SourceReference SourceReference, double Similarity);
public sealed record QuestionHelp(Guid QuestionId, IReadOnlyList<QuestionHelpMatch> Matches, string? GeneratedExplanation, bool Grounded, string? GeneratorVersion);

public sealed class ContentHandlers(IPracticeRepository repository, IPracticeGateway gateway, ICreditBilling billing, IPracticeQuestionGenerator questionGenerator) :
    IRequestHandler<GenerateQuestionsCommand, PracticeJob>, IRequestHandler<ImportExamCommand, PracticeJob>,
    IRequestHandler<GetPracticeJobQuery, PracticeJob>, IRequestHandler<GetQuestionHelpQuery, QuestionHelp>
{
    public async Task<PracticeJob> Handle(GenerateQuestionsCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        ValidateJob(request.IdempotencyKey, request.TargetCount);
        var payloadHash = PracticeRules.Sha256($"{request.ReviewPlanId}|{request.SnapshotVersion}|{string.Join(',', request.Kinds)}|{request.TargetCount}|{request.GeneratorVersion}");
        var existing = repository.FindJob(request.OwnerUserId, request.ProjectId, request.IdempotencyKey);
        if (existing is not null) return existing.PayloadHash == payloadHash ? existing : throw new PracticeDomainException(409, "IDEMPOTENCY_KEY_REUSED", "幂等键已用于不同生成请求。");
        if (project.GraphId is null)
            throw new PracticeDomainException(422, "PROJECT_GRAPH_REQUIRED", "从资料生成题目前必须先为复习项目绑定知识图谱。");
        if (request.ReviewPlanId is not Guid planId || string.IsNullOrWhiteSpace(request.SnapshotVersion))
            throw new PracticeDomainException(400, "PLAN_REQUIRED", "题目生成必须提供当前复习项目的 reviewPlanId 与 snapshotVersion。");
        var plan = await gateway.GetPlanAsync(planId, request.SnapshotVersion, ct);
        PracticePlanRules.Validate(project, request.OwnerUserId, plan);
        if (plan.Points.Count == 0)
            throw new PracticeDomainException(422, "PLAN_TARGETS_EMPTY", "复习计划没有可用于生成题目的目标知识点。");
        var materials = new List<MaterialText>();
        foreach (var materialId in project.MaterialIds)
        {
            var material = await gateway.GetMaterialTextAsync(materialId, ct);
            if (material.OwnerUserId != request.OwnerUserId) throw PracticeOwnership.NotFound();
            materials.Add(material);
        }
        var generationInput = new QuestionGenerationInput(materials, request.Kinds, request.TargetCount, plan.Points, request.GeneratorVersion);
        var estimate = questionGenerator.Estimate(generationInput);
        await billing.ReserveAsync(request.OwnerUserId, request.IdempotencyKey, "PRACTICE_GENERATION", estimate.MaximumTokenUnits, ct);
        var now = DateTimeOffset.UtcNow;
        PracticeJob job;
        try
        {
            job = repository.CreateJob(new PracticeJob(Guid.NewGuid(), request.OwnerUserId, project.ProjectId, request.IdempotencyKey,
                payloadHash, PracticeJobKind.QuestionGeneration, PracticeJobStatus.Running, 0, 0, [], now, now, null));
        }
        catch { await billing.ReleaseAsync(request.IdempotencyKey, CancellationToken.None); throw; }
        var diagnostics = new List<PracticeJobDiagnostic>(); var created = 0;
        try
        {
            var batch = await questionGenerator.GenerateAsync(generationInput, ct);
            diagnostics.AddRange(batch.Diagnostics);
            foreach (var draft in batch.Drafts)
            {
                try
                {
                    var generatedQuestion = repository.CreateQuestion(PracticeRules.CreateQuestion(project, draft));
                    created++;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                { diagnostics.Add(new(draft.SourceReferences.FirstOrDefault()?.MaterialId, error is PracticeDomainException domain ? domain.Code : "QUESTION_GENERATION_FAILED", error.Message, true)); }
            }
            var status = created == 0 ? PracticeJobStatus.Failed : diagnostics.Count == 0 ? PracticeJobStatus.Succeeded : PracticeJobStatus.PartiallySucceeded;
            job = job with { Status = status, Progress = 1, CreatedCount = created, Diagnostics = diagnostics, FinishedAt = DateTimeOffset.UtcNow };
            repository.SaveJob(job);
            if (created == 0) await billing.ReleaseAsync(request.IdempotencyKey, CancellationToken.None);
            else
            {
                await billing.SettleAsync(request.IdempotencyKey, batch.ActualTokenUnits, CancellationToken.None);
            }
            return job;
        }
        catch (OperationCanceledException)
        {
            job = job with
            {
                Status = PracticeJobStatus.Failed,
                Progress = 1,
                Diagnostics = [new(null, "GENERATION_CANCELLED", "题目生成已取消。", true)],
                FinishedAt = DateTimeOffset.UtcNow
            };
            repository.SaveJob(job);
            await billing.ReleaseAsync(request.IdempotencyKey, CancellationToken.None);
            throw;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            job = job with { Status = PracticeJobStatus.Failed, Progress = 1, Diagnostics = [new(null, error is PracticeDomainException domain ? domain.Code : "GENERATION_FAILED", error.Message, false)], FinishedAt = DateTimeOffset.UtcNow };
            repository.SaveJob(job); await billing.ReleaseAsync(request.IdempotencyKey, CancellationToken.None); return job;
        }
    }

    public async Task<PracticeJob> Handle(ImportExamCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository); ValidateJob(request.IdempotencyKey, 1);
        var payloadHash = PracticeRules.Sha256(request.MaterialId.ToString("D"));
        var existing = repository.FindJob(request.OwnerUserId, project.ProjectId, request.IdempotencyKey);
        if (existing is not null) return existing.PayloadHash == payloadHash ? existing : throw new PracticeDomainException(409, "IDEMPOTENCY_KEY_REUSED", "幂等键已用于不同导入请求。");
        var now = DateTimeOffset.UtcNow; var job = repository.CreateJob(new PracticeJob(Guid.NewGuid(), request.OwnerUserId, project.ProjectId, request.IdempotencyKey,
            payloadHash, PracticeJobKind.ExamImport, PracticeJobStatus.Running, 0, 0, [], now, now, null));
        try
        {
            if (!project.MaterialIds.Contains(request.MaterialId)) throw new PracticeDomainException(422, "MATERIAL_ACCESS_DENIED", "整卷资料必须属于当前学习项目。");
            var material = await gateway.GetMaterialTextAsync(request.MaterialId, ct); if (material.OwnerUserId != request.OwnerUserId) throw PracticeOwnership.NotFound();
            var drafts = ParseExam(material).ToArray(); foreach (var draft in drafts) repository.CreateQuestion(PracticeRules.CreateQuestion(project, draft));
            job = job with { Status = drafts.Length == 0 ? PracticeJobStatus.Failed : PracticeJobStatus.Succeeded, Progress = 1, CreatedCount = drafts.Length,
                Diagnostics = drafts.Length == 0 ? [new(request.MaterialId, "EXAM_STRUCTURE_NOT_FOUND", "没有识别到带题号和答案的题目，未创建猜测答案。", false)] : [], FinishedAt = DateTimeOffset.UtcNow };
        }
        catch (Exception error) when (error is not OperationCanceledException)
        { job = job with { Status = PracticeJobStatus.Failed, Progress = 1, Diagnostics = [new(request.MaterialId, error is PracticeDomainException domain ? domain.Code : "EXAM_IMPORT_FAILED", error.Message, false)], FinishedAt = DateTimeOffset.UtcNow }; }
        repository.SaveJob(job); return job;
    }

    public Task<PracticeJob> Handle(GetPracticeJobQuery request, CancellationToken ct)
    {
        var job = repository.GetJob(request.JobId); return Task.FromResult(job is null || job.OwnerUserId != request.OwnerUserId ? throw PracticeOwnership.NotFound() : job);
    }

    public async Task<QuestionHelp> Handle(GetQuestionHelpQuery request, CancellationToken ct)
    {
        var question = repository.GetQuestion(request.QuestionId) ?? throw PracticeOwnership.NotFound();
        _ = PracticeOwnership.Project(question.ProjectId, request.OwnerUserId, repository); var matches = new List<QuestionHelpMatch>();
        foreach (var source in question.SourceReferences.Take(3))
        {
            var material = await gateway.GetMaterialTextAsync(source.MaterialId, ct); if (material.OwnerUserId != request.OwnerUserId) continue;
            var start = (int)Math.Clamp(source.StartOffset, 0, material.Text.Length); var end = (int)Math.Clamp(source.EndOffset, start, material.Text.Length);
            var excerpt = material.Text[start..end]; matches.Add(new(question.KnowledgePointId, question.Prompt, excerpt, source, PracticeRules.LevenshteinSimilarity(question.Prompt, excerpt)));
        }
        var ranked = matches.OrderByDescending(x => x.Similarity).ToArray();
        var explanation = request.GenerateExplanation && ranked.Length > 0 ? $"根据资料原文：{ranked[0].Excerpt}" : null;
        return new(question.QuestionId, ranked, explanation, ranked.Length > 0, explanation is null ? null : "grounded-template-v1");
    }

    private static IEnumerable<QuestionDraft> ParseExam(MaterialText material)
    {
        var blocks = Regex.Split(material.Text.Replace("\r", ""), @"(?m)(?=^\s*\d{1,4}[.、)]\s*)");
        foreach (var block in blocks)
        {
            var head = Regex.Match(block, @"^\s*\d{1,4}[.、)]\s*(?<q>[^\n]+)"); var answer = Regex.Match(block, @"(?im)^\s*(?:参考)?答案\s*[:：]\s*(?<a>.+)$");
            if (!head.Success || !answer.Success) continue;
            var prompt = head.Groups["q"].Value.Trim(); var answerText = answer.Groups["a"].Value.Trim(); var options = Regex.Matches(block, @"(?m)^\s*(?<id>[A-H])[.、)]\s*(?<text>.+)$").Select(x => new QuestionOption(x.Groups["id"].Value, x.Groups["text"].Value.Trim())).ToArray();
            var kind = options.Length >= 2 ? PracticeQuestionKind.SingleChoice : PracticeQuestionKind.Essay; var normalizedAnswer = kind == PracticeQuestionKind.SingleChoice ? Regex.Match(answerText, "[A-H]", RegexOptions.IgnoreCase).Value.ToUpperInvariant() : answerText;
            if (normalizedAnswer.Length == 0) continue;
            var start = material.Text.IndexOf(block, StringComparison.Ordinal); var source = new SourceReference(material.MaterialId, Math.Max(0, start), Math.Max(0, start) + block.Length, material.SourceMapVersion, PracticeRules.Sha256(block));
            yield return new(kind, prompt, options, [normalizedAnswer], null, kind == PracticeQuestionKind.SingleChoice ? 3 : 5, 3, null, [source], QuestionStatus.Draft);
        }
    }
    private static void ValidateJob(Guid key, int? count)
    {
        if (key == Guid.Empty) throw new PracticeDomainException(400, "VALIDATION_ERROR", "idempotencyKey 必填。");
        if (count is < 1 or > 1000) throw new PracticeDomainException(400, "VALIDATION_ERROR", "targetCount 必须在 1-1000 范围内，或省略以自动建库。");
    }
}

public sealed record QuestionInput(
    PracticeQuestionKind Kind, string Prompt, IReadOnlyList<QuestionOption> Options,
    IReadOnlyList<string> CorrectAnswers, string? Explanation, decimal Score, int Difficulty,
    Guid? KnowledgePointId, IReadOnlyList<SourceReference> SourceReferences, QuestionStatus Status, int? Version = null);

public sealed record CreateProjectCommand(Guid OwnerUserId, string Name, string? SubjectCode, IReadOnlyList<Guid> MaterialIds, Guid? GraphId) : IRequest<StudyProject>;
public sealed record ListProjectsQuery(Guid OwnerUserId) : IRequest<IReadOnlyList<StudyProject>>;
public sealed record GetProjectQuery(Guid OwnerUserId, Guid ProjectId) : IRequest<ProjectDetails>;
public sealed record ProjectDetails(StudyProject Project, IReadOnlyDictionary<PracticeQuestionKind, int> QuestionCounts, int ReadyQuestionCount);
public sealed record ValidateProjectGraphScopeQuery(Guid OwnerUserId, Guid ProjectId, Guid MaterialId) : IRequest<ProjectGraphScope>;
public sealed record ProjectGraphScope(Guid StudyProjectId, Guid OwnerUserId, IReadOnlyList<Guid> MaterialIds);
public sealed record UpdateProjectCommand(Guid OwnerUserId, Guid ProjectId, string? Name, string? SubjectCode, IReadOnlyList<Guid>? MaterialIds, Guid? GraphId, int Version) : IRequest<StudyProject>;
public sealed record ArchiveProjectCommand(Guid OwnerUserId, Guid ProjectId) : IRequest;

public sealed class ProjectHandlers(IPracticeRepository repository, IPracticeGateway gateway) :
    IRequestHandler<CreateProjectCommand, StudyProject>, IRequestHandler<ListProjectsQuery, IReadOnlyList<StudyProject>>,
    IRequestHandler<GetProjectQuery, ProjectDetails>, IRequestHandler<ValidateProjectGraphScopeQuery, ProjectGraphScope>,
    IRequestHandler<UpdateProjectCommand, StudyProject>, IRequestHandler<ArchiveProjectCommand>
{
    public async Task<StudyProject> Handle(CreateProjectCommand request, CancellationToken ct)
    {
        if (request.GraphId is not null)
            throw new PracticeDomainException(409, "PROJECT_GRAPH_MUST_BE_CREATED_IN_PROJECT", "新研习册的知识图谱必须在立册后以本册为作用域建立。");
        var name = ValidateName(request.Name); var materials = ValidateMaterials(request.MaterialIds); await ValidateMaterialOwnership(materials, request.OwnerUserId, ct); var now = DateTimeOffset.UtcNow;
        var project = new StudyProject(Guid.NewGuid(), request.OwnerUserId, name, NormalizeSubject(request.SubjectCode), materials,
            request.GraphId, Guid.NewGuid(), ProjectStatus.Active, 1, now, now);
        return repository.CreateProject(project);
    }
    public Task<IReadOnlyList<StudyProject>> Handle(ListProjectsQuery request, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<StudyProject>>(repository.ListProjects(request.OwnerUserId).Where(x => x.Status == ProjectStatus.Active).ToArray());
    public Task<ProjectDetails> Handle(GetProjectQuery request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        var questions = repository.ListQuestions(project.ProjectId).Where(x => x.Status != QuestionStatus.Deleted).ToArray();
        var readyCount = questions.Count(question => question.Status == QuestionStatus.Ready &&
            (!project.GraphId.HasValue || question.KnowledgePointId.HasValue));
        return Task.FromResult(new ProjectDetails(project, questions.GroupBy(x => x.Kind).ToDictionary(x => x.Key, x => x.Count()), readyCount));
    }
    public Task<ProjectGraphScope> Handle(ValidateProjectGraphScopeQuery request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        if (request.MaterialId == Guid.Empty || !project.MaterialIds.Contains(request.MaterialId))
            throw new PracticeDomainException(409, "MATERIAL_OUTSIDE_PROJECT_SCOPE", "该资料不属于目标研习册，不能用于建立本册图谱。");
        return Task.FromResult(new ProjectGraphScope(project.ProjectId, project.OwnerUserId, project.MaterialIds));
    }
    public async Task<StudyProject> Handle(UpdateProjectCommand request, CancellationToken ct)
    {
        var current = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        if (request.Version != current.Version) throw new PracticeDomainException(409, "VERSION_CONFLICT", "项目版本已经变化，请刷新后重试。");
        var materials = request.MaterialIds is null ? current.MaterialIds : ValidateMaterials(request.MaterialIds);
        if (request.MaterialIds is not null) await ValidateMaterialOwnership(materials, request.OwnerUserId, ct);
        if (request.GraphId is { } graphId && graphId != current.GraphId)
        {
            var scope = await gateway.GetGraphScopeAsync(graphId, request.OwnerUserId, ct);
            if (scope.StudyProjectId != current.ProjectId || !materials.Contains(scope.MaterialId))
                throw new PracticeDomainException(409, "GRAPH_OUTSIDE_PROJECT_SCOPE", "知识图谱不属于本研习册或其资料范围。");
        }
        var updated = current with { Name = request.Name is null ? current.Name : ValidateName(request.Name),
            SubjectCode = request.SubjectCode is null ? current.SubjectCode : NormalizeSubject(request.SubjectCode),
            MaterialIds = materials,
            GraphId = request.GraphId ?? current.GraphId, Version = current.Version + 1, UpdatedAt = DateTimeOffset.UtcNow };
        repository.SaveProject(updated); return updated;
    }
    public Task Handle(ArchiveProjectCommand request, CancellationToken ct)
    {
        var current = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        repository.SaveProject(current with { Status = ProjectStatus.Archived, Version = current.Version + 1, UpdatedAt = DateTimeOffset.UtcNow });
        return Task.CompletedTask;
    }
    private static string ValidateName(string value) { var name = value.Trim(); if (name.Length is < 1 or > 120) throw new PracticeDomainException(400, "VALIDATION_ERROR", "name 必须包含 1-120 个字符。"); return name; }
    private static IReadOnlyList<Guid> ValidateMaterials(IEnumerable<Guid> value) { var ids = value.Distinct().ToArray(); if (ids.Length is < 1 or > 20 || ids.Any(x => x == Guid.Empty)) throw new PracticeDomainException(400, "PROJECT_MATERIALS_REQUIRED", "项目必须引用 1-20 份有效资料。"); return ids; }
    private async Task ValidateMaterialOwnership(IReadOnlyList<Guid> ids, Guid owner, CancellationToken ct)
    { foreach (var id in ids) { var material = await gateway.GetMaterialTextAsync(id, ct); if (material.OwnerUserId != owner) throw PracticeOwnership.NotFound(); } }
    private static string? NormalizeSubject(string? value) { if (string.IsNullOrWhiteSpace(value)) return null; var result = value.Trim().ToUpperInvariant(); if (!System.Text.RegularExpressions.Regex.IsMatch(result, "^[A-Z][A-Z0-9_]{0,31}$")) throw new PracticeDomainException(400, "VALIDATION_ERROR", "subjectCode 格式无效。"); return result; }
}

public sealed record ListQuestionsQuery(Guid OwnerUserId, Guid ProjectId, PracticeQuestionKind? Kind, QuestionStatus? Status, Guid? KnowledgePointId) : IRequest<IReadOnlyList<PracticeQuestion>>;
public sealed record CreateQuestionCommand(Guid OwnerUserId, Guid ProjectId, QuestionInput Input) : IRequest<PracticeQuestion>;
public sealed record UpdateQuestionCommand(Guid OwnerUserId, Guid QuestionId, QuestionInput Input) : IRequest<PracticeQuestion>;
public sealed record DeleteQuestionCommand(Guid OwnerUserId, Guid QuestionId) : IRequest;

public sealed class QuestionHandlers(IPracticeRepository repository, IPracticeGateway gateway) :
    IRequestHandler<ListQuestionsQuery, IReadOnlyList<PracticeQuestion>>, IRequestHandler<CreateQuestionCommand, PracticeQuestion>,
    IRequestHandler<UpdateQuestionCommand, PracticeQuestion>, IRequestHandler<DeleteQuestionCommand>
{
    public Task<IReadOnlyList<PracticeQuestion>> Handle(ListQuestionsQuery request, CancellationToken ct)
    {
        _ = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        var query = repository.ListQuestions(request.ProjectId).Where(x => x.Status != QuestionStatus.Deleted);
        if (request.Kind.HasValue) query = query.Where(x => x.Kind == request.Kind);
        if (request.Status.HasValue) query = query.Where(x => x.Status == request.Status);
        if (request.KnowledgePointId.HasValue) query = query.Where(x => x.KnowledgePointId == request.KnowledgePointId);
        return Task.FromResult<IReadOnlyList<PracticeQuestion>>(query.ToArray());
    }
    public Task<PracticeQuestion> Handle(CreateQuestionCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        return Task.FromResult(repository.CreateQuestion(PracticeRules.CreateQuestion(project, Draft(request.Input))));
    }
    public async Task<PracticeQuestion> Handle(UpdateQuestionCommand request, CancellationToken ct)
    {
        var current = repository.GetQuestion(request.QuestionId) ?? throw PracticeOwnership.NotFound();
        var project = PracticeOwnership.Project(current.ProjectId, request.OwnerUserId, repository);
        if (request.Input.Version != current.Version) throw new PracticeDomainException(409, "VERSION_CONFLICT", "题目版本已经变化，请刷新后重试。");
        var input = request.Input;
        if (project.GraphId is Guid graphId && input.Status == QuestionStatus.Ready)
        {
            var scope = await gateway.GetGraphScopeAsync(graphId, request.OwnerUserId, ct);
            if (scope.StudyProjectId != project.ProjectId || scope.OwnerUserId != request.OwnerUserId)
                throw new PracticeDomainException(409, "PROJECT_GRAPH_SCOPE_MISMATCH", "题目知识点必须来自当前研习册自己的图谱。");
            if (scope.Points.Count == 0)
                throw new PracticeDomainException(502, "KNOWLEDGE_POINTS_NOT_FOUND", "图谱归属已确认，但没有返回可用于题目补签的知识点。");

            var pointId = input.KnowledgePointId;
            if (!pointId.HasValue)
            {
                var binding = await AutomaticQuestionBinding.ResolveAsync(project, input.Kind, input.Prompt, input.Options,
                    input.CorrectAnswers, input.SourceReferences, scope.Points, gateway,
                    new Dictionary<Guid, MaterialText>(), ct);
                if (!binding.PointId.HasValue)
                {
                    var code = binding.Rule == "SOURCE_NOT_VERIFIED"
                        ? "QUESTION_SOURCE_VERIFICATION_FAILED"
                        : binding.Ambiguous ? "QUESTION_BINDING_AMBIGUOUS" : "QUESTION_BINDING_REQUIRED";
                    var message = binding.Rule == "SOURCE_NOT_VERIFIED"
                        ? "题目来源或答案尚不能由原文校验，未自动收入正式题库。"
                        : binding.Ambiguous
                            ? "题目同时对应多个知识点，自动补签没有猜测选择。"
                            : "题目未能唯一对应本册知识点，未自动收入正式题库。";
                    throw new PracticeDomainException(422, code, message, new { binding.Rule });
                }
                pointId = binding.PointId;
                input = input with { KnowledgePointId = pointId };
            }
            if (!scope.Points.Any(point => point.KnowledgePointId == pointId.Value))
                throw new PracticeDomainException(422, "QUESTION_BINDING_INVALID", "题目知识点不属于当前研习册图谱。");
        }
        var updated = PracticeRules.CreateQuestion(project, Draft(input), current.QuestionId, current.Version + 1, current.CreatedAt);
        repository.SaveQuestion(updated); return updated;
    }
    public Task Handle(DeleteQuestionCommand request, CancellationToken ct)
    {
        var current = repository.GetQuestion(request.QuestionId) ?? throw PracticeOwnership.NotFound();
        _ = PracticeOwnership.Project(current.ProjectId, request.OwnerUserId, repository);
        repository.SaveQuestion(current with { Status = QuestionStatus.Deleted, Version = current.Version + 1, UpdatedAt = DateTimeOffset.UtcNow });
        return Task.CompletedTask;
    }
    private static QuestionDraft Draft(QuestionInput x) => new(x.Kind, x.Prompt, x.Options, x.CorrectAnswers, x.Explanation, x.Score, x.Difficulty, x.KnowledgePointId, x.SourceReferences, x.Status);
}

public sealed record CreateExamPaperCommand(Guid OwnerUserId, Guid ProjectId, string? Title, int QuestionCount, int DurationSeconds, int? Seed,
    IReadOnlyDictionary<PracticeQuestionKind, int>? KindCounts, Guid? ReviewPlanId, string? SnapshotVersion) : IRequest<ExamPaper>;
public sealed class CreateExamPaperHandler(IPracticeRepository repository, IPracticeGateway gateway) : IRequestHandler<CreateExamPaperCommand, ExamPaper>
{
    public async Task<ExamPaper> Handle(CreateExamPaperCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository); var seed = request.Seed ?? RandomNumberGenerator.GetInt32(int.MaxValue);
        if (request.ReviewPlanId is not Guid planId || string.IsNullOrWhiteSpace(request.SnapshotVersion))
            throw new PracticeDomainException(400, "PLAN_REQUIRED", "模拟试卷必须提供当前研习册的 reviewPlanId 与 snapshotVersion，才能回写掌握度。");
        var plan = await gateway.GetPlanAsync(planId, request.SnapshotVersion, ct);
        PracticePlanRules.Validate(project, request.OwnerUserId, plan);
        await AutomaticQuestionBinding.ReconcileDraftsAsync(project, plan.Points, repository, gateway, ct);
        if (request.KindCounts is { Count: > 0 })
            throw new PracticeDomainException(400, "VALIDATION_ERROR", "图谱试卷暂不接受固定题型配额；题型由各目标知识点已有题目决定。");
        var selected = PracticeRules.SelectSmartQuestions(repository.ListQuestions(project.ProjectId), request.QuestionCount, seed, plan.Points)
            .OrderBy(question => (int)question.Kind).ToArray();
        return repository.CreateExamPaper(new ExamPaper(Guid.NewGuid(), request.OwnerUserId, project.ProjectId,
            string.IsNullOrWhiteSpace(request.Title) ? $"{project.Name} · 模拟试卷" : request.Title.Trim(), selected.Select(x => x.QuestionId).ToArray(),
            Math.Clamp(request.DurationSeconds, 60, 86400), seed, selected.Sum(x => x.Score), DateTimeOffset.UtcNow));
    }
}

public sealed record CreateSessionCommand(Guid OwnerUserId, Guid ProjectId, PracticeSessionMode Mode, Guid? ReviewPlanId, string? SnapshotVersion, Guid? ExamPaperId, int QuestionCount, IReadOnlyList<PracticeQuestionKind> Kinds, int? DurationSeconds, int? Seed) : IRequest<SessionDetails>;
public sealed record GetSessionQuery(Guid OwnerUserId, Guid SessionId) : IRequest<SessionDetails>;
public sealed record SaveAnswerCommand(Guid OwnerUserId, Guid SessionId, Guid QuestionId, IReadOnlyList<string> Answer, int ResponseTimeMs, int AttemptNumber, Guid IdempotencyKey) : IRequest<AnswerOutcome>;
public sealed record CompleteSessionCommand(Guid OwnerUserId, Guid SessionId, Guid IdempotencyKey) : IRequest<CompletionOutcome>;
public sealed record SessionDetails(PracticeSession Session, IReadOnlyList<PracticeQuestion> Questions);
public sealed record AnswerOutcome(PracticeAnswer Answer, bool Duplicate, bool Degraded);
public sealed record CompletionOutcome(PracticeSession Session, object Evidence, bool Duplicate);

internal static class PracticePlanRules
{
    public static void Validate(StudyProject project, Guid ownerUserId, PlanGraphSnapshot plan)
    {
        if (plan.OwnerUserId != ownerUserId) throw PracticeOwnership.NotFound();
        if (project.GraphId != plan.GraphId)
            throw new PracticeDomainException(409, "PROJECT_PLAN_GRAPH_MISMATCH", "复习计划不属于当前项目绑定的知识图谱。");
        if (!string.Equals(plan.Status, "OPEN", StringComparison.OrdinalIgnoreCase))
            throw new PracticeDomainException(409, "REVIEW_PLAN_NOT_OPEN", "复习计划已经完成或过期，请创建新计划。");
    }
}

public sealed class SessionHandlers(IPracticeRepository repository, IPracticeGateway gateway, IAnswerScorer scorer) :
    IRequestHandler<CreateSessionCommand, SessionDetails>, IRequestHandler<GetSessionQuery, SessionDetails>,
    IRequestHandler<SaveAnswerCommand, AnswerOutcome>, IRequestHandler<CompleteSessionCommand, CompletionOutcome>
{
    public async Task<SessionDetails> Handle(CreateSessionCommand request, CancellationToken ct)
    {
        var project = PracticeOwnership.Project(request.ProjectId, request.OwnerUserId, repository);
        if (request.Mode == PracticeSessionMode.SmartReview && (request.ReviewPlanId is null || string.IsNullOrWhiteSpace(request.SnapshotVersion)))
            throw new PracticeDomainException(400, "PLAN_REQUIRED", "SMART_REVIEW 必须提供 reviewPlanId 与 snapshotVersion。");
        PlanGraphSnapshot? plan = null;
        if (request.ReviewPlanId is Guid planId && !string.IsNullOrWhiteSpace(request.SnapshotVersion))
        {
            plan = await gateway.GetPlanAsync(planId, request.SnapshotVersion, ct);
            PracticePlanRules.Validate(project, request.OwnerUserId, plan);
            if (request.Mode == PracticeSessionMode.SmartReview)
                await AutomaticQuestionBinding.ReconcileDraftsAsync(project, plan.Points, repository, gateway, ct);
        }
        var seed = request.Seed ?? RandomNumberGenerator.GetInt32(int.MaxValue); IReadOnlyList<PracticeQuestion> selected;
        if (request.Mode == PracticeSessionMode.Exam)
        {
            if (request.ExamPaperId is null) throw new PracticeDomainException(400, "VALIDATION_ERROR", "EXAM 会话必须提供 examPaperId。");
            var paper = repository.GetExamPaper(request.ExamPaperId.Value);
            if (paper is null || paper.OwnerUserId != request.OwnerUserId || paper.ProjectId != project.ProjectId) throw PracticeOwnership.NotFound();
            selected = paper.QuestionIds.Select(repository.GetQuestion).Where(x => x is not null).Cast<PracticeQuestion>().ToArray();
        }
        else if (request.Mode == PracticeSessionMode.SmartReview)
            selected = PracticeRules.SelectSmartQuestions(repository.ListQuestions(project.ProjectId), request.QuestionCount, seed, plan!.Points, request.Kinds);
        else selected = PracticeRules.SelectQuestions(repository.ListQuestions(project.ProjectId), request.QuestionCount, seed, request.Kinds);
        if (selected.Count == 0) throw new PracticeDomainException(422, "NOT_ENOUGH_QUESTIONS", "当前范围内没有 READY 题目。");
        if (plan is not null)
        {
            var allowedPointIds = plan.Points.Select(point => point.KnowledgePointId).ToHashSet();
            if (selected.Any(question => question.KnowledgePointId is not Guid pointId || !allowedPointIds.Contains(pointId)))
                throw new PracticeDomainException(422, "QUESTION_BINDING_REQUIRED", "带 PlanGraph 的会话只能包含已绑定到计划目标的题目。");
            if (selected.Select(question => question.KnowledgePointId).Distinct().Count() != selected.Count)
                throw new PracticeDomainException(422, "DUPLICATE_KNOWLEDGE_POINT", "同一次计分复习中一个知识点只能出现一道题。");
        }
        var now = DateTimeOffset.UtcNow;
        var session = repository.CreateSession(new PracticeSession(Guid.NewGuid(), request.OwnerUserId, project.ProjectId, project.QuestionBankId,
            request.Mode, request.ReviewPlanId, request.SnapshotVersion, request.ExamPaperId, selected.Select(x => x.QuestionId).ToArray(), [], request.DurationSeconds,
            seed, PracticeSessionStatus.Active, null, null, now, now, null));
        return new(session, selected);
    }
    public Task<SessionDetails> Handle(GetSessionQuery request, CancellationToken ct)
    {
        var session = PracticeOwnership.Session(request.SessionId, request.OwnerUserId, repository);
        return Task.FromResult(new SessionDetails(session, session.QuestionIds.Select(repository.GetQuestion).Where(x => x is not null).Cast<PracticeQuestion>().ToArray()));
    }
    public async Task<AnswerOutcome> Handle(SaveAnswerCommand request, CancellationToken ct)
    {
        var session = PracticeOwnership.Session(request.SessionId, request.OwnerUserId, repository);
        if (session.Status != PracticeSessionStatus.Active) throw new PracticeDomainException(409, "SESSION_NOT_ACTIVE", "会话当前不可作答。");
        if (!session.QuestionIds.Contains(request.QuestionId)) throw PracticeOwnership.NotFound();
        if (request.IdempotencyKey == Guid.Empty || request.ResponseTimeMs is < 0 or > 86400000 || request.AttemptNumber is < 1 or > 100)
            throw new PracticeDomainException(400, "VALIDATION_ERROR", "答案参数超出契约范围。");
        var duplicate = session.Answers.FirstOrDefault(x => x.IdempotencyKey == request.IdempotencyKey);
        if (duplicate is not null)
        {
            if (duplicate.QuestionId != request.QuestionId || !duplicate.Answer.SequenceEqual(request.Answer)) throw new PracticeDomainException(409, "IDEMPOTENCY_CONFLICT", "幂等键已用于不同答案。");
            return new(duplicate, true, duplicate.AnswerJudgeVersion.Contains("fallback", StringComparison.Ordinal));
        }
        var question = repository.GetQuestion(request.QuestionId) ?? throw PracticeOwnership.NotFound();
        var score = await scorer.ScoreAsync(question, request.Answer, request.ResponseTimeMs, ct);
        var answer = new PracticeAnswer(Guid.NewGuid(), question.QuestionId, request.IdempotencyKey, request.Answer.ToArray(), score.Correct, score.Similarity,
            score.Quality, score.AwardedScore, request.ResponseTimeMs, request.AttemptNumber, score.JudgeVersion, DateTimeOffset.UtcNow);
        repository.SaveSession(session with { Answers = session.Answers.Where(x => x.QuestionId != question.QuestionId).Append(answer).ToArray() });
        return new(answer, false, score.Degraded);
    }
    public async Task<CompletionOutcome> Handle(CompleteSessionCommand request, CancellationToken ct)
    {
        var session = PracticeOwnership.Session(request.SessionId, request.OwnerUserId, repository);
        if (request.IdempotencyKey == Guid.Empty) throw new PracticeDomainException(400, "VALIDATION_ERROR", "idempotencyKey 必填。");
        if (session.Status == PracticeSessionStatus.Completed)
        {
            if (session.CompletionIdempotencyKey != request.IdempotencyKey) throw new PracticeDomainException(409, "SESSION_ALREADY_COMPLETED", "会话已经用另一个幂等键完成。");
            return new(session, new { status = "DUPLICATE" }, true);
        }
        if (session.Status != PracticeSessionStatus.Active || session.Answers.Count == 0) throw new PracticeDomainException(409, "SESSION_NOT_ACTIVE", "活动会话至少作答一题后才能完成。");
        var questions = session.Answers.Select(x => repository.GetQuestion(x.QuestionId)).Where(x => x is not null).Cast<PracticeQuestion>().ToArray();
        var resultId = Guid.NewGuid(); var evidence = await gateway.SubmitEvidenceAsync(session, questions, resultId, request.IdempotencyKey, ct);
        var completed = session with { Status = PracticeSessionStatus.Completed, CompletionIdempotencyKey = request.IdempotencyKey, ResultId = resultId, CompletedAt = DateTimeOffset.UtcNow };
        repository.SaveSession(completed); return new(completed, evidence, false);
    }
}
