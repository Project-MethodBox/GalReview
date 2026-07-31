using System.Text.Json;

public static class UserProfileUpdateHandler
{
    public static async Task<IResult> HandleAsync(
        string userId,
        HttpContext context,
        IUserRepository users,
        JsonSerializerOptions jsonOptions)
    {
        UpdateUserProfileRequest? request;
        try
        {
            request =
                await JsonSerializer.DeserializeAsync<UpdateUserProfileRequest>(
                    context.Request.Body,
                    jsonOptions,
                    context.RequestAborted);
        }
        catch (JsonException)
        {
            return ValidationFailure(context);
        }

        if (!UserProfileValidation.IsValid(request))
        {
            return ValidationFailure(context);
        }

        var profile = users.UpdateProfile(
            userId,
            UserProfileValidation.Normalize(request!));
        return profile is null
            ? Results.Json(
                ApiFailure.Create(
                    "RESOURCE_NOT_FOUND",
                    "用户资料不存在",
                    context.TraceIdentifier),
                statusCode: StatusCodes.Status404NotFound)
            : Results.Ok(
                ApiSuccess.Create(profile, context.TraceIdentifier));
    }

    private static IResult ValidationFailure(HttpContext context) =>
        Results.Json(
            ApiFailure.Create(
                "VALIDATION_ERROR",
                "资料字段不符合要求",
                context.TraceIdentifier),
            statusCode: StatusCodes.Status400BadRequest);
}
