using System.Collections.Concurrent;
using System.Text.Json;

public sealed record PackageVoiceResult(
    GamePackage Package,
    IReadOnlyList<GameAudioAsset> AudioAssets);

public sealed class PackageVoiceService
{
    private readonly ITtsClient _ttsClient;
    private readonly VoiceSynthesisOptions _options;
    private readonly CharacterVoiceCatalog _characterVoiceCatalog;
    private readonly ILogger<PackageVoiceService> _logger;

    public PackageVoiceService(
        ITtsClient ttsClient,
        VoiceSynthesisOptions options,
        ILogger<PackageVoiceService> logger)
        : this(ttsClient, options, CharacterVoiceCatalog.LoadDefault(), logger)
    {
    }

    public PackageVoiceService(
        ITtsClient ttsClient,
        VoiceSynthesisOptions options,
        CharacterVoiceCatalog characterVoiceCatalog,
        ILogger<PackageVoiceService> logger)
    {
        _ttsClient = ttsClient;
        _options = options;
        _characterVoiceCatalog = characterVoiceCatalog;
        _logger = logger;
    }

    public async Task<PackageVoiceResult> SynthesizeAsync(
        GamePackage package,
        Action<int>? reportProgress = null,
        CancellationToken cancellationToken = default)
    {
        if (!_ttsClient.IsEnabled)
            return new PackageVoiceResult(package, Array.Empty<GameAudioAsset>());

        var lines = package.Scenes
            .SelectMany((scene, sceneIndex) => scene.Dialogue.Select((line, lineIndex) =>
                new PendingDialogue(sceneIndex, lineIndex, scene.SceneId, line)))
            .Where(item => ShouldSynthesize(item.Line))
            .ToArray();
        if (lines.Length == 0)
            return new PackageVoiceResult(package, Array.Empty<GameAudioAsset>());

        var generated = new ConcurrentBag<GeneratedVoice>();
        var completed = 0;
        using var gate = new SemaphoreSlim(Math.Clamp(_options.MaxConcurrency, 1, 6));

        var tasks = lines.Select(async item =>
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                var profile = _characterVoiceCatalog.ResolveVoice(item.Line.SpeakerId);
                var context = _characterVoiceCatalog.BuildVoiceContext(profile, item.Line.Emotion);
                var audio = await _ttsClient.SynthesizeAsync(
                    item.Line.Text,
                    profile.Voice,
                    context,
                    cancellationToken);
                var assetId = VoiceAssetId(item.SceneIndex, item.LineIndex);
                var uri = $"/api/v1/game-packages/{package.PackageId}/audio/{assetId}";
                generated.Add(new GeneratedVoice(
                    item.SceneIndex,
                    item.LineIndex,
                    new AssetRef(assetId, AssetType.AUDIO, uri),
                    new GameAudioAsset(
                        package.PackageId,
                        assetId,
                        audio.ContentType,
                        audio.Data,
                        DateTimeOffset.UtcNow)));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception) when (
                exception is HttpRequestException
                    or JsonException
                    or InvalidDataException
                    or InvalidOperationException
                    or ArgumentException
                    or OperationCanceledException)
            {
                _logger.LogWarning(
                    "MiMo voice synthesis skipped package {PackageId}, scene {SceneId}, line {LineIndex}; failureType={FailureType}",
                    package.PackageId,
                    item.SceneId,
                    item.LineIndex,
                    exception.GetType().Name);
            }
            finally
            {
                gate.Release();
                var done = Interlocked.Increment(ref completed);
                reportProgress?.Invoke(86 + (int)Math.Floor(7d * done / lines.Length));
            }
        }).ToArray();

        await Task.WhenAll(tasks);

        var ordered = generated
            .OrderBy(item => item.SceneIndex)
            .ThenBy(item => item.LineIndex)
            .ToArray();
        if (ordered.Length == 0)
            return new PackageVoiceResult(package, Array.Empty<GameAudioAsset>());

        var packageAssets = package.Assets ?? Array.Empty<AssetRef>();
        var enriched = package with
        {
            Assets = packageAssets.Concat(ordered.Select(item => item.Reference)).ToArray(),
        };

        _logger.LogInformation(
            "MiMo voice synthesis completed for package {PackageId}; generated={Generated}; requested={Requested}; model={Model}",
            package.PackageId,
            ordered.Length,
            lines.Length,
            _ttsClient.ModelName);

        return new PackageVoiceResult(enriched, ordered.Select(item => item.Audio).ToArray());
    }

    public static string VoiceAssetId(int sceneIndex, int lineIndex) =>
        $"voice-{sceneIndex:D3}-{lineIndex:D3}";

    private bool ShouldSynthesize(DialogueLine line) =>
        line is not null
        && !string.IsNullOrWhiteSpace(line.Text)
        && _characterVoiceCatalog.ShouldSynthesize(line.SpeakerId);

    private sealed record PendingDialogue(int SceneIndex, int LineIndex, string SceneId, DialogueLine Line);
    private sealed record GeneratedVoice(
        int SceneIndex,
        int LineIndex,
        AssetRef Reference,
        GameAudioAsset Audio);
}
