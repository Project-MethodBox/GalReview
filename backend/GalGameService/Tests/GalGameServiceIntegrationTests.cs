using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

// ============================================================================
// GalGameService 集成测试（WebApplicationFactory）
//
// 测试完整 HTTP 管道：
// - 中间件链（X-Correlation-Id、异常处理、Gateway 密钥验证）
// - 端点路由与 JSON 序列化
// - ETag / 304 协商缓存
// - 错误信封格式（ApiFailure）
// ============================================================================

public class GalGameServiceIntegrationTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;
    private readonly HttpClient _client;

    private const string GatewayKey = "test-gateway-key";
    private const string UserId = "7bc4918a-9079-4ea2-9e8e-369ad79a9f20";
    private static readonly Guid GoldenPackageId = Guid.Parse("f2561bb2-b88c-47ef-b0ae-8f283ff64f1b");
    private static readonly Guid MockReviewPlanId = Guid.Parse("8e812950-3311-40a7-93ab-636409df8cc2");
    private const string MockSnapshotVersion = "plan-graph-1.0:3da5f48f37ac57c91b49ee747c11e45f1a9e9e73d8e892fcd1bd1f9f3f50c620";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public GalGameServiceIntegrationTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory.WithWebHostBuilder(builder =>
        {
            builder.UseSetting("Gateway:ServiceKey", GatewayKey);
            builder.UseSetting("Gateway:BaseUrl", "http://localhost:5000");
            builder.UseSetting("MOONSTONE_MODE", "Mock");
            // 覆盖 contentRoot 以找到 appsettings.json
            builder.UseSetting("contentRoot", AppContext.BaseDirectory);
        });
        _client = _factory.CreateClient();
    }

    private HttpClient CreateClientWithAuth(string? serviceName = null, string userId = UserId)
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Gateway-Key", GatewayKey);
        client.DefaultRequestHeaders.Add("X-User-Id", userId);
        if (serviceName is not null)
            client.DefaultRequestHeaders.Add("X-Service-Name", serviceName);
        return client;
    }

    // ------------------------------------------------------------------------

    [Fact]
    public async Task Healthz_Returns200_WithoutGatewayKey()
    {
        var resp = await _client.GetAsync("/healthz");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("live", body.GetProperty("data").GetProperty("status").GetString());
    }

    [Fact]
    public async Task Readyz_Returns200_WithoutGatewayKey()
    {
        var resp = await _client.GetAsync("/readyz");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ready", body.GetProperty("data").GetProperty("status").GetString());
    }

    [Fact]
    public async Task GetPackage_WithoutGatewayKey_Returns403()
    {
        var resp = await _client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}");
        Assert.Equal(HttpStatusCode.Forbidden, resp.StatusCode);
        var body = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("FORBIDDEN", body.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task GetPackage_WithoutUserId_Returns401()
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Gateway-Key", GatewayKey);
        // 不加 X-User-Id
        var resp = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}");
        Assert.Equal(HttpStatusCode.Unauthorized, resp.StatusCode);
        Assert.Equal("AUTH_REQUIRED",
            (await resp.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task GetPackage_WithAuth_Returns200_AndNoOwnerUserId()
    {
        var client = CreateClientWithAuth();
        var resp = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var body = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("1.0", body.GetProperty("data").GetProperty("schemaVersion").GetString());
        // OwnerUserId 不应在响应中暴露（[JsonIgnore]）
        Assert.False(body.GetProperty("data").TryGetProperty("ownerUserId", out _));
    }

    [Fact]
    public async Task GetPackageContent_Returns200_WithETag()
    {
        var client = CreateClientWithAuth();
        var resp = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}/content");
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        Assert.NotNull(resp.Headers.ETag);
        // ASP.NET Core 的 CacheControlHeaderValue 排序为 no-cache, private
        Assert.True(resp.Headers.CacheControl?.NoCache);
        Assert.True(resp.Headers.CacheControl?.Private);
        Assert.Equal("nosniff", resp.Headers.GetValues("X-Content-Type-Options").FirstOrDefault());
    }

    [Fact]
    public async Task GetPackageContent_BytesMatchManifestChecksumAndETag()
    {
        var client = CreateClientWithAuth();
        var manifestResponse = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}");
        var manifest = await manifestResponse.Content.ReadFromJsonAsync<JsonElement>();
        var expectedChecksum = manifest.GetProperty("data").GetProperty("checksum").GetString();

        var contentResponse = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}/content");
        var contentBytes = await contentResponse.Content.ReadAsByteArrayAsync();
        var actualChecksum = Convert.ToHexStringLower(SHA256.HashData(contentBytes));

        Assert.Equal(expectedChecksum, actualChecksum);
        Assert.Equal($"\"{expectedChecksum}\"", contentResponse.Headers.ETag?.Tag);
    }

    [Fact]
    public async Task GetPackage_ForDifferentUser_Returns404()
    {
        var client = CreateClientWithAuth(userId: "4bb2a8b6-17b7-4b3b-a106-41ed23a5c763");
        var response = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task GetPackageContent_WithMatchingETag_Returns304()
    {
        var client = CreateClientWithAuth();

        // 第一次请求获取 ETag
        var resp1 = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}/content");
        var etag = resp1.Headers.ETag!.Tag;

        // 第二次请求带 If-None-Match
        client.DefaultRequestHeaders.IfNoneMatch.Add(new System.Net.Http.Headers.EntityTagHeaderValue(etag));
        var resp2 = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}/content");
        Assert.Equal(HttpStatusCode.NotModified, resp2.StatusCode);
    }

    [Fact]
    public async Task GetPackage_NonExistent_Returns404()
    {
        var client = CreateClientWithAuth();
        var resp = await client.GetAsync($"/api/v1/game-packages/{Guid.NewGuid()}");
        Assert.Equal(HttpStatusCode.NotFound, resp.StatusCode);
        Assert.Equal("RESOURCE_NOT_FOUND",
            (await resp.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task PostGeneration_ValidRequest_Returns202()
    {
        var client = CreateClientWithAuth();
        var body = new
        {
            reviewPlanId = MockReviewPlanId,
            snapshotVersion = MockSnapshotVersion,
            style = "CAMPUS",
            difficulty = "STANDARD",
            locale = "zh-CN",
            seed = 42
        };
        var resp = await client.PostAsJsonAsync("/api/v1/game-generations", body);
        Assert.Equal(HttpStatusCode.Accepted, resp.StatusCode);
        var json = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("QUEUED", json.GetProperty("data").GetProperty("status").GetString());
        Assert.Null(json.GetProperty("data").GetProperty("packageId").GetString());
    }

    [Fact]
    public async Task PostGeneration_WrongSnapshot_Returns422()
    {
        var client = CreateClientWithAuth();
        var body = new
        {
            reviewPlanId = MockReviewPlanId,
            snapshotVersion = "WRONG-SNAPSHOT",
            style = "FANTASY",
            difficulty = "BASIC",
            locale = "zh-CN"
        };
        var resp = await client.PostAsJsonAsync("/api/v1/game-generations", body);
        Assert.Equal(HttpStatusCode.UnprocessableEntity, resp.StatusCode);
        var json = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("REVIEW_PLAN_SNAPSHOT_MISMATCH",
            json.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task PostGeneration_MissingStyle_Returns400()
    {
        var client = CreateClientWithAuth();

        var body = new
        {
            reviewPlanId = MockReviewPlanId,
            snapshotVersion = MockSnapshotVersion,
            difficulty = "ADVANCED",
            locale = "zh-CN",
            seed = 999
        };

        var response = await client.PostAsJsonAsync("/api/v1/game-generations", body);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("VALIDATION_ERROR", json.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task PostGeneration_ForDifferentPlanOwner_Returns422WithoutLeakingOwner()
    {
        var client = CreateClientWithAuth(userId: "4bb2a8b6-17b7-4b3b-a106-41ed23a5c763");
        var body = new
        {
            reviewPlanId = MockReviewPlanId,
            snapshotVersion = MockSnapshotVersion,
            style = "CAMPUS",
            difficulty = "STANDARD",
            locale = "zh-CN"
        };

        var response = await client.PostAsJsonAsync("/api/v1/game-generations", body);
        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("REVIEW_PLAN_NOT_FOUND", json.GetProperty("error").GetProperty("code").GetString());
        Assert.DoesNotContain(UserId, await response.Content.ReadAsStringAsync(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task PostValidation_ValidPackage_Returns200()
    {
        var client = CreateClientWithAuth(serviceName: "RenderService");

        // 先获取黄金包内容
        var contentResp = await client.GetAsync($"/api/v1/game-packages/{GoldenPackageId}/content");
        var pkg = await contentResp.Content.ReadFromJsonAsync<JsonElement>();

        var body = new { package = pkg };
        var resp = await client.PostAsJsonAsync("/internal/v1/game-package-validations", body);
        Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
        var json = await resp.Content.ReadFromJsonAsync<JsonElement>();
        Assert.True(json.GetProperty("data").GetProperty("valid").GetBoolean());
    }

    [Fact]
    public async Task PostValidation_InvalidPackage_Returns422WithValidationResult()
    {
        var client = CreateClientWithAuth(serviceName: "RenderService");
        var body = new
        {
            package = new
            {
                schemaVersion = "1.0",
                packageId = GoldenPackageId,
                generatorVersion = "gala-0.1.0",
                reviewPlanId = MockReviewPlanId,
                snapshotVersion = MockSnapshotVersion,
                entrySceneId = "missing",
                scenes = Array.Empty<object>(),
                assets = Array.Empty<object>()
            }
        };

        var response = await client.PostAsJsonAsync("/internal/v1/game-package-validations", body);
        Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.False(json.GetProperty("data").GetProperty("valid").GetBoolean());
        Assert.NotEmpty(json.GetProperty("data").GetProperty("errors").EnumerateArray());
    }

    [Fact]
    public async Task PostValidation_WithoutServiceName_Returns403()
    {
        var client = CreateClientWithAuth();
        // 不加 X-Service-Name
        var body = new { package = new { schemaVersion = "1.0" } };
        var resp = await client.PostAsJsonAsync("/internal/v1/game-package-validations", body);
        Assert.Equal(HttpStatusCode.Forbidden, resp.StatusCode);
    }

    [Fact]
    public async Task PostGeneration_ThenPollStatus_EventuallySucceeds()
    {
        var client = CreateClientWithAuth();
        var body = new
        {
            reviewPlanId = MockReviewPlanId,
            snapshotVersion = MockSnapshotVersion,
            style = "CAMPUS",
            difficulty = "STANDARD",
            locale = "zh-CN",
            seed = 777
        };
        var resp = await client.PostAsJsonAsync("/api/v1/game-generations", body);
        var json = await resp.Content.ReadFromJsonAsync<JsonElement>();
        var genId = json.GetProperty("data").GetProperty("generationId").GetString();

        // 轮询直到 SUCCEEDED 或超时
        var maxAttempts = 20;
        for (var i = 0; i < maxAttempts; i++)
        {
            await Task.Delay(50);
            var statusResp = await client.GetAsync($"/api/v1/game-generations/{genId}");
            var statusJson = await statusResp.Content.ReadFromJsonAsync<JsonElement>();
            var status = statusJson.GetProperty("data").GetProperty("status").GetString();
            if (status == "SUCCEEDED")
            {
                Assert.NotNull(statusJson.GetProperty("data").GetProperty("packageId").GetString());
                return;
            }
            if (status == "FAILED")
                Assert.Fail($"Job failed: {statusJson.GetProperty("data").GetProperty("error").GetProperty("message").GetString()}");
        }
        Assert.Fail("Job did not complete within expected time");
    }

    [Fact]
    public async Task CorrelationId_IsPropagated()
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Correlation-Id", "my-trace-id-12345");
        var resp = await client.GetAsync("/healthz");
        Assert.Equal("my-trace-id-12345", resp.Headers.GetValues("X-Correlation-Id").FirstOrDefault());
    }

    [Fact]
    public async Task CorrelationId_GeneratedWhenMissing()
    {
        var client = _factory.CreateClient();
        var resp = await client.GetAsync("/healthz");
        var corrId = resp.Headers.GetValues("X-Correlation-Id").FirstOrDefault();
        Assert.False(string.IsNullOrWhiteSpace(corrId));
    }
}
