using KnowledgeService.Application.Persistence;

namespace KnowledgeService.API.Background;

/// <summary>
/// 进程启动后把仍处于 Queued/Running 的构建任务重新放回内存队列。
///
/// 队列本身是进程内 Channel：重启即清空。没有这一步时，重启前已被持久化为
/// Running 的任务再也不会被处理，GET /api/v1/knowledge-graph-builds/{buildId}
/// 会永远返回 RUNNING（进度停在中途），客户端轮询无限挂起；用同一 Idempotency-Key
/// 重发 POST 也救不回来——那时 Created=false 且状态不是 Queued，不满足入队条件。
///
/// 重放是安全的：ProcessGraphBuildCommandHandler 对已 Succeeded 的任务短路返回，
/// 其余任务按幂等的构建流程重跑。
/// </summary>
internal sealed class GraphBuildRecoveryService : BackgroundService
{
    /// <summary>单次恢复的任务数上限，与队列容量一致，避免启动时无界积压。</summary>
    private const int MaxRecoveredJobs = 256;

    private readonly IGraphBuildQueue _queue;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<GraphBuildRecoveryService> _logger;

    public GraphBuildRecoveryService(
        IGraphBuildQueue queue,
        IServiceScopeFactory scopeFactory,
        ILogger<GraphBuildRecoveryService> logger)
    {
        _queue = queue;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            using var scope = _scopeFactory.CreateScope();
            var repository = scope.ServiceProvider
                .GetRequiredService<IKnowledgeRepository>();
            var pending = await repository.ListUnfinishedBuildJobsAsync(
                MaxRecoveredJobs,
                stoppingToken);
            if (pending.Count == 0)
            {
                return;
            }

            foreach (var job in pending)
            {
                await _queue.EnqueueAsync(
                    new GraphBuildWorkItem(job.BuildId, $"recovery-{job.BuildId:N}"),
                    stoppingToken);
            }

            _logger.LogWarning(
                "Re-queued {Count} graph build job(s) left unfinished by a previous run.",
                pending.Count);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // 停机中，忽略
        }
        catch (Exception exception)
        {
            // 恢复失败不能阻止服务启动：正常的新建构建仍可工作
            _logger.LogError(
                exception,
                "Re-queueing unfinished graph build jobs failed.");
        }
    }
}
