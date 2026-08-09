using PracticeService.Domain;
using Xunit;

namespace PracticeService.Tests.Domain;

public sealed class FacetDecisionPolicyTests
{
    [Fact]
    public void Complete_recall_is_quality_five()
    {
        var result = FacetDecisionPolicy.Decide([
            Facet(FacetVerdict.Entailed), Facet(FacetVerdict.Entailed)
        ], false);

        Assert.Equal(GradingStatus.Decided, result.Status);
        Assert.True(result.Correct);
        Assert.Equal(5, result.Quality);
    }

    [Fact]
    public void Partial_recall_is_quality_two()
    {
        var result = FacetDecisionPolicy.Decide([
            Facet(FacetVerdict.Entailed), Facet(FacetVerdict.Omitted)
        ], false);

        Assert.False(result.Correct);
        Assert.Equal(2, result.Quality);
    }

    [Fact]
    public void Contradiction_is_quality_one()
    {
        var result = FacetDecisionPolicy.Decide([
            Facet(FacetVerdict.Entailed), Facet(FacetVerdict.Contradicted)
        ], false);

        Assert.False(result.Correct);
        Assert.Equal(1, result.Quality);
    }

    [Fact]
    public void Blank_is_quality_zero()
    {
        var result = FacetDecisionPolicy.Decide([], true);

        Assert.False(result.Correct);
        Assert.Equal(0, result.Quality);
    }

    [Fact]
    public void Indeterminate_abstains_without_quality()
    {
        var result = FacetDecisionPolicy.Decide([Facet(FacetVerdict.Indeterminate)], false);

        Assert.Equal(GradingStatus.Abstained, result.Status);
        Assert.Null(result.Correct);
        Assert.Null(result.Quality);
    }

    private static FacetAssessment Facet(FacetVerdict verdict) => new("事实", verdict, 0, 0, 0);
}
