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
        services.AddSingleton(new ModelAssetCatalog(Path.Combine(contentRoot, "Resources")));
        services.AddSingleton<IModelAssetStatusReader>(provider =>
            provider.GetRequiredService<ModelAssetCatalog>());
        services.AddSingleton<IFacetInferenceEngine, MultilingualNliInferenceEngine>();
        return services;
    }
}
