using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

internal static class InternalServiceAccessPolicy
{
    private const string GalGameService = "GalGameService";
    private const string RenderService = "RenderService";
    private const string PracticeService = "PracticeService";

    public static string RequirePlanGraphReader(HttpContext context) =>
        RequireCaller(context, GalGameService, PracticeService);

    public static string RequireEvidenceWriter(HttpContext context) =>
        RequireCaller(context, RenderService, PracticeService);

    private static string RequireCaller(
        HttpContext context,
        params string[] allowedServiceNames)
    {
        var serviceName = RequestIdentity.RequireServiceName(context);
        if (!allowedServiceNames.Contains(serviceName, StringComparer.Ordinal))
        {
            throw new KnowledgeServiceException(
                403,
                "FORBIDDEN",
                "当前服务身份无权调用该 KnowledgeService 内部接口。");
        }

        return serviceName;
    }
}
