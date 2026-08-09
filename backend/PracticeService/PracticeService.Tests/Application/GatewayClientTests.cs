using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PracticeService.Persistence;
using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace PracticeService.Tests.Application;

public sealed class GatewayClientTests
{
    [Fact]
    public async Task Graph_scope_reads_binding_candidates_from_the_existing_internal_response()
    {
        var graphId = Guid.NewGuid(); var materialId = Guid.NewGuid(); var projectId = Guid.NewGuid();
        var owner = Guid.NewGuid(); var pointId = Guid.NewGuid(); var chapterId = Guid.NewGuid();
        var body = JsonSerializer.Serialize(new
        {
            data = new
            {
                graphId,
                materialId,
                studyProjectId = projectId,
                ownerUserId = owner,
                points = new[] { new { pointId, chapterId, title = "第二性比", summary = "出生时的雌雄比例", tags = new[] { "性比" },
                    sourceReferences = new[] { new { materialId, startOffset = 12, endOffset = 24 } } } }
            }
        });
        var factory = new StubHttpClientFactory(new HttpClient(new StubHandler(body)) { BaseAddress = new Uri("http://gateway") });
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Gateway:ServiceKey"] = "test-key"
        }).Build();
        var client = new GatewayClient(factory, configuration, NullLogger<GatewayClient>.Instance);

        var scope = await client.GetGraphScopeAsync(graphId, owner, CancellationToken.None);

        var point = Assert.Single(scope.Points);
        Assert.Equal(projectId, scope.StudyProjectId);
        Assert.Equal(pointId, point.KnowledgePointId);
        Assert.Equal("第二性比", point.Title);
        Assert.Equal(["性比"], point.Tags);
        var source = Assert.Single(point.SourceReferences!);
        Assert.Equal((12, 24), (source.StartOffset, source.EndOffset));
    }

    private sealed class StubHttpClientFactory(HttpClient client) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client;
    }

    private sealed class StubHandler(string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            });
    }
}
