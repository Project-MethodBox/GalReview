using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

internal static class RequestIdentity
{
    private const string UserHeader = "X-User-Id";
    private const string ServiceHeader = "X-Service-Name";

    public static Guid RequireUserId(HttpContext context)
    {
        if (context.Request.Headers.TryGetValue(UserHeader, out var value) &&
            Guid.TryParse(value.ToString(), out var userId) &&
            userId != Guid.Empty)
        {
            return userId;
        }

        throw new KnowledgeServiceException(
            401,
            "AUTH_REQUIRED",
            "缺少 Gateway 注入的可信用户身份。");
    }

    public static string RequireServiceName(HttpContext context)
    {
        if (context.Request.Headers.TryGetValue(ServiceHeader, out var value) &&
            !string.IsNullOrWhiteSpace(value.ToString()))
        {
            return value.ToString();
        }

        throw new KnowledgeServiceException(
            403,
            "FORBIDDEN",
            "该接口只允许经 Gateway 认证的服务调用。");
    }

    public static string IdempotencyKey(HttpContext context)
    {
        if (context.Request.Headers.TryGetValue("Idempotency-Key", out var value) &&
            !string.IsNullOrWhiteSpace(value.ToString()))
        {
            return value.ToString();
        }

        throw new KnowledgeServiceException(
            400,
            "IDEMPOTENCY_KEY_REQUIRED",
            "该写接口必须提供 Idempotency-Key。");
    }
}
