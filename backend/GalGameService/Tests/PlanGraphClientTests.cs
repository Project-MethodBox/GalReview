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
}
