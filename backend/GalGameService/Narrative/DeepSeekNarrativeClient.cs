using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
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

    public async Task<NarrativeModelResult> GenerateJsonAsync(
        NarrativePrompt prompt,
        CancellationToken cancellationToken)
    {
        if (!IsEnabled)
            throw new InvalidOperationException("叙事模型未启用或配置不完整");

        var maxAttempts = Math.Clamp(_options.MaxProviderAttempts, 1, 4);
        long consumedByRejectedResponses = 0;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                var result = await SendOnceAsync(prompt, cancellationToken);
                return result with { TotalTokens = checked(result.TotalTokens + consumedByRejectedResponses) };
            }
            catch (Exception exception) when (
                attempt < maxAttempts
                && IsRetryable(exception, cancellationToken))
            {
                if (exception is NarrativeProviderPayloadException payload)
                    consumedByRejectedResponses = checked(consumedByRejectedResponses + payload.ConsumedTokens);
                var baseDelay = Math.Clamp(_options.RetryBaseDelayMilliseconds, 0, 5_000);
                var delayMilliseconds = Math.Min(baseDelay * (1 << (attempt - 1)), 5_000);
                if (delayMilliseconds > 0)
                    await Task.Delay(delayMilliseconds, cancellationToken);
            }
        }
    }

    private async Task<NarrativeModelResult> SendOnceAsync(
        NarrativePrompt prompt,
        CancellationToken cancellationToken)
    {
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

        // 必须自己限长读取：请求用 ResponseHeadersRead 发送，HttpClient 的
        // MaxResponseContentBufferSize 不再生效；对无 Content-Length 的 chunked 响应，
        // ReadAsStringAsync 会把整个响应体无界缓冲进内存（上限 int.MaxValue），
        // 故障或被劫持的上游可在超时窗口内把容器吃到 OOM。
        var responseText = await ReadBoundedAsync(response.Content, MaxResponseCharacters, timeout.Token);

        using var document = JsonDocument.Parse(responseText);
        if (!document.RootElement.TryGetProperty("usage", out var usage)
            || usage.ValueKind != JsonValueKind.Object
            || !usage.TryGetProperty("total_tokens", out var total)
            || !total.TryGetInt64(out var totalTokens)
            || totalTokens <= 0)
            throw new NarrativeUsageMissingException();

        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("choices", out var choices)
            || choices.ValueKind != JsonValueKind.Array
            || choices.GetArrayLength() == 0)
            throw new NarrativeProviderPayloadException("Narrative provider returned no choices.", totalTokens);

        var first = choices[0];
        if (first.TryGetProperty("finish_reason", out var finishReason)
            && !string.Equals(finishReason.GetString(), "stop", StringComparison.Ordinal))
            throw new NarrativeProviderPayloadException("Narrative provider response was incomplete.", totalTokens);

        if (first.ValueKind != JsonValueKind.Object
            || !first.TryGetProperty("message", out var message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("content", out var contentElement)
            || contentElement.ValueKind is not (JsonValueKind.String or JsonValueKind.Null))
            throw new NarrativeProviderPayloadException("Narrative provider returned an invalid message envelope.", totalTokens);

        var content = contentElement.GetString();
        if (string.IsNullOrWhiteSpace(content))
            throw new NarrativeProviderPayloadException("Narrative provider returned empty content.", totalTokens);
        return new NarrativeModelResult(content, totalTokens);
    }

    private static bool IsRetryable(Exception exception, CancellationToken callerToken)
    {
        if (callerToken.IsCancellationRequested)
            return false;

        if (exception is NarrativeUsageMissingException)
            return false;

        if (exception is OperationCanceledException or JsonException or InvalidDataException or NarrativeProviderPayloadException)
            return true;

        return exception is HttpRequestException http
            && (http.StatusCode is null
                || http.StatusCode is System.Net.HttpStatusCode.RequestTimeout
                || (int)http.StatusCode == 429
                || (int)http.StatusCode >= 500);
    }

    /// <summary>
    /// 按字符上限读取响应体，一旦越界立即抛出并停止读取（连接随 response 释放而中断），
    /// 从而给 chunked / 无 Content-Length 的响应也加上真正的内存上限。
    /// </summary>
    private static async Task<string> ReadBoundedAsync(
        HttpContent content, int maxCharacters, CancellationToken cancellationToken)
    {
        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var builder = new StringBuilder();
        var buffer = new char[8192];
        int read;
        while ((read = await reader.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (builder.Length + read > maxCharacters)
                throw new InvalidDataException("Narrative provider response exceeded the size limit.");
            builder.Append(buffer, 0, read);
        }

        return builder.ToString();
    }
}

internal sealed class NarrativeProviderPayloadException(string message, long consumedTokens) : Exception(message)
{
    public long ConsumedTokens { get; } = consumedTokens;
}

internal sealed class NarrativeUsageMissingException() : Exception("Narrative provider response did not include valid token usage.");
