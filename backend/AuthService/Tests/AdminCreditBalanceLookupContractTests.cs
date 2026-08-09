using System.Text;
using Xunit;

public sealed class AdminCreditBalanceLookupContractTests
{
    private const string UserId =
        "10000000-0000-4000-8000-000000000001";

    [Fact]
    public async Task Valid_balance_returns_available_credits()
    {
        using var content = Json(
            $$"""
              {
                "data":[{
                  "userId":"{{UserId}}",
                  "balance":2.5,
                  "available":2.25,
                  "held":0.25,
                  "updatedAt":"2026-08-09T00:00:00Z"
                }],
                "meta":{},
                "traceId":"trace-1"
              }
              """);

        var result = await AdminCreditBalanceLookupContract.ReadAsync(
            content,
            [UserId]);

        Assert.Equal(2.25m, result[UserId]);
    }

    [Theory]
    [InlineData("{")]
    [InlineData("{}")]
    [InlineData("""{"data":[],"meta":{},"traceId":"trace"}""")]
    [InlineData("""{"data":null,"meta":{},"traceId":"trace"}""")]
    public async Task Invalid_or_incomplete_response_is_rejected(string json)
    {
        using var content = Json(json);

        await Assert.ThrowsAsync<UpstreamContractException>(
            () => AdminCreditBalanceLookupContract.ReadAsync(
                content,
                [UserId]));
    }

    [Fact]
    public async Task Invalid_balance_math_is_rejected()
    {
        using var content = Json(
            $$"""
              {
                "data":[{
                  "userId":"{{UserId}}",
                  "balance":2.5,
                  "available":2.5,
                  "held":0.25,
                  "updatedAt":"2026-08-09T00:00:00Z"
                }],
                "meta":{},
                "traceId":"trace-2"
              }
              """);

        await Assert.ThrowsAsync<UpstreamContractException>(
            () => AdminCreditBalanceLookupContract.ReadAsync(
                content,
                [UserId]));
    }

    private static StringContent Json(string value) =>
        new(value, Encoding.UTF8, "application/json");
}
