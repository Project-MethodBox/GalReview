using Microsoft.AspNetCore.Identity;

/// <summary>
/// 注册流程 Saga 协调器。
/// 每一步完成后立即将状态持久化到 <see cref="IRegistrationSagaStore"/>，
/// 进程崩溃后由 <see cref="RegistrationReconciliationService"/> 接管重试或补偿。
/// </summary>
public sealed class RegistrationSagaCoordinator(
    IAuthRepository repository,
    IRegistrationSagaStore sagaStore,
    IPasswordHasher<Credential> hasher,
    IHttpClientFactory httpClientFactory,
    string gatewayKey,
    ILogger<RegistrationSagaCoordinator> logger)
{
    /// <summary>
    /// 执行完整的注册 Saga。返回创建的会话；失败时抛出异常，补偿已自动执行。
    /// </summary>
    public async Task<StoredSession> ExecuteAsync(
        string email,
        string password,
        string displayName,
        string invitationCode,
        string? deviceName,
        string traceId,
        CancellationToken cancellationToken)
    {
        var normalEmail = email.Trim().ToLowerInvariant();
        var normalDisplayName = displayName.Trim();
        var credential = Credential.New(normalEmail);
        credential = credential with { PasswordHash = hasher.HashPassword(credential, password) };

        // 1. 创建 Saga 记录（PENDING）
        var saga = RegistrationSagaRecord.Start(credential.UserId, normalEmail, normalDisplayName, invitationCode, deviceName);
        sagaStore.Create(saga);

        // 2. 创建 credential + 消费 invitation（原子事务）
        var outcome = repository.TryCreateCredentialWithInvitation(credential, invitationCode);
        if (outcome == RegistrationOutcome.EmailAlreadyRegistered)
        {
            sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Failed, false, false, false, "EMAIL_ALREADY_REGISTERED");
            throw new RegistrationConflictException("该邮箱已注册");
        }
        if (outcome == RegistrationOutcome.InvitationUnavailable)
        {
            sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Failed, false, false, false, "INVITATION_UNAVAILABLE");
            throw new RegistrationBusinessException("邀请码无效、已过期或使用次数已达上限");
        }

        // credential 已创建，落库。
        sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Pending, true, false, false, null);

        // 3. 创建 UserProfile（HTTP 调用 UserService）
        var client = httpClientFactory.CreateClient("gateway");
        var profileCreated = await AuthHelpers.CreateProfileAsync(client, gatewayKey, traceId, credential.UserId, normalDisplayName, cancellationToken);
        if (!profileCreated)
        {
            await CompensateAsync(saga with { CredentialCreated = true, ProfileCreated = false }, traceId, cancellationToken);
            throw new RegistrationDependencyException("用户资料服务暂时不可用");
        }

        sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Pending, true, true, false, null);

        // 4. 创建 Session
        StoredSession session;
        try
        {
            session = repository.CreateSession(credential.UserId, deviceName);
        }
        catch (Exception ex)
        {
            await CompensateAsync(saga with { CredentialCreated = true, ProfileCreated = true }, traceId, cancellationToken);
            throw new RegistrationDependencyException("会话创建失败，已执行补偿", ex);
        }

        // 5. 全部完成
        sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Completed, true, true, true, null);
        logger.LogInformation("Registration saga {SagaId} completed for user {UserId}", saga.SagaId, credential.UserId);
        return session;
    }

    /// <summary>
    /// 反向补偿：按 session → profile → credential 顺序撤销已完成的步骤。
    /// 补偿完成后将 Saga 标记为 FAILED。
    /// </summary>
    public async Task CompensateAsync(RegistrationSagaRecord saga, string traceId, CancellationToken cancellationToken)
    {
        logger.LogWarning("Compensating registration saga {SagaId} (credential={Credential}, profile={Profile}, session={Session})",
            saga.SagaId, saga.CredentialCreated, saga.ProfileCreated, saga.SessionCreated);

        // 标记为 COMPENSATING，防止对账 worker 重复处理
        sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Compensating, saga.CredentialCreated, saga.ProfileCreated, saga.SessionCreated, "COMPENSATING");

        // Session 补偿：撤销该用户所有会话
        if (saga.SessionCreated)
        {
            try { repository.RevokeAllSessions(saga.UserId); }
            catch (Exception ex) { logger.LogError(ex, "Failed to revoke sessions during compensation for saga {SagaId}", saga.SagaId); }
        }

        // Profile 补偿：删除 UserService 中的资料
        if (saga.ProfileCreated)
        {
            var client = httpClientFactory.CreateClient("gateway");
            try { await AuthHelpers.DeleteUserProfileAsync(client, gatewayKey, traceId, saga.UserId, cancellationToken); }
            catch (Exception ex) { logger.LogError(ex, "Failed to delete profile during compensation for saga {SagaId}", saga.SagaId); }
        }

        // Credential 补偿：删除凭据 + 回滚 invitation
        if (saga.CredentialCreated)
        {
            try { repository.RollbackRegistration(saga.UserId, saga.InvitationCode); }
            catch (Exception ex) { logger.LogError(ex, "Failed to rollback credential during compensation for saga {SagaId}", saga.SagaId); }
        }

        sagaStore.TryMarkCompensated(saga.SagaId);
        logger.LogWarning("Registration saga {SagaId} compensation completed (FAILED)", saga.SagaId);
    }
}

public sealed class RegistrationConflictException(string message) : Exception(message);
public sealed class RegistrationBusinessException(string message) : Exception(message);
public sealed class RegistrationDependencyException(string message, Exception? inner = null) : Exception(message, inner);
