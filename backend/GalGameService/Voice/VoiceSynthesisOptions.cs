public sealed class VoiceSynthesisOptions
{
    public const string SectionName = "VoiceSynthesis";

    public bool Enabled { get; set; } = true;
    public string Endpoint { get; set; } = "https://api.xiaomimimo.com/v1/chat/completions";
    public string Model { get; set; } = "mimo-v2.5-tts";
    public string ApiKey { get; set; } = string.Empty;
    public int TimeoutSeconds { get; set; } = 90;
    public int MaxConcurrency { get; set; } = 2;
    public int MaxAttempts { get; set; } = 3;
    public int RetryBaseDelayMilliseconds { get; set; } = 500;
    public int MaxTextCharacters { get; set; } = 2_000;
    public int MaxAudioBytes { get; set; } = 8 * 1024 * 1024;

    public bool CanCallProvider =>
        Enabled
        && !string.IsNullOrWhiteSpace(ApiKey)
        && string.Equals(Model, "mimo-v2.5-tts", StringComparison.Ordinal)
        && Uri.TryCreate(Endpoint, UriKind.Absolute, out var endpoint)
        && endpoint.Scheme == Uri.UriSchemeHttps;
}
