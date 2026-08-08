using PracticeService.Domain;
using System.Security.Cryptography;
using System.Text;

namespace PracticeService.API;

internal static class RequestIdentity
{
    public static Guid RequireUser(HttpContext context, string gatewayKey)
    {
        var supplied = context.Request.Headers["X-Gateway-Key"].ToString();
        var expected = Encoding.UTF8.GetBytes(gatewayKey); var actual = Encoding.UTF8.GetBytes(supplied);
        if (actual.Length != expected.Length || !CryptographicOperations.FixedTimeEquals(actual, expected) ||
            !Guid.TryParse(context.Request.Headers["X-User-Id"], out var userId) || userId == Guid.Empty)
            throw new PracticeDomainException(401, "AUTH_REQUIRED", "需要 Gateway 认证的用户身份。");
        return userId;
    }
}
