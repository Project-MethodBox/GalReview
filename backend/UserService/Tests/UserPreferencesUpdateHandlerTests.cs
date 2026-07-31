using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;

public sealed class UserPreferencesUpdateHandlerTests
{
    private const string UserId =
        "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    [Theory]
    [InlineData("")]
    [InlineData("{\"dailyGoalMinutes\":")]
    [InlineData("null")]
    [InlineData(
        "{\"dailyGoalMinutes\":\"30\",\"contentDifficulty\":\"STANDARD\",\"reducedMotion\":false}")]
    [InlineData(
        "{\"dailyGoalMinutes\":30,\"contentDifficulty\":\"STANDARD\",\"reducedMotion\":\"false\"}")]
    [InlineData("{}")]
    [InlineData(
        "{\"dailyGoalMinutes\":30,\"contentDifficulty\":\"STANDARD\"}")]
    [InlineData(
        "{\"contentDifficulty\":\"STANDARD\",\"reducedMotion\":false}")]
    [InlineData(
        "{\"dailyGoalMinutes\":30,\"reducedMotion\":false}")]
    public async Task Invalid_json_shape_returns_contract_400(string body)
    {
        var (result, repository) = await Invoke(body);

        AssertFailure(
            result,
            StatusCodes.Status400BadRequest,
            "VALIDATION_ERROR",
            "偏好设置请求 JSON 不符合要求");
        Assert.Equal(
            30,
            repository.FindPreferences(UserId)?.DailyGoalMinutes);
    }

    [Theory]
    [InlineData(
        "{\"dailyGoalMinutes\":4,\"contentDifficulty\":\"STANDARD\",\"reducedMotion\":false}")]
    [InlineData(
        "{\"dailyGoalMinutes\":181,\"contentDifficulty\":\"STANDARD\",\"reducedMotion\":false}")]
    [InlineData(
        "{\"dailyGoalMinutes\":30,\"contentDifficulty\":\"EXPERT\",\"reducedMotion\":false}")]
    public async Task Domain_rule_violation_remains_contract_422(string body)
    {
        var (result, repository) = await Invoke(body);

        AssertFailure(
            result,
            StatusCodes.Status422UnprocessableEntity,
            "BUSINESS_RULE_VIOLATION",
            "偏好设置不符合允许范围");
        Assert.Equal(
            30,
            repository.FindPreferences(UserId)?.DailyGoalMinutes);
    }

    [Fact]
    public async Task Valid_preferences_update_still_returns_success_envelope()
    {
        var (result, repository) = await Invoke(
            """
            {
              "dailyGoalMinutes": 45,
              "contentDifficulty": "ADVANCED",
              "reducedMotion": true
            }
            """);

        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(StatusCodes.Status200OK, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var success = Assert.IsType<ApiSuccess>(value.Value);
        Assert.Equal("preference-trace", success.TraceId);
        var preferences = repository.FindPreferences(UserId);
        Assert.NotNull(preferences);
        Assert.Equal(45, preferences.DailyGoalMinutes);
        Assert.Equal("ADVANCED", preferences.ContentDifficulty);
        Assert.True(preferences.ReducedMotion);
    }

    private static async Task<(
        IResult Result,
        InMemoryUserRepository Repository)> Invoke(string body)
    {
        var context = new DefaultHttpContext
        {
            TraceIdentifier = "preference-trace"
        };
        context.Request.Body = new MemoryStream(
            Encoding.UTF8.GetBytes(body));
        context.Request.ContentType = "application/json";
        var repository = new InMemoryUserRepository();

        var result = await UserPreferencesUpdateHandler.HandleAsync(
            UserId,
            context,
            repository,
            JsonOptions);
        return (result, repository);
    }

    private static void AssertFailure(
        IResult result,
        int expectedStatus,
        string expectedCode,
        string expectedMessage)
    {
        var status = Assert.IsAssignableFrom<IStatusCodeHttpResult>(result);
        Assert.Equal(expectedStatus, status.StatusCode);
        var value = Assert.IsAssignableFrom<IValueHttpResult>(result);
        var failure = Assert.IsType<ApiFailure>(value.Value);
        Assert.Null(failure.Data);
        Assert.Equal(expectedCode, failure.Error.Code);
        Assert.Equal(expectedMessage, failure.Error.Message);
        Assert.Equal("preference-trace", failure.TraceId);

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
