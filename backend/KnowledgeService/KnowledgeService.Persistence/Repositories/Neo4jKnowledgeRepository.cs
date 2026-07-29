using KnowledgeService.Application.Exceptions;
using KnowledgeService.Application.Persistence;
using KnowledgeService.Persistence.Neo4j;
using KnowledgeService.Persistence.Options;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Repositories;

public sealed partial class Neo4jKnowledgeRepository : IKnowledgeRepository
{
    private readonly IDriver _driver;
    private readonly Neo4jOptions _options;

    public Neo4jKnowledgeRepository(
        IDriver driver,
        Neo4jOptions options)
    {
        _driver = driver ?? throw new ArgumentNullException(nameof(driver));
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
    }

    public Task InitializeSchemaAsync(CancellationToken cancellationToken) =>
        Neo4jSchema.InitializeAsync(
            _driver,
            _options.Database,
            cancellationToken);

    public async Task<bool> IsReadyAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            await using var session = OpenSession(AccessMode.Read);
            var cursor = await session.RunAsync("RETURN 1 AS ready");
            await cursor.ConsumeAsync();
            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private IAsyncSession OpenSession(AccessMode accessMode) =>
        _driver.AsyncSession(config => config
            .WithDatabase(_options.Database)
            .WithDefaultAccessMode(accessMode));

    private static KnowledgeServiceException NotFound(
        string code,
        string message) =>
        new(404, code, message);

    private static KnowledgeServiceException Conflict(
        string code,
        string message,
        IReadOnlyDictionary<string, object?>? details = null) =>
        new(409, code, message, details);

    private static KnowledgeServiceException IntegrityFailure(
        string message,
        Exception? innerException = null) =>
        new(
            500,
            "KNOWLEDGE_STORAGE_INTEGRITY_ERROR",
            message,
            innerException: innerException);
}
