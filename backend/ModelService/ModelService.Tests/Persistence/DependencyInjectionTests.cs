using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using ModelService.Persistence;
using Xunit;

namespace ModelService.Tests.Persistence;

public sealed class DependencyInjectionTests
{
    [Fact]
    public void Configured_resource_root_overrides_release_content_root()
    {
        var contentRoot = Path.GetFullPath(Path.Combine("release", "model-service"));
        var sharedRoot = Path.GetFullPath(Path.Combine(".production", "shared", "model-resources"));
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ModelResources:RootPath"] = sharedRoot
            })
            .Build();
        var services = new ServiceCollection();

        services.AddModelPersistence(configuration, contentRoot);
        using var provider = services.BuildServiceProvider();

        var catalog = provider.GetRequiredService<ModelAssetCatalog>();
        Assert.Equal(
            Path.Combine(sharedRoot, "Models", "multilingual-minilm-nli", "model.onnx"),
            catalog.NliModelPath);
    }
}
