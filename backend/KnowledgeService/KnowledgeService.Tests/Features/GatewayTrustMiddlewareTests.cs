using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Exceptions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace KnowledgeService.Tests.Features;

public sealed class GatewayTrustMiddlewareTests
{
    private const string ExpectedKey = "knowledge-service-test-key";

    [Theory]
    [InlineData("/api/v1/knowledge-graphs")]
    [InlineData("/internal/v1/review-plans/plan/graph")]
    public async Task ProtectedRoute_WithExpectedGatewayKey_Continues(
        string path)
    {
        var invoked = false;
        var middleware = CreateMiddleware(_ =>
        {
            invoked = true;
            return Task.CompletedTask;
        });
        var context = new DefaultHttpContext();
        context.Request.Path = path;
        context.Request.Headers["X-Gateway-Key"] = ExpectedKey;

        await middleware.InvokeAsync(context);

        Assert.True(invoked);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("wrong-gateway-key")]
    public async Task ProtectedRoute_WithoutExpectedGatewayKey_IsForbidden(
        string? suppliedKey)
    {
        var middleware = CreateMiddleware(_ => Task.CompletedTask);
        var context = new DefaultHttpContext();
        context.Request.Path = "/api/v1/knowledge-graphs";
        if (suppliedKey is not null)
        {
            context.Request.Headers["X-Gateway-Key"] = suppliedKey;
        }

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => middleware.InvokeAsync(context));

        Assert.Equal(403, exception.StatusCode);
        Assert.Equal("FORBIDDEN", exception.Code);
    }

    [Fact]
    public async Task ProtectedRoute_WithMultipleGatewayKeys_IsForbidden()
    {
        var middleware = CreateMiddleware(_ => Task.CompletedTask);
        var context = new DefaultHttpContext();
        context.Request.Path = "/internal/v1/review-evidence/result";
        context.Request.Headers["X-Gateway-Key"] = new StringValues(
            new[] { ExpectedKey, ExpectedKey });

        var exception = await Assert.ThrowsAsync<KnowledgeServiceException>(
            () => middleware.InvokeAsync(context));

        Assert.Equal(403, exception.StatusCode);
        Assert.Equal("FORBIDDEN", exception.Code);
    }

    [Theory]
    [InlineData("/")]
    [InlineData("/healthz")]
    [InlineData("/readyz")]
    public async Task OperationalRoute_DoesNotRequireGatewayKey(string path)
    {
        var invoked = false;
        var middleware = CreateMiddleware(_ =>
        {
            invoked = true;
            return Task.CompletedTask;
        });
        var context = new DefaultHttpContext();
        context.Request.Path = path;

        await middleware.InvokeAsync(context);

        Assert.True(invoked);
    }

    private static GatewayTrustMiddleware CreateMiddleware(
        RequestDelegate next) =>
        new(
            next,
            new GatewayTrustOptions { ServiceKey = ExpectedKey });
}
