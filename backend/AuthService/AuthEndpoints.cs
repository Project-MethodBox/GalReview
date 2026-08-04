using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;

internal static class AuthEndpoints
{
    public static WebApplication MapAuthEndpoints(this WebApplication app, string gatewayKey, string adminUsername, string adminPassword)
    {
        app.MapPost("/api/v1/auth/registrations", async (RegistrationRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher, IHttpClientFactory clients) =>
        {
            var invitationCode = AuthHelpers.NormalizeInvitationCode(request.InvitationCode);
            if (!AuthHelpers.ValidEmail(request.Email) || !AuthHelpers.ValidName(request.DisplayName) || !AuthHelpers.ValidPassword(request.Password) || invitationCode is null) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "邮箱、显示名、密码或邀请码格式不正确");
            var credential = Credential.New(request.Email.Trim().ToLowerInvariant());
            credential = credential with { PasswordHash = hasher.HashPassword(credential, request.Password) };
            var registration = repository.TryCreateCredentialWithInvitation(credential, invitationCode);
            if (registration == RegistrationOutcome.EmailAlreadyRegistered) return AuthHelpers.Failure(c, 409, "STATE_CONFLICT", "该邮箱已注册");
            if (registration == RegistrationOutcome.InvitationUnavailable) return AuthHelpers.Failure(c, 422, "BUSINESS_RULE_VIOLATION", "邀请码无效、已过期或使用次数已达上限");
            var profileCreated = await AuthHelpers.CreateProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, credential.UserId, request.DisplayName.Trim(), c.RequestAborted);
            if (!profileCreated) { repository.RollbackRegistration(credential.UserId, invitationCode); return AuthHelpers.Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用"); }
            StoredSession session;
            try { session = repository.CreateSession(credential.UserId, request.DeviceName); }
            catch
            {
                await AuthHelpers.DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, credential.UserId, c.RequestAborted);
                repository.RollbackRegistration(credential.UserId, invitationCode);
                throw;
            }
            return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
        });

        app.MapPost("/api/v1/auth/sessions", (LoginRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
        {
            if (!AuthHelpers.ValidEmail(request.Email) || string.IsNullOrEmpty(request.Password)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "邮箱和密码不能为空");
            var credential = repository.FindCredential(request.Email.Trim().ToLowerInvariant());
            if (credential is null || !AuthHelpers.PasswordMatches(hasher, credential, request.Password)) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "邮箱或密码错误");
            var session = repository.CreateSession(credential.UserId, request.DeviceName);
            return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
        });

        app.MapPost("/api/v1/admin/sessions", (AdminLoginRequest request, HttpContext c, IAuthRepository repository) =>
        {
            if (!AuthHelpers.FixedTimeEquals(request.Username?.Trim() ?? string.Empty, adminUsername) ||
                !AuthHelpers.FixedTimeEquals(request.Password ?? string.Empty, adminPassword))
                return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "管理员账号或密码错误");
            var session = repository.CreateSession(AdminIdentity.UserId, "MoonStone admin");
            return Results.Created($"/api/v1/auth/sessions/{session.SessionId}", ApiSuccess.Create(session.ToResponse(), c.TraceIdentifier));
        });

        app.MapGet("/api/v1/admin/users", async (HttpContext c, IAdminRepository admin, IHttpClientFactory clients) =>
        {
            if (!AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限");
            var accounts = admin.ListUsers();
            var displayNames = await AuthHelpers.LookupProfileDisplayNamesAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, accounts.Select(account => account.Id).ToArray(), c.RequestAborted);
            if (displayNames is null) return AuthHelpers.Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用");
            var users = accounts.Select(account => new AdminUser(account.Id, account.Email, displayNames.GetValueOrDefault(account.Id, account.Email), true)).ToArray();
            return Results.Ok(ApiSuccess.Create(users, c.TraceIdentifier));
        });

        app.MapDelete("/api/v1/admin/users/{userId}", async (string userId, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit, IHttpClientFactory clients) =>
        {
            if (!AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限");
            var actorUserId = AuthHelpers.GetGatewayUser(c, gatewayKey)!;
            if (!admin.UserExists(userId))
            {
                audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, "NOT_FOUND", c.TraceIdentifier));
                return AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
            }
            if (!await AuthHelpers.DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, userId, c.RequestAborted))
            {
                audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, "PROFILE_DELETE_FAILED", c.TraceIdentifier));
                return AuthHelpers.Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用");
            }
            var deleted = admin.DeleteAuthUser(userId);
            audit.Write(AdminAuditRecord.Create(actorUserId, "USER_DELETE", userId, null, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
            return deleted ? Results.NoContent() : AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
        });

        app.MapPost("/api/v1/admin/users/{userId}/password", (string userId, AdminResetPasswordRequest request, HttpContext c, IAuthRepository repository, IAdminAuditRepository audit, IPasswordHasher<Credential> hasher) =>
        {
            if (!AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限");
            if (!AuthHelpers.ValidPassword(request.NewPassword)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "新密码至少需要 8 个字符");
            var credential = repository.FindCredentialById(userId);
            if (credential is null)
            {
                audit.Write(AdminAuditRecord.Create(AuthHelpers.GetGatewayUser(c, gatewayKey)!, "USER_PASSWORD_RESET", userId, null, "NOT_FOUND", c.TraceIdentifier));
                return AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
            }
            repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword) });
            repository.RevokeAllSessions(userId);
            audit.Write(AdminAuditRecord.Create(AuthHelpers.GetGatewayUser(c, gatewayKey)!, "USER_PASSWORD_RESET", userId, null, "SUCCEEDED", c.TraceIdentifier));
            return Results.NoContent();
        });

        app.MapPost("/api/v1/auth/password-changes", (PasswordChangeRequest request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
        {
            var userId = AuthHelpers.GetGatewayUser(c, gatewayKey);
            if (userId is null) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
            if (string.IsNullOrWhiteSpace(request.CurrentPassword)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "请输入当前密码");
            if (!AuthHelpers.ValidPassword(request.NewPassword)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "新密码至少需要 8 个字符");
            var credential = repository.FindCredentialById(userId);
            if (credential is null) return AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
            if (!AuthHelpers.PasswordMatches(hasher, credential, request.CurrentPassword)) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "当前密码错误");
            repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword!) });
            repository.RevokeAllSessions(userId);
            return Results.NoContent();
        });

        app.MapDelete("/api/v1/auth/account", async ([FromBody] AccountDeletionRequest request, HttpContext c, IAuthRepository repository, IAdminAuditRepository audit, IPasswordHasher<Credential> hasher, IHttpClientFactory clients) =>
        {
            var userId = AuthHelpers.GetGatewayUser(c, gatewayKey);
            if (userId is null) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "登陆状态已失效");
            if (AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "管理员不能通过此接口注销");
            if (string.IsNullOrWhiteSpace(request.CurrentPassword)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "请输入当前登录密码以确认注销");

            var credential = repository.FindCredentialById(userId);
            if (credential is null) return AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
            if (!AuthHelpers.PasswordMatches(hasher, credential, request.CurrentPassword)) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "当前密码错误");
            if (!await AuthHelpers.DeleteUserProfileAsync(clients.CreateClient("gateway"), gatewayKey, c.TraceIdentifier, userId, c.RequestAborted))
            {
                audit.Write(AdminAuditRecord.Create(userId, "ACCOUNT_SELF_DELETE", userId, null, "PROFILE_DELETE_FAILED", c.TraceIdentifier));
                return AuthHelpers.Failure(c, 503, "SERVICE_UNAVAILABLE", "用户资料服务暂时不可用，注销失败");
            }

            var deleted = repository.DeleteAccount(userId);
            audit.Write(AdminAuditRecord.Create(userId, "ACCOUNT_SELF_DELETE", userId, null, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
            return deleted ? Results.NoContent() : AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "用户不存在");
        });

        app.MapGet("/api/v1/admin/invitations", (HttpContext c, IAdminRepository admin) =>
            AuthHelpers.IsAdmin(c, gatewayKey) ? Results.Ok(ApiSuccess.Create(admin.ListInvitations(), c.TraceIdentifier)) : AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限"));

        app.MapPost("/api/v1/admin/invitations", (CreateInvitationRequest request, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit) =>
        {
            if (!AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限");
            var invitation = admin.CreateInvitation(request);
            if (invitation is null) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "请填写邀请码");
            audit.Write(AdminAuditRecord.Create(AuthHelpers.GetGatewayUser(c, gatewayKey)!, "INVITATION_CREATE", null, invitation.Code, "SUCCEEDED", c.TraceIdentifier));
            return Results.Created($"/api/v1/admin/invitations/{invitation.Code}", ApiSuccess.Create(invitation, c.TraceIdentifier));
        });

        app.MapDelete("/api/v1/admin/invitations/{code}", (string code, HttpContext c, IAdminRepository admin, IAdminAuditRepository audit) =>
        {
            if (!AuthHelpers.IsAdmin(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "需要管理员权限");
            var deleted = admin.DeleteInvitation(code);
            audit.Write(AdminAuditRecord.Create(AuthHelpers.GetGatewayUser(c, gatewayKey)!, "INVITATION_DELETE", null, code, deleted ? "SUCCEEDED" : "NOT_FOUND", c.TraceIdentifier));
            return deleted ? Results.NoContent() : AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "邀请码不存在");
        });

        app.MapGet("/api/v1/auth/sessions/{sessionId}", (string sessionId, HttpContext c, IAuthRepository repository) =>
        {
            var caller = AuthHelpers.GetGatewayUser(c, gatewayKey); if (caller is null) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
            var session = repository.FindSession(sessionId); return session is null || session.UserId != caller ? AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "会话不存在") : Results.Ok(ApiSuccess.Create(session.ToContract(), c.TraceIdentifier));
        });

        app.MapDelete("/api/v1/auth/sessions/{sessionId}", (string sessionId, HttpContext c, IAuthRepository repository) =>
        {
            var caller = AuthHelpers.GetGatewayUser(c, gatewayKey); if (caller is null) return AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "登录状态已失效");
            return repository.RevokeSession(sessionId, caller) ? Results.NoContent() : AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "会话不存在");
        });

        app.MapPost("/api/v1/auth/tokens", (RefreshTokenRequest request, HttpContext c, IAuthRepository repository) =>
        {
            var session = string.IsNullOrWhiteSpace(request.RefreshToken)
                ? null
                : repository.Rotate(request.RefreshToken);
            return session is null
                ? AuthHelpers.Failure(c, 401, "AUTH_REQUIRED", "刷新令牌无效")
                : Results.Created("/api/v1/auth/tokens", ApiSuccess.Create(session.ToTokenPair(), c.TraceIdentifier));
        });

        app.MapPost("/api/v1/auth/password-reset-requests", async (PasswordResetRequest request, HttpContext c, IAuthRepository repository, PasswordResetEmailSender emailSender) =>
        {
            if (!AuthHelpers.ValidEmail(request.Email)) return AuthHelpers.Failure(c, 400, "VALIDATION_ERROR", "请输入有效的邮箱地址");
            var credential = repository.FindCredential(request.Email.Trim().ToLowerInvariant());
            if (credential is null) return AuthHelpers.Failure(c, 404, "RESOURCE_NOT_FOUND", "该邮箱未注册");
            var resetToken = repository.CreatePasswordReset(credential.UserId);
            var delivered = await emailSender.SendAsync(credential.Email, resetToken, c.TraceIdentifier, c.RequestAborted);
            if (!delivered) repository.DeletePasswordReset(resetToken);
            return Results.Accepted();
        });

        app.MapPost("/api/v1/auth/password-resets", (PasswordResetConfirmation request, HttpContext c, IAuthRepository repository, IPasswordHasher<Credential> hasher) =>
        {
            if (!AuthHelpers.ValidPassword(request.NewPassword)) return AuthHelpers.Failure(c, 422, "BUSINESS_RULE_VIOLATION", "新密码不符合安全要求");
            if (string.IsNullOrWhiteSpace(request.ResetToken)) return AuthHelpers.Failure(c, 422, "BUSINESS_RULE_VIOLATION", "重置令牌无效或已过期");
            var credential = repository.ConsumePasswordReset(request.ResetToken);
            if (credential is null) return AuthHelpers.Failure(c, 422, "BUSINESS_RULE_VIOLATION", "重置令牌无效或已过期");
            repository.UpdatePassword(credential with { PasswordHash = hasher.HashPassword(credential, request.NewPassword!) });
            repository.RevokeAllSessions(credential.UserId);
            return Results.NoContent();
        }).RequireRateLimiting("password-reset-confirmation");

        app.MapPost("/internal/v1/auth/introspections", (TokenIntrospectionRequest request, HttpContext c, IAuthRepository repository) =>
        {
            if (!AuthHelpers.IsGateway(c, gatewayKey)) return AuthHelpers.Failure(c, 403, "FORBIDDEN", "仅允许 Gateway 调用令牌内省接口");
            var session = string.IsNullOrWhiteSpace(request.Token)
                ? null
                : repository.TouchAccessToken(request.Token);
            var result = session is not null
                ? new TokenIntrospection(true, session.UserId, session.SessionId, ["user"], session.AccessExpiresAt)
                : new TokenIntrospection(false, null, null, [], null);
            return Results.Ok(ApiSuccess.Create(result, c.TraceIdentifier));
        });

        return app;
    }
}
