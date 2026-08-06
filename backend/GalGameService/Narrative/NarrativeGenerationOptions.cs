public sealed class NarrativeGenerationOptions
{
    public const string SectionName = "NarrativeGeneration";

    public bool Enabled { get; set; }
    public string Endpoint { get; set; } = "https://api.deepseek.com/chat/completions";
    public string Model { get; set; } = "deepseek-v4-pro";
    public string ApiKey { get; set; } = string.Empty;
    public string PromptVersion { get; set; } = "galgame-narrative-v3";
    public int TimeoutSeconds { get; set; } = 120;
    public int MaxOutputTokens { get; set; } = 16_000;
    public double Temperature { get; set; } = 0.75;
    public int MaxDraftAttempts { get; set; } = 3;
    public int MaxProviderAttempts { get; set; } = 3;
    public int RetryBaseDelayMilliseconds { get; set; } = 400;

    public bool CanCallProvider =>
        Enabled
        && !string.IsNullOrWhiteSpace(ApiKey)
        && !string.IsNullOrWhiteSpace(Model)
        && Uri.TryCreate(Endpoint, UriKind.Absolute, out var endpoint)
        && endpoint.Scheme == Uri.UriSchemeHttps;
}
