public sealed class InMemoryUserRepository : IUserRepository
{
    private const string MockUserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    private readonly object _sync = new();
    private readonly Dictionary<string, UserProfile> _profiles = new(StringComparer.Ordinal);
    private readonly Dictionary<string, UserPreferences> _preferences = new(StringComparer.Ordinal);

    public InMemoryUserRepository()
    {
        var createdAt = new DateTimeOffset(2026, 7, 27, 8, 0, 0, TimeSpan.Zero);
        _profiles[MockUserId] = new UserProfile(MockUserId, "Arabidopsis", null, "zh-CN", ["AGRONOMY", "MEDICINE"], createdAt, createdAt);
        _preferences[MockUserId] = new UserPreferences(30, "STANDARD", false, createdAt);
    }

    public bool TryCreate(UserProfile profile)
    {
        lock (_sync)
        {
            if (_profiles.ContainsKey(profile.UserId)) return false;
            _profiles[profile.UserId] = profile;
            return true;
        }
    }

    public UserProfile? FindProfile(string userId)
    {
        lock (_sync) return _profiles.GetValueOrDefault(userId);
    }

    public List<AdminProfileSummary> FindAdminProfiles(IReadOnlyList<string> userIds)
    {
        lock (_sync)
        {
            return userIds
                .Where(_profiles.ContainsKey)
                .Select(userId => new AdminProfileSummary(userId, _profiles[userId].DisplayName))
                .ToList();
        }
    }

    public bool DeleteProfile(string userId)
    {
        lock (_sync)
        {
            _preferences.Remove(userId);
            return _profiles.Remove(userId);
        }
    }

    public UserProfile? UpdateProfile(string userId, UpdateUserProfileRequest request)
    {
        lock (_sync)
        {
            if (!_profiles.TryGetValue(userId, out var current)) return null;
            var updated = current with
            {
                DisplayName = request.DisplayName?.Trim() ?? current.DisplayName,
                Locale = request.Locale?.Trim() ?? current.Locale,
                PreferredSubjectCodes = request.PreferredSubjectCodes ?? current.PreferredSubjectCodes,
                UpdatedAt = DateTimeOffset.UtcNow
            };
            _profiles[userId] = updated;
            return updated;
        }
    }

    public UserPreferences? FindPreferences(string userId)
    {
        lock (_sync)
        {
            return _profiles.ContainsKey(userId)
                ? _preferences.GetValueOrDefault(userId) ?? new UserPreferences(30, "STANDARD", false, DateTimeOffset.UtcNow)
                : null;
        }
    }

    public UserPreferences? ReplacePreferences(string userId, UserPreferencesInput request)
    {
        lock (_sync)
        {
            if (!_profiles.ContainsKey(userId)) return null;
            var preferences = new UserPreferences(request.DailyGoalMinutes, request.ContentDifficulty, request.ReducedMotion, DateTimeOffset.UtcNow);
            _preferences[userId] = preferences;
            return preferences;
        }
    }
}
