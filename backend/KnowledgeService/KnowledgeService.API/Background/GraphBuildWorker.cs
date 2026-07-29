using KnowledgeService.Application.Features.Builds;
using MediatR;

namespace KnowledgeService.API.Background;

internal sealed class GraphBuildWorker : BackgroundService
{
    private readonly IGraphBuildQueue _queue;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<GraphBuildWorker> _logger;

    public GraphBuildWorker(
        IGraphBuildQueue queue,
        IServiceScopeFactory scopeFactory,
        ILogger<GraphBuildWorker> logger)
    {
        _queue = queue;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            GraphBuildWorkItem workItem;
            try
            {
                workItem = await _queue.DequeueAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }

            try
            {
                using var scope = _scopeFactory.CreateScope();
                var sender = scope.ServiceProvider.GetRequiredService<ISender>();
                var result = await sender.Send(
                    new ProcessGraphBuildCommand(
                        workItem.BuildId,
                        workItem.CorrelationId),
                    stoppingToken);
                if (result.Status == Domain.Builds.GraphBuildStatus.Failed)
                {
                    _logger.LogWarning(
                        "Graph build {BuildId} failed with {ErrorCode}: {ErrorMessage}",
                        result.BuildId,
                        result.ErrorCode,
                        result.ErrorMessage);
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                _logger.LogError(
                    exception,
                    "Unexpected background failure for graph build {BuildId}",
                    workItem.BuildId);
            }
        }
    }
}
