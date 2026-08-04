using System.Threading.Channels;

namespace GalGameService.Background;

/// <summary>
/// 游戏生成后台任务工作项：携带生成所需的全部上下文，
/// 避免后台 worker 再次访问 HttpContext（HttpContext 在请求结束后不可用）。
/// </summary>
public sealed record GameGenerationWorkItem(
    Guid GenerationId,
    string OwnerUserId,
    GameGenerationRequest Request,
    PlanGraph Graph,
    string TraceId);

/// <summary>
/// 有界 Channel 队列：替换原 fire-and-forget Task.Run，
/// 让游戏生成任务通过 BackgroundService 串行消费，提供反压与可取消能力。
/// </summary>
public sealed class GameGenerationQueue : IDisposable
{
    private readonly Channel<GameGenerationWorkItem> _channel;

    public GameGenerationQueue(IConfiguration configuration)
    {
        var capacity = configuration.GetValue<int?>("GameGeneration:QueueCapacity") ?? 32;
        _channel = Channel.CreateBounded<GameGenerationWorkItem>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
        });
    }

    public async ValueTask<bool> EnqueueAsync(GameGenerationWorkItem item, CancellationToken cancellationToken)
    {
        try
        {
            await _channel.Writer.WriteAsync(item, cancellationToken);
            return true;
        }
        catch (ChannelClosedException)
        {
            return false;
        }
    }

    public ChannelReader<GameGenerationWorkItem> Reader => _channel.Reader;

    public void Complete() => _channel.Writer.TryComplete();

    public void Dispose() => _channel.Writer.TryComplete();
}
