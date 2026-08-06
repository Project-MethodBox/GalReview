using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

public sealed class PackageVoiceServiceTests
{
    [Fact]
    public async Task SynthesizeAsync_AddsDeterministicAssetsForCharacterLinesOnly()
    {
        var tts = new RecordingTtsClient();
        var service = new PackageVoiceService(
            tts,
            new VoiceSynthesisOptions { Enabled = true, ApiKey = "test", MaxConcurrency = 2 },
            NullLogger<PackageVoiceService>.Instance);
        var packageId = Guid.NewGuid();
        var package = new GamePackage(
            "1.0",
            packageId,
            "test",
            Guid.NewGuid(),
            "snapshot",
            "scene-001",
            [
                new Scene(
                    "scene-001",
                    null,
                    [
                        new DialogueLine("旁白", "风吹过教室。", null),
                        new DialogueLine("你", "我准备好了。", null),
                        new DialogueLine("林澈", "先从第一题开始吧。", "warm"),
                        new DialogueLine("新角色", "我也加入。", "playful"),
                    ],
                    [],
                    []),
            ],
            []);

        var result = await service.SynthesizeAsync(package);

        Assert.Equal(2, tts.Calls.Count);
        Assert.Contains(tts.Calls, call => call.Text == "先从第一题开始吧。" && call.Voice == "茉莉");
        Assert.Contains(tts.Calls, call => call.Text == "我也加入。" && call.Voice == "茉莉");
        Assert.Collection(
            result.Package.Assets,
            asset =>
            {
                Assert.Equal("voice-000-002", asset.AssetId);
                Assert.Equal(AssetType.AUDIO, asset.Type);
                Assert.Equal($"/api/v1/game-packages/{packageId}/audio/voice-000-002", asset.Uri);
            },
            asset => Assert.Equal("voice-000-003", asset.AssetId));
        Assert.Equal(2, result.AudioAssets.Count);
        Assert.All(result.AudioAssets, asset => Assert.Equal("audio/wav", asset.ContentType));
    }

    [Fact]
    public async Task SynthesizeAsync_Disabled_ReturnsOriginalPackage()
    {
        var tts = new RecordingTtsClient { IsEnabled = false };
        var service = new PackageVoiceService(
            tts,
            new VoiceSynthesisOptions(),
            NullLogger<PackageVoiceService>.Instance);
        var package = new GamePackage(
            "1.0", Guid.NewGuid(), "test", Guid.NewGuid(), "snapshot", "scene", [], []);

        var result = await service.SynthesizeAsync(package);

        Assert.Same(package, result.Package);
        Assert.Empty(result.AudioAssets);
        Assert.Empty(tts.Calls);
    }

    private sealed class RecordingTtsClient : ITtsClient
    {
        public bool IsEnabled { get; set; } = true;
        public string ModelName => "mimo-v2.5-tts";
        public List<(string Text, string Voice, string Context)> Calls { get; } = [];

        public Task<SynthesizedAudio> SynthesizeAsync(
            string text,
            string voice,
            string context,
            CancellationToken cancellationToken = default)
        {
            lock (Calls)
                Calls.Add((text, voice, context));
            return Task.FromResult(new SynthesizedAudio([82, 73, 70, 70], "audio/wav"));
        }
    }
}
