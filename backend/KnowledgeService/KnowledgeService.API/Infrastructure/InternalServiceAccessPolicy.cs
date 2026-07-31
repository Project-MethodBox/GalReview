using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

internal static class InternalServiceAccessPolicy
{
    private const string GalGameService = "GalGameService";
    private const string RenderService = "RenderService";

    public static string RequirePlanGraphReader(HttpContext context) =>
        RequireCaller(context, GalGameService);

    public static string RequireEvidenceWriter(HttpContext context) =>
        RequireCaller(context, RenderService);

    private static string RequireCaller(
        HttpContext context,
        string allowedServiceName)
    {
        var serviceName = RequestIdentity.RequireServiceName(context);
        if (!string.Equals(
                serviceName,
                allowedServiceName,
                StringComparison.Ordinal))
        {
            throw new KnowledgeServiceException(
                403,
                "FORBIDDEN",
                "当前服务身份无权调用该 KnowledgeService 内部接口。");
        }

        return serviceName;
    }
}
