using Xunit;

public sealed class DeepSeekNarrativeLiveTests
{
    [Fact]
    public async Task LiveProvider_WhenExplicitlyEnabled_ReturnsAcceptedNarrativeDraft()
    {
        if (!string.Equals(
            Environment.GetEnvironmentVariable("GALGAME_RUN_LIVE_LLM_TEST"),
            "1",
            StringComparison.Ordinal))
            return;

        var apiKey = Environment.GetEnvironmentVariable("DEEPSEEK_API_KEY");
        Assert.False(string.IsNullOrWhiteSpace(apiKey));

        var options = new NarrativeGenerationOptions
        {
            Enabled = true,
            ApiKey = apiKey!,
            Endpoint = Environment.GetEnvironmentVariable("GALGAME_NARRATIVE_ENDPOINT")
                ?? "https://api.deepseek.com/chat/completions",
            Model = Environment.GetEnvironmentVariable("GALGAME_NARRATIVE_MODEL")
                ?? "deepseek-v4-pro",
            PromptVersion = NarrativeTestData.PromptVersion,
            TimeoutSeconds = 180,
            MaxOutputTokens = 16_000,
        };
        using var clientFactory = new LiveHttpClientFactory();
        var modelClient = new DeepSeekNarrativeClient(clientFactory, options);
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var prompt = new NarrativePromptBuilder().Build(
            skeleton, plan, request, options.PromptVersion);

        var modelResult = await modelClient.GenerateJsonAsync(prompt, CancellationToken.None);
        var rawJson = modelResult.Json;
        var accepted = new NarrativeDraftValidator(new GamePackageValidator()).TryApply(
            rawJson,
            skeleton,
            plan,
            request,
            options.PromptVersion,
            out var enhanced,
            out var errors);

        Assert.True(accepted, string.Join(',', errors) + Environment.NewLine + rawJson);
        Assert.DoesNotContain(enhanced.Scenes.SelectMany(scene => scene.Dialogue),
            line => line.Text.Contains("知识点讲解", StringComparison.Ordinal));
        Assert.Contains(enhanced.Scenes.SelectMany(scene => scene.Dialogue),
            line => line.Text.Contains("幼苗期", StringComparison.Ordinal));
    }

    private sealed class LiveHttpClientFactory : IHttpClientFactory, IDisposable
    {
        private readonly HttpClient _client = new() { Timeout = Timeout.InfiniteTimeSpan };

        public HttpClient CreateClient(string name) => _client;
        public void Dispose() => _client.Dispose();
    }
}
