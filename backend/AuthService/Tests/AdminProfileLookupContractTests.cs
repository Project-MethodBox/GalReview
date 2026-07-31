using System.Text;
using Xunit;

public sealed class AdminProfileLookupContractTests
{
    private const string UserId =
        "10000000-0000-4000-8000-000000000001";

    [Fact]
    public async Task Valid_empty_envelope_returns_empty_lookup()
    {
        using var content = Json(
            """{"data":[],"meta":{},"traceId":"trace-1"}""");

        var result = await AdminProfileLookupContract.ReadAsync(
            content,
            [UserId]);

        Assert.Empty(result);
    }

    [Fact]
    public async Task Valid_profile_is_projected()
    {
        using var content = Json(
            $$"""
              {
                "data":[{
                  "userId":"{{UserId}}",
                  "displayName":"Student"
                }],
                "meta":{},
                "traceId":"trace-2"
              }
              """);

        var result = await AdminProfileLookupContract.ReadAsync(
            content,
            [UserId]);

        Assert.Equal("Student", result[UserId]);
    }

    [Theory]
    [InlineData("{")]
    [InlineData("{}")]
    [InlineData("""{"data":null,"meta":{},"traceId":"trace"}""")]
    [InlineData("""{"data":[],"meta":{"page":1},"traceId":"trace"}""")]
    [InlineData("""{"data":[],"meta":{},"traceId":""}""")]
    public async Task Invalid_json_or_envelope_is_rejected(
        string json)
    {
        using var content = Json(json);

        await Assert.ThrowsAsync<UpstreamContractException>(
            () => AdminProfileLookupContract.ReadAsync(
                content,
                [UserId]));
    }

    [Fact]
    public async Task Duplicate_or_unrequested_profile_is_rejected()
    {
        const string otherUserId =
            "20000000-0000-4000-8000-000000000002";
        using var content = Json(
            $$"""
              {
                "data":[{
                  "userId":"{{otherUserId}}",
                  "displayName":"Other"
                }],
                "meta":{},
                "traceId":"trace-3"
              }
              """);

        await Assert.ThrowsAsync<UpstreamContractException>(
            () => AdminProfileLookupContract.ReadAsync(
                content,
                [UserId]));
    }

    private static StringContent Json(string value) =>
        new(
            value,
            Encoding.UTF8,
            "application/json");
}
