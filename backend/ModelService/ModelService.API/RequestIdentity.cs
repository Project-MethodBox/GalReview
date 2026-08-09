using ModelService.Domain;
using System.Security.Cryptography;
using System.Text;

namespace ModelService.API;

internal static class RequestIdentity
{
    public static void RequireService(
        HttpContext context,
        string gatewayKey,
        string expectedService)
    {
        var supplied = context.Request.Headers["X-Gateway-Key"].ToString();
        var expected = Encoding.UTF8.GetBytes(gatewayKey);
        var actual = Encoding.UTF8.GetBytes(supplied);
        if (actual.Length != expected.Length ||
            !CryptographicOperations.FixedTimeEquals(actual, expected) ||
            !string.Equals(context.Request.Headers["X-Service-Name"].ToString(),
                expectedService, StringComparison.Ordinal))
            throw new ModelServiceException(403, "FORBIDDEN",
                "该接口只允许 PracticeService 经 Gateway 调用。");
    }
}
