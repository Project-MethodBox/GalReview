using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class QuestionBindingTests
{
    [Fact]
    public async Task Existing_grounded_draft_is_bound_and_promoted_by_the_existing_update_command()
    {
        var owner = Guid.NewGuid(); var graphId = Guid.NewGuid(); var materialId = Guid.NewGuid();
        var point = new PlanGraphPoint(Guid.NewGuid(), Guid.NewGuid(), "第二性比（次级性比）", "", ["第二性比"], 0, [],
            [new KnowledgePointSource(materialId, 0, 12)]);
        const string text = "名词解释\n1. 第二性比：出生时同一世代雌雄个体数目的比例。";
        var source = new SourceReference(materialId, 0, text.Length, "source-map-1", PracticeRules.Sha256(text));
        var repository = new InMemoryPracticeRepository(); var now = DateTimeOffset.UtcNow;
        var project = repository.CreateProject(new StudyProject(Guid.NewGuid(), owner, "动物生态学", "ECOLOGY",
            [materialId], graphId, Guid.NewGuid(), ProjectStatus.Active, 1, now, now));
        var current = repository.CreateQuestion(PracticeRules.CreateQuestion(project,
            new QuestionDraft(PracticeQuestionKind.TermDefinition, "请解释“第二性比”。", [],
                ["出生时同一世代雌雄个体数目的比例"], null, 4, 3, null, [source], QuestionStatus.Draft)));
        var gateway = new BindingGateway(owner, graphId, project.ProjectId, materialId, text, point);

        var updated = await new QuestionHandlers(repository, gateway).Handle(
            new UpdateQuestionCommand(owner, current.QuestionId,
                new QuestionInput(current.Kind, current.Prompt, current.Options, current.CorrectAnswers,
                    current.Explanation, current.Score, current.Difficulty, null, current.SourceReferences,
                    QuestionStatus.Ready, current.Version)), CancellationToken.None);

        Assert.Equal(point.KnowledgePointId, updated.KnowledgePointId);
        Assert.Equal(QuestionStatus.Ready, updated.Status);
        Assert.Equal(current.Version + 1, updated.Version);
    }

    private sealed class BindingGateway(Guid owner, Guid graphId, Guid projectId, Guid materialId, string text, PlanGraphPoint point) : IPracticeGateway
    {
        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken) =>
            Task.FromResult(new PlanGraphSnapshot(planId, snapshotVersion, graphId, owner, "OPEN", "test", [point]));
        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId,
            Guid idempotencyKey, CancellationToken cancellationToken) => Task.FromResult<object>(new { resultId });
        public Task<MaterialText> GetMaterialTextAsync(Guid requestedMaterialId, CancellationToken cancellationToken) =>
            Task.FromResult(new MaterialText(materialId, owner, text, PracticeRules.Sha256(text), "source-map-1"));
        public Task<KnowledgeGraphScope> GetGraphScopeAsync(Guid requestedGraphId, Guid ownerUserId, CancellationToken cancellationToken) =>
            Task.FromResult(new KnowledgeGraphScope(graphId, materialId, projectId, owner, [point]));
    }
}
