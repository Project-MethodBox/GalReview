using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

public sealed class NarrativeGenerationServiceTests
{
    [Fact]
    public async Task GenerateAsync_InvalidModelDraftUsesCompleteFallback()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var service = CreateService(new StubNarrativeClient("{\"promptVersion\":\"wrong\",\"scenes\":[]}"));

        var package = await service.GenerateAsync(plan, request, NarrativeTestData.OwnerUserId.ToString());

        Assert.Equal("图书馆的自习时光", package.Scenes[0].Title);
        Assert.True(new GamePackageValidator().Validate(package).Valid);
    }

    [Fact]
    public async Task GenerateAsync_ValidDraftProducesNarrativePackage()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var service = CreateService(new StubNarrativeClient(NarrativeTestData.CreateValidDraftJson(skeleton)));
        var progress = new List<int>();

        var package = await service.GenerateAsync(
            plan,
            request,
            NarrativeTestData.OwnerUserId.ToString(),
            progress.Add);

        Assert.Equal("雨停前的温室记录", package.Scenes[0].Title);
        Assert.Contains(package.Scenes.SelectMany(scene => scene.Dialogue),
            line => line.Text.Contains("解决了问题", StringComparison.Ordinal));
        Assert.True(new GamePackageValidator().Validate(package).Valid);
        Assert.Equal(new[] { 20, 25, 50, 85 }, progress);
    }

    [Fact]
    public async Task GenerateAsync_FirstDraftInvalid_RequestsOneRepair()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var skeleton = NarrativeTestData.CreateSkeleton(plan, request);
        var client = new StubNarrativeClient(
            "{\"promptVersion\":\"wrong\",\"scenes\":[]}",
            NarrativeTestData.CreateValidDraftJson(skeleton));
        var service = CreateService(client);
        var progress = new List<int>();

        var package = await service.GenerateAsync(
            plan,
            request,
            NarrativeTestData.OwnerUserId.ToString(),
            progress.Add);

        Assert.Equal(2, client.CallCount);
        Assert.Equal("雨停前的温室记录", package.Scenes[0].Title);
        Assert.Equal(new[] { 20, 25, 50, 55, 65, 85 }, progress);
    }

    [Fact]
    public async Task GenerateAsync_NonJsonThreeTimesUsesFallback()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();
        var client = new StubNarrativeClient("not-json");

        var package = await CreateService(client).GenerateAsync(
            plan, request, NarrativeTestData.OwnerUserId.ToString());

        Assert.Equal(3, client.CallCount);
        Assert.Equal("图书馆的自习时光", package.Scenes[0].Title);
        Assert.True(new GamePackageValidator().Validate(package).Valid);
    }

    [Fact]
    public async Task GenerateAsync_ProviderHttpFailureUsesFallbackWithoutLeakingDetail()
    {
        var plan = NarrativeTestData.CreatePlan();
        var request = NarrativeTestData.CreateRequest();

        var package = await CreateService(new ThrowingNarrativeClient()).GenerateAsync(
            plan, request, NarrativeTestData.OwnerUserId.ToString());

        Assert.Equal("图书馆的自习时光", package.Scenes[0].Title);
        Assert.True(new GamePackageValidator().Validate(package).Valid);
    }

    private static NarrativeGenerationService CreateService(INarrativeModelClient client)
    {
        var packageValidator = new GamePackageValidator();
        var options = new NarrativeGenerationOptions
        {
            Enabled = true,
            ApiKey = "test-only-key",
            PromptVersion = NarrativeTestData.PromptVersion,
        };
        return new NarrativeGenerationService(
            new GameGenerator(packageValidator, NullLogger<GameGenerator>.Instance),
            new NarrativePromptBuilder(),
            new NarrativeDraftValidator(packageValidator),
            client,
            options,
            NullLogger<NarrativeGenerationService>.Instance);
    }

    private sealed class StubNarrativeClient : INarrativeModelClient
    {
        private readonly Queue<string> _responses;

        internal StubNarrativeClient(params string[] responses) => _responses = new Queue<string>(responses);

        public bool IsEnabled => true;
        public string ModelName => "stub";
        public int CallCount { get; private set; }

        public Task<string> GenerateJsonAsync(NarrativePrompt prompt, CancellationToken cancellationToken)
        {
            CallCount++;
            var response = _responses.Count > 1 ? _responses.Dequeue() : _responses.Peek();
            return Task.FromResult(response);
        }
    }

    private sealed class ThrowingNarrativeClient : INarrativeModelClient
    {
        public bool IsEnabled => true;
        public string ModelName => "throwing-stub";

        public Task<string> GenerateJsonAsync(NarrativePrompt prompt, CancellationToken cancellationToken) =>
            throw new HttpRequestException("test provider detail that must remain internal");
    }
}
