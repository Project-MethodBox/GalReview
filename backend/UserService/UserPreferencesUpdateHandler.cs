using System.Text.Json;
using System.Text.Json.Serialization;

public static class UserPreferencesUpdateHandler
{
    public static async Task<IResult> HandleAsync(
        string userId,
        HttpContext context,
        IUserRepository users,
        JsonSerializerOptions jsonOptions)
    {
        UserPreferencesUpdateRequest? request;
        try
        {
            var strictJsonOptions = new JsonSerializerOptions(jsonOptions)
            {
                NumberHandling = JsonNumberHandling.Strict
            };
            request =
                await JsonSerializer.DeserializeAsync<UserPreferencesUpdateRequest>(
                    context.Request.Body,
                    strictJsonOptions,
                    context.RequestAborted);
        }
        catch (JsonException)
        {
            return JsonValidationFailure(context);
        }

        if (request?.DailyGoalMinutes is null ||
            request.ContentDifficulty is null ||
            request.ReducedMotion is null)
        {
            return JsonValidationFailure(context);
        }

        if (request.DailyGoalMinutes.Value is < 5 or > 180 ||
            request.ContentDifficulty is not (
                "BASIC" or "STANDARD" or "ADVANCED"))
        {
            return Results.Json(
                ApiFailure.Create(
                    "BUSINESS_RULE_VIOLATION",
                    "偏好设置不符合允许范围",
                    context.TraceIdentifier),
                statusCode: StatusCodes.Status422UnprocessableEntity);
        }

        var preferences = users.ReplacePreferences(
            userId,
            new UserPreferencesInput(
                request.DailyGoalMinutes.Value,
                request.ContentDifficulty,
                request.ReducedMotion.Value));
        return preferences is null
            ? Results.Json(
                ApiFailure.Create(
                    "RESOURCE_NOT_FOUND",
                    "用户资料不存在",
                    context.TraceIdentifier),
                statusCode: StatusCodes.Status404NotFound)
            : Results.Ok(
                ApiSuccess.Create(preferences, context.TraceIdentifier));
    }

    private static IResult JsonValidationFailure(HttpContext context) =>
        Results.Json(
            ApiFailure.Create(
                "VALIDATION_ERROR",
                "偏好设置请求 JSON 不符合要求",
                context.TraceIdentifier),
            statusCode: StatusCodes.Status400BadRequest);
}

public sealed record UserPreferencesUpdateRequest(
    int? DailyGoalMinutes,
    string? ContentDifficulty,
    bool? ReducedMotion);
