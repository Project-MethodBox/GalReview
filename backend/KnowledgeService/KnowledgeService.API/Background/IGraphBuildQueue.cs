namespace KnowledgeService.API.Background;

internal interface IGraphBuildQueue
{
    ValueTask EnqueueAsync(
        GraphBuildWorkItem workItem,
        CancellationToken cancellationToken);

    ValueTask<GraphBuildWorkItem> DequeueAsync(
        CancellationToken cancellationToken);
}
