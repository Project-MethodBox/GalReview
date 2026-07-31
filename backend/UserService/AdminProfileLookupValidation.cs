public static class AdminProfileLookupValidation
{
    public static bool TryNormalize(
        AdminProfileLookupRequest? request,
        out string[] userIds)
    {
        userIds = [];
        if (request?.UserIds is null)
        {
            return false;
        }
        if (request.UserIds.Length > 500)
        {
            return false;
        }

        userIds = request.UserIds
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        return userIds.All(id => Guid.TryParse(id, out _));
    }
}
