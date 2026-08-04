using System.Text.Json;

public sealed record RegistrationRequest(string Email, string Password, string DisplayName, string InvitationCode, string? DeviceName);
public sealed record LoginRequest(string Email, string Password, string? DeviceName);
public sealed record AdminLoginRequest(string? Username, string? Password);
public sealed record AdminResetPasswordRequest(string NewPassword);
public sealed record PasswordChangeRequest(string? CurrentPassword, string? NewPassword);
public sealed record AccountDeletionRequest(string CurrentPassword);
public sealed record CreateInvitationRequest(string Type, int? MaxUses, DateTimeOffset? ValidFrom, DateTimeOffset? ValidTo);
public sealed record AdminUser(string Id, string Email, string DisplayName, bool IsActive);
public sealed record AdminInvitation(string Code, string Type, int MaxUses, int UsedCount, DateTimeOffset? ValidFrom, DateTimeOffset? ValidTo, DateTimeOffset CreatedAt);
public sealed record AdminAccount(string Id, string Email);
public sealed record AdminProfileSummary(string UserId, string DisplayName);
public sealed record ApiEnvelope<T>(T? Data, JsonElement Meta, string? TraceId);
public sealed record RefreshTokenRequest(string? RefreshToken);
public sealed record PasswordResetRequest(string Email);
public sealed record PasswordResetConfirmation(string? ResetToken, string? NewPassword);
public sealed record TokenIntrospectionRequest(string? Token);
public sealed record AuthSession(string SessionId, string UserId, string Status, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt);
public sealed record TokenPair(string AccessToken, string RefreshToken, string TokenType, int ExpiresInSeconds);
public sealed record AuthSessionResponse(AuthSession Session, TokenPair Tokens);
public sealed record TokenIntrospection(bool Active, string? UserId, string? SessionId, string[] Scopes, DateTimeOffset? ExpiresAt);
public sealed record ApiError(string Code, string Message, object Details);
public sealed record ApiSuccess(object Data, object Meta, string TraceId)
{
    public static ApiSuccess Create(object data, string id) => new(data, new { }, id);
}
public sealed record ApiFailure(object? Data, ApiError Error, string TraceId)
{
    public static ApiFailure Create(string code, string message, string id) => new(null, new ApiError(code, message, new { }), id);
}

public sealed record AdminAuditRecord(string AuditId, string ActorUserId, string Action, string? TargetUserId, string? TargetInvitationCode, string Outcome, string TraceId, DateTimeOffset CreatedAt)
{
    public static AdminAuditRecord Create(string actorUserId, string action, string? targetUserId, string? targetInvitationCode, string outcome, string traceId) =>
        new(Guid.NewGuid().ToString(), actorUserId, action, targetUserId, targetInvitationCode, outcome, traceId, DateTimeOffset.UtcNow);
}

public enum RegistrationOutcome { Created, EmailAlreadyRegistered, InvitationUnavailable }

public sealed record Credential(string UserId, string Email, string PasswordHash)
{
    public static Credential New(string email) => new(Guid.NewGuid().ToString(), email, string.Empty);
}

public sealed record StoredSession(string SessionId, string UserId, string AccessToken, string RefreshToken, DateTimeOffset CreatedAt, DateTimeOffset AccessExpiresAt, DateTimeOffset RefreshExpiresAt, DateTimeOffset? RevokedAt)
{
    public string Status => RevokedAt is not null ? "REVOKED" : RefreshExpiresAt <= DateTimeOffset.UtcNow ? "EXPIRED" : "ACTIVE";
    public AuthSession ToContract() => new(SessionId, UserId, Status, CreatedAt, RefreshExpiresAt);
    public TokenPair ToTokenPair() => new(AccessToken, RefreshToken, "Bearer", Math.Max(0, (int)(AccessExpiresAt - DateTimeOffset.UtcNow).TotalSeconds));
    public AuthSessionResponse ToResponse() => new(ToContract(), ToTokenPair());
}
