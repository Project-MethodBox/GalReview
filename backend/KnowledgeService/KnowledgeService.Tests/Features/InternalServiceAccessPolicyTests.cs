using KnowledgeService.API.Infrastructure;
using KnowledgeService.Application.Exceptions;
using Microsoft.AspNetCore.Http;

namespace KnowledgeService.Tests.Features;

public sealed class InternalServiceAccessPolicyTests
{
    [Theory]
    [InlineData("GalGameService")]
    [InlineData("PracticeService")]
    public void Plan_graph_allows_exact_allowlisted_services(string serviceName)
    {
        var context = ContextFor(serviceName);

        var caller =
            InternalServiceAccessPolicy.RequirePlanGraphReader(context);

        Assert.Equal(serviceName, caller);
    }

    [Theory]
    [InlineData("RenderService")]
    [InlineData("practiceservice")]
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

    [Theory]
    [InlineData("RenderService")]
    [InlineData("PracticeService")]
    public void Review_evidence_allows_exact_allowlisted_services(string serviceName)
    {
        var context = ContextFor(serviceName);

        var caller =
            InternalServiceAccessPolicy.RequireEvidenceWriter(context);

        Assert.Equal(serviceName, caller);
    }

    [Theory]
    [InlineData("GalGameService")]
    [InlineData("renderservice")]
    [InlineData("practiceservice")]
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
