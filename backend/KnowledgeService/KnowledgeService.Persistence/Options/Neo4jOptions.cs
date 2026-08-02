namespace KnowledgeService.Persistence.Options;

public sealed class Neo4jOptions
{
    public const string SectionName = "Neo4j";

    public string Uri { get; init; } = "bolt://localhost:5255";

    public string Username { get; init; } = "neo4j";

    public string Password { get; init; } = string.Empty;

    public string Database { get; init; } = "neo4j";

    public void Validate()
    {
        if (!System.Uri.TryCreate(Uri, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("bolt" or "bolt+s" or "bolt+ssc" or "neo4j" or "neo4j+s" or "neo4j+ssc"))
        {
            throw new InvalidOperationException(
                "Neo4j:Uri must be an absolute bolt:// or neo4j:// URI.");
        }

        if (uri.Port is < 5000 or > 5300)
        {
            throw new InvalidOperationException(
                "Neo4j:Uri port must be between 5000 and 5300.");
        }

        if (string.IsNullOrWhiteSpace(Username))
        {
            throw new InvalidOperationException("Neo4j:Username must be configured.");
        }

        if (string.IsNullOrEmpty(Password))
        {
            throw new InvalidOperationException("Neo4j:Password must be configured.");
        }

        if (string.IsNullOrWhiteSpace(Database))
        {
            throw new InvalidOperationException("Neo4j:Database must be configured.");
        }
    }
}
