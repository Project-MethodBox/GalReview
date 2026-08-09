using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using PracticeService.Application;

namespace PracticeService.Persistence;

public static class DependencyInjection
{
    public static IServiceCollection AddPracticePersistence(this IServiceCollection services, IConfiguration configuration, string contentRoot)
    {
        _ = contentRoot;
        services.AddSingleton<IFacetAdjudicator, GatewayModelFacetAdjudicator>();
        services.AddSingleton<IAnswerScorer, AutomaticAnswerScorer>();
        services.AddSingleton<IPracticeQuestionGenerator, ReciteQuestionGenerator>();
        services.AddSingleton<IPracticeGateway, GatewayClient>();
        services.AddSingleton<ICreditBilling>(sp => sp.GetRequiredService<IPracticeGateway>() as GatewayClient ?? throw new InvalidOperationException("GatewayClient registration is invalid."));
        services.AddSingleton<IPracticePackageCodec, PracticePackageCodec>();
        services.AddHttpClient("gateway", client =>
        {
            client.BaseAddress = new Uri(configuration["Gateway:BaseUrl"] ?? "http://localhost:5000");
            client.Timeout = TimeSpan.FromSeconds(45);
        });
        services.AddHttpClient("question-generation", client =>
        {
            client.Timeout = TimeSpan.FromMinutes(4);
        });
        if (string.Equals(configuration["PracticeStore:Provider"], "Memory", StringComparison.OrdinalIgnoreCase))
        {
            services.AddSingleton<IPracticeRepository, InMemoryPracticeRepository>();
            services.AddSingleton<ISharedPracticePackageStore, InMemorySharedPracticePackageStore>();
        }
        else
        {
            services.AddSingleton<IPracticeRepository, MongoPracticeRepository>();
            services.AddSingleton<ISharedPracticePackageStore, MongoSharedPracticePackageStore>();
        }
        return services;
    }
}
