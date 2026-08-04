using System.Threading.Channels;

namespace FileService.Background;

/// <summary>
/// 后台 worker：消费 <see cref="IngestionJobQueue"/> 中的 job id，
/// 调用 MongoFileStore.ProcessJobAsync 执行实际的文本抽取。
/// 替换原 Program.cs 中 fire-and-forget 的 Task.Run，确保：
/// 1) 进程停止时正在处理的任务能通过 stoppingToken 被取消；
/// 2) 队列在进程停止时被关闭，未消费任务通过 RecoverIncompleteJobsAsync 在下次启动恢复；
/// 3) 提供可观测的异常日志，避免异常被静默吞掉。
/// </summary>
public sealed class IngestionJobWorker : BackgroundService
{
    private readonly IngestionJobQueue _queue;
    private readonly IFileStore _store;
    private readonly ILogger<IngestionJobWorker> _logger;

    public IngestionJobWorker(IngestionJobQueue queue, IFileStore store, ILogger<IngestionJobWorker> logger)
    {
        _queue = queue;
        _store = store;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("IngestionJobWorker started.");
        try
        {
            await foreach (var jobId in _queue.Reader.ReadAllAsync(stoppingToken))
            {
                if (string.IsNullOrEmpty(jobId)) continue;
                try
                {
                    await _store.ProcessJobAsync(jobId, stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    // 进程关闭：剩余 job 会在下次启动通过 RecoverIncompleteJobsAsync 恢复。
                    throw;
                }
                catch (Exception exception)
                {
                    // 单个 job 失败不应让 worker 退出，记录后继续消费下一个。
                    _logger.LogError(exception, "Ingestion job {JobId} failed in background worker.", jobId);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // 正常关闭路径。
        }
        finally
        {
            _logger.LogInformation("IngestionJobWorker stopped.");
        }
    }
}
