using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;

public sealed class UserProfileUpdateHandlerTests
{
    private const string UserId =
        "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    [Theory]
    [InlineData("")]
    [InlineData("{\"displayName\":")]
    [InlineData("null")]
    [InlineData("{\"displayName\":42}")]
    public async Task Empty_or_malformed_json_returns_contract_400(
        string body)
    {
        var (result, repository) = await Invoke(body);

        AssertValidationFailure(result);
        Assert.Equal(
            "Arabidopsis",
            repository.FindProfile(UserId)?.DisplayName);
    }

    [Theory]
    [InlineData("{\"displayName\":\"   \"}")]
    [InlineData("{\"locale\":\"!\"}")]
    [InlineData(
        "{\"preferredSubjectCodes\":[\"A\",\"B\",\"C\",\"D\",\"E\",\"F\",\"G\",\"H\",\"I\",\"J\",\"K\"]}")]
    [InlineData("{\"preferredSubjectCodes\":[\"AGRONOMY\",\" \"]}")]
    [InlineData("{\"preferredSubjectCodes\":[\"BIO-CHEM\"]}")]
    [InlineData(
        "{\"preferredSubjectCodes\":[\"ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567\"]}")]
    public async Task Invalid_profile_fields_return_contract_400(
        string body)
    {
        var (result, repository) = await Invoke(body);

        AssertValidationFailure(result);
        Assert.Equal(
            "Arabidopsis",
            repository.FindProfile(UserId)?.DisplayName);
    }

    [Fact]
    public async Task Valid_profile_update_still_returns_success_envelope()
    {
        var (result, repository) = await Invoke(
            """
            {
              "displayName": " Updated learner ",
              "locale": "zh-CN",
              "preferredSubjectCodes": ["agronomy"]
            }
            """);

        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(StatusCodes.Status200OK, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var success = Assert.IsType<ApiSuccess>(value.Value);
        Assert.Equal("test-trace", success.TraceId);
        var profile = repository.FindProfile(UserId);
        Assert.NotNull(profile);
        Assert.Equal("Updated learner", profile.DisplayName);
        Assert.Equal(
            ["AGRONOMY"],
            profile.PreferredSubjectCodes);
    }

    private static async Task<(
        IResult Result,
        InMemoryUserRepository Repository)> Invoke(string body)
    {
        var context = new DefaultHttpContext
        {
            TraceIdentifier = "test-trace"
        };
        context.Request.Body = new MemoryStream(
            Encoding.UTF8.GetBytes(body));
        context.Request.ContentType = "application/json";
        var repository = new InMemoryUserRepository();

        var result = await UserProfileUpdateHandler.HandleAsync(
            UserId,
            context,
            repository,
            JsonOptions);
        return (result, repository);
    }

    private static void AssertValidationFailure(IResult result)
    {
        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(StatusCodes.Status400BadRequest, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var failure = Assert.IsType<ApiFailure>(value.Value);
        Assert.Null(failure.Data);
        Assert.Equal("VALIDATION_ERROR", failure.Error.Code);
        Assert.Equal("资料字段不符合要求", failure.Error.Message);
        Assert.Equal("test-trace", failure.TraceId);

        var envelope = JsonSerializer.SerializeToElement(
            failure,
            JsonOptions);
        Assert.Equal(
            JsonValueKind.Null,
            envelope.GetProperty("data").ValueKind);
        Assert.Equal(
            "VALIDATION_ERROR",
            envelope.GetProperty("error").GetProperty("code").GetString());
        Assert.Empty(
            envelope
                .GetProperty("error")
                .GetProperty("details")
                .EnumerateObject());
        Assert.Equal(
            "test-trace",
            envelope.GetProperty("traceId").GetString());
    }
}
