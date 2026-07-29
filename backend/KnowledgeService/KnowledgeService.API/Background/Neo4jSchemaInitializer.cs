using KnowledgeService.Application.Persistence;

namespace KnowledgeService.API.Background;

internal sealed class Neo4jSchemaInitializer : IHostedService
{
    private readonly IKnowledgeRepository _repository;
    private readonly ILogger<Neo4jSchemaInitializer> _logger;

    public Neo4jSchemaInitializer(
        IKnowledgeRepository repository,
        ILogger<Neo4jSchemaInitializer> logger)
    {
        _repository = repository;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        await _repository.InitializeSchemaAsync(cancellationToken);
        _logger.LogInformation("Neo4j schema is initialized.");
    }

    public Task StopAsync(CancellationToken cancellationToken) =>
        Task.CompletedTask;
}
