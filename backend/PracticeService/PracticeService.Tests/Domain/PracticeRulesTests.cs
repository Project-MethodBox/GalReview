using PracticeService.Domain;
using Xunit;

namespace PracticeService.Tests.Domain;

public sealed class PracticeRulesTests
{
    [Theory]
    [InlineData("正确", "true")]
    [InlineData("FALSE", "false")]
    [InlineData("×", "false")]
    public void True_false_normalization_preserves_ReciteHelper_compatibility(string input, string expected) =>
        Assert.Equal(expected, PracticeRules.NormalizeTrueFalse(input));

    [Fact]
    public void Choice_answer_must_reference_an_existing_option()
    {
        var error = Assert.Throws<PracticeDomainException>(() => PracticeRules.ValidateAnswerShape(
            PracticeQuestionKind.SingleChoice, [new("A", "一"), new("B", "二")], ["C"]));
        Assert.Equal("QUESTION_ANSWER_INVALID", error.Code);
    }

    [Fact]
    public void Graph_project_requires_a_knowledge_point_before_question_is_ready()
    {
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "测试", "CS", [Guid.NewGuid()], Guid.NewGuid(), Guid.NewGuid(), ProjectStatus.Active, 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var error = Assert.Throws<PracticeDomainException>(() => PracticeRules.CreateQuestion(project,
            new QuestionDraft(PracticeQuestionKind.Essay, "题目", [], ["答案"], null, 5, 3, null, [], QuestionStatus.Ready)));
        Assert.Equal("QUESTION_BINDING_REQUIRED", error.Code);
    }

    [Fact]
    public void Seeded_selection_is_replayable()
    {
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "测试", "CS", [Guid.NewGuid()], null, Guid.NewGuid(), ProjectStatus.Active, 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var questions = Enumerable.Range(0, 12).Select(i => PracticeRules.CreateQuestion(project,
            new QuestionDraft(PracticeQuestionKind.Essay, $"题目 {i}", [], ["答案"], null, 5, 3, null, [], QuestionStatus.Ready))).ToArray();
        Assert.Equal(PracticeRules.SelectQuestions(questions, 5, 42).Select(x => x.QuestionId), PracticeRules.SelectQuestions(questions, 5, 42).Select(x => x.QuestionId));
    }

    [Fact]
    public void Similarity_uses_only_the_zero_to_one_scale()
    {
        Assert.Equal(1, PracticeRules.LevenshteinSimilarity("二叉树", "二叉树"));
        Assert.InRange(PracticeRules.LevenshteinSimilarity("二叉树", "树"), 0, 1);
        Assert.Equal(0, PracticeRules.LevenshteinSimilarity("", "答案"));
    }

    [Fact]
    public void Smart_selection_returns_one_replayable_question_per_target_point()
    {
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "测试", "CS", [Guid.NewGuid()], Guid.NewGuid(), Guid.NewGuid(), ProjectStatus.Active, 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var firstPoint = Guid.NewGuid(); var secondPoint = Guid.NewGuid();
        var targets = new[]
        {
            new PlanGraphPoint(firstPoint, Guid.NewGuid(), "第一点", "", [], 0.8, [firstPoint]),
            new PlanGraphPoint(secondPoint, Guid.NewGuid(), "第二点", "", [], 0.2, [secondPoint])
        };
        var questions = new[]
        {
            ReadyQuestion(project, "第一点 A", firstPoint), ReadyQuestion(project, "第一点 B", firstPoint), ReadyQuestion(project, "第二点", secondPoint)
        };

        var selected = PracticeRules.SelectSmartQuestions(questions, 2, 42, targets);

        Assert.Equal(2, selected.Count);
        Assert.Equal(2, selected.Select(question => question.KnowledgePointId).Distinct().Count());
        Assert.Equal(selected.Select(question => question.QuestionId), PracticeRules.SelectSmartQuestions(questions, 2, 42, targets).Select(question => question.QuestionId));
    }

    [Fact]
    public void Smart_selection_reports_exact_coverage_gap()
    {
        var project = new StudyProject(Guid.NewGuid(), Guid.NewGuid(), "测试", "CS", [Guid.NewGuid()], Guid.NewGuid(), Guid.NewGuid(), ProjectStatus.Active, 1, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
        var missingPoint = Guid.NewGuid();
        var target = new PlanGraphPoint(missingPoint, Guid.NewGuid(), "缺题知识点", "", [], 1, [missingPoint]);

        var error = Assert.Throws<PracticeDomainException>(() => PracticeRules.SelectSmartQuestions([], 1, 42, [target]));

        Assert.Equal("QUESTION_COVERAGE_GAP", error.Code);
    }

    private static PracticeQuestion ReadyQuestion(StudyProject project, string prompt, Guid pointId) =>
        PracticeRules.CreateQuestion(project, new QuestionDraft(PracticeQuestionKind.Essay, prompt, [], ["答案"], null, 5, 3, pointId, [], QuestionStatus.Ready));
}
