using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KnowledgeService.Application.Exceptions;
using KnowledgeService.Persistence.Materials;
using KnowledgeService.Persistence.Options;

namespace KnowledgeService.Tests.Features;

public sealed class GatewayMaterialTextClientTests
{
    private static readonly Guid MaterialId =
        Guid.Parse("3a7f3d0f-1876-4879-8d6d-01a919d5c935");
    private static readonly Guid OwnerUserId =
        Guid.Parse("7bc4918a-9079-4ea2-9e8e-369ad79a9f20");

    [Fact]
    public async Task GetExtractedTextAsync_ConsumesCurrentFileContract()
    {
        const string text = "第一章 农业生态系统\n1. 生态位：物种利用资源的方式。";
        var handler = new StubHttpHandler(
            request =>
            {
                Assert.Equal(
                    $"/internal/v1/materials/{MaterialId:D}/extracted-text",
                    request.RequestUri?.AbsolutePath);
                Assert.Equal(
                    "KnowledgeService",
                    request.Headers.GetValues("X-Service-Name").Single());
                Assert.Equal(
                    "knowledge-service-test-key",
                    request.Headers.GetValues("X-Service-Key").Single());
                Assert.Equal(
                    "trace-knowledge-contract",
                    request.Headers.GetValues("X-Correlation-Id").Single());

                return JsonResponse(CreatePayload(OwnerUserId, text));
            });
        var client = CreateClient(handler);

        var document = await client.GetExtractedTextAsync(
            MaterialId,
            OwnerUserId,
            "trace-knowledge-contract",
            CancellationToken.None);

        Assert.Equal(MaterialId, document.MaterialId);
        Assert.Equal(OwnerUserId, document.OwnerUserId);
        Assert.Equal(text, document.Text);
        Assert.Equal(Sha256(text), document.TextChecksum);
        var sourceSpan = Assert.Single(document.SourceMap);
        Assert.Equal("第 1 页", sourceSpan.SourceLabel);
        Assert.Equal(text.Length, sourceSpan.EndOffset);
        var block = Assert.Single(document.Blocks);
        Assert.Equal("PARAGRAPH", block.Kind);
        Assert.Equal(text, block.Text);
        Assert.Equal(sourceSpan, block.Source);
        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public async Task GetExtractedTextAsync_RejectsMaterialOwnedByAnotherUser()
    {
        const string text = "第一章 土壤\n1. 土壤结构：土粒形成的空间排列。";
        var otherOwner = Guid.Parse(
            "9d8be45e-ab82-40bb-8a44-0a15a8abf810");
        var handler = new StubHttpHandler(
            _ => JsonResponse(CreatePayload(otherOwner, text)));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => client.GetExtractedTextAsync(
                MaterialId,
                OwnerUserId,
                "trace-owner-check",
                CancellationToken.None));

        Assert.Equal(403, exception.StatusCode);
        Assert.Equal("MATERIAL_ACCESS_DENIED", exception.Code);
    }

    [Fact]
    public async Task GetExtractedTextAsync_RejectsEnvelopeWithoutOwner()
    {
        const string text = "第一章 作物\n1. 光合作用：作物固定光能的过程。";
        var payload = CreatePayload(OwnerUserId, text);
        payload["ownerUserId"] = null;
        var handler = new StubHttpHandler(_ => JsonResponse(payload));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => client.GetExtractedTextAsync(
                MaterialId,
                OwnerUserId,
                "trace-owner-required",
                CancellationToken.None));

        Assert.Equal(502, exception.StatusCode);
        Assert.Equal("MATERIAL_TEXT_CONTRACT_INVALID", exception.Code);
    }

    [Fact]
    public async Task GetExtractedTextAsync_RejectsBlockThatDoesNotMatchRange()
    {
        const string text = "第一章 作物\n1. 蒸腾作用：水分以水蒸气散失。";
        var handler = new StubHttpHandler(
            _ => JsonResponse(
                CreatePayload(
                    OwnerUserId,
                    text,
                    blockText: "被篡改的块文本")));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => client.GetExtractedTextAsync(
                MaterialId,
                OwnerUserId,
                "trace-block-check",
                CancellationToken.None));

        Assert.Equal(502, exception.StatusCode);
        Assert.Equal("MATERIAL_TEXT_CONTRACT_INVALID", exception.Code);
    }

    private static GatewayMaterialTextClient CreateClient(
        HttpMessageHandler handler) =>
        new(
            new HttpClient(handler),
            new GatewayMaterialTextOptions
            {
                BaseUrl = "http://gateway.test/",
                ServiceName = "KnowledgeService",
                ServiceKey = "knowledge-service-test-key",
                Timeout = TimeSpan.FromSeconds(5)
            });

    private static Dictionary<string, object?> CreatePayload(
        Guid ownerUserId,
        string text,
        string? blockText = null)
    {
        var source = new
        {
            startOffset = 0,
            endOffset = text.Length,
            pageNumber = 1,
            paragraphIndex = 0,
            sourceLabel = "第 1 页"
        };
        return new Dictionary<string, object?>
        {
            ["materialId"] = MaterialId,
            ["ownerUserId"] = ownerUserId,
            ["status"] = "READY",
            ["text"] = text,
            ["encoding"] = "utf-8",
            ["normalization"] = "NFC",
            ["lineEnding"] = "LF",
            ["textChecksum"] = Sha256(text),
            ["textLength"] = text.Length,
            ["parserVersion"] = "files-text-v1",
            ["sourceMapVersion"] = "1",
            ["sourceMap"] = new[] { source },
            ["blocks"] = new[]
            {
                new
                {
                    kind = "PARAGRAPH",
                    level = (int?)null,
                    text = blockText ?? text,
                    source
                }
            },
            ["createdAt"] = "2026-07-30T10:00:00Z"
        };
    }

    private static HttpResponseMessage JsonResponse(
        Dictionary<string, object?> payload) =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(new { data = payload }),
                Encoding.UTF8,
                "application/json")
        };

    private static string Sha256(string text) =>
        Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private sealed class StubHttpHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public int CallCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(responseFactory(request));
        }
    }
}
