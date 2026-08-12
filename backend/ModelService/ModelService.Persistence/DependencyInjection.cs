using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using ModelService.Application;

namespace ModelService.Persistence;

public static class DependencyInjection
{
    public static IServiceCollection AddModelPersistence(
        this IServiceCollection services,
        IConfiguration configuration,
        string contentRoot)
    {
        var configuredRoot = configuration["ModelResources:RootPath"];
        var resourceRoot = string.IsNullOrWhiteSpace(configuredRoot)
            ? Path.Combine(contentRoot, "Resources")
            : Path.GetFullPath(configuredRoot, contentRoot);
        services.AddSingleton(new ModelAssetCatalog(resourceRoot));
        services.AddSingleton<IModelAssetStatusReader>(provider =>
            provider.GetRequiredService<ModelAssetCatalog>());
        services.AddSingleton<IFacetInferenceEngine, MultilingualNliInferenceEngine>();
        return services;
    }
}
