using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Exceptions;
using Microsoft.AspNetCore.Http;

namespace KnowledgeService.Tests.Features;

public sealed class InternalServiceAccessPolicyTests
{
    [Fact]
    public void Plan_graph_allows_gal_game_service()
    {
        var context = ContextFor("GalGameService");

        var caller =
            InternalServiceAccessPolicy.RequirePlanGraphReader(context);

        Assert.Equal("GalGameService", caller);
    }

    [Theory]
    [InlineData("RenderService")]
    [InlineData("galgameservice")]
    [InlineData("KnowledgeService")]
    public void Plan_graph_rejects_non_allowlisted_service(string serviceName)
    {
        var exception = Assert.Throws<KnowledgeServiceException>(
            () => InternalServiceAccessPolicy.RequirePlanGraphReader(
                ContextFor(serviceName)));

        Assert.Equal(403, exception.StatusCode);
        Assert.Equal("FORBIDDEN", exception.Code);
    }

    [Fact]
    public void Review_evidence_allows_render_service()
    {
        var context = ContextFor("RenderService");

        var caller =
            InternalServiceAccessPolicy.RequireEvidenceWriter(context);

        Assert.Equal("RenderService", caller);
    }

    [Theory]
    [InlineData("GalGameService")]
    [InlineData("renderservice")]
    [InlineData("KnowledgeService")]
    public void Review_evidence_rejects_non_allowlisted_service(
        string serviceName)
    {
        var exception = Assert.Throws<KnowledgeServiceException>(
            () => InternalServiceAccessPolicy.RequireEvidenceWriter(
                ContextFor(serviceName)));

        Assert.Equal(403, exception.StatusCode);
        Assert.Equal("FORBIDDEN", exception.Code);
    }

    private static DefaultHttpContext ContextFor(string serviceName)
    {
        var context = new DefaultHttpContext();
        context.Request.Headers["X-Service-Name"] = serviceName;
        return context;
    }
}
