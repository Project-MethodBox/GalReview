using System.Security.Cryptography;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Primitives;

public static class InternalServiceAccessPolicy
{
    public static IReadOnlySet<string> CreateAllowlist(IConfigurationSection section, params string[] defaults)
    {
        var configured = section.GetChildren()
            .Select(child => child.Value)
            .Concat(SplitScalar(section.Value))
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .ToArray();

        return new HashSet<string>(
            section.Exists() ? configured : defaults,
            StringComparer.OrdinalIgnoreCase);
    }

    public static bool IsTrusted(
        IHeaderDictionary headers,
        string gatewayKey,
        IReadOnlySet<string>? allowedServices = null)
    {
        if (!HasSingleFixedTimeValue(headers, "X-Gateway-Key", gatewayKey))
        {
            return false;
        }

        if (!headers.TryGetValue("X-Service-Name", out var serviceNames) || serviceNames.Count != 1)
        {
            return false;
        }

        var serviceName = serviceNames[0]?.Trim();
        if (string.IsNullOrWhiteSpace(serviceName))
        {
            return false;
        }

        return allowedServices is null || allowedServices.Contains(serviceName);
    }

    /// <summary>
    /// 使用固定时间比较防止时序侧信道攻击。仅当 header 恰好一个值且与期望值在
    /// 恒定时间内相等时返回 true。
    /// </summary>
    private static bool HasSingleFixedTimeValue(
        IHeaderDictionary headers,
        string headerName,
        string expected)
    {
        if (!headers.TryGetValue(headerName, out StringValues values) || values.Count != 1)
            return false;
        var actual = values[0];
        if (actual is null) return false;
        var left = System.Text.Encoding.UTF8.GetBytes(actual);
        var right = System.Text.Encoding.UTF8.GetBytes(expected);
        var length = Math.Max(left.Length, right.Length);
        var paddedLeft = new byte[length];
        var paddedRight = new byte[length];
        left.CopyTo(paddedLeft, 0);
        right.CopyTo(paddedRight, 0);
        return CryptographicOperations.FixedTimeEquals(paddedLeft, paddedRight) && left.Length == right.Length;
    }

    private static IEnumerable<string?> SplitScalar(string? value)
    {
        return value?.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            ?? Array.Empty<string>();
    }
}
