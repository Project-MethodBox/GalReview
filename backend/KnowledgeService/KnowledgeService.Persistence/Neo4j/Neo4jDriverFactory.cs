using KnowledgeService.Persistence.Options;
using Neo4j.Driver;

namespace KnowledgeService.Persistence.Neo4j;

public static class Neo4jDriverFactory
{
    public static IDriver Create(Neo4jOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();

        return GraphDatabase.Driver(
            new Uri(options.Uri),
            AuthTokens.Basic(options.Username, options.Password));
    }
}
