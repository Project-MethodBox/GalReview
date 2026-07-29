using System.Threading.Channels;

namespace KnowledgeService.API.Background;

internal sealed class GraphBuildQueue : IGraphBuildQueue
{
    private readonly Channel<GraphBuildWorkItem> _channel =
        Channel.CreateBounded<GraphBuildWorkItem>(
            new BoundedChannelOptions(256)
            {
                FullMode = BoundedChannelFullMode.Wait,
                SingleReader = true,
                SingleWriter = false
            });

    public ValueTask EnqueueAsync(
        GraphBuildWorkItem workItem,
        CancellationToken cancellationToken) =>
        _channel.Writer.WriteAsync(workItem, cancellationToken);

    public ValueTask<GraphBuildWorkItem> DequeueAsync(
        CancellationToken cancellationToken) =>
        _channel.Reader.ReadAsync(cancellationToken);
}
