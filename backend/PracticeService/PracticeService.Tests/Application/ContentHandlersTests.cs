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
        var gateway = new FakeGateway(owner, materialId,
            "二叉树是一种常用的数据结构。二叉树的每个节点最多具有两个子节点。算法课程使用二叉树讲解递归遍历。");
        var handler = new ContentHandlers(repository, gateway, new FakeBilling());
        var key = Guid.NewGuid();

        var result = await handler.Handle(new GenerateQuestionsCommand(owner, project.ProjectId, key, null, null,
            [PracticeQuestionKind.SingleChoice, PracticeQuestionKind.FillBlank], 2, "recite-question-v1"), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Succeeded, result.Status);
        Assert.Equal(2, result.CreatedCount);
        var questions = repository.ListQuestions(project.ProjectId);
        Assert.All(questions, question =>
        {
            Assert.Equal(QuestionStatus.Draft, question.Status);
            Assert.Single(question.SourceReferences);
            Assert.Equal(materialId, question.SourceReferences[0].MaterialId);
        });
        var choice = Assert.Single(questions, x => x.Kind == PracticeQuestionKind.SingleChoice);
        Assert.Equal("A", Assert.Single(choice.CorrectAnswers));
        Assert.Equal(choice.Options[0].Id, choice.CorrectAnswers[0]);

        var error = await Assert.ThrowsAsync<PracticeDomainException>(() => handler.Handle(
            new GenerateQuestionsCommand(owner, project.ProjectId, key, null, null, [PracticeQuestionKind.Essay], 1, "recite-question-v1"), CancellationToken.None));
        Assert.Equal("IDEMPOTENCY_KEY_REUSED", error.Code);
    }

    [Fact]
    public async Task Exam_import_does_not_invent_answers()
    {
        var owner = Guid.NewGuid();
        var materialId = Guid.NewGuid();
        var repository = new InMemoryPracticeRepository();
        var project = CreateProject(repository, owner, materialId);
        var handler = new ContentHandlers(repository, new FakeGateway(owner, materialId, "1. 请说明什么是二叉树。"), new FakeBilling());

        var result = await handler.Handle(new ImportExamCommand(owner, project.ProjectId, materialId, Guid.NewGuid()), CancellationToken.None);

        Assert.Equal(PracticeJobStatus.Failed, result.Status);
        Assert.Empty(repository.ListQuestions(project.ProjectId));
        Assert.Contains(result.Diagnostics, x => x.Code == "EXAM_STRUCTURE_NOT_FOUND");
    }

    private static StudyProject CreateProject(InMemoryPracticeRepository repository, Guid owner, Guid materialId)
    {
        var now = DateTimeOffset.UtcNow;
        return repository.CreateProject(new StudyProject(Guid.NewGuid(), owner, "算法复习", "CS", [materialId], null,
            Guid.NewGuid(), ProjectStatus.Active, 1, now, now));
    }

    private sealed class FakeGateway(Guid owner, Guid materialId, string text) : IPracticeGateway
    {
        public Task<MaterialText> GetMaterialTextAsync(Guid requestedMaterialId, CancellationToken cancellationToken) =>
            Task.FromResult(requestedMaterialId == materialId
                ? new MaterialText(materialId, owner, text, PracticeRules.Sha256(text), "source-map-1")
                : throw PracticeOwnership.NotFound());

        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken) =>
            Task.FromResult(new PlanGraphSnapshot(planId, snapshotVersion, [new(Guid.NewGuid(), "二叉树")]));

        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId,
            Guid idempotencyKey, CancellationToken cancellationToken) => Task.FromResult<object>(new { resultId });
    }
    private sealed class FakeBilling : ICreditBilling
    {
        public Task ReserveAsync(Guid userId, Guid operationId, string operationType, long estimatedTokenUnits, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task SettleAsync(Guid operationId, long actualTokenUnits, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task ReleaseAsync(Guid operationId, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
