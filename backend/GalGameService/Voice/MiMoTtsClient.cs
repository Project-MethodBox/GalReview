using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

public interface ITtsClient
{
    bool IsEnabled { get; }
    string ModelName { get; }

    Task<SynthesizedAudio> SynthesizeAsync(
        string text,
        string voice,
        string context,
        CancellationToken cancellationToken = default);
}

public sealed record SynthesizedAudio(byte[] Data, string ContentType);

public sealed class MiMoTtsClient : ITtsClient
{
    private const string AudioFormat = "wav";

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly VoiceSynthesisOptions _options;

    public MiMoTtsClient(
        IHttpClientFactory httpClientFactory,
        VoiceSynthesisOptions options)
    {
        _httpClientFactory = httpClientFactory;
        _options = options;
    }

    public bool IsEnabled => _options.CanCallProvider;
    public string ModelName => _options.Model;

    public async Task<SynthesizedAudio> SynthesizeAsync(
        string text,
        string voice,
        string context,
        CancellationToken cancellationToken = default)
    {
        if (!IsEnabled)
            throw new InvalidOperationException("MiMo voice synthesis is not enabled or configured.");
        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("Speech text cannot be blank.", nameof(text));
        if (text.Length > Math.Clamp(_options.MaxTextCharacters, 1, 10_000))
            throw new InvalidDataException("Speech text exceeded the configured length limit.");
        if (string.IsNullOrWhiteSpace(voice))
            throw new ArgumentException("MiMo preset voice cannot be blank.", nameof(voice));

        var maxAttempts = Math.Clamp(_options.MaxAttempts, 1, 4);
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await SendOnceAsync(text, voice, context, cancellationToken);
            }
            catch (Exception exception) when (
                attempt < maxAttempts
                && IsRetryable(exception, cancellationToken))
            {
                var baseDelay = Math.Clamp(_options.RetryBaseDelayMilliseconds, 0, 5_000);
                var delayMilliseconds = Math.Min(baseDelay * (1 << (attempt - 1)), 5_000);
                if (delayMilliseconds > 0)
                    await Task.Delay(delayMilliseconds, cancellationToken);
            }
        }
    }

    private async Task<SynthesizedAudio> SendOnceAsync(
        string text,
        string voice,
        string context,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(_options.TimeoutSeconds, 10, 300)));

        var messages = new List<object>();
        if (!string.IsNullOrWhiteSpace(context))
            messages.Add(new { role = "user", content = context.Trim() });
        messages.Add(new { role = "assistant", content = text.Trim() });

        var body = new
        {
            model = _options.Model,
            messages,
            audio = new { format = AudioFormat, voice },
            stream = false,
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, _options.Endpoint)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.ApiKey.Trim());
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

        var client = _httpClientFactory.CreateClient("mimo-tts");
        using var response = await client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            timeout.Token);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"MiMo TTS returned HTTP {(int)response.StatusCode}.",
                null,
                response.StatusCode);

        var maxAudioBytes = Math.Clamp(_options.MaxAudioBytes, 64 * 1024, 12 * 1024 * 1024);
        var maxResponseCharacters = checked(maxAudioBytes * 2);
        var responseText = await ReadBoundedAsync(
            response.Content,
            maxResponseCharacters,
            timeout.Token);

        using var document = JsonDocument.Parse(responseText);
        if (!TryReadAudioData(document.RootElement, out var audioData))
            throw new InvalidDataException("MiMo TTS returned no audio data.");

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(audioData);
        }
        catch (FormatException exception)
        {
            throw new InvalidDataException("MiMo TTS returned invalid Base64 audio data.", exception);
        }

        if (bytes.Length == 0 || bytes.Length > maxAudioBytes)
            throw new InvalidDataException("MiMo TTS audio exceeded the configured size limit.");

        return new SynthesizedAudio(bytes, "audio/wav");
    }

    private static bool TryReadAudioData(JsonElement root, out string data)
    {
        data = string.Empty;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("choices", out var choices)
            || choices.ValueKind != JsonValueKind.Array
            || choices.GetArrayLength() == 0)
            return false;

        var first = choices[0];
        if (first.ValueKind != JsonValueKind.Object
            || !first.TryGetProperty("message", out var message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("audio", out var audio)
            || audio.ValueKind != JsonValueKind.Object
            || !audio.TryGetProperty("data", out var dataElement)
            || dataElement.ValueKind != JsonValueKind.String)
            return false;

        data = dataElement.GetString() ?? string.Empty;
        return data.Length > 0;
    }

    private static bool IsRetryable(Exception exception, CancellationToken callerToken)
    {
        if (callerToken.IsCancellationRequested)
            return false;

        if (exception is OperationCanceledException or JsonException or InvalidDataException)
            return true;

        return exception is HttpRequestException http
            && (http.StatusCode is null
                || http.StatusCode is System.Net.HttpStatusCode.RequestTimeout
                || (int)http.StatusCode == 429
                || (int)http.StatusCode >= 500);
    }

    private static async Task<string> ReadBoundedAsync(
        HttpContent content,
        int maxCharacters,
        CancellationToken cancellationToken)
    {
        await using var stream = await content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var builder = new StringBuilder();
        var buffer = new char[8192];
        int read;
        while ((read = await reader.ReadAsync(buffer, cancellationToken)) > 0)
        {
            if (builder.Length + read > maxCharacters)
                throw new InvalidDataException("MiMo TTS response exceeded the configured size limit.");
            builder.Append(buffer, 0, read);
        }

        return builder.ToString();
    }
}
