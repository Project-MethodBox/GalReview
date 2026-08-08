using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

public sealed class DeepSeekNarrativeClientTests
{
    [Fact]
    public async Task GenerateJsonAsync_EmptyJsonModeContent_RetriesAndReturnsNextDraft()
    {
        var handler = new SequenceHandler(
            Completion(string.Empty),
            Completion("{\"promptVersion\":\"ok\",\"scenes\":[]}"));
        using var factory = new TestHttpClientFactory(handler);
        var client = new DeepSeekNarrativeClient(factory, Options());

        var result = await client.GenerateJsonAsync(
            new NarrativePrompt("return json", "json example: {}"),
            CancellationToken.None);

        Assert.Equal("{\"promptVersion\":\"ok\",\"scenes\":[]}", result.Json);
        Assert.Equal(246, result.TotalTokens);
        Assert.Equal(2, handler.CallCount);
    }

    [Fact]
    public async Task GenerateJsonAsync_MissingUsage_FailsWithoutGuessingOrRetrying()
    {
        var body = JsonSerializer.Serialize(new
        {
            choices = new[] { new { finish_reason = "stop", message = new { content = "{}" } } },
        });
        var handler = new SequenceHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        });
        using var factory = new TestHttpClientFactory(handler);
        var client = new DeepSeekNarrativeClient(factory, Options());

        var exception = await Assert.ThrowsAnyAsync<Exception>(() => client.GenerateJsonAsync(
            new NarrativePrompt("return json", "json example: {}"),
            CancellationToken.None));

        Assert.Contains("token usage", exception.Message, StringComparison.Ordinal);
        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public async Task GenerateJsonAsync_RateLimited_RetriesAndUsesV4JsonRequest()
    {
        var handler = new SequenceHandler(
            new HttpResponseMessage(HttpStatusCode.TooManyRequests),
            Completion("{\"promptVersion\":\"ok\",\"scenes\":[]}"));
        using var factory = new TestHttpClientFactory(handler);
        var client = new DeepSeekNarrativeClient(factory, Options());

        await client.GenerateJsonAsync(
            new NarrativePrompt("return json", "json example: {}"),
            CancellationToken.None);

        Assert.Equal(2, handler.CallCount);
        using var requestBody = JsonDocument.Parse(handler.RequestBodies[^1]);
        Assert.Equal("deepseek-v4-flash", requestBody.RootElement.GetProperty("model").GetString());
        Assert.Equal("json_object", requestBody.RootElement
            .GetProperty("response_format").GetProperty("type").GetString());
        Assert.Equal("disabled", requestBody.RootElement
            .GetProperty("thinking").GetProperty("type").GetString());
    }

    [Fact]
    public async Task GenerateJsonAsync_Unauthorized_DoesNotRetry()
    {
        var handler = new SequenceHandler(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        using var factory = new TestHttpClientFactory(handler);
        var client = new DeepSeekNarrativeClient(factory, Options());

        await Assert.ThrowsAsync<HttpRequestException>(() => client.GenerateJsonAsync(
            new NarrativePrompt("return json", "json example: {}"),
            CancellationToken.None));

        Assert.Equal(1, handler.CallCount);
    }

    private static NarrativeGenerationOptions Options() => new()
    {
        Enabled = true,
        ApiKey = "test-only-key",
        Model = "deepseek-v4-flash",
        MaxProviderAttempts = 3,
        RetryBaseDelayMilliseconds = 0,
    };

    private static HttpResponseMessage Completion(string content)
    {
        var body = JsonSerializer.Serialize(new
        {
            choices = new[]
            {
                new { finish_reason = "stop", message = new { content } },
            },
            usage = new { total_tokens = 123 },
        });
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class SequenceHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private readonly Queue<HttpResponseMessage> _responses = new(responses);
        public int CallCount { get; private set; }
        public List<string> RequestBodies { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount++;
            RequestBodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return _responses.Dequeue();
        }
    }

    private sealed class TestHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory, IDisposable
    {
        private readonly HttpClient _client = new(handler) { Timeout = Timeout.InfiniteTimeSpan };
        public HttpClient CreateClient(string name) => _client;
        public void Dispose() => _client.Dispose();
    }
}
