using System.Security.Cryptography;
using System.Text;
using KnowledgeService.Application.Exceptions;

namespace KnowledgeService.API.Infrastructure;

public sealed class GatewayTrustMiddleware
{
    private const string GatewayKeyHeader = "X-Gateway-Key";
    private readonly RequestDelegate _next;
    private readonly byte[] _expectedKeyHash;

    public GatewayTrustMiddleware(
        RequestDelegate next,
        GatewayTrustOptions options)
    {
        ArgumentNullException.ThrowIfNull(next);
        ArgumentNullException.ThrowIfNull(options);

        options.Validate();
        _next = next;
        _expectedKeyHash = SHA256.HashData(
            Encoding.UTF8.GetBytes(options.ServiceKey));
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (!RequiresGatewayTrust(context.Request.Path))
        {
            await _next(context);
            return;
        }

        var suppliedValues = context.Request.Headers[GatewayKeyHeader];
        if (suppliedValues.Count != 1 ||
            string.IsNullOrEmpty(suppliedValues[0]) ||
            !HasExpectedKey(suppliedValues[0]!))
        {
            throw new KnowledgeServiceException(
                403,
                "FORBIDDEN",
                "该接口只接受经受信 API Gateway 转发的请求。");
        }

        await _next(context);
    }

    private bool HasExpectedKey(string suppliedKey)
    {
        var suppliedHash = SHA256.HashData(
            Encoding.UTF8.GetBytes(suppliedKey));
        return CryptographicOperations.FixedTimeEquals(
            _expectedKeyHash,
            suppliedHash);
    }

    private static bool RequiresGatewayTrust(PathString path) =>
        path.StartsWithSegments("/api/v1", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWithSegments(
            "/internal/v1",
            StringComparison.OrdinalIgnoreCase);
}
