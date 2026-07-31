namespace KnowledgeService.API.Infrastructure;

public sealed class GatewayTrustOptions
{
    public const string SectionName = "Gateway";

    public string ServiceKey { get; init; } = string.Empty;

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ServiceKey) ||
            ServiceKey.Length is < 16 or > 512)
        {
            throw new InvalidOperationException(
                "Gateway:ServiceKey must contain between 16 and 512 characters.");
        }
    }
}
