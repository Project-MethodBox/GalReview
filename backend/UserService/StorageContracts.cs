public interface IUserRepository
{
    bool TryCreate(UserProfile profile);
    UserProfile? FindProfile(string userId);
    List<AdminProfileSummary> FindAdminProfiles(IReadOnlyList<string> userIds);
    bool DeleteProfile(string userId);
    UserProfile? UpdateProfile(string userId, UpdateUserProfileRequest request);
    UserPreferences? FindPreferences(string userId);
    UserPreferences? ReplacePreferences(string userId, UserPreferencesInput request);
}
