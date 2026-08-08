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
}
