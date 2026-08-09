using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class ContentHandlersTests
{
    [Fact]
    public async Task Generation_creates_source_grounded_drafts_and_rejects_idempotency_payload_change()
    {
        var owner = Guid.NewGuid();
        var materialId = Guid.NewGuid();
        var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var pointId = Guid.NewGuid();
        var gateway = new FakeGateway(owner, materialId, project.GraphId!.Value, pointId,
            "二叉树是一种常用的数据结构。二叉树的每个节点最多具有两个子节点。算法课程使用二叉树讲解递归遍历。");
        var handler = CreateHandler(repository, gateway);
        var key = Guid.NewGuid();

        var result = await handler.Handle(new GenerateQuestionsCommand(owner, project.ProjectId, key, gateway.PlanId, "snapshot-1",
            [PracticeQuestionKind.SingleChoice, PracticeQuestionKind.FillBlank], 2, "recite-question-v2"), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Succeeded, result.Status);
        Assert.Equal(2, result.CreatedCount);
        var questions = repository.ListQuestions(project.ProjectId);
        Assert.All(questions, question =>
        {
            Assert.Equal(QuestionStatus.Ready, question.Status);
            Assert.Single(question.SourceReferences);
            Assert.Equal(materialId, question.SourceReferences[0].MaterialId);
            Assert.Equal(pointId, question.KnowledgePointId);
        });
        var choice = Assert.Single(questions, x => x.Kind == PracticeQuestionKind.SingleChoice);
        Assert.Equal("A", Assert.Single(choice.CorrectAnswers));
        Assert.Equal(choice.Options[0].Id, choice.CorrectAnswers[0]);

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new GenerateQuestionsCommand(owner, project.ProjectId, key, gateway.PlanId, "snapshot-1", [PracticeQuestionKind.Essay], 1, "recite-question-v2"), CancellationToken.None));
        Assert.Equal("IDEMPOTENCY_KEY_REUSED", error.Code);
    }

    [Fact]
    public async Task Generation_cycles_requested_classic_kinds_before_repeating_a_kind()
    {
        var owner = Guid.NewGuid();
        var materialId = Guid.NewGuid();
        var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var gateway = new FakeGateway(owner, materialId, project.GraphId!.Value, Guid.NewGuid(),
            "二叉树是一种常用的数据结构。递归遍历访问树的节点。栈保存尚未处理的路径。队列支持层次搜索。", 4);
        var handler = CreateHandler(repository, gateway);
        PracticeQuestionKind[] classicKinds =
        [
            PracticeQuestionKind.SingleChoice,
            PracticeQuestionKind.FillBlank,
            PracticeQuestionKind.TermDefinition,
            PracticeQuestionKind.Essay
        ];

        var result = await handler.Handle(new GenerateQuestionsCommand(owner, project.ProjectId, Guid.NewGuid(),
            gateway.PlanId, "snapshot-1", classicKinds, classicKinds.Length, "recite-question-v2"), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Succeeded, result.Status);
        var questions = repository.ListQuestions(project.ProjectId);
        Assert.Equal(classicKinds.Length, questions.Count);
        Assert.Equal(classicKinds.Order(), questions.Select(question => question.Kind).Order());
        Assert.Equal(classicKinds.Length, questions.Select(question => question.KnowledgePointId).Distinct().Count());
    }

    [Fact]
    public async Task Generation_rejects_plan_from_another_graph()
    {
        var owner = Guid.NewGuid(); var materialId = Guid.NewGuid(); var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var gateway = new FakeGateway(owner, materialId, Guid.NewGuid(), Guid.NewGuid(), "二叉树是一种数据结构。");
        var handler = CreateHandler(repository, gateway);

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new GenerateQuestionsCommand(owner, project.ProjectId, Guid.NewGuid(), gateway.PlanId, "snapshot-1", [PracticeQuestionKind.Essay], 1, "recite-question-v2"), CancellationToken.None));

        Assert.Equal("PROJECT_PLAN_GRAPH_MISMATCH", error.Code);
        Assert.Empty(repository.ListQuestions(project.ProjectId));
    }

    [Fact]
    public async Task Generation_does_not_bind_semantically_unrelated_source_by_position()
    {
        var owner = Guid.NewGuid(); var materialId = Guid.NewGuid(); var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var gateway = new FakeGateway(owner, materialId, project.GraphId!.Value, Guid.NewGuid(), "线性代数讨论矩阵与向量的运算规则。");
        var handler = CreateHandler(repository, gateway);

        var result = await handler.Handle(new GenerateQuestionsCommand(owner, project.ProjectId, Guid.NewGuid(), gateway.PlanId, "snapshot-1",
            [PracticeQuestionKind.Essay], 1, "recite-question-v2"), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Failed, result.Status);
        Assert.Contains(result.Diagnostics, diagnostic => diagnostic.Code == "KNOWLEDGE_POINT_SOURCE_NOT_FOUND");
        Assert.Empty(repository.ListQuestions(project.ProjectId));
    }

    [Fact]
    public async Task Exam_import_does_not_invent_answers()
    {
        var owner = Guid.NewGuid();
        var materialId = Guid.NewGuid();
        var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var handler = CreateHandler(repository, new FakeGateway(owner, materialId, project.GraphId!.Value, Guid.NewGuid(), "1. 请说明什么是二叉树。"));

        var result = await handler.Handle(new ImportExamCommand(owner, project.ProjectId, materialId, Guid.NewGuid()), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Failed, result.Status);
        Assert.Empty(repository.ListQuestions(project.ProjectId));
        Assert.Contains(result.Diagnostics, x => x.Code == "EXAM_STRUCTURE_NOT_FOUND");
    }

    private static StudyProject CreateProject(InMemoryPracticeRepository repository, Guid owner, Guid materialId)
    {
        var now = DateTimeOffset.UtcNow;
        return repository.CreateProject(new StudyProject(Guid.NewGuid(), owner, "算法复习", "CS", [materialId], Guid.NewGuid(),
            Guid.NewGuid(), ProjectStatus.Active, 1, now, now));
    }

    private static ContentHandlers CreateHandler(InMemoryPracticeRepository repository, IPracticeGateway gateway) =>
        new(repository, gateway, new FakeBilling(), new FakeQuestionGenerator());

    private sealed class FakeGateway(Guid owner, Guid materialId, Guid graphId, Guid pointId, string text, int pointCount = 1) : IPracticeGateway
    {
        public Guid PlanId { get; } = Guid.NewGuid();
        public Task<MaterialText> GetMaterialTextAsync(Guid requestedMaterialId, CancellationToken cancellationToken) =>
            Task.FromResult(requestedMaterialId == materialId
                ? new MaterialText(materialId, owner, text, PracticeRules.Sha256(text), "source-map-1")
                : throw PracticeOwnership.NotFound());

        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken) =>
            Task.FromResult(new PlanGraphSnapshot(planId, snapshotVersion, graphId, owner, "OPEN", "assessment-planner-v1",
                Enumerable.Range(0, pointCount)
                    .Select(index => index == 0 ? pointId : Guid.NewGuid())
                    .Select(id => new PlanGraphPoint(id, Guid.NewGuid(), "二叉树", "二叉树的定义与性质", ["二叉树"], 1, [id]))
                    .ToArray()));

        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId,
            Guid idempotencyKey, CancellationToken cancellationToken) => Task.FromResult<object>(new { resultId });
        public Task<KnowledgeGraphScope> GetGraphScopeAsync(Guid requestedGraphId, Guid ownerUserId, CancellationToken cancellationToken) =>
            Task.FromResult(new KnowledgeGraphScope(requestedGraphId, materialId, null, owner, []));
    }
    private sealed class FakeBilling : ICreditBilling
    {
        public Task ReserveAsync(Guid userId, Guid operationId, string operationType, long estimatedTokenUnits, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task SettleAsync(Guid operationId, long actualTokenUnits, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task ReleaseAsync(Guid operationId, CancellationToken cancellationToken) => Task.CompletedTask;
    }

    private sealed class FakeQuestionGenerator : IPracticeQuestionGenerator
    {
        public QuestionGenerationEstimate Estimate(QuestionGenerationInput input) =>
            new(input.RequestedTargetCount ?? 1, 1, "TEST");

        public Task<QuestionGenerationOutput> GenerateAsync(QuestionGenerationInput input, CancellationToken cancellationToken)
        {
            var count = input.RequestedTargetCount ?? 1;
            if (!input.Materials.Any(material => material.Text.Contains("二叉树", StringComparison.Ordinal)))
                return Task.FromResult(new QuestionGenerationOutput([],
                    [new(null, "KNOWLEDGE_POINT_SOURCE_NOT_FOUND", "未找到来源。", false)], 1, "TEST"));
            var kinds = input.Kinds.Count == 0
                ? new[] { PracticeQuestionKind.SingleChoice, PracticeQuestionKind.FillBlank, PracticeQuestionKind.TermDefinition, PracticeQuestionKind.Essay }
                : input.Kinds;
            var material = input.Materials[0];
            var source = new SourceReference(material.MaterialId, 0, material.Text.Length, material.SourceMapVersion, PracticeRules.Sha256(material.Text));
            var drafts = Enumerable.Range(0, count).Select(index =>
            {
                var kind = kinds[index % kinds.Count];
                var point = input.Points[index % input.Points.Count];
                return kind switch
                {
                    PracticeQuestionKind.SingleChoice => new QuestionDraft(kind, $"二叉树题目 {index}？",
                        [new("A", "最多两个子节点"), new("B", "没有节点")], ["A"], null, 3, 2, point.KnowledgePointId, [source], QuestionStatus.Ready),
                    PracticeQuestionKind.FillBlank => new QuestionDraft(kind, $"二叉树每个节点最多有 ____ 个子节点（{index}）。", [], ["两个"], null, 2, 2, point.KnowledgePointId, [source], QuestionStatus.Ready),
                    PracticeQuestionKind.TermDefinition => new QuestionDraft(kind, $"请解释二叉树（{index}）。", [], ["每个节点最多具有两个子节点的数据结构"], null, 4, 3, point.KnowledgePointId, [source], QuestionStatus.Ready),
                    _ => new QuestionDraft(PracticeQuestionKind.Essay, $"请说明二叉树的性质（{index}）。", [], ["每个节点最多具有两个子节点"], null, 5, 3, point.KnowledgePointId, [source], QuestionStatus.Ready)
                };
            }).ToArray();
            return Task.FromResult(new QuestionGenerationOutput(drafts, [], 1, "TEST"));
        }
    }
}
