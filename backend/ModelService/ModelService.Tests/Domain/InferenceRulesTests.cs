using ModelService.Domain;
using Xunit;

namespace ModelService.Tests.Domain;

public sealed class InferenceRulesTests
{
    [Fact]
    public void Valid_input_is_trimmed_without_changing_claim_order()
    {
        var result = InferenceRules.Validate(" 答案 ", [" 事实一 ", "事实二"]);

        Assert.Equal("答案", result.Answer);
        Assert.Equal(["事实一", "事实二"], result.Claims);
    }

    [Fact]
    public void Duplicate_claims_are_rejected()
    {
        var error = Assert.Throws<ModelServiceException>(() =>
            InferenceRules.Validate("答案", ["事实", "事实"]));

        Assert.Equal("VALIDATION_ERROR", error.Code);
    }

    [Fact]
    public void More_than_twelve_claims_are_rejected()
    {
        var error = Assert.Throws<ModelServiceException>(() =>
            InferenceRules.Validate("答案", Enumerable.Range(0, 13).Select(index => $"事实{index}").ToArray()));

        Assert.Equal(400, error.StatusCode);
    }
}
