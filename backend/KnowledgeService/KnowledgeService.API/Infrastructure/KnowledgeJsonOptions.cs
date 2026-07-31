using System.Text.Json;
using System.Text.Json.Serialization;

namespace KnowledgeService.API.Infrastructure;

internal static class KnowledgeJsonOptions
{
    public static void Configure(JsonSerializerOptions options)
    {
        options.Converters.Add(
            new JsonStringEnumConverter(
                JsonNamingPolicy.SnakeCaseUpper,
                allowIntegerValues: false));
    }
}
