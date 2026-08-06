using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

public sealed class MiMoTtsClientTests
{
    [Fact]
    public async Task SynthesizeAsync_SendsMiMoTtsRequestAndDecodesWav()
    {
        var expectedAudio = new byte[] { 82, 73, 70, 70, 1, 2, 3, 4 };
        var responseBody = JsonSerializer.Serialize(new
        {
            choices = new[]
            {
                new
                {
                    message = new
                    {
                        audio = new { data = Convert.ToBase64String(expectedAudio) },
                    },
                },
            },
        });
        var handler = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(responseBody, Encoding.UTF8, "application/json"),
        });
        using var factory = new TestHttpClientFactory(handler);
        var client = new MiMoTtsClient(factory, Options());

        var result = await client.SynthesizeAsync(
            "今天也一起复习吧。",
            "茉莉",
            "青年女性，语气温柔。",
            CancellationToken.None);

        Assert.Equal("audio/wav", result.ContentType);
        Assert.Equal(expectedAudio, result.Data);
        Assert.Equal("Bearer", handler.AuthorizationScheme);
        Assert.Equal("test-mimo-key", handler.AuthorizationParameter);

        using var request = JsonDocument.Parse(handler.RequestBody!);
        Assert.Equal("mimo-v2.5-tts", request.RootElement.GetProperty("model").GetString());
        Assert.False(request.RootElement.GetProperty("stream").GetBoolean());
        Assert.Equal("wav", request.RootElement.GetProperty("audio").GetProperty("format").GetString());
        Assert.Equal("茉莉", request.RootElement.GetProperty("audio").GetProperty("voice").GetString());

        var messages = request.RootElement.GetProperty("messages");
        Assert.Equal("user", messages[0].GetProperty("role").GetString());
        Assert.Equal("青年女性，语气温柔。", messages[0].GetProperty("content").GetString());
        Assert.Equal("assistant", messages[1].GetProperty("role").GetString());
        Assert.Equal("今天也一起复习吧。", messages[1].GetProperty("content").GetString());
    }

    [Fact]
    public async Task SynthesizeAsync_RateLimited_Retries()
    {
        var calls = 0;
        var handler = new RecordingHandler(_ =>
        {
            calls++;
            if (calls == 1)
                return new HttpResponseMessage(HttpStatusCode.TooManyRequests);

            var body = "{\"choices\":[{\"message\":{\"audio\":{\"data\":\"UklGRg==\"}}}]}";
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        });
        using var factory = new TestHttpClientFactory(handler);
        var client = new MiMoTtsClient(factory, Options());

        var result = await client.SynthesizeAsync("重试", "冰糖", string.Empty);

        Assert.Equal(2, calls);
        Assert.NotEmpty(result.Data);
    }

    private static VoiceSynthesisOptions Options() => new()
    {
        Enabled = true,
        ApiKey = "test-mimo-key",
        Model = "mimo-v2.5-tts",
        Endpoint = "https://api.xiaomimimo.com/v1/chat/completions",
        MaxAttempts = 2,
        RetryBaseDelayMilliseconds = 0,
    };

    private sealed class RecordingHandler(
        Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public string? RequestBody { get; private set; }
        public string? AuthorizationScheme { get; private set; }
        public string? AuthorizationParameter { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestBody = await request.Content!.ReadAsStringAsync(cancellationToken);
            AuthorizationScheme = request.Headers.Authorization?.Scheme;
            AuthorizationParameter = request.Headers.Authorization?.Parameter;
            return respond(request);
        }
    }

    private sealed class TestHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory, IDisposable
    {
        private readonly HttpClient _client = new(handler) { Timeout = Timeout.InfiniteTimeSpan };
        public HttpClient CreateClient(string name) => _client;
        public void Dispose() => _client.Dispose();
    }
}
