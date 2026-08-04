/// <summary>
/// 注册 Saga 的执行状态。
/// PENDING  — Saga 已创建，正逐步执行；对账 worker 会回收长期停留在此状态的记录。
/// COMPLETED — 全部步骤成功，用户可正常登录。
/// COMPENSATING — 正在反向补偿已完成的步骤。
/// FAILED — 补偿已完成（或无法进一步修复），凭据/资料已被清理。
/// </summary>
public enum RegistrationSagaStatus
{
    Pending,
    Completed,
    Compensating,
    Failed,
}

/// <summary>
/// 注册 Saga 持久化记录。每一步完成后立即落库，崩溃后对账 worker 可据此决定重试或补偿。
/// </summary>
public sealed record RegistrationSagaRecord(
    string SagaId,
    string UserId,
    string Email,
    string DisplayName,
    string InvitationCode,
    string? DeviceName,
    RegistrationSagaStatus Status,
    bool CredentialCreated,
    bool ProfileCreated,
    bool SessionCreated,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? CompensatedAt,
    string? LastError)
{
    public static RegistrationSagaRecord Start(string userId, string email, string displayName, string invitationCode, string? deviceName) =>
        new(Guid.NewGuid().ToString(), userId, email, displayName, invitationCode, deviceName, RegistrationSagaStatus.Pending, false, false, false, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, null, null);
}

/// <summary>
/// Saga 存储抽象：供协调器与对账 worker 共享状态。
/// </summary>
public interface IRegistrationSagaStore
{
    /// <summary>插入一条 PENDING 记录。sagaId 必须唯一。</summary>
    void Create(RegistrationSagaRecord record);
    /// <summary>按 sagaId 原子更新状态与各步骤标志。返回受影响行数（0 表示已被并发修改）。</summary>
    bool TryUpdate(string sagaId, RegistrationSagaStatus status, bool credentialCreated, bool profileCreated, bool sessionCreated, string? lastError);
    /// <summary>标记补偿完成时间，状态改为 FAILED。</summary>
    bool TryMarkCompensated(string sagaId);
    /// <summary>取出超时仍未完成的 Saga，供对账 worker 处理。按创建时间升序。</summary>
    IReadOnlyList<RegistrationSagaRecord> FindStale(TimeSpan age, int limit);
    /// <summary>单条查询，供测试与排查使用。</summary>
    RegistrationSagaRecord? Find(string sagaId);
    /// <summary>按 userId 查询最新 Saga，供对账 worker 判断凭据是否已被清理。</summary>
    RegistrationSagaRecord? FindByUserId(string userId);
    /// <summary>按 email 查询最新 Saga，不限状态。供测试与排查使用。</summary>
    RegistrationSagaRecord? FindLatestByEmail(string email);
}
