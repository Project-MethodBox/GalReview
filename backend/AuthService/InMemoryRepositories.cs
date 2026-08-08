using System.Security.Cryptography;
using Microsoft.AspNetCore.Identity;

public sealed class MockAuthStore
{
    internal const string DemoUserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    internal readonly object Sync = new();
    internal readonly Dictionary<string, Credential> CredentialsById = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, string> CredentialIdsByEmail = new(StringComparer.OrdinalIgnoreCase);
    internal readonly Dictionary<string, StoredSession> SessionsById = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, string> SessionIdsByAccessToken = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, string> SessionIdsByRefreshToken = new(StringComparer.Ordinal);
    internal readonly Dictionary<string, AdminInvitation> Invitations = new(StringComparer.OrdinalIgnoreCase);
    internal readonly Dictionary<string, MockPasswordReset> PasswordResets = new(StringComparer.Ordinal);
    internal readonly List<AdminAuditRecord> AuditRecords = [];

    public MockAuthStore(IPasswordHasher<Credential> hasher)
    {
        var credential = new Credential(DemoUserId, "student@example.com", string.Empty);
        credential = credential with { PasswordHash = hasher.HashPassword(credential, "mock114514") };
        CredentialsById[credential.UserId] = credential;
        CredentialIdsByEmail[credential.Email] = credential.UserId;
        Invitations["MS-MOCK2026"] = new AdminInvitation("MS-MOCK2026", "multi-use", 100, 0, null, null, DateTimeOffset.UtcNow);
    }

    internal bool DeleteAccount(string userId)
    {
        if (!CredentialsById.Remove(userId, out var credential)) return false;
        CredentialIdsByEmail.Remove(credential.Email);
        foreach (var session in SessionsById.Values.Where(value => value.UserId == userId).ToArray()) RemoveSession(session);
        foreach (var key in PasswordResets.Where(pair => pair.Value.UserId == userId).Select(pair => pair.Key).ToArray()) PasswordResets.Remove(key);
        return true;
    }

    internal void RemoveSession(StoredSession session)
    {
        SessionsById.Remove(session.SessionId);
        SessionIdsByAccessToken.Remove(session.AccessToken);
        SessionIdsByRefreshToken.Remove(session.RefreshToken);
    }
}

public sealed record MockPasswordReset(string UserId, DateTimeOffset ExpiresAt);

public sealed class InMemoryAuthRepository(MockAuthStore store) : IAuthRepository
{
    public RegistrationOutcome TryCreateCredential(Credential value)
    {
        lock (store.Sync)
        {
            if (store.CredentialIdsByEmail.ContainsKey(value.Email)) return RegistrationOutcome.EmailAlreadyRegistered;
            store.CredentialsById[value.UserId] = value;
            store.CredentialIdsByEmail[value.Email] = value.UserId;
            return RegistrationOutcome.Created;
        }
    }

    public RegistrationOutcome TryCreateCredentialWithInvitation(Credential value, string invitationCode)
    {
        lock (store.Sync)
        {
            if (store.CredentialIdsByEmail.ContainsKey(value.Email)) return RegistrationOutcome.EmailAlreadyRegistered;
            if (!store.Invitations.TryGetValue(invitationCode, out var invitation) || !InvitationIsUsable(invitation)) return RegistrationOutcome.InvitationUnavailable;
            store.CredentialsById[value.UserId] = value;
            store.CredentialIdsByEmail[value.Email] = value.UserId;
            store.Invitations[invitation.Code] = invitation with { UsedCount = invitation.UsedCount + 1 };
            return RegistrationOutcome.Created;
        }
    }

    public void RollbackRegistration(string userId, string invitationCode)
    {
        lock (store.Sync)
        {
            store.DeleteAccount(userId);
            if (store.Invitations.TryGetValue(invitationCode, out var invitation) && invitation.UsedCount > 0)
                store.Invitations[invitation.Code] = invitation with { UsedCount = invitation.UsedCount - 1 };
        }
    }

    public void DeleteCredential(string id)
    {
        lock (store.Sync) store.DeleteAccount(id);
    }

    public bool DeleteAccount(string userId)
    {
        lock (store.Sync) return store.DeleteAccount(userId);
    }

    public Credential? FindCredential(string email)
    {
        lock (store.Sync)
        {
            return store.CredentialIdsByEmail.TryGetValue(email, out var userId)
                ? store.CredentialsById.GetValueOrDefault(userId)
                : null;
        }
    }

    public Credential? FindCredentialById(string userId)
    {
        lock (store.Sync) return store.CredentialsById.GetValueOrDefault(userId);
    }

    public StoredSession CreateSession(string userId, string? deviceName)
    {
        lock (store.Sync)
        {
            var now = DateTimeOffset.UtcNow;
            var session = new StoredSession(Guid.NewGuid().ToString(), userId, Token(), Token(), now, now.AddMinutes(15), now.AddDays(7), null);
            store.SessionsById[session.SessionId] = session;
            store.SessionIdsByAccessToken[session.AccessToken] = session.SessionId;
            store.SessionIdsByRefreshToken[session.RefreshToken] = session.SessionId;
            return session;
        }
    }

    public StoredSession? FindSession(string id)
    {
        lock (store.Sync) return store.SessionsById.GetValueOrDefault(id);
    }

    public StoredSession? FindByAccessToken(string token)
    {
        lock (store.Sync)
        {
            return store.SessionIdsByAccessToken.TryGetValue(token, out var sessionId)
                ? store.SessionsById.GetValueOrDefault(sessionId)
                : null;
        }
    }

    public StoredSession? TouchAccessToken(string token)
    {
        lock (store.Sync)
        {
            if (!store.SessionIdsByAccessToken.TryGetValue(token, out var sessionId) || !store.SessionsById.TryGetValue(sessionId, out var session)) return null;
            var now = DateTimeOffset.UtcNow;
            if (session.Status != "ACTIVE" || session.AccessExpiresAt <= now) return null;
            return session;
        }
    }

    public bool RevokeSession(string sessionId, string userId)
    {
        lock (store.Sync)
        {
            if (!store.SessionsById.TryGetValue(sessionId, out var session) || session.UserId != userId || session.RevokedAt is not null) return false;
            store.SessionsById[sessionId] = session with { RevokedAt = DateTimeOffset.UtcNow };
            return true;
        }
    }

    public StoredSession? Rotate(string refreshToken)
    {
        lock (store.Sync)
        {
            if (!store.SessionIdsByRefreshToken.TryGetValue(refreshToken, out var sessionId) || !store.SessionsById.TryGetValue(sessionId, out var session) || session.Status != "ACTIVE") return null;
            var now = DateTimeOffset.UtcNow;
            store.SessionIdsByAccessToken.Remove(session.AccessToken);
            store.SessionIdsByRefreshToken.Remove(session.RefreshToken);
            var rotated = session with
            {
                AccessToken = Token(),
                RefreshToken = Token(),
                AccessExpiresAt = now.AddMinutes(15),
                RefreshExpiresAt = now.AddDays(7),
            };
            store.SessionsById[sessionId] = rotated;
            store.SessionIdsByAccessToken[rotated.AccessToken] = sessionId;
            store.SessionIdsByRefreshToken[rotated.RefreshToken] = sessionId;
            return rotated;
        }
    }

    public void RevokeAllSessions(string userId)
    {
        lock (store.Sync)
        {
            foreach (var session in store.SessionsById.Values.Where(value => value.UserId == userId && value.RevokedAt is null).ToArray())
                store.SessionsById[session.SessionId] = session with { RevokedAt = DateTimeOffset.UtcNow };
        }
    }

    public void UpdatePassword(Credential credential)
    {
        lock (store.Sync)
        {
            if (store.CredentialsById.ContainsKey(credential.UserId)) store.CredentialsById[credential.UserId] = credential;
        }
    }

    public string CreatePasswordReset(string userId)
    {
        lock (store.Sync)
        {
            foreach (var code in store.PasswordResets.Where(pair => pair.Value.UserId == userId).Select(pair => pair.Key).ToArray()) store.PasswordResets.Remove(code);
            store.PasswordResets["123456"] = new MockPasswordReset(userId, DateTimeOffset.UtcNow.AddMinutes(10));
            return "123456";
        }
    }

    public void DeletePasswordReset(string token)
    {
        lock (store.Sync) store.PasswordResets.Remove(token);
    }

    public Credential? ConsumePasswordReset(string token)
    {
        lock (store.Sync)
        {
            if (!store.PasswordResets.Remove(token, out var reset) || reset.ExpiresAt <= DateTimeOffset.UtcNow) return null;
            return store.CredentialsById.GetValueOrDefault(reset.UserId);
        }
    }

    private static bool InvitationIsUsable(AdminInvitation invitation)
    {
        if (invitation.Type == "time-window")
            return invitation.ValidFrom <= DateTimeOffset.UtcNow && invitation.ValidTo >= DateTimeOffset.UtcNow;
        return invitation.UsedCount < invitation.MaxUses;
    }

    private static string Token() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(48)).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

public sealed class InMemoryAdminRepository(MockAuthStore store) : IAdminRepository
{
    public List<AdminAccount> ListUsers()
    {
        lock (store.Sync) return store.CredentialsById.Values.Select(value => new AdminAccount(value.UserId, value.Email)).OrderBy(value => value.Email).ToList();
    }

    public bool UserExists(string userId)
    {
        lock (store.Sync) return store.CredentialsById.ContainsKey(userId);
    }

    public bool DeleteAuthUser(string userId)
    {
        lock (store.Sync) return store.DeleteAccount(userId);
    }

    public List<AdminInvitation> ListInvitations()
    {
        lock (store.Sync) return store.Invitations.Values.OrderByDescending(value => value.CreatedAt).ToList();
    }

    public AdminInvitation? CreateInvitation(CreateInvitationRequest request)
    {
        var type = request.Type?.Trim().ToLowerInvariant();
        if (type is not ("single-use" or "multi-use" or "time-window") ||
            (type == "multi-use" && !request.MaxUses.HasValue)) return null;
        var maxUses = type switch
        {
            "single-use" => 1,
            "time-window" => int.MaxValue,
            _ => request.MaxUses.GetValueOrDefault(),
        };
        if ((type == "multi-use" && maxUses is < 1 or > 10000)
            || (type == "time-window" && (!request.ValidFrom.HasValue || !request.ValidTo.HasValue || request.ValidTo <= request.ValidFrom))) return null;

        lock (store.Sync)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var invitation = new AdminInvitation("MS-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(5)), type, maxUses, 0, request.ValidFrom, request.ValidTo, DateTimeOffset.UtcNow);
                if (store.Invitations.ContainsKey(invitation.Code)) continue;
                store.Invitations[invitation.Code] = invitation;
                return invitation;
            }
        }
        return null;
    }

    public bool DeleteInvitation(string code)
    {
        lock (store.Sync) return store.Invitations.Remove(code);
    }
}

public sealed class InMemoryAdminAuditRepository(MockAuthStore store) : IAdminAuditRepository
{
    public void Write(AdminAuditRecord record)
    {
        lock (store.Sync) store.AuditRecords.Add(record);
    }
}
