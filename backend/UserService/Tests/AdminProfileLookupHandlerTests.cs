using System.Text.Json;
using Microsoft.AspNetCore.Http;

public sealed class AdminProfileLookupHandlerTests
{
    private const string ExistingUserId =
        "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"userIds\":null}")]
    public void Missing_or_null_user_ids_returns_contract_400(string body)
    {
        var request =
            JsonSerializer.Deserialize<AdminProfileLookupRequest>(
                body,
                JsonOptions);

        var result = Invoke(request);

        AssertValidationFailure(result);
    }

    [Fact]
    public void Null_request_returns_contract_400()
    {
        var result = Invoke(null);

        AssertValidationFailure(result);
    }

    [Fact]
    public void Explicit_empty_array_is_a_valid_empty_query()
    {
        var result = Invoke(new AdminProfileLookupRequest([]));

        var success = AssertSuccess(result);
        Assert.Empty(
            Assert.IsType<List<AdminProfileSummary>>(success.Data));
    }

    [Fact]
    public void Invalid_user_id_returns_contract_400()
    {
        var result = Invoke(
            new AdminProfileLookupRequest(["not-a-uuid"]));

        AssertValidationFailure(result);
    }

    [Fact]
    public void More_than_500_distinct_user_ids_returns_contract_400()
    {
        var userIds = Enumerable.Range(1, 501)
            .Select(index =>
                $"00000000-0000-0000-0000-{index:D12}")
            .ToArray();

        var result = Invoke(new AdminProfileLookupRequest(userIds));

        AssertValidationFailure(result);
    }

    [Fact]
    public void More_than_500_repeated_user_ids_returns_contract_400()
    {
        var userIds = Enumerable.Repeat(ExistingUserId, 501).ToArray();

        var result = Invoke(new AdminProfileLookupRequest(userIds));

        AssertValidationFailure(result);
    }

    [Fact]
    public void Valid_user_ids_return_matching_admin_profiles()
    {
        var result = Invoke(
            new AdminProfileLookupRequest([ExistingUserId]));

        var success = AssertSuccess(result);
        var profile = Assert.Single(
            Assert.IsType<List<AdminProfileSummary>>(success.Data));
        Assert.Equal(ExistingUserId, profile.UserId);
        Assert.Equal("Arabidopsis", profile.DisplayName);
    }

    private static IResult Invoke(AdminProfileLookupRequest? request)
    {
        var context = new DefaultHttpContext
        {
            TraceIdentifier = "lookup-trace"
        };
        return AdminProfileLookupHandler.Handle(
            request,
            context,
            new InMemoryUserRepository());
    }

    private static ApiSuccess AssertSuccess(IResult result)
    {
        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(StatusCodes.Status200OK, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var success = Assert.IsType<ApiSuccess>(value.Value);
        Assert.Equal("lookup-trace", success.TraceId);
        return success;
    }

    private static void AssertValidationFailure(IResult result)
    {
        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(StatusCodes.Status400BadRequest, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var failure = Assert.IsType<ApiFailure>(value.Value);
        Assert.Null(failure.Data);
        Assert.Equal("VALIDATION_ERROR", failure.Error.Code);
        Assert.Equal("userIds 不符合要求", failure.Error.Message);
        Assert.Equal("lookup-trace", failure.TraceId);

        var envelope = JsonSerializer.SerializeToElement(
            failure,
            JsonOptions);
        Assert.Empty(
            envelope
                .GetProperty("error")
                .GetProperty("details")
                .EnumerateObject());
    }
}
