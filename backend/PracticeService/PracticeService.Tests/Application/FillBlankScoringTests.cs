using PracticeService.Application;
using PracticeService.Domain;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class FillBlankScoringTests
{
    [Fact]
    public async Task Equivalent_number_tuple_and_term_variants_are_all_correct()
    {
        var scorer = new AutomaticAnswerScorer(new UnexpectedAdjudicator());
        var question = Question(["2", "(1,3)", "G+"]);

        var result = await scorer.ScoreAsync(
            question,
            ["两个", "( 1，3 )。", "革兰氏阳性"],
            1_000,
            TestContext.Current.CancellationToken);

        Assert.Equal(GradingStatus.Decided, result.Status);
        Assert.True(result.Correct);
        Assert.Equal(RecallOutcome.Perfect, result.Outcome);
        Assert.Equal(5, result.Quality);
        Assert.Contains(FillBlankAnswerEquivalence.Version, result.JudgeVersion);
    }

    [Fact]
    public async Task One_non_equivalent_blank_is_partial_instead_of_correct()
    {
        var scorer = new AutomaticAnswerScorer(new UnexpectedAdjudicator());
        var question = Question(["2", "(1,3)", "G+"]);

        var result = await scorer.ScoreAsync(
            question,
            ["二", "(3,1)", "G-"],
            1_000,
            TestContext.Current.CancellationToken);

        Assert.Equal(GradingStatus.Decided, result.Status);
        Assert.False(result.Correct);
        Assert.Equal(RecallOutcome.Partial, result.Outcome);
        Assert.Equal(2, result.Quality);
    }

    private static PracticeQuestion Question(IReadOnlyList<string> answers)
    {
        var now = DateTimeOffset.UtcNow;
        return new(
            Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), PracticeQuestionKind.FillBlank,
            "请依次填写数量、坐标与菌型。", [], answers, null, 3, 2, null, [],
            QuestionStatus.Ready, 1, now, now);
    }

    private sealed class UnexpectedAdjudicator : IFacetAdjudicator
    {
        public Task<FacetAdjudicationBatch> AdjudicateAsync(
            string answer,
            IReadOnlyList<ReferenceFacet> facets,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Fill-blank scoring must not call the NLI adjudicator.");
    }
}
