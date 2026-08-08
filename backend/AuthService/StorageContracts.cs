public interface IAuthRepository
{
    RegistrationOutcome TryCreateCredential(Credential value);
    RegistrationOutcome TryCreateCredentialWithInvitation(Credential value, string invitationCode);
    void RollbackRegistration(string userId, string invitationCode);
    void DeleteCredential(string id);
    bool DeleteAccount(string userId);
    Credential? FindCredential(string email);
    Credential? FindCredentialById(string userId);
    StoredSession CreateSession(string userId, string? deviceName);
    StoredSession? FindSession(string id);
    StoredSession? FindByAccessToken(string token);
    StoredSession? TouchAccessToken(string token);
    bool RevokeSession(string sessionId, string userId);
    StoredSession? Rotate(string refreshToken);
    void RevokeAllSessions(string userId);
    void UpdatePassword(Credential credential);
    string CreatePasswordReset(string userId);
    void DeletePasswordReset(string token);
    Credential? ConsumePasswordReset(string token);
}

public interface IAdminRepository
{
    List<AdminAccount> ListUsers();
    bool UserExists(string userId);
    bool DeleteAuthUser(string userId);
    List<AdminInvitation> ListInvitations();
    AdminInvitation? CreateInvitation(CreateInvitationRequest request);
    bool DeleteInvitation(string code);
}

public interface IAdminAuditRepository
{
    void Write(AdminAuditRecord record);
}
