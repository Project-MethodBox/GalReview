using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PracticeService.Application;
using PracticeService.Domain;
using PracticeService.Persistence;
using Xunit;

namespace PracticeService.Tests.Infrastructure;

public sealed class GatewayModelFacetAdjudicatorTests
{
    [Fact]
    public async Task TimeoutBecomesUnavailableInsteadOfEscapingAsRequestFailure()
    {
        var adjudicator = Create(new ThrowingHandler(cancelCaller: false));

        var result = await adjudicator.AdjudicateAsync(
            "答案",
            [new ReferenceFacet("必要事实")],
            CancellationToken.None);

        Assert.False(result.Available);
        Assert.Equal("MODEL_SERVICE_TIMEOUT", result.FailureReason);
        Assert.Empty(result.Facets);
    }

    [Fact]
    public async Task CallerCancellationIsNotSwallowed()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var adjudicator = Create(new ThrowingHandler(cancelCaller: true));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            adjudicator.AdjudicateAsync(
                "答案",
                [new ReferenceFacet("必要事实")],
                cancellation.Token));
    }

    private static GatewayModelFacetAdjudicator Create(HttpMessageHandler handler)
    {
        var client = new HttpClient(handler) { BaseAddress = new Uri("http://gateway.test") };
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Gateway:ServiceName"] = "PracticeService",
            ["Gateway:ServiceKey"] = "test-key"
        }).Build();
        return new(new SingleClientFactory(client), configuration,
            NullLogger<GatewayModelFacetAdjudicator>.Instance);
    }

    private sealed class SingleClientFactory(HttpClient client) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client;
    }

    private sealed class ThrowingHandler(bool cancelCaller) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (cancelCaller) cancellationToken.ThrowIfCancellationRequested();
            throw new TaskCanceledException("simulated timeout");
        }
    }
}
