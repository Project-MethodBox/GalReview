using ModelService.Domain;
using PracticeService.Application;
using PracticeService.Domain;
using Xunit;
using ModelFacetVerdict = ModelService.Domain.FacetVerdict;

namespace ModelService.Tests.Integration;

public sealed class ModelScoringAssetTests
{
    [Theory]
    [InlineData("天空是蓝色的。", "天空是蓝色的。", ModelFacetVerdict.Entailed)]
    [InlineData("天空不是蓝色的。", "天空是蓝色的。", ModelFacetVerdict.Contradicted)]
    [InlineData("土壤里有微生物。", "天空是蓝色的。", ModelFacetVerdict.Indeterminate)]
    public async Task Nli_pair_encoding_and_labels_are_stable(
        string premise,
        string hypothesis,
        ModelFacetVerdict expected)
    {
        using var engine = ModelTestRuntime.Create();

        var result = await engine.InferAsync(
            premise, [hypothesis], TestContext.Current.CancellationToken);

        Assert.True(result.Available);
        Assert.Equal(expected, Assert.Single(result.Facets).Verdict);
    }

    [Fact]
    public async Task Complete_paraphrase_is_not_reduced_to_string_similarity()
    {
        using var engine = ModelTestRuntime.Create();
        var scorer = new AutomaticAnswerScorer(new PracticeFacetAdjudicatorAdapter(engine));
        var now = DateTimeOffset.UtcNow;
        var question = new PracticeQuestion(
            Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), PracticeQuestionKind.TermDefinition,
            "请解释“腐食性食物链”。", [],
            ["是指以死亡有机体或排泄物为能量来源，在微生物或原生动物的参与下，经腐烂、分解将其还原为无机物并从中取得能量的食物链。"],
            null, 4, 3, Guid.NewGuid(), [], QuestionStatus.Ready, 1, now, now);

        var result = await scorer.ScoreAsync(question,
            ["从尸体或排泄物开始，经细菌和原生动物分解，最终还原成无机物并获取能量的食物链。"],
            12_000, TestContext.Current.CancellationToken);

        Assert.Equal(GradingStatus.Decided, result.Status);
        Assert.True(result.Correct);
        Assert.Equal(5, result.Quality);
        Assert.Null(result.Similarity);
    }
}
