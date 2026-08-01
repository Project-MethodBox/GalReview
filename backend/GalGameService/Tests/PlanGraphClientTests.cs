using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

// ============================================================================
// PlanGraph 客户端测试（§7.3.1 URGENT 跨服务阻塞项）
//
// Mock 模式下：
// - 已知 reviewPlanId + 正确 snapshotVersion → 返回 Success
// - 已知 reviewPlanId + 错误 snapshotVersion → 返回 SnapshotMismatch
// - 未知 reviewPlanId → 返回 NotFound
// - 返回的 PlanGraph 包含 questionTarget=true 的节点
// ============================================================================

public class PlanGraphClientTests
{
    private static readonly Guid ContractChapterId = Guid.Parse("7623c5ae-f377-4247-aaf5-bf73378e74ef");
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);

    private static PlanGraphClient CreateMockClient()
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Gateway:BaseUrl"] = "http://localhost:5000",
                ["Gateway:ServiceKey"] = "moonstone-local-gateway-key",
            })
            .Build();

        return new PlanGraphClient(
            httpClientFactory: null!, // Mock 模式不使用 HttpClient
            logger: NullLogger<PlanGraphClient>.Instance,
            configuration: config,
            isMockMode: true);
    }

    [Fact]
    public async Task Mock_KnownPlan_CorrectSnapshot_ReturnsSuccess()
    {
        var client = CreateMockClient();
        var result = await client.GetGraphAsync(
            PlanGraphClient.MockReviewPlanId,
            PlanGraphClient.MockSnapshotVersion,
            traceId: "test-trace-1",
            CancellationToken.None);

        Assert.Equal(PlanGraphFetchStatus.Success, result.Status);
        Assert.NotNull(result.Graph);
        Assert.Equal(PlanGraphClient.MockReviewPlanId, result.Graph!.ReviewPlanId);
        Assert.Equal(PlanGraphClient.MockSnapshotVersion, result.Graph.SnapshotVersion);
        Assert.Equal("LEARNING", result.Graph.Type);
        Assert.Equal("learning-planner-v1", result.Graph.AlgorithmVersion);
        Assert.Equal(new[] { ContractChapterId }, result.Graph.SelectedChapterIds);
    }

    [Fact]
    public async Task Mock_KnownPlan_WrongSnapshot_ReturnsSnapshotMismatch()
    {
        var client = CreateMockClient();
        var result = await client.GetGraphAsync(
            PlanGraphClient.MockReviewPlanId,
            snapshotVersion: "wrong-snapshot-version",
            traceId: "test-trace-2",
            CancellationToken.None);

        Assert.Equal(PlanGraphFetchStatus.SnapshotMismatch, result.Status);
        Assert.Null(result.Graph);
        Assert.NotNull(result.Detail);
    }

    [Fact]
    public async Task Mock_UnknownPlan_ReturnsNotFound()
    {
        var client = CreateMockClient();
        var result = await client.GetGraphAsync(
            reviewPlanId: Guid.Parse("00000000-0000-0000-0000-000000000001"),
            PlanGraphClient.MockSnapshotVersion,
            traceId: "test-trace-3",
            CancellationToken.None);

        Assert.Equal(PlanGraphFetchStatus.NotFound, result.Status);
        Assert.Null(result.Graph);
        Assert.NotNull(result.Detail);
    }

    [Fact]
    public async Task Mock_ReturnedGraph_HasQuestionTargetNode()
    {
        var client = CreateMockClient();
        var result = await client.GetGraphAsync(
            PlanGraphClient.MockReviewPlanId,
            PlanGraphClient.MockSnapshotVersion,
            traceId: "test-trace-4",
            CancellationToken.None);

        Assert.Equal(PlanGraphFetchStatus.Success, result.Status);
        var graph = result.Graph!;
        // PlanGraph 中至少有一个 questionTarget=true 的节点（用于生成计分题）
        Assert.Contains(graph.Nodes, n => n.QuestionTarget);
        // 至少有一条 PREREQUISITE 边（用于讲解场景）
        Assert.NotEmpty(graph.Edges);
    }

    [Fact]
    public async Task Mock_MutableArrays_CannotPolluteLaterSnapshots()
    {
        var client = CreateMockClient();
        var first = await FetchContractGraph(client);
        first.Graph!.Nodes[0].Tags[0] = "已污染";
        first.Graph.SelectedChapterIds[0] = Guid.Empty;

        var second = await FetchContractGraph(client);

        Assert.NotSame(first.Graph, second.Graph);
        Assert.Equal("群体结构", second.Graph!.Nodes[0].Tags[0]);
        Assert.Equal(ContractChapterId, second.Graph.SelectedChapterIds[0]);
    }

    [Fact]
    public async Task NonMock_ContractSuccessEnvelope_ReturnsSuccessAndSendsInternalHeaders()
    {
        var graph = BuildContractGraph();
        var client = CreateNonMockClient((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal(
                $"/internal/v1/review-plans/{PlanGraphClient.MockReviewPlanId}/graph?snapshotVersion={Uri.EscapeDataString(PlanGraphClient.MockSnapshotVersion)}",
                request.RequestUri!.PathAndQuery);
            Assert.Equal("GalGameService", Assert.Single(request.Headers.GetValues("X-Service-Name")));
            Assert.Equal("test-service-key", Assert.Single(request.Headers.GetValues("X-Service-Key")));
            Assert.Equal("caller-trace", Assert.Single(request.Headers.GetValues("X-Correlation-Id")));
            return Task.FromResult(JsonResponse(CreateSuccessEnvelope(graph)));
        });

        var result = await client.GetGraphAsync(
            PlanGraphClient.MockReviewPlanId,
            PlanGraphClient.MockSnapshotVersion,
            "caller-trace",
            CancellationToken.None);

        Assert.Equal(PlanGraphFetchStatus.Success, result.Status);
        Assert.NotNull(result.Graph);
        Assert.Equal(graph.ReviewPlanId, result.Graph!.ReviewPlanId);
        Assert.Equal(graph.SnapshotVersion, result.Graph.SnapshotVersion);
        Assert.Equal(graph.Type, result.Graph.Type);
        Assert.Equal(graph.AlgorithmVersion, result.Graph.AlgorithmVersion);
        Assert.Equal(graph.Nodes.Length, result.Graph.Nodes.Length);
        Assert.Equal(graph.Edges.Length, result.Graph.Edges.Length);
    }

    [Theory]
    [InlineData("missing-meta")]
    [InlineData("non-empty-meta")]
    [InlineData("blank-trace")]
    [InlineData("data-not-object")]
    public async Task NonMock_InvalidSuccessEnvelope_ReturnsUpstreamContractInvalid(string mutation)
    {
        var root = JsonNode.Parse(CreateSuccessEnvelope(BuildContractGraph()))!.AsObject();
        switch (mutation)
        {
            case "missing-meta":
                root.Remove("meta");
                break;
            case "non-empty-meta":
                root["meta"] = new JsonObject { ["unexpected"] = true };
                break;
            case "blank-trace":
                root["traceId"] = " ";
                break;
            case "data-not-object":
                root["data"] = "not-an-object";
                break;
        }

        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(root.ToJsonString(WebJson))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_UnknownContractExtensions_DoNotHideRequiredValidFields()
    {
        var root = JsonNode.Parse(CreateSuccessEnvelope(BuildContractGraph()))!.AsObject();
        root["extension"] = true;
        root["data"]!.AsObject()["extension"] = "future-field";
        root["data"]!["nodes"]![0]!.AsObject()["extension"] = 1;
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(root.ToJsonString(WebJson))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.Success, result.Status);
        Assert.NotNull(result.Graph);
    }

    [Fact]
    public async Task NonMock_Malformed200Json_ReturnsUpstreamContractInvalid()
    {
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse("{not-json")));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_MismatchedReviewPlanIdIn200_ReturnsUpstreamContractInvalid()
    {
        var graph = BuildContractGraph() with { ReviewPlanId = Guid.Parse("768d1844-6f00-4f7b-ae1b-723f7e40d62f") };
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(CreateSuccessEnvelope(graph))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
    }

    [Fact]
    public async Task NonMock_MismatchedSnapshotVersionIn200_ReturnsUpstreamContractInvalid()
    {
        var graph = BuildContractGraph() with { SnapshotVersion = "plan-graph-1.0:different" };
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(CreateSuccessEnvelope(graph))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
    }

    [Fact]
    public async Task NonMock_LearningRootWithoutQuestionTarget_RemainsContractValid()
    {
        var graph = BuildContractGraph();
        graph = graph with
        {
            Nodes = [graph.Nodes[0], graph.Nodes[1] with { QuestionTarget = false }],
            EstimatedQuestionCount = 0,
        };
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(CreateSuccessEnvelope(graph))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.Success, result.Status);
        Assert.NotNull(result.Graph);
    }

    [Theory]
    [InlineData("empty-nodes")]
    [InlineData("wrong-algorithm")]
    [InlineData("dangling-edge")]
    [InlineData("disconnected-prerequisite")]
    [InlineData("root-not-target")]
    [InlineData("outside-flag-mismatch")]
    [InlineData("outside-weight-over-cap")]
    [InlineData("non-utc-date")]
    [InlineData("supports-path-mismatch")]
    public async Task NonMock_InvalidPlanGraphStructure_ReturnsUpstreamContractInvalid(string mutation)
    {
        var graph = BuildContractGraph();
        graph = mutation switch
        {
            "empty-nodes" => graph with { Nodes = [] },
            "wrong-algorithm" => graph with { AlgorithmVersion = "assessment-planner-v1" },
            "dangling-edge" => graph with
            {
                Edges =
                [
                    graph.Edges[0] with
                    {
                        FromPointId = Guid.Parse("479776b9-adf0-4a48-abaa-9bfd0616ba0c"),
                    },
                ],
            },
            "disconnected-prerequisite" => graph with { Edges = [] },
            "root-not-target" => graph with { RootPointIds = [graph.Nodes[0].PointId] },
            "outside-flag-mismatch" => graph with
            {
                Nodes =
                [
                    graph.Nodes[0] with { OutsideRequestedChapters = true },
                    graph.Nodes[1],
                ],
            },
            "outside-weight-over-cap" => graph with
            {
                Nodes =
                [
                    graph.Nodes[0] with
                    {
                        ChapterId = Guid.Parse("edbd0ee3-4a51-44d0-9c72-5560988d1899"),
                        OutsideRequestedChapters = true,
                        Weight = 0.31,
                    },
                    graph.Nodes[1] with { Weight = 0.69 },
                ],
            },
            "non-utc-date" => graph with
            {
                CreatedAt = new DateTimeOffset(2026, 7, 27, 16, 50, 0, TimeSpan.FromHours(8)),
                ExpiresAt = new DateTimeOffset(2026, 8, 3, 16, 50, 0, TimeSpan.FromHours(8)),
            },
            "supports-path-mismatch" => graph with
            {
                Nodes =
                [
                    graph.Nodes[0] with
                    {
                        Weight = 0.3,
                        SupportsPointIds = [Guid.Parse("06bf8906-dafa-49cb-9159-32ff0797b625")],
                    },
                    graph.Nodes[1] with { Weight = 0.5 },
                    graph.Nodes[1] with
                    {
                        PointId = Guid.Parse("06bf8906-dafa-49cb-9159-32ff0797b625"),
                        Title = "另一个学习目标",
                        Weight = 0.2,
                        QuestionTarget = false,
                        CoversPointIds = [Guid.Parse("06bf8906-dafa-49cb-9159-32ff0797b625")],
                        SupportsPointIds = [Guid.Parse("06bf8906-dafa-49cb-9159-32ff0797b625")],
                    },
                ],
            },
            _ => throw new ArgumentOutOfRangeException(nameof(mutation)),
        };
        var client = CreateNonMockClient((_, _) =>
            Task.FromResult(JsonResponse(CreateSuccessEnvelope(graph))));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
    }

    [Fact]
    public async Task NonMock_Upstream503_ReturnsUnavailable()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(ErrorResponse(
            HttpStatusCode.ServiceUnavailable,
            "SERVICE_UNAVAILABLE",
            "知识图谱服务暂不可用")));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.Unavailable, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_Malformed503FailureEnvelope_ReturnsUpstreamContractInvalid()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_Contract400Failure_ReturnsInvalidRequest()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(ErrorResponse(
            HttpStatusCode.BadRequest,
            "VALIDATION_ERROR",
            "snapshotVersion Query 无效")));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.InvalidRequest, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_Malformed400FailureEnvelope_ReturnsUpstreamContractInvalid()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.BadRequest)));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_Contract409Failure_ReturnsSnapshotMismatch()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(ErrorResponse(
            HttpStatusCode.Conflict,
            "SNAPSHOT_VERSION_CONFLICT",
            "snapshotVersion 不匹配")));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.SnapshotMismatch, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_Wrong409FailureCode_ReturnsUpstreamContractInvalid()
    {
        var client = CreateNonMockClient((_, _) => Task.FromResult(ErrorResponse(
            HttpStatusCode.Conflict,
            "OTHER_CONFLICT",
            "其他冲突")));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.UpstreamContractInvalid, result.Status);
        Assert.Null(result.Graph);
    }

    [Fact]
    public async Task NonMock_TransportFailure_ReturnsUnavailable()
    {
        var client = CreateNonMockClient((_, _) =>
            throw new HttpRequestException("connection refused"));

        var result = await FetchContractGraph(client);

        Assert.Equal(PlanGraphFetchStatus.Unavailable, result.Status);
        Assert.Null(result.Graph);
    }

    private static PlanGraphClient CreateNonMockClient(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> sendAsync)
    {
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Gateway:ServiceKey"] = "test-service-key",
            })
            .Build();

        return new PlanGraphClient(
            new StubHttpClientFactory(new StubHttpMessageHandler(sendAsync)),
            NullLogger<PlanGraphClient>.Instance,
            config,
            isMockMode: false);
    }

    private static Task<PlanGraphFetchResult> FetchContractGraph(PlanGraphClient client) =>
        client.GetGraphAsync(
            PlanGraphClient.MockReviewPlanId,
            PlanGraphClient.MockSnapshotVersion,
            "caller-trace",
            CancellationToken.None);

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private static HttpResponseMessage ErrorResponse(
        HttpStatusCode statusCode,
        string code,
        string message) => new(statusCode)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(
                    new
                    {
                        data = (object?)null,
                        error = new { code, message, details = new { } },
                        traceId = "01JPLAN...",
                    },
                    WebJson),
                Encoding.UTF8,
                "application/json"),
        };

    private static string CreateSuccessEnvelope(PlanGraph graph) => JsonSerializer.Serialize(
        new
        {
            data = graph,
            meta = new { },
            traceId = "01JPLAN...",
        },
        WebJson);

    private static PlanGraph BuildContractGraph()
    {
        var prerequisiteId = Guid.Parse("84f7d873-e573-4689-b18d-6f82c745d1bf");
        var targetId = Guid.Parse("d1adc45a-52db-4de2-9cf7-02e1ac0d53cb");

        return new PlanGraph(
            SchemaVersion: "1.0",
            ReviewPlanId: PlanGraphClient.MockReviewPlanId,
            Type: "LEARNING",
            Status: "OPEN",
            GraphId: Guid.Parse("b45d8f8f-4c55-4f28-9de6-2ad7dbb52dc0"),
            GraphVersion: 1,
            OwnerUserId: Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20"),
            SelectedChapterIds: [ContractChapterId],
            SnapshotVersion: PlanGraphClient.MockSnapshotVersion,
            AlgorithmVersion: "learning-planner-v1",
            Nodes:
            [
                new PlanNode(
                    prerequisiteId,
                    ContractChapterId,
                    "作物群体与个体关系",
                    "群体数量与单株生长之间存在资源竞争和补偿关系。",
                    ["群体结构", "基础"],
                    0,
                    "PREREQUISITE",
                    0.5,
                    "MAX_PRODUCT_PREREQUISITE_PATH",
                    1,
                    false,
                    false,
                    [prerequisiteId, targetId],
                    [targetId]),
                new PlanNode(
                    targetId,
                    ContractChapterId,
                    "水稻分蘖期管理目标",
                    "协调群体数量与个体生长，形成合理群体结构。",
                    ["水稻", "分蘖期"],
                    0,
                    "TARGET",
                    0.5,
                    "REQUESTED_CHAPTER_FORGETTING_RISK",
                    0,
                    true,
                    false,
                    [targetId],
                    [targetId]),
            ],
            Edges:
            [
                new PlanEdge(prerequisiteId, targetId, "PREREQUISITE", 0.91, 0.91),
            ],
            RootPointIds: [targetId],
            EstimatedQuestionCount: 1,
            EstimatedCoverage: 0.82,
            TotalWeight: 1,
            CreatedAt: DateTimeOffset.Parse("2026-07-27T08:50:00Z"),
            ExpiresAt: DateTimeOffset.Parse("2026-08-03T08:50:00Z"));
    }

    private sealed class StubHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
    {
        private readonly HttpClient _client = new(handler)
        {
            BaseAddress = new Uri("http://gateway.test/"),
        };

        public HttpClient CreateClient(string name)
        {
            Assert.Equal("gateway", name);
            return _client;
        }
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> sendAsync) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => sendAsync(request, cancellationToken);
    }
}
