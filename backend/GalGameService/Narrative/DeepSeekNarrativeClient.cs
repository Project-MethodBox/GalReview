using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

public sealed class DeepSeekNarrativeClient : INarrativeModelClient
{
    private const int MaxResponseCharacters = 1_000_000;

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly NarrativeGenerationOptions _options;

    public DeepSeekNarrativeClient(
        IHttpClientFactory httpClientFactory,
        NarrativeGenerationOptions options)
    {
        _httpClientFactory = httpClientFactory;
        _options = options;
    }

    public bool IsEnabled => _options.CanCallProvider;
    public string ModelName => _options.Model;

    public async Task<string> GenerateJsonAsync(
        NarrativePrompt prompt,
        CancellationToken cancellationToken)
    {
        if (!IsEnabled)
            throw new InvalidOperationException("叙事模型未启用或配置不完整");

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(_options.TimeoutSeconds, 10, 300)));

        var body = new
        {
            model = _options.Model,
            messages = new object[]
            {
                new { role = "system", content = prompt.System },
                new { role = "user", content = prompt.User },
            },
            response_format = new { type = "json_object" },
            thinking = new { type = "disabled" },
            temperature = Math.Clamp(_options.Temperature, 0, 2),
            max_tokens = Math.Clamp(_options.MaxOutputTokens, 1_000, 32_000),
            stream = false,
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, _options.Endpoint)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.ApiKey.Trim());
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        var client = _httpClientFactory.CreateClient("narrative");
        using var response = await client.SendAsync(
            request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"Narrative provider returned HTTP {(int)response.StatusCode}.",
                null,
                response.StatusCode);

        if (response.Content.Headers.ContentLength is > MaxResponseCharacters)
            throw new InvalidDataException("Narrative provider response exceeded the size limit.");

        var responseText = await response.Content.ReadAsStringAsync(timeout.Token);
        if (responseText.Length > MaxResponseCharacters)
            throw new InvalidDataException("Narrative provider response exceeded the size limit.");

        using var document = JsonDocument.Parse(responseText);
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("choices", out var choices)
            || choices.ValueKind != JsonValueKind.Array
            || choices.GetArrayLength() == 0)
            throw new InvalidDataException("Narrative provider returned no choices.");

        var first = choices[0];
        if (first.TryGetProperty("finish_reason", out var finishReason)
            && !string.Equals(finishReason.GetString(), "stop", StringComparison.Ordinal))
            throw new InvalidDataException("Narrative provider response was incomplete.");

        if (first.ValueKind != JsonValueKind.Object
            || !first.TryGetProperty("message", out var message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("content", out var contentElement)
            || contentElement.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
            throw new InvalidDataException("Narrative provider returned an invalid message envelope.");

        var content = contentElement.GetString();
        if (string.IsNullOrWhiteSpace(content))
            throw new InvalidDataException("Narrative provider returned empty content.");

        return content;
    }
}
