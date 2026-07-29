namespace KnowledgeService.Persistence.Options;

public sealed class GatewayMaterialTextOptions
{
    public const string SectionName = "GatewayMaterialText";

    public string BaseUrl { get; init; } = "http://localhost:5000";

    public string ServiceName { get; init; } = "KnowledgeService";

    public string? ServiceKey { get; init; }

    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(30);

    public void Validate()
    {
        if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https"))
        {
            throw new InvalidOperationException(
                "GatewayMaterialText:BaseUrl must be an absolute HTTP(S) URI.");
        }

        if (string.IsNullOrWhiteSpace(ServiceName))
        {
            throw new InvalidOperationException(
                "GatewayMaterialText:ServiceName must be configured.");
        }

        if (Timeout <= TimeSpan.Zero || Timeout > TimeSpan.FromMinutes(5))
        {
            throw new InvalidOperationException(
                "GatewayMaterialText:Timeout must be between zero and five minutes.");
        }
    }
}
