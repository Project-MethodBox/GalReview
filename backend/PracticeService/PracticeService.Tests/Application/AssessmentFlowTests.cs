using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class AssessmentFlowTests
{
    [Fact]
    public async Task Exam_uses_one_question_per_plan_target_and_completion_submits_mastery_evidence()
    {
        var owner = Guid.NewGuid();
        var graphId = Guid.NewGuid();
        var materialId = Guid.NewGuid();
        var repository = new InMemoryPracticeRepository();
        var now = DateTimeOffset.UtcNow;
        var project = repository.CreateProject(new StudyProject(
            Guid.NewGuid(), owner, "算法研习", "CS", [materialId], graphId, Guid.NewGuid(),
            ProjectStatus.Active, 1, now, now));
        var firstPoint = Guid.NewGuid();
        var secondPoint = Guid.NewGuid();
        var gateway = new FakeGateway(owner, graphId,
        [
            new PlanGraphPoint(firstPoint, Guid.NewGuid(), "二叉树", "", [], 0.9, [firstPoint]),
            new PlanGraphPoint(secondPoint, Guid.NewGuid(), "图遍历", "", [], 0.6, [secondPoint])
        ]);
        repository.CreateQuestion(ReadyQuestion(project, firstPoint, "说明二叉树的定义。"));
        repository.CreateQuestion(ReadyQuestion(project, firstPoint, "说明二叉树的节点约束。"));
        repository.CreateQuestion(ReadyQuestion(project, secondPoint, "说明图遍历的含义。"));

        var paper = await new CreateExamPaperHandler(repository, gateway).Handle(
            new CreateExamPaperCommand(owner, project.ProjectId, null, 2, 1800, 42, null, gateway.PlanId, "snapshot-1"),
            CancellationToken.None);

        Assert.Equal(2, paper.QuestionIds.Count);
        Assert.Equal(2, paper.QuestionIds.Select(repository.GetQuestion).Select(question => question!.KnowledgePointId).Distinct().Count());

        var sessions = new SessionHandlers(repository, gateway, new FakeScorer());
        var details = await sessions.Handle(new CreateSessionCommand(
            owner, project.ProjectId, PracticeSessionMode.Exam, gateway.PlanId, "snapshot-1", paper.ExamPaperId,
            2, [], 1800, 42), CancellationToken.None);
        var answered = details.Questions[0];
        await sessions.Handle(new SaveAnswerCommand(owner, details.Session.SessionId, answered.QuestionId,
            answered.CorrectAnswers, 800, 1, Guid.NewGuid()), CancellationToken.None);
        var completed = await sessions.Handle(new CompleteSessionCommand(owner, details.Session.SessionId, Guid.NewGuid()), CancellationToken.None);

        Assert.Equal(PracticeSessionStatus.Completed, completed.Session.Status);
        Assert.Equal(gateway.PlanId, gateway.SubmittedPlanId);
        Assert.Equal([answered.KnowledgePointId!.Value], gateway.SubmittedPointIds);
    }

    private static PracticeQuestion ReadyQuestion(StudyProject project, Guid pointId, string prompt) =>
        PracticeRules.CreateQuestion(project, new QuestionDraft(
            PracticeQuestionKind.Essay, prompt, [], ["答案"], "解析", 5, 3, pointId, [], QuestionStatus.Ready));

    private sealed class FakeScorer : IAnswerScorer
    {
        public Task<ScoreResult> ScoreAsync(PracticeQuestion question, IReadOnlyList<string> answer, int responseTimeMs,
            CancellationToken cancellationToken) => Task.FromResult(new ScoreResult(true, 1, 5, question.Score, "test-v1", false));
    }

    private sealed class FakeGateway(Guid owner, Guid graphId, IReadOnlyList<PlanGraphPoint> points) : IPracticeGateway
    {
        public Guid PlanId { get; } = Guid.NewGuid();
        public Guid? SubmittedPlanId { get; private set; }
        public IReadOnlyList<Guid> SubmittedPointIds { get; private set; } = [];

        public Task<PlanGraphSnapshot> GetPlanAsync(Guid planId, string snapshotVersion, CancellationToken cancellationToken) =>
            Task.FromResult(new PlanGraphSnapshot(planId, snapshotVersion, graphId, owner, "OPEN", "assessment-planner-v1", points));

        public Task<object> SubmitEvidenceAsync(PracticeSession session, IReadOnlyList<PracticeQuestion> questions, Guid resultId,
            Guid idempotencyKey, CancellationToken cancellationToken)
        {
            SubmittedPlanId = session.ReviewPlanId;
            SubmittedPointIds = questions.Select(question => question.KnowledgePointId!.Value).ToArray();
            return Task.FromResult<object>(new { resultId });
        }

        public Task<MaterialText> GetMaterialTextAsync(Guid materialId, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
        public Task<KnowledgeGraphScope> GetGraphScopeAsync(Guid requestedGraphId, Guid ownerUserId, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
    }
}
