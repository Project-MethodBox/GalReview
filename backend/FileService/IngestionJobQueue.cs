using System.Threading.Channels;

namespace FileService.Background;

/// <summary>
/// 有界 Channel 队列：用于把 ingestion job 从同步请求路径中解耦，
/// 替换原有 fire-and-forget 的 Task.Run。后台 worker 通过 <see cref="BackgroundService"/>
/// 消费，避免请求结束后任务被丢弃，同时提供反压与可取消的消费循环。
/// </summary>
public sealed class IngestionJobQueue : IDisposable
{
    private readonly Channel<string> _channel;
    private readonly ILogger<IngestionJobQueue> _logger;

    public IngestionJobQueue(IConfiguration configuration, ILogger<IngestionJobQueue> logger)
    {
        _logger = logger;
        var capacity = configuration.GetValue<int?>("Ingestion:QueueCapacity") ?? 64;
        _channel = Channel.CreateBounded<string>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
        });
    }

    /// <summary>入队一个待处理 job。队列已关闭时返回 false。</summary>
    public async ValueTask<bool> EnqueueAsync(string jobId, CancellationToken cancellationToken)
    {
        try
        {
            await _channel.Writer.WriteAsync(jobId, cancellationToken);
            return true;
        }
        catch (ChannelClosedException)
        {
            return false;
        }
    }

    /// <summary>提供给后台 worker 读取的 reader。</summary>
    public ChannelReader<string> Reader => _channel.Reader;

    /// <summary>关闭队列：进程停止时调用，确保 worker 能正常退出。</summary>
    public void Complete() => _channel.Writer.TryComplete();

    public void Dispose() => _channel.Writer.TryComplete();
}
