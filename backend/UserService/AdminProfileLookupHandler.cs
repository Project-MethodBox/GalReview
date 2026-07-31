public static class AdminProfileLookupHandler
{
    public static IResult Handle(
        AdminProfileLookupRequest? request,
        HttpContext context,
        IUserRepository users)
    {
        if (!AdminProfileLookupValidation.TryNormalize(
                request,
                out var userIds))
        {
            return Results.Json(
                ApiFailure.Create(
                    "VALIDATION_ERROR",
                    "userIds 不符合要求",
                    context.TraceIdentifier),
                statusCode: StatusCodes.Status400BadRequest);
        }

        return Results.Ok(
            ApiSuccess.Create(
                users.FindAdminProfiles(userIds),
                context.TraceIdentifier));
    }
}
