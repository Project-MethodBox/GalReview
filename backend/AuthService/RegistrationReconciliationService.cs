using System.Threading;

/// <summary>
/// 注册 Saga 对账后台服务。
/// 定期扫描超时仍为 PENDING 的 Saga，根据已完成的步骤决定重试或补偿，
/// 保证注册流程在进程崩溃后最终达到一致状态（COMPLETED 或 FAILED）。
/// </summary>
public sealed class RegistrationReconciliationService(
    IRegistrationSagaStore sagaStore,
    IAuthRepository repository,
    RegistrationSagaCoordinator coordinator,
    IHttpClientFactory httpClientFactory,
    string gatewayKey,
    ILogger<RegistrationReconciliationService> logger,
    IConfiguration configuration) : BackgroundService
{
    private static readonly TimeSpan DefaultStaleAge = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan DefaultPollInterval = TimeSpan.FromMinutes(2);
    private const int DefaultBatchSize = 50;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var pollInterval = configuration.GetValue<TimeSpan?>("RegistrationReconciliation:PollInterval") ?? DefaultPollInterval;
        var staleAge = configuration.GetValue<TimeSpan?>("RegistrationReconciliation:StaleAge") ?? DefaultStaleAge;
        var batchSize = configuration.GetValue<int?>("RegistrationReconciliation:BatchSize") ?? DefaultBatchSize;

        logger.LogInformation("Registration reconciliation service started (poll={Poll}, staleAge={StaleAge}, batch={Batch})",
            pollInterval, staleAge, batchSize);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await ReconcileBatchAsync(staleAge, batchSize, stoppingToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Error during registration reconciliation batch");
            }

            try { await Task.Delay(pollInterval, stoppingToken); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task ReconcileBatchAsync(TimeSpan staleAge, int batchSize, CancellationToken cancellationToken)
    {
        var staleSagas = sagaStore.FindStale(staleAge, batchSize);
        if (staleSagas.Count == 0) return;

        logger.LogInformation("Found {Count} stale registration saga(s) to reconcile", staleSagas.Count);

        foreach (var saga in staleSagas)
        {
            if (cancellationToken.IsCancellationRequested) break;
            await ReconcileSagaAsync(saga, cancellationToken);
        }
    }

    private async Task ReconcileSagaAsync(RegistrationSagaRecord saga, CancellationToken cancellationToken)
    {
        // 如果 credential 已不存在，说明已被其他途径清理（如手动删除或补偿已完成）。
        var credential = repository.FindCredentialById(saga.UserId);
        if (credential is null)
        {
            logger.LogInformation("Saga {SagaId}: credential already gone, marking FAILED", saga.SagaId);
            sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Failed, saga.CredentialCreated, saga.ProfileCreated, saga.SessionCreated, "CREDENTIAL_GONE");
            return;
        }

        // 情况1：profile 和 credential 都已创建，但 session 未创建 → 尝试重试创建 session
        if (saga.CredentialCreated && saga.ProfileCreated && !saga.SessionCreated)
        {
            try
            {
                var session = repository.CreateSession(saga.UserId, saga.DeviceName);
                sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Completed, true, true, true, null);
                logger.LogInformation("Saga {SagaId}: session created on retry, marking COMPLETED (session={SessionId})",
                    saga.SagaId, session.SessionId);
                return;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Saga {SagaId}: session retry failed, compensating", saga.SagaId);
                await coordinator.CompensateAsync(saga, $"reconcine-{saga.SagaId}", cancellationToken);
                return;
            }
        }

        // 情况2：credential 已创建但 profile 未创建 → 尝试重试创建 profile
        if (saga.CredentialCreated && !saga.ProfileCreated)
        {
            var client = httpClientFactory.CreateClient("gateway");
            var profileCreated = await AuthHelpers.CreateProfileAsync(client, gatewayKey, $"reconcile-{saga.SagaId}", saga.UserId, saga.DisplayName, cancellationToken);
            if (profileCreated)
            {
                // profile 创建成功，继续尝试创建 session
                try
                {
                    var session = repository.CreateSession(saga.UserId, saga.DeviceName);
                    sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Completed, true, true, true, null);
                    logger.LogInformation("Saga {SagaId}: profile + session created on retry, marking COMPLETED", saga.SagaId);
                    return;
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "Saga {SagaId}: session creation failed after profile retry, compensating", saga.SagaId);
                    await coordinator.CompensateAsync(saga with { ProfileCreated = true }, $"reconcile-{saga.SagaId}", cancellationToken);
                    return;
                }
            }
            else
            {
                // profile 仍然创建不了 → 补偿
                logger.LogWarning("Saga {SagaId}: profile retry failed, compensating", saga.SagaId);
                await coordinator.CompensateAsync(saga, $"reconcine-{saga.SagaId}", cancellationToken);
                return;
            }
        }

        // 情况3：所有步骤都标记为完成但状态仍为 PENDING（更新失败） → 标记 COMPLETED
        if (saga.CredentialCreated && saga.ProfileCreated && saga.SessionCreated)
        {
            sagaStore.TryUpdate(saga.SagaId, RegistrationSagaStatus.Completed, true, true, true, "RECONCILED_AS_COMPLETED");
            logger.LogInformation("Saga {SagaId}: all steps done but status was stale, marking COMPLETED", saga.SagaId);
            return;
        }

        // 其他异常情况：补偿
        logger.LogWarning("Saga {SagaId}: unexpected state (credential={Cred}, profile={Prof}, session={Sess}), compensating",
            saga.SagaId, saga.CredentialCreated, saga.ProfileCreated, saga.SessionCreated);
        await coordinator.CompensateAsync(saga, $"reconcile-{saga.SagaId}", cancellationToken);
    }
}
